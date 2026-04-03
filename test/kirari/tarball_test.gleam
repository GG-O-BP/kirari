import gleeunit
import kirari/platform
import kirari/tarball
import kirari/types.{Hex, Npm}
import simplifile

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// Hex tarball (비압축 외부 tar → contents.tar.gz)
// ---------------------------------------------------------------------------

pub fn extract_hex_test() {
  let data = create_hex_test_tarball()
  let assert Ok(home) = platform.get_home_dir()
  let dest = home <> "/.kir/test-hex-extract"
  let _ = simplifile.delete(dest)
  let assert Ok(Nil) = tarball.extract(data, dest, Hex)
  // contents.tar.gz 안의 src/hello.gleam이 추출되어야 함
  let assert Ok(content) = simplifile.read(dest <> "/src/hello.gleam")
  assert content == "pub fn main() { Nil }\n"
  let _ = simplifile.delete(dest)
}

// ---------------------------------------------------------------------------
// npm tarball (gzip tar with package/ prefix)
// ---------------------------------------------------------------------------

pub fn extract_npm_test() {
  let data = create_npm_test_tarball()
  let assert Ok(home) = platform.get_home_dir()
  let dest = home <> "/.kir/test-npm-extract"
  let _ = simplifile.delete(dest)
  let assert Ok(Nil) = tarball.extract(data, dest, Npm)
  // package/ prefix가 제거되어 root에 파일이 있어야 함
  let assert Ok(content) = simplifile.read(dest <> "/index.js")
  assert content == "module.exports = {};\n"
  let assert Ok(pkg) = simplifile.read(dest <> "/package.json")
  assert pkg == "{\"name\":\"test\",\"version\":\"1.0.0\"}\n"
  let _ = simplifile.delete(dest)
}

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

@external(erlang, "kirari_test_ffi", "create_hex_test_tarball")
fn create_hex_test_tarball() -> BitArray

@external(erlang, "kirari_test_ffi", "create_npm_test_tarball")
fn create_npm_test_tarball() -> BitArray
