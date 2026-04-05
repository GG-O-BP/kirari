//// Content-addressable 패키지 저장소 — ~/.kir/store
//// Hex와 npm 레지스트리별 전용 하위 모듈로 위임하는 라우터
//// 타입 정의는 store/types.gleam에 위치 (순환 의존성 방지)

import gleam/list
import gleam/result
import kirari/platform
import kirari/store/git as git_store
import kirari/store/hex as hex_store
import kirari/store/manifest
import kirari/store/npm as npm_store
import kirari/store/types as store_types
import kirari/store/url as url_store
import kirari/types.{type Registry, Git, Hex, Npm, Url}
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
    Git -> git_store.has_package(sha256)
    Url -> url_store.has_package(sha256)
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
    Git -> git_store.package_path(sha256)
    Url -> url_store.package_path(sha256)
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
    Url -> url_store.store_package(data, expected_sha256, name, version)
    Git ->
      Error(store_types.IoError(
        "use store_git_package for Git registry packages",
      ))
  }
}

/// Git clone 디렉토리를 저장소에 저장
pub fn store_git_package(
  src_dir: String,
  content_sha256: String,
  name: String,
  version: String,
) -> Result(StoreResult, StoreError) {
  git_store.store_from_directory(src_dir, content_sha256, name, version)
}

// ---------------------------------------------------------------------------
// 패키지 무결성 검증
// ---------------------------------------------------------------------------

/// 패키지 무결성 전체 검증 (Level 3: 모든 파일 SHA256 재계산)
pub fn verify_package(
  sha256: String,
  registry: Registry,
) -> Result(manifest.VerifyResult, StoreError) {
  use path <- result.try(package_path(sha256, registry))
  manifest.verify_full(path)
  |> result.map_error(fn(e) {
    case e {
      manifest.ReadError(d) -> store_types.IoError(d)
      manifest.WriteError(d) -> store_types.IoError(d)
      manifest.ParseError(d) -> store_types.IoError(d)
    }
  })
}

/// 패키지 빠른 검증 (Level 2: 매니페스트 존재 + 파일 수)
pub fn verify_package_quick(
  sha256: String,
  registry: Registry,
) -> Result(manifest.VerifyResult, StoreError) {
  use path <- result.try(package_path(sha256, registry))
  manifest.verify_quick(path)
  |> result.map_error(fn(e) {
    case e {
      manifest.ReadError(d) -> store_types.IoError(d)
      manifest.WriteError(d) -> store_types.IoError(d)
      manifest.ParseError(d) -> store_types.IoError(d)
    }
  })
}

/// 레지스트리별 store 내 캐시된 패키지 수 반환
pub fn count_entries(registry: Registry) -> Int {
  case store_root() {
    Ok(base) -> {
      let path = case registry {
        Hex -> base <> "/hex"
        Npm -> base <> "/npm"
        Git -> base <> "/git"
        Url -> base <> "/url"
      }
      count_entries_in(path)
    }
    Error(_) -> 0
  }
}

fn count_entries_in(path: String) -> Int {
  case simplifile.read_directory(path) {
    Ok(dirs) ->
      list.fold(dirs, 0, fn(count, dir) {
        case simplifile.read_directory(path <> "/" <> dir) {
          Ok(entries) -> count + list.length(entries)
          Error(_) -> count
        }
      })
    Error(_) -> 0
  }
}
