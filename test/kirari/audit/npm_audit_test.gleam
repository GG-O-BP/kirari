import gleam/string
import gleeunit/should
import kirari/audit/npm_audit
import kirari/types.{Npm, ResolvedPackage}

// ---------------------------------------------------------------------------
// build_request_body
// ---------------------------------------------------------------------------

pub fn build_request_body_single_test() {
  let packages = [
    ResolvedPackage(
      name: "lodash",
      version: "4.17.20",
      registry: Npm,
      sha256: "abc",
      has_scripts: False,
      platform: Error(Nil),
      license: "MIT",
      dev: False,
      package_name: Error(Nil),
    ),
  ]
  let body = npm_audit.build_request_body(packages)
  should.be_true(string.contains(body, "\"lodash\""))
  should.be_true(string.contains(body, "\"4.17.20\""))
}

pub fn build_request_body_multiple_test() {
  let packages = [
    ResolvedPackage(
      name: "lodash",
      version: "4.17.20",
      registry: Npm,
      sha256: "abc",
      has_scripts: False,
      platform: Error(Nil),
      license: "MIT",
      dev: False,
      package_name: Error(Nil),
    ),
    ResolvedPackage(
      name: "esbuild",
      version: "0.21.5",
      registry: Npm,
      sha256: "def",
      has_scripts: False,
      platform: Error(Nil),
      license: "MIT",
      dev: False,
      package_name: Error(Nil),
    ),
  ]
  let body = npm_audit.build_request_body(packages)
  should.be_true(string.contains(body, "\"lodash\""))
  should.be_true(string.contains(body, "\"esbuild\""))
}

pub fn build_request_body_scoped_test() {
  let packages = [
    ResolvedPackage(
      name: "@babel/core",
      version: "7.24.0",
      registry: Npm,
      sha256: "abc",
      has_scripts: False,
      platform: Error(Nil),
      license: "MIT",
      dev: False,
      package_name: Error(Nil),
    ),
  ]
  let body = npm_audit.build_request_body(packages)
  should.be_true(string.contains(body, "\"@babel/core\""))
}
