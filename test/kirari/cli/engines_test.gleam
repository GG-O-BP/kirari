//// engines.gleam 단위 테스트

import kirari/cli/engines
import kirari/types

pub fn no_constraints_always_passes_test() {
  let cfg = types.default_engines_config()
  assert engines.check(cfg) == engines.AllSatisfied
}

pub fn gleam_constraint_satisfied_test() {
  // 현재 실행 중인 Gleam이 존재하므로 낮은 제약은 통과해야 함
  let cfg =
    types.EnginesConfig(
      gleam: Ok(">= 0.1.0"),
      erlang: Error(Nil),
      node: Error(Nil),
    )
  assert engines.check(cfg) == engines.AllSatisfied
}

pub fn erlang_constraint_satisfied_test() {
  // 현재 실행 중인 Erlang이 존재하므로 낮은 제약은 통과해야 함
  let cfg =
    types.EnginesConfig(
      gleam: Error(Nil),
      erlang: Ok(">= 20"),
      node: Error(Nil),
    )
  assert engines.check(cfg) == engines.AllSatisfied
}

pub fn gleam_constraint_violated_test() {
  // 비현실적으로 높은 제약 → 위반
  let cfg =
    types.EnginesConfig(
      gleam: Ok(">= 999.0.0"),
      erlang: Error(Nil),
      node: Error(Nil),
    )
  case engines.check(cfg) {
    engines.ConstraintViolation(violations) -> {
      assert violations != []
      let assert [v] = violations
      assert v.engine == "gleam"
      assert v.constraint == ">= 999.0.0"
    }
    engines.AllSatisfied -> panic as "expected violation"
  }
}

pub fn erlang_constraint_violated_test() {
  let cfg =
    types.EnginesConfig(
      gleam: Error(Nil),
      erlang: Ok(">= 999"),
      node: Error(Nil),
    )
  case engines.check(cfg) {
    engines.ConstraintViolation(violations) -> {
      let assert [v] = violations
      assert v.engine == "erlang"
    }
    engines.AllSatisfied -> panic as "expected violation"
  }
}

pub fn multiple_violations_test() {
  let cfg =
    types.EnginesConfig(
      gleam: Ok(">= 999.0.0"),
      erlang: Ok(">= 999"),
      node: Error(Nil),
    )
  case engines.check(cfg) {
    engines.ConstraintViolation(violations) -> {
      assert violations != []
    }
    engines.AllSatisfied -> panic as "expected violations"
  }
}
