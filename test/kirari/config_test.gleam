import gleam/list
import gleam/string
import gleeunit
import kirari/config
import kirari/types.{
  type KirConfig, Dependency, Hex, KirConfig, Npm, PackageInfo,
}

pub fn main() -> Nil {
  gleeunit.main()
}

fn sample_config() -> KirConfig {
  KirConfig(
    package: PackageInfo(
      name: "my_app",
      version: "1.0.0",
      description: "A test application",
      target: "erlang",
      licences: ["MIT"],
      repository: Ok("github:user/repo"),
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
    hex_dev_deps: [
      Dependency(
        name: "gleeunit",
        version_constraint: ">= 1.0.0 and < 2.0.0",
        registry: Hex,
        dev: True,
        optional: False,
      ),
    ],
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
    security: types.SecurityConfig(
      ..types.default_security_config(),
      exclude_newer: Ok("2026-04-01T00:00:00Z"),
    ),
    path_deps: [],
    path_dev_deps: [],
    overrides: [],
    engines: types.default_engines_config(),
  )
}

pub fn encode_config_test() {
  let encoded = config.encode_config(sample_config())
  assert string.contains(encoded, "name = \"my_app\"")
  assert string.contains(encoded, "[dependencies]")
  assert string.contains(encoded, "[dev-dependencies]")
  assert string.contains(encoded, "[npm-dependencies]")
  assert string.contains(encoded, "[security]")
  // gleam.toml 포맷: [package] 섹션 없음
  assert !string.contains(encoded, "[package]")
}

pub fn config_roundtrip_test() {
  let original = sample_config()
  let encoded = config.encode_config(original)
  let assert Ok(parsed) = config.parse_config(encoded)
  assert parsed.package.name == original.package.name
  assert parsed.package.version == original.package.version
  assert parsed.package.description == original.package.description
  assert list.length(parsed.hex_deps) == list.length(original.hex_deps)
  assert list.length(parsed.hex_dev_deps) == list.length(original.hex_dev_deps)
  assert list.length(parsed.npm_deps) == list.length(original.npm_deps)
  let assert Ok(exclude) = parsed.security.exclude_newer
  assert exclude == "2026-04-01T00:00:00Z"
}

// ---------------------------------------------------------------------------
// 파싱 에러
// ---------------------------------------------------------------------------

pub fn parse_config_missing_name_test() {
  let toml = "version = \"1.0.0\"\n[dependencies]\n"
  let assert Error(config.InvalidField("name", _)) = config.parse_config(toml)
}

pub fn parse_config_invalid_toml_test() {
  let assert Error(config.ParseError(_)) =
    config.parse_config("[[[ invalid toml")
}

// ---------------------------------------------------------------------------
// 최소 설정
// ---------------------------------------------------------------------------

pub fn parse_config_minimal_test() {
  let toml = "name = \"minimal\"\nversion = \"0.1.0\"\n"
  let assert Ok(cfg) = config.parse_config(toml)
  assert cfg.package.name == "minimal"
  assert cfg.hex_deps == []
  assert cfg.npm_deps == []
  let assert Error(Nil) = cfg.security.exclude_newer
}

// ---------------------------------------------------------------------------
// 의존성 추가/제거
// ---------------------------------------------------------------------------

pub fn add_dependency_test() {
  let cfg =
    KirConfig(
      package: PackageInfo(
        name: "t",
        version: "0.1.0",
        description: "",
        target: "erlang",
        licences: [],
        repository: Error(Nil),
      ),
      hex_deps: [],
      hex_dev_deps: [],
      npm_deps: [],
      npm_dev_deps: [],
      security: types.default_security_config(),
      path_deps: [],
      path_dev_deps: [],
      overrides: [],
      engines: types.default_engines_config(),
    )
  let dep =
    Dependency(
      name: "gleam_json",
      version_constraint: ">= 3.0.0",
      registry: Hex,
      dev: False,
      optional: False,
    )
  let updated = config.add_dependency(cfg, dep)
  assert list.length(updated.hex_deps) == 1
  let assert Ok(first) = list.first(updated.hex_deps)
  assert first.name == "gleam_json"
}

pub fn add_dependency_upsert_test() {
  let dep_v1 =
    Dependency(
      name: "foo",
      version_constraint: "1.0.0",
      registry: Hex,
      dev: False,
      optional: False,
    )
  let dep_v2 =
    Dependency(
      name: "foo",
      version_constraint: "2.0.0",
      registry: Hex,
      dev: False,
      optional: False,
    )
  let cfg =
    KirConfig(
      package: PackageInfo(
        name: "t",
        version: "0.1.0",
        description: "",
        target: "erlang",
        licences: [],
        repository: Error(Nil),
      ),
      hex_deps: [dep_v1],
      hex_dev_deps: [],
      npm_deps: [],
      npm_dev_deps: [],
      security: types.default_security_config(),
      path_deps: [],
      path_dev_deps: [],
      overrides: [],
      engines: types.default_engines_config(),
    )
  let updated = config.add_dependency(cfg, dep_v2)
  assert list.length(updated.hex_deps) == 1
  let assert Ok(first) = list.first(updated.hex_deps)
  assert first.version_constraint == "2.0.0"
}

pub fn remove_dependency_test() {
  let dep =
    Dependency(
      name: "foo",
      version_constraint: "1.0.0",
      registry: Npm,
      dev: False,
      optional: False,
    )
  let cfg =
    KirConfig(
      package: PackageInfo(
        name: "t",
        version: "0.1.0",
        description: "",
        target: "erlang",
        licences: [],
        repository: Error(Nil),
      ),
      hex_deps: [],
      hex_dev_deps: [],
      npm_deps: [dep],
      npm_dev_deps: [],
      security: types.default_security_config(),
      path_deps: [],
      path_dev_deps: [],
      overrides: [],
      engines: types.default_engines_config(),
    )
  let updated = config.remove_dependency(cfg, "foo", Npm)
  assert updated.npm_deps == []
}
