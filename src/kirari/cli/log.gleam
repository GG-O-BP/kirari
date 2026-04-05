//// 구조화된 로그 — CLI 전역 로그 레벨 관리 (persistent_term 기반)

import gleam/io
import kirari/cli/output
import kirari/platform

/// 로그 레벨 — Silent < Normal < Verbose < Debug
pub type LogLevel {
  /// --quiet: 에러 외 출력 억제
  Silent
  /// 기본: 상태 메시지만
  Normal
  /// --verbose: 상세 진행 정보
  Verbose
  /// --debug: 내부 동작 추적
  Debug
}

/// 로그 레벨 초기화 (CLI 시작 시 1회 호출)
pub fn init(level: LogLevel) -> Nil {
  platform.set_log_level(level_to_string(level))
}

/// 현재 로그 레벨 조회
pub fn get_level() -> LogLevel {
  level_from_string(platform.get_log_level())
}

/// Normal 이상에서 출력 (일반 상태 메시지)
pub fn info(msg: String) -> Nil {
  case level_to_int(get_level()) >= level_to_int(Normal) {
    True -> io.println(msg)
    False -> Nil
  }
}

/// Verbose 이상에서 출력 (dim 색상)
pub fn verbose(msg: String) -> Nil {
  case level_to_int(get_level()) >= level_to_int(Verbose) {
    True -> io.println(output.color_dim(msg))
    False -> Nil
  }
}

/// Debug에서만 출력 ([debug] prefix, dim 색상)
pub fn debug(msg: String) -> Nil {
  case level_to_int(get_level()) >= level_to_int(Debug) {
    True -> io.println(output.color_dim("[debug] " <> msg))
    False -> Nil
  }
}

/// Verbose lazy — 비싼 메시지 생성을 레벨 체크 후에만 실행
pub fn verbose_fn(thunk: fn() -> String) -> Nil {
  case level_to_int(get_level()) >= level_to_int(Verbose) {
    True -> io.println(output.color_dim(thunk()))
    False -> Nil
  }
}

/// Debug lazy — 비싼 메시지 생성을 레벨 체크 후에만 실행
pub fn debug_fn(thunk: fn() -> String) -> Nil {
  case level_to_int(get_level()) >= level_to_int(Debug) {
    True -> io.println(output.color_dim("[debug] " <> thunk()))
    False -> Nil
  }
}

/// CLI 플래그 + 환경변수로 로그 레벨 결정
/// 우선순위: quiet > debug > verbose > KIR_LOG env > Normal
pub fn determine_level(quiet: Bool, verbose: Bool, debug: Bool) -> LogLevel {
  case quiet, debug, verbose {
    True, _, _ -> Silent
    _, True, _ -> Debug
    _, _, True -> Verbose
    _, _, _ ->
      case platform.get_env("KIR_LOG") {
        Ok("debug") -> Debug
        Ok("verbose") -> Verbose
        Ok("silent") | Ok("quiet") -> Silent
        _ -> Normal
      }
  }
}

/// 환경변수만으로 로그 레벨 결정 (플래그 없는 커맨드용)
pub fn determine_level_from_env() -> LogLevel {
  determine_level(False, False, False)
}

// ---------------------------------------------------------------------------
// 내부 헬퍼
// ---------------------------------------------------------------------------

fn level_to_string(level: LogLevel) -> String {
  case level {
    Silent -> "silent"
    Normal -> "normal"
    Verbose -> "verbose"
    Debug -> "debug"
  }
}

fn level_from_string(s: String) -> LogLevel {
  case s {
    "silent" | "quiet" -> Silent
    "verbose" -> Verbose
    "debug" -> Debug
    _ -> Normal
  }
}

fn level_to_int(level: LogLevel) -> Int {
  case level {
    Silent -> 0
    Normal -> 1
    Verbose -> 2
    Debug -> 3
  }
}
