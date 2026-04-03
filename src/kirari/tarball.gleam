//// Hex/npm tarball 추출 — 레지스트리별 아카이브 형식 처리

import gleam/list
import gleam/result
import gleam/string
import kirari/platform
import kirari/types.{type Registry, Hex, Npm}
import simplifile

/// tarball 에러 타입
pub type TarballError {
  ExtractError(detail: String)
  IoError(detail: String)
}

/// 레지스트리에 맞는 tarball 추출
pub fn extract(
  data: BitArray,
  dest: String,
  registry: Registry,
) -> Result(Nil, TarballError) {
  case registry {
    Hex -> extract_hex(data, dest)
    Npm -> extract_npm(data, dest)
  }
}

/// Hex tarball: 비압축 외부 tar → contents.tar.gz 추출 → 압축 내부 tar 추출
fn extract_hex(data: BitArray, dest: String) -> Result(Nil, TarballError) {
  // 1. 임시 디렉토리에 외부 tar 해제 (비압축)
  let outer_dir = dest <> "__hex_outer"
  use _ <- result.try(
    simplifile.create_directory_all(outer_dir)
    |> result.map_error(fn(e) { IoError(simplifile.describe_error(e)) }),
  )
  use _ <- result.try(
    platform.extract_tar_uncompressed(data, outer_dir)
    |> result.map_error(fn(e) { ExtractError("hex outer tar: " <> e) }),
  )
  // 2. contents.tar.gz 읽기
  let contents_path = outer_dir <> "/contents.tar.gz"
  use contents_data <- result.try(
    simplifile.read_bits(contents_path)
    |> result.map_error(fn(e) {
      // outer tar가 gzip일 수도 있음 (일부 Hex 미러) — 압축 추출 fallback
      IoError("contents.tar.gz not found: " <> simplifile.describe_error(e))
    }),
  )
  // 3. contents.tar.gz를 최종 dest에 추출
  use _ <- result.try(
    simplifile.create_directory_all(dest)
    |> result.map_error(fn(e) { IoError(simplifile.describe_error(e)) }),
  )
  use _ <- result.try(
    platform.extract_tar(contents_data, dest)
    |> result.map_error(fn(e) { ExtractError("hex contents: " <> e) }),
  )
  // 4. 임시 외부 디렉토리 정리
  let _ = simplifile.delete(outer_dir)
  Ok(Nil)
}

/// npm tarball: gzip tar 추출 → package/ prefix 제거
fn extract_npm(data: BitArray, dest: String) -> Result(Nil, TarballError) {
  // 1. gzip tar 추출
  use _ <- result.try(
    simplifile.create_directory_all(dest)
    |> result.map_error(fn(e) { IoError(simplifile.describe_error(e)) }),
  )
  use _ <- result.try(
    platform.extract_tar(data, dest)
    |> result.map_error(fn(e) { ExtractError("npm tar: " <> e) }),
  )
  // 2. package/ prefix가 있으면 내용을 상위로 이동
  let package_dir = dest <> "/package"
  case simplifile.is_directory(package_dir) {
    Ok(True) -> move_contents_up(package_dir, dest)
    _ -> Ok(Nil)
  }
}

/// package/ 하위 파일들을 dest/ 루트로 이동
fn move_contents_up(from: String, to: String) -> Result(Nil, TarballError) {
  case simplifile.get_files(from) {
    Ok(files) -> {
      use _ <- result.try(move_files(files, from, to))
      // 빈 package/ 디렉토리 정리
      let _ = simplifile.delete(from)
      Ok(Nil)
    }
    Error(e) -> Error(IoError(simplifile.describe_error(e)))
  }
}

fn move_files(
  files: List(String),
  src_root: String,
  dst_root: String,
) -> Result(Nil, TarballError) {
  case files {
    [] -> Ok(Nil)
    [file, ..rest] -> {
      let relative = string.drop_start(file, string.length(src_root))
      let dst_file = dst_root <> relative
      let dst_dir =
        string.split(dst_file, "/")
        |> list.reverse
        |> list.rest
        |> result.unwrap([])
        |> list.reverse
        |> string.join("/")
      let _ = simplifile.create_directory_all(dst_dir)
      use _ <- result.try(
        simplifile.rename(file, dst_file)
        |> result.map_error(fn(e) { IoError(simplifile.describe_error(e)) }),
      )
      move_files(rest, src_root, dst_root)
    }
  }
}
