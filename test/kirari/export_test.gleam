import gleam/dict
import gleam/string
import gleeunit
import kirari/export
import kirari/semver
import kirari/types.{
  type KirConfig, Dependency, EnginesConfig, Hex, KirConfig, Npm, PackageInfo,
}
import tom

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
      links: [],
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
    npm_package: dict.new(),
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
  // npm deps 없어도 자동 파생 필드(name, version, description, license) 포함
  assert string.contains(output, "\"name\": \"my_app\"")
  assert string.contains(output, "\"version\": \"1.0.0\"")
  assert string.contains(output, "\"license\": \"MIT\"")
  assert !string.contains(output, "\"dependencies\"")
  assert !string.contains(output, "\"devDependencies\"")
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

// ---------------------------------------------------------------------------
// 자동 파생 필드
// ---------------------------------------------------------------------------

pub fn to_package_json_auto_derived_fields_test() {
  let config =
    KirConfig(
      ..sample_config(),
      package: PackageInfo(
        name: "my_pkg",
        version: "2.0.0",
        description: "A great package",
        target: "erlang",
        licences: ["MIT"],
        repository: Ok("github:owner/repo"),
        links: [#("Website", "https://example.com")],
      ),
      engines: EnginesConfig(
        gleam: Error(Nil),
        erlang: Error(Nil),
        node: Ok(">= 16"),
      ),
      npm_deps: [],
      npm_dev_deps: [],
    )
  let output = export.to_package_json(config)
  assert string.contains(output, "\"name\": \"my_pkg\"")
  assert string.contains(output, "\"version\": \"2.0.0\"")
  assert string.contains(output, "\"description\": \"A great package\"")
  assert string.contains(output, "\"license\": \"MIT\"")
  assert string.contains(output, "\"homepage\": \"https://example.com\"")
  assert string.contains(output, "\"repository\": ")
  assert string.contains(output, "git+https://github.com/owner/repo.git")
  assert string.contains(output, "\"engines\": {")
  assert string.contains(output, "\"node\": \">= 16\"")
}

pub fn to_package_json_multi_license_test() {
  let config =
    KirConfig(
      ..sample_config(),
      package: PackageInfo(..sample_config().package, licences: [
        "MIT",
        "Apache-2.0",
      ]),
    )
  let output = export.to_package_json(config)
  assert string.contains(output, "\"license\": \"(MIT OR Apache-2.0)\"")
}

// ---------------------------------------------------------------------------
// [npm-package] passthrough
// ---------------------------------------------------------------------------

pub fn to_package_json_npm_package_fields_test() {
  let npm_table =
    dict.from_list([
      #("type", tom.String("module")),
      #("main", tom.String("./dist/index.js")),
      #("private", tom.Bool(True)),
      #("keywords", tom.Array([tom.String("gleam"), tom.String("npm")])),
    ])
  let config = KirConfig(..sample_config(), npm_package: npm_table)
  let output = export.to_package_json(config)
  assert string.contains(output, "\"type\": \"module\"")
  assert string.contains(output, "\"main\": \"./dist/index.js\"")
  assert string.contains(output, "\"private\": true")
  assert string.contains(output, "\"keywords\": [\n")
  assert string.contains(output, "\"gleam\"")
  assert string.contains(output, "\"npm\"")
}

pub fn to_package_json_npm_package_nested_test() {
  let npm_table =
    dict.from_list([
      #(
        "scripts",
        tom.InlineTable(
          dict.from_list([
            #("build", tom.String("tsc")),
            #("test", tom.String("jest")),
          ]),
        ),
      ),
      #(
        "bin",
        tom.InlineTable(
          dict.from_list([#("myapp", tom.String("./bin/cli.js"))]),
        ),
      ),
    ])
  let config = KirConfig(..sample_config(), npm_package: npm_table)
  let output = export.to_package_json(config)
  assert string.contains(output, "\"scripts\": {")
  assert string.contains(output, "\"build\": \"tsc\"")
  assert string.contains(output, "\"bin\": {")
  assert string.contains(output, "\"myapp\": \"./bin/cli.js\"")
}

pub fn to_package_json_npm_package_peer_deps_test() {
  let npm_table =
    dict.from_list([
      #(
        "peerDependencies",
        tom.InlineTable(
          dict.from_list([
            #("react", tom.String("^17.0.0 || ^18.0.0")),
          ]),
        ),
      ),
    ])
  let config = KirConfig(..sample_config(), npm_package: npm_table)
  let output = export.to_package_json(config)
  assert string.contains(output, "\"peerDependencies\": {")
  assert string.contains(output, "\"react\": \"^17.0.0 || ^18.0.0\"")
}

// ---------------------------------------------------------------------------
// override 우선순위
// ---------------------------------------------------------------------------

pub fn to_package_json_npm_package_overrides_derived_test() {
  let npm_table =
    dict.from_list([
      #("name", tom.String("@scope/custom-name")),
      #("description", tom.String("npm specific desc")),
    ])
  let config = KirConfig(..sample_config(), npm_package: npm_table)
  let output = export.to_package_json(config)
  // [npm-package]의 name이 자동 파생 name을 override
  assert string.contains(output, "\"name\": \"@scope/custom-name\"")
  assert !string.contains(output, "\"name\": \"my_app\"")
  // description도 override
  assert string.contains(output, "\"description\": \"npm specific desc\"")
}

pub fn to_package_json_deps_override_npm_package_test() {
  // [npm-package]에 dependencies를 넣어도 [npm-dependencies]가 최우선
  let npm_table =
    dict.from_list([
      #(
        "dependencies",
        tom.InlineTable(dict.from_list([#("lodash", tom.String("^4.0.0"))])),
      ),
    ])
  let config = KirConfig(..sample_config(), npm_package: npm_table)
  let output = export.to_package_json(config)
  // [npm-dependencies]의 highlight.js가 포함
  assert string.contains(output, "\"highlight.js\"")
  // [npm-package]의 lodash는 덮어씌워짐
  assert !string.contains(output, "lodash")
}

// ---------------------------------------------------------------------------
// 필드 순서
// ---------------------------------------------------------------------------

pub fn to_package_json_field_order_test() {
  let npm_table =
    dict.from_list([
      #("keywords", tom.Array([tom.String("test")])),
      #("private", tom.Bool(True)),
    ])
  let config = KirConfig(..sample_config(), npm_package: npm_table)
  let output = export.to_package_json(config)
  // name이 keywords보다 앞에 있어야 함
  let assert Ok(name_pos) = find_position(output, "\"name\"")
  let assert Ok(kw_pos) = find_position(output, "\"keywords\"")
  let assert Ok(deps_pos) = find_position(output, "\"dependencies\"")
  let assert Ok(priv_pos) = find_position(output, "\"private\"")
  assert name_pos < kw_pos
  assert kw_pos < deps_pos
  assert deps_pos < priv_pos
}

fn find_position(haystack: String, needle: String) -> Result(Int, Nil) {
  case string.split_once(haystack, needle) {
    Ok(#(before, _)) -> Ok(string.length(before))
    Error(_) -> Error(Nil)
  }
}
