//// Erlang FFI 래퍼 — Gleam에서 직접 호출할 수 없는 BEAM 기능

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
