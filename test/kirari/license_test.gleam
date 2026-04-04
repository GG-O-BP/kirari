import gleeunit/should
import kirari/license.{
  type PackageLicense, DeniedLicense, MissingLicense, NotAllowed, PackageLicense,
  UnparsableLicense,
}
import kirari/types.{LicenseAllow, LicenseDeny, LicenseNoPolicy}

fn pkg(name: String, lic: String) -> PackageLicense {
  PackageLicense(
    name: name,
    version: "1.0.0",
    registry: "hex",
    license_expression: lic,
  )
}

// ---------------------------------------------------------------------------
// check — LicenseNoPolicy
// ---------------------------------------------------------------------------

pub fn check_no_policy_test() {
  license.check([pkg("a", "MIT"), pkg("b", "GPL-3.0-only")], LicenseNoPolicy)
  |> should.equal([])
}

// ---------------------------------------------------------------------------
// check — AllowList
// ---------------------------------------------------------------------------

pub fn check_allow_all_pass_test() {
  license.check(
    [pkg("a", "MIT"), pkg("b", "Apache-2.0")],
    LicenseAllow(["MIT", "Apache-2.0"]),
  )
  |> should.equal([])
}

pub fn check_allow_violation_test() {
  let violations =
    license.check(
      [pkg("a", "GPL-3.0-only")],
      LicenseAllow(["MIT", "Apache-2.0"]),
    )
  case violations {
    [NotAllowed(name: "a", ..)] -> Nil
    _ -> should.fail()
  }
}

pub fn check_allow_or_expression_test() {
  // "MIT OR GPL-3.0" satisfies LicenseAllow(["MIT"]) because one branch matches
  license.check([pkg("a", "MIT OR GPL-3.0-only")], LicenseAllow(["MIT"]))
  |> should.equal([])
}

pub fn check_allow_and_expression_partial_test() {
  // "MIT AND GPL-3.0" does NOT satisfy LicenseAllow(["MIT"]) — both required
  let violations =
    license.check([pkg("a", "MIT AND GPL-3.0-only")], LicenseAllow(["MIT"]))
  case violations {
    [NotAllowed(name: "a", ..)] -> Nil
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// check — DenyList
// ---------------------------------------------------------------------------

pub fn check_deny_no_violation_test() {
  license.check([pkg("a", "MIT")], LicenseDeny(["GPL-3.0-only"]))
  |> should.equal([])
}

pub fn check_deny_violation_test() {
  let violations =
    license.check([pkg("a", "GPL-3.0-only")], LicenseDeny(["GPL-3.0-only"]))
  case violations {
    [DeniedLicense(name: "a", ..)] -> Nil
    _ -> should.fail()
  }
}

pub fn check_deny_or_safe_test() {
  // "MIT OR GPL-3.0" — MIT branch is safe, so no violation
  license.check(
    [pkg("a", "MIT OR GPL-3.0-only")],
    LicenseDeny(["GPL-3.0-only"]),
  )
  |> should.equal([])
}

// ---------------------------------------------------------------------------
// check — 누락 / 파싱 실패
// ---------------------------------------------------------------------------

pub fn check_missing_license_test() {
  let violations = license.check([pkg("a", "")], LicenseAllow(["MIT"]))
  case violations {
    [MissingLicense(name: "a", ..)] -> Nil
    _ -> should.fail()
  }
}

pub fn check_unparsable_license_test() {
  let violations = license.check([pkg("a", "((invalid")], LicenseAllow(["MIT"]))
  case violations {
    [UnparsableLicense(name: "a", raw: "((invalid", ..)] -> Nil
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// group_by_license
// ---------------------------------------------------------------------------

pub fn group_by_license_test() {
  let groups =
    license.group_by_license([
      pkg("a", "MIT"),
      pkg("b", "MIT"),
      pkg("c", "Apache-2.0"),
    ])
  case groups {
    [#("Apache-2.0", [_]), #("MIT", [_, _])] -> Nil
    _ -> should.fail()
  }
}

pub fn group_by_license_empty_test() {
  license.group_by_license([])
  |> should.equal([])
}
