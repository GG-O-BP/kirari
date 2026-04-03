import gleam/list
import gleeunit
import kirari/resolver.{type ResolverError, type VersionInfo, VersionInfo}
import kirari/types.{
  type KirConfig, type Registry, Dependency, Hex, KirConfig, KirLock, Npm,
  PackageInfo, ResolvedPackage, SecurityConfig,
}

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// 모의 레지스트리
// ---------------------------------------------------------------------------

fn mock_fetch(
  name: String,
  registry: Registry,
) -> Result(List(VersionInfo), ResolverError) {
  case name, registry {
    "gleam_stdlib", Hex ->
      Ok([
        VersionInfo(
          tarball_url: "",
          version: "0.44.0",
          published_at: "2024-01-01T00:00:00Z",
          dependencies: [],
        ),
        VersionInfo(
          tarball_url: "",
          version: "0.45.0",
          published_at: "2024-06-01T00:00:00Z",
          dependencies: [],
        ),
        VersionInfo(
          tarball_url: "",
          version: "1.0.0",
          published_at: "2025-01-01T00:00:00Z",
          dependencies: [],
        ),
      ])
    "gleam_json", Hex ->
      Ok([
        VersionInfo(
          tarball_url: "",
          version: "3.0.0",
          published_at: "2024-03-01T00:00:00Z",
          dependencies: [
            Dependency(
              name: "gleam_stdlib",
              version_constraint: ">= 0.44.0 and < 2.0.0",
              registry: Hex,
              dev: False,
            ),
          ],
        ),
      ])
    "highlight.js", Npm ->
      Ok([
        VersionInfo(
          tarball_url: "",
          version: "11.0.0",
          published_at: "2024-01-01T00:00:00Z",
          dependencies: [],
        ),
        VersionInfo(
          tarball_url: "",
          version: "11.9.0",
          published_at: "2024-06-01T00:00:00Z",
          dependencies: [],
        ),
        VersionInfo(
          tarball_url: "",
          version: "12.0.0",
          published_at: "2025-01-01T00:00:00Z",
          dependencies: [],
        ),
      ])
    _, _ -> Error(resolver.PackageNotFound(name, registry))
  }
}

fn test_config(deps: List(types.Dependency)) -> KirConfig {
  KirConfig(
    package: PackageInfo(
      name: "test",
      version: "0.1.0",
      description: "",
      target: "erlang",
      licences: [],
      repository: Error(Nil),
    ),
    hex_deps: list.filter(deps, fn(d) { d.registry == Hex && !d.dev }),
    hex_dev_deps: list.filter(deps, fn(d) { d.registry == Hex && d.dev }),
    npm_deps: list.filter(deps, fn(d) { d.registry == Npm && !d.dev }),
    npm_dev_deps: list.filter(deps, fn(d) { d.registry == Npm && d.dev }),
    security: SecurityConfig(exclude_newer: Error(Nil)),
  )
}

// ---------------------------------------------------------------------------
// 기본 해결
// ---------------------------------------------------------------------------

pub fn resolve_simple_hex_test() {
  let config =
    test_config([
      Dependency(
        name: "gleam_stdlib",
        version_constraint: ">= 0.44.0 and < 2.0.0",
        registry: Hex,
        dev: False,
      ),
    ])
  let assert Ok(resolved) =
    resolver.resolve_with(config, Error(Nil), mock_fetch)
  assert list.length(resolved) == 1
  let assert [pkg] = resolved
  assert pkg.name == "gleam_stdlib"
  // 최고 버전 선택
  assert pkg.version == "1.0.0"
}

pub fn resolve_simple_npm_test() {
  let config =
    test_config([
      Dependency(
        name: "highlight.js",
        version_constraint: "^11.0.0",
        registry: Npm,
        dev: False,
      ),
    ])
  let assert Ok(resolved) =
    resolver.resolve_with(config, Error(Nil), mock_fetch)
  let assert [pkg] = resolved
  assert pkg.name == "highlight.js"
  // ^11.0.0 → < 12.0.0 이므로 11.9.0 선택
  assert pkg.version == "11.9.0"
}

// ---------------------------------------------------------------------------
// 패키지 미발견
// ---------------------------------------------------------------------------

pub fn resolve_not_found_test() {
  let config =
    test_config([
      Dependency(
        name: "nonexistent",
        version_constraint: "^1.0.0",
        registry: Hex,
        dev: False,
      ),
    ])
  let assert Error(resolver.PackageNotFound("nonexistent", Hex)) =
    resolver.resolve_with(config, Error(Nil), mock_fetch)
}

// ---------------------------------------------------------------------------
// 제약 불일치
// ---------------------------------------------------------------------------

pub fn resolve_incompatible_test() {
  let config =
    test_config([
      Dependency(
        name: "gleam_stdlib",
        version_constraint: ">= 99.0.0",
        registry: Hex,
        dev: False,
      ),
    ])
  let assert Error(resolver.IncompatibleVersions(
    package: "gleam_stdlib",
    constraints: _,
  )) = resolver.resolve_with(config, Error(Nil), mock_fetch)
}

// ---------------------------------------------------------------------------
// Lock 우선
// ---------------------------------------------------------------------------

pub fn resolve_prefers_lock_test() {
  let config =
    test_config([
      Dependency(
        name: "gleam_stdlib",
        version_constraint: ">= 0.44.0 and < 2.0.0",
        registry: Hex,
        dev: False,
      ),
    ])
  let lock =
    KirLock(version: 1, packages: [
      ResolvedPackage(
        name: "gleam_stdlib",
        version: "0.44.0",
        registry: Hex,
        sha256: "abc",
      ),
    ])
  let assert Ok(resolved) = resolver.resolve_with(config, Ok(lock), mock_fetch)
  let assert [pkg] = resolved
  // lock에 있는 0.44.0을 우선
  assert pkg.version == "0.44.0"
}

// ---------------------------------------------------------------------------
// exclude-newer
// ---------------------------------------------------------------------------

pub fn resolve_exclude_newer_test() {
  let config =
    KirConfig(
      ..test_config([
        Dependency(
          name: "gleam_stdlib",
          version_constraint: ">= 0.44.0 and < 2.0.0",
          registry: Hex,
          dev: False,
        ),
      ]),
      security: SecurityConfig(exclude_newer: Ok("2024-08-01T00:00:00Z")),
    )
  let assert Ok(resolved) =
    resolver.resolve_with(config, Error(Nil), mock_fetch)
  let assert [pkg] = resolved
  // 2024-08-01 이전: 0.44.0 (2024-01), 0.45.0 (2024-06) 만 후보
  assert pkg.version == "0.45.0"
}

// ---------------------------------------------------------------------------
// 혼합 레지스트리
// ---------------------------------------------------------------------------

pub fn resolve_mixed_registries_test() {
  let config =
    test_config([
      Dependency(
        name: "gleam_stdlib",
        version_constraint: ">= 0.44.0 and < 2.0.0",
        registry: Hex,
        dev: False,
      ),
      Dependency(
        name: "highlight.js",
        version_constraint: "^11.0.0",
        registry: Npm,
        dev: False,
      ),
    ])
  let assert Ok(resolved) =
    resolver.resolve_with(config, Error(Nil), mock_fetch)
  assert list.length(resolved) == 2
}

// ---------------------------------------------------------------------------
// 전이 의존성
// ---------------------------------------------------------------------------

pub fn resolve_transitive_deps_test() {
  // gleam_json만 직접 의존 — gleam_json은 gleam_stdlib에 의존
  let config =
    test_config([
      Dependency(
        name: "gleam_json",
        version_constraint: ">= 3.0.0",
        registry: Hex,
        dev: False,
      ),
    ])
  let assert Ok(resolved) =
    resolver.resolve_with(config, Error(Nil), mock_fetch)
  // gleam_json + gleam_stdlib (전이) = 2개
  assert list.length(resolved) == 2
  let assert Ok(_) = list.find(resolved, fn(p) { p.name == "gleam_json" })
  let assert Ok(stdlib) =
    list.find(resolved, fn(p) { p.name == "gleam_stdlib" })
  // 전이 의존성은 최고 버전 선택
  assert stdlib.version == "1.0.0"
}
