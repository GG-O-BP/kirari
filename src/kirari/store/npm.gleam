//// npm 전용 content-addressable 패키지 저장소 — ~/.kir/store/npm
//// 메타데이터 사이드카(.meta) 동반 저장

import gleam/result
import kirari/platform
import kirari/security
import kirari/store/cas
import kirari/store/metadata
import kirari/store/types as store_types
import kirari/tarball
import kirari/types
import simplifile

// ---------------------------------------------------------------------------
// 저장소 루트
// ---------------------------------------------------------------------------

/// KIR_STORE/npm 또는 ~/.kir/store/npm 경로를 반환, 없으면 생성
pub fn store_root() -> Result(String, store_types.StoreError) {
  cas.store_root("npm")
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

/// 저장된 npm 패키지의 메타데이터 읽기
pub fn read_package_metadata(
  sha256: String,
) -> Result(metadata.PackageMetadata, store_types.StoreError) {
  use root <- result.try(store_root())
  let meta_path = meta_file_path(root, sha256)
  metadata.read_metadata(meta_path)
  |> result.map_error(fn(e) {
    case e {
      metadata.ReadError(d) -> store_types.IoError(d)
      metadata.ParseError(d) -> store_types.IoError(d)
      metadata.WriteError(d) -> store_types.IoError(d)
    }
  })
}

// ---------------------------------------------------------------------------
// 패키지 저장
// ---------------------------------------------------------------------------

/// npm tarball을 검증하고 저장소에 저장 + 메타데이터 사이드카 기록
pub fn store_package(
  data: BitArray,
  expected_sha256: String,
  name: String,
  version: String,
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

  // 2. 이미 존재하면 메타데이터 읽어서 반환
  case simplifile.is_directory(final_path) {
    Ok(True) -> read_existing_result(root, expected_sha256, final_path)
    _ -> {
      // 3. 임시 디렉토리에 추출
      use tmp_dir <- result.try(
        platform.make_temp_dir(root)
        |> result.map_error(fn(e) { store_types.IoError(e) }),
      )
      use _ <- result.try(
        tarball.extract(data, tmp_dir, types.Npm)
        |> result.map_error(fn(e) {
          case e {
            tarball.ExtractError(d) -> store_types.ExtractError(d)
            tarball.IoError(d) -> store_types.IoError(d)
          }
        }),
      )

      // 4. package.json에서 메타데이터 추출
      let meta = extract_metadata(tmp_dir, name, version)

      // 5. 2글자 prefix 디렉토리 생성
      let prefix_dir = cas.prefix_path(root, expected_sha256)
      use _ <- result.try(
        simplifile.create_directory_all(prefix_dir)
        |> result.map_error(fn(e) {
          store_types.IoError(simplifile.describe_error(e))
        }),
      )

      // 6. 원자적 rename
      case platform.atomic_rename(tmp_dir, final_path) {
        Ok(_) -> {
          // 7. 메타데이터 사이드카 기록
          let meta_path = meta_file_path(root, expected_sha256)
          let _ = metadata.write_metadata(meta, meta_path)
          Ok(store_types.StoreResult(
            path: final_path,
            has_scripts: meta.has_scripts,
            bin: meta.bin,
          ))
        }
        Error(_) -> {
          let _ = simplifile.delete(tmp_dir)
          case simplifile.is_directory(final_path) {
            Ok(True) -> read_existing_result(root, expected_sha256, final_path)
            _ -> Error(store_types.IoError("failed to store package"))
          }
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// 내부 헬퍼
// ---------------------------------------------------------------------------

fn extract_metadata(
  pkg_dir: String,
  name: String,
  version: String,
) -> metadata.PackageMetadata {
  case simplifile.read(pkg_dir <> "/package.json") {
    Ok(content) ->
      case metadata.extract_from_package_json(content, name, version) {
        Ok(meta) -> meta
        Error(_) -> metadata.default_metadata(name, version)
      }
    Error(_) -> metadata.default_metadata(name, version)
  }
}

fn read_existing_result(
  root: String,
  sha256: String,
  final_path: String,
) -> Result(store_types.StoreResult, store_types.StoreError) {
  let meta_path = meta_file_path(root, sha256)
  case metadata.read_metadata(meta_path) {
    Ok(meta) ->
      Ok(store_types.StoreResult(
        path: final_path,
        has_scripts: meta.has_scripts,
        bin: meta.bin,
      ))
    Error(_) ->
      Ok(store_types.StoreResult(path: final_path, has_scripts: False, bin: []))
  }
}

fn meta_file_path(root: String, sha256: String) -> String {
  cas.prefix_path(root, sha256) <> "/" <> sha256 <> ".meta"
}
