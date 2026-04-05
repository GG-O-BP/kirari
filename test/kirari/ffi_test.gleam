import gleam/list
import gleeunit
import kirari/ffi as ffi_detect
import kirari/types.{Dependency, KirConfig, Npm, PackageInfo}

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn detect_no_build_dir_test() {
  let assert Ok(detections) = ffi_detect.detect_npm_imports("/nonexistent")
  assert detections == []
}

pub fn find_undeclared_filters_declared_test() {
  let detections = [
    ffi_detect.FfiDetection(package_name: "lodash", source_file: "a.mjs"),
    ffi_detect.FfiDetection(package_name: "highlight.js", source_file: "b.mjs"),
  ]
  let config =
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
      npm_deps: [
        Dependency(
          name: "lodash",
          version_constraint: "^4.0.0",
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
  let undeclared = ffi_detect.find_undeclared(detections, config)
  assert list.length(undeclared) == 1
  let assert [d] = undeclared
  assert d.package_name == "highlight.js"
}

pub fn to_dependencies_test() {
  let detections = [
    ffi_detect.FfiDetection(package_name: "lodash", source_file: "a.mjs"),
    ffi_detect.FfiDetection(package_name: "lodash", source_file: "b.mjs"),
    ffi_detect.FfiDetection(
      package_name: "@codemirror/view",
      source_file: "c.mjs",
    ),
  ]
  let deps = ffi_detect.to_dependencies(detections)
  assert list.length(deps) == 2
}
