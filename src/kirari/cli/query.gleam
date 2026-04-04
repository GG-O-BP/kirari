//// CLI 조회 커맨드 — outdated, why, diff, ls, doctor, store verify

import gleam/dict
import gleam/int
import gleam/io
import gleam/list
import gleam/option
import gleam/order
import gleam/result
import gleam/string
import kirari/cli/error.{type KirError, ConfigErr, LockErr, ResolveErr}
import kirari/cli/output
import kirari/config
import kirari/installer
import kirari/license
import kirari/lockfile
import kirari/platform
import kirari/resolver
import kirari/semver
import kirari/store
import kirari/types.{Hex, Npm}
import simplifile

// ---------------------------------------------------------------------------
// outdated
// ---------------------------------------------------------------------------

pub fn do_outdated(dir: String) -> Result(Nil, KirError) {
  use cfg <- result.try(
    config.read_config(dir)
    |> result.map_error(ConfigErr),
  )
  use lock <- result.try(
    lockfile.read(dir)
    |> result.map_error(LockErr),
  )
  let all_deps =
    list.flatten([
      cfg.hex_deps,
      cfg.hex_dev_deps,
      cfg.npm_deps,
      cfg.npm_dev_deps,
    ])
  let direct_names = list.map(all_deps, fn(d) { #(d.name, d.registry) })
  let outdated =
    list.filter_map(direct_names, fn(pair) {
      let #(name, registry) = pair
      case lockfile.find_package(lock, name, registry) {
        option.Some(pkg) -> {
          let latest = resolver.get_latest_version(name, registry)
          case latest {
            Ok(latest_ver) ->
              case
                semver.parse_version(pkg.version),
                semver.parse_version(latest_ver)
              {
                Ok(current), Ok(latest_parsed) ->
                  case semver.compare(latest_parsed, current) {
                    order.Gt ->
                      Ok(#(
                        name,
                        pkg.version,
                        latest_ver,
                        types.registry_to_string(registry),
                      ))
                    _ -> Error(Nil)
                  }
                _, _ -> Error(Nil)
              }
            Error(_) -> Error(Nil)
          }
        }
        option.None -> Error(Nil)
      }
    })
  case outdated {
    [] -> {
      io.println(output.color_green("All dependencies are up to date"))
      Ok(Nil)
    }
    _ -> {
      io.println(
        output.pad_right("Package", 24)
        <> output.pad_right("Current", 12)
        <> output.pad_right("Latest", 12)
        <> "Registry",
      )
      list.each(outdated, fn(entry) {
        let #(name, current, latest, registry) = entry
        io.println(
          output.pad_right(name, 24)
          <> output.pad_right(current, 12)
          <> output.pad_right(latest, 12)
          <> registry,
        )
      })
      Ok(Nil)
    }
  }
}

// ---------------------------------------------------------------------------
// why
// ---------------------------------------------------------------------------

pub fn do_why(dir: String, pkg_name: String) -> Result(Nil, KirError) {
  use cfg <- result.try(
    config.read_config(dir)
    |> result.map_error(ConfigErr),
  )
  use lock <- result.try(
    lockfile.read(dir)
    |> result.map_error(LockErr),
  )
  case list.find(lock.packages, fn(p) { p.name == pkg_name }) {
    Error(_) -> {
      io.println(pkg_name <> " is not installed")
      Ok(Nil)
    }
    Ok(pkg) -> {
      io.println(
        pkg.name
        <> "@"
        <> pkg.version
        <> " ("
        <> types.registry_to_string(pkg.registry)
        <> ")",
      )
      let all_deps =
        list.flatten([
          cfg.hex_deps,
          cfg.hex_dev_deps,
          cfg.npm_deps,
          cfg.npm_dev_deps,
        ])
      let is_direct =
        list.any(all_deps, fn(d) {
          d.name == pkg_name && d.registry == pkg.registry
        })
      case is_direct {
        True -> {
          let section = case pkg.registry {
            Hex -> "[dependencies]"
            Npm -> "[npm-dependencies]"
          }
          io.println("  direct dependency in " <> section)
        }
        False -> {
          let version_infos = case resolver.resolve_full(cfg, Ok(lock)) {
            Ok(resolve_result) -> resolve_result.version_infos
            Error(_) -> dict.new()
          }
          let dependents =
            resolver.find_dependents(pkg_name, version_infos, lock)
          case dependents {
            [] -> io.println("  (dependency chain unknown)")
            _ ->
              list.each(dependents, fn(dep_name) {
                io.println("  required by " <> dep_name)
              })
          }
        }
      }
      Ok(Nil)
    }
  }
}

// ---------------------------------------------------------------------------
// diff
// ---------------------------------------------------------------------------

pub fn do_diff(dir: String) -> Result(Nil, KirError) {
  use cfg <- result.try(config.read_config(dir) |> result.map_error(ConfigErr))
  use lock <- result.try(lockfile.read(dir) |> result.map_error(LockErr))
  use resolve_result <- result.try(
    resolver.resolve_full(cfg, Error(Nil))
    |> result.map_error(ResolveErr),
  )
  let entries = lockfile.diff(lock, resolve_result.packages)
  case entries {
    [] -> io.println("No changes")
    _ ->
      list.each(entries, fn(entry) {
        case entry {
          lockfile.Added(name, version, registry) ->
            io.println(
              output.color_green("+ ")
              <> name
              <> " v"
              <> version
              <> " ("
              <> types.registry_to_string(registry)
              <> ")",
            )
          lockfile.Removed(name, version, registry) ->
            io.println(
              output.color_red("- ")
              <> name
              <> " v"
              <> version
              <> " ("
              <> types.registry_to_string(registry)
              <> ")",
            )
          lockfile.Changed(name, old_version, new_version, registry) ->
            io.println(
              output.color_yellow("~ ")
              <> name
              <> " v"
              <> old_version
              <> " → v"
              <> new_version
              <> " ("
              <> types.registry_to_string(registry)
              <> ")",
            )
        }
      })
  }
  Ok(Nil)
}

// ---------------------------------------------------------------------------
// ls
// ---------------------------------------------------------------------------

pub fn do_ls(dir: String) -> Result(Nil, KirError) {
  use lock <- result.try(lockfile.read(dir) |> result.map_error(LockErr))
  let sorted = list.sort(lock.packages, types.compare_packages)
  list.each(sorted, fn(p) {
    let path = installer.install_path(p, dir)
    let status = case simplifile.is_directory(path) {
      Ok(True) -> "  ✓ "
      _ -> "  ✗ "
    }
    io.println(
      status
      <> output.pad_right(p.name, 28)
      <> output.pad_right("v" <> p.version, 12)
      <> "("
      <> types.registry_to_string(p.registry)
      <> ")  "
      <> path,
    )
  })
  Ok(Nil)
}

// ---------------------------------------------------------------------------
// store verify
// ---------------------------------------------------------------------------

pub fn do_store_verify(dir: String) -> Result(Nil, KirError) {
  use lock <- result.try(lockfile.read(dir) |> result.map_error(LockErr))
  let results =
    list.map(lock.packages, fn(p) {
      let cached = case store.has_package(p.sha256, p.registry) {
        Ok(True) -> True
        _ -> False
      }
      #(p, cached)
    })
  let ok_count = list.count(results, fn(r) { r.1 })
  let missing = list.filter(results, fn(r) { !r.1 })
  list.each(results, fn(r) {
    let #(p, cached) = r
    let status = case cached {
      True -> "  ✓ "
      False -> "  ✗ "
    }
    io.println(
      status
      <> p.name
      <> "@"
      <> p.version
      <> " ("
      <> types.registry_to_string(p.registry)
      <> ")",
    )
  })
  io.println("")
  case missing {
    [] ->
      io.println(
        output.color_green("All")
        <> " "
        <> int.to_string(ok_count)
        <> " packages verified in store",
      )
    _ ->
      io.println(
        output.color_red(int.to_string(list.length(missing)))
        <> " packages missing from store. Run 'kir install' to restore.",
      )
  }
  Ok(Nil)
}

// ---------------------------------------------------------------------------
// doctor
// ---------------------------------------------------------------------------

pub fn do_doctor(dir: String) -> Nil {
  let version = platform.app_version() |> result.unwrap("unknown")
  io.println("kirari " <> version)
  case
    platform.run_command(
      "erl -eval \"io:format(\\\"~s\\\", [erlang:system_info(otp_release)]),halt().\" -noshell",
    )
  {
    Ok(otp) -> io.println("Erlang/OTP " <> string.trim(otp))
    Error(_) -> io.println("Erlang/OTP not found")
  }
  case platform.run_command("gleam --version") {
    Ok(gleam_ver) -> io.println(string.trim(gleam_ver))
    Error(_) -> io.println("Gleam not found")
  }
  case platform.store_base_path() {
    Ok(base) -> {
      let hex_count = store.count_entries(Hex)
      let npm_count = store.count_entries(Npm)
      io.println(
        "Store: "
        <> base
        <> " (hex: "
        <> int.to_string(hex_count)
        <> ", npm: "
        <> int.to_string(npm_count)
        <> ")",
      )
    }
    Error(_) -> io.println("Store: not found")
  }
  case simplifile.is_file(dir <> "/gleam.toml") {
    Ok(True) -> io.println("Config: gleam.toml ✓")
    _ -> io.println("Config: gleam.toml ✗")
  }
  case lockfile.read(dir) {
    Ok(lock) ->
      io.println(
        "Lock: kir.lock ✓ ("
        <> int.to_string(list.length(lock.packages))
        <> " packages)",
      )
    Error(_) -> io.println("Lock: kir.lock ✗")
  }
}

// ---------------------------------------------------------------------------
// license
// ---------------------------------------------------------------------------

pub fn do_license(dir: String) -> Result(Nil, KirError) {
  use cfg <- result.try(config.read_config(dir) |> result.map_error(ConfigErr))
  use lock <- result.try(lockfile.read(dir) |> result.map_error(LockErr))
  let packages =
    list.map(lock.packages, fn(p) {
      license.PackageLicense(
        name: p.name,
        version: p.version,
        registry: types.registry_to_string(p.registry),
        license_expression: p.license,
      )
    })
  // 라이선스별 그룹 출력
  let groups = license.group_by_license(packages)
  io.println("Dependency Licenses:")
  io.println("")
  list.each(groups, fn(group) {
    let #(lic, pkgs) = group
    let label = case lic {
      "" -> "(unknown)"
      l -> l
    }
    io.println("  " <> output.color_green(label))
    list.each(pkgs, fn(p) {
      io.println(
        "    " <> p.name <> "@" <> p.version <> " (" <> p.registry <> ")",
      )
    })
  })
  // 정책 검사
  let violations = license.check(packages, cfg.security.license_policy)
  io.println("")
  case violations {
    [] -> {
      io.println(
        output.color_green("All")
        <> " "
        <> int.to_string(list.length(packages))
        <> " packages comply with license policy",
      )
      Ok(Nil)
    }
    _ -> {
      io.println(output.color_red("License violations found:"))
      list.each(violations, fn(v) {
        case v {
          license.DeniedLicense(name, ver, reg, lic, _) ->
            io.println(
              "  "
              <> output.color_red("DENIED")
              <> " "
              <> name
              <> "@"
              <> ver
              <> " ("
              <> reg
              <> ") — "
              <> lic,
            )
          license.NotAllowed(name, ver, reg, lic, _) ->
            io.println(
              "  "
              <> output.color_red("NOT ALLOWED")
              <> " "
              <> name
              <> "@"
              <> ver
              <> " ("
              <> reg
              <> ") — "
              <> lic,
            )
          license.MissingLicense(name, ver, reg) ->
            io.println(
              "  "
              <> output.color_yellow("MISSING")
              <> " "
              <> name
              <> "@"
              <> ver
              <> " ("
              <> reg
              <> ")",
            )
          license.UnparsableLicense(name, ver, reg, raw, _) ->
            io.println(
              "  "
              <> output.color_yellow("UNPARSABLE")
              <> " "
              <> name
              <> "@"
              <> ver
              <> " ("
              <> reg
              <> ") — "
              <> raw,
            )
        }
      })
      Ok(Nil)
    }
  }
}
