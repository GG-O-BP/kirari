//// CLI 오케스트레이터 — glint 기반 명령어 등록 및 디스패치

import gleam/int
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import gleam_community/ansi
import glint
import kirari/config
import kirari/export
import kirari/ffi as ffi_detect
import kirari/lockfile
import kirari/migrate
import kirari/pipeline
import kirari/platform
import kirari/resolver
import kirari/tree
import kirari/types.{
  type Dependency, type KirConfig, Dependency, Hex, KirConfig, Npm,
}
import simplifile

/// 최상위 에러 타입 — 모든 모듈 에러를 래핑
pub type KirError {
  ConfigErr(config.ConfigError)
  MigrateErr(migrate.MigrateError)
  LockErr(lockfile.LockfileError)
  ResolveErr(resolver.ResolverError)
  PipelineErr(pipeline.PipelineError)
  ExportErr(export.ExportError)
  FfiErr(ffi_detect.FfiError)
  UserError(detail: String)
}

// ---------------------------------------------------------------------------
// 공개 API
// ---------------------------------------------------------------------------

/// CLI 실행
pub fn run(args: List(String)) -> Result(Nil, KirError) {
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
  |> glint.add(at: ["clean"], do: clean_cmd())
  |> glint.add(at: ["publish"], do: publish_cmd())
  |> glint.add(at: ["hex", "retire"], do: hex_retire_cmd())
  |> glint.add(at: ["hex", "unretire"], do: hex_unretire_cmd())
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

/// 에러를 사람이 읽을 수 있는 형태로 출력
pub fn print_error(error: KirError) -> Nil {
  io.println_error(ansi.red(ansi.bold("error:")) <> " " <> format_error(error))
}

fn format_error(error: KirError) -> String {
  case error {
    ConfigErr(e) ->
      case e {
        config.FileNotFound(p) -> "file not found: " <> p
        config.ParseError(d) -> "parse error: " <> d
        config.InvalidField(f, d) -> "invalid field " <> f <> ": " <> d
        config.WriteError(p, d) -> "write error " <> p <> ": " <> d
      }
    MigrateErr(e) ->
      case e {
        migrate.FileNotFound(p) -> "file not found: " <> p
        migrate.ParseError(d) -> "parse error: " <> d
        migrate.InvalidField(f, d) -> "invalid field " <> f <> ": " <> d
      }
    LockErr(e) ->
      case e {
        lockfile.FileNotFound(p) -> "lockfile not found: " <> p
        lockfile.ParseError(d) -> "lockfile parse error: " <> d
        lockfile.FrozenMismatch(d) -> "frozen lockfile mismatch: " <> d
        lockfile.WriteError(p, d) -> "lockfile write error " <> p <> ": " <> d
      }
    ResolveErr(e) ->
      case e {
        resolver.IncompatibleVersions(pkg, cs) ->
          "no compatible version for "
          <> pkg
          <> " (constraints: "
          <> string.join(cs, ", ")
          <> ")"
        resolver.PackageNotFound(name, reg) ->
          "package not found: "
          <> name
          <> " ("
          <> types.registry_to_string(reg)
          <> ")"
        resolver.RegistryError(d) -> "registry error: " <> d
        resolver.CyclicDependency(c) ->
          "cyclic dependency: " <> string.join(c, " → ")
      }
    PipelineErr(e) ->
      case e {
        pipeline.DownloadError(name, ver, d) ->
          "download failed: " <> name <> "@" <> ver <> " — " <> d
        pipeline.StoreErr(se) -> "store error: " <> string.inspect(se)
        pipeline.InstallErr(ie) -> "install error: " <> string.inspect(ie)
      }
    ExportErr(e) ->
      case e {
        export.WriteError(p, d) -> "export write error " <> p <> ": " <> d
      }
    FfiErr(e) ->
      case e {
        ffi_detect.IoError(d) -> "ffi detection error: " <> d
      }
    UserError(d) -> d
  }
}

// ---------------------------------------------------------------------------
// 명령어 구현
// ---------------------------------------------------------------------------

fn root_cmd() -> glint.Command(Nil) {
  glint.command(fn(_named, _args, _flags) {
    io.println("kir — unified package manager for Gleam")
    io.println("")
    io.println("Commands:")
    io.println("  init        Add kirari sections to gleam.toml")
    io.println("  install     Resolve and install dependencies")
    io.println("  update      Update all to latest compatible versions")
    io.println("  add         Add a dependency")
    io.println("  remove      Remove a dependency")
    io.println("  deps list   List all dependencies")
    io.println("  deps download  Download dependencies without installing")
    io.println("  tree        Print dependency tree")
    io.println("  clean       Remove build artifacts and store cache")
    io.println("  publish     Publish package to Hex")
    io.println("  hex retire  Retire a Hex release")
    io.println("  hex unretire  Un-retire a Hex release")
    io.println("  export      Export manifest.toml + package.json")
  })
}

fn init_cmd() -> glint.Command(Nil) {
  use <- glint.command_help("Add kirari sections to gleam.toml")
  glint.command(fn(_named, _args, _flags) {
    case do_init(".") {
      Ok(_) -> Nil
      Error(e) -> print_error(e)
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
  glint.command(fn(_named, _args, flags) {
    let frozen = frozen_flag(flags) |> result.unwrap(False)
    let exclude_newer = exclude_newer_flag(flags) |> result.unwrap("")
    case do_install(".", frozen, exclude_newer) {
      Ok(_) -> Nil
      Error(e) -> print_error(e)
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
      [name, ..] ->
        case do_add(".", name, is_npm, is_dev) {
          Ok(_) -> Nil
          Error(e) -> print_error(e)
        }
      _ -> io.println("Usage: kir add <package> [--npm] [--dev]")
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
        case do_remove(".", name, is_npm) {
          Ok(_) -> Nil
          Error(e) -> print_error(e)
        }
      _ -> io.println("Usage: kir remove <package> [--npm]")
    }
  })
}

fn update_cmd() -> glint.Command(Nil) {
  use <- glint.command_help(
    "Update all dependencies to latest compatible versions",
  )
  glint.command(fn(_named, _args, _flags) {
    case do_update(".") {
      Ok(_) -> Nil
      Error(e) -> print_error(e)
    }
  })
}

fn deps_list_cmd() -> glint.Command(Nil) {
  use <- glint.command_help("List all dependencies")
  glint.command(fn(_named, _args, _flags) {
    case do_deps_list(".") {
      Ok(_) -> Nil
      Error(e) -> print_error(e)
    }
  })
}

fn deps_download_cmd() -> glint.Command(Nil) {
  use <- glint.command_help("Download dependencies without installing")
  glint.command(fn(_named, _args, _flags) {
    case do_deps_download(".") {
      Ok(_) -> Nil
      Error(e) -> print_error(e)
    }
  })
}

fn build_cmd() -> glint.Command(Nil) {
  install_then_gleam_cmd("Build the project", "gleam build")
}

fn run_cmd() -> glint.Command(Nil) {
  install_then_gleam_cmd("Run the project", "gleam run")
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

/// install(store → hardlink) 후 gleam 명령어 실행
fn install_then_gleam_cmd(help: String, cmd: String) -> glint.Command(Nil) {
  use <- glint.command_help(help)
  glint.command(fn(_named, _args, _flags) {
    let _ = do_install_quiet(".")
    run_gleam_cmd(cmd)
  })
}

fn clean_cmd() -> glint.Command(Nil) {
  use <- glint.command_help("Remove build artifacts and store cache")
  glint.command(fn(_named, _args, _flags) { do_clean(".") })
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
  glint.command(fn(_named, _args, flags) {
    let replace = replace_flag(flags) |> result.unwrap(False)
    let yes = yes_flag(flags) |> result.unwrap(False)
    do_publish(".", replace, yes)
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
        run_gleam_cmd(
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
        run_gleam_cmd("gleam hex unretire " <> package <> " " <> version)
      _ -> io.println("Usage: kir hex unretire <package> <version>")
    }
  })
}

fn gleam_passthrough_cmd(help: String, cmd: String) -> glint.Command(Nil) {
  use <- glint.command_help(help)
  glint.command(fn(_named, _args, _flags) { run_gleam_cmd(cmd) })
}

fn tree_cmd() -> glint.Command(Nil) {
  use <- glint.command_help("Print the unified dependency tree")
  glint.command(fn(_named, _args, _flags) {
    case do_tree(".") {
      Ok(_) -> Nil
      Error(e) -> print_error(e)
    }
  })
}

fn export_cmd() -> glint.Command(Nil) {
  use <- glint.command_help("Export manifest.toml + package.json")
  glint.command(fn(_named, _args, _flags) {
    case do_export(".") {
      Ok(_) -> Nil
      Error(e) -> print_error(e)
    }
  })
}

// ---------------------------------------------------------------------------
// 명령어 로직
// ---------------------------------------------------------------------------

fn do_init(dir: String) -> Result(Nil, KirError) {
  io.println("Initializing kirari...")
  use cfg <- result.try(
    config.read_config(dir)
    |> result.map_error(ConfigErr),
  )
  // package.json이 있으면 npm 의존성을 [npm-dependencies]에 병합
  let npm_deps = case migrate.read_package_json(dir) {
    Ok(deps) -> deps
    Error(_) -> []
  }
  let merged = merge_npm_deps(cfg, npm_deps)
  use _ <- result.try(
    config.write_config(merged, dir)
    |> result.map_error(ConfigErr),
  )
  io.println(ansi.green("Initialized") <> " gleam.toml with kirari sections")
  Ok(Nil)
}

fn do_install(
  dir: String,
  frozen: Bool,
  exclude_newer: String,
) -> Result(Nil, KirError) {
  use cfg <- result.try(
    config.read_config(dir)
    |> result.map_error(ConfigErr),
  )
  // --exclude-newer 플래그로 오버라이드
  let cfg = case exclude_newer {
    "" -> cfg
    ts ->
      types.KirConfig(
        ..cfg,
        security: types.SecurityConfig(exclude_newer: Ok(ts)),
      )
  }
  let existing_lock =
    lockfile.read(dir)
    |> result.map_error(fn(_) { Nil })
  io.println("Resolving dependencies...")
  use resolve_result <- result.try(
    resolver.resolve_full(cfg, existing_lock)
    |> result.map_error(ResolveErr),
  )
  io.println(
    ansi.green("Resolved")
    <> " "
    <> int.to_string(list.length(resolve_result.packages))
    <> " packages",
  )
  // --frozen: lockfile 일치 검증만 수행
  case frozen {
    True -> {
      use lock <- result.try(
        lockfile.read(dir)
        |> result.map_error(LockErr),
      )
      use _ <- result.try(
        lockfile.verify_frozen(lock, resolve_result.packages)
        |> result.map_error(LockErr),
      )
      io.println(ansi.green("Verified") <> " lockfile matches (--frozen)")
      Ok(Nil)
    }
    False -> {
      // 다운로드 → 저장 → 설치
      io.println("Downloading and installing...")
      use installed <- result.try(
        pipeline.run(resolve_result, dir)
        |> result.map_error(PipelineErr),
      )
      // lockfile 기록 (실제 sha256 포함)
      let lock = lockfile.from_packages(installed)
      use _ <- result.try(
        lockfile.write(lock, dir)
        |> result.map_error(LockErr),
      )
      io.println(
        ansi.green("Installed")
        <> " "
        <> int.to_string(list.length(installed))
        <> " packages, wrote kir.lock",
      )
      // gleam build 호환: gleam.toml + manifest.toml 자동 생성
      let _ = export.write_build_metadata(cfg, lock, dir)
      // FFI 감지: 미선언 npm import 경고
      warn_undeclared_npm(dir, cfg)
      Ok(Nil)
    }
  }
}

/// install과 동일하되 출력 없이 수행 (kir build/run/test/check/dev 용)
fn do_install_quiet(dir: String) -> Result(Nil, KirError) {
  use cfg <- result.try(
    config.read_config(dir)
    |> result.map_error(ConfigErr),
  )
  let existing_lock =
    lockfile.read(dir)
    |> result.map_error(fn(_) { Nil })
  use resolve_result <- result.try(
    resolver.resolve_full(cfg, existing_lock)
    |> result.map_error(ResolveErr),
  )
  use installed <- result.try(
    pipeline.run(resolve_result, dir)
    |> result.map_error(PipelineErr),
  )
  let lock = lockfile.from_packages(installed)
  use _ <- result.try(
    lockfile.write(lock, dir)
    |> result.map_error(LockErr),
  )
  let _ = export.write_build_metadata(cfg, lock, dir)
  Ok(Nil)
}

fn do_update(dir: String) -> Result(Nil, KirError) {
  use cfg <- result.try(
    config.read_config(dir)
    |> result.map_error(ConfigErr),
  )
  io.println("Updating all dependencies...")
  // lock 무시 — Error(Nil) 전달하여 전부 재해결
  use resolve_result <- result.try(
    resolver.resolve_full(cfg, Error(Nil))
    |> result.map_error(ResolveErr),
  )
  io.println(
    ansi.green("Resolved")
    <> " "
    <> int.to_string(list.length(resolve_result.packages))
    <> " packages",
  )
  io.println("Downloading and installing...")
  use installed <- result.try(
    pipeline.run(resolve_result, dir)
    |> result.map_error(PipelineErr),
  )
  let lock = lockfile.from_packages(installed)
  use _ <- result.try(
    lockfile.write(lock, dir)
    |> result.map_error(LockErr),
  )
  io.println(
    ansi.green("Updated")
    <> " "
    <> int.to_string(list.length(installed))
    <> " packages, wrote kir.lock",
  )
  let _ = export.write_build_metadata(cfg, lock, dir)
  Ok(Nil)
}

fn do_add(
  dir: String,
  name: String,
  is_npm: Bool,
  is_dev: Bool,
) -> Result(Nil, KirError) {
  use cfg <- result.try(
    config.read_config(dir)
    |> result.map_error(ConfigErr),
  )
  let registry = case is_npm {
    True -> Npm
    False -> detect_registry(name)
  }
  let dep =
    Dependency(
      name: name,
      version_constraint: case registry {
        Hex -> ">= 0.0.0"
        Npm -> "*"
      },
      registry: registry,
      dev: is_dev,
    )
  let updated = config.add_dependency(cfg, dep)
  use _ <- result.try(
    config.write_config(updated, dir)
    |> result.map_error(ConfigErr),
  )
  io.println(
    ansi.green("Added")
    <> " "
    <> name
    <> " to ["
    <> types.registry_to_string(registry)
    <> case is_dev {
      True -> ".dev"
      False -> ""
    }
    <> "]",
  )
  do_install(dir, False, "")
}

fn do_remove(dir: String, name: String, is_npm: Bool) -> Result(Nil, KirError) {
  use cfg <- result.try(
    config.read_config(dir)
    |> result.map_error(ConfigErr),
  )
  let registry = case is_npm {
    True -> Npm
    False -> detect_registry(name)
  }
  let updated = config.remove_dependency(cfg, name, registry)
  use _ <- result.try(
    config.write_config(updated, dir)
    |> result.map_error(ConfigErr),
  )
  io.println(
    ansi.red("Removed")
    <> " "
    <> name
    <> " from ["
    <> types.registry_to_string(registry)
    <> "]",
  )
  do_install(dir, False, "")
}

fn do_tree(dir: String) -> Result(Nil, KirError) {
  use cfg <- result.try(
    config.read_config(dir)
    |> result.map_error(ConfigErr),
  )
  use lock <- result.try(
    lockfile.read(dir)
    |> result.map_error(LockErr),
  )
  let roots = tree.build(cfg, lock)
  let output = tree.render(roots)
  case output {
    "" -> io.println("(no dependencies)")
    _ -> io.println(output)
  }
  Ok(Nil)
}

fn do_export(dir: String) -> Result(Nil, KirError) {
  use cfg <- result.try(
    config.read_config(dir)
    |> result.map_error(ConfigErr),
  )
  let lock =
    lockfile.read(dir)
    |> result.map_error(fn(_) { Nil })
  use paths <- result.try(
    export.export(cfg, lock, dir)
    |> result.map_error(ExportErr),
  )
  list.each(paths, fn(p) { io.println("Wrote " <> p) })
  Ok(Nil)
}

fn do_deps_list(dir: String) -> Result(Nil, KirError) {
  use cfg <- result.try(
    config.read_config(dir)
    |> result.map_error(ConfigErr),
  )
  let all_deps =
    list.flatten([
      cfg.hex_deps,
      cfg.hex_dev_deps,
      cfg.npm_deps,
      cfg.npm_dev_deps,
    ])
    |> list.sort(fn(a, b) { string.compare(a.name, b.name) })
  case all_deps {
    [] -> io.println("(no dependencies)")
    _ ->
      list.each(all_deps, fn(d) {
        io.println(
          d.name
          <> " "
          <> ansi.dim(d.version_constraint)
          <> " ("
          <> types.registry_to_string(d.registry)
          <> case d.dev {
            True -> ", dev"
            False -> ""
          }
          <> ")",
        )
      })
  }
  Ok(Nil)
}

fn do_deps_download(dir: String) -> Result(Nil, KirError) {
  use cfg <- result.try(
    config.read_config(dir)
    |> result.map_error(ConfigErr),
  )
  let existing_lock =
    lockfile.read(dir)
    |> result.map_error(fn(_) { Nil })
  io.println("Resolving dependencies...")
  use resolve_result <- result.try(
    resolver.resolve_full(cfg, existing_lock)
    |> result.map_error(ResolveErr),
  )
  io.println("Downloading...")
  use installed <- result.try(
    pipeline.run(resolve_result, dir)
    |> result.map_error(PipelineErr),
  )
  let lock = lockfile.from_packages(installed)
  use _ <- result.try(
    lockfile.write(lock, dir)
    |> result.map_error(LockErr),
  )
  io.println(
    ansi.green("Downloaded")
    <> " "
    <> int.to_string(list.length(installed))
    <> " packages",
  )
  Ok(Nil)
}

fn do_clean(dir: String) -> Nil {
  let _ = simplifile.delete(dir <> "/build")
  let _ = simplifile.delete(dir <> "/node_modules")
  io.println(ansi.green("Cleaned") <> " build artifacts")
}

fn do_publish(dir: String, replace: Bool, yes: Bool) -> Nil {
  // kir export로 gleam.toml 생성 후 gleam publish 위임
  case do_export(dir) {
    Ok(_) -> Nil
    Error(e) -> {
      print_error(e)
    }
  }
  let cmd =
    "gleam publish"
    <> case replace {
      True -> " --replace"
      False -> ""
    }
    <> case yes {
      True -> " --yes"
      False -> ""
    }
  run_gleam_cmd(cmd)
}

fn run_gleam_cmd(cmd: String) -> Nil {
  case platform.run_command(cmd) {
    Ok(output) -> io.print(output)
    Error(#(_code, output)) -> {
      io.print(output)
    }
  }
}

// ---------------------------------------------------------------------------
// 헬퍼
// ---------------------------------------------------------------------------

fn merge_npm_deps(config: KirConfig, npm_deps: List(Dependency)) -> KirConfig {
  let prod = list.filter(npm_deps, fn(d) { !d.dev })
  let dev = list.filter(npm_deps, fn(d) { d.dev })
  KirConfig(
    ..config,
    npm_deps: list.append(config.npm_deps, prod),
    npm_dev_deps: list.append(config.npm_dev_deps, dev),
  )
}

/// @로 시작하면 npm, 아니면 hex로 추정
fn detect_registry(name: String) -> types.Registry {
  case string.starts_with(name, "@") {
    True -> Npm
    False -> Hex
  }
}

fn warn_undeclared_npm(dir: String, cfg: KirConfig) -> Nil {
  case ffi_detect.detect_npm_imports(dir) {
    Ok(detections) -> {
      let undeclared = ffi_detect.find_undeclared(detections, cfg)
      let names =
        list.map(undeclared, fn(d) { d.package_name })
        |> list.unique
      case names {
        [] -> Nil
        _ -> {
          io.println(
            ansi.yellow("Warning:") <> " undeclared npm imports detected:",
          )
          list.each(names, fn(n) { io.println("  " <> n) })
        }
      }
    }
    Error(_) -> Nil
  }
}
