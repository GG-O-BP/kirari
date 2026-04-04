//// Content-addressable storage 공통 헬퍼 — Hex/npm store 공유 로직

import gleam/result
import gleam/string
import kirari/platform
import kirari/store/types as store_types
import simplifile

/// 레지스트리별 store 루트 경로 반환 (없으면 생성)
pub fn store_root(
  registry_name: String,
) -> Result(String, store_types.StoreError) {
  use base <- result.try(
    platform.store_base_path()
    |> result.map_error(fn(e) { store_types.HomeNotFound(e) }),
  )
  let root = base <> "/" <> registry_name
  use _ <- result.try(
    simplifile.create_directory_all(root)
    |> result.map_error(fn(e) {
      store_types.IoError(simplifile.describe_error(e))
    }),
  )
  Ok(root)
}

/// SHA256으로 저장소에 패키지가 있는지 확인
pub fn has_package(
  sha256: String,
  root: String,
) -> Result(Bool, store_types.StoreError) {
  let path = package_dir(root, sha256)
  case simplifile.is_directory(path) {
    Ok(True) -> Ok(True)
    _ -> Ok(False)
  }
}

/// SHA256으로 저장된 패키지의 경로 반환
pub fn package_path(
  sha256: String,
  root: String,
) -> Result(String, store_types.StoreError) {
  let path = package_dir(root, sha256)
  case simplifile.is_directory(path) {
    Ok(True) -> Ok(path)
    _ -> Error(store_types.IoError("package not in store: " <> sha256))
  }
}

/// SHA256 기반 패키지 디렉토리 경로
pub fn package_dir(root: String, sha256: String) -> String {
  prefix_path(root, sha256) <> "/" <> sha256
}

/// 2글자 prefix 디렉토리 경로
pub fn prefix_path(root: String, sha256: String) -> String {
  let prefix = string.slice(sha256, 0, 2)
  root <> "/" <> prefix
}
