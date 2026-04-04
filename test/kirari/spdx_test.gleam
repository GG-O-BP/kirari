import gleam/list
import gleam/string
import gleeunit/should
import kirari/spdx

// ---------------------------------------------------------------------------
// parse — 단일 라이선스
// ---------------------------------------------------------------------------

pub fn parse_simple_license_test() {
  spdx.parse("MIT")
  |> should.be_ok
  |> spdx.to_string
  |> should.equal("MIT")
}

pub fn parse_apache_test() {
  spdx.parse("Apache-2.0")
  |> should.be_ok
  |> spdx.to_string
  |> should.equal("Apache-2.0")
}

pub fn parse_gpl_test() {
  spdx.parse("GPL-3.0-only")
  |> should.be_ok
  |> spdx.to_string
  |> should.equal("GPL-3.0-only")
}

pub fn parse_license_ref_test() {
  spdx.parse("LicenseRef-custom")
  |> should.be_ok
  |> spdx.to_string
  |> should.equal("LicenseRef-custom")
}

// ---------------------------------------------------------------------------
// parse — 복합 표현식
// ---------------------------------------------------------------------------

pub fn parse_or_test() {
  spdx.parse("MIT OR Apache-2.0")
  |> should.be_ok
  |> spdx.to_string
  |> should.equal("MIT OR Apache-2.0")
}

pub fn parse_and_test() {
  spdx.parse("MIT AND BSD-3-Clause")
  |> should.be_ok
  |> spdx.to_string
  |> should.equal("MIT AND BSD-3-Clause")
}

pub fn parse_with_test() {
  spdx.parse("GPL-3.0-only WITH Classpath-exception-2.0")
  |> should.be_ok
  |> spdx.to_string
  |> should.equal("GPL-3.0-only WITH Classpath-exception-2.0")
}

pub fn parse_nested_or_and_test() {
  spdx.parse("(MIT OR Apache-2.0) AND BSD-3-Clause")
  |> should.be_ok
  |> spdx.to_string
  |> should.equal("(MIT OR Apache-2.0) AND BSD-3-Clause")
}

pub fn parse_precedence_and_before_or_test() {
  // AND binds tighter than OR
  // "MIT AND Apache-2.0 OR BSD-3-Clause" = "(MIT AND Apache-2.0) OR BSD-3-Clause"
  spdx.parse("MIT AND Apache-2.0 OR BSD-3-Clause")
  |> should.be_ok
  |> spdx.to_string
  |> should.equal("MIT AND Apache-2.0 OR BSD-3-Clause")
}

pub fn parse_multiple_or_test() {
  spdx.parse("MIT OR Apache-2.0 OR BSD-3-Clause")
  |> should.be_ok
  |> spdx.to_string
  |> should.equal("MIT OR Apache-2.0 OR BSD-3-Clause")
}

pub fn parse_complex_nested_test() {
  spdx.parse("(MIT OR Apache-2.0) AND (BSD-3-Clause OR ISC)")
  |> should.be_ok
  |> spdx.to_string
  |> should.equal("(MIT OR Apache-2.0) AND (BSD-3-Clause OR ISC)")
}

// ---------------------------------------------------------------------------
// parse — 에러
// ---------------------------------------------------------------------------

pub fn parse_empty_string_test() {
  spdx.parse("")
  |> should.be_error
}

pub fn parse_only_spaces_test() {
  spdx.parse("   ")
  |> should.be_error
}

pub fn parse_unbalanced_paren_test() {
  spdx.parse("(MIT OR Apache-2.0")
  |> should.be_error
}

pub fn parse_dangling_operator_test() {
  spdx.parse("MIT OR")
  |> should.be_error
}

pub fn parse_leading_operator_test() {
  spdx.parse("AND MIT")
  |> should.be_error
}

// ---------------------------------------------------------------------------
// satisfies — 허용 목록
// ---------------------------------------------------------------------------

pub fn satisfies_simple_match_test() {
  let assert Ok(expr) = spdx.parse("MIT")
  spdx.satisfies(expr, ["MIT"])
  |> should.be_true
}

pub fn satisfies_simple_no_match_test() {
  let assert Ok(expr) = spdx.parse("GPL-3.0-only")
  spdx.satisfies(expr, ["MIT"])
  |> should.be_false
}

pub fn satisfies_case_insensitive_test() {
  let assert Ok(expr) = spdx.parse("MIT")
  spdx.satisfies(expr, ["mit"])
  |> should.be_true
}

pub fn satisfies_or_one_branch_test() {
  let assert Ok(expr) = spdx.parse("MIT OR GPL-3.0-only")
  spdx.satisfies(expr, ["MIT"])
  |> should.be_true
}

pub fn satisfies_and_both_required_test() {
  let assert Ok(expr) = spdx.parse("MIT AND Apache-2.0")
  spdx.satisfies(expr, ["MIT"])
  |> should.be_false
}

pub fn satisfies_and_both_present_test() {
  let assert Ok(expr) = spdx.parse("MIT AND Apache-2.0")
  spdx.satisfies(expr, ["MIT", "Apache-2.0"])
  |> should.be_true
}

pub fn satisfies_with_base_only_test() {
  let assert Ok(expr) = spdx.parse("GPL-3.0-only WITH Classpath-exception-2.0")
  spdx.satisfies(expr, ["GPL-3.0-only"])
  |> should.be_true
}

pub fn satisfies_license_ref_in_allow_test() {
  let assert Ok(expr) = spdx.parse("LicenseRef-custom")
  spdx.satisfies(expr, ["LicenseRef-custom"])
  |> should.be_true
}

pub fn satisfies_license_ref_not_in_allow_test() {
  let assert Ok(expr) = spdx.parse("LicenseRef-custom")
  spdx.satisfies(expr, ["MIT"])
  |> should.be_false
}

// ---------------------------------------------------------------------------
// violates — 금지 목록
// ---------------------------------------------------------------------------

pub fn violates_simple_denied_test() {
  let assert Ok(expr) = spdx.parse("GPL-3.0-only")
  spdx.violates(expr, ["GPL-3.0-only"])
  |> should.be_true
}

pub fn violates_simple_not_denied_test() {
  let assert Ok(expr) = spdx.parse("MIT")
  spdx.violates(expr, ["GPL-3.0-only"])
  |> should.be_false
}

pub fn violates_or_one_branch_safe_test() {
  // "MIT OR GPL-3.0" — MIT is not denied, so user can pick MIT → not violated
  let assert Ok(expr) = spdx.parse("MIT OR GPL-3.0-only")
  spdx.violates(expr, ["GPL-3.0-only"])
  |> should.be_false
}

pub fn violates_or_all_denied_test() {
  let assert Ok(expr) = spdx.parse("GPL-3.0-only OR AGPL-3.0-only")
  spdx.violates(expr, ["GPL-3.0-only", "AGPL-3.0-only"])
  |> should.be_true
}

pub fn violates_and_one_denied_test() {
  let assert Ok(expr) = spdx.parse("MIT AND GPL-3.0-only")
  spdx.violates(expr, ["GPL-3.0-only"])
  |> should.be_true
}

pub fn violates_case_insensitive_test() {
  let assert Ok(expr) = spdx.parse("GPL-3.0-only")
  spdx.violates(expr, ["gpl-3.0-only"])
  |> should.be_true
}

// ---------------------------------------------------------------------------
// extract_ids
// ---------------------------------------------------------------------------

pub fn extract_ids_simple_test() {
  let assert Ok(expr) = spdx.parse("MIT")
  spdx.extract_ids(expr)
  |> should.equal(["MIT"])
}

pub fn extract_ids_compound_test() {
  let assert Ok(expr) = spdx.parse("MIT OR Apache-2.0")
  spdx.extract_ids(expr)
  |> list.sort(string.compare)
  |> should.equal(["Apache-2.0", "MIT"])
}

pub fn extract_ids_complex_test() {
  let assert Ok(expr) = spdx.parse("(MIT AND BSD-3-Clause) OR Apache-2.0")
  spdx.extract_ids(expr)
  |> list.sort(string.compare)
  |> should.equal(["Apache-2.0", "BSD-3-Clause", "MIT"])
}

pub fn extract_ids_with_test() {
  let assert Ok(expr) = spdx.parse("GPL-3.0-only WITH Classpath-exception-2.0")
  spdx.extract_ids(expr)
  |> should.equal(["GPL-3.0-only"])
}

pub fn extract_ids_license_ref_test() {
  let assert Ok(expr) = spdx.parse("LicenseRef-custom OR MIT")
  spdx.extract_ids(expr)
  |> list.sort(string.compare)
  |> should.equal(["LicenseRef-custom", "MIT"])
}
