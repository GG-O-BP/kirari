//// 공유 도메인 타입 — kir 전체에서 사용하는 핵심 데이터 구조

import gleam/order.{type Order}
import gleam/string

// ---------------------------------------------------------------------------
// Registry
// ---------------------------------------------------------------------------

/// 패키지 레지스트리 종류
pub type Registry {
  Hex
  Npm
}

/// Registry를 문자열로 변환
pub fn registry_to_string(registry: Registry) -> String {
  case registry {
    Hex -> "hex"
    Npm -> "npm"
  }
}

/// 문자열을 Registry로 변환
pub fn registry_from_string(s: String) -> Result(Registry, Nil) {
  case string.lowercase(s) {
    "hex" -> Ok(Hex)
    "npm" -> Ok(Npm)
    _ -> Error(Nil)
  }
}

// ---------------------------------------------------------------------------
// Dependency (gleam.toml에 선언된 의존성)
// ---------------------------------------------------------------------------

/// gleam.toml에 선언된 하나의 레지스트리 의존성
pub type Dependency {
  Dependency(
    name: String,
    version_constraint: String,
    registry: Registry,
    dev: Bool,
    optional: Bool,
    /// npm alias 시 실제 패키지 이름 (예: "npm:react@^18" → Ok("react"))
    package_name: Result(String, Nil),
  )
}

/// 레지스트리 조회용 실제 이름 반환 (alias-aware)
pub fn effective_name(dep: Dependency) -> String {
  case dep.package_name {
    Ok(real) -> real
    Error(_) -> dep.name
  }
}

/// gleam.toml에 선언된 로컬 경로 의존성 (gleam이 직접 관리)
pub type PathDep {
  PathDep(name: String, path: String, dev: Bool)
}

/// 전이 의존성 버전 강제 ([overrides] / [npm-overrides])
pub type Override {
  Override(name: String, version_constraint: String, registry: Registry)
}

// ---------------------------------------------------------------------------
// ResolvedPackage (kir.lock에 기록되는 확정 패키지)
// ---------------------------------------------------------------------------

/// 버전 해결 완료된 패키지
pub type ResolvedPackage {
  ResolvedPackage(
    name: String,
    version: String,
    registry: Registry,
    sha256: String,
    has_scripts: Bool,
    platform: Result(Platform, Nil),
    license: String,
    /// dev-only 패키지 여부 (production에서 도달 불가능하면 True)
    dev: Bool,
    /// npm alias 시 실제 패키지 이름
    package_name: Result(String, Nil),
  )
}

/// 해결된 패키지의 레지스트리 조회용 실제 이름
pub fn resolved_effective_name(pkg: ResolvedPackage) -> String {
  case pkg.package_name {
    Ok(real) -> real
    Error(_) -> pkg.name
  }
}

/// npm 패키지의 플랫폼 제약
pub type Platform {
  Platform(os: List(String), cpu: List(String))
}

/// lockfile 정렬용 비교 — 이름 사전순, 같으면 레지스트리 사전순
pub fn compare_packages(a: ResolvedPackage, b: ResolvedPackage) -> Order {
  case string.compare(a.name, b.name) {
    order.Eq ->
      string.compare(
        registry_to_string(a.registry),
        registry_to_string(b.registry),
      )
    other -> other
  }
}

// ---------------------------------------------------------------------------
// SecurityConfig
// ---------------------------------------------------------------------------

/// npm 스크립트 실행 정책
pub type ScriptPolicy {
  DenyAll
  AllowAll
  AllowList(packages: List(String))
}

/// npm provenance 검증 정책
pub type ProvenancePolicy {
  ProvenanceIgnore
  ProvenanceWarn
  ProvenanceRequire
}

/// 라이선스 정책
pub type LicensePolicy {
  LicenseAllow(licenses: List(String))
  LicenseDeny(licenses: List(String))
  LicenseNoPolicy
}

/// [security] 섹션
pub type SecurityConfig {
  SecurityConfig(
    exclude_newer: Result(String, Nil),
    npm_scripts: ScriptPolicy,
    provenance: ProvenancePolicy,
    license_policy: LicensePolicy,
    audit_ignore: List(String),
  )
}

/// 기본 보안 설정 (제한 없음)
pub fn default_security_config() -> SecurityConfig {
  SecurityConfig(
    exclude_newer: Error(Nil),
    npm_scripts: DenyAll,
    provenance: ProvenanceWarn,
    license_policy: LicenseNoPolicy,
    audit_ignore: [],
  )
}

// ---------------------------------------------------------------------------
// DownloadConfig (다운로드 파이프라인 설정)
// ---------------------------------------------------------------------------

/// 다운로드 파이프라인 설정
pub type DownloadConfig {
  DownloadConfig(
    /// 최대 재시도 횟수 (기본 3)
    max_retries: Int,
    /// 패키지당 타임아웃 밀리초 (기본 120_000)
    timeout_ms: Int,
    /// 최대 병렬 다운로드 수 (0 = 무제한, 기본 0)
    parallel: Int,
    /// 재시도 간 백오프 밀리초 (기본 2000)
    backoff_ms: Int,
  )
}

/// 기본 다운로드 설정
pub fn default_download_config() -> DownloadConfig {
  DownloadConfig(
    max_retries: 3,
    timeout_ms: 120_000,
    parallel: 0,
    backoff_ms: 2000,
  )
}

// ---------------------------------------------------------------------------
// PackageInfo ([package] 섹션)
// ---------------------------------------------------------------------------

/// kir.toml [package] 섹션
pub type PackageInfo {
  PackageInfo(
    name: String,
    version: String,
    description: String,
    target: String,
    licences: List(String),
    repository: Result(String, Nil),
  )
}

// ---------------------------------------------------------------------------
// EnginesConfig ([engines] 섹션)
// ---------------------------------------------------------------------------

/// 런타임 버전 제약 — Gleam/Erlang/Node.js
pub type EnginesConfig {
  EnginesConfig(
    gleam: Result(String, Nil),
    erlang: Result(String, Nil),
    node: Result(String, Nil),
  )
}

/// 기본 engines 설정 (제약 없음)
pub fn default_engines_config() -> EnginesConfig {
  EnginesConfig(gleam: Error(Nil), erlang: Error(Nil), node: Error(Nil))
}

// ---------------------------------------------------------------------------
// KirConfig (kir.toml 전체)
// ---------------------------------------------------------------------------

/// gleam.toml의 인메모리 표현
pub type KirConfig {
  KirConfig(
    package: PackageInfo,
    hex_deps: List(Dependency),
    hex_dev_deps: List(Dependency),
    npm_deps: List(Dependency),
    npm_dev_deps: List(Dependency),
    security: SecurityConfig,
    path_deps: List(PathDep),
    path_dev_deps: List(PathDep),
    overrides: List(Override),
    engines: EnginesConfig,
    download: DownloadConfig,
  )
}

// ---------------------------------------------------------------------------
// KirLock (kir.lock 전체)
// ---------------------------------------------------------------------------

/// kir.lock의 인메모리 표현
pub type KirLock {
  KirLock(
    version: Int,
    packages: List(ResolvedPackage),
    /// config fingerprint — 변경 감지용 (Error(Nil) = 레거시 lockfile)
    config_fingerprint: Result(String, Nil),
  )
}
