//// CLI 오케스트레이터 — glint 기반 명령어 등록 및 디스패치

import gleam/io
import gleam/list
import gleam/result
import gleam/string
import glint
import kirari/audit
import kirari/cli/error
import kirari/cli/install
import kirari/cli/lock_resolve
import kirari/cli/log
import kirari/cli/output
import kirari/cli/query
import kirari/completion
import kirari/config
import kirari/platform
import kirari/sbom

// ---------------------------------------------------------------------------
// 공개 API
// ---------------------------------------------------------------------------

/// 최상위 에러 타입 re-export
pub type KirError =
  error.KirError

/// CLI 실행
pub fn run(args: List(String)) -> Result(Nil, KirError) {
  case args {
    ["--help"] | ["-h"] | ["help"] -> {
      print_help()
      Ok(Nil)
    }
    ["--version"] | ["-v"] -> {
      io.println("kirari " <> read_version())
      Ok(Nil)
    }
    // format은 glint 밖에서 처리 (--check 등 플래그를 gleam에 직접 전달)
    ["format", ..rest] -> {
      let _ = config.normalize_gleam_toml(".")
      let cmd = case rest {
        [] -> "gleam format"
        extra -> "gleam format " <> string.join(extra, " ")
      }
      output.run_gleam_cmd(cmd)
      Ok(Nil)
    }
    _ -> run_glint(args)
  }
}

/// 에러를 사람이 읽을 수 있는 형태로 출력
pub fn print_error(err: KirError) -> Nil {
  output.print_error(err)
}

// ---------------------------------------------------------------------------
// 명령어 등록
// ---------------------------------------------------------------------------

fn run_glint(args: List(String)) -> Result(Nil, KirError) {
  glint.new()
  |> glint.with_name("kir")
  |> glint.pretty_help(glint.default_pretty_help())
  |> glint.add(at: [], do: root_cmd())
  |> glint.add(at: ["init"], do: init_cmd())
  |> glint.add(at: ["install"], do: install_cmd())
  |> glint.add(at: ["add"], do: add_cmd())
  |> glint.add(at: ["remove"], do: remove_cmd())
  |> glint.add(at: ["update"], do: update_cmd())
  |> glint.add(at: ["deps", "list"], do: deps_list_cmd())
  |> glint.add(at: ["deps", "download"], do: deps_download_cmd())
  |> glint.add(at: ["tree"], do: tree_cmd())
  |> glint.add(at: ["outdated"], do: outdated_cmd())
  |> glint.add(at: ["why"], do: why_cmd())
  |> glint.add(at: ["clean"], do: clean_cmd())
  |> glint.add(at: ["lock", "resolve"], do: lock_resolve_cmd())
  |> glint.add(at: ["hash", "pin"], do: hash_pin_cmd())
  |> glint.add(at: ["hash", "verify"], do: hash_verify_cmd())
  |> glint.add(at: ["diff"], do: diff_cmd())
  |> glint.add(at: ["ls"], do: ls_cmd())
  |> glint.add(at: ["doctor"], do: doctor_cmd())
  |> glint.add(at: ["store", "verify"], do: store_verify_cmd())
  |> glint.add(at: ["publish"], do: publish_cmd())
  |> glint.add(at: ["hex", "retire"], do: hex_retire_cmd())
  |> glint.add(at: ["hex", "unretire"], do: hex_unretire_cmd())
  |> glint.add(
    at: ["hex", "revert"],
    do: gleam_passthrough_cmd("Revert a Hex release", "gleam hex revert"),
  )
  |> glint.add(
    at: ["hex", "owner"],
    do: gleam_passthrough_cmd("Manage package ownership", "gleam hex owner"),
  )
  |> glint.add(at: ["license"], do: license_cmd())
  |> glint.add(at: ["audit"], do: audit_cmd())
  |> glint.add(at: ["completion"], do: completion_cmd())
  |> glint.add(at: ["build"], do: build_cmd())
  |> glint.add(at: ["run"], do: run_cmd())
  |> glint.add(at: ["test"], do: test_cmd())
  |> glint.add(at: ["check"], do: check_cmd())
  |> glint.add(
    at: ["format"],
    do: gleam_passthrough_cmd("Format source code", "gleam format"),
  )
  |> glint.add(
    at: ["new"],
    do: gleam_passthrough_cmd("Create a new Gleam project", "gleam new"),
  )
  |> glint.add(
    at: ["shell"],
    do: gleam_passthrough_cmd("Start an Erlang shell", "gleam shell"),
  )
  |> glint.add(
    at: ["lsp"],
    do: gleam_passthrough_cmd("Run the language server", "gleam lsp"),
  )
  |> glint.add(at: ["dev"], do: dev_cmd())
  |> glint.add(
    at: ["fix"],
    do: gleam_passthrough_cmd("Rewrite deprecated code", "gleam fix"),
  )
  |> glint.add(
    at: ["docs", "build"],
    do: gleam_passthrough_cmd("Build documentation", "gleam docs build"),
  )
  |> glint.add(
    at: ["docs", "publish"],
    do: gleam_passthrough_cmd("Publish documentation", "gleam docs publish"),
  )
  |> glint.add(
    at: ["docs", "remove"],
    do: gleam_passthrough_cmd(
      "Remove published documentation",
      "gleam docs remove",
    ),
  )
  |> glint.add(at: ["export"], do: export_cmd())
  |> glint.add(at: ["export", "sbom"], do: export_sbom_cmd())
  |> glint.add(
    at: ["export", "erlang-shipment"],
    do: gleam_passthrough_cmd(
      "Export precompiled Erlang for deployment",
      "gleam export erlang-shipment",
    ),
  )
  |> glint.add(
    at: ["export", "hex-tarball"],
    do: gleam_passthrough_cmd(
      "Export package as tarball for Hex publishing",
      "gleam export hex-tarball",
    ),
  )
  |> glint.add(
    at: ["export", "javascript-prelude"],
    do: gleam_passthrough_cmd(
      "Export JavaScript prelude module",
      "gleam export javascript-prelude",
    ),
  )
  |> glint.add(
    at: ["export", "typescript-prelude"],
    do: gleam_passthrough_cmd(
      "Export TypeScript prelude module",
      "gleam export typescript-prelude",
    ),
  )
  |> glint.add(
    at: ["export", "package-interface"],
    do: gleam_passthrough_cmd(
      "Export package interface as JSON",
      "gleam export package-interface",
    ),
  )
  |> glint.run(args)

  Ok(Nil)
}

// ---------------------------------------------------------------------------
// 명령어 정의
// ---------------------------------------------------------------------------

fn root_cmd() -> glint.Command(Nil) {
  glint.command(fn(_named, _args, _flags) { print_help() })
}

fn init_cmd() -> glint.Command(Nil) {
  use <- glint.command_help("Add kirari sections to gleam.toml")
  use template_flag <- glint.flag(
    glint.string_flag("template")
    |> glint.flag_default("basic")
    |> glint.flag_help("Template: basic (default) or advanced"),
  )
  glint.command(fn(_named, _args, flags) {
    let template = template_flag(flags) |> result.unwrap("basic")
    case install.do_init_with_template(".", template) {
      Ok(_) -> Nil
      Error(e) -> output.print_error(e)
    }
  })
}

fn install_cmd() -> glint.Command(Nil) {
  use <- glint.command_help(
    "Resolve and install dependencies, generate kir.lock",
  )
  use frozen_flag <- glint.flag(
    glint.bool_flag("frozen")
    |> glint.flag_default(False)
    |> glint.flag_help("Verify lockfile matches without installing"),
  )
  use exclude_newer_flag <- glint.flag(
    glint.string_flag("exclude-newer")
    |> glint.flag_default("")
    |> glint.flag_help("Exclude versions published after timestamp (RFC 3339)"),
  )
  use offline_flag <- glint.flag(
    glint.bool_flag("offline")
    |> glint.flag_default(False)
    |> glint.flag_help("Use only cached packages, skip registry"),
  )
  use quiet_flag <- glint.flag(
    glint.bool_flag("quiet")
    |> glint.flag_default(False)
    |> glint.flag_help("Suppress output (CI mode)"),
  )
  use verify_flag <- glint.flag(
    glint.bool_flag("verify")
    |> glint.flag_default(False)
    |> glint.flag_help("Verify installed package integrity after install"),
  )
  use verbose_flag <- glint.flag(
    glint.bool_flag("verbose")
    |> glint.flag_default(False)
    |> glint.flag_help("Show detailed progress information"),
  )
  use debug_flag <- glint.flag(
    glint.bool_flag("debug")
    |> glint.flag_default(False)
    |> glint.flag_help("Show internal debug trace"),
  )
  glint.command(fn(_named, _args, flags) {
    let frozen = frozen_flag(flags) |> result.unwrap(False)
    let exclude_newer = exclude_newer_flag(flags) |> result.unwrap("")
    let offline = offline_flag(flags) |> result.unwrap(False)
    let quiet = quiet_flag(flags) |> result.unwrap(False)
    let verify = verify_flag(flags) |> result.unwrap(False)
    let verbose = verbose_flag(flags) |> result.unwrap(False)
    let debug = debug_flag(flags) |> result.unwrap(False)
    log.init(log.determine_level(quiet, verbose, debug))
    let install_result = case quiet {
      True -> install.do_install_quiet(".")
      False -> install.do_install(".", frozen, exclude_newer, verify, offline)
    }
    case install_result {
      Ok(_) -> Nil
      Error(e) -> output.print_error(e)
    }
  })
}

fn add_cmd() -> glint.Command(Nil) {
  use <- glint.command_help("Add a dependency (auto-detects Hex or npm)")
  use npm_flag <- glint.flag(
    glint.bool_flag("npm")
    |> glint.flag_default(False)
    |> glint.flag_help("Force npm registry"),
  )
  use dev_flag <- glint.flag(
    glint.bool_flag("dev")
    |> glint.flag_default(False)
    |> glint.flag_help("Add as dev dependency"),
  )
  glint.command(fn(_named, args, flags) {
    let is_npm = npm_flag(flags) |> result.unwrap(False)
    let is_dev = dev_flag(flags) |> result.unwrap(False)
    case args {
      [raw_name, ..] -> {
        let #(name, version) = install.parse_add_arg(raw_name, is_npm)
        case install.do_add(".", name, version, is_npm, is_dev) {
          Ok(_) -> Nil
          Error(e) -> output.print_error(e)
        }
      }
      _ -> io.println("Usage: kir add <package[@version]> [--npm] [--dev]")
    }
  })
}

fn remove_cmd() -> glint.Command(Nil) {
  use <- glint.command_help("Remove a dependency")
  use npm_flag <- glint.flag(
    glint.bool_flag("npm")
    |> glint.flag_default(False)
    |> glint.flag_help("Force npm registry"),
  )
  glint.command(fn(_named, args, flags) {
    let is_npm = npm_flag(flags) |> result.unwrap(False)
    case args {
      [name, ..] ->
        case install.do_remove(".", name, is_npm) {
          Ok(_) -> Nil
          Error(e) -> output.print_error(e)
        }
      _ -> io.println("Usage: kir remove <package> [--npm]")
    }
  })
}

fn update_cmd() -> glint.Command(Nil) {
  use <- glint.command_help("Update dependencies (all or specific packages)")
  glint.command(fn(_named, args, _flags) {
    let result = case args {
      [] -> install.do_update(".")
      packages -> install.do_update_selective(".", packages)
    }
    case result {
      Ok(_) -> Nil
      Error(e) -> output.print_error(e)
    }
  })
}

fn deps_list_cmd() -> glint.Command(Nil) {
  use <- glint.command_help("List all dependencies")
  use json_flag <- glint.flag(
    glint.bool_flag("json")
    |> glint.flag_default(False)
    |> glint.flag_help("Output as JSON"),
  )
  glint.command(fn(_named, _args, flags) {
    let json = json_flag(flags) |> result.unwrap(False)
    case install.do_deps_list(".", json) {
      Ok(_) -> Nil
      Error(e) -> output.print_error(e)
    }
  })
}

fn deps_download_cmd() -> glint.Command(Nil) {
  use <- glint.command_help("Download dependencies without installing")
  glint.command(fn(_named, _args, _flags) {
    case install.do_deps_download(".") {
      Ok(_) -> Nil
      Error(e) -> output.print_error(e)
    }
  })
}

fn tree_cmd() -> glint.Command(Nil) {
  use <- glint.command_help("Print the unified dependency tree")
  use json_flag <- glint.flag(
    glint.bool_flag("json")
    |> glint.flag_default(False)
    |> glint.flag_help("Output as JSON"),
  )
  glint.command(fn(_named, _args, flags) {
    let json = json_flag(flags) |> result.unwrap(False)
    case install.do_tree(".", json) {
      Ok(_) -> Nil
      Error(e) -> output.print_error(e)
    }
  })
}

fn export_cmd() -> glint.Command(Nil) {
  use <- glint.command_help("Export manifest.toml + package.json")
  glint.command(fn(_named, _args, _flags) {
    case install.do_export(".") {
      Ok(_) -> Nil
      Error(e) -> output.print_error(e)
    }
  })
}

fn export_sbom_cmd() -> glint.Command(Nil) {
  use <- glint.command_help("Export SBOM (SPDX 2.3 or CycloneDX 1.5)")
  use format_flag <- glint.flag(
    glint.string_flag("format")
    |> glint.flag_default("spdx")
    |> glint.flag_help("SBOM format: spdx or cyclonedx"),
  )
  use output_flag <- glint.flag(
    glint.string_flag("output")
    |> glint.flag_default("")
    |> glint.flag_help("Output file path (default: stdout)"),
  )
  glint.command(fn(_named, _args, flags) {
    let format_str = format_flag(flags) |> result.unwrap("spdx")
    let output_path = output_flag(flags) |> result.unwrap("")
    case sbom.parse_format(format_str) {
      Ok(format) ->
        case install.do_export_sbom(".", format, output_path) {
          Ok(_) -> Nil
          Error(e) -> output.print_error(e)
        }
      Error(_) ->
        io.println(
          "Invalid format: " <> format_str <> " (use 'spdx' or 'cyclonedx')",
        )
    }
  })
}

fn clean_cmd() -> glint.Command(Nil) {
  use <- glint.command_help("Remove build artifacts and store cache")
  use store_flag <- glint.flag(
    glint.bool_flag("store")
    |> glint.flag_default(False)
    |> glint.flag_help("Also garbage-collect the global package store"),
  )
  use keep_cache_flag <- glint.flag(
    glint.bool_flag("keep-cache")
    |> glint.flag_default(False)
    |> glint.flag_help("Keep Gleam compilation cache (_gleam_artefacts)"),
  )
  use dry_run_flag <- glint.flag(
    glint.bool_flag("dry-run")
    |> glint.flag_default(False)
    |> glint.flag_help("Show what would be removed without deleting"),
  )
  use only_flag <- glint.flag(
    glint.string_flag("only")
    |> glint.flag_default("")
    |> glint.flag_help("Remove only these packages (comma-separated names)"),
  )
  use keep_flag <- glint.flag(
    glint.string_flag("keep")
    |> glint.flag_default("")
    |> glint.flag_help("Preserve these packages (comma-separated names)"),
  )
  use max_age_flag <- glint.flag(
    glint.int_flag("max-age")
    |> glint.flag_default(0)
    |> glint.flag_help("Override retention days (0 = use defaults)"),
  )
  glint.command(fn(_named, _args, flags) {
    let clean_store = store_flag(flags) |> result.unwrap(False)
    let keep_cache = keep_cache_flag(flags) |> result.unwrap(False)
    let dry_run = dry_run_flag(flags) |> result.unwrap(False)
    let only = parse_comma_list(only_flag(flags) |> result.unwrap(""))
    let keep = parse_comma_list(keep_flag(flags) |> result.unwrap(""))
    let max_age = max_age_flag(flags) |> result.unwrap(0)
    install.do_clean(".", clean_store, keep_cache, dry_run, only, keep, max_age)
  })
}

fn parse_comma_list(s: String) -> List(String) {
  case s {
    "" -> []
    _ ->
      string.split(s, ",")
      |> list.map(string.trim)
      |> list.filter(fn(x) { x != "" })
  }
}

fn hash_pin_cmd() -> glint.Command(Nil) {
  use <- glint.command_help("Pin current hash of a package to .kir-hashes")
  glint.command(fn(_named, args, _flags) {
    case args {
      [name, ..] ->
        case install.do_hash_pin(".", name) {
          Ok(_) -> Nil
          Error(e) -> output.print_error(e)
        }
      _ -> io.println("Usage: kir hash pin <package>")
    }
  })
}

fn hash_verify_cmd() -> glint.Command(Nil) {
  use <- glint.command_help("Verify installed packages against .kir-hashes")
  glint.command(fn(_named, _args, _flags) {
    case install.do_hash_verify(".") {
      Ok(_) -> Nil
      Error(e) -> output.print_error(e)
    }
  })
}

fn lock_resolve_cmd() -> glint.Command(Nil) {
  use <- glint.command_help(
    "Re-resolve kir.lock from gleam.toml (fixes git merge conflicts)",
  )
  use dry_run_flag <- glint.flag(
    glint.bool_flag("dry-run")
    |> glint.flag_default(False)
    |> glint.flag_help("Show what would change without writing"),
  )
  glint.command(fn(_named, _args, flags) {
    log.init(log.determine_level_from_env())
    let dry_run = dry_run_flag(flags) |> result.unwrap(False)
    case lock_resolve.do_lock_resolve(".", dry_run) {
      Ok(_) -> Nil
      Error(e) -> output.print_error(e)
    }
  })
}

fn publish_cmd() -> glint.Command(Nil) {
  use <- glint.command_help("Publish package to Hex")
  use replace_flag <- glint.flag(
    glint.bool_flag("replace")
    |> glint.flag_default(False)
    |> glint.flag_help("Replace existing version on Hex"),
  )
  use yes_flag <- glint.flag(
    glint.bool_flag("yes")
    |> glint.flag_default(False)
    |> glint.flag_help("Skip confirmation prompt"),
  )
  use dry_run_flag <- glint.flag(
    glint.bool_flag("dry-run")
    |> glint.flag_default(False)
    |> glint.flag_help("Simulate publish without uploading"),
  )
  glint.command(fn(_named, _args, flags) {
    let replace = replace_flag(flags) |> result.unwrap(False)
    let yes = yes_flag(flags) |> result.unwrap(False)
    let dry_run = dry_run_flag(flags) |> result.unwrap(False)
    install.do_publish(".", replace, yes, dry_run)
  })
}

fn hex_retire_cmd() -> glint.Command(Nil) {
  use <- glint.command_help("Retire a Hex release")
  glint.command(fn(_named, args, _flags) {
    case args {
      [package, version, reason, ..rest] -> {
        let message = case rest {
          [msg, ..] -> " " <> msg
          [] -> ""
        }
        output.run_gleam_cmd(
          "gleam hex retire "
          <> package
          <> " "
          <> version
          <> " "
          <> reason
          <> message,
        )
      }
      _ ->
        io.println(
          "Usage: kir hex retire <package> <version> <reason> [message]",
        )
    }
  })
}

fn hex_unretire_cmd() -> glint.Command(Nil) {
  use <- glint.command_help("Un-retire a Hex release")
  glint.command(fn(_named, args, _flags) {
    case args {
      [package, version] ->
        output.run_gleam_cmd("gleam hex unretire " <> package <> " " <> version)
      _ -> io.println("Usage: kir hex unretire <package> <version>")
    }
  })
}

fn build_cmd() -> glint.Command(Nil) {
  install_then_gleam_cmd("Build the project", "gleam build")
}

fn run_cmd() -> glint.Command(Nil) {
  use <- glint.command_help("Run the project")
  glint.command(fn(_named, args, _flags) {
    let _ = config.normalize_gleam_toml(".")
    let _ = install.do_install_quiet(".")
    let cmd = case args {
      [] -> "gleam run"
      extra -> "gleam run -- " <> string.join(extra, " ")
    }
    output.run_gleam_cmd(cmd)
  })
}

fn test_cmd() -> glint.Command(Nil) {
  install_then_gleam_cmd("Run the tests", "gleam test")
}

fn check_cmd() -> glint.Command(Nil) {
  install_then_gleam_cmd("Type check the project", "gleam check")
}

fn dev_cmd() -> glint.Command(Nil) {
  install_then_gleam_cmd("Run the dev entrypoint", "gleam dev")
}

fn install_then_gleam_cmd(help: String, cmd: String) -> glint.Command(Nil) {
  use <- glint.command_help(help)
  glint.command(fn(_named, _args, _flags) {
    let _ = config.normalize_gleam_toml(".")
    let _ = install.do_install_quiet(".")
    output.run_gleam_cmd(cmd)
  })
}

fn gleam_passthrough_cmd(help: String, cmd: String) -> glint.Command(Nil) {
  use <- glint.command_help(help)
  glint.command(fn(_named, _args, _flags) {
    let _ = config.normalize_gleam_toml(".")
    output.run_gleam_cmd(cmd)
  })
}

fn outdated_cmd() -> glint.Command(Nil) {
  use <- glint.command_help("List outdated dependencies")
  use json_flag <- glint.flag(
    glint.bool_flag("json")
    |> glint.flag_default(False)
    |> glint.flag_help("Output as JSON"),
  )
  glint.command(fn(_named, _args, flags) {
    let json = json_flag(flags) |> result.unwrap(False)
    case query.do_outdated(".", json) {
      Ok(_) -> Nil
      Error(e) -> output.print_error(e)
    }
  })
}

fn why_cmd() -> glint.Command(Nil) {
  use <- glint.command_help("Explain why a package is installed")
  use json_flag <- glint.flag(
    glint.bool_flag("json")
    |> glint.flag_default(False)
    |> glint.flag_help("Output as JSON"),
  )
  glint.command(fn(_named, args, flags) {
    let json = json_flag(flags) |> result.unwrap(False)
    case args {
      [name, ..] ->
        case query.do_why(".", name, json) {
          Ok(_) -> Nil
          Error(e) -> output.print_error(e)
        }
      _ -> io.println("Usage: kir why <package>")
    }
  })
}

fn diff_cmd() -> glint.Command(Nil) {
  use <- glint.command_help("Show lock changes (update preview)")
  use json_flag <- glint.flag(
    glint.bool_flag("json")
    |> glint.flag_default(False)
    |> glint.flag_help("Output as JSON"),
  )
  glint.command(fn(_named, _args, flags) {
    let json = json_flag(flags) |> result.unwrap(False)
    case query.do_diff(".", json) {
      Ok(_) -> Nil
      Error(e) -> output.print_error(e)
    }
  })
}

fn ls_cmd() -> glint.Command(Nil) {
  use <- glint.command_help("List installed packages with paths")
  use json_flag <- glint.flag(
    glint.bool_flag("json")
    |> glint.flag_default(False)
    |> glint.flag_help("Output as JSON"),
  )
  glint.command(fn(_named, _args, flags) {
    let json = json_flag(flags) |> result.unwrap(False)
    case query.do_ls(".", json) {
      Ok(_) -> Nil
      Error(e) -> output.print_error(e)
    }
  })
}

fn doctor_cmd() -> glint.Command(Nil) {
  use <- glint.command_help("Diagnose environment")
  glint.command(fn(_named, _args, _flags) { query.do_doctor(".") })
}

fn store_verify_cmd() -> glint.Command(Nil) {
  use <- glint.command_help("Verify cached package integrity")
  use quick_flag <- glint.flag(
    glint.bool_flag("quick")
    |> glint.flag_default(False)
    |> glint.flag_help("Quick check (manifest exists + file count only)"),
  )
  use json_flag <- glint.flag(
    glint.bool_flag("json")
    |> glint.flag_default(False)
    |> glint.flag_help("Output as JSON"),
  )
  glint.command(fn(_named, _args, flags) {
    let quick = case quick_flag(flags) {
      Ok(v) -> v
      Error(_) -> False
    }
    let json = json_flag(flags) |> result.unwrap(False)
    case query.do_store_verify(".", quick, json) {
      Ok(_) -> Nil
      Error(e) -> output.print_error(e)
    }
  })
}

fn license_cmd() -> glint.Command(Nil) {
  use <- glint.command_help("Audit dependency licenses against policy")
  use json_flag <- glint.flag(
    glint.bool_flag("json")
    |> glint.flag_default(False)
    |> glint.flag_help("Output as JSON"),
  )
  glint.command(fn(_named, _args, flags) {
    let json = json_flag(flags) |> result.unwrap(False)
    case query.do_license(".", json) {
      Ok(_) -> Nil
      Error(e) -> output.print_error(e)
    }
  })
}

fn completion_cmd() -> glint.Command(Nil) {
  use <- glint.command_help(
    "Generate shell completion script (bash, zsh, fish)",
  )
  glint.command(fn(_named, args, _flags) {
    case args {
      ["bash", ..] -> io.println(completion.generate_bash())
      ["zsh", ..] -> io.println(completion.generate_zsh())
      ["fish", ..] -> io.println(completion.generate_fish())
      _ ->
        io.println(
          "Usage: kir completion <bash|zsh|fish>\n\n"
          <> "Examples:\n"
          <> "  eval \"$(kir completion bash)\"    # bash\n"
          <> "  kir completion zsh > ~/.zfunc/_kir  # zsh\n"
          <> "  kir completion fish | source        # fish",
        )
    }
  })
}

fn audit_cmd() -> glint.Command(Nil) {
  use <- glint.command_help("Audit dependencies for known vulnerabilities")
  use json_flag <- glint.flag(
    glint.bool_flag("json")
    |> glint.flag_default(False)
    |> glint.flag_help("Output results as JSON"),
  )
  use severity_flag <- glint.flag(
    glint.string_flag("severity")
    |> glint.flag_default("low")
    |> glint.flag_help(
      "Minimum severity to report: low, moderate, high, critical",
    ),
  )
  glint.command(fn(_named, _args, flags) {
    let json = json_flag(flags) |> result.unwrap(False)
    let severity_str = severity_flag(flags) |> result.unwrap("low")
    let severity =
      audit.severity_from_string(severity_str) |> result.unwrap(audit.Low)
    case query.do_audit(".", json, severity) {
      Ok(True) -> platform.halt(1)
      Ok(False) -> Nil
      Error(e) -> output.print_error(e)
    }
  })
}

// ---------------------------------------------------------------------------
// 헬퍼
// ---------------------------------------------------------------------------

fn print_help() -> Nil {
  io.println("kir — unified package manager for Gleam")
  let version = platform.app_version() |> result.unwrap("unknown")
  io.println("kirari " <> version)
  io.println("")
  io.println("Usage: kir <command> [flags]")
  io.println("")
  io.println("Commands:")
  io.println("  build       Build the project")
  io.println("  run         Run the project")
  io.println("  test        Run the tests")
  io.println("  check       Type check the project")
  io.println("  dev         Run the dev entrypoint")
  io.println("  init        Add kirari sections to gleam.toml")
  io.println("  install     Resolve and install dependencies")
  io.println("  update      Update dependencies (all or specific packages)")
  io.println("  add         Add a dependency (supports pkg@version)")
  io.println("  remove      Remove a dependency")
  io.println("  outdated    List outdated dependencies")
  io.println("  why         Explain why a package is installed")
  io.println("  diff        Show lock changes (update preview)")
  io.println("  ls          List installed packages with paths")
  io.println("  doctor      Diagnose environment")
  io.println("  deps list   List all dependencies")
  io.println("  deps download  Download dependencies without installing")
  io.println("  tree        Print full dependency tree")
  io.println("  clean       Remove build artifacts and store cache")
  io.println("  publish     Publish package to Hex")
  io.println("  hex retire  Retire a Hex release")
  io.println("  hex unretire  Un-retire a Hex release")
  io.println("  hex revert  Revert a Hex release")
  io.println("  hex owner   Manage package ownership")
  io.println("  store verify  Verify cached package integrity")
  io.println("  license     Audit dependency licenses")
  io.println("  audit       Audit dependencies for vulnerabilities")
  io.println("  export      Export manifest.toml + package.json")
  io.println("  export sbom Export SBOM (SPDX/CycloneDX)")
  io.println("  format      Format source code")
  io.println("  fix         Rewrite deprecated code")
  io.println("  new         Create a new Gleam project")
  io.println("  shell       Start an Erlang shell")
  io.println("  lsp         Run the language server")
  io.println("  docs        Build, publish, or remove documentation")
  io.println("  help        Print this help message")
  io.println("")
  io.println("Flags:")
  io.println("  --help, -h     Print help")
  io.println("  --version, -v  Print version")
}

fn read_version() -> String {
  platform.app_version() |> result.unwrap("unknown")
}
