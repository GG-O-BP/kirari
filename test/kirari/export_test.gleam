import gleam/string
import gleeunit
import kirari/export
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
