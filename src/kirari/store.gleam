//// Content-addressable 패키지 저장소 — ~/.kir/store
//// Hex와 npm 레지스트리별 전용 하위 모듈로 위임하는 라우터
//// 타입 정의는 store/types.gleam에 위치 (순환 의존성 방지)

import gleam/result
import kirari/platform
import kirari/store/hex as hex_store
import kirari/store/npm as npm_store
import kirari/store/types as store_types
import kirari/types.{type Registry, Hex, Npm}
import simplifile

// 타입 re-export (기존 호출부 호환)
pub type StoreError =
  store_types.StoreError

pub type StoreResult =
  store_types.StoreResult

// ---------------------------------------------------------------------------
// 저장소 루트
// ---------------------------------------------------------------------------

/// KIR_STORE 환경변수 또는 ~/.kir/store 경로를 반환, 없으면 생성
pub fn store_root() -> Result(String, StoreError) {
  use base <- result.try(
    platform.store_base_path()
    |> result.map_error(fn(e) { store_types.HomeNotFound(e) }),
  )
  use _ <- result.try(
    simplifile.create_directory_all(base)
    |> result.map_error(fn(e) {
      store_types.IoError(simplifile.describe_error(e))
    }),
  )
  Ok(base)
}

// ---------------------------------------------------------------------------
// 패키지 조회 (레지스트리별 위임)
// ---------------------------------------------------------------------------

/// SHA256으로 저장소에 패키지가 있는지 확인
pub fn has_package(
  sha256: String,
  registry: Registry,
) -> Result(Bool, StoreError) {
  case registry {
    Hex -> hex_store.has_package(sha256)
    Npm -> npm_store.has_package(sha256)
  }
}

/// SHA256으로 저장된 패키지의 경로 반환
pub fn package_path(
  sha256: String,
  registry: Registry,
) -> Result(String, StoreError) {
  case registry {
    Hex -> hex_store.package_path(sha256)
    Npm -> npm_store.package_path(sha256)
  }
}

// ---------------------------------------------------------------------------
// 패키지 저장 (레지스트리별 위임)
// ---------------------------------------------------------------------------

/// tarball 데이터를 검증하고 저장소에 저장
pub fn store_package(
  data: BitArray,
  expected_sha256: String,
  name: String,
  version: String,
  registry: Registry,
) -> Result(StoreResult, StoreError) {
  case registry {
    Hex -> hex_store.store_package(data, expected_sha256, name, version)
    Npm -> npm_store.store_package(data, expected_sha256, name, version)
  }
}
