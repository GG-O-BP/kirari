//// Hex 전용 content-addressable 패키지 저장소 — ~/.kir/store/hex

import gleam/result
import kirari/platform
import kirari/security
import kirari/store/cas
import kirari/store/manifest
import kirari/store/types as store_types
import kirari/tarball
import kirari/types
import simplifile

// ---------------------------------------------------------------------------
// 저장소 루트
// ---------------------------------------------------------------------------

/// KIR_STORE/hex 또는 ~/.kir/store/hex 경로를 반환, 없으면 생성
pub fn store_root() -> Result(String, store_types.StoreError) {
  cas.store_root("hex")
}

// ---------------------------------------------------------------------------
// 패키지 조회
// ---------------------------------------------------------------------------

/// SHA256으로 저장소에 패키지가 있는지 확인
pub fn has_package(sha256: String) -> Result(Bool, store_types.StoreError) {
  use root <- result.try(store_root())
  cas.has_package(sha256, root)
}

/// SHA256으로 저장된 패키지의 경로 반환
pub fn package_path(sha256: String) -> Result(String, store_types.StoreError) {
  use root <- result.try(store_root())
  cas.package_path(sha256, root)
}

// ---------------------------------------------------------------------------
// 패키지 저장
// ---------------------------------------------------------------------------

/// Hex tarball을 검증하고 저장소에 저장
pub fn store_package(
  data: BitArray,
  expected_sha256: String,
  _name: String,
  _version: String,
) -> Result(store_types.StoreResult, store_types.StoreError) {
  // 1. 해시 검증
  use _ <- result.try(
    security.verify_hash(data, expected_sha256)
    |> result.map_error(fn(e) {
      case e {
        security.HashMismatch(expected, actual) ->
          store_types.HashMismatch(expected, actual)
        _ -> store_types.IoError("hash verification failed")
      }
    }),
  )

  use root <- result.try(store_root())
  let final_path = cas.package_dir(root, expected_sha256)

  // 2. 이미 존재하면 바로 반환
  case simplifile.is_directory(final_path) {
    Ok(True) ->
      Ok(store_types.StoreResult(path: final_path, has_scripts: False, bin: []))
    _ -> {
      // 3. 임시 디렉토리에 추출
      use tmp_dir <- result.try(
        platform.make_temp_dir(root)
        |> result.map_error(fn(e) { store_types.IoError(e) }),
      )
      use _ <- result.try(
        tarball.extract(data, tmp_dir, types.Hex)
        |> result.map_error(fn(e) {
          case e {
            tarball.ExtractError(d) -> store_types.ExtractError(d)
            tarball.IoError(d) -> store_types.IoError(d)
          }
        }),
      )

      // 4. 2글자 prefix 디렉토리 생성
      let prefix_dir = cas.prefix_path(root, expected_sha256)
      use _ <- result.try(
        simplifile.create_directory_all(prefix_dir)
        |> result.map_error(fn(e) {
          store_types.IoError(simplifile.describe_error(e))
        }),
      )

      // 5. 원자적 rename
      case platform.atomic_rename(tmp_dir, final_path) {
        Ok(_) -> {
          let _ = manifest.generate(final_path)
          Ok(
            store_types.StoreResult(
              path: final_path,
              has_scripts: False,
              bin: [],
            ),
          )
        }
        Error(_) -> {
          let _ = simplifile.delete(tmp_dir)
          case simplifile.is_directory(final_path) {
            Ok(True) ->
              Ok(
                store_types.StoreResult(
                  path: final_path,
                  has_scripts: False,
                  bin: [],
                ),
              )
            _ -> Error(store_types.IoError("failed to store package"))
          }
        }
      }
    }
  }
}
