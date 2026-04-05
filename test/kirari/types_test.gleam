import gleam/order
import gleeunit
import kirari/types.{Hex, Npm, ResolvedPackage}

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn registry_to_string_test() {
  assert types.registry_to_string(Hex) == "hex"
  assert types.registry_to_string(Npm) == "npm"
}

pub fn registry_from_string_test() {
  assert types.registry_from_string("hex") == Ok(Hex)
  assert types.registry_from_string("npm") == Ok(Npm)
  assert types.registry_from_string("Hex") == Ok(Hex)
  assert types.registry_from_string("NPM") == Ok(Npm)
  assert types.registry_from_string("other") == Error(Nil)
}

pub fn compare_packages_by_name_test() {
  let a =
    ResolvedPackage(
      name: "alpha",
      version: "1.0.0",
      registry: Hex,
      sha256: "a",
      has_scripts: False,
      platform: Error(Nil),
      license: "",
      dev: False,
      package_name: Error(Nil),
    )
  let b =
    ResolvedPackage(
      name: "beta",
      version: "1.0.0",
      registry: Hex,
      sha256: "b",
      has_scripts: False,
      platform: Error(Nil),
      license: "",
      dev: False,
      package_name: Error(Nil),
    )
  assert types.compare_packages(a, b) == order.Lt
  assert types.compare_packages(b, a) == order.Gt
  assert types.compare_packages(a, a) == order.Eq
}

pub fn compare_packages_same_name_different_registry_test() {
  let hex_pkg =
    ResolvedPackage(
      name: "utils",
      version: "1.0.0",
      registry: Hex,
      sha256: "h",
      has_scripts: False,
      platform: Error(Nil),
      license: "",
      dev: False,
      package_name: Error(Nil),
    )
  let npm_pkg =
    ResolvedPackage(
      name: "utils",
      version: "2.0.0",
      registry: Npm,
      sha256: "n",
      has_scripts: False,
      platform: Error(Nil),
      license: "",
      dev: False,
      package_name: Error(Nil),
    )
  // "hex" < "npm" 사전순
  assert types.compare_packages(hex_pkg, npm_pkg) == order.Lt
  assert types.compare_packages(npm_pkg, hex_pkg) == order.Gt
}
