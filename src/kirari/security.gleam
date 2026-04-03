//// 공급망 보안 — SHA256 해싱, 상수 시간 비교, 경로 검증, exclude-newer

import gleam/bit_array
import gleam/crypto
import gleam/order
import gleam/result
import gleam/string
import gleam/time/timestamp

/// security 모듈 전용 에러 타입
pub type SecurityError {
  HashMismatch(expected: String, actual: String)
  PathTraversal(path: String)
  InvalidTimestamp(value: String)
}

// ---------------------------------------------------------------------------
// SHA256
// ---------------------------------------------------------------------------

/// BitArray의 SHA256 다이제스트를 소문자 16진수 문자열로 반환
pub fn sha256_hex(data: BitArray) -> String {
  crypto.hash(crypto.Sha256, data)
  |> bit_array.base16_encode
  |> string.lowercase
}

// ---------------------------------------------------------------------------
// 상수 시간 비교
// ---------------------------------------------------------------------------

/// 두 문자열을 상수 시간으로 비교 (타이밍 공격 방지)
pub fn constant_time_equal(a: String, b: String) -> Bool {
  let a_bits = bit_array.from_string(a)
  let b_bits = bit_array.from_string(b)
  crypto.secure_compare(a_bits, b_bits)
}

// ---------------------------------------------------------------------------
// 해시 검증
// ---------------------------------------------------------------------------

/// 데이터의 SHA256이 기대 해시와 일치하는지 검증
pub fn verify_hash(
  data: BitArray,
  expected_hash: String,
) -> Result(Nil, SecurityError) {
  let actual = sha256_hex(data)
  let expected_lower = string.lowercase(expected_hash)
  case constant_time_equal(actual, expected_lower) {
    True -> Ok(Nil)
    False -> Error(HashMismatch(expected: expected_lower, actual: actual))
  }
}

// ---------------------------------------------------------------------------
// 경로 검증
// ---------------------------------------------------------------------------

/// 경로에 path traversal 패턴이 없는지 검증
pub fn validate_path(path: String) -> Result(String, SecurityError) {
  let segments = split_path(path)
  case check_path_segments(segments, path) {
    Ok(_) -> Ok(path)
    Error(e) -> Error(e)
  }
}

fn split_path(path: String) -> List(String) {
  path
  |> string.replace("\\", "/")
  |> string.split("/")
}

fn check_path_segments(
  segments: List(String),
  original: String,
) -> Result(Nil, SecurityError) {
  case segments {
    [] -> Ok(Nil)
    [seg, ..rest] -> {
      case is_dangerous_segment(seg, original) {
        True -> Error(PathTraversal(original))
        False -> check_path_segments(rest, original)
      }
    }
  }
}

fn is_dangerous_segment(seg: String, original: String) -> Bool {
  // ".." 세그먼트 거부
  seg == ".."
  // null 바이트 포함 거부
  || string.contains(seg, "\u{0000}")
  // 절대 경로 거부 (첫 세그먼트가 빈 문자열이면 /로 시작한 것)
  || is_absolute_path(original)
  // Windows 드라이브 문자 거부 (C: 등)
  || is_drive_letter(seg)
}

fn is_absolute_path(path: String) -> Bool {
  string.starts_with(path, "/") || string.starts_with(path, "\\")
}

fn is_drive_letter(seg: String) -> Bool {
  case string.length(seg) {
    2 -> string.ends_with(seg, ":")
    _ -> False
  }
}

// ---------------------------------------------------------------------------
// exclude-newer 타임스탬프 비교
// ---------------------------------------------------------------------------

/// publish_time이 cutoff 이전인지 확인 (RFC 3339 파싱)
pub fn is_before_cutoff(
  publish_time: String,
  cutoff: String,
) -> Result(Bool, SecurityError) {
  use pub_ts <- result.try(
    timestamp.parse_rfc3339(publish_time)
    |> result.map_error(fn(_) { InvalidTimestamp(publish_time) }),
  )
  use cut_ts <- result.try(
    timestamp.parse_rfc3339(cutoff)
    |> result.map_error(fn(_) { InvalidTimestamp(cutoff) }),
  )
  Ok(timestamp.compare(pub_ts, cut_ts) == order.Lt)
}
