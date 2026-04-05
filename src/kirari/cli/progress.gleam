//// 다운로드 진행률 표시 — Erlang process 기반 액터

import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/string
import kirari/platform

/// 진행률 이벤트
pub type ProgressEvent {
  /// 다운로드 시작
  Started(name: String, version: String)
  /// 다운로드 완료 (bytes: 다운로드 크기)
  Complete(name: String, version: String, bytes: Int)
  /// 다운로드 실패
  Failed(name: String, version: String)
  /// 캐시에서 로드 (다운로드 불필요)
  Cached(name: String, version: String)
  /// 액터 중지
  Stop
}

/// 진행률 표시 설정
pub type ProgressConfig {
  ProgressConfig(total_packages: Int, quiet: Bool, no_color: Bool)
}

/// 진행률 표시 핸들
pub type ProgressHandle {
  Active(subject: process.Subject(ProgressEvent))
  Inactive
}

/// 액터 내부 상태
type ProgressState {
  ProgressState(
    total: Int,
    completed: Int,
    cached: Int,
    failed: Int,
    active: Int,
    total_bytes: Int,
    start_time: Int,
    no_color: Bool,
    is_tty: Bool,
    rendered: Bool,
  )
}

// ---------------------------------------------------------------------------
// 공개 API
// ---------------------------------------------------------------------------

/// 진행률 액터 시작. quiet=True면 Inactive 반환.
pub fn start(config: ProgressConfig) -> ProgressHandle {
  case config.quiet || config.total_packages == 0 {
    True -> Inactive
    False -> {
      let callback = process.new_subject()
      let state =
        ProgressState(
          total: config.total_packages,
          completed: 0,
          cached: 0,
          failed: 0,
          active: 0,
          total_bytes: 0,
          start_time: platform.current_unix_seconds(),
          no_color: config.no_color,
          is_tty: platform.is_tty(),
          rendered: False,
        )
      let _ =
        process.spawn(fn() {
          let subject = process.new_subject()
          process.send(callback, subject)
          progress_loop(state, subject)
        })
      case process.receive(callback, 1000) {
        Ok(subject) -> Active(subject: subject)
        Error(_) -> Inactive
      }
    }
  }
}

/// 이벤트 전송
pub fn send(handle: ProgressHandle, event: ProgressEvent) -> Nil {
  case handle {
    Active(subject) -> process.send(subject, event)
    Inactive -> Nil
  }
}

/// 액터 중지 — 최종 줄 출력 대기
pub fn stop(handle: ProgressHandle) -> Nil {
  case handle {
    Active(subject) -> {
      process.send(subject, Stop)
      // 액터가 종료할 시간을 줌
      process.sleep(50)
    }
    Inactive -> Nil
  }
}

// ---------------------------------------------------------------------------
// 액터 루프
// ---------------------------------------------------------------------------

fn progress_loop(
  state: ProgressState,
  subject: process.Subject(ProgressEvent),
) -> Nil {
  case process.receive(subject, 500) {
    Ok(event) -> {
      let new_state = handle_event(state, event)
      case event {
        Stop -> {
          render_final(new_state)
          Nil
        }
        _ -> {
          render(new_state)
          progress_loop(new_state, subject)
        }
      }
    }
    Error(_) -> {
      // 타임아웃 — 리렌더 (속도 업데이트)
      render(state)
      progress_loop(state, subject)
    }
  }
}

fn handle_event(state: ProgressState, event: ProgressEvent) -> ProgressState {
  case event {
    Started(_, _) -> ProgressState(..state, active: state.active + 1)
    Complete(_, _, bytes) ->
      ProgressState(
        ..state,
        completed: state.completed + 1,
        active: state.active - 1,
        total_bytes: state.total_bytes + bytes,
      )
    Failed(_, _) ->
      ProgressState(..state, failed: state.failed + 1, active: state.active - 1)
    Cached(_, _) -> ProgressState(..state, cached: state.cached + 1)
    Stop -> state
  }
}

// ---------------------------------------------------------------------------
// 렌더링
// ---------------------------------------------------------------------------

fn render(state: ProgressState) -> Nil {
  let done = state.completed + state.cached
  case state.is_tty {
    True -> render_tty(state, done)
    False -> render_plain(state, done)
  }
}

fn render_tty(state: ProgressState, done: Int) -> Nil {
  let width = platform.get_terminal_width()
  let bar = format_bar(done, state.total, width - 30)
  let speed = format_speed(state.total_bytes, state.start_time)
  let line =
    "\r\u{1b}[2K  Downloading "
    <> bar
    <> " "
    <> int.to_string(done)
    <> "/"
    <> int.to_string(state.total)
    <> case speed {
      "" -> ""
      s -> "  " <> s
    }
  io.print(line)
}

fn render_plain(state: ProgressState, done: Int) -> Nil {
  case done > 0 && done % 5 == 0 || done == state.total {
    True ->
      io.println(
        "  Downloading "
        <> int.to_string(done)
        <> "/"
        <> int.to_string(state.total)
        <> "...",
      )
    False -> Nil
  }
}

fn render_final(state: ProgressState) -> Nil {
  let done = state.completed + state.cached
  case state.is_tty {
    True -> {
      let bytes_str = format_bytes(state.total_bytes)
      let line =
        "\r\u{1b}[2K  "
        <> color_green("Downloaded", state.no_color)
        <> " "
        <> int.to_string(done)
        <> " packages"
        <> case state.total_bytes > 0 {
          True -> " (" <> bytes_str <> ")"
          False -> ""
        }
        <> case state.cached > 0 {
          True -> ", " <> int.to_string(state.cached) <> " cached"
          False -> ""
        }
        <> "\n"
      io.print(line)
    }
    False ->
      io.println(
        "  Downloaded "
        <> int.to_string(done)
        <> " packages"
        <> case state.cached > 0 {
          True -> " (" <> int.to_string(state.cached) <> " cached)"
          False -> ""
        },
      )
  }
}

// ---------------------------------------------------------------------------
// 포맷팅 헬퍼
// ---------------------------------------------------------------------------

/// 진행률 바 생성: [========>          ]
pub fn format_bar(done: Int, total: Int, width: Int) -> String {
  let bar_width = case width < 10 {
    True -> 10
    False -> width
  }
  let filled = case total > 0 {
    True -> { done * bar_width } / total
    False -> 0
  }
  let empty = bar_width - filled
  "["
  <> string.repeat("=", case filled > 0 {
    True -> filled - 1
    False -> 0
  })
  <> case filled > 0 && done < total {
    True -> ">"
    False ->
      case filled > 0 {
        True -> "="
        False -> ""
      }
  }
  <> string.repeat(" ", empty)
  <> "]"
}

/// 바이트 크기 포맷: 1.2 MB, 456 KB
pub fn format_bytes(bytes: Int) -> String {
  case bytes {
    b if b >= 1_048_576 -> {
      let tenths = b * 10 / 1_048_576
      int.to_string(tenths / 10) <> "." <> int.to_string(tenths % 10) <> " MB"
    }
    b if b >= 1024 -> {
      let kb = b / 1024
      int.to_string(kb) <> " KB"
    }
    b -> int.to_string(b) <> " B"
  }
}

/// 다운로드 속도 포맷: 1.2 MB/s
pub fn format_speed(total_bytes: Int, start_time: Int) -> String {
  let now = platform.current_unix_seconds()
  let elapsed = now - start_time
  case elapsed > 0 && total_bytes > 0 {
    True -> {
      let bps = total_bytes / elapsed
      format_bytes(bps) <> "/s"
    }
    False -> ""
  }
}

fn color_green(s: String, no_color: Bool) -> String {
  case no_color {
    True -> s
    False -> "\u{1b}[32m" <> s <> "\u{1b}[0m"
  }
}
