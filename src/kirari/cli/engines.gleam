//// 런타임 엔진 버전 제약 검증 — [engines] 섹션 기반

import gleam/list
import kirari/platform
import kirari/semver
import kirari/types.{type EnginesConfig}

/// 엔진 검증 결과
pub type EngineCheckResult {
  /// 모든 제약 만족 (또는 제약 없음)
  AllSatisfied
  /// 하나 이상의 제약 위반
  ConstraintViolation(violations: List(EngineViolation))
}

/// 개별 엔진 위반 정보
pub type EngineViolation {
  EngineViolation(
    /// 엔진 이름: "gleam", "erlang", "node"
    engine: String,
    /// 선언된 제약: ">= 1.0.0"
    constraint: String,
    /// 감지된 버전: Ok("1.10.0") 또는 Error("not found")
    detected: Result(String, String),
  )
}

/// 모든 engines 제약을 현재 런타임 버전과 비교
pub fn check(engines: EnginesConfig) -> EngineCheckResult {
  let violations =
    [
      check_one("gleam", engines.gleam, platform.detect_gleam_version),
      check_one("erlang", engines.erlang, platform.detect_erlang_version),
      check_one("node", engines.node, platform.detect_node_version),
    ]
    |> list.filter_map(fn(x) { x })

  case violations {
    [] -> AllSatisfied
    vs -> ConstraintViolation(vs)
  }
}

/// 개별 엔진 체크 — 제약이 없으면 Ok(Error(Nil)) (스킵)
fn check_one(
  engine: String,
  constraint_result: Result(String, Nil),
  detect: fn() -> Result(String, String),
) -> Result(EngineViolation, Nil) {
  case constraint_result {
    Error(_) -> Error(Nil)
    Ok(constraint_str) -> {
      let detected = detect()
      case detected {
        Error(reason) ->
          Ok(EngineViolation(
            engine: engine,
            constraint: constraint_str,
            detected: Error(reason),
          ))
        Ok(version_str) ->
          case
            semver.parse_constraint(constraint_str),
            semver.parse_version(version_str)
          {
            Ok(constraint), Ok(version) ->
              case semver.satisfies(version, constraint) {
                True -> Error(Nil)
                False ->
                  Ok(EngineViolation(
                    engine: engine,
                    constraint: constraint_str,
                    detected: Ok(version_str),
                  ))
              }
            _, _ -> Error(Nil)
          }
      }
    }
  }
}
