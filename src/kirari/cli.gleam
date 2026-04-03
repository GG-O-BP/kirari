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
import kirari/resolver
import kirari/tree
import kirari/types.{
  type Dependency, type KirConfig, Dependency, Hex, KirConfig, Npm,
}

/// 최상위 에러 타입 — 모든 모듈 에러를 래핑
pub type KirError {
  ConfigErr(config.ConfigError)
  MigrateErr(migrate.MigrateError)
  LockErr(lockfile.LockfileError)
  ResolveErr(resolver.ResolverError)
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
  |> glint.add(at: ["tree"], do: tree_cmd())
  |> glint.add(at: ["export"], do: export_cmd())
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
    io.println("  init      Migrate gleam.toml + package.json → kir.toml")
    io.println("  install   Resolve and install dependencies")
    io.println("  add       Add a dependency")
    io.println("  tree      Print dependency tree")
    io.println("  export    Export kir.toml → gleam.toml + package.json")
  })
}

fn init_cmd() -> glint.Command(Nil) {
  use <- glint.command_help("Migrate gleam.toml + package.json → kir.toml")
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
  glint.command(fn(_named, _args, _flags) {
    case do_install(".") {
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
  use <- glint.command_help("Export kir.toml → gleam.toml + package.json")
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
  io.println("Migrating to kir.toml...")
  use gleam_config <- result.try(
    migrate.read_gleam_toml(dir)
    |> result.map_error(MigrateErr),
  )
  // package.json이 있으면 npm 의존성도 병합
  let npm_deps = case migrate.read_package_json(dir) {
    Ok(deps) -> deps
    Error(_) -> []
  }
  let merged = merge_npm_deps(gleam_config, npm_deps)
  use _ <- result.try(
    config.write_kir_toml(merged, dir)
    |> result.map_error(ConfigErr),
  )
  io.println(ansi.green("Created") <> " kir.toml")
  Ok(Nil)
}

fn do_install(dir: String) -> Result(Nil, KirError) {
  use cfg <- result.try(
    config.read_kir_toml(dir)
    |> result.map_error(ConfigErr),
  )
  let existing_lock =
    lockfile.read(dir)
    |> result.map_error(fn(_) { Nil })
  io.println("Resolving dependencies...")
  use resolved <- result.try(
    resolver.resolve(cfg, existing_lock)
    |> result.map_error(ResolveErr),
  )
  let lock = lockfile.from_packages(resolved)
  use _ <- result.try(
    lockfile.write(lock, dir)
    |> result.map_error(LockErr),
  )
  io.println(
    ansi.green("Resolved")
    <> " "
    <> int.to_string(list.length(resolved))
    <> " packages, wrote kir.lock",
  )
  Ok(Nil)
}

fn do_add(
  dir: String,
  name: String,
  is_npm: Bool,
  is_dev: Bool,
) -> Result(Nil, KirError) {
  use cfg <- result.try(
    config.read_kir_toml(dir)
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
    config.write_kir_toml(updated, dir)
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
  Ok(Nil)
}

fn do_tree(dir: String) -> Result(Nil, KirError) {
  use cfg <- result.try(
    config.read_kir_toml(dir)
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
    config.read_kir_toml(dir)
    |> result.map_error(ConfigErr),
  )
  use paths <- result.try(
    export.export(cfg, dir)
    |> result.map_error(ExportErr),
  )
  list.each(paths, fn(p) { io.println("Wrote " <> p) })
  Ok(Nil)
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
