import gleam/list
import gleam/string
import gleeunit
import kirari/tree
import kirari/types.{
  type KirConfig, type KirLock, Dependency, Hex, KirConfig, KirLock, Npm,
  PackageInfo, ResolvedPackage, SecurityConfig,
}

pub fn main() -> Nil {
  gleeunit.main()
}

fn test_config() -> KirConfig {
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
        version_constraint: ">= 0.44.0",
        registry: Hex,
        dev: False,
      ),
    ],
    hex_dev_deps: [],
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
    path_deps: [],
    path_dev_deps: [],
  )
}

fn test_lock() -> KirLock {
  KirLock(version: 1, packages: [
    ResolvedPackage(
      name: "gleam_stdlib",
      version: "0.44.0",
      registry: Hex,
      sha256: "aaa",
    ),
    ResolvedPackage(
      name: "highlight.js",
      version: "11.9.0",
      registry: Npm,
      sha256: "bbb",
    ),
  ])
}

pub fn build_tree_test() {
  let roots = tree.build(test_config(), test_lock())
  assert list.length(roots) == 2
  let assert [first, second] = roots
  assert first.name == "gleam_stdlib"
  assert second.name == "highlight.js"
}

pub fn render_tree_test() {
  let roots = tree.build(test_config(), test_lock())
  let output = tree.render(roots)
  assert string.contains(output, "gleam_stdlib")
  assert string.contains(output, "v0.44.0")
  assert string.contains(output, "(hex)")
  assert string.contains(output, "highlight.js")
  assert string.contains(output, "(npm)")
}

pub fn empty_tree_test() {
  let empty_config =
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
      security: SecurityConfig(exclude_newer: Error(Nil)),
      path_deps: [],
      path_dev_deps: [],
    )
  let roots = tree.build(empty_config, KirLock(version: 1, packages: []))
  assert roots == []
  assert tree.render(roots) == ""
}
