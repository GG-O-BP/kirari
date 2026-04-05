//// 프로젝트 설치 — store에서 build/packages, node_modules로 링크/복사

import filepath
import gleam/list
import gleam/result
import gleam/string
import kirari/platform
import kirari/store
import kirari/store/manifest
import kirari/types.{type ResolvedPackage, Hex, Npm}
import simplifile

/// installer 에러 타입
pub type InstallerError {
  StoreErr(store.StoreError)
  IoError(detail: String)
  LinkError(detail: String)
  RollbackTriggered(detail: String)
  RollbackFailed(original_error: String, rollback_error: String)
}

/// installer 경고 타입
pub type Warning {
  PlatformMismatch(name: String, version: String, os: String, arch: String)
}

// ---------------------------------------------------------------------------
// 공개 API
// ---------------------------------------------------------------------------

/// 해결된 패키지를 프로젝트 디렉토리에 설치
pub fn install_all(
  packages: List(ResolvedPackage),
  project_dir: String,
) -> Result(List(Warning), InstallerError) {
  use _ <- result.try(ensure_dirs(project_dir))
  install_each(packages, project_dir, [])
}

/// 단일 패키지 설치
pub fn install_package(
  package: ResolvedPackage,
  project_dir: String,
) -> Result(List(Warning), InstallerError) {
  use source_path <- result.try(
    store.package_path(package.sha256, package.registry)
    |> result.map_error(StoreErr),
  )
  let warnings = check_platform_mismatch(package)
  let target = install_path(package, project_dir)
  // 기존 디렉토리 제거 후 복사
  let _ = simplifile.delete(target)
  use _ <- result.try(
    simplifile.create_directory_all(target)
    |> result.map_error(fn(e) { IoError(simplifile.describe_error(e)) }),
  )
  use _ <- result.try(case install_mode(package) {
    HardlinkMode -> hardlink_dir_contents(source_path, target)
    CopyMode -> copy_dir_contents(source_path, target)
  })
  Ok(warnings)
}

/// npm 패키지의 bin 심볼릭 링크 생성
pub fn link_bins(
  bin_entries: List(#(String, List(#(String, String)))),
  project_dir: String,
) -> Result(Nil, InstallerError) {
  let bin_dir = project_dir <> "/node_modules/.bin"
  // 기존 .bin 디렉토리 정리 후 재생성
  let _ = simplifile.delete(bin_dir)
  case bin_entries {
    [] -> Ok(Nil)
    _ -> {
      use _ <- result.try(
        simplifile.create_directory_all(bin_dir)
        |> result.map_error(fn(e) { IoError(simplifile.describe_error(e)) }),
      )
      create_bin_links(bin_entries, project_dir, bin_dir)
    }
  }
}

/// 더 이상 필요 없는 패키지 정리
pub fn clean_stale(
  packages: List(ResolvedPackage),
  project_dir: String,
) -> Result(Nil, InstallerError) {
  let hex_names =
    list.filter_map(packages, fn(p) {
      case p.registry {
        Hex -> Ok(p.name)
        Npm -> Error(Nil)
      }
    })
  let npm_names =
    list.filter_map(packages, fn(p) {
      case p.registry {
        Npm -> Ok(p.name)
        Hex -> Error(Nil)
      }
    })
  let _ = clean_dir(project_dir <> "/build/packages", hex_names)
  let _ = clean_dir(project_dir <> "/node_modules", npm_names)
  Ok(Nil)
}

/// 원자적 설치 — staging에 먼저 설치 후 성공 시 교체, 실패 시 롤백
pub fn install_atomic(
  packages: List(ResolvedPackage),
  bin_entries: List(#(String, List(#(String, String)))),
  project_dir: String,
) -> Result(List(Warning), InstallerError) {
  // project_dir 존재 보장
  use _ <- result.try(
    simplifile.create_directory_all(project_dir)
    |> result.map_error(fn(e) { IoError(simplifile.describe_error(e)) }),
  )
  // staging 디렉토리 생성 (같은 파일시스템에서 atomic rename 보장)
  use staging <- result.try(
    platform.make_temp_dir(project_dir)
    |> result.map_error(fn(e) { IoError(e) }),
  )
  let staging_hex = staging <> "/build/packages"
  let staging_npm = staging <> "/node_modules"
  use _ <- result.try(
    simplifile.create_directory_all(staging_hex)
    |> result.map_error(fn(e) { IoError(simplifile.describe_error(e)) }),
  )
  use _ <- result.try(
    simplifile.create_directory_all(staging_npm)
    |> result.map_error(fn(e) { IoError(simplifile.describe_error(e)) }),
  )
  // staging에 패키지 설치
  case install_each(packages, staging, []) {
    Ok(warnings) -> {
      // bin 링크 생성
      case link_bins(bin_entries, staging) {
        Ok(_) ->
          // 성공 → 원자적 교체
          swap_dirs(project_dir, staging)
          |> result.map(fn(_) { warnings })
        Error(e) -> {
          let _ = simplifile.delete(staging)
          Error(RollbackTriggered(format_installer_error(e)))
        }
      }
    }
    Error(e) -> {
      let _ = simplifile.delete(staging)
      Error(RollbackTriggered(format_installer_error(e)))
    }
  }
}

/// staging과 실제 디렉토리를 원자적으로 교체
fn swap_dirs(
  project_dir: String,
  staging: String,
) -> Result(Nil, InstallerError) {
  case platform.make_temp_dir(project_dir) {
    Error(e) -> Error(IoError(e))
    Ok(backup) -> swap_with_backup(project_dir, staging, backup)
  }
}

fn swap_with_backup(
  project_dir: String,
  staging: String,
  backup: String,
) -> Result(Nil, InstallerError) {
  let hex_dir = project_dir <> "/build/packages"
  let npm_dir = project_dir <> "/node_modules"
  let staging_hex = staging <> "/build/packages"
  let staging_npm = staging <> "/node_modules"
  let backup_hex = backup <> "/packages"
  let backup_npm = backup <> "/node_modules"
  // 1단계: 기존 → backup (기존이 없으면 skip)
  let hex_backed = case simplifile.is_directory(hex_dir) {
    Ok(True) ->
      case platform.atomic_rename(hex_dir, backup_hex) {
        Ok(_) -> True
        Error(_) -> False
      }
    _ -> False
  }
  let npm_backed = case simplifile.is_directory(npm_dir) {
    Ok(True) ->
      case platform.atomic_rename(npm_dir, backup_npm) {
        Ok(_) -> True
        Error(_) -> False
      }
    _ -> False
  }
  // 2단계: staging → 실제 위치
  let _ = simplifile.create_directory_all(project_dir <> "/build")
  let hex_swap = platform.atomic_rename(staging_hex, hex_dir)
  let npm_swap = platform.atomic_rename(staging_npm, npm_dir)
  case hex_swap, npm_swap {
    Ok(_), Ok(_) -> {
      // 성공 → backup + staging 정리
      let _ = simplifile.delete(backup)
      let _ = simplifile.delete(staging)
      Ok(Nil)
    }
    _, _ -> {
      // 실패 → backup에서 복원
      case hex_backed {
        True -> {
          let _ = simplifile.delete(hex_dir)
          let _ = platform.atomic_rename(backup_hex, hex_dir)
          Nil
        }
        False -> Nil
      }
      case npm_backed {
        True -> {
          let _ = simplifile.delete(npm_dir)
          let _ = platform.atomic_rename(backup_npm, npm_dir)
          Nil
        }
        False -> Nil
      }
      let _ = simplifile.delete(staging)
      let _ = simplifile.delete(backup)
      Error(RollbackFailed(
        original_error: "directory swap failed",
        rollback_error: "attempted restore from backup",
      ))
    }
  }
}

fn format_installer_error(e: InstallerError) -> String {
  case e {
    StoreErr(_) -> "store error"
    IoError(d) -> d
    LinkError(d) -> d
    RollbackTriggered(d) -> d
    RollbackFailed(o, r) -> o <> " / " <> r
  }
}

// ---------------------------------------------------------------------------
// 내부 구현
// ---------------------------------------------------------------------------

type InstallMode {
  HardlinkMode
  CopyMode
}

fn install_mode(package: ResolvedPackage) -> InstallMode {
  case package.registry {
    Hex -> HardlinkMode
    Npm ->
      case package.has_scripts {
        True -> CopyMode
        False -> HardlinkMode
      }
  }
}

fn install_each(
  packages: List(ResolvedPackage),
  project_dir: String,
  acc: List(Warning),
) -> Result(List(Warning), InstallerError) {
  case packages {
    [] -> Ok(acc)
    [pkg, ..rest] -> {
      use warnings <- result.try(install_package(pkg, project_dir))
      install_each(rest, project_dir, list.append(acc, warnings))
    }
  }
}

/// 패키지의 설치 경로 반환
pub fn install_path(pkg: ResolvedPackage, project_dir: String) -> String {
  case pkg.registry {
    Hex -> project_dir <> "/build/packages/" <> pkg.name
    Npm -> project_dir <> "/node_modules/" <> pkg.name
  }
}

fn ensure_dirs(project_dir: String) -> Result(Nil, InstallerError) {
  use _ <- result.try(
    simplifile.create_directory_all(project_dir <> "/build/packages")
    |> result.map_error(fn(e) { IoError(simplifile.describe_error(e)) }),
  )
  simplifile.create_directory_all(project_dir <> "/node_modules")
  |> result.map_error(fn(e) { IoError(simplifile.describe_error(e)) })
}

/// hardlink 시도, 실패 시 copy 폴백 (Hex 및 스크립트 없는 npm)
fn hardlink_dir_contents(
  src: String,
  dst: String,
) -> Result(Nil, InstallerError) {
  case simplifile.get_files(src) {
    Ok(files) -> transfer_files(files, src, dst, True)
    Error(e) -> Error(IoError(simplifile.describe_error(e)))
  }
}

/// 항상 copy (스크립트 있는 npm — store 원본 보호)
fn copy_dir_contents(src: String, dst: String) -> Result(Nil, InstallerError) {
  case simplifile.get_files(src) {
    Ok(files) -> transfer_files(files, src, dst, False)
    Error(e) -> Error(IoError(simplifile.describe_error(e)))
  }
}

fn transfer_files(
  files: List(String),
  src_root: String,
  dst_root: String,
  try_hardlink: Bool,
) -> Result(Nil, InstallerError) {
  case files {
    [] -> Ok(Nil)
    [file, ..rest] -> {
      let relative = string.drop_start(file, string.length(src_root))
      let dst_file = dst_root <> relative
      let dst_dir = filepath.directory_name(dst_file)
      let _ = simplifile.create_directory_all(dst_dir)
      let transfer_result = case try_hardlink {
        True ->
          case platform.make_hardlink(file, dst_file) {
            Ok(_) -> Ok(Nil)
            Error(_) ->
              simplifile.copy_file(file, dst_file)
              |> result.map_error(fn(e) {
                LinkError(simplifile.describe_error(e))
              })
          }
        False ->
          simplifile.copy_file(file, dst_file)
          |> result.map_error(fn(e) { LinkError(simplifile.describe_error(e)) })
      }
      use _ <- result.try(transfer_result)
      transfer_files(rest, src_root, dst_root, try_hardlink)
    }
  }
}

fn create_bin_links(
  entries: List(#(String, List(#(String, String)))),
  project_dir: String,
  bin_dir: String,
) -> Result(Nil, InstallerError) {
  case entries {
    [] -> Ok(Nil)
    [#(pkg_name, bins), ..rest] -> {
      use _ <- result.try(create_pkg_bin_links(
        bins,
        pkg_name,
        project_dir,
        bin_dir,
      ))
      create_bin_links(rest, project_dir, bin_dir)
    }
  }
}

fn create_pkg_bin_links(
  bins: List(#(String, String)),
  pkg_name: String,
  project_dir: String,
  bin_dir: String,
) -> Result(Nil, InstallerError) {
  case bins {
    [] -> Ok(Nil)
    [#(cmd, file_path), ..rest] -> {
      let target =
        project_dir <> "/node_modules/" <> pkg_name <> "/" <> file_path
      case platform.get_platform_os() {
        "win32" -> {
          // Windows: .cmd wrapper 생성
          let _ = create_cmd_wrapper(cmd, pkg_name, file_path, bin_dir)
          Nil
        }
        _ -> {
          // Unix: 심볼릭 링크 + 실행 권한
          let link = bin_dir <> "/" <> cmd
          let _ = platform.make_symlink(target, link)
          let _ = platform.chmod_executable(target)
          Nil
        }
      }
      create_pkg_bin_links(rest, pkg_name, project_dir, bin_dir)
    }
  }
}

fn create_cmd_wrapper(
  cmd: String,
  pkg_name: String,
  file_path: String,
  bin_dir: String,
) -> Result(Nil, InstallerError) {
  let cmd_path = bin_dir <> "/" <> cmd <> ".cmd"
  let relative = string.replace(pkg_name <> "/" <> file_path, "/", "\\")
  let content = "@\"%~dp0\\..\\" <> relative <> "\" %*\r\n"
  simplifile.write(cmd_path, content)
  |> result.map_error(fn(e) { IoError(simplifile.describe_error(e)) })
}

fn check_platform_mismatch(package: ResolvedPackage) -> List(Warning) {
  case package.registry, package.platform {
    Npm, Ok(plat) -> {
      let current_os = platform.get_platform_os()
      let current_arch = platform.get_platform_arch()
      let os_ok = case plat.os {
        [] -> True
        os_list ->
          list.any(os_list, fn(o) { o == current_os })
          || list.any(os_list, fn(o) {
            string.starts_with(o, "!") && o != "!" <> current_os
          })
      }
      let cpu_ok = case plat.cpu {
        [] -> True
        cpu_list ->
          list.any(cpu_list, fn(c) { c == current_arch })
          || list.any(cpu_list, fn(c) {
            string.starts_with(c, "!") && c != "!" <> current_arch
          })
      }
      case os_ok && cpu_ok {
        True -> []
        False -> [
          PlatformMismatch(
            name: package.name,
            version: package.version,
            os: current_os,
            arch: current_arch,
          ),
        ]
      }
    }
    _, _ -> []
  }
}

fn clean_dir(
  dir: String,
  keep_names: List(String),
) -> Result(Nil, InstallerError) {
  case simplifile.read_directory(dir) {
    Ok(entries) -> {
      list.each(entries, fn(entry) {
        case list.contains(keep_names, entry) {
          True -> Nil
          False -> {
            let _ = simplifile.delete(dir <> "/" <> entry)
            Nil
          }
        }
      })
      Ok(Nil)
    }
    Error(_) -> Ok(Nil)
  }
}

// ---------------------------------------------------------------------------
// 설치 후 무결성 검증
// ---------------------------------------------------------------------------

/// 설치된 패키지들의 무결성을 manifest 기반으로 검증
pub fn verify_installed(
  packages: List(ResolvedPackage),
  project_dir: String,
) -> List(#(ResolvedPackage, manifest.VerifyResult)) {
  list.filter_map(packages, fn(pkg) {
    let path = install_path(pkg, project_dir)
    case simplifile.is_directory(path) {
      Ok(True) ->
        case manifest.verify_full(path) {
          Ok(result) -> Ok(#(pkg, result))
          Error(_) -> Ok(#(pkg, manifest.VerifyNoManifest))
        }
      _ -> Error(Nil)
    }
  })
}
