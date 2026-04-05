import gleam/string
import gleeunit
import kirari/export
import kirari/semver
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
      description: "A test app",
      target: "erlang",
      licences: ["MIT"],
      repository: Error(Nil),
    ),
    hex_deps: [
      Dependency(
        name: "gleam_stdlib",
        version_constraint: ">= 0.44.0 and < 2.0.0",
        registry: Hex,
        dev: False,
        optional: False,
        package_name: Error(Nil),
      ),
    ],
    hex_dev_deps: [
      Dependency(
        name: "gleeunit",
        version_constraint: ">= 1.0.0",
        registry: Hex,
        dev: True,
        optional: False,
        package_name: Error(Nil),
      ),
    ],
    npm_deps: [
      Dependency(
        name: "highlight.js",
        version_constraint: "^11.0.0",
        registry: Npm,
        dev: False,
        optional: False,
        package_name: Error(Nil),
      ),
    ],
    npm_dev_deps: [],
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

pub fn to_package_json_test() {
  let output = export.to_package_json(sample_config())
  assert string.contains(output, "\"highlight.js\"")
  assert string.contains(output, "\"^11.0.0\"")
  assert string.contains(output, "dependencies")
}

pub fn to_package_json_no_deps_test() {
  let config = KirConfig(..sample_config(), npm_deps: [], npm_dev_deps: [])
  let output = export.to_package_json(config)
  assert output == "{}\n"
}

// ---------------------------------------------------------------------------
// hex_to_npm_constraint 변환
// ---------------------------------------------------------------------------

pub fn hex_to_npm_and_range_test() {
  assert semver.hex_to_npm_constraint(">= 1.0.0 and < 2.0.0")
    == ">= 1.0.0 < 2.0.0"
}

pub fn hex_to_npm_any_test() {
  assert semver.hex_to_npm_constraint(">= 0.0.0") == "*"
}

pub fn hex_to_npm_caret_passthrough_test() {
  assert semver.hex_to_npm_constraint("^11.0.0") == "^11.0.0"
}

pub fn hex_to_npm_tilde_passthrough_test() {
  assert semver.hex_to_npm_constraint("~1.2.3") == "~1.2.3"
}

pub fn hex_to_npm_star_passthrough_test() {
  assert semver.hex_to_npm_constraint("*") == "*"
}

pub fn hex_to_npm_or_to_pipes_test() {
  assert semver.hex_to_npm_constraint(">= 1.0.0 and < 2.0.0 or >= 3.0.0")
    == ">= 1.0.0 < 2.0.0 || >= 3.0.0"
}

pub fn hex_to_npm_simple_gte_test() {
  assert semver.hex_to_npm_constraint(">= 5.0.0") == ">= 5.0.0"
}

// ---------------------------------------------------------------------------
// to_package_json에서 hex→npm 변환 적용 확인
// ---------------------------------------------------------------------------

pub fn to_package_json_converts_hex_format_test() {
  let config =
    KirConfig(
      ..sample_config(),
      npm_deps: [
        Dependency(
          name: "chalk",
          version_constraint: ">= 5.6.2 and < 6.0.0",
          registry: Npm,
          dev: False,
          optional: False,
          package_name: Error(Nil),
        ),
      ],
      npm_dev_deps: [
        Dependency(
          name: "prettier",
          version_constraint: ">= 3.8.1 and < 4.0.0",
          registry: Npm,
          dev: True,
          optional: False,
          package_name: Error(Nil),
        ),
      ],
    )
  let output = export.to_package_json(config)
  // "and" 가 npm 출력에 나타나면 안 됨
  assert !string.contains(output, "and")
  // npm 형식으로 변환된 결과 확인
  assert string.contains(output, ">= 5.6.2 < 6.0.0")
  assert string.contains(output, ">= 3.8.1 < 4.0.0")
}
