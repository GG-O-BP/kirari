//// CLI 출력 헬퍼 — 색상, 경고, 포맷팅, 외부 명령 실행

import gleam/io
import gleam/list
import gleam/string
import gleam_community/ansi
import kirari/cli/error.{type KirError}
import kirari/installer
import kirari/pipeline
import kirari/platform
import kirari/types.{type Override}

// ---------------------------------------------------------------------------
// 에러 출력
// ---------------------------------------------------------------------------

/// 에러를 사람이 읽을 수 있는 형태로 stderr에 출력
pub fn print_error(err: KirError) -> Nil {
  io.println_error(color_bold_red("error:") <> " " <> error.format_error(err))
}

// ---------------------------------------------------------------------------
// 색상 래퍼 (NO_COLOR 대응)
// ---------------------------------------------------------------------------

pub fn color_green(s: String) -> String {
  case platform.get_env("NO_COLOR") {
    Ok(_) -> s
    Error(_) -> ansi.green(s)
  }
}

pub fn color_red(s: String) -> String {
  case platform.get_env("NO_COLOR") {
    Ok(_) -> s
    Error(_) -> ansi.red(s)
  }
}

pub fn color_yellow(s: String) -> String {
  case platform.get_env("NO_COLOR") {
    Ok(_) -> s
    Error(_) -> ansi.yellow(s)
  }
}

pub fn color_dim(s: String) -> String {
  case platform.get_env("NO_COLOR") {
    Ok(_) -> s
    Error(_) -> ansi.dim(s)
  }
}

pub fn color_bold_red(s: String) -> String {
  case platform.get_env("NO_COLOR") {
    Ok(_) -> s
    Error(_) -> ansi.red(ansi.bold(s))
  }
}

// ---------------------------------------------------------------------------
// 경고 출력
// ---------------------------------------------------------------------------

pub fn print_pipeline_warnings(warnings: List(pipeline.Warning)) -> Nil {
  list.each(warnings, fn(w) {
    case w {
      pipeline.ScriptBlocked(name, version) ->
        io.println(
          color_yellow("\u{26a0}")
          <> " "
          <> name
          <> "@"
          <> version
          <> " has install scripts (blocked by npm-scripts policy)",
        )
      pipeline.Deprecated(name, version, reason) ->
        io.println(
          color_yellow("\u{26a0}")
          <> " "
          <> name
          <> "@"
          <> version
          <> " is deprecated: "
          <> reason,
        )
      pipeline.PlatformMismatch(name, version, os, arch) ->
        io.println(
          color_yellow("\u{26a0}")
          <> " "
          <> name
          <> "@"
          <> version
          <> " may not be compatible with "
          <> os
          <> "/"
          <> arch,
        )
      pipeline.PeerDependencyMissing(package, peer, constraint) ->
        io.println(
          color_yellow("\u{26a0}")
          <> " "
          <> package
          <> " requires peer dependency "
          <> peer
          <> " "
          <> constraint
          <> " but it is not installed",
        )
      pipeline.PeerDependencyIncompatible(package, peer, required, installed) ->
        io.println(
          color_yellow("\u{26a0}")
          <> " "
          <> package
          <> " requires peer "
          <> peer
          <> " "
          <> required
          <> " but "
          <> installed
          <> " is installed",
        )
      pipeline.OptionalSkipped(name, reason) ->
        io.println(color_dim("  skipped optional " <> name <> ": " <> reason))
    }
  })
}

pub fn print_installer_warnings(warnings: List(installer.Warning)) -> Nil {
  list.each(warnings, fn(w) {
    case w {
      installer.PlatformMismatch(name, version, os, arch) ->
        io.println(
          color_yellow("\u{26a0}")
          <> " "
          <> name
          <> "@"
          <> version
          <> " may not be compatible with "
          <> os
          <> "/"
          <> arch,
        )
    }
  })
}

// ---------------------------------------------------------------------------
// 오버라이드 출력
// ---------------------------------------------------------------------------

pub fn print_overrides(overrides: List(Override)) -> Nil {
  case overrides {
    [] -> Nil
    _ -> {
      io.println(color_yellow("Overrides:"))
      list.each(overrides, fn(o) {
        io.println(
          "  "
          <> o.name
          <> " → "
          <> color_dim(o.version_constraint)
          <> " ("
          <> types.registry_to_string(o.registry)
          <> ")",
        )
      })
    }
  }
}

// ---------------------------------------------------------------------------
// 유틸리티
// ---------------------------------------------------------------------------

/// gleam 명령어 실행, 실패 시 프로세스 종료
pub fn run_gleam_cmd(cmd: String) -> Nil {
  let code = platform.exec_command(cmd)
  case code {
    0 -> Nil
    _ -> platform.halt(code)
  }
}

/// 문자열을 고정 폭으로 패딩
pub fn pad_right(s: String, width: Int) -> String {
  let len = string.length(s)
  case len >= width {
    True -> s <> " "
    False -> s <> string.repeat(" ", width - len)
  }
}
