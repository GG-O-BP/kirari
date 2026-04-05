//// PubGrub Term — 패키지에 대한 버전 범위 선언 (양수/음수)

import gleam/order
import kirari/semver.{type Version, type VersionRange}
import kirari/types.{type Registry}

/// 레지스트리 스코프 패키지 식별자
pub type PackageRef {
  PackageRef(name: String, registry: Registry)
}

/// Term: 패키지가 특정 범위에 있어야(Positive) 또는 없어야(Negative) 한다는 선언
pub type Term {
  Positive(package: PackageRef, range: VersionRange)
  Negative(package: PackageRef, range: VersionRange)
}

/// partial solution에서 Term과 누적 범위의 관계
pub type Relation {
  Satisfied
  Contradicted
  Inconclusive
}

/// Term이 참조하는 패키지
pub fn package(t: Term) -> PackageRef {
  case t {
    Positive(pkg, _) -> pkg
    Negative(pkg, _) -> pkg
  }
}

/// Term의 버전 범위
pub fn range(t: Term) -> VersionRange {
  case t {
    Positive(_, r) -> r
    Negative(_, r) -> r
  }
}

/// Term 부정: Positive ↔ Negative
pub fn negate(t: Term) -> Term {
  case t {
    Positive(pkg, r) -> Negative(pkg, r)
    Negative(pkg, r) -> Positive(pkg, r)
  }
}

/// PackageRef를 Dict 키로 사용할 문자열 생성
pub fn to_key(pkg: PackageRef) -> String {
  pkg.name <> ":" <> types.registry_to_string(pkg.registry)
}

/// 같은 패키지의 두 Term 교집합
pub fn intersect(a: Term, b: Term) -> Result(Term, Nil) {
  case to_key(package(a)) == to_key(package(b)) {
    False -> Error(Nil)
    True -> {
      let pkg = package(a)
      case a, b {
        Positive(_, ra), Positive(_, rb) ->
          Ok(Positive(pkg, semver.range_intersect(ra, rb)))
        Negative(_, ra), Negative(_, rb) ->
          Ok(Negative(pkg, semver.range_union(ra, rb)))
        Positive(_, pos), Negative(_, neg) ->
          Ok(Positive(
            pkg,
            semver.range_intersect(pos, semver.range_complement(neg)),
          ))
        Negative(_, neg), Positive(_, pos) ->
          Ok(Positive(
            pkg,
            semver.range_intersect(pos, semver.range_complement(neg)),
          ))
      }
    }
  }
}

/// 같은 패키지의 두 Term 합집합 (PubGrub resolution 피벗용)
/// 허용 버전 = a 허용 ∪ b 허용
pub fn union(a: Term, b: Term) -> Result(Term, Nil) {
  case to_key(package(a)) == to_key(package(b)) {
    False -> Error(Nil)
    True -> {
      let pkg = package(a)
      case a, b {
        Positive(_, ra), Positive(_, rb) ->
          Ok(Positive(pkg, semver.range_union(ra, rb)))
        Negative(_, ra), Negative(_, rb) ->
          Ok(Negative(pkg, semver.range_intersect(ra, rb)))
        Positive(_, r_pos), Negative(_, r_neg) ->
          Ok(Negative(pkg, semver.range_minus(r_neg, r_pos)))
        Negative(_, r_neg), Positive(_, r_pos) ->
          Ok(Negative(pkg, semver.range_minus(r_neg, r_pos)))
      }
    }
  }
}

/// Term이 항상 참인지 판정 (Negative(∅) = any = 항상 만족)
pub fn is_any(t: Term) -> Bool {
  case t {
    Negative(_, r) -> semver.range_is_empty(r)
    Positive(_, _) -> False
  }
}

/// Term이 특정 버전을 만족하는지 판정
pub fn satisfies_version(t: Term, v: Version) -> Bool {
  case t {
    Positive(_, r) -> semver.range_allows_version(r, v)
    Negative(_, r) -> !semver.range_allows_version(r, v)
  }
}

/// Term과 누적된 양수 범위의 관계 평가
/// accumulated: partial solution에서 해당 패키지의 누적 양수 범위
pub fn relation(t: Term, accumulated: VersionRange) -> Relation {
  case t {
    Positive(_, r) ->
      // accumulated ⊆ r 이면 Satisfied (누적 범위가 전부 term 안에 있음)
      // accumulated ∩ r = ∅ 이면 Contradicted
      case semver.range_subset(accumulated, r) {
        True -> Satisfied
        False ->
          case semver.range_is_empty(semver.range_intersect(accumulated, r)) {
            True -> Contradicted
            False -> Inconclusive
          }
      }
    Negative(_, r) ->
      // Negative(r): 패키지가 r에 없어야 함
      // accumulated ∩ r = ∅ 이면 Satisfied (이미 r 밖에 있음)
      // accumulated ⊆ r 이면 Contradicted (전부 r 안에 있음)
      case semver.range_is_empty(semver.range_intersect(accumulated, r)) {
        True -> Satisfied
        False ->
          case semver.range_subset(accumulated, r) {
            True -> Contradicted
            False -> Inconclusive
          }
      }
  }
}

/// Relation을 Order로 변환 (정렬용)
pub fn relation_to_order(r: Relation) -> order.Order {
  case r {
    Satisfied -> order.Lt
    Contradicted -> order.Eq
    Inconclusive -> order.Gt
  }
}
