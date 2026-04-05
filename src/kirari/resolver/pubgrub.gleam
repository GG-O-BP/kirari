//// PubGrub Solver — 백트래킹 기반 의존성 해결 알고리즘

import gleam/dict.{type Dict}
import gleam/list
import gleam/order
import gleam/result
import gleam/string
import kirari/resolver/incompatibility.{
  type Incompatibility, ConflictCause, DependencyOn, Incompatibility, NoVersions,
  Root,
}
import kirari/resolver/partial_solution.{type Assignment, Decision, Derivation}
import kirari/resolver/term.{type PackageRef, Negative, Positive}
import kirari/semver.{type Version}
import kirari/types.{
  type Dependency, type KirLock, type Registry, type ResolvedPackage, Dependency,
  Hex, Npm, ResolvedPackage,
}

/// resolver 에러 (pubgrub 내부에서 사용, resolver.gleam으로 전파)
pub type PubGrubError {
  ResolutionConflict(
    explanation: String,
    root_cause: Result(Incompatibility, Nil),
    version_cache: Dict(String, List(VersionInfoCompact)),
  )
  PkgNotFound(name: String, registry: Registry)
  RegError(detail: String)
}

/// 레지스트리 조회 함수 타입 (resolver.gleam에서 주입)
pub type FetchVersions =
  fn(String, Registry) -> Result(List(VersionInfoCompact), PubGrubError)

/// 선택된 버전의 의존성 조회 함수 타입
pub type FetchReleaseDeps =
  fn(String, String, Registry) ->
    Result(#(List(Dependency), String), PubGrubError)

/// solver가 필요로 하는 버전 정보 (resolver.VersionInfo의 축약)
pub type VersionInfoCompact {
  VersionInfoCompact(
    version: String,
    published_at: String,
    dependencies: List(Dependency),
    optional_dependencies: List(Dependency),
    os: List(String),
    cpu: List(String),
    license: String,
  )
}

/// solver 컨텍스트 (불변, DI)
pub type SolverContext {
  SolverContext(
    fetch_versions: FetchVersions,
    fetch_deps: FetchReleaseDeps,
    existing_lock: Result(KirLock, Nil),
    exclude_newer: Result(String, Nil),
    overrides: Dict(String, String),
    /// 병렬 prefetch된 버전 캐시 — solver 시작 시 version_cache 초기값
    prefetch_cache: Dict(String, List(VersionInfoCompact)),
    /// npm alias 매핑: local_name:registry → real_name
    alias_map: Dict(String, String),
  )
}

/// solver 내부 상태 (accumulator)
type SolverState {
  SolverState(
    ps: partial_solution.PartialSolution,
    incompatibilities: Dict(String, List(Incompatibility)),
    version_cache: Dict(String, List(VersionInfoCompact)),
  )
}

/// 해결 결과: 패키��� 키 → (ResolvedPackage, VersionInfoCompact)
pub type SolveResult {
  SolveResult(entries: Dict(String, #(ResolvedPackage, VersionInfoCompact)))
}

// ---------------------------------------------------------------------------
// 공개 API
// ---------------------------------------------------------------------------

/// PubGrub 해결 메인 진입점
pub fn solve(
  direct_deps: List(Dependency),
  ctx: SolverContext,
) -> Result(SolveResult, PubGrubError) {
  let state =
    SolverState(
      ps: partial_solution.new(),
      incompatibilities: dict.new(),
      version_cache: ctx.prefetch_cache,
    )
  // 루트 패키지 참조 (가상)
  let root_ref = term.PackageRef(name: "$root", registry: Hex)
  let root_key = term.to_key(root_ref)

  // 루트 의존성마다 incompatibility 추가 (오버라이드 적용)
  let state =
    list.fold(direct_deps, state, fn(s, dep) {
      let dep = apply_override(dep, ctx.overrides)
      let dep_ref = term.PackageRef(name: dep.name, registry: dep.registry)
      let constraint_range = parse_direct_dep_range(dep)
      let inc =
        incompatibility.new(
          [
            Positive(root_ref, semver.version_range_any()),
            Negative(dep_ref, constraint_range),
          ],
          Root,
        )
      add_incompatibility(s, inc)
    })

  // 루트 결정: $root = 0.0.0
  let root_version = make_root_version()
  let state =
    SolverState(
      ..state,
      ps: partial_solution.decide(state.ps, root_ref, root_version),
    )

  // 메인 루프 시작
  main_loop(state, root_key, ctx, direct_deps)
}

// ---------------------------------------------------------------------------
// 메인 루프
// ---------------------------------------------------------------------------

fn main_loop(
  state: SolverState,
  changed: String,
  ctx: SolverContext,
  direct_deps: List(Dependency),
) -> Result(SolveResult, PubGrubError) {
  use state <- result.try(unit_propagation(state, [changed]))
  case choose_next_package(state, direct_deps) {
    Error(_) -> Ok(extract_solution(state, ctx))
    Ok(#(pkg_key, pkg_ref, registry)) -> {
      use #(state, versions) <- result.try(get_versions(
        state,
        ctx,
        pkg_ref.name,
        registry,
      ))
      let compatible =
        filter_compatible_versions(state, pkg_key, versions, registry, ctx)
      case pick_best_version(compatible, pkg_key, ctx) {
        Error(_) -> {
          let range = partial_solution.get_effective_range(state.ps, pkg_key)
          let inc =
            incompatibility.new(
              [Positive(pkg_ref, range)],
              NoVersions(
                package: pkg_ref.name,
                range_desc: semver.range_to_string(range),
              ),
            )
          let state = add_incompatibility(state, inc)
          main_loop(state, pkg_key, ctx, direct_deps)
        }
        Ok(chosen) -> {
          use state <- result.try(add_version_dependencies(
            state,
            ctx,
            pkg_ref,
            chosen,
          ))
          let v = case semver.parse_version(chosen.version) {
            Ok(v) -> v
            Error(_) -> make_root_version()
          }
          let state =
            SolverState(
              ..state,
              ps: partial_solution.decide(state.ps, pkg_ref, v),
            )
          main_loop(state, pkg_key, ctx, direct_deps)
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Unit Propagation
// ---------------------------------------------------------------------------

fn unit_propagation(
  state: SolverState,
  changed_queue: List(String),
) -> Result(SolverState, PubGrubError) {
  case changed_queue {
    [] -> Ok(state)
    [pkg_key, ..rest_queue] -> {
      let incs = case dict.get(state.incompatibilities, pkg_key) {
        Ok(list) -> list
        Error(_) -> []
      }
      propagate_incompatibilities(state, incs, rest_queue)
    }
  }
}

fn propagate_incompatibilities(
  state: SolverState,
  incs: List(Incompatibility),
  changed_queue: List(String),
) -> Result(SolverState, PubGrubError) {
  case incs {
    [] -> unit_propagation(state, changed_queue)
    [inc, ..rest_incs] -> {
      case check_incompatibility(state, inc) {
        // 모든 term 만족됨 → 충돌!
        AllSatisfied -> {
          use state <- result.try(resolve_conflict(state, inc))
          let changed_keys = dict.keys(state.incompatibilities)
          unit_propagation(state, changed_keys)
        }
        // 하나만 미결정 → 유도
        AlmostSatisfied(unsatisfied_key, unsatisfied_term) -> {
          let negated = term.negate(unsatisfied_term)
          let state =
            SolverState(
              ..state,
              ps: partial_solution.add_derivation(state.ps, negated, inc),
            )
          let new_queue = case list.contains(changed_queue, unsatisfied_key) {
            True -> changed_queue
            False -> [unsatisfied_key, ..changed_queue]
          }
          propagate_incompatibilities(state, rest_incs, new_queue)
        }
        // 이미 모순 또는 불확정 → 건너뜀
        NotRelevant ->
          propagate_incompatibilities(state, rest_incs, changed_queue)
      }
    }
  }
}

type IncompatibilityCheck {
  AllSatisfied
  AlmostSatisfied(key: String, term: term.Term)
  NotRelevant
}

fn check_incompatibility(
  state: SolverState,
  inc: Incompatibility,
) -> IncompatibilityCheck {
  let terms = dict.to_list(inc.terms)
  do_check_incompatibility(state, terms, Error(Nil))
}

fn do_check_incompatibility(
  state: SolverState,
  terms: List(#(String, term.Term)),
  undecided: Result(#(String, term.Term), Nil),
) -> IncompatibilityCheck {
  case terms {
    [] ->
      case undecided {
        Error(_) -> AllSatisfied
        Ok(#(key, t)) -> AlmostSatisfied(key, t)
      }
    [#(key, t), ..rest] -> {
      let rel = partial_solution.relation(state.ps, t)
      case rel {
        term.Satisfied -> do_check_incompatibility(state, rest, undecided)
        term.Contradicted -> NotRelevant
        term.Inconclusive ->
          case undecided {
            Ok(_) -> NotRelevant
            Error(_) -> do_check_incompatibility(state, rest, Ok(#(key, t)))
          }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Conflict Resolution
// ---------------------------------------------------------------------------

fn resolve_conflict(
  state: SolverState,
  inc: Incompatibility,
) -> Result(SolverState, PubGrubError) {
  do_resolve_conflict(state, inc)
}

fn do_resolve_conflict(
  state: SolverState,
  inc: Incompatibility,
) -> Result(SolverState, PubGrubError) {
  case
    partial_solution.decision_level(state.ps) <= 0
    || incompatibility.term_count(inc) == 0
    || only_has_root(inc)
  {
    True ->
      Error(ResolutionConflict(
        incompatibility.explain(inc),
        Ok(inc),
        state.version_cache,
      ))
    False -> {
      let terms = dict.to_list(inc.terms)
      // 모든 term의 satisfier 수집
      let all_satisfiers = collect_all_satisfiers(state, terms)
      case find_most_recent_in(state, all_satisfiers) {
        Error(_) ->
          Error(ResolutionConflict(
            incompatibility.explain(inc),
            Ok(inc),
            state.version_cache,
          ))
        Ok(#(satisfier, satisfier_term, satisfier_level)) -> {
          // 두 번째 satisfier의 레벨 (prior satisfier level)
          let prior_level =
            find_prior_satisfier_level(all_satisfiers, satisfier)
          case satisfier_level < 1 {
            True ->
              Error(ResolutionConflict(
                incompatibility.explain(inc),
                Ok(inc),
                state.version_cache,
              ))
            False ->
              case satisfier {
                Derivation(cause: cause, ..)
                  if satisfier_level == prior_level || prior_level < 1
                -> {
                  // 같은 레벨이거나 backtrack 불가 → cause와 resolve하여 계속
                  let new_inc = resolve_incompatibilities(inc, cause)
                  let state = add_incompatibility(state, new_inc)
                  do_resolve_conflict(state, new_inc)
                }
                _ -> {
                  // Decision이거나 backtrack 가능한 Derivation → prior_level로 backtrack
                  let backtrack_level = prior_level
                  case backtrack_level < 1 {
                    True ->
                      Error(ResolutionConflict(
                        incompatibility.explain(inc),
                        Ok(inc),
                        state.version_cache,
                      ))
                    False -> {
                      let new_ps =
                        partial_solution.backtrack_to(state.ps, backtrack_level)
                      let state = SolverState(..state, ps: new_ps)
                      let state = add_incompatibility(state, inc)
                      let negated = term.negate(satisfier_term)
                      let state =
                        SolverState(
                          ..state,
                          ps: partial_solution.add_derivation(
                            state.ps,
                            negated,
                            inc,
                          ),
                        )
                      Ok(state)
                    }
                  }
                }
              }
          }
        }
      }
    }
  }
}

fn only_has_root(inc: Incompatibility) -> Bool {
  let keys = incompatibility.packages(inc)
  list.all(keys, fn(k) { k == "$root:hex" })
}

/// 모든 term의 satisfier를 수집
fn collect_all_satisfiers(
  state: SolverState,
  terms: List(#(String, term.Term)),
) -> List(#(Assignment, term.Term, Int)) {
  list.filter_map(terms, fn(entry) {
    let #(_key, t) = entry
    case partial_solution.find_satisfier(state.ps, t) {
      Ok(satisfier) -> {
        let level = case satisfier {
          Decision(decision_level: l, ..) -> l
          Derivation(decision_level: l, ..) -> l
        }
        Ok(#(satisfier, t, level))
      }
      Error(_) -> Error(Nil)
    }
  })
}

/// assignment 목록에서 가장 최근 satisfier 찾기
fn find_most_recent_in(
  state: SolverState,
  satisfiers: List(#(Assignment, term.Term, Int)),
) -> Result(#(Assignment, term.Term, Int), Nil) {
  let assignments = partial_solution.assignments(state.ps)
  do_find_most_recent(assignments, satisfiers)
}

fn do_find_most_recent(
  assignments: List(Assignment),
  candidates: List(#(Assignment, term.Term, Int)),
) -> Result(#(Assignment, term.Term, Int), Nil) {
  case assignments {
    [] ->
      case candidates {
        [first, ..] -> Ok(first)
        [] -> Error(Nil)
      }
    [a, ..rest] ->
      case list.find(candidates, fn(c) { same_assignment(c.0, a) }) {
        Ok(found) -> Ok(found)
        Error(_) -> do_find_most_recent(rest, candidates)
      }
  }
}

/// 가장 최근 satisfier를 제외한 나머지 중 최고 레벨 (prior satisfier level)
fn find_prior_satisfier_level(
  satisfiers: List(#(Assignment, term.Term, Int)),
  most_recent: Assignment,
) -> Int {
  list.fold(satisfiers, 0, fn(max_level, entry) {
    let #(s, _, level) = entry
    case same_assignment(s, most_recent) {
      True -> max_level
      False ->
        case level > max_level {
          True -> level
          False -> max_level
        }
    }
  })
}

/// 두 incompatibility를 결합 (PubGrub resolution)
/// 피벗 패키지(양쪽에 반대 극성으로 등장)의 term은 상쇄하여 제거
/// 비피벗 패키지는 intersect로 병합
fn resolve_incompatibilities(
  a: Incompatibility,
  b: Incompatibility,
) -> Incompatibility {
  let combined_terms =
    dict.fold(a.terms, b.terms, fn(acc, key, a_term) {
      case dict.get(acc, key) {
        Ok(b_term) -> {
          case is_opposite_polarity(a_term, b_term) {
            True -> dict.delete(acc, key)
            False -> {
              case term.intersect(a_term, b_term) {
                Ok(merged) ->
                  case is_trivial(merged) {
                    True -> dict.delete(acc, key)
                    False -> dict.insert(acc, key, merged)
                  }
                Error(_) -> dict.insert(acc, key, a_term)
              }
            }
          }
        }
        Error(_) -> dict.insert(acc, key, a_term)
      }
    })
  Incompatibility(terms: combined_terms, cause: ConflictCause(a, b))
}

/// 두 term의 극성이 반대인지 판정 (피벗 상쇄 조건)
fn is_opposite_polarity(a: term.Term, b: term.Term) -> Bool {
  case a, b {
    Positive(_, _), Negative(_, _) | Negative(_, _), Positive(_, _) -> True
    _, _ -> False
  }
}

/// term이 의미 없는지 (Positive(Empty) = 항상 거짓, Negative(Full) = 항상 거짓)
fn is_trivial(t: term.Term) -> Bool {
  case t {
    Positive(_, r) -> semver.range_is_empty(r)
    Negative(_, r) -> semver.range_is_empty(semver.range_complement(r))
  }
}

fn same_assignment(a: Assignment, b: Assignment) -> Bool {
  case a, b {
    Decision(package: pa, version: va, decision_level: la),
      Decision(package: pb, version: vb, decision_level: lb)
    ->
      term.to_key(pa) == term.to_key(pb)
      && semver.to_string(va) == semver.to_string(vb)
      && la == lb
    Derivation(package: pa, decision_level: la, ..),
      Derivation(package: pb, decision_level: lb, ..)
    -> term.to_key(pa) == term.to_key(pb) && la == lb
    _, _ -> False
  }
}

// ---------------------------------------------------------------------------
// 패키지 선택 + 버전 선택
// ---------------------------------------------------------------------------

fn choose_next_package(
  state: SolverState,
  direct_deps: List(Dependency),
) -> Result(#(String, PackageRef, Registry), Nil) {
  // incompatibility에 등장하지만 아직 결정되지 않은 패키지들
  let decided = partial_solution.decided_packages(state.ps)
  let undecided_keys =
    dict.keys(state.incompatibilities)
    |> list.filter(fn(key) { key != "$root:hex" && !dict.has_key(decided, key) })

  case undecided_keys {
    [] -> Error(Nil)
    _ -> {
      // 직접 의존성에서 패키지 정보 파싱
      let all_deps = collect_known_packages(state, direct_deps)
      // 후보 버전 수 최소인 패키지 선택 (smallest domain heuristic)
      let scored =
        list.filter_map(undecided_keys, fn(key) {
          case dict.get(all_deps, key) {
            Ok(#(name, registry)) -> {
              let range = partial_solution.get_effective_range(state.ps, key)
              let count = case dict.get(state.version_cache, key) {
                Ok(versions) ->
                  list.count(versions, fn(vi) {
                    case semver.parse_version(vi.version) {
                      Ok(v) -> semver.range_allows_version(range, v)
                      Error(_) -> False
                    }
                  })
                Error(_) -> 999_999
              }
              Ok(#(
                key,
                term.PackageRef(name: name, registry: registry),
                registry,
                count,
              ))
            }
            Error(_) -> Error(Nil)
          }
        })

      case list.sort(scored, fn(a, b) { int_compare(a.3, b.3) }) {
        [#(key, ref, reg, _), ..] -> Ok(#(key, ref, reg))
        [] -> Error(Nil)
      }
    }
  }
}

fn int_compare(a: Int, b: Int) -> order.Order {
  case a < b {
    True -> order.Lt
    False ->
      case a == b {
        True -> order.Eq
        False -> order.Gt
      }
  }
}

/// 모든 알려진 패키지의 name/registry 수집
fn collect_known_packages(
  state: SolverState,
  direct_deps: List(Dependency),
) -> Dict(String, #(String, Registry)) {
  let from_deps =
    list.fold(direct_deps, dict.new(), fn(acc, d) {
      let key = d.name <> ":" <> types.registry_to_string(d.registry)
      dict.insert(acc, key, #(d.name, d.registry))
    })
  // incompatibility에 등장하는 패키지도 포함
  dict.fold(state.incompatibilities, from_deps, fn(acc, key, _) {
    case dict.has_key(acc, key) {
      True -> acc
      False -> {
        case parse_package_key(key) {
          Ok(#(name, registry)) -> dict.insert(acc, key, #(name, registry))
          Error(_) -> acc
        }
      }
    }
  })
}

fn parse_package_key(key: String) -> Result(#(String, Registry), Nil) {
  case string.split_once(key, ":") {
    Ok(#(name, reg_str)) ->
      case reg_str {
        "hex" -> Ok(#(name, Hex))
        "npm" -> Ok(#(name, Npm))
        _ -> Error(Nil)
      }
    Error(_) -> Error(Nil)
  }
}

fn filter_compatible_versions(
  state: SolverState,
  pkg_key: String,
  versions: List(VersionInfoCompact),
  registry: Registry,
  ctx: SolverContext,
) -> List(VersionInfoCompact) {
  let range = partial_solution.get_effective_range(state.ps, pkg_key)
  versions
  |> list.filter(fn(vi) {
    case semver.parse_version(vi.version) {
      Ok(v) -> semver.range_allows_version(range, v)
      Error(_) -> False
    }
  })
  |> list.filter(fn(vi) { matches_platform(vi, registry) })
  |> filter_by_cutoff(ctx.exclude_newer)
}

fn pick_best_version(
  versions: List(VersionInfoCompact),
  pkg_key: String,
  ctx: SolverContext,
) -> Result(VersionInfoCompact, Nil) {
  // lock 우선
  let lock_version = case ctx.existing_lock {
    Ok(lock) ->
      list.find(lock.packages, fn(p) {
        let key = p.name <> ":" <> types.registry_to_string(p.registry)
        key == pkg_key
      })
      |> result.map(fn(p) { p.version })
    Error(_) -> Error(Nil)
  }

  case lock_version {
    Ok(lv) -> {
      case list.find(versions, fn(vi) { vi.version == lv }) {
        Ok(locked) -> Ok(locked)
        Error(_) -> pick_highest(versions)
      }
    }
    Error(_) -> pick_highest(versions)
  }
}

fn pick_highest(
  versions: List(VersionInfoCompact),
) -> Result(VersionInfoCompact, Nil) {
  let sorted =
    list.sort(versions, fn(a, b) {
      case semver.parse_version(a.version), semver.parse_version(b.version) {
        Ok(va), Ok(vb) -> semver.compare(vb, va)
        _, _ -> string.compare(b.version, a.version)
      }
    })
  case sorted {
    [best, ..] -> Ok(best)
    [] -> Error(Nil)
  }
}

// ---------------------------------------------------------------------------
// 의존성 incompatibility 추가
// ---------------------------------------------------------------------------

fn add_version_dependencies(
  state: SolverState,
  ctx: SolverContext,
  pkg_ref: PackageRef,
  chosen: VersionInfoCompact,
) -> Result(SolverState, PubGrubError) {
  // 먼저 enrichment 시도 (Hex에서 의존성이 비어있을 때)
  use deps <- result.try(enrich_deps(chosen, pkg_ref, ctx))

  let all_deps = list.map(deps, apply_override(_, ctx.overrides))

  let v = case semver.parse_version(chosen.version) {
    Ok(v) -> v
    Error(_) -> make_root_version()
  }
  let exact_range = semver.version_range_exact(v)

  let state =
    list.fold(all_deps, state, fn(s, dep) {
      let dep_ref = term.PackageRef(name: dep.name, registry: dep.registry)
      let dep_range = parse_dep_range(dep)
      let inc =
        incompatibility.new(
          [
            Positive(pkg_ref, exact_range),
            Negative(dep_ref, dep_range),
          ],
          DependencyOn(
            package: pkg_ref.name,
            version: chosen.version,
            dep_name: dep.name,
            dep_constraint: dep.version_constraint,
          ),
        )
      add_incompatibility(s, inc)
    })

  // 알 수 없는 패키지의 버전 캐시 사전 조회는 하지 않음 (lazy)
  Ok(state)
}

fn enrich_deps(
  chosen: VersionInfoCompact,
  pkg_ref: PackageRef,
  ctx: SolverContext,
) -> Result(List(Dependency), PubGrubError) {
  case chosen.dependencies {
    [] -> {
      use #(deps, _deprecated) <- result.try(ctx.fetch_deps(
        pkg_ref.name,
        chosen.version,
        pkg_ref.registry,
      ))
      Ok(deps)
    }
    deps -> Ok(deps)
  }
}

// ---------------------------------------------------------------------------
// 솔루션 추출
// ---------------------------------------------------------------------------

fn extract_solution(state: SolverState, ctx: SolverContext) -> SolveResult {
  let decisions = partial_solution.decided_packages(state.ps)
  let entries =
    dict.fold(decisions, dict.new(), fn(acc, key, version) {
      case key == "$root:hex" {
        True -> acc
        False -> {
          case parse_package_key(key) {
            Ok(#(name, registry)) -> {
              let version_str = semver.to_string(version)
              let vi = find_version_info(state, key, version_str)
              let pkg_name_result = case dict.get(ctx.alias_map, key) {
                Ok(real) -> Ok(real)
                Error(_) -> Error(Nil)
              }
              let pkg =
                ResolvedPackage(
                  name: name,
                  version: version_str,
                  registry: registry,
                  sha256: "",
                  has_scripts: False,
                  platform: Error(Nil),
                  license: vi.license,
                  dev: False,
                  package_name: pkg_name_result,
                  git_source: Error(Nil),
                  url_source: Error(Nil),
                )
              // lock에서 sha256 복원
              let pkg = case ctx.existing_lock {
                Ok(lock) ->
                  case
                    list.find(lock.packages, fn(p) {
                      p.name == name
                      && p.registry == registry
                      && p.version == version_str
                    })
                  {
                    Ok(locked) ->
                      ResolvedPackage(
                        ..pkg,
                        sha256: locked.sha256,
                        has_scripts: locked.has_scripts,
                        platform: locked.platform,
                      )
                    Error(_) -> pkg
                  }
                Error(_) -> pkg
              }
              dict.insert(acc, key, #(pkg, vi))
            }
            Error(_) -> acc
          }
        }
      }
    })
  SolveResult(entries: entries)
}

fn find_version_info(
  state: SolverState,
  key: String,
  version_str: String,
) -> VersionInfoCompact {
  case dict.get(state.version_cache, key) {
    Ok(versions) ->
      case list.find(versions, fn(vi) { vi.version == version_str }) {
        Ok(vi) -> vi
        Error(_) -> empty_version_info(version_str)
      }
    Error(_) -> empty_version_info(version_str)
  }
}

fn empty_version_info(version: String) -> VersionInfoCompact {
  VersionInfoCompact(
    version: version,
    published_at: "",
    dependencies: [],
    optional_dependencies: [],
    os: [],
    cpu: [],
    license: "",
  )
}

// ---------------------------------------------------------------------------
// 헬퍼
// ---------------------------------------------------------------------------

fn add_incompatibility(state: SolverState, inc: Incompatibility) -> SolverState {
  let new_incs =
    list.fold(
      incompatibility.packages(inc),
      state.incompatibilities,
      fn(acc, key) {
        let existing = case dict.get(acc, key) {
          Ok(l) -> l
          Error(_) -> []
        }
        dict.insert(acc, key, [inc, ..existing])
      },
    )
  SolverState(..state, incompatibilities: new_incs)
}

fn get_versions(
  state: SolverState,
  ctx: SolverContext,
  name: String,
  registry: Registry,
) -> Result(#(SolverState, List(VersionInfoCompact)), PubGrubError) {
  let key = name <> ":" <> types.registry_to_string(registry)
  case dict.get(state.version_cache, key) {
    Ok(cached) -> Ok(#(state, cached))
    Error(_) -> {
      use versions <- result.try(ctx.fetch_versions(name, registry))
      let new_cache = dict.insert(state.version_cache, key, versions)
      Ok(#(SolverState(..state, version_cache: new_cache), versions))
    }
  }
}

fn parse_direct_dep_range(dep: Dependency) -> semver.VersionRange {
  case semver.parse_constraint(dep.version_constraint) {
    Ok(c) -> semver.constraint_to_range(c)
    Error(_) -> semver.version_range_any()
  }
}

fn parse_dep_range(dep: Dependency) -> semver.VersionRange {
  let constraint = case dep.registry {
    Hex -> semver.parse_hex_constraint(dep.version_constraint)
    Npm -> semver.parse_npm_constraint(dep.version_constraint)
    types.Git | types.Url -> semver.parse_hex_constraint(">= 0.0.0")
  }
  case constraint {
    Ok(c) -> semver.constraint_to_range(c)
    Error(_) -> semver.version_range_any()
  }
}

fn make_root_version() -> Version {
  semver.zero()
}

fn matches_platform(vi: VersionInfoCompact, registry: Registry) -> Bool {
  case registry {
    Hex | types.Git | types.Url -> True
    Npm ->
      check_platform_list(vi.os, get_platform_os())
      && check_platform_list(vi.cpu, get_platform_arch())
  }
}

fn check_platform_list(allowed: List(String), current: String) -> Bool {
  case allowed {
    [] -> True
    _ -> {
      let has_exclude = list.any(allowed, fn(s) { string.starts_with(s, "!") })
      case has_exclude {
        True -> !list.contains(allowed, "!" <> current)
        False -> list.contains(allowed, current)
      }
    }
  }
}

@external(erlang, "kirari_ffi", "get_platform_os")
fn get_platform_os() -> String

@external(erlang, "kirari_ffi", "get_platform_arch")
fn get_platform_arch() -> String

/// 오버라이드 대상이면 제약을 교체
fn apply_override(
  dep: Dependency,
  overrides: Dict(String, String),
) -> Dependency {
  let key = dep.name <> ":" <> types.registry_to_string(dep.registry)
  case dict.get(overrides, key) {
    Ok(override_constraint) ->
      Dependency(..dep, version_constraint: override_constraint)
    Error(_) -> dep
  }
}

fn filter_by_cutoff(
  versions: List(VersionInfoCompact),
  exclude_newer: Result(String, Nil),
) -> List(VersionInfoCompact) {
  case exclude_newer {
    Error(_) -> versions
    Ok(cutoff) ->
      list.filter(versions, fn(vi) {
        case vi.published_at {
          "" -> True
          ts -> string.compare(ts, cutoff) == order.Lt || ts == cutoff
        }
      })
  }
}
