//// 패키지 무결성 매니페스트 — 파일 단위 SHA256 해시 기록 및 검증

import gleam/list
import gleam/result
import gleam/string
import kirari/security
import simplifile

// ---------------------------------------------------------------------------
// 타입
// ---------------------------------------------------------------------------

/// 매니페스트 파일 항목 (SHA256 + 상대 경로)
pub type ManifestEntry {
  ManifestEntry(sha256: String, path: String)
}

/// 검증 결과
pub type VerifyResult {
  /// 모든 파일이 매니페스트와 일치
  VerifyOk(file_count: Int)
  /// 불일치/누락/미등록 파일 존재
  VerifyCorrupted(
    mismatched: List(String),
    missing: List(String),
    extra: List(String),
  )
  /// 매니페스트 파일 없음 (구 버전 store)
  VerifyNoManifest
}

/// 매니페스트 에러
pub type ManifestError {
  WriteError(detail: String)
  ReadError(detail: String)
  ParseError(detail: String)
}

/// 매니페스트 파일명
const manifest_filename = ".kir-manifest"

// ---------------------------------------------------------------------------
// 공개 API
// ---------------------------------------------------------------------------

/// 매니페스트 파일 경로
pub fn manifest_path(dir: String) -> String {
  dir <> "/" <> manifest_filename
}

/// 디렉토리의 모든 파일을 해싱하여 매니페스트 생성 및 기록
pub fn generate(dir: String) -> Result(Nil, ManifestError) {
  use files <- result.try(list_files(dir))
  let entries =
    files
    |> list.filter(fn(f) { !string.ends_with(f, "/" <> manifest_filename) })
    |> list.filter_map(fn(abs_path) {
      case simplifile.read_bits(abs_path) {
        Ok(data) -> {
          let hash = security.sha256_hex(data)
          let rel = relative_path(dir, abs_path)
          Ok(ManifestEntry(sha256: hash, path: rel))
        }
        Error(_) -> Error(Nil)
      }
    })
    |> list.sort(fn(a, b) { string.compare(a.path, b.path) })
  let content =
    list.map(entries, fn(e) { e.sha256 <> "  " <> e.path })
    |> string.join("\n")
  simplifile.write(manifest_path(dir), content)
  |> result.map_error(fn(e) { WriteError(simplifile.describe_error(e)) })
}

/// 매니페스트 읽기
pub fn read(dir: String) -> Result(List(ManifestEntry), ManifestError) {
  let path = manifest_path(dir)
  use content <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(_) { ReadError("manifest not found: " <> path) }),
  )
  parse_manifest(content)
}

/// 전체 파일 검증 (Level 3: 모든 파일 SHA256 재계산)
pub fn verify_full(dir: String) -> Result(VerifyResult, ManifestError) {
  case simplifile.is_file(manifest_path(dir)) {
    Ok(True) -> do_verify_full(dir)
    _ -> Ok(VerifyNoManifest)
  }
}

/// 빠른 검증 (Level 2: 매니페스트 존재 + 파일 수 일치만)
pub fn verify_quick(dir: String) -> Result(VerifyResult, ManifestError) {
  case simplifile.is_file(manifest_path(dir)) {
    Ok(True) -> {
      use entries <- result.try(read(dir))
      use actual_files <- result.try(list_non_manifest_files(dir))
      let expected_count = list.length(entries)
      let actual_count = list.length(actual_files)
      case expected_count == actual_count {
        True -> Ok(VerifyOk(expected_count))
        False -> Ok(VerifyCorrupted(mismatched: [], missing: [], extra: []))
      }
    }
    _ -> Ok(VerifyNoManifest)
  }
}

// ---------------------------------------------------------------------------
// 내부: 전체 검증
// ---------------------------------------------------------------------------

fn do_verify_full(dir: String) -> Result(VerifyResult, ManifestError) {
  use entries <- result.try(read(dir))
  use actual_files <- result.try(list_non_manifest_files(dir))

  // 매니페스트 항목별 검증
  let #(mismatched, missing) =
    list.fold(entries, #([], []), fn(acc, entry) {
      let abs_path = dir <> "/" <> entry.path
      case simplifile.read_bits(abs_path) {
        Ok(data) -> {
          let actual_hash = security.sha256_hex(data)
          case actual_hash == entry.sha256 {
            True -> acc
            False -> #([entry.path, ..acc.0], acc.1)
          }
        }
        Error(_) -> #(acc.0, [entry.path, ..acc.1])
      }
    })

  // 매니페스트에 없는 파일 (extra) 감지
  let manifest_paths = list.map(entries, fn(e) { e.path })
  let actual_rel_paths = list.map(actual_files, fn(f) { relative_path(dir, f) })
  let extra =
    list.filter(actual_rel_paths, fn(p) { !list.contains(manifest_paths, p) })

  case mismatched, missing, extra {
    [], [], [] -> Ok(VerifyOk(list.length(entries)))
    _, _, _ ->
      Ok(VerifyCorrupted(
        mismatched: list.reverse(mismatched),
        missing: list.reverse(missing),
        extra: extra,
      ))
  }
}

// ---------------------------------------------------------------------------
// 내부: 파서
// ---------------------------------------------------------------------------

fn parse_manifest(content: String) -> Result(List(ManifestEntry), ManifestError) {
  let lines =
    string.split(content, "\n")
    |> list.filter(fn(l) { string.trim(l) != "" })
  Ok(list.filter_map(lines, parse_manifest_line))
}

fn parse_manifest_line(line: String) -> Result(ManifestEntry, Nil) {
  // 포맷: "sha256hex  relative/path"
  case string.split_once(line, "  ") {
    Ok(#(hash, path)) ->
      case string.trim(hash), string.trim(path) {
        "", _ | _, "" -> Error(Nil)
        h, p -> Ok(ManifestEntry(sha256: h, path: p))
      }
    Error(_) -> Error(Nil)
  }
}

// ---------------------------------------------------------------------------
// 내부: 파일 시스템 헬퍼
// ---------------------------------------------------------------------------

fn list_files(dir: String) -> Result(List(String), ManifestError) {
  simplifile.get_files(dir)
  |> result.map(fn(files) { list.map(files, fn(f) { normalize_slashes(f) }) })
  |> result.map_error(fn(e) {
    ReadError("failed to list files: " <> simplifile.describe_error(e))
  })
}

fn list_non_manifest_files(dir: String) -> Result(List(String), ManifestError) {
  use files <- result.try(list_files(dir))
  Ok(
    list.filter(files, fn(f) { !string.ends_with(f, "/" <> manifest_filename) }),
  )
}

fn relative_path(base: String, abs_path: String) -> String {
  let norm_base = normalize_slashes(base)
  let norm_path = normalize_slashes(abs_path)
  case string.starts_with(norm_path, norm_base <> "/") {
    True -> string.drop_start(norm_path, string.length(norm_base) + 1)
    False -> norm_path
  }
}

/// 백슬래시를 슬래시로 정규화 (Windows 호환)
fn normalize_slashes(path: String) -> String {
  string.replace(path, "\\", "/")
}
