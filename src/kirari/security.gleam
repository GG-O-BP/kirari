//// 공급망 보안 — SHA256 해싱, 상수 시간 비교, 경로 검증, exclude-newer

import gleam/bit_array
import gleam/crypto
import gleam/list
import gleam/order
import gleam/result
import gleam/string
import gleam/time/timestamp
import kirari/platform
import kirari/types

/// security 모듈 전용 에러 타입
pub type SecurityError {
  HashMismatch(expected: String, actual: String)
  PathTraversal(path: String)
  InvalidTimestamp(value: String)
  SignatureError(detail: String)
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

// ---------------------------------------------------------------------------
// npm Sigstore 서명 검증
// ---------------------------------------------------------------------------

/// 서명 검증 결과
pub type SignatureVerification {
  Verified
  NoSignature
  VerificationFailed(detail: String)
}

/// npm 레지스트리 서명 검증 (ECDSA, 단일 서명)
pub fn verify_npm_signature(
  data: BitArray,
  signature_b64: String,
  public_key_pem: String,
) -> SignatureVerification {
  case platform.verify_ecdsa_signature(data, signature_b64, public_key_pem) {
    Ok(_) -> Verified
    Error(detail) -> VerificationFailed(detail)
  }
}

/// npm 패키지 서명 검증 (정책 적용)
pub fn verify_npm_provenance(
  data: BitArray,
  signatures: List(#(String, String)),
  keys: List(#(String, String)),
  policy: types.ProvenancePolicy,
) -> Result(Nil, SecurityError) {
  case policy {
    types.ProvenanceIgnore -> Ok(Nil)
    _ ->
      case signatures {
        [] ->
          case policy {
            types.ProvenanceRequire ->
              Error(SignatureError("no signatures found"))
            _ -> Ok(Nil)
          }
        _ -> verify_any_signature(data, signatures, keys, policy)
      }
  }
}

fn verify_any_signature(
  data: BitArray,
  signatures: List(#(String, String)),
  keys: List(#(String, String)),
  policy: types.ProvenancePolicy,
) -> Result(Nil, SecurityError) {
  let verified =
    list.any(signatures, fn(sig) {
      let #(keyid, sig_b64) = sig
      case list.find(keys, fn(k) { k.0 == keyid }) {
        Ok(#(_, pem)) ->
          case verify_npm_signature(data, sig_b64, pem) {
            Verified -> True
            _ -> False
          }
        Error(_) -> False
      }
    })
  case verified {
    True -> Ok(Nil)
    False ->
      case policy {
        types.ProvenanceRequire ->
          Error(SignatureError("all signature verifications failed"))
        _ -> Ok(Nil)
      }
  }
}

// ---------------------------------------------------------------------------
// SRI integrity 검증
// ---------------------------------------------------------------------------

/// npm SRI integrity 검증 (sha512-... 또는 sha256-... 형식)
pub fn verify_sri_integrity(
  data: BitArray,
  sri: String,
) -> Result(Nil, SecurityError) {
  case sri {
    "" -> Ok(Nil)
    "sha512-" <> expected_b64 -> {
      let actual = crypto.hash(crypto.Sha512, data)
      let expected = bit_array.base64_decode(expected_b64)
      case expected {
        Ok(expected_bytes) ->
          case crypto.secure_compare(actual, expected_bytes) {
            True -> Ok(Nil)
            False ->
              Error(HashMismatch(expected: sri, actual: "sha512 mismatch"))
          }
        Error(_) -> Error(HashMismatch(expected: sri, actual: "invalid base64"))
      }
    }
    "sha256-" <> expected_b64 -> {
      let actual = crypto.hash(crypto.Sha256, data)
      let expected = bit_array.base64_decode(expected_b64)
      case expected {
        Ok(expected_bytes) ->
          case crypto.secure_compare(actual, expected_bytes) {
            True -> Ok(Nil)
            False ->
              Error(HashMismatch(expected: sri, actual: "sha256 mismatch"))
          }
        Error(_) -> Error(HashMismatch(expected: sri, actual: "invalid base64"))
      }
    }
    // 알 수 없는 SRI 형식은 건너뛰기
    _ -> Ok(Nil)
  }
}
