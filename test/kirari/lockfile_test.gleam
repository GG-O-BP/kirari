import gleam/list
import gleam/option.{None, Some}
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
    ),
    ResolvedPackage(
      name: "highlight.js",
      version: "11.9.0",
      registry: Npm,
      sha256: "def456",
      has_scripts: False,
      platform: Error(Nil),
    ),
    ResolvedPackage(
      name: "gleam_json",
      version: "3.0.0",
      registry: Hex,
      sha256: "ghi789",
      has_scripts: False,
      platform: Error(Nil),
    ),
  ]
}

// ---------------------------------------------------------------------------
// from_packages 정렬
// ---------------------------------------------------------------------------

pub fn from_packages_sorts_alphabetically_test() {
  let lock = lockfile.from_packages(sample_packages())
  assert lock.version == 1
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
  assert parsed.version == 1
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
