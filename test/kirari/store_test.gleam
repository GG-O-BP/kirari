import gleeunit
import kirari/security
import kirari/store
import kirari/types.{Hex}
import simplifile

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn store_root_creates_dir_test() {
  let assert Ok(root) = store.store_root()
  let assert Ok(True) = simplifile.is_directory(root)
}

pub fn has_package_not_found_test() {
  let assert Ok(False) = store.has_package("0000000000000000")
}

pub fn store_and_retrieve_test() {
  let data = create_test_tarball()
  let hash = security.sha256_hex(data)
  let assert Ok(path) =
    store.store_package(data, hash, "test_pkg", "1.0.0", Hex)
  let assert Ok(True) = simplifile.is_directory(path)
  let assert Ok(True) = store.has_package(hash)
  let assert Ok(retrieved_path) = store.package_path(hash)
  assert retrieved_path == path
}

pub fn store_hash_mismatch_test() {
  let data = <<"some data":utf8>>
  let assert Error(store.HashMismatch(_, _)) =
    store.store_package(data, "wrong_hash", "bad", "1.0.0", Hex)
}

pub fn store_idempotent_test() {
  let data = create_test_tarball()
  let hash = security.sha256_hex(data)
  let assert Ok(path1) = store.store_package(data, hash, "idem", "1.0.0", Hex)
  let assert Ok(path2) = store.store_package(data, hash, "idem", "1.0.0", Hex)
  assert path1 == path2
}

/// Erlang FFI로 실제 .tar.gz 생성
@external(erlang, "kirari_test_ffi", "create_test_tarball")
fn create_test_tarball() -> BitArray
