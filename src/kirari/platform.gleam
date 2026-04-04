//// Erlang FFI 래퍼 — Gleam에서 직접 호출할 수 없는 BEAM 기능
//// 플랫폼 추상화 — Erlang FFI 바인딩 및 OS/시간 유틸리티

/// gzip tar 아카이브를 dest 디렉토리에 압축 해제
@external(erlang, "kirari_ffi", "extract_tar")
pub fn extract_tar(data: BitArray, dest: String) -> Result(Nil, String)

/// 비압축 tar 아카이브를 dest 디렉토리에 해제 (Hex 외부 tarball용)
@external(erlang, "kirari_ffi", "extract_tar_uncompressed")
pub fn extract_tar_uncompressed(
  data: BitArray,
  dest: String,
) -> Result(Nil, String)

/// 하드링크 생성 (src → dst)
@external(erlang, "kirari_ffi", "make_hardlink")
pub fn make_hardlink(src: String, dst: String) -> Result(Nil, String)

/// 원자적 파일/디렉토리 이름 변경
@external(erlang, "kirari_ffi", "atomic_rename")
pub fn atomic_rename(src: String, dst: String) -> Result(Nil, String)

/// 사용자 홈 디렉토리 경로
@external(erlang, "kirari_ffi", "get_home_dir")
pub fn get_home_dir() -> Result(String, String)

/// 프로세스 종료
@external(erlang, "kirari_ffi", "halt")
pub fn halt(code: Int) -> Nil

/// 지정 경로 아래에 임시 디렉토리 생성
@external(erlang, "kirari_ffi", "make_temp_dir")
pub fn make_temp_dir(base: String) -> Result(String, String)

/// 애플리케이션 버전 — .app 메타데이터에서 읽기
@external(erlang, "kirari_ffi", "app_version")
pub fn app_version() -> Result(String, Nil)

/// 셸 명령어 실행 — 성공 시 stdout, 실패 시 #(exit_code, output)
@external(erlang, "kirari_ffi", "run_command")
pub fn run_command(cmd: String) -> Result(String, #(Int, String))

/// 셸 명령어 실행 — stdout/stderr 실시간 스트리밍, 종료 코드 반환
@external(erlang, "kirari_ffi", "exec_command")
pub fn exec_command(cmd: String) -> Int

/// 현재 시스템 OS ("win32" | "darwin" | "linux" | ...)
@external(erlang, "kirari_ffi", "get_platform_os")
pub fn get_platform_os() -> String

/// 현재 시스템 아키텍처 ("x64" | "arm64" | "ia32" | ...)
@external(erlang, "kirari_ffi", "get_platform_arch")
pub fn get_platform_arch() -> String

/// 파일 수정 시각 (Unix 초)
@external(erlang, "kirari_ffi", "get_file_mtime")
pub fn get_file_mtime(path: String) -> Result(Int, String)

/// 심볼릭 링크 생성 (target ← link)
@external(erlang, "kirari_ffi", "make_symlink")
pub fn make_symlink(target: String, link: String) -> Result(Nil, String)

/// 실행 권한 설정 (Unix: 755)
@external(erlang, "kirari_ffi", "chmod_executable")
pub fn chmod_executable(path: String) -> Result(Nil, String)

/// ECDSA 서명 검증 (npm Sigstore용)
@external(erlang, "kirari_ffi", "verify_ecdsa_signature")
pub fn verify_ecdsa_signature(
  data: BitArray,
  signature_b64: String,
  public_key_pem: String,
) -> Result(Nil, String)

/// 현재 시각 RFC 3339 형식
@external(erlang, "kirari_ffi", "get_current_timestamp")
pub fn get_current_timestamp() -> String

/// 환경변수 조회
@external(erlang, "kirari_ffi", "get_env")
pub fn get_env(key: String) -> Result(String, String)

/// store 기본 경로 — KIR_STORE 환경변수 또는 ~/.kir/store
pub fn store_base_path() -> Result(String, String) {
  case get_env("KIR_STORE") {
    Ok(custom) -> Ok(custom)
    Error(_) -> {
      use home <- result.try(get_home_dir())
      Ok(home <> "/.kir/store")
    }
  }
}

import gleam/int
import gleam/result
import gleam/string

/// 현재 시각을 대략적 Unix seconds로 반환
pub fn current_unix_seconds() -> Int {
  parse_timestamp_to_seconds(get_current_timestamp()) |> result.unwrap(0)
}

/// RFC 3339 타임스탬프를 대략적 Unix seconds로 변환 (윤년 무시)
pub fn parse_timestamp_to_seconds(ts: String) -> Result(Int, Nil) {
  let cleaned =
    string.replace(ts, "T", "-")
    |> string.replace(":", "-")
    |> string.replace("Z", "")
  case string.split(cleaned, "-") {
    [y_s, mo_s, d_s, h_s, mi_s, s_s] -> {
      use y <- result.try(int.parse(y_s))
      use mo <- result.try(int.parse(mo_s))
      use d <- result.try(int.parse(d_s))
      use h <- result.try(int.parse(h_s))
      use mi <- result.try(int.parse(mi_s))
      use s <- result.try(int.parse(s_s))
      let days = { y - 1970 } * 365 + { y - 1969 } / 4 + month_days(mo) + d - 1
      Ok(days * 86_400 + h * 3600 + mi * 60 + s)
    }
    _ -> Error(Nil)
  }
}

fn month_days(month: Int) -> Int {
  case month {
    1 -> 0
    2 -> 31
    3 -> 59
    4 -> 90
    5 -> 120
    6 -> 151
    7 -> 181
    8 -> 212
    9 -> 243
    10 -> 273
    11 -> 304
    12 -> 334
    _ -> 0
  }
}
