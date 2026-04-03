//// Content-addressable 패키지 저장소 — ~/.kir/store

import gleam/result
import gleam/string
import kirari/platform
import kirari/security
import kirari/types.{type Registry}
import simplifile

/// store 모듈 전용 에러 타입
pub type StoreError {
  HomeNotFound(detail: String)
  HashMismatch(expected: String, actual: String)
  ExtractError(detail: String)
  IoError(detail: String)
  PathTraversalError(path: String)
}

// ---------------------------------------------------------------------------
// 저장소 루트
// ---------------------------------------------------------------------------

/// ~/.kir/store 경로를 반환, 없으면 생성
pub fn store_root() -> Result(String, StoreError) {
  use home <- result.try(
    platform.get_home_dir()
    |> result.map_error(fn(e) { HomeNotFound(e) }),
  )
  let root = home <> "/.kir/store"
  use _ <- result.try(
    simplifile.create_directory_all(root)
    |> result.map_error(fn(e) { IoError(simplifile.describe_error(e)) }),
  )
  Ok(root)
}

// ---------------------------------------------------------------------------
// 패키지 조회
// ---------------------------------------------------------------------------

/// SHA256으로 저장소에 패키지가 있는지 확인
pub fn has_package(sha256: String) -> Result(Bool, StoreError) {
  use root <- result.try(store_root())
  let path = package_dir(root, sha256)
  case simplifile.is_directory(path) {
    Ok(True) -> Ok(True)
    _ -> Ok(False)
  }
}

/// SHA256으로 저장된 패키지의 경로 반환
pub fn package_path(sha256: String) -> Result(String, StoreError) {
  use root <- result.try(store_root())
  let path = package_dir(root, sha256)
  case simplifile.is_directory(path) {
    Ok(True) -> Ok(path)
    _ -> Error(IoError("package not in store: " <> sha256))
  }
}

// ---------------------------------------------------------------------------
// 패키지 저장
// ---------------------------------------------------------------------------

/// tarball 데이터를 검증하고 저장소에 저장
pub fn store_package(
  data: BitArray,
  expected_sha256: String,
  _name: String,
  _version: String,
  _registry: Registry,
) -> Result(String, StoreError) {
  // 1. 해시 검증
  use _ <- result.try(
    security.verify_hash(data, expected_sha256)
    |> result.map_error(fn(e) {
      case e {
        security.HashMismatch(expected, actual) ->
          HashMismatch(expected, actual)
        _ -> IoError("hash verification failed")
      }
    }),
  )

  use root <- result.try(store_root())
  let final_path = package_dir(root, expected_sha256)

  // 2. 이미 존재하면 바로 반환
  case simplifile.is_directory(final_path) {
    Ok(True) -> Ok(final_path)
    _ -> {
      // 3. 임시 디렉토리에 추출
      use tmp_dir <- result.try(
        platform.make_temp_dir(root)
        |> result.map_error(fn(e) { IoError(e) }),
      )
      use _ <- result.try(
        platform.extract_tar(data, tmp_dir)
        |> result.map_error(fn(e) { ExtractError(e) }),
      )

      // 4. 2글자 prefix 디렉토리 생성
      let prefix_dir = prefix_path(root, expected_sha256)
      use _ <- result.try(
        simplifile.create_directory_all(prefix_dir)
        |> result.map_error(fn(e) { IoError(simplifile.describe_error(e)) }),
      )

      // 5. 원자적 rename
      case platform.atomic_rename(tmp_dir, final_path) {
        Ok(_) -> Ok(final_path)
        Error(_) -> {
          // 경합 상태: 다른 프로세스가 먼저 저장. tmp 정리 후 기존 경로 반환
          let _ = simplifile.delete(tmp_dir)
          case simplifile.is_directory(final_path) {
            Ok(True) -> Ok(final_path)
            _ -> Error(IoError("failed to store package"))
          }
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// 내부 헬퍼
// ---------------------------------------------------------------------------

fn package_dir(root: String, sha256: String) -> String {
  prefix_path(root, sha256) <> "/" <> sha256
}

fn prefix_path(root: String, sha256: String) -> String {
  let prefix = string.slice(sha256, 0, 2)
  root <> "/" <> prefix
}
