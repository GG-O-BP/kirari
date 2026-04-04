import gleeunit
import kirari/security
import kirari/store
import kirari/store/types as store_types
import kirari/types.{Hex, Npm}
import simplifile

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn store_root_creates_dir_test() {
  let assert Ok(root) = store.store_root()
  let assert Ok(True) = simplifile.is_directory(root)
}

pub fn has_package_not_found_test() {
  let assert Ok(False) = store.has_package("0000000000000000", Hex)
  let assert Ok(False) = store.has_package("0000000000000000", Npm)
}

pub fn store_hex_and_retrieve_test() {
  let data = create_hex_test_tarball()
  let hash = security.sha256_hex(data)
  let assert Ok(result) =
    store.store_package(data, hash, "test_hex_pkg", "1.0.0", Hex)
  let assert Ok(True) = simplifile.is_directory(result.path)
  assert result.has_scripts == False
  assert result.bin == []
  let assert Ok(True) = store.has_package(hash, Hex)
  let assert Ok(retrieved_path) = store.package_path(hash, Hex)
  assert retrieved_path == result.path
  // Hex 패키지는 hex/ 하위에 저장
  assert string_contains(result.path, "/hex/")
}

pub fn store_npm_and_retrieve_test() {
  let data = create_npm_test_tarball()
  let hash = security.sha256_hex(data)
  let assert Ok(result) =
    store.store_package(data, hash, "test_npm_pkg", "1.0.0", Npm)
  let assert Ok(True) = simplifile.is_directory(result.path)
  let assert Ok(True) = store.has_package(hash, Npm)
  // npm 패키지는 npm/ 하위에 저장
  assert string_contains(result.path, "/npm/")
  // .meta 사이드카 존재 확인
  let meta_path = result.path <> ".meta"
  let assert Ok(True) = simplifile.is_file(meta_path)
}

pub fn store_hash_mismatch_test() {
  let data = <<"some data":utf8>>
  let assert Error(store_types.HashMismatch(_, _)) =
    store.store_package(data, "wrong_hash", "bad", "1.0.0", Hex)
}

pub fn store_idempotent_test() {
  let data = create_npm_test_tarball()
  let hash = security.sha256_hex(data)
  let assert Ok(r1) = store.store_package(data, hash, "idem", "1.0.0", Npm)
  let assert Ok(r2) = store.store_package(data, hash, "idem", "1.0.0", Npm)
  assert r1.path == r2.path
}

pub fn hex_npm_separate_stores_test() {
  // 같은 데이터라도 registry가 다르면 다른 경로
  let data = create_hex_test_tarball()
  let hash = security.sha256_hex(data)
  let assert Ok(hex_r) = store.store_package(data, hash, "sep", "1.0.0", Hex)
  // Hex store에는 있지만 npm store에는 없음
  let assert Ok(True) = store.has_package(hash, Hex)
  let assert Ok(False) = store.has_package(hash, Npm)
  assert string_contains(hex_r.path, "/hex/")
}

import gleam/string

fn string_contains(haystack: String, needle: String) -> Bool {
  string.contains(haystack, needle)
}

@external(erlang, "kirari_test_ffi", "create_hex_test_tarball")
fn create_hex_test_tarball() -> BitArray

@external(erlang, "kirari_test_ffi", "create_npm_test_tarball")
fn create_npm_test_tarball() -> BitArray
