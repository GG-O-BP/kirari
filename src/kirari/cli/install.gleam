//// CLI 워크플로우 커맨드 — init, install, update, add, remove, clean 등

import gleam/dict
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import kirari/cli/engines
import kirari/cli/error.{
  type KirError, ConfigErr, EnginesErr, ExportErr, LockErr, PipelineErr,
  ResolveErr, UserError,
}
import kirari/cli/log
import kirari/cli/output
import kirari/cli/progress
import kirari/config
import kirari/export
import kirari/ffi as ffi_detect
import kirari/installer
import kirari/lockfile
import kirari/migrate
import kirari/pipeline
import kirari/platform
import kirari/registry/cache
import kirari/registry/npm as npm_registry
import kirari/resolver
import kirari/resolver/fingerprint
import kirari/sbom
import kirari/semver
import kirari/store
import kirari/store/gc
import kirari/store/manifest
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
  verify: Bool,
  offline: Bool,
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
  // engines 제약 검증
  use _ <- result.try(validate_engines(cfg.engines))
  warn_duplicate_deps(cfg)
  output.print_overrides(cfg.overrides)
  let existing_lock =
    lockfile.read(dir)
    |> result.map_error(fn(_) { Nil })
  // frozen 모드는 항상 전체 해결
  case frozen {
    True -> {
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
      let decision = resolver.resolution_needed(cfg, existing_lock)
      log.verbose("Resolution decision: " <> resolution_decision_name(decision))
      case decision {
        resolver.SkipAll -> {
          let assert Ok(lock) = existing_lock
          case all_packages_installed(lock, dir) {
            True -> {
              io.println(
                output.color_green("Up to date")
                <> " — nothing changed ("
                <> int.to_string(list.length(lock.packages))
                <> " packages)",
              )
              let _ = export.write_build_metadata(cfg, lock, dir)
              Ok(Nil)
            }
            False -> {
              io.println("Installing from lock (no resolution needed)...")
              do_install_from_lock_verbose(cfg, lock, dir)
            }
          }
        }
        resolver.InstallOnly -> {
          let assert Ok(lock) = existing_lock
          io.println("Installing from lock (no resolution needed)...")
          do_install_from_lock_verbose(cfg, lock, dir)
        }
        resolver.FullResolve -> {
          let mode = case offline {
            True -> "Resolving dependencies (offline)..."
            False -> "Resolving dependencies..."
          }
          io.println(mode)
          use resolve_result <- result.try(case offline {
            True ->
              resolver.resolve_full_offline(cfg, existing_lock)
              |> result.map_error(ResolveErr)
            False ->
              resolver.resolve_full(cfg, existing_lock)
              |> result.map_error(ResolveErr)
          })
          io.println(
            output.color_green("Resolved")
            <> " "
            <> int.to_string(list.length(resolve_result.packages))
            <> " packages",
          )
          let prog = make_progress(list.length(resolve_result.packages))
          use pipeline_result <- result.try(
            pipeline.run(resolve_result, dir, cfg.security, prog, offline)
            |> result.map_error(PipelineErr),
          )
          progress.stop(prog)
          output.print_pipeline_warnings(pipeline_result.warnings)
          let installed = pipeline_result.packages
          let fp = fingerprint.compute(cfg)
          log.debug("Config fingerprint: " <> fp)
          let lock = lockfile.from_packages_with_fingerprint(installed, fp)
          use _ <- result.try(
            lockfile.write(lock, dir)
            |> result.map_error(LockErr),
          )
          log.verbose(
            "Wrote kir.lock (version "
            <> int.to_string(lock.version)
            <> ", "
            <> int.to_string(list.length(installed))
            <> " packages)",
          )
          io.println(
            output.color_green("Installed")
            <> " "
            <> int.to_string(list.length(installed))
            <> " packages, wrote kir.lock",
          )
          let _ = export.write_build_metadata(cfg, lock, dir)
          warn_undeclared_npm(dir, cfg)
          case verify {
            True ->
              print_verify_results(installer.verify_installed(installed, dir))
            False -> Nil
          }
          Ok(Nil)
        }
      }
    }
  }
}

/// install과 동일하되 출력 없이 수행 (kir build/run/test/check/dev 용)
/// incremental resolution: config가 변경되지 않았으면 resolution 건��뜀
pub fn do_install_quiet(dir: String) -> Result(Nil, KirError) {
  use cfg <- result.try(
    config.read_config(dir)
    |> result.map_error(ConfigErr),
  )
  let existing_lock =
    lockfile.read(dir)
    |> result.map_error(fn(_) { Nil })
  case resolver.resolution_needed(cfg, existing_lock) {
    resolver.SkipAll -> {
      // fingerprint 일치 — 패키지가 모두 store에 있는지 확인
      let assert Ok(lock) = existing_lock
      case all_packages_installed(lock, dir) {
        True -> {
          let _ = export.write_build_metadata(cfg, lock, dir)
          Ok(Nil)
        }
        False -> do_install_from_lock(cfg, lock, dir)
      }
    }
    resolver.InstallOnly -> {
      let assert Ok(lock) = existing_lock
      do_install_from_lock(cfg, lock, dir)
    }
    resolver.FullResolve -> {
      use resolve_result <- result.try(
        resolver.resolve_full(cfg, existing_lock)
        |> result.map_error(ResolveErr),
      )
      use pipeline_result <- result.try(
        pipeline.run(
          resolve_result,
          dir,
          cfg.security,
          progress.Inactive,
          False,
        )
        |> result.map_error(PipelineErr),
      )
      let fp = fingerprint.compute(cfg)
      let lock =
        lockfile.from_packages_with_fingerprint(pipeline_result.packages, fp)
      use _ <- result.try(
        lockfile.write(lock, dir)
        |> result.map_error(LockErr),
      )
      let _ = export.write_build_metadata(cfg, lock, dir)
      Ok(Nil)
    }
  }
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
  output.print_overrides(cfg.overrides)
  io.println("Updating all dependencies...")
  use resolve_result <- result.try(
    resolver.resolve_full_fresh(cfg, Error(Nil))
    |> result.map_error(ResolveErr),
  )
  io.println(
    output.color_green("Resolved")
    <> " "
    <> int.to_string(list.length(resolve_result.packages))
    <> " packages",
  )
  let prog = make_progress(list.length(resolve_result.packages))
  use pipeline_result <- result.try(
    pipeline.run(resolve_result, dir, cfg.security, prog, False)
    |> result.map_error(PipelineErr),
  )
  progress.stop(prog)
  output.print_pipeline_warnings(pipeline_result.warnings)
  let installed = pipeline_result.packages
  let fp = fingerprint.compute(cfg)
  let lock = lockfile.from_packages_with_fingerprint(installed, fp)
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
  output.print_overrides(cfg.overrides)
  io.println("Updating " <> string.join(packages, ", ") <> "...")
  let filtered_lock = lockfile.remove_packages(lock, packages)
  use resolve_result <- result.try(
    resolver.resolve_full_fresh(cfg, Ok(filtered_lock))
    |> result.map_error(ResolveErr),
  )
  io.println(
    output.color_green("Resolved")
    <> " "
    <> int.to_string(list.length(resolve_result.packages))
    <> " packages",
  )
  let prog = make_progress(list.length(resolve_result.packages))
  use pipeline_result <- result.try(
    pipeline.run(resolve_result, dir, cfg.security, prog, False)
    |> result.map_error(PipelineErr),
  )
  progress.stop(prog)
  output.print_pipeline_warnings(pipeline_result.warnings)
  let installed = pipeline_result.packages
  let fp = fingerprint.compute(cfg)
  let new_lock = lockfile.from_packages_with_fingerprint(installed, fp)
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
  // npm dist-tag 해결: "latest" → "^5.0.0" 등
  use version_constraint <- result.try(resolve_add_constraint(
    name,
    version_constraint,
    registry,
  ))
  let dep =
    Dependency(
      name: name,
      version_constraint: version_constraint,
      registry: registry,
      dev: is_dev,
      optional: False,
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
  do_install(dir, False, "", False, False)
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
  do_install(dir, False, "", False, False)
}

// ---------------------------------------------------------------------------
// tree / export / deps / clean / publish
// ---------------------------------------------------------------------------

pub fn do_tree(dir: String, json_output: Bool) -> Result(Nil, KirError) {
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
  case json_output {
    True -> io.println(tree.to_json(roots))
    False -> {
      let tree_output = tree.render(roots)
      case tree_output {
        "" -> io.println("(no dependencies)")
        _ -> io.println(tree_output)
      }
    }
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

pub fn do_export_sbom(
  dir: String,
  format: sbom.SbomFormat,
  output_path: String,
) -> Result(Nil, KirError) {
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
  use json_str <- result.try(
    sbom.generate(cfg, lock, version_infos, format)
    |> result.map_error(fn(e) {
      case e {
        sbom.MissingLockfile -> UserError("lockfile not found")
        sbom.MissingConfig -> UserError("config not found")
        sbom.SerializationError(d) -> UserError("sbom error: " <> d)
      }
    }),
  )
  case output_path {
    "" -> {
      io.println(json_str)
      Ok(Nil)
    }
    path ->
      case simplifile.write(path, json_str) {
        Ok(_) -> {
          io.println("Wrote " <> path)
          Ok(Nil)
        }
        Error(e) -> Error(UserError(simplifile.describe_error(e)))
      }
  }
}

pub fn do_deps_list(dir: String, json_output: Bool) -> Result(Nil, KirError) {
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
  case json_output {
    True -> {
      io.println(
        json.array(all_deps, fn(d) {
          json.object([
            #("name", json.string(d.name)),
            #("constraint", json.string(d.version_constraint)),
            #("registry", json.string(types.registry_to_string(d.registry))),
            #("dev", json.bool(d.dev)),
          ])
        })
        |> json.to_string,
      )
      Ok(Nil)
    }
    False -> {
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
  }
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
  let prog = make_progress(list.length(resolve_result.packages))
  use pipeline_result <- result.try(
    pipeline.run(resolve_result, dir, cfg.security, prog, False)
    |> result.map_error(PipelineErr),
  )
  progress.stop(prog)
  output.print_pipeline_warnings(pipeline_result.warnings)
  let fp = fingerprint.compute(cfg)
  let lock =
    lockfile.from_packages_with_fingerprint(pipeline_result.packages, fp)
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
  let _ = cache.invalidate_all()
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
// incremental resolution 헬퍼
// ---------------------------------------------------------------------------

/// lock에서 직접 설치 + 상태 출력 (대화형 install)
fn do_install_from_lock_verbose(
  cfg: types.KirConfig,
  lock: types.KirLock,
  dir: String,
) -> Result(Nil, KirError) {
  let resolve_result = resolver.resolve_result_from_lock(lock)
  let prog = make_progress(list.length(lock.packages))
  use pipeline_result <- result.try(
    pipeline.run(resolve_result, dir, cfg.security, prog, False)
    |> result.map_error(PipelineErr),
  )
  progress.stop(prog)
  output.print_pipeline_warnings(pipeline_result.warnings)
  let fp = fingerprint.compute(cfg)
  let new_lock =
    lockfile.from_packages_with_fingerprint(pipeline_result.packages, fp)
  use _ <- result.try(
    lockfile.write(new_lock, dir)
    |> result.map_error(LockErr),
  )
  io.println(
    output.color_green("Installed")
    <> " "
    <> int.to_string(list.length(pipeline_result.packages))
    <> " packages from lock",
  )
  let _ = export.write_build_metadata(cfg, new_lock, dir)
  warn_undeclared_npm(dir, cfg)
  Ok(Nil)
}

/// lock에서 직접 설치 (resolution 건너뜀, 무출력)
fn do_install_from_lock(
  cfg: types.KirConfig,
  lock: types.KirLock,
  dir: String,
) -> Result(Nil, KirError) {
  let resolve_result = resolver.resolve_result_from_lock(lock)
  use pipeline_result <- result.try(
    pipeline.run(resolve_result, dir, cfg.security, progress.Inactive, False)
    |> result.map_error(PipelineErr),
  )
  let fp = fingerprint.compute(cfg)
  let new_lock =
    lockfile.from_packages_with_fingerprint(pipeline_result.packages, fp)
  use _ <- result.try(
    lockfile.write(new_lock, dir)
    |> result.map_error(LockErr),
  )
  let _ = export.write_build_metadata(cfg, new_lock, dir)
  Ok(Nil)
}

/// 모든 lock 패키지가 store에 있고 설치 디렉토리가 존재하는지 확인
fn all_packages_installed(lock: types.KirLock, dir: String) -> Bool {
  let has_packages = !list.is_empty(lock.packages)
  let all_in_store =
    list.all(lock.packages, fn(p) {
      case store.has_package(p.sha256, p.registry) {
        Ok(True) -> True
        _ -> False
      }
    })
  // 설치 디렉토리 존재 확인 (build/packages 또는 node_modules)
  let hex_dir_ok = case list.any(lock.packages, fn(p) { p.registry == Hex }) {
    True ->
      case simplifile.is_directory(dir <> "/build/packages") {
        Ok(True) -> True
        _ -> False
      }
    False -> True
  }
  let npm_dir_ok = case list.any(lock.packages, fn(p) { p.registry == Npm }) {
    True ->
      case simplifile.is_directory(dir <> "/node_modules") {
        Ok(True) -> True
        _ -> False
      }
    False -> True
  }
  has_packages && all_in_store && hex_dir_ok && npm_dir_ok
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

/// npm dist-tag면 레지스트리에서 해결, 아니면 그대로 반환
fn resolve_add_constraint(
  name: String,
  constraint: String,
  registry: types.Registry,
) -> Result(String, KirError) {
  case registry, semver.is_dist_tag(constraint) {
    Npm, True -> {
      io.println(
        "Resolving dist-tag \"" <> constraint <> "\" for " <> name <> "...",
      )
      case npm_registry.get_versions_with_tags(name) {
        Ok(result) ->
          case dict.get(result.dist_tags, constraint) {
            Ok(version) -> {
              let resolved = "^" <> version
              io.println(
                "  "
                <> constraint
                <> " -> "
                <> version
                <> " (using "
                <> resolved
                <> ")",
              )
              Ok(resolved)
            }
            Error(_) ->
              Error(UserError(
                detail: "unknown npm dist-tag \""
                <> constraint
                <> "\" for "
                <> name
                <> ". Available tags: "
                <> string.join(dict.keys(result.dist_tags), ", "),
              ))
          }
        Error(e) ->
          Error(UserError(
            detail: "failed to fetch dist-tags for "
            <> name
            <> ": "
            <> string.inspect(e),
          ))
      }
    }
    _, _ -> Ok(constraint)
  }
}

/// 설치 후 무결성 검증 결과 출력
fn print_verify_results(
  results: List(#(types.ResolvedPackage, manifest.VerifyResult)),
) -> Nil {
  io.println("")
  io.println("Verifying installed packages...")
  let ok_count =
    list.count(results, fn(r) {
      case r.1 {
        manifest.VerifyOk(_) -> True
        _ -> False
      }
    })
  let fail_count = list.length(results) - ok_count
  list.each(results, fn(r) {
    let #(p, result) = r
    let label = p.name <> "@" <> p.version
    case result {
      manifest.VerifyOk(n) ->
        io.println(
          output.color_green("  ✓ ")
          <> label
          <> output.color_dim(" — " <> int.to_string(n) <> " files ok"),
        )
      manifest.VerifyCorrupted(mismatched, missing, extra) -> {
        io.println(output.color_red("  ✗ ") <> label <> " — integrity mismatch")
        list.each(mismatched, fn(f) {
          io.println(output.color_red("      corrupted: ") <> f)
        })
        list.each(missing, fn(f) {
          io.println(output.color_red("      missing:   ") <> f)
        })
        list.each(extra, fn(f) {
          io.println(output.color_yellow("      extra:     ") <> f)
        })
      }
      manifest.VerifyNoManifest ->
        io.println(
          output.color_yellow("  ⚠ ")
          <> label
          <> output.color_dim(" — no manifest"),
        )
    }
  })
  case fail_count {
    0 ->
      io.println(
        output.color_green("All")
        <> " "
        <> int.to_string(ok_count)
        <> " installed packages verified",
      )
    _ ->
      io.println(
        output.color_red(int.to_string(fail_count))
        <> " packages failed verification",
      )
  }
}

fn make_progress(total: Int) -> progress.ProgressHandle {
  let no_color = case platform.get_env("NO_COLOR") {
    Ok(_) -> True
    Error(_) -> False
  }
  progress.start(progress.ProgressConfig(
    total_packages: total,
    quiet: False,
    no_color: no_color,
  ))
}

fn resolution_decision_name(d: resolver.ResolutionDecision) -> String {
  case d {
    resolver.SkipAll -> "SkipAll (fingerprint match, packages installed)"
    resolver.InstallOnly -> "InstallOnly (fingerprint match, install needed)"
    resolver.FullResolve -> "FullResolve (config changed or no lock)"
  }
}

fn validate_engines(
  engines_config: types.EnginesConfig,
) -> Result(Nil, KirError) {
  case engines.check(engines_config) {
    engines.AllSatisfied -> {
      log.verbose("Engine constraints satisfied")
      Ok(Nil)
    }
    engines.ConstraintViolation(violations) -> Error(EnginesErr(violations))
  }
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
