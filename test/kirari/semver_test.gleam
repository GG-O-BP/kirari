import gleam/order
import gleeunit
import kirari/semver

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// parse_version
// ---------------------------------------------------------------------------

pub fn parse_version_basic_test() {
  let assert Ok(v) = semver.parse_version("1.2.3")
  assert semver.to_string(v) == "1.2.3"
}

pub fn parse_version_prerelease_test() {
  let assert Ok(v) = semver.parse_version("1.0.0-rc.1")
  assert semver.to_string(v) == "1.0.0-rc.1"
}

pub fn parse_version_v_prefix_test() {
  let assert Ok(v) = semver.parse_version("v2.0.0")
  assert semver.to_string(v) == "2.0.0"
}

pub fn parse_version_two_parts_test() {
  let assert Ok(v) = semver.parse_version("1.2")
  assert semver.to_string(v) == "1.2.0"
}

pub fn parse_version_invalid_test() {
  let assert Error(_) = semver.parse_version("abc")
  let assert Error(_) = semver.parse_version("1.2.3.4")
}

// ---------------------------------------------------------------------------
// compare
// ---------------------------------------------------------------------------

pub fn compare_basic_test() {
  let assert Ok(a) = semver.parse_version("1.0.0")
  let assert Ok(b) = semver.parse_version("1.0.1")
  assert semver.compare(a, b) == order.Lt
  assert semver.compare(b, a) == order.Gt
  assert semver.compare(a, a) == order.Eq
}

pub fn compare_major_test() {
  let assert Ok(a) = semver.parse_version("1.9.9")
  let assert Ok(b) = semver.parse_version("2.0.0")
  assert semver.compare(a, b) == order.Lt
}

pub fn compare_prerelease_test() {
  let assert Ok(release) = semver.parse_version("1.0.0")
  let assert Ok(pre) = semver.parse_version("1.0.0-rc.1")
  // pre-release < release
  assert semver.compare(pre, release) == order.Lt
}

// ---------------------------------------------------------------------------
// Hex 제약 조건
// ---------------------------------------------------------------------------

pub fn hex_constraint_and_test() {
  let assert Ok(c) = semver.parse_hex_constraint(">= 0.44.0 and < 2.0.0")
  let assert Ok(v1) = semver.parse_version("0.44.0")
  let assert Ok(v2) = semver.parse_version("1.5.0")
  let assert Ok(v3) = semver.parse_version("2.0.0")
  let assert Ok(v4) = semver.parse_version("0.43.0")
  assert semver.satisfies(v1, c) == True
  assert semver.satisfies(v2, c) == True
  assert semver.satisfies(v3, c) == False
  assert semver.satisfies(v4, c) == False
}

pub fn hex_constraint_exact_test() {
  let assert Ok(c) = semver.parse_hex_constraint("== 1.0.0")
  let assert Ok(v1) = semver.parse_version("1.0.0")
  let assert Ok(v2) = semver.parse_version("1.0.1")
  assert semver.satisfies(v1, c) == True
  assert semver.satisfies(v2, c) == False
}

pub fn hex_constraint_tilde_test() {
  let assert Ok(c) = semver.parse_hex_constraint("~> 1.2.0")
  let assert Ok(v1) = semver.parse_version("1.2.0")
  let assert Ok(v2) = semver.parse_version("1.2.9")
  let assert Ok(v3) = semver.parse_version("1.3.0")
  assert semver.satisfies(v1, c) == True
  assert semver.satisfies(v2, c) == True
  assert semver.satisfies(v3, c) == False
}

pub fn hex_constraint_empty_test() {
  let assert Ok(c) = semver.parse_hex_constraint("")
  let assert Ok(v) = semver.parse_version("99.0.0")
  assert semver.satisfies(v, c) == True
}

// ---------------------------------------------------------------------------
// npm 제약 조건
// ---------------------------------------------------------------------------

pub fn npm_caret_test() {
  let assert Ok(c) = semver.parse_npm_constraint("^11.0.0")
  let assert Ok(v1) = semver.parse_version("11.0.0")
  let assert Ok(v2) = semver.parse_version("11.9.0")
  let assert Ok(v3) = semver.parse_version("12.0.0")
  assert semver.satisfies(v1, c) == True
  assert semver.satisfies(v2, c) == True
  assert semver.satisfies(v3, c) == False
}

pub fn npm_caret_zero_major_test() {
  let assert Ok(c) = semver.parse_npm_constraint("^0.2.3")
  let assert Ok(v1) = semver.parse_version("0.2.3")
  let assert Ok(v2) = semver.parse_version("0.2.9")
  let assert Ok(v3) = semver.parse_version("0.3.0")
  assert semver.satisfies(v1, c) == True
  assert semver.satisfies(v2, c) == True
  assert semver.satisfies(v3, c) == False
}

pub fn npm_tilde_test() {
  let assert Ok(c) = semver.parse_npm_constraint("~1.2.3")
  let assert Ok(v1) = semver.parse_version("1.2.3")
  let assert Ok(v2) = semver.parse_version("1.2.9")
  let assert Ok(v3) = semver.parse_version("1.3.0")
  assert semver.satisfies(v1, c) == True
  assert semver.satisfies(v2, c) == True
  assert semver.satisfies(v3, c) == False
}

pub fn npm_range_test() {
  let assert Ok(c) = semver.parse_npm_constraint(">=1.0.0 <2.0.0")
  let assert Ok(v1) = semver.parse_version("1.0.0")
  let assert Ok(v2) = semver.parse_version("1.9.9")
  let assert Ok(v3) = semver.parse_version("2.0.0")
  assert semver.satisfies(v1, c) == True
  assert semver.satisfies(v2, c) == True
  assert semver.satisfies(v3, c) == False
}

pub fn npm_or_test() {
  let assert Ok(c) = semver.parse_npm_constraint("^1.0.0 || ^2.0.0")
  let assert Ok(v1) = semver.parse_version("1.5.0")
  let assert Ok(v2) = semver.parse_version("2.5.0")
  let assert Ok(v3) = semver.parse_version("3.0.0")
  assert semver.satisfies(v1, c) == True
  assert semver.satisfies(v2, c) == True
  assert semver.satisfies(v3, c) == False
}

pub fn npm_star_test() {
  let assert Ok(c) = semver.parse_npm_constraint("*")
  let assert Ok(v) = semver.parse_version("99.0.0")
  assert semver.satisfies(v, c) == True
}
