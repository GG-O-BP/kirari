import gleam/dict
import gleam/list
import gleam/string
import gleeunit
import kirari/resolver/conflict.{
  AddOverride, ConflictReport, ConflictRequirer, ImpossibleConstraint,
  NoMatchingVersion, RelaxConstraint, RemovePackage, UseVersion, VersionConflict,
}
import kirari/resolver/incompatibility.{
  ConflictCause, DependencyOn, Incompatibility, NoVersions, Root,
}
import kirari/resolver/term.{Negative, Positive}
import kirari/semver
import kirari/types.{Dependency, Hex, Npm}

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// 헬퍼
// ---------------------------------------------------------------------------

fn make_range(constraint: String) -> semver.VersionRange {
  case semver.parse_constraint(constraint) {
    Ok(c) -> semver.constraint_to_range(c)
    Error(_) -> semver.version_range_any()
  }
}

fn pkg_ref(name: String) -> term.PackageRef {
  term.PackageRef(name: name, registry: Hex)
}

// ---------------------------------------------------------------------------
// analyze: NoVersions → NoMatchingVersion
// ---------------------------------------------------------------------------

pub fn analyze_no_versions_test() {
  let inc =
    Incompatibility(
      terms: dict.from_list([
        #("pkg_x:hex", Positive(pkg_ref("pkg_x"), make_range(">= 5.0.0"))),
      ]),
      cause: NoVersions(package: "pkg_x", range_desc: ">= 5.0.0"),
    )
  let causes = conflict.analyze(inc)
  assert list.length(causes) >= 1
  let assert Ok(NoMatchingVersion(
    package: "pkg_x",
    required_range: ">= 5.0.0",
    ..,
  )) =
    list.find(causes, fn(c) {
      case c {
        NoMatchingVersion(package: "pkg_x", ..) -> True
        _ -> False
      }
    })
}

// ---------------------------------------------------------------------------
// analyze: 다이아몬드 충돌 → VersionConflict
// ---------------------------------------------------------------------------

pub fn analyze_diamond_conflict_test() {
  // pkg_a@1.0.0 → shared >= 1.0.0 and < 2.0.0
  let left =
    Incompatibility(
      terms: dict.from_list([
        #(
          "pkg_a:hex",
          Positive(pkg_ref("pkg_a"), make_range(">= 1.0.0 and < 2.0.0")),
        ),
        #(
          "shared:hex",
          Negative(pkg_ref("shared"), make_range(">= 1.0.0 and < 2.0.0")),
        ),
      ]),
      cause: DependencyOn(
        package: "pkg_a",
        version: "1.0.0",
        dep_name: "shared",
        dep_constraint: ">= 1.0.0 and < 2.0.0",
      ),
    )
  // pkg_b@1.0.0 → shared >= 2.0.0
  let right =
    Incompatibility(
      terms: dict.from_list([
        #("pkg_b:hex", Positive(pkg_ref("pkg_b"), make_range(">= 1.0.0"))),
        #("shared:hex", Negative(pkg_ref("shared"), make_range(">= 2.0.0"))),
      ]),
      cause: DependencyOn(
        package: "pkg_b",
        version: "1.0.0",
        dep_name: "shared",
        dep_constraint: ">= 2.0.0",
      ),
    )
  // 충돌 결합
  let combined =
    Incompatibility(
      terms: dict.from_list([
        #("pkg_a:hex", Positive(pkg_ref("pkg_a"), make_range(">= 1.0.0"))),
        #("pkg_b:hex", Positive(pkg_ref("pkg_b"), make_range(">= 1.0.0"))),
      ]),
      cause: ConflictCause(left, right),
    )
  let causes = conflict.analyze(combined)
  let assert Ok(VersionConflict(package: "shared", required_by: requirers)) =
    list.find(causes, fn(c) {
      case c {
        VersionConflict(package: "shared", ..) -> True
        _ -> False
      }
    })
  assert list.length(requirers) == 2
  // pkg_a와 pkg_b 모두 requirer에 포함
  let requirer_names = list.map(requirers, fn(r) { r.package })
  assert list.contains(requirer_names, "pkg_a")
  assert list.contains(requirer_names, "pkg_b")
}

// ---------------------------------------------------------------------------
// analyze: Root → ImpossibleConstraint
// ---------------------------------------------------------------------------

pub fn analyze_impossible_constraint_test() {
  let inc =
    Incompatibility(
      terms: dict.from_list([
        #("$root:hex", Positive(pkg_ref("$root"), semver.version_range_any())),
        #(
          "nonexistent:hex",
          Negative(pkg_ref("nonexistent"), make_range(">= 1.0.0")),
        ),
      ]),
      cause: Root,
    )
  let causes = conflict.analyze(inc)
  let assert Ok(ImpossibleConstraint(package: "nonexistent", ..)) =
    list.find(causes, fn(c) {
      case c {
        ImpossibleConstraint(package: "nonexistent", ..) -> True
        _ -> False
      }
    })
}

// ---------------------------------------------------------------------------
// suggest: VersionConflict → AddOverride
// ---------------------------------------------------------------------------

pub fn suggest_override_for_conflict_test() {
  let causes = [
    VersionConflict(package: "shared", required_by: [
      ConflictRequirer(
        package: "pkg_a",
        version: "1.0.0",
        required_range: ">= 1.0.0 and < 2.0.0",
      ),
      ConflictRequirer(
        package: "pkg_b",
        version: "1.0.0",
        required_range: ">= 2.0.0",
      ),
    ]),
  ]
  let available = dict.from_list([#("shared:hex", ["1.0.0", "2.0.0", "2.1.0"])])
  let direct_deps = [
    Dependency(
      name: "pkg_a",
      version_constraint: ">= 1.0.0",
      registry: Hex,
      dev: False,
      optional: False,
    ),
    Dependency(
      name: "pkg_b",
      version_constraint: ">= 1.0.0",
      registry: Hex,
      dev: False,
      optional: False,
    ),
  ]
  let suggestions = conflict.suggest(causes, direct_deps, available)
  // AddOverride 제안이 있어야 함
  let assert Ok(AddOverride(package: "shared", registry: Hex, ..)) =
    list.find(suggestions, fn(s) {
      case s {
        AddOverride(package: "shared", ..) -> True
        _ -> False
      }
    })
}

// ---------------------------------------------------------------------------
// suggest: NoMatchingVersion → RelaxConstraint
// ---------------------------------------------------------------------------

pub fn suggest_relax_for_no_matching_test() {
  let causes = [
    NoMatchingVersion(
      package: "my_lib",
      required_range: ">= 99.0.0",
      available_versions: [],
    ),
  ]
  let available = dict.from_list([#("my_lib:hex", ["1.0.0", "2.0.0"])])
  let direct_deps = [
    Dependency(
      name: "my_lib",
      version_constraint: ">= 99.0.0",
      registry: Hex,
      dev: False,
      optional: False,
    ),
  ]
  let suggestions = conflict.suggest(causes, direct_deps, available)
  let assert Ok(RelaxConstraint(package: "my_lib", ..)) =
    list.find(suggestions, fn(s) {
      case s {
        RelaxConstraint(package: "my_lib", ..) -> True
        _ -> False
      }
    })
}

// ---------------------------------------------------------------------------
// suggest: 가용 버전 없음 → RemovePackage
// ---------------------------------------------------------------------------

pub fn suggest_remove_for_no_versions_test() {
  let causes = [
    NoMatchingVersion(
      package: "ghost_pkg",
      required_range: ">= 1.0.0",
      available_versions: [],
    ),
  ]
  let available = dict.new()
  let direct_deps = [
    Dependency(
      name: "ghost_pkg",
      version_constraint: ">= 1.0.0",
      registry: Hex,
      dev: False,
      optional: False,
    ),
  ]
  let suggestions = conflict.suggest(causes, direct_deps, available)
  let assert Ok(RemovePackage(package: "ghost_pkg")) =
    list.find(suggestions, fn(s) {
      case s {
        RemovePackage(package: "ghost_pkg") -> True
        _ -> False
      }
    })
}

// ---------------------------------------------------------------------------
// suggest: UseVersion (직접 의존성의 대안 버전)
// ---------------------------------------------------------------------------

pub fn suggest_use_version_test() {
  let causes = [
    VersionConflict(package: "shared", required_by: [
      ConflictRequirer(
        package: "pkg_a",
        version: "1.0.0",
        required_range: ">= 1.0.0 and < 2.0.0",
      ),
      ConflictRequirer(
        package: "pkg_b",
        version: "1.0.0",
        required_range: ">= 2.0.0",
      ),
    ]),
  ]
  let available =
    dict.from_list([
      #("shared:hex", ["1.0.0", "2.0.0"]),
      #("pkg_a:hex", ["1.0.0", "2.0.0"]),
      #("pkg_b:hex", ["1.0.0"]),
    ])
  let direct_deps = [
    Dependency(
      name: "pkg_a",
      version_constraint: ">= 1.0.0",
      registry: Hex,
      dev: False,
      optional: False,
    ),
    Dependency(
      name: "pkg_b",
      version_constraint: ">= 1.0.0",
      registry: Hex,
      dev: False,
      optional: False,
    ),
  ]
  let suggestions = conflict.suggest(causes, direct_deps, available)
  let assert Ok(UseVersion(package: "pkg_a", ..)) =
    list.find(suggestions, fn(s) {
      case s {
        UseVersion(package: "pkg_a", ..) -> True
        _ -> False
      }
    })
}

// ---------------------------------------------------------------------------
// extract_chains
// ---------------------------------------------------------------------------

pub fn extract_chains_from_diamond_test() {
  let left =
    Incompatibility(
      terms: dict.new(),
      cause: DependencyOn(
        package: "pkg_a",
        version: "1.0.0",
        dep_name: "shared",
        dep_constraint: ">= 1.0.0",
      ),
    )
  let right =
    Incompatibility(
      terms: dict.new(),
      cause: DependencyOn(
        package: "pkg_b",
        version: "1.0.0",
        dep_name: "shared",
        dep_constraint: ">= 2.0.0",
      ),
    )
  let combined =
    Incompatibility(terms: dict.new(), cause: ConflictCause(left, right))
  let chains = conflict.extract_chains(combined)
  assert list.length(chains) == 2
}

// ---------------------------------------------------------------------------
// format_report: 출력 내용 검증
// ---------------------------------------------------------------------------

pub fn format_report_contains_conflict_info_test() {
  let report =
    ConflictReport(
      explanation: "test explanation",
      causes: [
        VersionConflict(package: "shared", required_by: [
          ConflictRequirer(
            package: "pkg_a",
            version: "1.0.0",
            required_range: ">= 1.0.0",
          ),
          ConflictRequirer(
            package: "pkg_b",
            version: "1.0.0",
            required_range: ">= 2.0.0",
          ),
        ]),
      ],
      suggestions: [
        AddOverride(package: "shared", registry: Hex, suggested: ">= 2.0.0"),
      ],
      dependency_chains: [],
    )
  let output = conflict.format_report(report)
  assert string.contains(output, "Conflict: shared")
  assert string.contains(output, "pkg_a@1.0.0")
  assert string.contains(output, "pkg_b@1.0.0")
  assert string.contains(output, "Suggestions")
  assert string.contains(output, "[overrides]")
}

// ---------------------------------------------------------------------------
// build_report: 전체 통합 테스트
// ---------------------------------------------------------------------------

pub fn build_report_integration_test() {
  let left =
    Incompatibility(
      terms: dict.from_list([
        #(
          "pkg_a:hex",
          Positive(pkg_ref("pkg_a"), make_range(">= 1.0.0 and < 2.0.0")),
        ),
      ]),
      cause: DependencyOn(
        package: "pkg_a",
        version: "1.0.0",
        dep_name: "shared",
        dep_constraint: ">= 1.0.0 and < 2.0.0",
      ),
    )
  let right =
    Incompatibility(
      terms: dict.from_list([
        #("pkg_b:hex", Positive(pkg_ref("pkg_b"), make_range(">= 1.0.0"))),
      ]),
      cause: DependencyOn(
        package: "pkg_b",
        version: "1.0.0",
        dep_name: "shared",
        dep_constraint: ">= 2.0.0",
      ),
    )
  let combined =
    Incompatibility(terms: dict.new(), cause: ConflictCause(left, right))
  let available =
    dict.from_list([
      #("shared:hex", ["1.0.0", "2.0.0"]),
      #("pkg_a:hex", ["1.0.0"]),
      #("pkg_b:hex", ["1.0.0"]),
    ])
  let direct_deps = [
    Dependency(
      name: "pkg_a",
      version_constraint: ">= 1.0.0",
      registry: Hex,
      dev: False,
      optional: False,
    ),
    Dependency(
      name: "pkg_b",
      version_constraint: ">= 1.0.0",
      registry: Hex,
      dev: False,
      optional: False,
    ),
  ]
  let report = conflict.build_report(combined, direct_deps, available)
  assert list.length(report.causes) >= 1
  assert list.length(report.suggestions) >= 1
  assert list.length(report.dependency_chains) >= 1
}

// ---------------------------------------------------------------------------
// npm 레지스트리 지원
// ---------------------------------------------------------------------------

pub fn suggest_npm_override_test() {
  let causes = [
    VersionConflict(package: "@scope/pkg", required_by: [
      ConflictRequirer(
        package: "dep_a",
        version: "1.0.0",
        required_range: "^1.0.0",
      ),
      ConflictRequirer(
        package: "dep_b",
        version: "1.0.0",
        required_range: "^2.0.0",
      ),
    ]),
  ]
  let available =
    dict.from_list([#("@scope/pkg:npm", ["1.0.0", "2.0.0", "2.1.0"])])
  let suggestions = conflict.suggest(causes, [], available)
  let assert Ok(AddOverride(package: "@scope/pkg", registry: Npm, ..)) =
    list.find(suggestions, fn(s) {
      case s {
        AddOverride(package: "@scope/pkg", ..) -> True
        _ -> False
      }
    })
}
