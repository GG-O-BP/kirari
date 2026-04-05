//// Git 전용 content-addressable 패키지 저장소 — ~/.kir/store/git
//// clone 디렉토리를 CAS에 복사하는 방식 (tarball이 아닌 디렉토리 기반)

import gleam/result
import kirari/platform
import kirari/store/cas
import kirari/store/manifest
import kirari/store/types as store_types
import simplifile

// ---------------------------------------------------------------------------
// 저장소 루트
// ---------------------------------------------------------------------------

/// ~/.kir/store/git 경로를 반환, 없으면 생성
pub fn store_root() -> Result(String, store_types.StoreError) {
  cas.store_root("git")
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
// 패키지 저장 (디렉토리 복사)
// ---------------------------------------------------------------------------

/// clone 디렉토리를 CAS에 저장 (content hash 기반)
/// .git/ 디렉토리는 제외하고 소스 파일만 복사
pub fn store_from_directory(
  src_dir: String,
  content_sha256: String,
  _name: String,
  _version: String,
) -> Result(store_types.StoreResult, store_types.StoreError) {
  use root <- result.try(store_root())
  let final_path = cas.package_dir(root, content_sha256)

  // 이미 존재하면 바로 반환
  case simplifile.is_directory(final_path) {
    Ok(True) ->
      Ok(store_types.StoreResult(path: final_path, has_scripts: False, bin: []))
    _ -> {
      // 임시 디렉토리에 복사 (.git 제외)
      use tmp_dir <- result.try(
        platform.make_temp_dir(root)
        |> result.map_error(fn(e) { store_types.IoError(e) }),
      )
      use _ <- result.try(
        copy_directory_excluding_git(src_dir, tmp_dir)
        |> result.map_error(fn(e) { store_types.IoError(e) }),
      )

      // prefix 디렉토리 생성
      let prefix_dir = cas.prefix_path(root, content_sha256)
      use _ <- result.try(
        simplifile.create_directory_all(prefix_dir)
        |> result.map_error(fn(e) {
          store_types.IoError(simplifile.describe_error(e))
        }),
      )

      // 원자적 rename
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
            _ -> Error(store_types.IoError("failed to store git package"))
          }
        }
      }
    }
  }
}

/// .git/ 제외 디렉토리 복사
fn copy_directory_excluding_git(
  src: String,
  dest: String,
) -> Result(Nil, String) {
  // simplifile.copy_directory로 전체 복사 후 .git 삭제
  simplifile.copy_directory(src, dest)
  |> result.map_error(fn(e) { simplifile.describe_error(e) })
  |> result.try(fn(_) {
    let git_dir = dest <> "/.git"
    case simplifile.is_directory(git_dir) {
      Ok(True) -> {
        let _ = simplifile.delete(git_dir)
        Ok(Nil)
      }
      _ -> Ok(Nil)
    }
  })
}
