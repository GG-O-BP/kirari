import gleeunit
import kirari/security

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// SHA256
// ---------------------------------------------------------------------------

pub fn sha256_hex_empty_test() {
  // SHA256("") = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
  let hash = security.sha256_hex(<<>>)
  assert hash
    == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
}

pub fn sha256_hex_hello_test() {
  // SHA256("hello") = 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
  let hash = security.sha256_hex(<<"hello":utf8>>)
  assert hash
    == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
}

// ---------------------------------------------------------------------------
// 상수 시간 비교
// ---------------------------------------------------------------------------

pub fn constant_time_equal_same_test() {
  assert security.constant_time_equal("abc", "abc") == True
}

pub fn constant_time_equal_different_test() {
  assert security.constant_time_equal("abc", "def") == False
}

pub fn constant_time_equal_different_length_test() {
  assert security.constant_time_equal("abc", "abcd") == False
}

// ---------------------------------------------------------------------------
// 해시 검증
// ---------------------------------------------------------------------------

pub fn verify_hash_ok_test() {
  let data = <<"test data":utf8>>
  let hash = security.sha256_hex(data)
  let assert Ok(Nil) = security.verify_hash(data, hash)
}

pub fn verify_hash_mismatch_test() {
  let assert Error(security.HashMismatch(_, _)) =
    security.verify_hash(<<"data":utf8>>, "0000000000000000")
}

pub fn verify_hash_case_insensitive_test() {
  let data = <<>>
  let hash_upper =
    "E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855"
  let assert Ok(Nil) = security.verify_hash(data, hash_upper)
}

// ---------------------------------------------------------------------------
// 경로 검증
// ---------------------------------------------------------------------------

pub fn validate_path_ok_test() {
  let assert Ok("foo/bar/baz.txt") = security.validate_path("foo/bar/baz.txt")
}

pub fn validate_path_traversal_test() {
  let assert Error(security.PathTraversal(_)) =
    security.validate_path("../etc/passwd")
}

pub fn validate_path_nested_traversal_test() {
  let assert Error(security.PathTraversal(_)) =
    security.validate_path("foo/../../bar")
}

pub fn validate_path_absolute_test() {
  let assert Error(security.PathTraversal(_)) =
    security.validate_path("/absolute/path")
}

pub fn validate_path_windows_drive_test() {
  let assert Error(security.PathTraversal(_)) =
    security.validate_path("C:\\Windows\\System32")
}

// ---------------------------------------------------------------------------
// exclude-newer 타임스탬프
// ---------------------------------------------------------------------------

pub fn is_before_cutoff_true_test() {
  let assert Ok(True) =
    security.is_before_cutoff("2026-01-15T10:00:00Z", "2026-04-01T00:00:00Z")
}

pub fn is_before_cutoff_false_test() {
  let assert Ok(False) =
    security.is_before_cutoff("2026-06-01T00:00:00Z", "2026-04-01T00:00:00Z")
}

pub fn is_before_cutoff_invalid_test() {
  let assert Error(security.InvalidTimestamp(_)) =
    security.is_before_cutoff("not-a-date", "2026-04-01T00:00:00Z")
}
