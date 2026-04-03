import gleam/string
import gleeunit
import kirari/export
import kirari/types.{
  type KirConfig, Dependency, Hex, KirConfig, Npm, PackageInfo, SecurityConfig,
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
      ),
    ],
    hex_dev_deps: [
      Dependency(
        name: "gleeunit",
        version_constraint: ">= 1.0.0",
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
    security: SecurityConfig(exclude_newer: Error(Nil)),
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
