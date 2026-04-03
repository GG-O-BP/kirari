//// 의존성 해결 — Greedy 알고리즘, DI 기반 레지스트리 주입

import gleam/dict.{type Dict}
import gleam/list
import gleam/result
import gleam/string
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
  )
}

/// 해결 결과 — 패키지 목록 + 버전 정보 캐시 (파이프라인에서 tarball_url 조회용)
pub type ResolveResult {
  ResolveResult(
    packages: List(ResolvedPackage),
    version_infos: Dict(String, VersionInfo),
  )
}

/// 레지스트리 조회 함수 타입
pub type FetchVersions =
  fn(String, Registry) -> Result(List(VersionInfo), ResolverError)

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
  use result <- result.try(resolve_full_with(config, existing_lock, fetch))
  Ok(result.packages)
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
    existing_lock,
    exclude_newer,
    fetch,
    [],
  )
}

// ---------------------------------------------------------------------------
// Greedy 해결 루프
// ---------------------------------------------------------------------------

fn do_resolve(
  queue: List(Dependency),
  resolved: Dict(String, ResolvedPackage),
  version_cache: Dict(String, VersionInfo),
  existing_lock: Result(KirLock, Nil),
  exclude_newer: Result(String, Nil),
  fetch: FetchVersions,
  visited: List(String),
) -> Result(ResolveResult, ResolverError) {
  case queue {
    [] ->
      Ok(ResolveResult(
        packages: dict.values(resolved)
          |> list.sort(types.compare_packages),
        version_infos: version_cache,
      ))
    [dep, ..rest] -> {
      let key = dep.name <> ":" <> types.registry_to_string(dep.registry)
      case dict.has_key(resolved, key) {
        True ->
          do_resolve(
            rest,
            resolved,
            version_cache,
            existing_lock,
            exclude_newer,
            fetch,
            visited,
          )
        False -> {
          case list.contains(visited, key) {
            True -> Error(CyclicDependency([key, ..visited]))
            False -> {
              use #(pkg, vi) <- result.try(resolve_one(
                dep,
                existing_lock,
                exclude_newer,
                fetch,
              ))
              let new_resolved = dict.insert(resolved, key, pkg)
              let new_cache = dict.insert(version_cache, key, vi)
              let transitive = vi.dependencies
              do_resolve(
                list.append(rest, transitive),
                new_resolved,
                new_cache,
                existing_lock,
                exclude_newer,
                fetch,
                [key, ..visited],
              )
            }
          }
        }
      }
    }
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
        |> result.unwrap(
          VersionInfo(
            version: pkg.version,
            published_at: "",
            tarball_url: "",
            dependencies: [],
          ),
        )
      Ok(#(pkg, vi))
    }
    Error(_) -> {
      // 제약 조건 파싱
      use constraint <- result.try(parse_constraint(dep))
      // 만족하는 버전 필터 + 최고 버전 선택
      let matching =
        list.filter(versions, fn(vi) {
          case semver.parse_version(vi.version) {
            Ok(v) -> semver.satisfies(v, constraint)
            Error(_) -> False
          }
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
        IncompatibleVersions(package: dep.name, constraints: [e])
      })
    Npm ->
      semver.parse_npm_constraint(dep.version_constraint)
      |> result.map_error(fn(e) {
        IncompatibleVersions(package: dep.name, constraints: [e])
      })
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
        dependencies: list.filter_map(v.dependencies, fn(d) {
          case d.optional {
            True -> Error(Nil)
            False ->
              Ok(types.Dependency(
                name: d.name,
                version_constraint: d.requirement,
                registry: Hex,
                dev: False,
              ))
          }
        }),
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
          )
        }),
      )
    }),
  )
}
