//// PubGrub Incompatibility — 동시에 참이 될 수 없는 Term 집합 + 원인 추적

import gleam/dict.{type Dict}
import gleam/list
import gleam/string
import kirari/resolver/term.{type Term, Negative, Positive}
import kirari/semver

/// Incompatibility가 존재하는 이유
pub type IncompatibilityCause {
  /// gleam.toml 루트 의존성
  Root
  /// package@version이 dep_name을 dep_constraint로 의존
  DependencyOn(
    package: String,
    version: String,
    dep_name: String,
    dep_constraint: String,
  )
  /// 범위 내에 후보 버전이 없음
  NoVersions(package: String, range_desc: String)
  /// 두 incompatibility의 충돌에서 유도됨
  ConflictCause(left: Incompatibility, right: Incompatibility)
}

/// 동시에 참이 될 수 없는 Term 집합
pub type Incompatibility {
  Incompatibility(terms: Dict(String, Term), cause: IncompatibilityCause)
}

/// Term 목록과 원인으로 Incompatibility 생성
pub fn new(terms: List(Term), cause: IncompatibilityCause) -> Incompatibility {
  let terms_dict =
    list.fold(terms, dict.new(), fn(acc, t) {
      let key = term.to_key(term.package(t))
      case dict.get(acc, key) {
        Ok(existing) ->
          case term.intersect(existing, t) {
            Ok(merged) -> dict.insert(acc, key, merged)
            Error(_) -> dict.insert(acc, key, t)
          }
        Error(_) -> dict.insert(acc, key, t)
      }
    })
  Incompatibility(terms: terms_dict, cause: cause)
}

/// 특정 패키지의 Term 조회
pub fn get_term(i: Incompatibility, key: String) -> Result(Term, Nil) {
  dict.get(i.terms, key)
}

/// 이 incompatibility가 언급하는 모든 패키지 키
pub fn packages(i: Incompatibility) -> List(String) {
  dict.keys(i.terms)
}

/// Term 수
pub fn term_count(i: Incompatibility) -> Int {
  dict.size(i.terms)
}

/// 충돌 설명을 사람이 읽을 수 있는 문자열로 생성
pub fn explain(i: Incompatibility) -> String {
  do_explain(i, 1).0
}

fn do_explain(i: Incompatibility, line_num: Int) -> #(String, Int) {
  case i.cause {
    Root -> #(describe_terms(i), line_num)
    DependencyOn(package:, version:, dep_name:, dep_constraint:) -> #(
      "Because "
        <> package
        <> "@"
        <> version
        <> " depends on "
        <> dep_name
        <> " "
        <> dep_constraint,
      line_num,
    )
    NoVersions(package:, range_desc:) -> #(
      "Because no version of " <> package <> " matches " <> range_desc,
      line_num,
    )
    ConflictCause(left, right) -> explain_conflict(left, right, line_num)
  }
}

fn explain_conflict(
  left: Incompatibility,
  right: Incompatibility,
  line_num: Int,
) -> #(String, Int) {
  let is_leaf_left = is_leaf(left)
  let is_leaf_right = is_leaf(right)
  case is_leaf_left, is_leaf_right {
    True, True -> {
      let left_desc = { do_explain(left, line_num) }.0
      let right_desc = { do_explain(right, line_num) }.0
      #(
        left_desc
          <> "\nand "
          <> uncapitalize(right_desc)
          <> ",\nversion solving failed.",
        line_num,
      )
    }
    True, False -> {
      let #(right_text, next) = do_explain(right, line_num)
      let left_desc = { do_explain(left, next) }.0
      #(
        right_text
          <> ".\nAnd "
          <> uncapitalize(left_desc)
          <> ",\nversion solving failed.",
        next,
      )
    }
    False, True -> {
      let #(left_text, next) = do_explain(left, line_num)
      let right_desc = { do_explain(right, next) }.0
      #(
        left_text
          <> ".\nAnd "
          <> uncapitalize(right_desc)
          <> ",\nversion solving failed.",
        next,
      )
    }
    False, False -> {
      let #(left_text, next1) = do_explain(left, line_num)
      let #(right_text, next2) = do_explain(right, next1)
      #(
        left_text
          <> ".\nAnd "
          <> uncapitalize(right_text)
          <> ",\nversion solving failed.",
        next2,
      )
    }
  }
}

fn is_leaf(i: Incompatibility) -> Bool {
  case i.cause {
    ConflictCause(_, _) -> False
    _ -> True
  }
}

fn describe_terms(i: Incompatibility) -> String {
  let term_strs =
    dict.values(i.terms)
    |> list.map(fn(t) {
      let pkg = term.package(t)
      let range = term.range(t)
      case t {
        Positive(_, _) -> pkg.name <> " " <> semver.range_to_string(range)
        Negative(_, _) ->
          "not " <> pkg.name <> " " <> semver.range_to_string(range)
      }
    })
  "Because root depends on " <> string.join(term_strs, " and ")
}

fn uncapitalize(s: String) -> String {
  case string.pop_grapheme(s) {
    Ok(#(first, rest)) -> string.lowercase(first) <> rest
    Error(_) -> s
  }
}
