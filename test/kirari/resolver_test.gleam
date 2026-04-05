import gleam/list
import gleeunit
import kirari/resolver.{type ResolverError, type VersionInfo, VersionInfo}
import kirari/types.{
  type KirConfig, type Registry, Dependency, Hex, KirConfig, KirLock, Npm,
  PackageInfo, ResolvedPackage,
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
          peer_dependencies: [],
          optional_dependencies: [],
          os: [],
          cpu: [],
          has_scripts: False,
          signatures: [],
          integrity: "",
          deprecated: "",
          license: "",
        ),
        VersionInfo(
          tarball_url: "",
          version: "0.45.0",
          published_at: "2024-06-01T00:00:00Z",
          dependencies: [],
          peer_dependencies: [],
          optional_dependencies: [],
          os: [],
          cpu: [],
          has_scripts: False,
          signatures: [],
          integrity: "",
          deprecated: "",
          license: "",
        ),
        VersionInfo(
          tarball_url: "",
          version: "1.0.0",
          published_at: "2025-01-01T00:00:00Z",
          dependencies: [],
          peer_dependencies: [],
          optional_dependencies: [],
          os: [],
          cpu: [],
          has_scripts: False,
          signatures: [],
          integrity: "",
          deprecated: "",
          license: "",
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
              optional: False,
              package_name: Error(Nil),
            ),
          ],
          peer_dependencies: [],
          optional_dependencies: [],
          os: [],
          cpu: [],
          has_scripts: False,
          signatures: [],
          integrity: "",
          deprecated: "",
          license: "",
        ),
      ])
    "highlight.js", Npm ->
      Ok([
        VersionInfo(
          tarball_url: "",
          version: "11.0.0",
          published_at: "2024-01-01T00:00:00Z",
          dependencies: [],
          peer_dependencies: [],
          optional_dependencies: [],
          os: [],
          cpu: [],
          has_scripts: False,
          signatures: [],
          integrity: "",
          deprecated: "",
          license: "",
        ),
        VersionInfo(
          tarball_url: "",
          version: "11.9.0",
          published_at: "2024-06-01T00:00:00Z",
          dependencies: [],
          peer_dependencies: [],
          optional_dependencies: [],
          os: [],
          cpu: [],
          has_scripts: False,
          signatures: [],
          integrity: "",
          deprecated: "",
          license: "",
        ),
        VersionInfo(
          tarball_url: "",
          version: "12.0.0",
          published_at: "2025-01-01T00:00:00Z",
          dependencies: [],
          peer_dependencies: [],
          optional_dependencies: [],
          os: [],
          cpu: [],
          has_scripts: False,
          signatures: [],
          integrity: "",
          deprecated: "",
          license: "",
        ),
      ])
    // 다이아몬드 충돌 테스트용
    "pkg_a", Hex ->
      Ok([
        VersionInfo(
          tarball_url: "",
          version: "1.0.0",
          published_at: "2024-01-01T00:00:00Z",
          dependencies: [
            Dependency(
              name: "pkg_shared",
              version_constraint: ">= 1.0.0 and < 2.0.0",
              registry: Hex,
              dev: False,
              optional: False,
              package_name: Error(Nil),
            ),
          ],
          peer_dependencies: [],
          optional_dependencies: [],
          os: [],
          cpu: [],
          has_scripts: False,
          signatures: [],
          integrity: "",
          deprecated: "",
          license: "",
        ),
      ])
    "pkg_b", Hex ->
      Ok([
        VersionInfo(
          tarball_url: "",
          version: "1.0.0",
          published_at: "2024-01-01T00:00:00Z",
          dependencies: [
            Dependency(
              name: "pkg_shared",
              version_constraint: ">= 2.0.0",
              registry: Hex,
              dev: False,
              optional: False,
              package_name: Error(Nil),
            ),
          ],
          peer_dependencies: [],
          optional_dependencies: [],
          os: [],
          cpu: [],
          has_scripts: False,
          signatures: [],
          integrity: "",
          deprecated: "",
          license: "",
        ),
      ])
    "pkg_shared", Hex ->
      Ok([
        VersionInfo(
          tarball_url: "",
          version: "1.0.0",
          published_at: "2024-01-01T00:00:00Z",
          dependencies: [],
          peer_dependencies: [],
          optional_dependencies: [],
          os: [],
          cpu: [],
          has_scripts: False,
          signatures: [],
          integrity: "",
          deprecated: "",
          license: "",
        ),
        VersionInfo(
          tarball_url: "",
          version: "2.0.0",
          published_at: "2024-06-01T00:00:00Z",
          dependencies: [],
          peer_dependencies: [],
          optional_dependencies: [],
          os: [],
          cpu: [],
          has_scripts: False,
          signatures: [],
          integrity: "",
          deprecated: "",
          license: "",
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
    security: types.default_security_config(),
    path_deps: [],
    path_dev_deps: [],
    overrides: [],
    engines: types.default_engines_config(),
    download: types.default_download_config(),
    git_deps: [],
    git_dev_deps: [],
    url_deps: [],
    url_dev_deps: [],
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
        optional: False,
        package_name: Error(Nil),
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
        optional: False,
        package_name: Error(Nil),
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
        optional: False,
        package_name: Error(Nil),
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
        optional: False,
        package_name: Error(Nil),
      ),
    ])
  let assert Error(resolver.ResolutionConflict(_, _)) =
    resolver.resolve_with(config, Error(Nil), mock_fetch)
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
        optional: False,
        package_name: Error(Nil),
      ),
    ])
  let lock =
    KirLock(version: 1, config_fingerprint: Error(Nil), packages: [
      ResolvedPackage(
        name: "gleam_stdlib",
        version: "0.44.0",
        registry: Hex,
        sha256: "abc",
        has_scripts: False,
        platform: Error(Nil),
        license: "",
        dev: False,
        package_name: Error(Nil),
        git_source: Error(Nil),
        url_source: Error(Nil),
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
          optional: False,
          package_name: Error(Nil),
        ),
      ]),
      security: types.SecurityConfig(
        ..types.default_security_config(),
        exclude_newer: Ok("2024-08-01T00:00:00Z"),
      ),
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
        optional: False,
        package_name: Error(Nil),
      ),
      Dependency(
        name: "highlight.js",
        version_constraint: "^11.0.0",
        registry: Npm,
        dev: False,
        optional: False,
        package_name: Error(Nil),
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
        optional: False,
        package_name: Error(Nil),
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

// ---------------------------------------------------------------------------
// 다이아몬드 충돌 감지
// ---------------------------------------------------------------------------

pub fn resolve_diamond_conflict_test() {
  // pkg_a → pkg_shared >= 1.0.0 and < 2.0.0
  // pkg_b → pkg_shared >= 2.0.0
  // greedy: pkg_a 먼저 해결 → pkg_shared@1.0.0
  //         pkg_b 해결 → pkg_shared >= 2.0.0 but already @1.0.0 → 충돌!
  let config =
    test_config([
      Dependency(
        name: "pkg_a",
        version_constraint: ">= 1.0.0",
        registry: Hex,
        dev: False,
        optional: False,
        package_name: Error(Nil),
      ),
      Dependency(
        name: "pkg_b",
        version_constraint: ">= 1.0.0",
        registry: Hex,
        dev: False,
        optional: False,
        package_name: Error(Nil),
      ),
    ])
  let assert Error(resolver.ResolutionConflict(explanation, report)) =
    resolver.resolve_with(config, Error(Nil), mock_fetch)
  // 충돌 설명에 pkg_shared와 의존성 정보 포함
  assert string.contains(explanation, "pkg_shared")
  assert string.contains(explanation, "pkg_b")
    || string.contains(explanation, "pkg_a")
  // 구조화된 리포트가 존재해야 함
  let assert Ok(r) = report
  assert list.length(r.causes) >= 1
}

pub fn resolve_diamond_compatible_test() {
  // 직접 의존: gleam_stdlib >= 0.44.0 and < 2.0.0
  // gleam_json → gleam_stdlib >= 0.44.0 and < 2.0.0 (호환)
  let config =
    test_config([
      Dependency(
        name: "gleam_stdlib",
        version_constraint: ">= 0.44.0 and < 2.0.0",
        registry: Hex,
        dev: False,
        optional: False,
        package_name: Error(Nil),
      ),
      Dependency(
        name: "gleam_json",
        version_constraint: ">= 3.0.0",
        registry: Hex,
        dev: False,
        optional: False,
        package_name: Error(Nil),
      ),
    ])
  let assert Ok(resolved) =
    resolver.resolve_with(config, Error(Nil), mock_fetch)
  // 호환 가능 → 정상 해결
  assert list.length(resolved) == 2
}

import gleam/string

// ---------------------------------------------------------------------------
// dev 전이 의존성 분류
// ---------------------------------------------------------------------------

/// mock_fetch_deps는 no-op (Hex release deps 불필요 — mock_fetch에서 이미 제공)
fn mock_fetch_deps(
  _name: String,
  _version: String,
  _registry: Registry,
) -> Result(#(List(types.Dependency), String), ResolverError) {
  Ok(#([], ""))
}

pub fn classify_dev_pure_prod_test() {
  // 모든 의존성이 prod → 전부 dev: False
  let config =
    test_config([
      Dependency(
        name: "gleam_stdlib",
        version_constraint: ">= 0.44.0 and < 2.0.0",
        registry: Hex,
        dev: False,
        optional: False,
        package_name: Error(Nil),
      ),
    ])
  let assert Ok(result) =
    resolver.resolve_full_with_deps(
      config,
      Error(Nil),
      mock_fetch,
      mock_fetch_deps,
    )
  list.each(result.packages, fn(p) {
    assert p.dev == False
  })
}

pub fn classify_dev_pure_dev_test() {
  // 모든 의존성이 dev → 전부 dev: True
  let config =
    test_config([
      Dependency(
        name: "gleam_stdlib",
        version_constraint: ">= 0.44.0 and < 2.0.0",
        registry: Hex,
        dev: True,
        optional: False,
        package_name: Error(Nil),
      ),
    ])
  let assert Ok(result) =
    resolver.resolve_full_with_deps(
      config,
      Error(Nil),
      mock_fetch,
      mock_fetch_deps,
    )
  list.each(result.packages, fn(p) {
    assert p.dev == True
  })
}

pub fn classify_dev_shared_transitive_test() {
  // prod: gleam_json → gleam_stdlib (전이)
  // dev: gleam_stdlib (직접 dev)
  // gleam_stdlib은 prod에서 도달 가능 → dev: False
  let config =
    KirConfig(
      ..test_config([]),
      hex_deps: [
        Dependency(
          name: "gleam_json",
          version_constraint: ">= 3.0.0",
          registry: Hex,
          dev: False,
          optional: False,
          package_name: Error(Nil),
        ),
      ],
      hex_dev_deps: [
        Dependency(
          name: "gleam_stdlib",
          version_constraint: ">= 0.44.0",
          registry: Hex,
          dev: True,
          optional: False,
          package_name: Error(Nil),
        ),
      ],
    )
  let assert Ok(result) =
    resolver.resolve_full_with_deps(
      config,
      Error(Nil),
      mock_fetch,
      mock_fetch_deps,
    )
  let assert Ok(stdlib) =
    list.find(result.packages, fn(p) { p.name == "gleam_stdlib" })
  // prod에서 ��이 의존성으로 도달 가능 → dev: False
  assert stdlib.dev == False
  let assert Ok(json_pkg) =
    list.find(result.packages, fn(p) { p.name == "gleam_json" })
  assert json_pkg.dev == False
}

pub fn classify_dev_only_chain_test() {
  // dev: highlight.js (직접 dev, npm)
  // prod: gleam_stdlib (직접 prod, hex)
  // highlight.js는 prod에서 도달 불가 → dev: True
  let config =
    KirConfig(
      ..test_config([]),
      hex_deps: [
        Dependency(
          name: "gleam_stdlib",
          version_constraint: ">= 0.44.0",
          registry: Hex,
          dev: False,
          optional: False,
          package_name: Error(Nil),
        ),
      ],
      npm_dev_deps: [
        Dependency(
          name: "highlight.js",
          version_constraint: "^11.0.0",
          registry: Npm,
          dev: True,
          optional: False,
          package_name: Error(Nil),
        ),
      ],
    )
  let assert Ok(result) =
    resolver.resolve_full_with_deps(
      config,
      Error(Nil),
      mock_fetch,
      mock_fetch_deps,
    )
  let assert Ok(stdlib) =
    list.find(result.packages, fn(p) { p.name == "gleam_stdlib" })
  assert stdlib.dev == False
  let assert Ok(hljs) =
    list.find(result.packages, fn(p) { p.name == "highlight.js" })
  assert hljs.dev == True
}
