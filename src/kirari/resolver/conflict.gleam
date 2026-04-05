//// Conflict Analysis — 충돌 시 구조화된 원인 분석 + 대안 제안

import gleam/dict.{type Dict}
import gleam/list
import gleam/result
import gleam/string
import kirari/resolver/incompatibility.{
  type Incompatibility, type IncompatibilityCause, ConflictCause, DependencyOn,
  NoVersions, Root,
}
import kirari/resolver/term.{Negative, Positive}
import kirari/semver
import kirari/types.{type Dependency, type Registry, Hex, Npm}

// ---------------------------------------------------------------------------
// 공개 타입
// ---------------------------------------------------------------------------

/// 누가 어떤 버전 범위를 요구하는지
pub type ConflictRequirer {
  ConflictRequirer(package: String, version: String, required_range: String)
}

/// 충돌 원인 분류
pub type ConflictCause {
  /// 두 패키지가 공유 의존성의 호환 불가능한 버전을 요구
  VersionConflict(package: String, required_by: List(ConflictRequirer))
  /// 요구 범위에 맞는 버전이 없음
  NoMatchingVersion(
    package: String,
    required_range: String,
    available_versions: List(String),
  )
  /// 직접 제약이 해결 불가능
  ImpossibleConstraint(package: String, constraint: String)
}

/// 구체적 해결 제안
pub type Suggestion {
  /// 직접 의존성 제약 완화
  RelaxConstraint(package: String, current: String, suggested: String)
  /// [overrides] / [npm-overrides]에 추가
  AddOverride(package: String, registry: Registry, suggested: String)
  /// 직접 의존성의 다른 버전 사용
  UseVersion(package: String, current: String, suggested_version: String)
  /// 충돌하는 패키지 제거
  RemovePackage(package: String)
}

/// 전체 충돌 리포트
pub type ConflictReport {
  ConflictReport(
    explanation: String,
    causes: List(ConflictCause),
    suggestions: List(Suggestion),
    dependency_chains: List(List(String)),
  )
}

// ---------------------------------------------------------------------------
// 공개 API
// ---------------------------------------------------------------------------

/// incompatibility tree를 DFS로 분석하여 구조화된 원인 추출
pub fn analyze(inc: Incompatibility) -> List(ConflictCause) {
  let leaf_causes = collect_leaf_causes(inc, [])
  let dep_infos = collect_dependency_infos(leaf_causes)
  let no_version_causes = collect_no_version_causes(leaf_causes)
  let impossible_causes = collect_impossible_causes(leaf_causes, inc)

  // DependencyOn 원인들을 target별로 그룹핑 → 2+ requirer면 VersionConflict
  let version_conflicts = build_version_conflicts(dep_infos)

  list.flatten([version_conflicts, no_version_causes, impossible_causes])
  |> deduplicate_causes
}

/// 원인 + 가용 버전 목록으로 대안 제안 생성
pub fn suggest(
  causes: List(ConflictCause),
  direct_deps: List(Dependency),
  available_versions: Dict(String, List(String)),
) -> List(Suggestion) {
  list.flat_map(causes, fn(cause) {
    suggest_for_cause(cause, direct_deps, available_versions)
  })
  |> deduplicate_suggestions
}

/// 의존성 체인 추출 (root → ... → conflict)
pub fn extract_chains(inc: Incompatibility) -> List(List(String)) {
  do_extract_chains(inc, [])
  |> list.unique
}

/// 전체 리포트 빌드
pub fn build_report(
  inc: Incompatibility,
  direct_deps: List(Dependency),
  available_versions: Dict(String, List(String)),
) -> ConflictReport {
  let causes = analyze(inc)
  let suggestions = suggest(causes, direct_deps, available_versions)
  let chains = extract_chains(inc)
  ConflictReport(
    explanation: incompatibility.explain(inc),
    causes: causes,
    suggestions: suggestions,
    dependency_chains: chains,
  )
}

/// 사람이 읽을 수 있는 포맷
pub fn format_report(report: ConflictReport) -> String {
  let header = "dependency resolution failed:\n"
  let causes_section = format_causes(report.causes)
  let chains_section = format_chains(report.dependency_chains)
  let suggestions_section = format_suggestions(report.suggestions)
  header <> causes_section <> chains_section <> suggestions_section
}

// ---------------------------------------------------------------------------
// 분석: leaf cause 수집
// ---------------------------------------------------------------------------

/// DFS로 incompatibility tree 순회, leaf cause 수집
fn collect_leaf_causes(
  inc: Incompatibility,
  acc: List(IncompatibilityCause),
) -> List(IncompatibilityCause) {
  case inc.cause {
    ConflictCause(left, right) -> {
      let acc = collect_leaf_causes(left, acc)
      collect_leaf_causes(right, acc)
    }
    cause -> [cause, ..acc]
  }
}

/// DependencyInfo: 누가 어떤 패키지의 어떤 범위를 요구하는지
type DepInfo {
  DepInfo(
    source_package: String,
    source_version: String,
    target_package: String,
    target_constraint: String,
  )
}

fn collect_dependency_infos(causes: List(IncompatibilityCause)) -> List(DepInfo) {
  list.filter_map(causes, fn(c) {
    case c {
      DependencyOn(
        package: pkg,
        version: ver,
        dep_name: dep,
        dep_constraint: constraint,
      ) ->
        Ok(DepInfo(
          source_package: pkg,
          source_version: ver,
          target_package: dep,
          target_constraint: constraint,
        ))
      _ -> Error(Nil)
    }
  })
}

fn collect_no_version_causes(
  causes: List(IncompatibilityCause),
) -> List(ConflictCause) {
  list.filter_map(causes, fn(c) {
    case c {
      NoVersions(package: pkg, range_desc: range) ->
        Ok(
          NoMatchingVersion(
            package: pkg,
            required_range: range,
            available_versions: [],
          ),
        )
      _ -> Error(Nil)
    }
  })
}

fn collect_impossible_causes(
  leaf_causes: List(IncompatibilityCause),
  root_inc: Incompatibility,
) -> List(ConflictCause) {
  // Root cause + 전체 incompatibility의 terms에서 직접 제약 불가능 감지
  let has_root =
    list.any(leaf_causes, fn(c) {
      case c {
        Root -> True
        _ -> False
      }
    })
  case has_root {
    False -> []
    True -> {
      // Root incompatibility의 terms에서 직접 제약이 불만족인 패키지 추출
      let root_terms =
        dict.values(root_inc.terms)
        |> list.filter_map(fn(t) {
          case t {
            Positive(pkg, range) ->
              Ok(ImpossibleConstraint(
                package: pkg.name,
                constraint: semver.range_to_string(range),
              ))
            Negative(pkg, range) ->
              Ok(ImpossibleConstraint(
                package: pkg.name,
                constraint: "not " <> semver.range_to_string(range),
              ))
          }
        })
      // $root 자체는 제외
      list.filter(root_terms, fn(c) {
        case c {
          ImpossibleConstraint(package: "$root", ..) -> False
          _ -> True
        }
      })
    }
  }
}

// ---------------------------------------------------------------------------
// 분석: VersionConflict 구성
// ---------------------------------------------------------------------------

fn build_version_conflicts(dep_infos: List(DepInfo)) -> List(ConflictCause) {
  // target_package별로 그룹
  let grouped = group_by_target(dep_infos, dict.new())
  dict.to_list(grouped)
  |> list.filter_map(fn(entry) {
    let #(target, infos) = entry
    case list.length(infos) >= 2 {
      True -> {
        let requirers =
          list.map(infos, fn(info) {
            ConflictRequirer(
              package: info.source_package,
              version: info.source_version,
              required_range: info.target_constraint,
            )
          })
        Ok(VersionConflict(package: target, required_by: requirers))
      }
      False -> Error(Nil)
    }
  })
}

fn group_by_target(
  infos: List(DepInfo),
  acc: Dict(String, List(DepInfo)),
) -> Dict(String, List(DepInfo)) {
  case infos {
    [] -> acc
    [info, ..rest] -> {
      let existing = case dict.get(acc, info.target_package) {
        Ok(l) -> l
        Error(_) -> []
      }
      let acc = dict.insert(acc, info.target_package, [info, ..existing])
      group_by_target(rest, acc)
    }
  }
}

// ---------------------------------------------------------------------------
// 의존성 체인 추출
// ---------------------------------------------------------------------------

fn do_extract_chains(
  inc: Incompatibility,
  current_path: List(String),
) -> List(List(String)) {
  case inc.cause {
    Root -> {
      let step = "root"
      [list.reverse([step, ..current_path])]
    }
    DependencyOn(
      package: pkg,
      version: ver,
      dep_name: dep,
      dep_constraint: constraint,
    ) -> {
      let step = pkg <> "@" <> ver <> " -> " <> dep <> " " <> constraint
      [list.reverse([step, ..current_path])]
    }
    NoVersions(package: pkg, range_desc: range) -> {
      let step = pkg <> " " <> range <> " (no versions)"
      [list.reverse([step, ..current_path])]
    }
    ConflictCause(left, right) -> {
      let left_chains = do_extract_chains(left, current_path)
      let right_chains = do_extract_chains(right, current_path)
      list.append(left_chains, right_chains)
    }
  }
}

// ---------------------------------------------------------------------------
// 제안 생성
// ---------------------------------------------------------------------------

fn suggest_for_cause(
  cause: ConflictCause,
  direct_deps: List(Dependency),
  available_versions: Dict(String, List(String)),
) -> List(Suggestion) {
  case cause {
    VersionConflict(package: pkg, required_by: requirers) ->
      suggest_for_version_conflict(
        pkg,
        requirers,
        direct_deps,
        available_versions,
      )
    NoMatchingVersion(
      package: pkg,
      required_range: range,
      available_versions: _,
    ) -> suggest_for_no_matching(pkg, range, direct_deps, available_versions)
    ImpossibleConstraint(package: pkg, constraint: constraint) ->
      suggest_for_impossible(pkg, constraint, direct_deps, available_versions)
  }
}

fn suggest_for_version_conflict(
  pkg: String,
  requirers: List(ConflictRequirer),
  direct_deps: List(Dependency),
  available_versions: Dict(String, List(String)),
) -> List(Suggestion) {
  let suggestions = []

  // 1. override 제안 — requirer들의 요구 범위 중 가용 버전이 있는 범위 찾기
  let pkg_key_hex = pkg <> ":hex"
  let pkg_key_npm = pkg <> ":npm"
  let versions = case dict.get(available_versions, pkg_key_hex) {
    Ok(vs) -> #(vs, Hex)
    Error(_) ->
      case dict.get(available_versions, pkg_key_npm) {
        Ok(vs) -> #(vs, Npm)
        Error(_) -> #([], Hex)
      }
  }
  let #(available, registry) = versions

  let suggestions = case available {
    [] -> suggestions
    _ -> {
      // 가용 버전 중 최고 버전을 override로 제안
      let sorted = sort_versions_desc(available)
      case sorted {
        [highest, ..] -> [
          AddOverride(
            package: pkg,
            registry: registry,
            suggested: ">= " <> highest,
          ),
          ..suggestions
        ]
        [] -> suggestions
      }
    }
  }

  // 2. 직접 의존성인 requirer의 제약 완화 제안
  let suggestions =
    list.fold(requirers, suggestions, fn(acc, req) {
      case is_direct_dep(req.package, direct_deps) {
        True -> {
          // 해당 requirer 패키지의 다른 버전이 있는지 확인
          let req_key_hex = req.package <> ":hex"
          let req_key_npm = req.package <> ":npm"
          let req_versions = case dict.get(available_versions, req_key_hex) {
            Ok(vs) -> vs
            Error(_) ->
              case dict.get(available_versions, req_key_npm) {
                Ok(vs) -> vs
                Error(_) -> []
              }
          }
          case find_alternative_version(req_versions, req.version) {
            Ok(alt) -> [
              UseVersion(
                package: req.package,
                current: req.version,
                suggested_version: alt,
              ),
              ..acc
            ]
            Error(_) -> acc
          }
        }
        False -> acc
      }
    })

  suggestions
}

fn suggest_for_no_matching(
  pkg: String,
  _range: String,
  direct_deps: List(Dependency),
  available_versions: Dict(String, List(String)),
) -> List(Suggestion) {
  let pkg_key_hex = pkg <> ":hex"
  let pkg_key_npm = pkg <> ":npm"
  let available = case dict.get(available_versions, pkg_key_hex) {
    Ok(vs) -> vs
    Error(_) ->
      case dict.get(available_versions, pkg_key_npm) {
        Ok(vs) -> vs
        Error(_) -> []
      }
  }
  case available {
    [] ->
      // 가용 버전이 없으면 패키지 제거 제안
      case is_direct_dep(pkg, direct_deps) {
        True -> [RemovePackage(package: pkg)]
        False -> []
      }
    _ -> {
      // 가용 버전 중 최고 버전으로 제약 완화 제안
      let sorted = sort_versions_desc(available)
      case sorted {
        [highest, ..] ->
          case find_direct_dep_constraint(pkg, direct_deps) {
            Ok(current) -> [
              RelaxConstraint(
                package: pkg,
                current: current,
                suggested: ">= " <> highest,
              ),
            ]
            Error(_) -> []
          }
        [] -> []
      }
    }
  }
}

fn suggest_for_impossible(
  pkg: String,
  _constraint: String,
  direct_deps: List(Dependency),
  available_versions: Dict(String, List(String)),
) -> List(Suggestion) {
  let pkg_key_hex = pkg <> ":hex"
  let pkg_key_npm = pkg <> ":npm"
  let available = case dict.get(available_versions, pkg_key_hex) {
    Ok(vs) -> vs
    Error(_) ->
      case dict.get(available_versions, pkg_key_npm) {
        Ok(vs) -> vs
        Error(_) -> []
      }
  }
  case available {
    [] -> [RemovePackage(package: pkg)]
    _ -> {
      let sorted = sort_versions_desc(available)
      case sorted {
        [highest, ..] ->
          case find_direct_dep_constraint(pkg, direct_deps) {
            Ok(current) -> [
              RelaxConstraint(
                package: pkg,
                current: current,
                suggested: ">= " <> highest,
              ),
            ]
            Error(_) -> []
          }
        [] -> []
      }
    }
  }
}

// ---------------------------------------------------------------------------
// 포맷
// ---------------------------------------------------------------------------

fn format_causes(causes: List(ConflictCause)) -> String {
  case causes {
    [] -> ""
    _ -> "\n" <> string.join(list.map(causes, format_one_cause), "\n") <> "\n"
  }
}

fn format_one_cause(cause: ConflictCause) -> String {
  case cause {
    VersionConflict(package: pkg, required_by: requirers) -> {
      let header = "  Conflict: " <> pkg <> " requires incompatible versions"
      let details =
        list.map(requirers, fn(r) {
          "    "
          <> r.package
          <> "@"
          <> r.version
          <> " requires "
          <> pkg
          <> " "
          <> r.required_range
        })
      header <> "\n" <> string.join(details, "\n")
    }
    NoMatchingVersion(package: pkg, required_range: range, ..) ->
      "  No versions: no version of " <> pkg <> " matches " <> range
    ImpossibleConstraint(package: pkg, constraint: constraint) ->
      "  Impossible: " <> pkg <> " " <> constraint <> " cannot be satisfied"
  }
}

fn format_chains(chains: List(List(String))) -> String {
  case chains {
    [] -> ""
    _ -> {
      let formatted =
        list.map(chains, fn(chain) { "    " <> string.join(chain, " -> ") })
      "\n  Dependency chains:\n" <> string.join(formatted, "\n") <> "\n"
    }
  }
}

fn format_suggestions(suggestions: List(Suggestion)) -> String {
  case suggestions {
    [] -> ""
    _ -> {
      let numbered =
        list.index_map(suggestions, fn(s, i) {
          "    " <> string.inspect(i + 1) <> ". " <> format_one_suggestion(s)
        })
      "\n  Suggestions:\n" <> string.join(numbered, "\n") <> "\n"
    }
  }
}

fn format_one_suggestion(s: Suggestion) -> String {
  case s {
    RelaxConstraint(package: pkg, current: cur, suggested: sug) ->
      "Relax constraint: change "
      <> pkg
      <> " from \""
      <> cur
      <> "\" to \""
      <> sug
      <> "\""
    AddOverride(package: pkg, registry: reg, suggested: sug) ->
      "Add override: ["
      <> case reg {
        Hex -> "overrides"
        Npm -> "npm-overrides"
        types.Git -> "git-overrides"
        types.Url -> "url-overrides"
      }
      <> "] "
      <> pkg
      <> " = \""
      <> sug
      <> "\""
    UseVersion(package: pkg, current: cur, suggested_version: ver) ->
      "Use " <> pkg <> " " <> ver <> " instead of " <> cur
    RemovePackage(package: pkg) -> "Remove " <> pkg <> " if it is not needed"
  }
}

// ---------------------------------------------------------------------------
// 헬퍼
// ---------------------------------------------------------------------------

fn is_direct_dep(name: String, deps: List(Dependency)) -> Bool {
  list.any(deps, fn(d) { d.name == name })
}

fn find_direct_dep_constraint(
  name: String,
  deps: List(Dependency),
) -> Result(String, Nil) {
  list.find(deps, fn(d) { d.name == name })
  |> result.map(fn(d) { d.version_constraint })
}

fn find_alternative_version(
  versions: List(String),
  current: String,
) -> Result(String, Nil) {
  let sorted = sort_versions_desc(versions)
  list.find(sorted, fn(v) { v != current })
}

fn sort_versions_desc(versions: List(String)) -> List(String) {
  let parsed =
    list.filter_map(versions, fn(v) {
      case semver.parse_version(v) {
        Ok(sv) -> Ok(#(v, sv))
        Error(_) -> Error(Nil)
      }
    })
  list.sort(parsed, fn(a, b) { semver.compare(b.1, a.1) })
  |> list.map(fn(pair) { pair.0 })
}

fn deduplicate_causes(causes: List(ConflictCause)) -> List(ConflictCause) {
  list.unique(causes)
}

fn deduplicate_suggestions(suggestions: List(Suggestion)) -> List(Suggestion) {
  list.unique(suggestions)
}
