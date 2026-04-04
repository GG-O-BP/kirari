//// 라이선스 준수 검사 — 의존성 트리 라이선스 감사 엔진

import gleam/dict
import gleam/list
import gleam/string
import kirari/spdx.{type Expression}
import kirari/types.{
  type LicensePolicy, LicenseAllow, LicenseDeny, LicenseNoPolicy,
}

// ---------------------------------------------------------------------------
// 에러 타입
// ---------------------------------------------------------------------------

/// license 모듈 전용 에러 타입
pub type LicenseError {
  PolicyConflict(detail: String)
}

// ---------------------------------------------------------------------------
// 패키지 라이선스 정보
// ---------------------------------------------------------------------------

/// 패키지의 라이선스 정보 (검사용 데이터)
pub type PackageLicense {
  PackageLicense(
    name: String,
    version: String,
    registry: String,
    license_expression: String,
  )
}

// ---------------------------------------------------------------------------
// 위반 타입
// ---------------------------------------------------------------------------

/// 라이선스 정책 위반 상세
pub type Violation {
  DeniedLicense(
    name: String,
    version: String,
    registry: String,
    license: String,
    expression: Expression,
  )
  NotAllowed(
    name: String,
    version: String,
    registry: String,
    license: String,
    expression: Expression,
  )
  MissingLicense(name: String, version: String, registry: String)
  UnparsableLicense(
    name: String,
    version: String,
    registry: String,
    raw: String,
    error: spdx.SpdxError,
  )
}

// ---------------------------------------------------------------------------
// 공개 API
// ---------------------------------------------------------------------------

/// 패키지 목록을 라이선스 정책에 따라 검사, 위반 목록 반환
pub fn check(
  packages: List(PackageLicense),
  policy: LicensePolicy,
) -> List(Violation) {
  case policy {
    LicenseNoPolicy -> []
    _ -> list.flat_map(packages, fn(pkg) { check_one(pkg, policy) })
  }
}

/// 패키지를 라이선스 표현식 기준으로 그룹핑
pub fn group_by_license(
  packages: List(PackageLicense),
) -> List(#(String, List(PackageLicense))) {
  list.group(packages, fn(pkg) { pkg.license_expression })
  |> dict.to_list
  |> list.sort(fn(a: #(String, List(PackageLicense)), b) {
    string.compare(a.0, b.0)
  })
}

// ---------------------------------------------------------------------------
// 내부 검사 로직
// ---------------------------------------------------------------------------

fn check_one(pkg: PackageLicense, policy: LicensePolicy) -> List(Violation) {
  case pkg.license_expression {
    "" -> [
      MissingLicense(
        name: pkg.name,
        version: pkg.version,
        registry: pkg.registry,
      ),
    ]
    raw ->
      case spdx.parse(raw) {
        Error(e) -> [
          UnparsableLicense(
            name: pkg.name,
            version: pkg.version,
            registry: pkg.registry,
            raw: raw,
            error: e,
          ),
        ]
        Ok(expr) -> check_against_policy(pkg, expr, policy)
      }
  }
}

fn check_against_policy(
  pkg: PackageLicense,
  expr: Expression,
  policy: LicensePolicy,
) -> List(Violation) {
  case policy {
    LicenseAllow(allowed) ->
      case spdx.satisfies(expr, allowed) {
        True -> []
        False -> [
          NotAllowed(
            name: pkg.name,
            version: pkg.version,
            registry: pkg.registry,
            license: pkg.license_expression,
            expression: expr,
          ),
        ]
      }
    LicenseDeny(denied) ->
      case spdx.violates(expr, denied) {
        False -> []
        True -> [
          DeniedLicense(
            name: pkg.name,
            version: pkg.version,
            registry: pkg.registry,
            license: pkg.license_expression,
            expression: expr,
          ),
        ]
      }
    LicenseNoPolicy -> []
  }
}
