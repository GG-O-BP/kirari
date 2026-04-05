import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import kirari/lockfile
import kirari/types.{type ResolvedPackage, Hex, Npm, ResolvedPackage}

pub fn main() -> Nil {
  gleeunit.main()
}

fn sample_packages() -> List(ResolvedPackage) {
  [
    ResolvedPackage(
      name: "gleam_stdlib",
      version: "0.44.0",
      registry: Hex,
      sha256: "abc123",
      has_scripts: False,
      platform: Error(Nil),
      license: "",
      dev: False,
    ),
    ResolvedPackage(
      name: "highlight.js",
      version: "11.9.0",
      registry: Npm,
      sha256: "def456",
      has_scripts: False,
      platform: Error(Nil),
      license: "",
      dev: False,
    ),
    ResolvedPackage(
      name: "gleam_json",
      version: "3.0.0",
      registry: Hex,
      sha256: "ghi789",
      has_scripts: False,
      platform: Error(Nil),
      license: "",
      dev: False,
    ),
  ]
}

// ---------------------------------------------------------------------------
// from_packages 정렬
// ---------------------------------------------------------------------------

pub fn from_packages_sorts_alphabetically_test() {
  let lock = lockfile.from_packages(sample_packages())
  assert lock.version == lockfile.lock_version
  assert list.length(lock.packages) == 3
  let assert [first, second, third] = lock.packages
  assert first.name == "gleam_json"
  assert second.name == "gleam_stdlib"
  assert third.name == "highlight.js"
}

// ---------------------------------------------------------------------------
// round-trip
// ---------------------------------------------------------------------------

pub fn encode_parse_roundtrip_test() {
  let original = lockfile.from_packages(sample_packages())
  let encoded = lockfile.encode(original)
  let assert Ok(parsed) = lockfile.parse(encoded)
  assert parsed.version == original.version
  assert list.length(parsed.packages) == list.length(original.packages)
  let assert [first, ..] = parsed.packages
  assert first.name == "gleam_json"
  assert first.version == "3.0.0"
  assert first.registry == Hex
  assert first.sha256 == "ghi789"
}

// ---------------------------------------------------------------------------
// 빈 lock
// ---------------------------------------------------------------------------

pub fn empty_lock_roundtrip_test() {
  let lock = lockfile.from_packages([])
  let encoded = lockfile.encode(lock)
  let assert Ok(parsed) = lockfile.parse(encoded)
  assert parsed.packages == []
  assert parsed.version == lockfile.lock_version
}

// ---------------------------------------------------------------------------
// find_package
// ---------------------------------------------------------------------------

pub fn find_package_exists_test() {
  let lock = lockfile.from_packages(sample_packages())
  let assert Some(pkg) = lockfile.find_package(lock, "gleam_stdlib", Hex)
  assert pkg.version == "0.44.0"
}

pub fn find_package_not_found_test() {
  let lock = lockfile.from_packages(sample_packages())
  let assert None = lockfile.find_package(lock, "nonexistent", Hex)
}

pub fn find_package_wrong_registry_test() {
  let lock = lockfile.from_packages(sample_packages())
  let assert None = lockfile.find_package(lock, "gleam_stdlib", Npm)
}

// ---------------------------------------------------------------------------
// frozen 검증
// ---------------------------------------------------------------------------

pub fn verify_frozen_match_test() {
  let lock = lockfile.from_packages(sample_packages())
  let assert Ok(Nil) = lockfile.verify_frozen(lock, sample_packages())
}

pub fn verify_frozen_mismatch_test() {
  let lock = lockfile.from_packages(sample_packages())
  let modified = [
    ResolvedPackage(
      name: "gleam_stdlib",
      version: "0.45.0",
      registry: Hex,
      sha256: "new_hash",
      has_scripts: False,
      platform: Error(Nil),
      license: "",
      dev: False,
    ),
  ]
  let assert Error(lockfile.FrozenMismatch(_)) =
    lockfile.verify_frozen(lock, modified)
}

// ---------------------------------------------------------------------------
// 파싱 에러
// ---------------------------------------------------------------------------

pub fn parse_invalid_toml_test() {
  let assert Error(lockfile.ParseError(_)) = lockfile.parse("[[[ bad toml")
}

pub fn parse_missing_version_test() {
  let assert Error(lockfile.ParseError("missing version field")) =
    lockfile.parse("[[package]]\nname = \"foo\"\n")
}

// ---------------------------------------------------------------------------
// [[package]] TOML array-of-tables 지원 확인
// ---------------------------------------------------------------------------

pub fn parse_array_of_tables_test() {
  let content =
    "version = 1

[[package]]
name = \"alpha\"
registry = \"hex\"
sha256 = \"aaa\"
version = \"1.0.0\"

[[package]]
name = \"beta\"
registry = \"npm\"
sha256 = \"bbb\"
version = \"2.0.0\"
"
  let assert Ok(lock) = lockfile.parse(content)
  assert list.length(lock.packages) == 2
  let assert [first, second] = lock.packages
  assert first.name == "alpha"
  assert second.name == "beta"
  assert second.registry == Npm
}

// ---------------------------------------------------------------------------
// config-fingerprint round-trip
// ---------------------------------------------------------------------------

pub fn encode_parse_fingerprint_roundtrip_test() {
  let lock =
    lockfile.from_packages_with_fingerprint(sample_packages(), "abc123def456")
  let encoded = lockfile.encode(lock)
  let assert Ok(parsed) = lockfile.parse(encoded)
  assert parsed.config_fingerprint == Ok("abc123def456")
}

pub fn parse_legacy_lock_without_fingerprint_test() {
  let content =
    "version = 1

[[package]]
name = \"alpha\"
registry = \"hex\"
sha256 = \"aaa\"
version = \"1.0.0\"
"
  let assert Ok(lock) = lockfile.parse(content)
  assert lock.config_fingerprint == Error(Nil)
}

pub fn from_packages_has_no_fingerprint_test() {
  let lock = lockfile.from_packages(sample_packages())
  assert lock.config_fingerprint == Error(Nil)
}

pub fn from_packages_with_fingerprint_has_fingerprint_test() {
  let lock = lockfile.from_packages_with_fingerprint(sample_packages(), "fp123")
  assert lock.config_fingerprint == Ok("fp123")
}

// ---------------------------------------------------------------------------
// lockfile 버전 마이그레이션
// ---------------------------------------------------------------------------

pub fn parse_v1_lock_migrates_to_current_test() {
  let content =
    "version = 1\n\n[[package]]\nname = \"a\"\nregistry = \"hex\"\nsha256 = \"x\"\nversion = \"1.0.0\"\n"
  let assert Ok(lock) = lockfile.parse(content)
  // v1 lockfile → 현재 버전으로 마이그레이션
  assert lock.version == lockfile.lock_version
}

pub fn parse_v2_lock_unchanged_test() {
  let content =
    "version = 2\n\n[[package]]\nname = \"a\"\nregistry = \"hex\"\nsha256 = \"x\"\nversion = \"1.0.0\"\n"
  let assert Ok(lock) = lockfile.parse(content)
  assert lock.version == 2
}

pub fn parse_future_version_fails_test() {
  let content =
    "version = 99\n\n[[package]]\nname = \"a\"\nregistry = \"hex\"\nsha256 = \"x\"\nversion = \"1.0.0\"\n"
  let assert Error(lockfile.UnsupportedLockVersion(99, _)) =
    lockfile.parse(content)
}

pub fn parse_v1_with_dev_field_preserves_dev_test() {
  let content =
    "version = 1\n\n[[package]]\ndev = true\nname = \"a\"\nregistry = \"hex\"\nsha256 = \"x\"\nversion = \"1.0.0\"\n"
  let assert Ok(lock) = lockfile.parse(content)
  let assert [pkg] = lock.packages
  assert pkg.dev == True
}

pub fn parse_v1_without_dev_defaults_false_test() {
  let content =
    "version = 1\n\n[[package]]\nname = \"a\"\nregistry = \"hex\"\nsha256 = \"x\"\nversion = \"1.0.0\"\n"
  let assert Ok(lock) = lockfile.parse(content)
  let assert [pkg] = lock.packages
  assert pkg.dev == False
}

pub fn from_packages_uses_current_version_test() {
  let lock = lockfile.from_packages([])
  assert lock.version == lockfile.lock_version
}

pub fn encode_uses_current_version_test() {
  let lock = lockfile.from_packages([])
  let encoded = lockfile.encode(lock)
  assert string.contains(encoded, "version = 2")
}

// ---------------------------------------------------------------------------
// merge conflict 감지
// ---------------------------------------------------------------------------

pub fn has_merge_conflicts_detects_markers_test() {
  let content =
    "version = 2\n<<<<<<< HEAD\nconfig-fingerprint = \"abc\"\n=======\nconfig-fingerprint = \"def\"\n>>>>>>> feature\n"
  assert lockfile.has_merge_conflicts(content) == True
}

pub fn has_merge_conflicts_clean_file_test() {
  let content = "version = 2\nconfig-fingerprint = \"abc\"\n"
  assert lockfile.has_merge_conflicts(content) == False
}

pub fn strip_conflict_markers_extracts_before_test() {
  let content =
    "version = 2\n<<<<<<< HEAD\nstuff\n=======\nother\n>>>>>>> branch\n"
  let stripped = lockfile.strip_conflict_markers(content)
  assert string.contains(stripped, "version = 2")
  assert !string.contains(stripped, "<<<<<<<")
}

pub fn strip_conflict_markers_no_markers_test() {
  let content = "version = 2\nclean content\n"
  assert lockfile.strip_conflict_markers(content) == content
}
