import gleam/list
import gleam/string
import gleeunit
import kirari/store/manifest
import simplifile

pub fn main() -> Nil {
  gleeunit.main()
}

fn make_test_dir() -> String {
  let dir = "./test_manifest_tmp_" <> random_suffix()
  let _ = simplifile.create_directory_all(dir)
  dir
}

fn random_suffix() -> String {
  let now = erlang_unique_integer()
  string.inspect(now)
}

@external(erlang, "erlang", "unique_integer")
fn erlang_unique_integer() -> Int

fn cleanup(dir: String) -> Nil {
  let _ = simplifile.delete(dir)
  Nil
}

// ---------------------------------------------------------------------------
// generate + read round-trip
// ---------------------------------------------------------------------------

pub fn generate_and_read_roundtrip_test() {
  let dir = make_test_dir()
  let _ = simplifile.write(dir <> "/a.txt", "hello")
  let _ = simplifile.write(dir <> "/b.txt", "world")
  let assert Ok(Nil) = manifest.generate(dir)
  let assert Ok(entries) = manifest.read(dir)
  assert list.length(entries) == 2
  // 경로는 정렬되어 있어야 함
  let assert [first, second] = entries
  assert first.path == "a.txt"
  assert second.path == "b.txt"
  // SHA256은 64자 hex
  assert string.length(first.sha256) == 64
  cleanup(dir)
}

// ---------------------------------------------------------------------------
// verify_full: 정상
// ---------------------------------------------------------------------------

pub fn verify_full_ok_test() {
  let dir = make_test_dir()
  let _ = simplifile.write(dir <> "/file1.gleam", "pub fn main() { }")
  let _ = simplifile.write(dir <> "/file2.gleam", "import gleam/io")
  let assert Ok(Nil) = manifest.generate(dir)
  let assert Ok(manifest.VerifyOk(2)) = manifest.verify_full(dir)
  cleanup(dir)
}

// ---------------------------------------------------------------------------
// verify_full: 파일 내용 변경 → mismatched
// ---------------------------------------------------------------------------

pub fn verify_full_corrupted_test() {
  let dir = make_test_dir()
  let _ = simplifile.write(dir <> "/data.txt", "original content")
  let assert Ok(Nil) = manifest.generate(dir)
  // 파일 내용 변경
  let _ = simplifile.write(dir <> "/data.txt", "CORRUPTED content")
  let assert Ok(manifest.VerifyCorrupted(mismatched, missing, extra)) =
    manifest.verify_full(dir)
  assert mismatched == ["data.txt"]
  assert missing == []
  assert extra == []
  cleanup(dir)
}

// ---------------------------------------------------------------------------
// verify_full: 파일 삭제 → missing
// ---------------------------------------------------------------------------

pub fn verify_full_missing_file_test() {
  let dir = make_test_dir()
  let _ = simplifile.write(dir <> "/keep.txt", "keep")
  let _ = simplifile.write(dir <> "/remove.txt", "will be removed")
  let assert Ok(Nil) = manifest.generate(dir)
  // 파일 삭제
  let _ = simplifile.delete(dir <> "/remove.txt")
  let assert Ok(manifest.VerifyCorrupted(mismatched, missing, extra)) =
    manifest.verify_full(dir)
  assert mismatched == []
  assert missing == ["remove.txt"]
  assert extra == []
  cleanup(dir)
}

// ---------------------------------------------------------------------------
// verify_full: 파일 추가 → extra
// ---------------------------------------------------------------------------

pub fn verify_full_extra_file_test() {
  let dir = make_test_dir()
  let _ = simplifile.write(dir <> "/original.txt", "original")
  let assert Ok(Nil) = manifest.generate(dir)
  // 파일 추가
  let _ = simplifile.write(dir <> "/injected.txt", "malware")
  let assert Ok(manifest.VerifyCorrupted(mismatched, missing, extra)) =
    manifest.verify_full(dir)
  assert mismatched == []
  assert missing == []
  assert extra == ["injected.txt"]
  cleanup(dir)
}

// ---------------------------------------------------------------------------
// verify_full: 매니페스트 없음 → VerifyNoManifest
// ---------------------------------------------------------------------------

pub fn verify_full_no_manifest_test() {
  let dir = make_test_dir()
  let _ = simplifile.write(dir <> "/file.txt", "content")
  // manifest.generate 호출하지 않음
  let assert Ok(manifest.VerifyNoManifest) = manifest.verify_full(dir)
  cleanup(dir)
}

// ---------------------------------------------------------------------------
// verify_quick: 정상
// ---------------------------------------------------------------------------

pub fn verify_quick_ok_test() {
  let dir = make_test_dir()
  let _ = simplifile.write(dir <> "/a.txt", "aaa")
  let _ = simplifile.write(dir <> "/b.txt", "bbb")
  let assert Ok(Nil) = manifest.generate(dir)
  let assert Ok(manifest.VerifyOk(2)) = manifest.verify_quick(dir)
  cleanup(dir)
}

// ---------------------------------------------------------------------------
// verify_quick: 파일 삭제 → count 불일치
// ---------------------------------------------------------------------------

pub fn verify_quick_count_mismatch_test() {
  let dir = make_test_dir()
  let _ = simplifile.write(dir <> "/a.txt", "aaa")
  let _ = simplifile.write(dir <> "/b.txt", "bbb")
  let assert Ok(Nil) = manifest.generate(dir)
  let _ = simplifile.delete(dir <> "/b.txt")
  let assert Ok(manifest.VerifyCorrupted(_, _, _)) = manifest.verify_quick(dir)
  cleanup(dir)
}

// ---------------------------------------------------------------------------
// verify_quick: 매니페스트 없음
// ---------------------------------------------------------------------------

pub fn verify_quick_no_manifest_test() {
  let dir = make_test_dir()
  let _ = simplifile.write(dir <> "/file.txt", "content")
  let assert Ok(manifest.VerifyNoManifest) = manifest.verify_quick(dir)
  cleanup(dir)
}

// ---------------------------------------------------------------------------
// .kir-manifest 자체는 매니페스트에 포함되지 않음
// ---------------------------------------------------------------------------

pub fn manifest_excludes_itself_test() {
  let dir = make_test_dir()
  let _ = simplifile.write(dir <> "/code.gleam", "pub fn x() { }")
  let assert Ok(Nil) = manifest.generate(dir)
  let assert Ok(entries) = manifest.read(dir)
  let paths = list.map(entries, fn(e) { e.path })
  assert !list.contains(paths, ".kir-manifest")
  assert list.length(entries) == 1
  cleanup(dir)
}

// ---------------------------------------------------------------------------
// 하위 디렉토리 파일 포함
// ---------------------------------------------------------------------------

pub fn nested_directory_files_test() {
  let dir = make_test_dir()
  let _ = simplifile.create_directory_all(dir <> "/src/lib")
  let _ = simplifile.write(dir <> "/src/lib/main.gleam", "pub fn main() { }")
  let _ = simplifile.write(dir <> "/README.md", "# Test")
  let assert Ok(Nil) = manifest.generate(dir)
  let assert Ok(entries) = manifest.read(dir)
  assert list.length(entries) == 2
  let paths = list.map(entries, fn(e) { e.path })
  assert list.contains(paths, "src/lib/main.gleam")
  assert list.contains(paths, "README.md")
  cleanup(dir)
}
