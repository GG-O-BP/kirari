//// 의존성 해결 — Greedy 알고리즘, DI 기반 레지스트리 주입

import gleam/dict.{type Dict}
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import kirari/platform
import kirari/registry/hex
import kirari/registry/npm
import kirari/security
import kirari/semver.{type Constraint}
import kirari/types.{
  type Dependency, type KirConfig, type KirLock, type Registry,
  type ResolvedPackage, Hex, Npm, ResolvedPackage,
}

/// resolver 에러 타입
pub type ResolverError {
  IncompatibleVersions(package: String, constraints: List(String))
  PackageNotFound(name: String, registry: Registry)
  RegistryError(detail: String)
  CyclicDependency(cycle: List(String))
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
/// mock_fetch가 dependencies를 이미 포함하므로 release deps 조회 불필요
pub fn resolve_with(
  config: KirConfig,
  existing_lock: Result(KirLock, Nil),
  fetch: FetchVersions,
) -> Result(List(ResolvedPackage), ResolverError) {
  use result <- result.try(resolve_full_with_deps(
    config,
    existing_lock,
    fetch,
    no_op_fetch_deps,
  ))
  Ok(result.packages)
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
  do_resolve(
    direct_deps,
    dict.new(),
    dict.new(),
    dict.new(),
    existing_lock,
    exclude_newer,
    fetch,
    fetch_deps,
    [],
  )
}

// ---------------------------------------------------------------------------
// Greedy 해결 루프
// ---------------------------------------------------------------------------

/// constraints_map: 패키지 key → 해당 패키지에 부여된 제약 조건 목록
/// 다이아몬드 충돌 감지 및 에러 메시지에 사용
fn do_resolve(
  queue: List(Dependency),
  resolved: Dict(String, ResolvedPackage),
  version_cache: Dict(String, VersionInfo),
  constraints_map: Dict(String, List(String)),
  existing_lock: Result(KirLock, Nil),
  exclude_newer: Result(String, Nil),
  fetch: FetchVersions,
  fetch_deps: FetchReleaseDeps,
  visited: List(String),
) -> Result(ResolveResult, ResolverError) {
  case queue {
    [] -> {
      let peer_warnings = verify_peer_dependencies(resolved, version_cache)
      Ok(ResolveResult(
        packages: dict.values(resolved)
          |> list.sort(types.compare_packages),
        version_infos: version_cache,
        peer_warnings: peer_warnings,
      ))
    }
    [dep, ..rest] -> {
      let key = dep.name <> ":" <> types.registry_to_string(dep.registry)
      // 제약 조건 기록
      let constraints_map =
        dict.upsert(constraints_map, key, fn(existing) {
          case existing {
            option.Some(cs) -> [dep.version_constraint, ..cs]
            option.None -> [dep.version_constraint]
          }
        })
      case dict.get(resolved, key) {
        // 이미 해결됨 → 새 제약 조건과 호환 검증
        Ok(pkg) -> {
          use _ <- result.try(verify_compatible(pkg, dep, constraints_map))
          do_resolve(
            rest,
            resolved,
            version_cache,
            constraints_map,
            existing_lock,
            exclude_newer,
            fetch,
            fetch_deps,
            visited,
          )
        }
        Error(_) -> {
          case list.contains(visited, key) {
            True -> Error(CyclicDependency([key, ..visited]))
            False -> {
              case resolve_one(dep, existing_lock, exclude_newer, fetch) {
                Ok(#(pkg, vi)) -> {
                  // 의존성이 비어있으면 개별 release API에서 조회
                  use vi <- result.try(enrich_dependencies(
                    vi,
                    pkg.name,
                    pkg.version,
                    dep.registry,
                    fetch_deps,
                  ))
                  let new_resolved = dict.insert(resolved, key, pkg)
                  let new_cache = dict.insert(version_cache, key, vi)
                  // 전이 의존성 + optional 의존성 모두 큐에 추가
                  let transitive =
                    list.append(vi.dependencies, vi.optional_dependencies)
                  do_resolve(
                    list.append(rest, transitive),
                    new_resolved,
                    new_cache,
                    constraints_map,
                    existing_lock,
                    exclude_newer,
                    fetch,
                    fetch_deps,
                    [key, ..visited],
                  )
                }
                Error(_) if dep.optional -> {
                  // optional 의존성 해결 실패 → 건너뛰고 계속
                  do_resolve(
                    rest,
                    resolved,
                    version_cache,
                    constraints_map,
                    existing_lock,
                    exclude_newer,
                    fetch,
                    fetch_deps,
                    visited,
                  )
                }
                Error(e) -> Error(e)
              }
            }
          }
        }
      }
    }
  }
}

/// 이미 해결된 버전이 새 제약 조건을 만족하는지 검증
fn verify_compatible(
  pkg: ResolvedPackage,
  dep: Dependency,
  constraints_map: Dict(String, List(String)),
) -> Result(Nil, ResolverError) {
  case parse_constraint(dep) {
    Ok(constraint) -> {
      case semver.parse_version(pkg.version) {
        Ok(version) ->
          case semver.satisfies(version, constraint) {
            True -> Ok(Nil)
            False -> {
              let key =
                dep.name <> ":" <> types.registry_to_string(dep.registry)
              let all_constraints = case dict.get(constraints_map, key) {
                Ok(cs) -> cs
                Error(_) -> [dep.version_constraint]
              }
              Error(IncompatibleVersions(
                package: dep.name <> "@" <> pkg.version,
                constraints: all_constraints,
              ))
            }
          }
        Error(_) -> Ok(Nil)
      }
    }
    Error(_) -> Ok(Nil)
  }
}

fn resolve_one(
  dep: Dependency,
  existing_lock: Result(KirLock, Nil),
  exclude_newer: Result(String, Nil),
  fetch: FetchVersions,
) -> Result(#(ResolvedPackage, VersionInfo), ResolverError) {
  // 레지스트리에서 가져오기
  use versions <- result.try(fetch(dep.name, dep.registry))
  // exclude-newer 필터
  let versions = filter_by_cutoff(versions, exclude_newer)
  // 기존 lock에서 찾기
  case try_from_lock(dep, existing_lock) {
    Ok(pkg) -> {
      // lock hit — 해당 버전의 VersionInfo를 찾아 전이 의존성 반환
      let vi =
        list.find(versions, fn(v) { v.version == pkg.version })
        |> result.unwrap(VersionInfo(
          version: pkg.version,
          published_at: "",
          tarball_url: "",
          dependencies: [],
          peer_dependencies: [],
          optional_dependencies: [],
          os: [],
          cpu: [],
          has_scripts: False,
          signatures: [],
          integrity: "",
          deprecated: "",
          license: pkg.license,
        ))
      Ok(#(pkg, vi))
    }
    Error(_) -> {
      // 제약 조건 파싱
      use constraint <- result.try(parse_constraint(dep))
      // 만족하는 버전 필터 + 플랫폼 필터 + 최고 버전 선택
      let matching =
        list.filter(versions, fn(vi) {
          let version_ok = case semver.parse_version(vi.version) {
            Ok(v) -> semver.satisfies(v, constraint)
            Error(_) -> False
          }
          version_ok && matches_platform(vi, dep.registry)
        })
        |> list.sort(fn(a, b) {
          case
            semver.parse_version(a.version),
            semver.parse_version(b.version)
          {
            Ok(va), Ok(vb) -> semver.compare(vb, va)
            _, _ -> string.compare(b.version, a.version)
          }
        })
      case matching {
        [best, ..] ->
          Ok(#(
            ResolvedPackage(
              name: dep.name,
              version: best.version,
              registry: dep.registry,
              sha256: "",
              has_scripts: False,
              platform: Error(Nil),
              license: best.license,
            ),
            best,
          ))
        [] ->
          Error(
            IncompatibleVersions(package: dep.name, constraints: [
              dep.version_constraint,
            ]),
          )
      }
    }
  }
}

fn try_from_lock(
  dep: Dependency,
  existing_lock: Result(KirLock, Nil),
) -> Result(ResolvedPackage, Nil) {
  use lock <- result.try(existing_lock)
  use pkg <- result.try(
    list.find(lock.packages, fn(p) {
      p.name == dep.name && p.registry == dep.registry
    }),
  )
  use constraint <- result.try(
    parse_constraint(dep) |> result.replace_error(Nil),
  )
  use version <- result.try(
    semver.parse_version(pkg.version) |> result.replace_error(Nil),
  )
  case semver.satisfies(version, constraint) {
    True -> Ok(pkg)
    False -> Error(Nil)
  }
}

fn parse_constraint(dep: Dependency) -> Result(Constraint, ResolverError) {
  case dep.registry {
    Hex ->
      semver.parse_hex_constraint(dep.version_constraint)
      |> result.map_error(fn(e) {
        IncompatibleVersions(package: dep.name, constraints: [
          semver_error_to_string(e),
        ])
      })
    Npm ->
      semver.parse_npm_constraint(dep.version_constraint)
      |> result.map_error(fn(e) {
        IncompatibleVersions(package: dep.name, constraints: [
          semver_error_to_string(e),
        ])
      })
  }
}

fn semver_error_to_string(e: semver.SemverError) -> String {
  case e {
    semver.InvalidVersion(d) -> d
    semver.InvalidConstraint(d) -> d
  }
}

fn filter_by_cutoff(
  versions: List(VersionInfo),
  exclude_newer: Result(String, Nil),
) -> List(VersionInfo) {
  case exclude_newer {
    Error(_) -> versions
    Ok(cutoff) ->
      list.filter(versions, fn(vi) {
        case vi.published_at {
          "" -> True
          ts ->
            case security.is_before_cutoff(ts, cutoff) {
              Ok(True) -> True
              _ -> False
            }
        }
      })
  }
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

/// 의존성이 비어있으면 개별 release API에서 조회하여 VersionInfo 갱신
fn enrich_dependencies(
  vi: VersionInfo,
  name: String,
  version: String,
  registry: Registry,
  fetch_deps: FetchReleaseDeps,
) -> Result(VersionInfo, ResolverError) {
  case vi.dependencies {
    [] -> {
      use #(deps, deprecated) <- result.try(fetch_deps(name, version, registry))
      Ok(VersionInfo(..vi, dependencies: deps, deprecated: deprecated))
    }
    // 이미 의존성이 있으면 그대로 사용 (npm, 테스트 mock)
    _ -> Ok(vi)
  }
}

// ---------------------------------------------------------------------------
// peer dependency 검증 (post-resolution)
// ---------------------------------------------------------------------------

/// 해결 완료 후 모든 패키지의 peerDependencies가 만족되는지 검증
fn verify_peer_dependencies(
  resolved: Dict(String, ResolvedPackage),
  version_cache: Dict(String, VersionInfo),
) -> List(PeerWarning) {
  dict.to_list(version_cache)
  |> list.flat_map(fn(entry) {
    let #(key, vi) = entry
    // key에서 패키지명 추출 (name:registry 형식)
    let package_name = case string.split_once(key, ":") {
      Ok(#(name, _)) -> name
      Error(_) -> key
    }
    list.filter_map(vi.peer_dependencies, fn(peer) {
      let peer_key = peer.name <> ":" <> types.registry_to_string(peer.registry)
      case dict.get(resolved, peer_key) {
        Ok(installed) ->
          // peer 패키지가 설치됨 → 버전 제약 조건 검증
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
          // peer 패키지 미설치
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
// 플랫폼 필터링
// ---------------------------------------------------------------------------

fn matches_platform(vi: VersionInfo, registry: Registry) -> Bool {
  case registry {
    Hex -> True
    Npm ->
      check_platform_list(vi.os, platform.get_platform_os())
      && check_platform_list(vi.cpu, platform.get_platform_arch())
  }
}

/// 빈 목록이면 모든 플랫폼 허용. "!" prefix는 제외 목록.
fn check_platform_list(allowed: List(String), current: String) -> Bool {
  case allowed {
    [] -> True
    _ -> {
      let has_exclude = list.any(allowed, fn(s) { string.starts_with(s, "!") })
      case has_exclude {
        True ->
          // 제외 목록: "!win32"이면 win32만 제외
          !list.contains(allowed, "!" <> current)
        False ->
          // 포함 목록: 현재 플랫폼이 목록에 있어야 함
          list.contains(allowed, current)
      }
    }
  }
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
