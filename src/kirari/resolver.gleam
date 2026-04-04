//// 의존성 해결 — PubGrub 알고리즘, DI 기반 레지스트리 주입

import gleam/dict.{type Dict}
import gleam/list
import gleam/result
import gleam/string
import kirari/registry/hex
import kirari/registry/npm
import kirari/resolver/pubgrub
import kirari/semver
import kirari/types.{
  type Dependency, type KirConfig, type KirLock, type Registry,
  type ResolvedPackage, Hex, Npm,
}

/// resolver 에러 타입
pub type ResolverError {
  IncompatibleVersions(package: String, constraints: List(String))
  PackageNotFound(name: String, registry: Registry)
  RegistryError(detail: String)
  CyclicDependency(cycle: List(String))
  ResolutionConflict(explanation: String)
}

/// 레지스트리에서 가져온 버전 정보 (통합)
pub type VersionInfo {
  VersionInfo(
    version: String,
    published_at: String,
    tarball_url: String,
    dependencies: List(Dependency),
    peer_dependencies: List(PeerDependency),
    optional_dependencies: List(Dependency),
    os: List(String),
    cpu: List(String),
    has_scripts: Bool,
    signatures: List(#(String, String)),
    integrity: String,
    deprecated: String,
    license: String,
  )
}

/// npm peerDependencies 항목 (해결 대상이 아닌 검증 대상)
pub type PeerDependency {
  PeerDependency(
    name: String,
    constraint: String,
    registry: Registry,
    optional: Bool,
  )
}

/// peer dependency 검증 경고
pub type PeerWarning {
  PeerMissing(package: String, peer: String, constraint: String)
  PeerIncompatible(
    package: String,
    peer: String,
    required: String,
    installed: String,
  )
}

/// 해결 결과 — 패키지 목록 + 버전 정보 캐시 (파이프라인에서 tarball_url 조회용)
pub type ResolveResult {
  ResolveResult(
    packages: List(ResolvedPackage),
    version_infos: Dict(String, VersionInfo),
    peer_warnings: List(PeerWarning),
  )
}

/// 레지스트리 조회 함수 타입
pub type FetchVersions =
  fn(String, Registry) -> Result(List(VersionInfo), ResolverError)

/// 선택된 버전의 의존성 + deprecated 정보 조회 함수 타입
pub type FetchReleaseDeps =
  fn(String, String, Registry) ->
    Result(#(List(types.Dependency), String), ResolverError)

// ---------------------------------------------------------------------------
// 공개 API
// ---------------------------------------------------------------------------

/// 실제 레지스트리를 사용하여 의존성 해결
pub fn resolve(
  config: KirConfig,
  existing_lock: Result(KirLock, Nil),
) -> Result(List(ResolvedPackage), ResolverError) {
  resolve_with(config, existing_lock, fetch_from_registries)
}

/// 레지스트리 함수를 주입하여 의존성 해결 (테스트용)
pub fn resolve_with(
  config: KirConfig,
  existing_lock: Result(KirLock, Nil),
  fetch: FetchVersions,
) -> Result(List(ResolvedPackage), ResolverError) {
  use r <- result.try(resolve_full_with_deps(
    config,
    existing_lock,
    fetch,
    no_op_fetch_deps,
  ))
  Ok(r.packages)
}

fn no_op_fetch_deps(
  _name: String,
  _version: String,
  _registry: Registry,
) -> Result(#(List(types.Dependency), String), ResolverError) {
  Ok(#([], ""))
}

/// 실제 레지스트리 — 패키지 + 버전 정보 함께 반환
pub fn resolve_full(
  config: KirConfig,
  existing_lock: Result(KirLock, Nil),
) -> Result(ResolveResult, ResolverError) {
  resolve_full_with(config, existing_lock, fetch_from_registries)
}

/// DI 기반 — 패키지 + 버전 정보 함께 반환
pub fn resolve_full_with(
  config: KirConfig,
  existing_lock: Result(KirLock, Nil),
  fetch: FetchVersions,
) -> Result(ResolveResult, ResolverError) {
  resolve_full_with_deps(
    config,
    existing_lock,
    fetch,
    fetch_release_deps_from_registries,
  )
}

// ---------------------------------------------------------------------------
// PubGrub 위임
// ---------------------------------------------------------------------------

fn resolve_full_with_deps(
  config: KirConfig,
  existing_lock: Result(KirLock, Nil),
  fetch: FetchVersions,
  fetch_deps: FetchReleaseDeps,
) -> Result(ResolveResult, ResolverError) {
  let direct_deps =
    list.flatten([
      config.hex_deps,
      config.hex_dev_deps,
      config.npm_deps,
      config.npm_dev_deps,
    ])
  let exclude_newer = case config.security.exclude_newer {
    Ok(ts) -> Ok(ts)
    Error(_) -> Error(Nil)
  }

  // FetchVersions를 PubGrub 형식으로 변환
  let pubgrub_fetch = fn(name: String, registry: Registry) {
    use vis <- result.try(
      fetch(name, registry)
      |> result.map_error(convert_error),
    )
    Ok(list.map(vis, version_info_to_compact))
  }

  // FetchReleaseDeps를 PubGrub 형식으로 변환
  let pubgrub_fetch_deps = fn(name: String, version: String, registry: Registry) {
    fetch_deps(name, version, registry)
    |> result.map_error(convert_error)
  }

  let ctx =
    pubgrub.SolverContext(
      fetch_versions: pubgrub_fetch,
      fetch_deps: pubgrub_fetch_deps,
      existing_lock: existing_lock,
      exclude_newer: exclude_newer,
    )

  use solve_result <- result.try(
    pubgrub.solve(direct_deps, ctx)
    |> result.map_error(convert_pubgrub_error),
  )

  // PubGrub 결과를 ResolveResult로 변환
  let entries = solve_result.entries
  let resolved_dict = dict.map_values(entries, fn(_key, pair) { pair.0 })
  let packages =
    dict.values(resolved_dict)
    |> list.sort(types.compare_packages)

  // 전체 VersionInfo (tarball_url 등 포함) 재구축
  let version_infos = build_version_infos(entries, fetch)

  // peer dependency 검증
  let peer_warnings = verify_peer_dependencies(resolved_dict, version_infos)

  Ok(ResolveResult(
    packages: packages,
    version_infos: version_infos,
    peer_warnings: peer_warnings,
  ))
}

fn version_info_to_compact(vi: VersionInfo) -> pubgrub.VersionInfoCompact {
  pubgrub.VersionInfoCompact(
    version: vi.version,
    published_at: vi.published_at,
    dependencies: vi.dependencies,
    optional_dependencies: vi.optional_dependencies,
    os: vi.os,
    cpu: vi.cpu,
    license: vi.license,
  )
}

fn convert_error(e: ResolverError) -> pubgrub.PubGrubError {
  case e {
    PackageNotFound(name, registry) -> pubgrub.PkgNotFound(name, registry)
    RegistryError(d) -> pubgrub.RegError(d)
    ResolutionConflict(ex) -> pubgrub.ResolutionConflict(ex)
    IncompatibleVersions(pkg, cs) ->
      pubgrub.ResolutionConflict(
        "no compatible version for "
        <> pkg
        <> " ("
        <> string.join(cs, ", ")
        <> ")",
      )
    CyclicDependency(c) ->
      pubgrub.ResolutionConflict("cyclic dependency: " <> string.join(c, " → "))
  }
}

fn convert_pubgrub_error(e: pubgrub.PubGrubError) -> ResolverError {
  case e {
    pubgrub.ResolutionConflict(explanation) -> ResolutionConflict(explanation)
    pubgrub.PkgNotFound(name, registry) -> PackageNotFound(name, registry)
    pubgrub.RegError(detail) -> RegistryError(detail)
  }
}

/// PubGrub 결과에서 전체 VersionInfo 재구축 (tarball_url, signatures 등 포함)
fn build_version_infos(
  entries: Dict(String, #(ResolvedPackage, pubgrub.VersionInfoCompact)),
  fetch: FetchVersions,
) -> Dict(String, VersionInfo) {
  dict.fold(entries, dict.new(), fn(acc, key, pair) {
    let #(pkg, compact) = pair
    // 레지스트리에서 전체 VersionInfo 조회하여 tarball_url 등 복원
    let full_vi = case fetch(pkg.name, pkg.registry) {
      Ok(vis) ->
        case list.find(vis, fn(v) { v.version == pkg.version }) {
          Ok(vi) -> vi
          Error(_) -> compact_to_full(compact)
        }
      Error(_) -> compact_to_full(compact)
    }
    dict.insert(acc, key, full_vi)
  })
}

fn compact_to_full(c: pubgrub.VersionInfoCompact) -> VersionInfo {
  VersionInfo(
    version: c.version,
    published_at: c.published_at,
    tarball_url: "",
    dependencies: c.dependencies,
    peer_dependencies: [],
    optional_dependencies: c.optional_dependencies,
    os: c.os,
    cpu: c.cpu,
    has_scripts: False,
    signatures: [],
    integrity: "",
    deprecated: "",
    license: c.license,
  )
}

// ---------------------------------------------------------------------------
// peer dependency 검증 (post-resolution)
// ---------------------------------------------------------------------------

fn verify_peer_dependencies(
  resolved: Dict(String, ResolvedPackage),
  version_cache: Dict(String, VersionInfo),
) -> List(PeerWarning) {
  dict.to_list(version_cache)
  |> list.flat_map(fn(entry) {
    let #(key, vi) = entry
    let package_name = case string.split_once(key, ":") {
      Ok(#(name, _)) -> name
      Error(_) -> key
    }
    list.filter_map(vi.peer_dependencies, fn(peer) {
      let peer_key = peer.name <> ":" <> types.registry_to_string(peer.registry)
      case dict.get(resolved, peer_key) {
        Ok(installed) ->
          case
            semver.parse_npm_constraint(peer.constraint),
            semver.parse_version(installed.version)
          {
            Ok(constraint), Ok(version) ->
              case semver.satisfies(version, constraint) {
                True -> Error(Nil)
                False ->
                  Ok(PeerIncompatible(
                    package: package_name,
                    peer: peer.name,
                    required: peer.constraint,
                    installed: installed.version,
                  ))
              }
            _, _ -> Error(Nil)
          }
        Error(_) ->
          case peer.optional {
            True -> Error(Nil)
            False ->
              Ok(PeerMissing(
                package: package_name,
                peer: peer.name,
                constraint: peer.constraint,
              ))
          }
      }
    })
  })
}

// ---------------------------------------------------------------------------
// 실제 레지스트리 조회
// ---------------------------------------------------------------------------

fn fetch_from_registries(
  name: String,
  registry: Registry,
) -> Result(List(VersionInfo), ResolverError) {
  case registry {
    Hex -> fetch_hex_versions(name)
    Npm -> fetch_npm_versions(name)
  }
}

fn fetch_release_deps_from_registries(
  name: String,
  version: String,
  registry: Registry,
) -> Result(#(List(types.Dependency), String), ResolverError) {
  case registry {
    Hex -> {
      use info <- result.try(
        hex.get_release_info(name, version)
        |> result.map_error(fn(e) { RegistryError(string.inspect(e)) }),
      )
      let deps =
        list.map(info.deps, fn(d) {
          types.Dependency(
            name: d.name,
            version_constraint: d.requirement,
            registry: Hex,
            dev: False,
            optional: False,
          )
        })
      let deprecated = case info.retired {
        True -> "retired: " <> info.retirement_reason
        False -> ""
      }
      Ok(#(deps, deprecated))
    }
    Npm -> Ok(#([], ""))
  }
}

fn fetch_hex_versions(name: String) -> Result(List(VersionInfo), ResolverError) {
  use versions <- result.try(
    hex.get_versions(name)
    |> result.map_error(fn(e) { RegistryError(string.inspect(e)) }),
  )
  Ok(
    list.map(versions, fn(v) {
      VersionInfo(
        version: v.version,
        published_at: v.inserted_at,
        tarball_url: "https://repo.hex.pm/tarballs/"
          <> name
          <> "-"
          <> v.version
          <> ".tar",
        dependencies: list.map(v.dependencies, fn(d) {
          types.Dependency(
            name: d.name,
            version_constraint: d.requirement,
            registry: Hex,
            dev: False,
            optional: False,
          )
        }),
        peer_dependencies: [],
        optional_dependencies: [],
        os: [],
        cpu: [],
        has_scripts: False,
        signatures: [],
        integrity: "",
        deprecated: "",
        license: v.license,
      )
    }),
  )
}

fn fetch_npm_versions(name: String) -> Result(List(VersionInfo), ResolverError) {
  use versions <- result.try(
    npm.get_versions(name)
    |> result.map_error(fn(e) { RegistryError(string.inspect(e)) }),
  )
  Ok(
    list.map(versions, fn(v) {
      VersionInfo(
        version: v.version,
        published_at: v.published_at,
        tarball_url: v.tarball_url,
        dependencies: list.map(v.dependencies, fn(d) {
          types.Dependency(
            name: d.name,
            version_constraint: d.constraint,
            registry: Npm,
            dev: False,
            optional: False,
          )
        }),
        peer_dependencies: list.map(v.peer_dependencies, fn(p) {
          PeerDependency(
            name: p.name,
            constraint: p.constraint,
            registry: Npm,
            optional: p.optional,
          )
        }),
        optional_dependencies: list.map(v.optional_dependencies, fn(d) {
          types.Dependency(
            name: d.name,
            version_constraint: d.constraint,
            registry: Npm,
            dev: False,
            optional: True,
          )
        }),
        os: v.os,
        cpu: v.cpu,
        has_scripts: v.has_scripts,
        signatures: list.map(v.signatures, fn(s) { #(s.keyid, s.sig) }),
        integrity: v.integrity,
        deprecated: v.deprecated,
        license: v.license,
      )
    }),
  )
}

// ---------------------------------------------------------------------------
// 의존성 체인 분석
// ---------------------------------------------------------------------------

/// lock에서 pkg_name을 의존하는 패키지 목록 반환 ("name@version" 형식)
pub fn find_dependents(
  pkg_name: String,
  version_infos: Dict(String, VersionInfo),
  lock: KirLock,
) -> List(String) {
  list.filter_map(lock.packages, fn(p) {
    let key = p.name <> ":" <> types.registry_to_string(p.registry)
    case dict.get(version_infos, key) {
      Ok(vi) ->
        case list.any(vi.dependencies, fn(d) { d.name == pkg_name }) {
          True -> Ok(p.name <> "@" <> p.version)
          False -> Error(Nil)
        }
      Error(_) -> Error(Nil)
    }
  })
}

/// 레지스트리에서 최신 버전 조회
pub fn get_latest_version(
  name: String,
  registry: Registry,
) -> Result(String, Nil) {
  let versions = case registry {
    Hex ->
      hex.get_versions(name)
      |> result.map(list.map(_, fn(v) { v.version }))
      |> result.replace_error(Nil)
    Npm ->
      npm.get_versions(name)
      |> result.map(list.map(_, fn(v) { v.version }))
      |> result.replace_error(Nil)
  }
  use vs <- result.try(versions)
  vs
  |> list.filter_map(semver.parse_version)
  |> list.sort(semver.compare)
  |> list.last
  |> result.map(semver.to_string)
}
