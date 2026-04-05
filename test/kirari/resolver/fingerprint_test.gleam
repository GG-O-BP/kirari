import gleam/string
import gleeunit
import kirari/resolver/fingerprint
import kirari/types.{
  type KirConfig, Dependency, Hex, KirConfig, Npm, Override, PackageInfo,
  SecurityConfig,
}

pub fn main() -> Nil {
  gleeunit.main()
}

fn base_config() -> KirConfig {
  KirConfig(
    package: PackageInfo(
      name: "test",
      version: "0.1.0",
      description: "",
      target: "erlang",
      licences: [],
      repository: Error(Nil),
    ),
    hex_deps: [
      Dependency(
        name: "gleam_stdlib",
        version_constraint: ">= 0.44.0 and < 2.0.0",
        registry: Hex,
        dev: False,
        optional: False,
      ),
    ],
    hex_dev_deps: [],
    npm_deps: [
      Dependency(
        name: "highlight.js",
        version_constraint: "^11.0.0",
        registry: Npm,
        dev: False,
        optional: False,
      ),
    ],
    npm_dev_deps: [],
    security: types.default_security_config(),
    path_deps: [],
    path_dev_deps: [],
    overrides: [],
    engines: types.default_engines_config(),
  )
}

// ---------------------------------------------------------------------------
// 결정론성
// ---------------------------------------------------------------------------

pub fn deterministic_same_hash_test() {
  let config = base_config()
  let hash1 = fingerprint.compute(config)
  let hash2 = fingerprint.compute(config)
  assert hash1 == hash2
}

pub fn hash_is_64_hex_chars_test() {
  let hash = fingerprint.compute(base_config())
  // SHA256 hex = 64 chars
  assert string.length(hash) == 64
}

// ---------------------------------------------------------------------------
// dep 추가 → 해시 변경
// ---------------------------------------------------------------------------

pub fn adding_dep_changes_hash_test() {
  let config1 = base_config()
  let config2 =
    KirConfig(..config1, hex_deps: [
      Dependency(
        name: "gleam_stdlib",
        version_constraint: ">= 0.44.0 and < 2.0.0",
        registry: Hex,
        dev: False,
        optional: False,
      ),
      Dependency(
        name: "gleam_json",
        version_constraint: ">= 3.0.0",
        registry: Hex,
        dev: False,
        optional: False,
      ),
    ])
  assert fingerprint.compute(config1) != fingerprint.compute(config2)
}

// ---------------------------------------------------------------------------
// dep 제거 → 해시 변경
// ---------------------------------------------------------------------------

pub fn removing_dep_changes_hash_test() {
  let config1 = base_config()
  let config2 = KirConfig(..config1, hex_deps: [])
  assert fingerprint.compute(config1) != fingerprint.compute(config2)
}

// ---------------------------------------------------------------------------
// 제약 변경 → 해시 변경
// ---------------------------------------------------------------------------

pub fn changing_constraint_changes_hash_test() {
  let config1 = base_config()
  let config2 =
    KirConfig(..config1, hex_deps: [
      Dependency(
        name: "gleam_stdlib",
        version_constraint: ">= 1.0.0",
        registry: Hex,
        dev: False,
        optional: False,
      ),
    ])
  assert fingerprint.compute(config1) != fingerprint.compute(config2)
}

// ---------------------------------------------------------------------------
// override 변경 → 해시 변경
// ---------------------------------------------------------------------------

pub fn adding_override_changes_hash_test() {
  let config1 = base_config()
  let config2 =
    KirConfig(..config1, overrides: [
      Override(
        name: "gleam_stdlib",
        version_constraint: ">= 1.0.0",
        registry: Hex,
      ),
    ])
  assert fingerprint.compute(config1) != fingerprint.compute(config2)
}

// ---------------------------------------------------------------------------
// exclude_newer 변경 → 해시 변경
// ---------------------------------------------------------------------------

pub fn changing_exclude_newer_changes_hash_test() {
  let config1 = base_config()
  let config2 =
    KirConfig(
      ..config1,
      security: SecurityConfig(
        ..config1.security,
        exclude_newer: Ok("2024-01-01T00:00:00Z"),
      ),
    )
  assert fingerprint.compute(config1) != fingerprint.compute(config2)
}

// ---------------------------------------------------------------------------
// dep 순서 무관 (정렬)
// ---------------------------------------------------------------------------

pub fn dep_order_does_not_matter_test() {
  let dep_a =
    Dependency(
      name: "alpha",
      version_constraint: ">= 1.0.0",
      registry: Hex,
      dev: False,
      optional: False,
    )
  let dep_b =
    Dependency(
      name: "beta",
      version_constraint: ">= 2.0.0",
      registry: Hex,
      dev: False,
      optional: False,
    )
  let config1 = KirConfig(..base_config(), hex_deps: [dep_a, dep_b])
  let config2 = KirConfig(..base_config(), hex_deps: [dep_b, dep_a])
  assert fingerprint.compute(config1) == fingerprint.compute(config2)
}

// ---------------------------------------------------------------------------
// dev vs prod 구분
// ---------------------------------------------------------------------------

pub fn dev_vs_prod_different_hash_test() {
  let dep =
    Dependency(
      name: "gleam_stdlib",
      version_constraint: ">= 1.0.0",
      registry: Hex,
      dev: False,
      optional: False,
    )
  let config1 = KirConfig(..base_config(), hex_deps: [dep], hex_dev_deps: [])
  let config2 = KirConfig(..base_config(), hex_deps: [], hex_dev_deps: [dep])
  assert fingerprint.compute(config1) != fingerprint.compute(config2)
}

// ---------------------------------------------------------------------------
// matches 함수
// ---------------------------------------------------------------------------

pub fn matches_returns_true_for_same_config_test() {
  let config = base_config()
  let hash = fingerprint.compute(config)
  assert fingerprint.matches(hash, config) == True
}

pub fn matches_returns_false_for_different_config_test() {
  let config1 = base_config()
  let hash = fingerprint.compute(config1)
  let config2 = KirConfig(..config1, hex_deps: [])
  assert fingerprint.matches(hash, config2) == False
}

// ---------------------------------------------------------------------------
// pipeline 시점 설정은 해시에 영향 없음
// ---------------------------------------------------------------------------

pub fn script_policy_does_not_affect_hash_test() {
  let config1 = base_config()
  let config2 =
    KirConfig(
      ..config1,
      security: SecurityConfig(..config1.security, npm_scripts: types.AllowAll),
    )
  assert fingerprint.compute(config1) == fingerprint.compute(config2)
}

pub fn provenance_policy_does_not_affect_hash_test() {
  let config1 = base_config()
  let config2 =
    KirConfig(
      ..config1,
      security: SecurityConfig(
        ..config1.security,
        provenance: types.ProvenanceRequire,
      ),
    )
  assert fingerprint.compute(config1) == fingerprint.compute(config2)
}

pub fn license_policy_does_not_affect_hash_test() {
  let config1 = base_config()
  let config2 =
    KirConfig(
      ..config1,
      security: SecurityConfig(
        ..config1.security,
        license_policy: types.LicenseDeny(["GPL-3.0"]),
      ),
    )
  assert fingerprint.compute(config1) == fingerprint.compute(config2)
}
