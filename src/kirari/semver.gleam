//// SemVer 파싱 및 제약 조건 매칭 — Hex와 npm 양쪽 문법 지원

import gleam/int
import gleam/list
import gleam/order.{type Order}
import gleam/result
import gleam/string

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
pub fn parse_version(s: String) -> Result(Version, String) {
  let s = string.trim(s)
  // v 접두사 제거
  let s = case string.starts_with(s, "v") {
    True -> string.drop_start(s, 1)
    False -> s
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
        |> result.replace_error("invalid major: " <> maj_s),
      )
      use min <- result.try(
        int.parse(min_s)
        |> result.replace_error("invalid minor: " <> min_s),
      )
      use pat <- result.try(
        int.parse(pat_s)
        |> result.replace_error("invalid patch: " <> pat_s),
      )
      Ok(Version(major: maj, minor: min, patch: pat, pre: pre))
    }
    [maj_s, min_s] -> {
      use maj <- result.try(
        int.parse(maj_s)
        |> result.replace_error("invalid major: " <> maj_s),
      )
      use min <- result.try(
        int.parse(min_s)
        |> result.replace_error("invalid minor: " <> min_s),
      )
      Ok(Version(major: maj, minor: min, patch: 0, pre: pre))
    }
    _ -> Error("expected MAJOR.MINOR.PATCH, got: " <> s)
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
    _, _ -> string.compare(a, b)
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
pub fn parse_hex_constraint(s: String) -> Result(Constraint, String) {
  let s = string.trim(s)
  case s {
    "" -> Ok(Any)
    _ -> parse_hex_or(s)
  }
}

fn parse_hex_or(s: String) -> Result(Constraint, String) {
  case string.split_once(s, " or ") {
    Ok(#(left, right)) -> {
      use l <- result.try(parse_hex_and(left))
      use r <- result.try(parse_hex_or(right))
      Ok(Or(l, r))
    }
    Error(_) -> parse_hex_and(s)
  }
}

fn parse_hex_and(s: String) -> Result(Constraint, String) {
  case string.split_once(s, " and ") {
    Ok(#(left, right)) -> {
      use l <- result.try(parse_hex_leaf(string.trim(left)))
      use r <- result.try(parse_hex_and(right))
      Ok(And(l, r))
    }
    Error(_) -> parse_hex_leaf(string.trim(s))
  }
}

fn parse_hex_leaf(s: String) -> Result(Constraint, String) {
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
pub fn parse_npm_constraint(s: String) -> Result(Constraint, String) {
  let s = string.trim(s)
  case s {
    "" | "*" -> Ok(Any)
    _ -> parse_npm_or(s)
  }
}

fn parse_npm_or(s: String) -> Result(Constraint, String) {
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

fn parse_npm_range(s: String) -> Result(Constraint, String) {
  // 공백으로 구분된 여러 비교를 AND로 결합
  let parts =
    string.split(s, " ")
    |> list.filter(fn(p) { string.trim(p) != "" })
  parse_npm_parts(parts)
}

fn parse_npm_parts(parts: List(String)) -> Result(Constraint, String) {
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

fn parse_npm_single(s: String) -> Result(Constraint, String) {
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
fn parse_npm_caret(s: String) -> Result(Constraint, String) {
  use v <- result.try(parse_version(s))
  let upper = case v.major, v.minor {
    0, 0 -> Version(0, 0, v.patch + 1, "")
    0, _ -> Version(0, v.minor + 1, 0, "")
    _, _ -> Version(v.major + 1, 0, 0, "")
  }
  Ok(And(Gte(Version(..v, pre: "")), Lt(upper)))
}

/// ~1.2.3 → >= 1.2.3 and < 1.3.0 (minor 고정)
fn parse_npm_tilde(s: String) -> Result(Constraint, String) {
  use v <- result.try(parse_version(s))
  let upper = Version(v.major, v.minor + 1, 0, "")
  Ok(And(Gte(Version(..v, pre: "")), Lt(upper)))
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
