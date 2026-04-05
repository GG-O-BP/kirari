import gleam/dict
import gleam/list
import gleam/string
import gleeunit
import kirari/resolver.{type VersionInfo, VersionInfo}
import kirari/tree
import kirari/types.{
  type KirConfig, type KirLock, Dependency, Hex, KirConfig, KirLock, Npm,
  PackageInfo, ResolvedPackage,
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
      links: [],
    ),
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
    hex_dev_deps: [],
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

fn test_lock() -> KirLock {
  KirLock(version: 1, config_fingerprint: Error(Nil), packages: [
    ResolvedPackage(
      name: "gleam_stdlib",
      version: "0.44.0",
      registry: Hex,
      sha256: "aaa",
      has_scripts: False,
      platform: Error(Nil),
      license: "",
      dev: False,
      package_name: Error(Nil),
      git_source: Error(Nil),
      url_source: Error(Nil),
    ),
    ResolvedPackage(
      name: "highlight.js",
      version: "11.9.0",
      registry: Npm,
      sha256: "bbb",
      has_scripts: False,
      platform: Error(Nil),
      license: "",
      dev: False,
      package_name: Error(Nil),
      git_source: Error(Nil),
      url_source: Error(Nil),
    ),
  ])
}

fn test_version_infos() -> dict.Dict(String, VersionInfo) {
  dict.from_list([
    #(
      "gleam_stdlib:hex",
      VersionInfo(
        version: "0.44.0",
        published_at: "",
        tarball_url: "",
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
    ),
    #(
      "highlight.js:npm",
      VersionInfo(
        version: "11.9.0",
        published_at: "",
        tarball_url: "",
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
    ),
  ])
}

pub fn build_tree_test() {
  let roots = tree.build(test_config(), test_lock(), test_version_infos())
  assert list.length(roots) == 2
  let assert [first, second] = roots
  assert first.name == "gleam_stdlib"
  assert second.name == "highlight.js"
}

pub fn render_tree_test() {
  let roots = tree.build(test_config(), test_lock(), test_version_infos())
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
        links: [],
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
      download: types.default_download_config(),
      git_deps: [],
      git_dev_deps: [],
      url_deps: [],
      url_dev_deps: [],
      npm_package: dict.new(),
    )
  let roots =
    tree.build(
      empty_config,
      KirLock(version: 1, config_fingerprint: Error(Nil), packages: []),
      dict.new(),
    )
  assert roots == []
  assert tree.render(roots) == ""
}

pub fn transitive_deps_tree_test() {
  let config =
    KirConfig(
      ..test_config(),
      hex_deps: [
        Dependency(
          name: "my_lib",
          version_constraint: ">= 1.0.0",
          registry: Hex,
          dev: False,
          optional: False,
          package_name: Error(Nil),
        ),
      ],
      npm_deps: [],
    )
  let lock =
    KirLock(version: 1, config_fingerprint: Error(Nil), packages: [
      ResolvedPackage(
        name: "my_lib",
        version: "1.0.0",
        registry: Hex,
        sha256: "x",
        has_scripts: False,
        platform: Error(Nil),
        license: "",
        dev: False,
        package_name: Error(Nil),
        git_source: Error(Nil),
        url_source: Error(Nil),
      ),
      ResolvedPackage(
        name: "gleam_stdlib",
        version: "0.44.0",
        registry: Hex,
        sha256: "y",
        has_scripts: False,
        platform: Error(Nil),
        license: "",
        dev: False,
        package_name: Error(Nil),
        git_source: Error(Nil),
        url_source: Error(Nil),
      ),
    ])
  let vis =
    dict.from_list([
      #(
        "my_lib:hex",
        VersionInfo(
          version: "1.0.0",
          published_at: "",
          tarball_url: "",
          dependencies: [
            Dependency(
              name: "gleam_stdlib",
              version_constraint: ">= 0.44.0",
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
      ),
      #(
        "gleam_stdlib:hex",
        VersionInfo(
          version: "0.44.0",
          published_at: "",
          tarball_url: "",
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
      ),
    ])
  let roots = tree.build(config, lock, vis)
  assert list.length(roots) == 1
  let assert [root] = roots
  assert root.name == "my_lib"
  // 전이 의존성이 children으로 표시
  assert list.length(root.children) == 1
  let assert [child] = root.children
  assert child.name == "gleam_stdlib"
  // 렌더링에 전이 의존성 포함
  let output = tree.render(roots)
  assert string.contains(output, "my_lib")
  assert string.contains(output, "gleam_stdlib")
}
