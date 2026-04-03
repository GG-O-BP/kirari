import gleeunit
import kirari/platform
import simplifile

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn get_home_dir_test() {
  let assert Ok(home) = platform.get_home_dir()
  let assert Ok(True) = simplifile.is_directory(home)
}

pub fn make_temp_dir_test() {
  let assert Ok(home) = platform.get_home_dir()
  let base = home <> "/.kir/test-tmp"
  let _ = simplifile.create_directory_all(base)
  let assert Ok(tmp) = platform.make_temp_dir(base)
  let assert Ok(True) = simplifile.is_directory(tmp)
  // 정리
  let _ = simplifile.delete(tmp)
  let _ = simplifile.delete(base)
}

pub fn atomic_rename_test() {
  let assert Ok(home) = platform.get_home_dir()
  let base = home <> "/.kir/test-rename"
  let _ = simplifile.create_directory_all(base)
  let src = base <> "/src_dir"
  let dst = base <> "/dst_dir"
  let _ = simplifile.create_directory_all(src)
  let _ = simplifile.write(src <> "/test.txt", "hello")
  let assert Ok(Nil) = platform.atomic_rename(src, dst)
  let assert Ok("hello") = simplifile.read(dst <> "/test.txt")
  // 정리
  let _ = simplifile.delete(base)
}
