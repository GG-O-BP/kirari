import gleam/list
import gleam/string
import gleeunit/should
import kirari/audit.{
  type Advisory, Advisory, AuditResult, Critical, High, Low, Moderate, Unknown,
  Vulnerability,
}
import kirari/types.{type ResolvedPackage, Hex, Npm, ResolvedPackage}

// ---------------------------------------------------------------------------
// 테스트 헬퍼
// ---------------------------------------------------------------------------

fn hex_pkg(name: String, version: String) -> ResolvedPackage {
  ResolvedPackage(
    name: name,
    version: version,
    registry: Hex,
    sha256: "abc123",
    has_scripts: False,
    platform: Error(Nil),
    license: "MIT",
    dev: False,
    package_name: Error(Nil),
  )
}

fn npm_pkg(name: String, version: String) -> ResolvedPackage {
  ResolvedPackage(
    name: name,
    version: version,
    registry: Npm,
    sha256: "def456",
    has_scripts: False,
    platform: Error(Nil),
    license: "MIT",
    dev: False,
    package_name: Error(Nil),
  )
}

fn hex_advisory(
  name: String,
  range: String,
  severity: audit.Severity,
) -> Advisory {
  Advisory(
    id: "GHSA-test-0001",
    aliases: ["CVE-2024-0001"],
    summary: "Test vulnerability in " <> name,
    severity: severity,
    vulnerable_range: range,
    patched_versions: ">= 2.0.0",
    url: "https://github.com/advisories/GHSA-test-0001",
    package_name: name,
    registry: Hex,
  )
}

fn npm_advisory(
  name: String,
  range: String,
  severity: audit.Severity,
) -> Advisory {
  Advisory(
    id: "GHSA-test-0002",
    aliases: ["CVE-2024-0002"],
    summary: "Test vulnerability in " <> name,
    severity: severity,
    vulnerable_range: range,
    patched_versions: ">=2.0.0",
    url: "https://github.com/advisories/GHSA-test-0002",
    package_name: name,
    registry: Npm,
  )
}

// ---------------------------------------------------------------------------
// severity 변환
// ---------------------------------------------------------------------------

pub fn severity_from_string_test() {
  audit.severity_from_string("critical") |> should.equal(Ok(Critical))
  audit.severity_from_string("high") |> should.equal(Ok(High))
  audit.severity_from_string("moderate") |> should.equal(Ok(Moderate))
  audit.severity_from_string("medium") |> should.equal(Ok(Moderate))
  audit.severity_from_string("low") |> should.equal(Ok(Low))
  audit.severity_from_string("unknown") |> should.equal(Ok(Unknown))
  audit.severity_from_string("CRITICAL") |> should.equal(Ok(Critical))
  audit.severity_from_string("invalid") |> should.equal(Error(Nil))
}

pub fn severity_to_int_ordering_test() {
  should.be_true(audit.severity_to_int(Critical) > audit.severity_to_int(High))
  should.be_true(audit.severity_to_int(High) > audit.severity_to_int(Moderate))
  should.be_true(audit.severity_to_int(Moderate) > audit.severity_to_int(Low))
  should.be_true(audit.severity_to_int(Low) > audit.severity_to_int(Unknown))
}

pub fn severity_roundtrip_test() {
  [Critical, High, Moderate, Low, Unknown]
  |> list.each(fn(s) {
    audit.severity_to_string(s)
    |> audit.severity_from_string
    |> should.equal(Ok(s))
  })
}

// ---------------------------------------------------------------------------
// match_package
// ---------------------------------------------------------------------------

pub fn match_hex_vulnerable_test() {
  let pkg = hex_pkg("phoenix", "1.5.0")
  let adv = hex_advisory("phoenix", ">= 1.0.0 and < 2.0.0", High)
  let vulns = audit.match_package(pkg, [adv])
  should.equal(list.length(vulns), 1)
}

pub fn match_hex_not_vulnerable_test() {
  let pkg = hex_pkg("phoenix", "2.1.0")
  let adv = hex_advisory("phoenix", ">= 1.0.0 and < 2.0.0", High)
  let vulns = audit.match_package(pkg, [adv])
  should.equal(vulns, [])
}

pub fn match_npm_vulnerable_test() {
  let pkg = npm_pkg("lodash", "4.17.20")
  let adv = npm_advisory("lodash", "<4.17.21", Critical)
  let vulns = audit.match_package(pkg, [adv])
  should.equal(list.length(vulns), 1)
}

pub fn match_npm_not_vulnerable_test() {
  let pkg = npm_pkg("lodash", "4.17.21")
  let adv = npm_advisory("lodash", "<4.17.21", Critical)
  let vulns = audit.match_package(pkg, [adv])
  should.equal(vulns, [])
}

pub fn match_wrong_package_name_test() {
  let pkg = hex_pkg("plug", "1.5.0")
  let adv = hex_advisory("phoenix", ">= 1.0.0 and < 2.0.0", High)
  let vulns = audit.match_package(pkg, [adv])
  should.equal(vulns, [])
}

pub fn match_wrong_registry_test() {
  // npm advisory는 hex 패키지와 매칭하지 않음
  let pkg = hex_pkg("lodash", "4.17.20")
  let adv = npm_advisory("lodash", "<4.17.21", Critical)
  let vulns = audit.match_package(pkg, [adv])
  should.equal(vulns, [])
}

pub fn match_case_insensitive_name_test() {
  let pkg = hex_pkg("Phoenix", "1.5.0")
  let adv = hex_advisory("phoenix", ">= 1.0.0 and < 2.0.0", High)
  let vulns = audit.match_package(pkg, [adv])
  should.equal(list.length(vulns), 1)
}

pub fn match_boundary_version_test() {
  // 정확히 상한 경계에 있는 버전은 취약하지 않음
  let pkg = hex_pkg("phoenix", "2.0.0")
  let adv = hex_advisory("phoenix", ">= 1.0.0 and < 2.0.0", High)
  let vulns = audit.match_package(pkg, [adv])
  should.equal(vulns, [])
}

pub fn match_boundary_lower_version_test() {
  // 정확히 하한 경계에 있는 버전은 취약
  let pkg = hex_pkg("phoenix", "1.0.0")
  let adv = hex_advisory("phoenix", ">= 1.0.0 and < 2.0.0", High)
  let vulns = audit.match_package(pkg, [adv])
  should.equal(list.length(vulns), 1)
}

// ---------------------------------------------------------------------------
// filter_by_severity
// ---------------------------------------------------------------------------

pub fn filter_by_severity_test() {
  let vulns = [
    Vulnerability(
      "a",
      "1.0.0",
      Hex,
      hex_advisory("a", ">= 1.0.0 and < 2.0.0", Critical),
    ),
    Vulnerability(
      "b",
      "1.0.0",
      Hex,
      hex_advisory("b", ">= 1.0.0 and < 2.0.0", Low),
    ),
    Vulnerability(
      "c",
      "1.0.0",
      Hex,
      hex_advisory("c", ">= 1.0.0 and < 2.0.0", High),
    ),
  ]
  // threshold = High → Critical + High만
  let filtered = audit.filter_by_severity(vulns, High)
  should.equal(list.length(filtered), 2)
}

pub fn filter_by_severity_all_pass_test() {
  let vulns = [
    Vulnerability(
      "a",
      "1.0.0",
      Hex,
      hex_advisory("a", ">= 1.0.0 and < 2.0.0", Critical),
    ),
  ]
  let filtered = audit.filter_by_severity(vulns, Low)
  should.equal(list.length(filtered), 1)
}

// ---------------------------------------------------------------------------
// filter_ignored
// ---------------------------------------------------------------------------

pub fn filter_ignored_by_id_test() {
  let adv =
    Advisory(
      id: "GHSA-xxxx-xxxx-xxxx",
      aliases: ["CVE-2024-1234"],
      summary: "test",
      severity: High,
      vulnerable_range: ">= 1.0.0 and < 2.0.0",
      patched_versions: ">= 2.0.0",
      url: "",
      package_name: "pkg",
      registry: Hex,
    )
  let vulns = [Vulnerability("pkg", "1.0.0", Hex, adv)]
  let filtered = audit.filter_ignored(vulns, ["GHSA-xxxx-xxxx-xxxx"])
  should.equal(filtered, [])
}

pub fn filter_ignored_by_alias_test() {
  let adv =
    Advisory(
      id: "GHSA-xxxx-xxxx-xxxx",
      aliases: ["CVE-2024-1234"],
      summary: "test",
      severity: High,
      vulnerable_range: ">= 1.0.0 and < 2.0.0",
      patched_versions: ">= 2.0.0",
      url: "",
      package_name: "pkg",
      registry: Hex,
    )
  let vulns = [Vulnerability("pkg", "1.0.0", Hex, adv)]
  let filtered = audit.filter_ignored(vulns, ["CVE-2024-1234"])
  should.equal(filtered, [])
}

pub fn filter_ignored_case_insensitive_test() {
  let adv =
    Advisory(
      id: "GHSA-xxxx-xxxx-xxxx",
      aliases: [],
      summary: "test",
      severity: High,
      vulnerable_range: ">= 1.0.0 and < 2.0.0",
      patched_versions: ">= 2.0.0",
      url: "",
      package_name: "pkg",
      registry: Hex,
    )
  let vulns = [Vulnerability("pkg", "1.0.0", Hex, adv)]
  let filtered = audit.filter_ignored(vulns, ["ghsa-xxxx-xxxx-xxxx"])
  should.equal(filtered, [])
}

pub fn filter_ignored_no_match_test() {
  let adv =
    Advisory(
      id: "GHSA-xxxx-xxxx-xxxx",
      aliases: [],
      summary: "test",
      severity: High,
      vulnerable_range: ">= 1.0.0 and < 2.0.0",
      patched_versions: ">= 2.0.0",
      url: "",
      package_name: "pkg",
      registry: Hex,
    )
  let vulns = [Vulnerability("pkg", "1.0.0", Hex, adv)]
  let filtered = audit.filter_ignored(vulns, ["GHSA-other-id"])
  should.equal(list.length(filtered), 1)
}

// ---------------------------------------------------------------------------
// check (통합)
// ---------------------------------------------------------------------------

pub fn check_full_flow_test() {
  let packages = [
    hex_pkg("phoenix", "1.5.0"),
    hex_pkg("plug", "1.14.0"),
    npm_pkg("lodash", "4.17.20"),
  ]
  let advisories = [
    hex_advisory("phoenix", ">= 1.0.0 and < 2.0.0", High),
    npm_advisory("lodash", "<4.17.21", Critical),
  ]
  let result = audit.check(packages, advisories, Low, [])
  should.equal(list.length(result.vulnerabilities), 2)
  should.equal(result.packages_scanned, 3)
  should.equal(result.advisories_fetched, 2)
  // Critical이 먼저 와야 함 (심각도 내림차순)
  case result.vulnerabilities {
    [first, ..] -> should.equal(first.advisory.severity, Critical)
    _ -> should.fail()
  }
}

pub fn check_empty_packages_test() {
  let result = audit.check([], [], Low, [])
  should.equal(result.vulnerabilities, [])
  should.equal(result.packages_scanned, 0)
}

pub fn check_no_matching_advisories_test() {
  let packages = [hex_pkg("gleam_stdlib", "0.44.0")]
  let advisories = [hex_advisory("phoenix", ">= 1.0.0 and < 2.0.0", High)]
  let result = audit.check(packages, advisories, Low, [])
  should.equal(result.vulnerabilities, [])
}

pub fn check_with_ignore_test() {
  let packages = [hex_pkg("phoenix", "1.5.0")]
  let advisories = [hex_advisory("phoenix", ">= 1.0.0 and < 2.0.0", High)]
  let result = audit.check(packages, advisories, Low, ["GHSA-test-0001"])
  should.equal(result.vulnerabilities, [])
}

pub fn check_with_severity_threshold_test() {
  let packages = [hex_pkg("phoenix", "1.5.0")]
  let advisories = [hex_advisory("phoenix", ">= 1.0.0 and < 2.0.0", Low)]
  let result = audit.check(packages, advisories, High, [])
  should.equal(result.vulnerabilities, [])
}

// ---------------------------------------------------------------------------
// count_by_severity
// ---------------------------------------------------------------------------

pub fn count_by_severity_test() {
  let vulns = [
    Vulnerability(
      "a",
      "1.0.0",
      Hex,
      hex_advisory("a", ">= 1.0.0 and < 2.0.0", Critical),
    ),
    Vulnerability(
      "b",
      "1.0.0",
      Hex,
      hex_advisory("b", ">= 1.0.0 and < 2.0.0", Critical),
    ),
    Vulnerability(
      "c",
      "1.0.0",
      Hex,
      hex_advisory("c", ">= 1.0.0 and < 2.0.0", Low),
    ),
  ]
  let counts = audit.count_by_severity(vulns)
  should.equal(counts, [#(Critical, 2), #(Low, 1)])
}

// ---------------------------------------------------------------------------
// to_json
// ---------------------------------------------------------------------------

pub fn to_json_test() {
  let result =
    AuditResult(
      vulnerabilities: [],
      packages_scanned: 5,
      advisories_fetched: 10,
    )
  let json_str = audit.to_json(result)
  should.be_true(string.contains(json_str, "\"packages_scanned\":5"))
  should.be_true(string.contains(json_str, "\"advisories_fetched\":10"))
  should.be_true(string.contains(json_str, "\"vulnerabilities\":[]"))
}

pub fn to_json_with_vulns_test() {
  let adv =
    Advisory(
      id: "GHSA-xxxx",
      aliases: ["CVE-2024-1234"],
      summary: "Test vuln",
      severity: High,
      vulnerable_range: ">= 1.0.0 and < 2.0.0",
      patched_versions: ">= 2.0.0",
      url: "https://example.com",
      package_name: "pkg",
      registry: Hex,
    )
  let result =
    AuditResult(
      vulnerabilities: [Vulnerability("pkg", "1.5.0", Hex, adv)],
      packages_scanned: 1,
      advisories_fetched: 1,
    )
  let json_str = audit.to_json(result)
  should.be_true(string.contains(json_str, "\"advisory_id\":\"GHSA-xxxx\""))
  should.be_true(string.contains(json_str, "\"severity\":\"high\""))
  should.be_true(string.contains(json_str, "\"package\":\"pkg\""))
}

// ---------------------------------------------------------------------------
// merge_advisories (중복 제거)
// ---------------------------------------------------------------------------

pub fn merge_deduplicates_test() {
  let adv1 = hex_advisory("phoenix", ">= 1.0.0 and < 2.0.0", High)
  let adv2 = hex_advisory("phoenix", ">= 1.0.0 and < 2.0.0", High)
  let merged = audit.merge_advisories([[adv1], [adv2]])
  // 같은 ID + 같은 package_name → 1개로 합쳐짐
  should.equal(list.length(merged), 1)
}

pub fn merge_keeps_different_packages_test() {
  let adv1 = hex_advisory("phoenix", ">= 1.0.0 and < 2.0.0", High)
  let adv2 = hex_advisory("plug", ">= 1.0.0 and < 2.0.0", High)
  let merged = audit.merge_advisories([[adv1], [adv2]])
  should.equal(list.length(merged), 2)
}
