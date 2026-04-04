//// SemVer 파싱 및 제약 조건 매칭 — Hex와 npm 양쪽 문법 지원

import gleam/int
import gleam/list
import gleam/order.{type Order}
import gleam/result
import gleam/string

/// semver 모듈 전용 에러 타입
pub type SemverError {
  InvalidVersion(detail: String)
  InvalidConstraint(detail: String)
}

// ---------------------------------------------------------------------------
// VersionRange — PubGrub solver용 정규화된 버전 범위 집합 대수
// ---------------------------------------------------------------------------

/// 정규화된 버전 범위 (PubGrub 내부 연산용)
pub opaque type VersionRange {
  Empty
  Full
  Interval(
    min: Result(Version, Nil),
    min_inclusive: Bool,
    max: Result(Version, Nil),
    max_inclusive: Bool,
  )
  Union(VersionRange, VersionRange)
}

/// 파싱된 시맨틱 버전 (opaque — parse_version으로만 생성)
pub opaque type Version {
  Version(major: Int, minor: Int, patch: Int, pre: String)
}

/// 파싱된 제약 조건 (opaque — parse_*_constraint로만 생성)
pub opaque type Constraint {
  Gt(Version)
  Gte(Version)
  Lt(Version)
  Lte(Version)
  Eq(Version)
  And(Constraint, Constraint)
  Or(Constraint, Constraint)
  Any
}

// ---------------------------------------------------------------------------
// Version 파싱
// ---------------------------------------------------------------------------

/// 버전 문자열 파싱: "1.2.3", "1.2.3-rc.1"
pub fn parse_version(s: String) -> Result(Version, SemverError) {
  let s = string.trim(s)
  // v 접두사 제거
  let s = case string.starts_with(s, "v") {
    True -> string.drop_start(s, 1)
    False -> s
  }
  // build metadata 제거 (+build.123 → SemVer 사양: 비교 시 무시)
  let s = case string.split_once(s, "+") {
    Ok(#(before, _build)) -> before
    Error(_) -> s
  }
  // pre-release 분리
  let #(base, pre) = case string.split_once(s, "-") {
    Ok(#(b, p)) -> #(b, p)
    Error(_) -> #(s, "")
  }
  let parts = string.split(base, ".")
  case parts {
    [maj_s, min_s, pat_s] -> {
      use maj <- result.try(
        int.parse(maj_s)
        |> result.replace_error(InvalidVersion("invalid major: " <> maj_s)),
      )
      use min <- result.try(
        int.parse(min_s)
        |> result.replace_error(InvalidVersion("invalid minor: " <> min_s)),
      )
      use pat <- result.try(
        int.parse(pat_s)
        |> result.replace_error(InvalidVersion("invalid patch: " <> pat_s)),
      )
      Ok(Version(major: maj, minor: min, patch: pat, pre: pre))
    }
    [maj_s, min_s] -> {
      use maj <- result.try(
        int.parse(maj_s)
        |> result.replace_error(InvalidVersion("invalid major: " <> maj_s)),
      )
      use min <- result.try(
        int.parse(min_s)
        |> result.replace_error(InvalidVersion("invalid minor: " <> min_s)),
      )
      Ok(Version(major: maj, minor: min, patch: 0, pre: pre))
    }
    [maj_s] -> {
      use maj <- result.try(
        int.parse(maj_s)
        |> result.replace_error(InvalidVersion("invalid major: " <> maj_s)),
      )
      Ok(Version(major: maj, minor: 0, patch: 0, pre: ""))
    }
    _ -> Error(InvalidVersion("expected MAJOR.MINOR.PATCH, got: " <> s))
  }
}

// ---------------------------------------------------------------------------
// Version 비교
// ---------------------------------------------------------------------------

/// 두 버전 비교 (pre-release 있으면 같은 버전의 release보다 앞)
pub fn compare(a: Version, b: Version) -> Order {
  case int.compare(a.major, b.major) {
    order.Eq ->
      case int.compare(a.minor, b.minor) {
        order.Eq ->
          case int.compare(a.patch, b.patch) {
            order.Eq -> compare_pre(a.pre, b.pre)
            other -> other
          }
        other -> other
      }
    other -> other
  }
}

fn compare_pre(a: String, b: String) -> Order {
  case a, b {
    "", "" -> order.Eq
    "", _ -> order.Gt
    _, "" -> order.Lt
    _, _ -> compare_pre_identifiers(string.split(a, "."), string.split(b, "."))
  }
}

/// SemVer 2.0.0 사양 11항: pre-release 식별자 비교
fn compare_pre_identifiers(a: List(String), b: List(String)) -> Order {
  case a, b {
    [], [] -> order.Eq
    [], _ -> order.Lt
    _, [] -> order.Gt
    [ha, ..ra], [hb, ..rb] ->
      case compare_pre_identifier(ha, hb) {
        order.Eq -> compare_pre_identifiers(ra, rb)
        other -> other
      }
  }
}

/// 숫자 식별자는 정수 비교, 문자 식별자는 사전순, 숫자 < 문자
fn compare_pre_identifier(a: String, b: String) -> Order {
  case int.parse(a), int.parse(b) {
    Ok(na), Ok(nb) -> int.compare(na, nb)
    Ok(_), Error(_) -> order.Lt
    Error(_), Ok(_) -> order.Gt
    Error(_), Error(_) -> string.compare(a, b)
  }
}

// ---------------------------------------------------------------------------
// Version → String
// ---------------------------------------------------------------------------

pub fn to_string(v: Version) -> String {
  let base =
    int.to_string(v.major)
    <> "."
    <> int.to_string(v.minor)
    <> "."
    <> int.to_string(v.patch)
  case v.pre {
    "" -> base
    p -> base <> "-" <> p
  }
}

/// Version의 major 번호
pub fn major(v: Version) -> Int {
  v.major
}

/// Version의 minor 번호
pub fn minor(v: Version) -> Int {
  v.minor
}

// ---------------------------------------------------------------------------
// Hex 제약 조건 파싱
// ---------------------------------------------------------------------------

/// Hex 스타일 제약 조건 파싱: ">= 0.44.0 and < 2.0.0"
pub fn parse_hex_constraint(s: String) -> Result(Constraint, SemverError) {
  let s = string.trim(s)
  case s {
    "" -> Ok(Any)
    _ -> parse_hex_or(s)
  }
}

fn parse_hex_or(s: String) -> Result(Constraint, SemverError) {
  case string.split_once(s, " or ") {
    Ok(#(left, right)) -> {
      use l <- result.try(parse_hex_and(left))
      use r <- result.try(parse_hex_or(right))
      Ok(Or(l, r))
    }
    Error(_) -> parse_hex_and(s)
  }
}

fn parse_hex_and(s: String) -> Result(Constraint, SemverError) {
  case string.split_once(s, " and ") {
    Ok(#(left, right)) -> {
      use l <- result.try(parse_hex_leaf(string.trim(left)))
      use r <- result.try(parse_hex_and(right))
      Ok(And(l, r))
    }
    Error(_) -> parse_hex_leaf(string.trim(s))
  }
}

fn parse_hex_leaf(s: String) -> Result(Constraint, SemverError) {
  case s {
    ">= " <> rest -> {
      use v <- result.try(parse_version(rest))
      Ok(Gte(v))
    }
    "> " <> rest -> {
      use v <- result.try(parse_version(rest))
      Ok(Gt(v))
    }
    "<= " <> rest -> {
      use v <- result.try(parse_version(rest))
      Ok(Lte(v))
    }
    "< " <> rest -> {
      use v <- result.try(parse_version(rest))
      Ok(Lt(v))
    }
    "== " <> rest -> {
      use v <- result.try(parse_version(rest))
      Ok(Eq(v))
    }
    "~> " <> rest -> {
      // Elixir tilde: 2파트 ~> 1.2 → >= 1.2.0 and < 2.0.0
      //               3파트 ~> 1.2.3 → >= 1.2.3 and < 1.3.0
      let trimmed = string.trim(rest)
      let dot_count =
        string.to_graphemes(trimmed)
        |> list.count(fn(c) { c == "." })
      use v <- result.try(parse_version(trimmed))
      let upper = case dot_count {
        1 -> Version(v.major + 1, 0, 0, "")
        _ -> Version(v.major, v.minor + 1, 0, "")
      }
      Ok(And(Gte(v), Lt(upper)))
    }
    _ -> {
      // bare version = exact
      use v <- result.try(parse_version(s))
      Ok(Eq(v))
    }
  }
}

// ---------------------------------------------------------------------------
// npm 제약 조건 파싱
// ---------------------------------------------------------------------------

/// npm 스타일 제약 조건 파싱: "^11.0.0", "~1.2.3", ">=1.0.0 <2.0.0"
pub fn parse_npm_constraint(s: String) -> Result(Constraint, SemverError) {
  let s = string.trim(s)
  case s {
    "" | "*" -> Ok(Any)
    _ -> parse_npm_or(s)
  }
}

fn parse_npm_or(s: String) -> Result(Constraint, SemverError) {
  let parts = string.split(s, "||")
  case parts {
    [] -> Ok(Any)
    [single] -> parse_npm_range(string.trim(single))
    [first, ..rest] -> {
      use l <- result.try(parse_npm_range(string.trim(first)))
      use r <- result.try(parse_npm_or(string.join(rest, "||")))
      Ok(Or(l, r))
    }
  }
}

fn parse_npm_range(s: String) -> Result(Constraint, SemverError) {
  // 하이픈 범위 감지: "1.2.3 - 2.3.4" (공백-하이픈-공백)
  case detect_hyphen_range(s) {
    Ok(#(low, high)) -> parse_hyphen_range(low, high)
    Error(_) -> {
      // 공백으로 구분된 여러 비교를 AND로 결합
      let parts =
        string.split(s, " ")
        |> list.filter(fn(p) { string.trim(p) != "" })
      parse_npm_parts(parts)
    }
  }
}

/// 하이픈 범위 감지: " - " 구분자로 정확히 2파트, 양쪽 모두 연산자 없는 버전
fn detect_hyphen_range(s: String) -> Result(#(String, String), Nil) {
  case string.split_once(s, " - ") {
    Ok(#(low, high)) -> {
      let low_trimmed = string.trim(low)
      let high_trimmed = string.trim(high)
      case
        starts_with_operator(low_trimmed),
        starts_with_operator(high_trimmed)
      {
        False, False -> Ok(#(low_trimmed, high_trimmed))
        _, _ -> Error(Nil)
      }
    }
    Error(_) -> Error(Nil)
  }
}

fn starts_with_operator(s: String) -> Bool {
  string.starts_with(s, "^")
  || string.starts_with(s, "~")
  || string.starts_with(s, ">")
  || string.starts_with(s, "<")
  || string.starts_with(s, "=")
}

/// 하이픈 범위 파싱 (npm 사양 준수)
/// 하한: 부분 버전이면 missing parts를 0으로 채움 → Gte
/// 상한: 완전한 3파트이면 Lte (inclusive), 부분이면 다음 범위까지 Lt (exclusive)
fn parse_hyphen_range(
  low: String,
  high: String,
) -> Result(Constraint, SemverError) {
  use low_version <- result.try(parse_version(low))
  let lower = Gte(low_version)
  use upper <- result.try(parse_hyphen_upper(high))
  Ok(And(lower, upper))
}

/// 상한 처리: 파트 수에 따라 inclusive/exclusive 분기
/// 3파트 "2.3.4" → <= 2.3.4
/// 2파트 "2.3"   → < 2.4.0
/// 1파트 "2"     → < 3.0.0
fn parse_hyphen_upper(s: String) -> Result(Constraint, SemverError) {
  let parts = string.split(s, ".")
  case parts {
    [_, _, _] -> {
      use v <- result.try(parse_version(s))
      Ok(Lte(v))
    }
    [maj_s, min_s] -> {
      use maj <- result.try(
        int.parse(maj_s)
        |> result.replace_error(InvalidConstraint(
          "invalid hyphen range upper: " <> s,
        )),
      )
      use min <- result.try(
        int.parse(min_s)
        |> result.replace_error(InvalidConstraint(
          "invalid hyphen range upper: " <> s,
        )),
      )
      Ok(Lt(Version(maj, min + 1, 0, "")))
    }
    [maj_s] -> {
      use maj <- result.try(
        int.parse(maj_s)
        |> result.replace_error(InvalidConstraint(
          "invalid hyphen range upper: " <> s,
        )),
      )
      Ok(Lt(Version(maj + 1, 0, 0, "")))
    }
    _ -> Error(InvalidConstraint("invalid hyphen range upper bound: " <> s))
  }
}

fn parse_npm_parts(parts: List(String)) -> Result(Constraint, SemverError) {
  case parts {
    [] -> Ok(Any)
    [single] -> parse_npm_single(single)
    [first, ..rest] -> {
      use l <- result.try(parse_npm_single(first))
      use r <- result.try(parse_npm_parts(rest))
      Ok(And(l, r))
    }
  }
}

fn parse_npm_single(s: String) -> Result(Constraint, SemverError) {
  case s {
    "^" <> rest -> parse_npm_caret(rest)
    "~" <> rest -> parse_npm_tilde(rest)
    ">=" <> rest -> {
      use v <- result.try(parse_version(string.trim(rest)))
      Ok(Gte(v))
    }
    ">" <> rest -> {
      use v <- result.try(parse_version(string.trim(rest)))
      Ok(Gt(v))
    }
    "<=" <> rest -> {
      use v <- result.try(parse_version(string.trim(rest)))
      Ok(Lte(v))
    }
    "<" <> rest -> {
      use v <- result.try(parse_version(string.trim(rest)))
      Ok(Lt(v))
    }
    "=" <> rest -> {
      use v <- result.try(parse_version(string.trim(rest)))
      Ok(Eq(v))
    }
    _ -> {
      use v <- result.try(parse_version(s))
      Ok(Eq(v))
    }
  }
}

/// ^1.2.3 → >= 1.2.3 and < 2.0.0 (major 고정)
/// ^0.2.3 → >= 0.2.3 and < 0.3.0 (minor 고정, major=0일 때)
/// ^0.0.3 → >= 0.0.3 and < 0.0.4 (patch 고정, major=0,minor=0일 때)
fn parse_npm_caret(s: String) -> Result(Constraint, SemverError) {
  use v <- result.try(parse_version(s))
  let upper = case v.major, v.minor {
    0, 0 -> Version(0, 0, v.patch + 1, "")
    0, _ -> Version(0, v.minor + 1, 0, "")
    _, _ -> Version(v.major + 1, 0, 0, "")
  }
  Ok(And(Gte(Version(..v, pre: "")), Lt(upper)))
}

/// ~1.2.3 → >= 1.2.3 and < 1.3.0 (minor 고정)
fn parse_npm_tilde(s: String) -> Result(Constraint, SemverError) {
  use v <- result.try(parse_version(s))
  let upper = Version(v.major, v.minor + 1, 0, "")
  Ok(And(Gte(Version(..v, pre: "")), Lt(upper)))
}

// ---------------------------------------------------------------------------
// 통합 제약 조건 파싱 (hex + npm 문법 모두 수용)
// ---------------------------------------------------------------------------

/// 통합 제약 조건 파서: hex와 npm 문법 모두 수용
/// gleam.toml에서 사용자가 작성하는 제약 조건용
pub fn parse_constraint(s: String) -> Result(Constraint, SemverError) {
  let s = string.trim(s)
  case s {
    "" | "*" -> Ok(Any)
    _ -> parse_unified_or(s)
  }
}

fn parse_unified_or(s: String) -> Result(Constraint, SemverError) {
  // hex 스타일 " or " 먼저 시도
  case string.split_once(s, " or ") {
    Ok(#(left, right)) -> {
      use l <- result.try(parse_unified_and_group(string.trim(left)))
      use r <- result.try(parse_unified_or(string.trim(right)))
      Ok(Or(l, r))
    }
    Error(_) -> {
      // npm 스타일 "||"
      let parts = string.split(s, "||")
      case parts {
        [] -> Ok(Any)
        [single] -> parse_unified_and_group(string.trim(single))
        [first, ..rest] -> {
          use l <- result.try(parse_unified_and_group(string.trim(first)))
          use r <- result.try(parse_unified_or(string.join(rest, "||")))
          Ok(Or(l, r))
        }
      }
    }
  }
}

fn parse_unified_and_group(s: String) -> Result(Constraint, SemverError) {
  // hex 스타일 " and "
  case string.split_once(s, " and ") {
    Ok(#(left, right)) -> {
      use l <- result.try(parse_unified_single(string.trim(left)))
      use r <- result.try(parse_unified_and_group(string.trim(right)))
      Ok(And(l, r))
    }
    Error(_) -> {
      // npm 스타일: 하이픈 범위 또는 공백 구분 AND
      case detect_hyphen_range(s) {
        Ok(#(low, high)) -> parse_hyphen_range(low, high)
        Error(_) -> {
          let parts =
            string.split(s, " ")
            |> list.filter(fn(p) { string.trim(p) != "" })
            |> merge_operator_parts
          parse_unified_parts(parts)
        }
      }
    }
  }
}

/// 공백 split 후 단독 연산자(">=", ">", "~>" 등)를 다음 토큰과 병합
/// [">=", "1.0.0", "<", "2.0.0"] → [">= 1.0.0", "< 2.0.0"]
fn merge_operator_parts(parts: List(String)) -> List(String) {
  case parts {
    [] -> []
    [op, version, ..rest] ->
      case is_bare_operator(op) {
        True -> [op <> " " <> version, ..merge_operator_parts(rest)]
        False -> [op, ..merge_operator_parts([version, ..rest])]
      }
    [single] -> [single]
  }
}

fn is_bare_operator(s: String) -> Bool {
  s == ">="
  || s == ">"
  || s == "<="
  || s == "<"
  || s == "=="
  || s == "="
  || s == "~>"
}

fn parse_unified_parts(parts: List(String)) -> Result(Constraint, SemverError) {
  case parts {
    [] -> Ok(Any)
    [single] -> parse_unified_single(single)
    [first, ..rest] -> {
      use l <- result.try(parse_unified_single(first))
      use r <- result.try(parse_unified_parts(rest))
      Ok(And(l, r))
    }
  }
}

fn parse_unified_single(s: String) -> Result(Constraint, SemverError) {
  case s {
    "^" <> rest -> parse_npm_caret(rest)
    "~> " <> rest -> parse_pessimistic(rest)
    "~>" <> rest -> parse_pessimistic(rest)
    "~" <> rest -> parse_npm_tilde(rest)
    ">= " <> rest -> {
      use v <- result.try(parse_version(rest))
      Ok(Gte(v))
    }
    ">=" <> rest -> {
      use v <- result.try(parse_version(string.trim(rest)))
      Ok(Gte(v))
    }
    "> " <> rest -> {
      use v <- result.try(parse_version(rest))
      Ok(Gt(v))
    }
    ">" <> rest -> {
      use v <- result.try(parse_version(string.trim(rest)))
      Ok(Gt(v))
    }
    "<= " <> rest -> {
      use v <- result.try(parse_version(rest))
      Ok(Lte(v))
    }
    "<=" <> rest -> {
      use v <- result.try(parse_version(string.trim(rest)))
      Ok(Lte(v))
    }
    "< " <> rest -> {
      use v <- result.try(parse_version(rest))
      Ok(Lt(v))
    }
    "<" <> rest -> {
      use v <- result.try(parse_version(string.trim(rest)))
      Ok(Lt(v))
    }
    "== " <> rest -> {
      use v <- result.try(parse_version(rest))
      Ok(Eq(v))
    }
    "==" <> rest -> {
      use v <- result.try(parse_version(string.trim(rest)))
      Ok(Eq(v))
    }
    "=" <> rest -> {
      use v <- result.try(parse_version(string.trim(rest)))
      Ok(Eq(v))
    }
    _ -> {
      use v <- result.try(parse_version(s))
      Ok(Eq(v))
    }
  }
}

/// Elixir pessimistic constraint (~>)
/// 2파트 ~> 1.2 → >= 1.2.0 and < 2.0.0
/// 3파트 ~> 1.2.3 → >= 1.2.3 and < 1.3.0
fn parse_pessimistic(s: String) -> Result(Constraint, SemverError) {
  let trimmed = string.trim(s)
  let dot_count =
    string.to_graphemes(trimmed)
    |> list.count(fn(c) { c == "." })
  use v <- result.try(parse_version(trimmed))
  let upper = case dot_count {
    1 -> Version(v.major + 1, 0, 0, "")
    _ -> Version(v.major, v.minor + 1, 0, "")
  }
  Ok(And(Gte(v), Lt(upper)))
}

// ---------------------------------------------------------------------------
// 제약 조건 만족 검사
// ---------------------------------------------------------------------------

/// 버전이 제약 조건을 만족하는지 검사
pub fn satisfies(version: Version, constraint: Constraint) -> Bool {
  case constraint {
    Any -> True
    Eq(v) -> compare(version, v) == order.Eq
    Gt(v) -> compare(version, v) == order.Gt
    Gte(v) -> compare(version, v) == order.Gt || compare(version, v) == order.Eq
    Lt(v) -> compare(version, v) == order.Lt
    Lte(v) -> compare(version, v) == order.Lt || compare(version, v) == order.Eq
    And(a, b) -> satisfies(version, a) && satisfies(version, b)
    Or(a, b) -> satisfies(version, a) || satisfies(version, b)
  }
}

// ---------------------------------------------------------------------------
// Hex 제약 조건 정규화
// ---------------------------------------------------------------------------

/// 단축 버전을 Hex SemVer 형식으로 변환
/// "3" → ">= 3.0.0 and < 4.0.0"
/// "3.1" → ">= 3.1.0 and < 4.0.0"
/// "3.1.0" → ">= 3.1.0 and < 4.0.0"
/// "^3.0" → ">= 3.0.0 and < 4.0.0"
/// "~3.1" → ">= 3.1.0 and < 3.2.0"
/// ">= 1.0.0" 등 이미 Hex 형식이면 그대로
pub fn normalize_hex_constraint(ver: String) -> String {
  // 이미 Hex SemVer 형식 (>=, and, <)이면 그대로
  case
    string.contains(ver, ">=")
    || string.contains(ver, "and")
    || string.contains(ver, ">= 0.0.0")
  {
    True -> ver
    False -> {
      // ^ prefix 제거
      let cleaned = case string.starts_with(ver, "^") {
        True -> string.drop_start(ver, 1)
        False -> ver
      }
      let is_tilde = string.starts_with(ver, "~")
      let cleaned = case is_tilde {
        True -> string.drop_start(cleaned, 1)
        False -> cleaned
      }
      normalize_hex_parts(string.split(cleaned, "."), is_tilde, ver)
    }
  }
}

fn normalize_hex_parts(
  parts: List(String),
  is_tilde: Bool,
  original: String,
) -> String {
  case parts {
    [major_s] ->
      case int.parse(major_s) {
        Ok(major) ->
          ">= "
          <> int.to_string(major)
          <> ".0.0 and < "
          <> int.to_string(major + 1)
          <> ".0.0"
        Error(_) -> original
      }
    [major_s, minor_s] ->
      case int.parse(major_s), int.parse(minor_s) {
        Ok(major), Ok(minor) ->
          case is_tilde {
            True ->
              ">= "
              <> int.to_string(major)
              <> "."
              <> int.to_string(minor)
              <> ".0 and < "
              <> int.to_string(major)
              <> "."
              <> int.to_string(minor + 1)
              <> ".0"
            False ->
              ">= "
              <> int.to_string(major)
              <> "."
              <> int.to_string(minor)
              <> ".0 and < "
              <> int.to_string(major + 1)
              <> ".0.0"
          }
        _, _ -> original
      }
    [major_s, minor_s, patch_s] ->
      case int.parse(major_s), int.parse(minor_s), int.parse(patch_s) {
        Ok(major), Ok(minor), Ok(patch) ->
          case is_tilde {
            True ->
              ">= "
              <> int.to_string(major)
              <> "."
              <> int.to_string(minor)
              <> "."
              <> int.to_string(patch)
              <> " and < "
              <> int.to_string(major)
              <> "."
              <> int.to_string(minor + 1)
              <> ".0"
            False ->
              ">= "
              <> int.to_string(major)
              <> "."
              <> int.to_string(minor)
              <> "."
              <> int.to_string(patch)
              <> " and < "
              <> int.to_string(major + 1)
              <> ".0.0"
          }
        _, _, _ -> original
      }
    _ -> original
  }
}

// ---------------------------------------------------------------------------
// VersionRange 생성자
// ---------------------------------------------------------------------------

/// 빈 범위 (공집합)
pub fn version_range_empty() -> VersionRange {
  Empty
}

/// 전체 범위 (모든 버전)
pub fn version_range_any() -> VersionRange {
  Full
}

/// 단일 버전 범위
pub fn version_range_exact(v: Version) -> VersionRange {
  Interval(min: Ok(v), min_inclusive: True, max: Ok(v), max_inclusive: True)
}

/// Constraint를 VersionRange로 변환 (opaque 접근 필요)
pub fn constraint_to_range(c: Constraint) -> VersionRange {
  case c {
    Any -> Full
    Eq(v) -> version_range_exact(v)
    Gt(v) ->
      Interval(
        min: Ok(v),
        min_inclusive: False,
        max: Error(Nil),
        max_inclusive: False,
      )
    Gte(v) ->
      Interval(
        min: Ok(v),
        min_inclusive: True,
        max: Error(Nil),
        max_inclusive: False,
      )
    Lt(v) ->
      Interval(
        min: Error(Nil),
        min_inclusive: False,
        max: Ok(v),
        max_inclusive: False,
      )
    Lte(v) ->
      Interval(
        min: Error(Nil),
        min_inclusive: False,
        max: Ok(v),
        max_inclusive: True,
      )
    And(a, b) -> range_intersect(constraint_to_range(a), constraint_to_range(b))
    Or(a, b) -> range_union(constraint_to_range(a), constraint_to_range(b))
  }
}

// ---------------------------------------------------------------------------
// VersionRange 집합 연산
// ---------------------------------------------------------------------------

/// 범위가 공집합인지 판정
pub fn range_is_empty(r: VersionRange) -> Bool {
  case r {
    Empty -> True
    Full -> False
    Interval(min:, min_inclusive:, max:, max_inclusive:) ->
      case min, max {
        Ok(lo), Ok(hi) ->
          case compare(lo, hi) {
            order.Gt -> True
            order.Eq -> !{ min_inclusive && max_inclusive }
            order.Lt -> False
          }
        _, _ -> False
      }
    Union(a, b) -> range_is_empty(a) && range_is_empty(b)
  }
}

/// 버전이 범위에 포함되는지 판정
pub fn range_allows_version(r: VersionRange, v: Version) -> Bool {
  case r {
    Empty -> False
    Full -> True
    Interval(min:, min_inclusive:, max:, max_inclusive:) -> {
      let above_min = case min {
        Error(_) -> True
        Ok(lo) ->
          case compare(v, lo) {
            order.Gt -> True
            order.Eq -> min_inclusive
            order.Lt -> False
          }
      }
      let below_max = case max {
        Error(_) -> True
        Ok(hi) ->
          case compare(v, hi) {
            order.Lt -> True
            order.Eq -> max_inclusive
            order.Gt -> False
          }
      }
      above_min && below_max
    }
    Union(a, b) -> range_allows_version(a, v) || range_allows_version(b, v)
  }
}

/// 두 범위의 교집합
pub fn range_intersect(a: VersionRange, b: VersionRange) -> VersionRange {
  case a, b {
    Empty, _ | _, Empty -> Empty
    Full, x | x, Full -> x
    Union(a1, a2), _ ->
      range_union(range_intersect(a1, b), range_intersect(a2, b))
    _, Union(b1, b2) ->
      range_union(range_intersect(a, b1), range_intersect(a, b2))
    Interval(
      min: a_min,
      min_inclusive: a_min_inc,
      max: a_max,
      max_inclusive: a_max_inc,
    ),
      Interval(
        min: b_min,
        min_inclusive: b_min_inc,
        max: b_max,
        max_inclusive: b_max_inc,
      )
    -> {
      let #(new_min, new_min_inc) =
        pick_higher_bound(a_min, a_min_inc, b_min, b_min_inc)
      let #(new_max, new_max_inc) =
        pick_lower_bound(a_max, a_max_inc, b_max, b_max_inc)
      let result =
        Interval(
          min: new_min,
          min_inclusive: new_min_inc,
          max: new_max,
          max_inclusive: new_max_inc,
        )
      case range_is_empty(result) {
        True -> Empty
        False -> result
      }
    }
  }
}

/// 두 범위의 합집합
pub fn range_union(a: VersionRange, b: VersionRange) -> VersionRange {
  case a, b {
    Empty, x | x, Empty -> x
    Full, _ | _, Full -> Full
    _, _ -> {
      // 두 구간이 인접하거나 겹치면 병합, 아니면 Union
      case try_merge_intervals(a, b) {
        Ok(merged) -> merged
        Error(_) -> Union(a, b)
      }
    }
  }
}

/// 여집합: ¬R
pub fn range_complement(r: VersionRange) -> VersionRange {
  case r {
    Empty -> Full
    Full -> Empty
    Interval(min:, min_inclusive:, max:, max_inclusive:) -> {
      let lower = case min {
        Error(_) -> Empty
        Ok(v) ->
          case min_inclusive {
            True ->
              Interval(
                min: Error(Nil),
                min_inclusive: False,
                max: Ok(v),
                max_inclusive: False,
              )
            False ->
              Interval(
                min: Error(Nil),
                min_inclusive: False,
                max: Ok(v),
                max_inclusive: True,
              )
          }
      }
      let upper = case max {
        Error(_) -> Empty
        Ok(v) ->
          case max_inclusive {
            True ->
              Interval(
                min: Ok(v),
                min_inclusive: False,
                max: Error(Nil),
                max_inclusive: False,
              )
            False ->
              Interval(
                min: Ok(v),
                min_inclusive: True,
                max: Error(Nil),
                max_inclusive: False,
              )
          }
      }
      range_union(lower, upper)
    }
    Union(a, b) -> range_intersect(range_complement(a), range_complement(b))
  }
}

/// a ⊆ b 판정 (complement 없이 직접 비교)
pub fn range_subset(a: VersionRange, b: VersionRange) -> Bool {
  case a, b {
    Empty, _ -> True
    _, Full -> True
    Full, _ -> False
    _, Empty -> False
    Union(a1, a2), _ -> range_subset(a1, b) && range_subset(a2, b)
    Interval(
      min: a_min,
      min_inclusive: a_min_inc,
      max: a_max,
      max_inclusive: a_max_inc,
    ),
      Interval(
        min: b_min,
        min_inclusive: b_min_inc,
        max: b_max,
        max_inclusive: b_max_inc,
      )
    -> {
      // a의 하한이 b의 하한 이상이고 a의 상한이 b의 상한 이하
      let min_ok = case b_min, a_min {
        Error(_), _ -> True
        _, Error(_) -> False
        Ok(bv), Ok(av) ->
          case compare(av, bv) {
            order.Gt -> True
            order.Lt -> False
            order.Eq ->
              // b가 inclusive면 a도 OK, b가 exclusive면 a도 exclusive여야 함
              b_min_inc || !a_min_inc
          }
      }
      let max_ok = case b_max, a_max {
        Error(_), _ -> True
        _, Error(_) -> False
        Ok(bv), Ok(av) ->
          case compare(av, bv) {
            order.Lt -> True
            order.Gt -> False
            order.Eq -> b_max_inc || !a_max_inc
          }
      }
      min_ok && max_ok
    }
    Interval(..), Union(b1, b2) -> {
      // a ⊆ b1 ∪ b2: a에서 b1에 속하는 부분을 빼고 나머지가 b2에 속하는지 확인
      let remainder = range_minus(a, b1)
      range_subset(remainder, b2)
    }
  }
}

/// a에서 b를 ��는 차집합 (complement 없이 직접 계산)
pub fn range_minus(a: VersionRange, b: VersionRange) -> VersionRange {
  case a, b {
    Empty, _ | _, Full -> Empty
    _, Empty -> a
    Full, _ -> range_intersect(a, range_complement(b))
    Union(a1, a2), _ -> range_union(range_minus(a1, b), range_minus(a2, b))
    Interval(
      min: a_min,
      min_inclusive: a_min_inc,
      max: a_max,
      max_inclusive: a_max_inc,
    ),
      Interval(
        min: b_min,
        min_inclusive: b_min_inc,
        max: b_max,
        max_inclusive: b_max_inc,
      )
    -> {
      // a \ b = a ∩ ¬b
      // ¬b = (-∞, b_min) ∪ (b_max, +∞) (inclusivity 반전)
      let left_part = case b_min {
        Error(_) -> Empty
        Ok(bv) -> {
          let left_max_inc = !b_min_inc
          let left =
            Interval(
              min: a_min,
              min_inclusive: a_min_inc,
              max: Ok(bv),
              max_inclusive: left_max_inc,
            )
          case range_is_empty(left) {
            True -> Empty
            False -> left
          }
        }
      }
      let right_part = case b_max {
        Error(_) -> Empty
        Ok(bv) -> {
          let right_min_inc = !b_max_inc
          let right =
            Interval(
              min: Ok(bv),
              min_inclusive: right_min_inc,
              max: a_max,
              max_inclusive: a_max_inc,
            )
          case range_is_empty(right) {
            True -> Empty
            False -> right
          }
        }
      }
      range_union(left_part, right_part)
    }
    _, Union(b1, b2) -> {
      // a \ (b1 ∪ b2) = (a \ b1) \ b2
      range_minus(range_minus(a, b1), b2)
    }
  }
}

/// VersionRange를 사람이 읽을 수 있는 문자열로 변환
pub fn range_to_string(r: VersionRange) -> String {
  case r {
    Empty -> "∅"
    Full -> "*"
    Interval(min:, min_inclusive:, max:, max_inclusive:) ->
      interval_to_string(min, min_inclusive, max, max_inclusive)
    Union(a, b) -> range_to_string(a) <> " || " <> range_to_string(b)
  }
}

// ---------------------------------------------------------------------------
// VersionRange 내부 헬퍼
// ---------------------------------------------------------------------------

fn interval_to_string(
  min: Result(Version, Nil),
  min_inclusive: Bool,
  max: Result(Version, Nil),
  max_inclusive: Bool,
) -> String {
  case min, max {
    Ok(lo), Ok(hi) if lo == hi && min_inclusive && max_inclusive ->
      to_string(lo)
    Ok(lo), Ok(hi) -> {
      let lo_str = case min_inclusive {
        True -> ">=" <> to_string(lo)
        False -> ">" <> to_string(lo)
      }
      let hi_str = case max_inclusive {
        True -> "<=" <> to_string(hi)
        False -> "<" <> to_string(hi)
      }
      lo_str <> " " <> hi_str
    }
    Error(_), Ok(hi) ->
      case max_inclusive {
        True -> "<=" <> to_string(hi)
        False -> "<" <> to_string(hi)
      }
    Ok(lo), Error(_) ->
      case min_inclusive {
        True -> ">=" <> to_string(lo)
        False -> ">" <> to_string(lo)
      }
    Error(_), Error(_) -> "*"
  }
}

/// 두 하한 중 더 높은 쪽 선택 (교집합용)
fn pick_higher_bound(
  a: Result(Version, Nil),
  a_inc: Bool,
  b: Result(Version, Nil),
  b_inc: Bool,
) -> #(Result(Version, Nil), Bool) {
  case a, b {
    Error(_), _ -> #(b, b_inc)
    _, Error(_) -> #(a, a_inc)
    Ok(va), Ok(vb) ->
      case compare(va, vb) {
        order.Gt -> #(a, a_inc)
        order.Lt -> #(b, b_inc)
        order.Eq -> #(a, a_inc && b_inc)
      }
  }
}

/// 두 상한 중 더 낮은 쪽 선택 (교집합용)
fn pick_lower_bound(
  a: Result(Version, Nil),
  a_inc: Bool,
  b: Result(Version, Nil),
  b_inc: Bool,
) -> #(Result(Version, Nil), Bool) {
  case a, b {
    Error(_), _ -> #(b, b_inc)
    _, Error(_) -> #(a, a_inc)
    Ok(va), Ok(vb) ->
      case compare(va, vb) {
        order.Lt -> #(a, a_inc)
        order.Gt -> #(b, b_inc)
        order.Eq -> #(a, a_inc && b_inc)
      }
  }
}

/// 두 구간이 인접하거나 겹치면 병합
fn try_merge_intervals(
  a: VersionRange,
  b: VersionRange,
) -> Result(VersionRange, Nil) {
  case a, b {
    Interval(
      min: a_min,
      min_inclusive: a_min_inc,
      max: a_max,
      max_inclusive: a_max_inc,
    ),
      Interval(
        min: b_min,
        min_inclusive: b_min_inc,
        max: b_max,
        max_inclusive: b_max_inc,
      )
    -> {
      // 겹치거나 인접한지 확인: a의 상한이 b의 하한 이상이고 b의 상한이 a의 하한 이상
      case
        intervals_overlap_or_adjacent(a_max, a_max_inc, b_min, b_min_inc)
        && intervals_overlap_or_adjacent(b_max, b_max_inc, a_min, a_min_inc)
      {
        True -> {
          let #(new_min, new_min_inc) =
            pick_lower_bound(a_min, a_min_inc, b_min, b_min_inc)
          let #(new_max, new_max_inc) =
            pick_higher_bound(a_max, a_max_inc, b_max, b_max_inc)
          Ok(Interval(
            min: new_min,
            min_inclusive: new_min_inc,
            max: new_max,
            max_inclusive: new_max_inc,
          ))
        }
        False -> Error(Nil)
      }
    }
    _, _ -> Error(Nil)
  }
}

/// 상한 bound가 하한 bound 이상인지 (겹침/인접 판정)
fn intervals_overlap_or_adjacent(
  upper: Result(Version, Nil),
  upper_inc: Bool,
  lower: Result(Version, Nil),
  lower_inc: Bool,
) -> Bool {
  case upper, lower {
    Error(_), _ | _, Error(_) -> True
    Ok(u), Ok(l) ->
      case compare(u, l) {
        order.Gt -> True
        order.Eq -> upper_inc || lower_inc
        order.Lt -> False
      }
  }
}
