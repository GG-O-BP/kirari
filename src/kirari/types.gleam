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
// Dependency (kir.toml에 선언된 의존성)
// ---------------------------------------------------------------------------

/// kir.toml에 선언된 하나의 의존성
pub type Dependency {
  Dependency(
    name: String,
    version_constraint: String,
    registry: Registry,
    dev: Bool,
  )
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
  )
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

/// [security] 섹션
pub type SecurityConfig {
  SecurityConfig(exclude_newer: Result(String, Nil))
}

/// 기본 보안 설정 (제한 없음)
pub fn default_security_config() -> SecurityConfig {
  SecurityConfig(exclude_newer: Error(Nil))
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
// KirConfig (kir.toml 전체)
// ---------------------------------------------------------------------------

/// kir.toml의 인메모리 표현
pub type KirConfig {
  KirConfig(
    package: PackageInfo,
    hex_deps: List(Dependency),
    hex_dev_deps: List(Dependency),
    npm_deps: List(Dependency),
    npm_dev_deps: List(Dependency),
    security: SecurityConfig,
  )
}

// ---------------------------------------------------------------------------
// KirLock (kir.lock 전체)
// ---------------------------------------------------------------------------

/// kir.lock의 인메모리 표현
pub type KirLock {
  KirLock(version: Int, packages: List(ResolvedPackage))
}
