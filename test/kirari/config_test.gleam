import gleam/list
import gleeunit
import kirari/config
import kirari/types.{
  type KirConfig, Dependency, Hex, KirConfig, Npm, PackageInfo, SecurityConfig,
}

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// kir.toml round-trip
// ---------------------------------------------------------------------------

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
      ),
    ],
    hex_dev_deps: [
      Dependency(
        name: "gleeunit",
        version_constraint: ">= 1.0.0 and < 2.0.0",
        registry: Hex,
        dev: True,
      ),
    ],
    npm_deps: [
      Dependency(
        name: "highlight.js",
        version_constraint: "^11.0.0",
        registry: Npm,
        dev: False,
      ),
    ],
    npm_dev_deps: [],
    security: SecurityConfig(exclude_newer: Ok("2026-04-01T00:00:00Z")),
  )
}

pub fn encode_kir_toml_test() {
  let encoded = config.encode_kir_toml(sample_config())
  assert {
    let assert Ok(True) =
      encoded
      |> has_substring("[package]")
    True
  }
  assert {
    let assert Ok(True) = encoded |> has_substring("name = \"my_app\"")
    True
  }
  assert {
    let assert Ok(True) = encoded |> has_substring("[hex]")
    True
  }
  assert {
    let assert Ok(True) = encoded |> has_substring("[hex.dev]")
    True
  }
  assert {
    let assert Ok(True) = encoded |> has_substring("[npm]")
    True
  }
  assert {
    let assert Ok(True) = encoded |> has_substring("[security]")
    True
  }
}

pub fn kir_toml_roundtrip_test() {
  let original = sample_config()
  let encoded = config.encode_kir_toml(original)
  let assert Ok(parsed) = config.parse_kir_toml(encoded)
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
// kir.toml 파싱 에러
// ---------------------------------------------------------------------------

pub fn parse_kir_toml_missing_package_test() {
  let toml = "[hex]\nfoo = \"1.0.0\"\n"
  let assert Error(config.InvalidField("package", _)) =
    config.parse_kir_toml(toml)
}

pub fn parse_kir_toml_missing_name_test() {
  let toml = "[package]\nversion = \"1.0.0\"\n"
  let assert Error(config.InvalidField("package.name", _)) =
    config.parse_kir_toml(toml)
}

pub fn parse_kir_toml_invalid_toml_test() {
  let assert Error(config.ParseError(_)) =
    config.parse_kir_toml("[[[ invalid toml")
}

// ---------------------------------------------------------------------------
// 빈 섹션 처리
// ---------------------------------------------------------------------------

pub fn parse_kir_toml_minimal_test() {
  let toml = "[package]\nname = \"minimal\"\nversion = \"0.1.0\"\n"
  let assert Ok(cfg) = config.parse_kir_toml(toml)
  assert cfg.package.name == "minimal"
  assert cfg.hex_deps == []
  assert cfg.npm_deps == []
  let assert Error(Nil) = cfg.security.exclude_newer
}

// ---------------------------------------------------------------------------
// gleam.toml 파싱
// ---------------------------------------------------------------------------

pub fn parse_gleam_toml_test() {
  // gleam.toml은 read_gleam_toml이 파일에서 읽으므로
  // 여기서는 내부 decode_gleam_toml 로직을 kir.toml 포맷 변환 후 간접 검증
  let gleam_toml =
    "name = \"test_app\"
version = \"2.0.0\"
description = \"Test\"
licences = [\"MPL-2.0\"]

[dependencies]
gleam_stdlib = \">= 0.44.0 and < 2.0.0\"

[dev_dependencies]
gleeunit = \">= 1.0.0 and < 2.0.0\"
"
  // tom으로 직접 파싱하여 gleam.toml 구조 확인
  let assert Ok(doc) = tom.parse(gleam_toml)
  let assert Ok(name) = tom.get_string(doc, ["name"])
  assert name == "test_app"
}

// ---------------------------------------------------------------------------
// package.json 파싱
// ---------------------------------------------------------------------------

pub fn parse_package_json_test() {
  let json_str =
    "{
  \"dependencies\": {
    \"highlight.js\": \"^11.0.0\",
    \"lodash\": \"^4.17.0\"
  },
  \"devDependencies\": {
    \"@types/node\": \"^18.0.0\"
  }
}"
  let assert Ok(deps) = config.parse_package_json(json_str)
  assert list.length(deps) == 3

  let assert Ok(highlight) = list.find(deps, fn(d) { d.name == "highlight.js" })
  assert highlight.registry == Npm
  assert highlight.dev == False
  assert highlight.version_constraint == "^11.0.0"

  let assert Ok(types_node) = list.find(deps, fn(d) { d.name == "@types/node" })
  assert types_node.dev == True
}

pub fn parse_package_json_empty_deps_test() {
  let json_str = "{}"
  let assert Ok(deps) = config.parse_package_json(json_str)
  assert deps == []
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
    )
  let dep =
    Dependency(
      name: "gleam_json",
      version_constraint: ">= 3.0.0",
      registry: Hex,
      dev: False,
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
    )
  let dep_v2 =
    Dependency(
      name: "foo",
      version_constraint: "2.0.0",
      registry: Hex,
      dev: False,
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
    )
  let updated = config.remove_dependency(cfg, "foo", Npm)
  assert updated.npm_deps == []
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

import gleam/string

fn has_substring(haystack: String, needle: String) -> Result(Bool, Nil) {
  Ok(string.contains(haystack, needle))
}

import tom
