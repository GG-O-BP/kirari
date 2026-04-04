//// SPDX 라이선스 표현식 파싱 — SPDX 2.3 Appendix IV 문법 준수
//// 재귀 하강 파서로 구현, 연산자 우선순위: WITH > AND > OR

import gleam/list
import gleam/string

// ---------------------------------------------------------------------------
// 에러 타입
// ---------------------------------------------------------------------------

/// SPDX 파서 전용 에러 타입
pub type SpdxError {
  InvalidExpression(detail: String)
  UnexpectedToken(expected: String, got: String)
  UnexpectedEnd
}

// ---------------------------------------------------------------------------
// AST (opaque)
// ---------------------------------------------------------------------------

/// SPDX 라이선스 표현식 AST (parse로만 생성)
pub opaque type Expression {
  LicenseId(id: String)
  LicenseRef(ref: String)
  With(license: Expression, exception: String)
  And(left: Expression, right: Expression)
  Or(left: Expression, right: Expression)
}

// ---------------------------------------------------------------------------
// 토큰
// ---------------------------------------------------------------------------

type Token {
  TLicenseId(String)
  TLicenseRef(String)
  TAnd
  TOr
  TWith
  TLParen
  TRParen
  TEof
}

// ---------------------------------------------------------------------------
// 공개 API
// ---------------------------------------------------------------------------

/// SPDX 라이선스 표현식 문자열을 파싱
pub fn parse(input: String) -> Result(Expression, SpdxError) {
  let trimmed = string.trim(input)
  case trimmed {
    "" -> Error(InvalidExpression(detail: "empty expression"))
    _ -> {
      let tokens = tokenize(trimmed)
      case parse_or_expr(tokens) {
        Ok(#(expr, remaining)) ->
          case remaining {
            [TEof] -> Ok(expr)
            [] -> Ok(expr)
            [tok, ..] ->
              Error(UnexpectedToken(
                expected: "end of expression",
                got: token_to_string(tok),
              ))
          }
        Error(e) -> Error(e)
      }
    }
  }
}

/// Expression을 SPDX 정규 문자열로 변환
pub fn to_string(expr: Expression) -> String {
  case expr {
    LicenseId(id) -> id
    LicenseRef(ref) -> "LicenseRef-" <> ref
    With(license, exception) -> to_string(license) <> " WITH " <> exception
    And(left, right) -> wrap_if_or(left) <> " AND " <> wrap_if_or(right)
    Or(left, right) -> to_string(left) <> " OR " <> to_string(right)
  }
}

/// 허용 목록 기반 만족 검사 (case-insensitive)
/// OR: 하나라도 만족하면 True
/// AND: 둘 다 만족해야 True
/// WITH: base 라이선스가 만족하면 True
pub fn satisfies(expr: Expression, allowed: List(String)) -> Bool {
  let lower_allowed = list.map(allowed, string.lowercase)
  satisfies_lower(expr, lower_allowed)
}

/// 금지 목록 기반 위반 검사 (case-insensitive)
/// OR: 모든 분기가 금지돼야 위반 (선택지가 있으므로)
/// AND: 하나라도 금지면 위반
pub fn violates(expr: Expression, denied: List(String)) -> Bool {
  let lower_denied = list.map(denied, string.lowercase)
  violates_lower(expr, lower_denied)
}

/// 표현식에서 모든 라이선스 ID 추출
pub fn extract_ids(expr: Expression) -> List(String) {
  extract_ids_acc(expr, [])
  |> list.reverse
  |> list.unique
}

// ---------------------------------------------------------------------------
// satisfies / violates 내부 (소문자 변환 완료된 리스트 사용)
// ---------------------------------------------------------------------------

fn satisfies_lower(expr: Expression, allowed: List(String)) -> Bool {
  case expr {
    LicenseId(id) -> list.contains(allowed, string.lowercase(id))
    LicenseRef(ref) ->
      list.contains(allowed, string.lowercase("LicenseRef-" <> ref))
    With(license, _) -> satisfies_lower(license, allowed)
    And(left, right) ->
      satisfies_lower(left, allowed) && satisfies_lower(right, allowed)
    Or(left, right) ->
      satisfies_lower(left, allowed) || satisfies_lower(right, allowed)
  }
}

fn violates_lower(expr: Expression, denied: List(String)) -> Bool {
  case expr {
    LicenseId(id) -> list.contains(denied, string.lowercase(id))
    LicenseRef(_) -> False
    With(license, _) -> violates_lower(license, denied)
    And(left, right) ->
      violates_lower(left, denied) || violates_lower(right, denied)
    Or(left, right) ->
      violates_lower(left, denied) && violates_lower(right, denied)
  }
}

fn extract_ids_acc(expr: Expression, acc: List(String)) -> List(String) {
  case expr {
    LicenseId(id) -> [id, ..acc]
    LicenseRef(ref) -> ["LicenseRef-" <> ref, ..acc]
    With(license, _) -> extract_ids_acc(license, acc)
    And(left, right) -> extract_ids_acc(right, extract_ids_acc(left, acc))
    Or(left, right) -> extract_ids_acc(right, extract_ids_acc(left, acc))
  }
}

// ---------------------------------------------------------------------------
// to_string 헬퍼
// ---------------------------------------------------------------------------

fn wrap_if_or(expr: Expression) -> String {
  case expr {
    Or(_, _) -> "(" <> to_string(expr) <> ")"
    _ -> to_string(expr)
  }
}

// ---------------------------------------------------------------------------
// 토크나이저
// ---------------------------------------------------------------------------

fn tokenize(input: String) -> List(Token) {
  tokenize_acc(string.to_graphemes(input), [], "")
  |> list.reverse
}

fn tokenize_acc(
  chars: List(String),
  acc: List(Token),
  current: String,
) -> List(Token) {
  case chars {
    [] -> flush_current(current, acc)
    [" ", ..rest] | ["\t", ..rest] | ["\n", ..rest] | ["\r", ..rest] ->
      tokenize_acc(rest, flush_current(current, acc), "")
    ["(", ..rest] ->
      tokenize_acc(rest, [TLParen, ..flush_current(current, acc)], "")
    [")", ..rest] ->
      tokenize_acc(rest, [TRParen, ..flush_current(current, acc)], "")
    [ch, ..rest] -> tokenize_acc(rest, acc, current <> ch)
  }
}

fn flush_current(current: String, acc: List(Token)) -> List(Token) {
  case current {
    "" -> acc
    "AND" -> [TAnd, ..acc]
    "OR" -> [TOr, ..acc]
    "WITH" -> [TWith, ..acc]
    _ ->
      case string.starts_with(current, "LicenseRef-") {
        True -> [
          TLicenseRef(string.drop_start(current, string.length("LicenseRef-"))),
          ..acc
        ]
        False -> [TLicenseId(current), ..acc]
      }
  }
}

fn token_to_string(tok: Token) -> String {
  case tok {
    TLicenseId(id) -> id
    TLicenseRef(ref) -> "LicenseRef-" <> ref
    TAnd -> "AND"
    TOr -> "OR"
    TWith -> "WITH"
    TLParen -> "("
    TRParen -> ")"
    TEof -> "EOF"
  }
}

// ---------------------------------------------------------------------------
// 재귀 하강 파서
// ---------------------------------------------------------------------------

/// or_expr = and_expr ( "OR" and_expr )*
fn parse_or_expr(
  tokens: List(Token),
) -> Result(#(Expression, List(Token)), SpdxError) {
  use #(left, rest) <- try_parse(parse_and_expr(tokens))
  parse_or_rest(left, rest)
}

fn parse_or_rest(
  left: Expression,
  tokens: List(Token),
) -> Result(#(Expression, List(Token)), SpdxError) {
  case tokens {
    [TOr, ..rest] -> {
      use #(right, rest2) <- try_parse(parse_and_expr(rest))
      parse_or_rest(Or(left, right), rest2)
    }
    _ -> Ok(#(left, tokens))
  }
}

/// and_expr = with_expr ( "AND" with_expr )*
fn parse_and_expr(
  tokens: List(Token),
) -> Result(#(Expression, List(Token)), SpdxError) {
  use #(left, rest) <- try_parse(parse_with_expr(tokens))
  parse_and_rest(left, rest)
}

fn parse_and_rest(
  left: Expression,
  tokens: List(Token),
) -> Result(#(Expression, List(Token)), SpdxError) {
  case tokens {
    [TAnd, ..rest] -> {
      use #(right, rest2) <- try_parse(parse_with_expr(rest))
      parse_and_rest(And(left, right), rest2)
    }
    _ -> Ok(#(left, tokens))
  }
}

/// with_expr = primary ( "WITH" exception-id )?
fn parse_with_expr(
  tokens: List(Token),
) -> Result(#(Expression, List(Token)), SpdxError) {
  use #(primary, rest) <- try_parse(parse_primary(tokens))
  case rest {
    [TWith, TLicenseId(exception), ..rest2] ->
      Ok(#(With(primary, exception), rest2))
    [TWith, ..] ->
      Error(UnexpectedToken(expected: "exception identifier", got: "end"))
    _ -> Ok(#(primary, rest))
  }
}

/// primary = license-id | "LicenseRef-" ref | "(" expression ")"
fn parse_primary(
  tokens: List(Token),
) -> Result(#(Expression, List(Token)), SpdxError) {
  case tokens {
    [TLicenseId(id), ..rest] -> Ok(#(LicenseId(id), rest))
    [TLicenseRef(ref), ..rest] -> Ok(#(LicenseRef(ref), rest))
    [TLParen, ..rest] -> {
      use #(expr, rest2) <- try_parse(parse_or_expr(rest))
      case rest2 {
        [TRParen, ..rest3] -> Ok(#(expr, rest3))
        _ -> Error(UnexpectedToken(expected: ")", got: "end of expression"))
      }
    }
    [tok, ..] ->
      Error(UnexpectedToken(
        expected: "license identifier",
        got: token_to_string(tok),
      ))
    [] -> Error(UnexpectedEnd)
  }
}

// ---------------------------------------------------------------------------
// 파서 유틸
// ---------------------------------------------------------------------------

fn try_parse(
  result: Result(#(Expression, List(Token)), SpdxError),
  next: fn(#(Expression, List(Token))) ->
    Result(#(Expression, List(Token)), SpdxError),
) -> Result(#(Expression, List(Token)), SpdxError) {
  case result {
    Ok(value) -> next(value)
    Error(e) -> Error(e)
  }
}
