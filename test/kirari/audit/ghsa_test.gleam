import gleeunit/should
import kirari/audit/ghsa

// ---------------------------------------------------------------------------
// normalize_ghsa_range
// ---------------------------------------------------------------------------

pub fn normalize_comma_separated_test() {
  ghsa.normalize_ghsa_range(">= 1.0.0, < 1.7.14")
  |> should.equal(">= 1.0.0 and < 1.7.14")
}

pub fn normalize_comma_no_space_test() {
  ghsa.normalize_ghsa_range(">= 1.0,< 2.0")
  |> should.equal(">= 1.0.0 and < 2.0.0")
}

pub fn normalize_single_bound_test() {
  ghsa.normalize_ghsa_range("< 2.0")
  |> should.equal("< 2.0.0")
}

pub fn normalize_three_part_unchanged_test() {
  ghsa.normalize_ghsa_range(">= 1.0.0 and < 2.0.0")
  |> should.equal(">= 1.0.0 and < 2.0.0")
}

pub fn normalize_single_major_test() {
  ghsa.normalize_ghsa_range("< 3")
  |> should.equal("< 3.0.0")
}

pub fn normalize_complex_range_test() {
  ghsa.normalize_ghsa_range(">= 1.0, < 1.5, >= 2.0, < 2.3")
  |> should.equal(">= 1.0.0 and < 1.5.0 and >= 2.0.0 and < 2.3.0")
}
