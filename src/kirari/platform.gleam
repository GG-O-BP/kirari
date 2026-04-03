//// Erlang FFI 래퍼 — Gleam에서 직접 호출할 수 없는 BEAM 기능

/// tar/tgz 아카이브를 dest 디렉토리에 압축 해제
@external(erlang, "kirari_ffi", "extract_tar")
pub fn extract_tar(data: BitArray, dest: String) -> Result(Nil, String)

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
