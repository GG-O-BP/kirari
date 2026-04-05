//// 의존성 해결 — PubGrub 알고리즘, DI 기반 레지스트리 주입

import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/list
import gleam/result
import gleam/string
import kirari/registry/hex
import kirari/registry/npm
import kirari/resolver/conflict
import kirari/resolver/fingerprint
import kirari/resolver/pubgrub
import kirari/semver
import kirari/types.{
  type Dependency, type KirConfig, type KirLock, type Override, type Registry,
  type ResolvedPackage, Hex, Npm,
}

/// resolver 에러 타입
pub type ResolverError {
  IncompatibleVersions(package: String, constraints: List(String))
  PackageNotFound(name: String, registry: Registry)
  RegistryError(detail: String)
  CyclicDependency(cycle: List(String))
  ResolutionConflict(
    explanation: String,
    report: Result(conflict.ConflictReport, Nil),
  )
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
// Incremental Resolution
// ---------------------------------------------------------------------------

/// resolution 필요 여부 판단 결과
pub type ResolutionDecision {
  /// lock이 config와 일치하고 패��지가 설치됨 — 아무것도 안 함
  SkipAll
  /// lock이 config와 일치하���만 일부 미설치 — resolution 건너뛰고 설치만
  InstallOnly
  /// config 변경됨 or lock 없음 — 전체 해결 필요
  FullResolve
}

/// config fingerprint를 기반으로 resolution 필요 여부 판단
pub fn resolution_needed(
  config: KirConfig,
  existing_lock: Result(KirLock, Nil),
) -> ResolutionDecision {
  case existing_lock {
    Error(_) -> FullResolve
    Ok(lock) ->
      case lock.config_fingerprint {
        Error(_) -> FullResolve
        Ok(stored_hash) ->
          case fingerprint.matches(stored_hash, config) {
            False -> FullResolve
            True -> SkipAll
          }
      }
  }
}

/// lock에서 직접 ResolveResult 구성 (resolution 건너뛸 때 사용)
pub fn resolve_result_from_lock(lock: KirLock) -> ResolveResult {
  ResolveResult(
    packages: lock.packages,
    version_infos: dict.new(),
    peer_warnings: [],
  )
}

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

/// 캐시 무시 — 항상 fresh 레지스트리 요청 (kir update용)
pub fn resolve_full_fresh(
  config: KirConfig,
  existing_lock: Result(KirLock, Nil),
) -> Result(ResolveResult, ResolverError) {
  resolve_full_with_deps(
    config,
    existing_lock,
    fetch_from_registries_fresh,
    fetch_release_deps_fresh,
  )
}

/// 오프라인 모드 — 레지스트리 캐시에서만 해결
pub fn resolve_full_offline(
  config: KirConfig,
  existing_lock: Result(KirLock, Nil),
) -> Result(ResolveResult, ResolverError) {
  resolve_full_with_deps(
    config,
    existing_lock,
    fetch_from_registries_offline,
    fetch_release_deps_offline,
  )
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

/// DI 기반 — 버전 조회 + 릴리스 의존성 조회 모두 주입 (테스트용)
pub fn resolve_full_with_deps(
  config: KirConfig,
  existing_lock: Result(KirLock, Nil),
  fetch: FetchVersions,
  fetch_deps: FetchReleaseDeps,
) -> Result(ResolveResult, ResolverError) {
  let raw_deps =
    list.flatten([
      config.hex_deps,
      config.hex_dev_deps,
      config.npm_deps,
      config.npm_dev_deps,
    ])
  // npm dist-tag 사전 해결 (직접 의존성만 — 전이 의존성은 이미 concrete semver)
  use direct_deps <- result.try(resolve_dist_tags(raw_deps))
  let exclude_newer = case config.security.exclude_newer {
    Ok(ts) -> Ok(ts)
    Error(_) -> Error(Nil)
  }
  let overrides = overrides_to_dict(config.overrides)

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

  // 직접 의존성 버전을 병렬 prefetch (solver 시작 전 워밍업)
  let prefetch_cache = prefetch_direct_versions(direct_deps, pubgrub_fetch)

  let ctx =
    pubgrub.SolverContext(
      fetch_versions: pubgrub_fetch,
      fetch_deps: pubgrub_fetch_deps,
      existing_lock: existing_lock,
      exclude_newer: exclude_newer,
      overrides: overrides,
      prefetch_cache: prefetch_cache,
    )

  use solve_result <- result.try(
    pubgrub.solve(direct_deps, ctx)
    |> result.map_error(fn(e) { convert_pubgrub_error(e, direct_deps) }),
  )

  // PubGrub 결과를 ResolveResult로 변환
  let entries = solve_result.entries
  let resolved_dict = dict.map_values(entries, fn(_key, pair) { pair.0 })
  let packages =
    dict.values(resolved_dict)
    |> list.sort(types.compare_packages)

  // 전체 VersionInfo (tarball_url 등 포함) 재구축
  let version_infos = build_version_infos(entries, fetch)

  // dev 전이 의존성 분류 — production 루트에서 도달 불가능한 패키지를 dev로 표시
  let packages = classify_dev_packages(packages, config, version_infos)

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
    ResolutionConflict(ex, _) ->
      pubgrub.ResolutionConflict(ex, Error(Nil), dict.new())
    IncompatibleVersions(pkg, cs) ->
      pubgrub.ResolutionConflict(
        "no compatible version for "
          <> pkg
          <> " ("
          <> string.join(cs, ", ")
          <> ")",
        Error(Nil),
        dict.new(),
      )
    CyclicDependency(c) ->
      pubgrub.ResolutionConflict(
        "cyclic dependency: " <> string.join(c, " → "),
        Error(Nil),
        dict.new(),
      )
  }
}

fn convert_pubgrub_error(
  e: pubgrub.PubGrubError,
  direct_deps: List(Dependency),
) -> ResolverError {
  case e {
    pubgrub.ResolutionConflict(explanation, root_cause, vcache) -> {
      let report = case root_cause {
        Ok(inc) -> {
          let available =
            dict.map_values(vcache, fn(_key, versions) {
              list.map(versions, fn(vi) { vi.version })
            })
          Ok(conflict.build_report(inc, direct_deps, available))
        }
        Error(_) -> Error(Nil)
      }
      ResolutionConflict(explanation, report)
    }
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
    Hex -> fetch_hex_versions(name, False)
    Npm -> fetch_npm_versions(name, False)
  }
}

fn fetch_from_registries_fresh(
  name: String,
  registry: Registry,
) -> Result(List(VersionInfo), ResolverError) {
  case registry {
    Hex -> fetch_hex_versions(name, True)
    Npm -> fetch_npm_versions(name, True)
  }
}

fn fetch_from_registries_offline(
  name: String,
  registry: Registry,
) -> Result(List(VersionInfo), ResolverError) {
  case registry {
    Hex -> fetch_hex_versions_offline(name)
    Npm -> fetch_npm_versions_offline(name)
  }
}

fn fetch_release_deps_offline(
  name: String,
  version: String,
  registry: Registry,
) -> Result(#(List(types.Dependency), String), ResolverError) {
  case registry {
    Hex -> {
      use info <- result.try(
        hex.get_release_info_offline(name, version)
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

fn fetch_release_deps_from_registries(
  name: String,
  version: String,
  registry: Registry,
) -> Result(#(List(types.Dependency), String), ResolverError) {
  fetch_release_deps_impl(name, version, registry, False)
}

fn fetch_release_deps_fresh(
  name: String,
  version: String,
  registry: Registry,
) -> Result(#(List(types.Dependency), String), ResolverError) {
  fetch_release_deps_impl(name, version, registry, True)
}

fn fetch_release_deps_impl(
  name: String,
  version: String,
  registry: Registry,
  skip_cache: Bool,
) -> Result(#(List(types.Dependency), String), ResolverError) {
  case registry {
    Hex -> {
      use info <- result.try(
        hex.get_release_info_with_opts(name, version, skip_cache)
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

fn fetch_hex_versions(
  name: String,
  skip_cache: Bool,
) -> Result(List(VersionInfo), ResolverError) {
  use versions <- result.try(
    hex.get_versions_with_opts(name, skip_cache)
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

fn fetch_npm_versions(
  name: String,
  skip_cache: Bool,
) -> Result(List(VersionInfo), ResolverError) {
  use versions <- result.try(
    npm.get_versions_with_tags_opts(name, skip_cache)
    |> result.map(fn(r) { r.versions })
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

fn fetch_hex_versions_offline(
  name: String,
) -> Result(List(VersionInfo), ResolverError) {
  use versions <- result.try(
    hex.get_versions_offline(name)
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

fn fetch_npm_versions_offline(
  name: String,
) -> Result(List(VersionInfo), ResolverError) {
  use versions <- result.try(
    npm.get_versions_with_tags_offline(name)
    |> result.map(fn(r) { r.versions })
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
// Override 변환
// ---------------------------------------------------------------------------

fn overrides_to_dict(overrides: List(Override)) -> Dict(String, String) {
  list.fold(overrides, dict.new(), fn(acc, o) {
    let key = o.name <> ":" <> types.registry_to_string(o.registry)
    dict.insert(acc, key, o.version_constraint)
  })
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

// ---------------------------------------------------------------------------
// npm dist-tag 사전 해결
// ---------------------------------------------------------------------------

/// 직접 의존성 목록에서 npm dist-tag 제약을 concrete 버전으로 해결
/// Hex deps와 일반 semver 제약은 그대로 통과
fn resolve_dist_tags(
  deps: List(Dependency),
) -> Result(List(Dependency), ResolverError) {
  list.try_map(deps, resolve_one_dist_tag)
}

fn resolve_one_dist_tag(dep: Dependency) -> Result(Dependency, ResolverError) {
  case dep.registry, semver.is_dist_tag(dep.version_constraint) {
    Npm, True -> {
      // dist-tag를 해결하려면 전체 버전 목록이 필요
      // fetch 결과에서 dist-tags를 직접 얻을 수 없으므로 npm API 직접 호출
      case npm.get_versions_with_tags(dep.name) {
        Ok(result) ->
          case dict.get(result.dist_tags, dep.version_constraint) {
            Ok(version) ->
              Ok(types.Dependency(..dep, version_constraint: "= " <> version))
            Error(_) ->
              // 알 수 없는 tag — 그대로 통과 (solver가 실패할 것)
              Ok(dep)
          }
        Error(_) ->
          // 네트워크 오류 — 그대로 통과
          Ok(dep)
      }
    }
    _, _ -> Ok(dep)
  }
}

// ---------------------------------------------------------------------------
// dev 전이 의존성 분류
// ---------------------------------------------------------------------------

/// production 루트에서 BFS 도달 가능 여부로 dev/prod 분류
/// production 루트: hex_deps + npm_deps (dev가 아닌 직접 의존성)
/// dev-only: production 루트에서 도달 불가능한 패키지
fn classify_dev_packages(
  packages: List(types.ResolvedPackage),
  config: types.KirConfig,
  version_infos: Dict(String, VersionInfo),
) -> List(types.ResolvedPackage) {
  // 1. production 루트 키 수집
  let prod_keys =
    list.flatten([
      list.map(config.hex_deps, fn(d) {
        d.name <> ":" <> types.registry_to_string(d.registry)
      }),
      list.map(config.npm_deps, fn(d) {
        d.name <> ":" <> types.registry_to_string(d.registry)
      }),
    ])

  // 2. 의존성 인접 리스트 구축
  let graph = build_dep_graph(packages, version_infos)

  // 3. production 루트에서 BFS — 도달 가능한 패키지 집합
  let prod_reachable = bfs_reachable(prod_keys, graph)

  // 4. 도달 불가능한 패키지를 dev로 표시
  list.map(packages, fn(pkg) {
    let key = pkg.name <> ":" <> types.registry_to_string(pkg.registry)
    let is_prod = dict.has_key(prod_reachable, key)
    types.ResolvedPackage(..pkg, dev: !is_prod)
  })
}

/// 패키지별 의존성 인접 리스트 구축
fn build_dep_graph(
  packages: List(types.ResolvedPackage),
  version_infos: Dict(String, VersionInfo),
) -> Dict(String, List(String)) {
  list.fold(packages, dict.new(), fn(acc, pkg) {
    let key = pkg.name <> ":" <> types.registry_to_string(pkg.registry)
    let dep_keys = case dict.get(version_infos, key) {
      Ok(vi) ->
        list.map(vi.dependencies, fn(d) {
          d.name <> ":" <> types.registry_to_string(d.registry)
        })
      Error(_) -> []
    }
    dict.insert(acc, key, dep_keys)
  })
}

/// BFS로 루트 집합에서 도달 가능한 모든 노드 수집
fn bfs_reachable(
  roots: List(String),
  graph: Dict(String, List(String)),
) -> Dict(String, Nil) {
  do_bfs(roots, graph, dict.new())
}

fn do_bfs(
  queue: List(String),
  graph: Dict(String, List(String)),
  visited: Dict(String, Nil),
) -> Dict(String, Nil) {
  case queue {
    [] -> visited
    [key, ..rest] ->
      case dict.has_key(visited, key) {
        True -> do_bfs(rest, graph, visited)
        False -> {
          let new_visited = dict.insert(visited, key, Nil)
          let neighbors = case dict.get(graph, key) {
            Ok(deps) -> deps
            Error(_) -> []
          }
          do_bfs(list.append(rest, neighbors), graph, new_visited)
        }
      }
  }
}

// ---------------------------------------------------------------------------
// 병렬 레지스트리 Prefetch
// ---------------------------------------------------------------------------

/// 직접 의존성의 버전 목록을 Erlang process로 병렬 fetch
/// 실패한 패키지는 결과에서 제외 (solver가 나중에 재시도)
fn prefetch_direct_versions(
  deps: List(types.Dependency),
  fetch: pubgrub.FetchVersions,
) -> Dict(String, List(pubgrub.VersionInfoCompact)) {
  // 중복 제거 (같은 패키지가 dev + prod에 모두 있을 수 있음)
  let unique_keys =
    list.map(deps, fn(d) {
      #(d.name <> ":" <> types.registry_to_string(d.registry), d)
    })
    |> dict.from_list
    |> dict.to_list

  let subject = process.new_subject()

  // 각 의존성마다 프로세스 스폰
  list.each(unique_keys, fn(entry) {
    let #(key, dep) = entry
    process.spawn(fn() {
      let result = fetch(dep.name, dep.registry)
      process.send(subject, #(key, result))
    })
  })

  // 결과 수집 (30초 타임아웃)
  collect_prefetch_results(subject, list.length(unique_keys), dict.new())
}

fn collect_prefetch_results(
  subject: process.Subject(
    #(String, Result(List(pubgrub.VersionInfoCompact), pubgrub.PubGrubError)),
  ),
  remaining: Int,
  acc: Dict(String, List(pubgrub.VersionInfoCompact)),
) -> Dict(String, List(pubgrub.VersionInfoCompact)) {
  case remaining <= 0 {
    True -> acc
    False ->
      case process.receive(subject, 30_000) {
        Ok(#(key, Ok(versions))) ->
          collect_prefetch_results(
            subject,
            remaining - 1,
            dict.insert(acc, key, versions),
          )
        Ok(#(_key, Error(_))) ->
          // fetch 실패 — 캐시에 넣지 않음, solver가 나중에 재시도
          collect_prefetch_results(subject, remaining - 1, acc)
        Error(_) ->
          // 타임아웃 — 남은 패키지 포기
          acc
      }
  }
}
