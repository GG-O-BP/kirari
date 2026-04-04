//// CLI 워크플로우 커맨드 — init, install, update, add, remove, clean 등

import gleam/dict
import gleam/int
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import kirari/cli/error.{
  type KirError, ConfigErr, ExportErr, LockErr, PipelineErr, ResolveErr,
  UserError,
}
import kirari/cli/output
import kirari/config
import kirari/export
import kirari/ffi as ffi_detect
import kirari/installer
import kirari/lockfile
import kirari/migrate
import kirari/pipeline
import kirari/resolver
import kirari/semver
import kirari/store
import kirari/store/gc
import kirari/tree
import kirari/types.{
  type Dependency, type KirConfig, Dependency, Hex, KirConfig, Npm,
}
import simplifile

// ---------------------------------------------------------------------------
// init
// ---------------------------------------------------------------------------

pub fn do_init(dir: String) -> Result(Nil, KirError) {
  io.println("Initializing kirari...")
  use cfg <- result.try(
    config.read_config(dir)
    |> result.map_error(ConfigErr),
  )
  let npm_deps = case migrate.read_package_json(dir) {
    Ok(deps) -> deps
    Error(_) -> []
  }
  let merged = merge_npm_deps(cfg, npm_deps)
  use _ <- result.try(
    config.write_config(merged, dir)
    |> result.map_error(ConfigErr),
  )
  io.println(
    output.color_green("Initialized") <> " gleam.toml with kirari sections",
  )
  Ok(Nil)
}

// ---------------------------------------------------------------------------
// install
// ---------------------------------------------------------------------------

pub fn do_install(
  dir: String,
  frozen: Bool,
  exclude_newer: String,
) -> Result(Nil, KirError) {
  use cfg <- result.try(
    config.read_config(dir)
    |> result.map_error(ConfigErr),
  )
  let cfg = case exclude_newer {
    "" -> cfg
    ts ->
      types.KirConfig(
        ..cfg,
        security: types.SecurityConfig(..cfg.security, exclude_newer: Ok(ts)),
      )
  }
  warn_duplicate_deps(cfg)
  let existing_lock =
    lockfile.read(dir)
    |> result.map_error(fn(_) { Nil })
  io.println("Resolving dependencies...")
  use resolve_result <- result.try(
    resolver.resolve_full(cfg, existing_lock)
    |> result.map_error(ResolveErr),
  )
  io.println(
    output.color_green("Resolved")
    <> " "
    <> int.to_string(list.length(resolve_result.packages))
    <> " packages",
  )
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
      io.println(
        output.color_green("Verified") <> " lockfile matches (--frozen)",
      )
      Ok(Nil)
    }
    False -> {
      io.println("Downloading and installing...")
      use pipeline_result <- result.try(
        pipeline.run(resolve_result, dir, cfg.security)
        |> result.map_error(PipelineErr),
      )
      output.print_pipeline_warnings(pipeline_result.warnings)
      let installed = pipeline_result.packages
      let lock = lockfile.from_packages(installed)
      use _ <- result.try(
        lockfile.write(lock, dir)
        |> result.map_error(LockErr),
      )
      io.println(
        output.color_green("Installed")
        <> " "
        <> int.to_string(list.length(installed))
        <> " packages, wrote kir.lock",
      )
      let _ = export.write_build_metadata(cfg, lock, dir)
      warn_undeclared_npm(dir, cfg)
      Ok(Nil)
    }
  }
}

/// install과 동일하되 출력 없이 수행 (kir build/run/test/check/dev 용)
pub fn do_install_quiet(dir: String) -> Result(Nil, KirError) {
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
  use pipeline_result <- result.try(
    pipeline.run(resolve_result, dir, cfg.security)
    |> result.map_error(PipelineErr),
  )
  let lock = lockfile.from_packages(pipeline_result.packages)
  use _ <- result.try(
    lockfile.write(lock, dir)
    |> result.map_error(LockErr),
  )
  let _ = export.write_build_metadata(cfg, lock, dir)
  Ok(Nil)
}

pub fn do_install_offline(dir: String) -> Result(Nil, KirError) {
  use cfg <- result.try(
    config.read_config(dir)
    |> result.map_error(ConfigErr),
  )
  use lock <- result.try(
    lockfile.read(dir)
    |> result.map_error(LockErr),
  )
  let missing =
    list.filter(lock.packages, fn(p) {
      case store.has_package(p.sha256, p.registry) {
        Ok(True) -> False
        _ -> True
      }
    })
  case missing {
    [] -> {
      io.println(
        "Installing "
        <> int.to_string(list.length(lock.packages))
        <> " packages from cache (offline)...",
      )
      use install_warnings <- result.try(
        installer.install_all(lock.packages, dir)
        |> result.map_error(fn(_) {
          UserError(detail: "offline install failed")
        }),
      )
      output.print_installer_warnings(install_warnings)
      use _ <- result.try(
        installer.clean_stale(lock.packages, dir)
        |> result.map_error(fn(_) { UserError(detail: "offline clean failed") }),
      )
      let _ = export.write_build_metadata(cfg, lock, dir)
      io.println(
        output.color_green("Installed")
        <> " "
        <> int.to_string(list.length(lock.packages))
        <> " packages (offline)",
      )
      Ok(Nil)
    }
    _ -> {
      io.println(
        output.color_bold_red("error:")
        <> " the following packages are not cached:",
      )
      list.each(missing, fn(p) {
        io.println(
          "  "
          <> p.name
          <> "@"
          <> p.version
          <> " ("
          <> types.registry_to_string(p.registry)
          <> ")",
        )
      })
      io.println("Run 'kir install' first to download them.")
      Error(UserError(detail: "packages not cached for offline mode"))
    }
  }
}

// ---------------------------------------------------------------------------
// update
// ---------------------------------------------------------------------------

pub fn do_update(dir: String) -> Result(Nil, KirError) {
  use cfg <- result.try(
    config.read_config(dir)
    |> result.map_error(ConfigErr),
  )
  io.println("Updating all dependencies...")
  use resolve_result <- result.try(
    resolver.resolve_full(cfg, Error(Nil))
    |> result.map_error(ResolveErr),
  )
  io.println(
    output.color_green("Resolved")
    <> " "
    <> int.to_string(list.length(resolve_result.packages))
    <> " packages",
  )
  io.println("Downloading and installing...")
  use pipeline_result <- result.try(
    pipeline.run(resolve_result, dir, cfg.security)
    |> result.map_error(PipelineErr),
  )
  output.print_pipeline_warnings(pipeline_result.warnings)
  let installed = pipeline_result.packages
  let lock = lockfile.from_packages(installed)
  use _ <- result.try(
    lockfile.write(lock, dir)
    |> result.map_error(LockErr),
  )
  io.println(
    output.color_green("Updated")
    <> " "
    <> int.to_string(list.length(installed))
    <> " packages, wrote kir.lock",
  )
  let _ = export.write_build_metadata(cfg, lock, dir)
  Ok(Nil)
}

pub fn do_update_selective(
  dir: String,
  packages: List(String),
) -> Result(Nil, KirError) {
  use cfg <- result.try(
    config.read_config(dir)
    |> result.map_error(ConfigErr),
  )
  use lock <- result.try(
    lockfile.read(dir)
    |> result.map_error(LockErr),
  )
  io.println("Updating " <> string.join(packages, ", ") <> "...")
  let filtered_lock = lockfile.remove_packages(lock, packages)
  use resolve_result <- result.try(
    resolver.resolve_full(cfg, Ok(filtered_lock))
    |> result.map_error(ResolveErr),
  )
  io.println(
    output.color_green("Resolved")
    <> " "
    <> int.to_string(list.length(resolve_result.packages))
    <> " packages",
  )
  io.println("Downloading and installing...")
  use pipeline_result <- result.try(
    pipeline.run(resolve_result, dir, cfg.security)
    |> result.map_error(PipelineErr),
  )
  output.print_pipeline_warnings(pipeline_result.warnings)
  let installed = pipeline_result.packages
  let new_lock = lockfile.from_packages(installed)
  use _ <- result.try(
    lockfile.write(new_lock, dir)
    |> result.map_error(LockErr),
  )
  io.println(
    output.color_green("Updated")
    <> " "
    <> string.join(packages, ", ")
    <> ", wrote kir.lock",
  )
  let _ = export.write_build_metadata(cfg, new_lock, dir)
  Ok(Nil)
}

// ---------------------------------------------------------------------------
// add / remove
// ---------------------------------------------------------------------------

/// pkg@version 형식 파싱 (scoped npm 패키지 @scope/pkg@ver 처리)
pub fn parse_add_arg(raw: String, is_npm: Bool) -> #(String, String) {
  let is_scoped_npm = is_npm || string.starts_with(raw, "@")
  let default_version = case is_scoped_npm {
    True -> "*"
    False -> ">= 0.0.0"
  }
  let #(name, ver) = case is_scoped_npm {
    True -> {
      let without_prefix = string.drop_start(raw, 1)
      case string.split(without_prefix, "@") {
        [scope_and_name] -> #("@" <> scope_and_name, default_version)
        [scope_and_name, ver] -> #("@" <> scope_and_name, ver)
        _ -> #(raw, default_version)
      }
    }
    False ->
      case string.split(raw, "@") {
        [n] -> #(n, default_version)
        [n, v] -> #(n, v)
        _ -> #(raw, default_version)
      }
  }
  case is_scoped_npm {
    True -> #(name, ver)
    False -> #(name, semver.normalize_hex_constraint(ver))
  }
}

pub fn do_add(
  dir: String,
  name: String,
  version_constraint: String,
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
      version_constraint: version_constraint,
      registry: registry,
      dev: is_dev,
    )
  let updated = config.add_dependency(cfg, dep)
  use _ <- result.try(
    config.write_config(updated, dir)
    |> result.map_error(ConfigErr),
  )
  io.println(
    output.color_green("Added")
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

pub fn do_remove(
  dir: String,
  name: String,
  is_npm: Bool,
) -> Result(Nil, KirError) {
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
    output.color_red("Removed")
    <> " "
    <> name
    <> " from ["
    <> types.registry_to_string(registry)
    <> "]",
  )
  do_install(dir, False, "")
}

// ---------------------------------------------------------------------------
// tree / export / deps / clean / publish
// ---------------------------------------------------------------------------

pub fn do_tree(dir: String) -> Result(Nil, KirError) {
  use cfg <- result.try(
    config.read_config(dir)
    |> result.map_error(ConfigErr),
  )
  use lock <- result.try(
    lockfile.read(dir)
    |> result.map_error(LockErr),
  )
  let version_infos = case resolver.resolve_full(cfg, Ok(lock)) {
    Ok(resolve_result) -> resolve_result.version_infos
    Error(_) -> dict.new()
  }
  let roots = tree.build(cfg, lock, version_infos)
  let tree_output = tree.render(roots)
  case tree_output {
    "" -> io.println("(no dependencies)")
    _ -> io.println(tree_output)
  }
  Ok(Nil)
}

pub fn do_export(dir: String) -> Result(Nil, KirError) {
  use cfg <- result.try(
    config.read_config(dir)
    |> result.map_error(ConfigErr),
  )
  let lock =
    lockfile.read(dir)
    |> result.map_error(fn(_) { Nil })
  let version_infos = case resolver.resolve_full(cfg, lock) {
    Ok(resolve_result) -> Ok(resolve_result.version_infos)
    Error(_) -> Error(Nil)
  }
  use paths <- result.try(
    export.export(cfg, lock, version_infos, dir)
    |> result.map_error(ExportErr),
  )
  list.each(paths, fn(p) { io.println("Wrote " <> p) })
  Ok(Nil)
}

pub fn do_deps_list(dir: String) -> Result(Nil, KirError) {
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
          <> output.color_dim(d.version_constraint)
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

pub fn do_deps_download(dir: String) -> Result(Nil, KirError) {
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
  use pipeline_result <- result.try(
    pipeline.run(resolve_result, dir, cfg.security)
    |> result.map_error(PipelineErr),
  )
  output.print_pipeline_warnings(pipeline_result.warnings)
  let lock = lockfile.from_packages(pipeline_result.packages)
  use _ <- result.try(
    lockfile.write(lock, dir)
    |> result.map_error(LockErr),
  )
  io.println(
    output.color_green("Downloaded")
    <> " "
    <> int.to_string(list.length(pipeline_result.packages))
    <> " packages",
  )
  Ok(Nil)
}

pub fn do_clean(dir: String, clean_store: Bool, keep_cache: Bool) -> Nil {
  case keep_cache {
    False -> {
      let _ = simplifile.delete(dir <> "/build/dev")
      let _ = simplifile.delete(dir <> "/build/packages")
      Nil
    }
    True -> {
      let _ = simplifile.delete(dir <> "/build/packages")
      Nil
    }
  }
  let _ = simplifile.delete(dir <> "/node_modules")
  io.println(output.color_green("Cleaned") <> " build artifacts")
  case clean_store {
    True ->
      case gc.gc_all() {
        Ok(#(hex_result, npm_result)) ->
          io.println(
            output.color_green("Store GC:")
            <> " removed "
            <> int.to_string(hex_result.removed_count)
            <> " hex, "
            <> int.to_string(npm_result.removed_count)
            <> " npm packages",
          )
        Error(_) -> io.println("Store GC failed")
      }
    False -> Nil
  }
}

pub fn do_publish(dir: String, replace: Bool, yes: Bool, dry_run: Bool) -> Nil {
  case do_export(dir) {
    Ok(_) -> Nil
    Error(e) -> output.print_error(e)
  }
  case dry_run {
    True ->
      io.println(
        output.color_green("Dry run:") <> " publish simulated, no upload",
      )
    False -> {
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
      output.run_gleam_cmd(cmd)
    }
  }
}

// ---------------------------------------------------------------------------
// 헬퍼
// ---------------------------------------------------------------------------

fn merge_npm_deps(cfg: KirConfig, npm_deps: List(Dependency)) -> KirConfig {
  let prod = list.filter(npm_deps, fn(d) { !d.dev })
  let dev = list.filter(npm_deps, fn(d) { d.dev })
  KirConfig(
    ..cfg,
    npm_deps: list.append(cfg.npm_deps, prod),
    npm_dev_deps: list.append(cfg.npm_dev_deps, dev),
  )
}

fn detect_registry(name: String) -> types.Registry {
  case string.starts_with(name, "@") {
    True -> Npm
    False -> Hex
  }
}

fn warn_duplicate_deps(cfg: KirConfig) -> Nil {
  case config.find_duplicate_deps(cfg) {
    [] -> Nil
    dups -> {
      io.println(
        output.color_yellow("Warning:")
        <> " duplicate declarations in deps and dev-deps:",
      )
      list.each(dups, fn(n) { io.println("  " <> n) })
    }
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
            output.color_yellow("Warning:")
            <> " undeclared npm imports detected:",
          )
          list.each(names, fn(n) { io.println("  " <> n) })
        }
      }
    }
    Error(_) -> Nil
  }
}
