//// PubGrub PartialSolution — 할당 추적, 결정 레벨, 백트래킹

import gleam/dict.{type Dict}
import gleam/list
import kirari/resolver/incompatibility.{type Incompatibility}
import kirari/resolver/term.{
  type PackageRef, type Relation, type Term, Contradicted, Inconclusive,
  Negative, Positive, Satisfied,
}
import kirari/semver.{type Version, type VersionRange}

/// 할당: 결정(Decision) 또는 유도(Derivation)
pub type Assignment {
  Decision(package: PackageRef, version: Version, decision_level: Int)
  Derivation(
    package: PackageRef,
    term: Term,
    decision_level: Int,
    cause: Incompatibility,
  )
}

/// Partial solution 상태
pub opaque type PartialSolution {
  PartialSolution(
    assignments: List(Assignment),
    decisions: Dict(String, Version),
    positive: Dict(String, VersionRange),
    negative: Dict(String, VersionRange),
    current_level: Int,
  )
}

/// 빈 partial solution 생성
pub fn new() -> PartialSolution {
  PartialSolution(
    assignments: [],
    decisions: dict.new(),
    positive: dict.new(),
    negative: dict.new(),
    current_level: 0,
  )
}

/// 현재 결정 레벨
pub fn decision_level(ps: PartialSolution) -> Int {
  ps.current_level
}

/// 결정된 패키지 → 버전 맵
pub fn decided_packages(ps: PartialSolution) -> Dict(String, Version) {
  ps.decisions
}

/// 할당 목록 (최신순)
pub fn assignments(ps: PartialSolution) -> List(Assignment) {
  ps.assignments
}

/// 패키지의 결정된 버전 조회
pub fn get_decision(ps: PartialSolution, key: String) -> Result(Version, Nil) {
  dict.get(ps.decisions, key)
}

/// 패키지의 누적 양수 범위 조회 (미등록이면 Full)
pub fn get_positive_range(ps: PartialSolution, key: String) -> VersionRange {
  case dict.get(ps.positive, key) {
    Ok(r) -> r
    Error(_) -> semver.version_range_any()
  }
}

/// 패키지의 유효 범위: positive \ negative (버전 선택/카운트에 사용)
pub fn get_effective_range(ps: PartialSolution, key: String) -> VersionRange {
  let pos = case dict.get(ps.positive, key) {
    Ok(r) -> r
    Error(_) -> semver.version_range_any()
  }
  let neg = case dict.get(ps.negative, key) {
    Ok(r) -> r
    Error(_) -> semver.version_range_empty()
  }
  semver.range_minus(pos, neg)
}

/// 패키지에 대한 결정 기록 (결정 레벨 +1)
pub fn decide(
  ps: PartialSolution,
  pkg: PackageRef,
  v: Version,
) -> PartialSolution {
  let key = term.to_key(pkg)
  let new_level = ps.current_level + 1
  let assignment = Decision(package: pkg, version: v, decision_level: new_level)
  let new_positive =
    dict.insert(ps.positive, key, semver.version_range_exact(v))
  PartialSolution(
    assignments: [assignment, ..ps.assignments],
    decisions: dict.insert(ps.decisions, key, v),
    positive: new_positive,
    negative: ps.negative,
    current_level: new_level,
  )
}

/// 유도된 Term 기록 (현재 결정 레벨 유지)
pub fn add_derivation(
  ps: PartialSolution,
  t: Term,
  cause: Incompatibility,
) -> PartialSolution {
  let key = term.to_key(term.package(t))
  let assignment =
    Derivation(
      package: term.package(t),
      term: t,
      decision_level: ps.current_level,
      cause: cause,
    )
  // 누적 범위 갱신
  let #(new_positive, new_negative) = case t {
    Positive(_, r) -> {
      let current = case dict.get(ps.positive, key) {
        Ok(existing) -> existing
        Error(_) -> semver.version_range_any()
      }
      #(
        dict.insert(ps.positive, key, semver.range_intersect(current, r)),
        ps.negative,
      )
    }
    Negative(_, r) -> {
      let current = case dict.get(ps.negative, key) {
        Ok(existing) -> existing
        Error(_) -> semver.version_range_empty()
      }
      #(
        ps.positive,
        dict.insert(ps.negative, key, semver.range_union(current, r)),
      )
    }
  }
  PartialSolution(
    assignments: [assignment, ..ps.assignments],
    decisions: ps.decisions,
    positive: new_positive,
    negative: new_negative,
    current_level: ps.current_level,
  )
}

/// target_level 이하로 백트래킹: level 초과 할당 모두 제거
pub fn backtrack_to(ps: PartialSolution, target_level: Int) -> PartialSolution {
  let kept =
    list.filter(ps.assignments, fn(a) { assignment_level(a) <= target_level })
  // 누적 범위를 남은 할당으로부터 재구축
  rebuild(kept, target_level)
}

/// Term과 현재 partial solution의 관계 평가
pub fn relation(ps: PartialSolution, t: Term) -> Relation {
  let key = term.to_key(term.package(t))
  // 결정이 있으면 정확한 버전으로 평가
  case dict.get(ps.decisions, key) {
    Ok(v) ->
      case term.satisfies_version(t, v) {
        True -> Satisfied
        False -> Contradicted
      }
    Error(_) -> {
      // 결정 없으면 누적 범위로 평가
      let accumulated = get_accumulated_range(ps, key)
      case semver.range_is_empty(accumulated) {
        True ->
          // 패키지에 대한 정보 없음 → term이 Negative면 자동 만족
          case t {
            Positive(_, _) -> Inconclusive
            Negative(_, _) -> Satisfied
          }
        False -> term.relation(t, accumulated)
      }
    }
  }
}

/// incompatibility의 term 중 가장 최근에 만족시킨 할당 찾기 (충돌 해결용)
pub fn find_satisfier(ps: PartialSolution, t: Term) -> Result(Assignment, Nil) {
  // 할당 목록을 역순(오래된 것부터)으로 순회하며
  // term이 처음 Satisfied/Contradicted 되는 시점의 할당 반환
  let reversed = list.reverse(ps.assignments)
  find_satisfier_in(reversed, t, term.to_key(term.package(t)))
}

// ---------------------------------------------------------------------------
// 내부 헬퍼
// ---------------------------------------------------------------------------

fn assignment_level(a: Assignment) -> Int {
  case a {
    Decision(decision_level: l, ..) -> l
    Derivation(decision_level: l, ..) -> l
  }
}

/// 할당 목록을 오래된 것부터 순회하면서 term이 만족되는 지점 찾기
fn find_satisfier_in(
  assignments: List(Assignment),
  t: Term,
  target_key: String,
) -> Result(Assignment, Nil) {
  do_find_satisfier(assignments, t, target_key, semver.version_range_any())
}

fn do_find_satisfier(
  assignments: List(Assignment),
  t: Term,
  target_key: String,
  accumulated: VersionRange,
) -> Result(Assignment, Nil) {
  case assignments {
    [] -> Error(Nil)
    [a, ..rest] -> {
      let a_key = assignment_key(a)
      case a_key == target_key {
        False -> do_find_satisfier(rest, t, target_key, accumulated)
        True -> {
          let new_accumulated = case a {
            Decision(version: v, ..) -> semver.version_range_exact(v)
            Derivation(term: dt, ..) ->
              case dt {
                Positive(_, r) -> semver.range_intersect(accumulated, r)
                Negative(_, r) -> semver.range_minus(accumulated, r)
              }
          }
          // 이 할당 후 term이 Satisfied인지 확인
          // AllSatisfied incompatibility에서 satisfier는 Satisfied 시점의 할당
          case term.relation(t, new_accumulated) {
            Satisfied -> Ok(a)
            _ -> do_find_satisfier(rest, t, target_key, new_accumulated)
          }
        }
      }
    }
  }
}

fn assignment_key(a: Assignment) -> String {
  case a {
    Decision(package: pkg, ..) -> term.to_key(pkg)
    Derivation(package: pkg, ..) -> term.to_key(pkg)
  }
}

/// 남은 할당으로부터 positive/negative/decisions 재구축
fn rebuild(assignments: List(Assignment), level: Int) -> PartialSolution {
  list.fold(list.reverse(assignments), new(), fn(ps, a) {
    case a {
      Decision(package: pkg, version: v, ..) -> {
        let key = term.to_key(pkg)
        PartialSolution(
          assignments: [
            Decision(..a, decision_level: assignment_level(a)),
            ..ps.assignments
          ],
          decisions: dict.insert(ps.decisions, key, v),
          positive: dict.insert(ps.positive, key, semver.version_range_exact(v)),
          negative: ps.negative,
          current_level: level,
        )
      }
      Derivation(term: t, cause: c, ..) -> {
        let key = term.to_key(term.package(t))
        let #(new_pos, new_neg) = case t {
          Positive(_, r) -> {
            let current = case dict.get(ps.positive, key) {
              Ok(existing) -> existing
              Error(_) -> semver.version_range_any()
            }
            #(
              dict.insert(ps.positive, key, semver.range_intersect(current, r)),
              ps.negative,
            )
          }
          Negative(_, r) -> {
            let current = case dict.get(ps.negative, key) {
              Ok(existing) -> existing
              Error(_) -> semver.version_range_empty()
            }
            #(
              ps.positive,
              dict.insert(ps.negative, key, semver.range_union(current, r)),
            )
          }
        }
        PartialSolution(
          assignments: [
            Derivation(
              package: term.package(t),
              term: t,
              decision_level: assignment_level(a),
              cause: c,
            ),
            ..ps.assignments
          ],
          decisions: ps.decisions,
          positive: new_pos,
          negative: new_neg,
          current_level: level,
        )
      }
    }
  })
}

/// 패키지의 유효 범위: positive ∩ ¬negative
fn get_accumulated_range(ps: PartialSolution, key: String) -> VersionRange {
  let pos = case dict.get(ps.positive, key) {
    Ok(r) -> r
    Error(_) -> semver.version_range_any()
  }
  let neg = case dict.get(ps.negative, key) {
    Ok(r) -> r
    Error(_) -> semver.version_range_empty()
  }
  semver.range_minus(pos, neg)
}
