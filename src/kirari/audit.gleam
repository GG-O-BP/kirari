//// 취약점 감사 엔진 — advisory 매칭, 필터링, JSON 직렬화

import gleam/int
import gleam/json
import gleam/list
import gleam/order
import gleam/string
import kirari/semver
import kirari/types.{type Registry, Hex, Npm}

// ---------------------------------------------------------------------------
// ��입
// ---------------------------------------------------------------------------

/// advisory 심각도
pub type Severity {
  Critical
  High
  Moderate
  Low
  Unknown
}

/// advisory 데이터베이스에서 가져온 하나의 보안 권고
pub type Advisory {
  Advisory(
    id: String,
    aliases: List(String),
    summary: String,
    severity: Severity,
    vulnerable_range: String,
    patched_versions: String,
    url: String,
    package_name: String,
    registry: Registry,
  )
}

/// 설치된 패키지에 확인된 취약점
pub type Vulnerability {
  Vulnerability(
    package_name: String,
    installed_version: String,
    registry: Registry,
    advisory: Advisory,
  )
}

/// 감사 결과
pub type AuditResult {
  AuditResult(
    vulnerabilities: List(Vulnerability),
    packages_scanned: Int,
    advisories_fetched: Int,
  )
}

/// 감사 에러
pub type AuditError {
  AdvisoryFetchError(source: String, detail: String)
  AdvisoryParseError(source: String, detail: String)
}

// ---------------------------------------------------------------------------
// Severity 헬퍼
// ---------------------------------------------------------------------------

pub fn severity_to_int(s: Severity) -> Int {
  case s {
    Critical -> 4
    High -> 3
    Moderate -> 2
    Low -> 1
    Unknown -> 0
  }
}

pub fn severity_to_string(s: Severity) -> String {
  case s {
    Critical -> "critical"
    High -> "high"
    Moderate -> "moderate"
    Low -> "low"
    Unknown -> "unknown"
  }
}

pub fn severity_from_string(s: String) -> Result(Severity, Nil) {
  case string.lowercase(s) {
    "critical" -> Ok(Critical)
    "high" -> Ok(High)
    "moderate" | "medium" -> Ok(Moderate)
    "low" -> Ok(Low)
    "unknown" -> Ok(Unknown)
    _ -> Error(Nil)
  }
}

fn compare_severity(a: Severity, b: Severity) -> order.Order {
  int.compare(severity_to_int(a), severity_to_int(b))
}

// ---------------------------------------------------------------------------
// 매칭 엔진
// ---------------------------------------------------------------------------

/// 패키지 목록과 advisory 목록을 대조하여 감사 결과 반환
pub fn check(
  packages: List(types.ResolvedPackage),
  advisories: List(Advisory),
  threshold: Severity,
  ignore_ids: List(String),
) -> AuditResult {
  let vulns =
    list.flat_map(packages, fn(pkg) { match_package(pkg, advisories) })
  let filtered =
    vulns
    |> filter_by_severity(threshold)
    |> filter_ignored(ignore_ids)
    |> sort_vulnerabilities
  AuditResult(
    vulnerabilities: filtered,
    packages_scanned: list.length(packages),
    advisories_fetched: list.length(advisories),
  )
}

/// 단일 패키지를 advisory 목록과 대조
pub fn match_package(
  pkg: types.ResolvedPackage,
  advisories: List(Advisory),
) -> List(Vulnerability) {
  let pkg_name_lower = string.lowercase(pkg.name)
  let matching_advisories =
    list.filter(advisories, fn(a) {
      string.lowercase(a.package_name) == pkg_name_lower
      && a.registry == pkg.registry
    })
  case semver.parse_version(pkg.version) {
    Error(_) -> []
    Ok(version) ->
      list.filter_map(matching_advisories, fn(a) {
        let constraint_result = case a.registry {
          Hex -> semver.parse_hex_constraint(a.vulnerable_range)
          Npm -> semver.parse_npm_constraint(a.vulnerable_range)
        }
        case constraint_result {
          Ok(constraint) ->
            case semver.satisfies(version, constraint) {
              True ->
                Ok(Vulnerability(
                  package_name: pkg.name,
                  installed_version: pkg.version,
                  registry: pkg.registry,
                  advisory: a,
                ))
              False -> Error(Nil)
            }
          Error(_) -> Error(Nil)
        }
      })
  }
}

/// severity 임계값 이상만 필터
pub fn filter_by_severity(
  vulns: List(Vulnerability),
  threshold: Severity,
) -> List(Vulnerability) {
  let threshold_int = severity_to_int(threshold)
  list.filter(vulns, fn(v) {
    severity_to_int(v.advisory.severity) >= threshold_int
  })
}

/// 무시 목록의 ID/alias와 매칭되는 항목 제거
pub fn filter_ignored(
  vulns: List(Vulnerability),
  ignore_ids: List(String),
) -> List(Vulnerability) {
  case ignore_ids {
    [] -> vulns
    _ -> {
      let lower_ids = list.map(ignore_ids, string.lowercase)
      list.filter(vulns, fn(v) {
        let id_lower = string.lowercase(v.advisory.id)
        let alias_lowers = list.map(v.advisory.aliases, string.lowercase)
        let all_ids = [id_lower, ..alias_lowers]
        !list.any(all_ids, fn(aid) { list.contains(lower_ids, aid) })
      })
    }
  }
}

fn sort_vulnerabilities(vulns: List(Vulnerability)) -> List(Vulnerability) {
  list.sort(vulns, fn(a, b) {
    case compare_severity(b.advisory.severity, a.advisory.severity) {
      order.Eq -> string.compare(a.package_name, b.package_name)
      other -> other
    }
  })
}

// ---------------------------------------------------------------------------
// severity 집계
// ---------------------------------------------------------------------------

/// severity별 취약점 수 집계 (출력용)
pub fn count_by_severity(vulns: List(Vulnerability)) -> List(#(Severity, Int)) {
  let severities = [Critical, High, Moderate, Low, Unknown]
  list.filter_map(severities, fn(s) {
    let count = list.count(vulns, fn(v) { v.advisory.severity == s })
    case count > 0 {
      True -> Ok(#(s, count))
      False -> Error(Nil)
    }
  })
}

// ---------------------------------------------------------------------------
// JSON 직렬화
// ---------------------------------------------------------------------------

pub fn to_json(result: AuditResult) -> String {
  json.object([
    #("packages_scanned", json.int(result.packages_scanned)),
    #("advisories_fetched", json.int(result.advisories_fetched)),
    #(
      "vulnerabilities",
      json.array(result.vulnerabilities, vulnerability_to_json),
    ),
  ])
  |> json.to_string
}

fn vulnerability_to_json(v: Vulnerability) -> json.Json {
  json.object([
    #("package", json.string(v.package_name)),
    #("version", json.string(v.installed_version)),
    #("registry", json.string(types.registry_to_string(v.registry))),
    #("advisory_id", json.string(v.advisory.id)),
    #("aliases", json.array(v.advisory.aliases, json.string)),
    #("severity", json.string(severity_to_string(v.advisory.severity))),
    #("summary", json.string(v.advisory.summary)),
    #("vulnerable_range", json.string(v.advisory.vulnerable_range)),
    #("patched_versions", json.string(v.advisory.patched_versions)),
    #("url", json.string(v.advisory.url)),
  ])
}

// ---------------------------------------------------------------------------
// advisory 병합 헬퍼 (ghsa + npm audit 결과 합치기)
// ---------------------------------------------------------------------------

/// 여러 소스의 advisory를 하나로 합친다 (중복 ID 제거)
pub fn merge_advisories(sources: List(List(Advisory))) -> List(Advisory) {
  list.flatten(sources)
  |> deduplicate_advisories
}

fn deduplicate_advisories(advisories: List(Advisory)) -> List(Advisory) {
  do_deduplicate(advisories, [], [])
}

fn do_deduplicate(
  remaining: List(Advisory),
  seen_ids: List(String),
  acc: List(Advisory),
) -> List(Advisory) {
  case remaining {
    [] -> list.reverse(acc)
    [a, ..rest] -> {
      let key =
        string.lowercase(a.id) <> ":" <> string.lowercase(a.package_name)
      case list.contains(seen_ids, key) {
        True -> do_deduplicate(rest, seen_ids, acc)
        False -> do_deduplicate(rest, [key, ..seen_ids], [a, ..acc])
      }
    }
  }
}
