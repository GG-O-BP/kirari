//// 프로젝트 설치 — store에서 build/packages, node_modules로 링크/복사

import filepath
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import kirari/platform
import kirari/store
import kirari/types.{type ResolvedPackage, Hex, Npm}
import simplifile

/// installer 에러 타입
pub type InstallerError {
  StoreErr(store.StoreError)
  IoError(detail: String)
  LinkError(detail: String)
}

// ---------------------------------------------------------------------------
// 공개 API
// ---------------------------------------------------------------------------

/// 해결된 패키지를 프로젝트 디렉토리에 설치
pub fn install_all(
  packages: List(ResolvedPackage),
  project_dir: String,
) -> Result(Nil, InstallerError) {
  use _ <- result.try(ensure_dirs(project_dir))
  install_each(packages, project_dir)
}

/// 단일 패키지 설치
pub fn install_package(
  package: ResolvedPackage,
  project_dir: String,
) -> Result(Nil, InstallerError) {
  use source_path <- result.try(
    store.package_path(package.sha256, package.registry)
    |> result.map_error(StoreErr),
  )
  // 플랫폼 불일치 경고 (npm만)
  warn_platform_mismatch(package)
  let target = install_target(package, project_dir)
  // 기존 디렉토리 제거 후 복사
  let _ = simplifile.delete(target)
  use _ <- result.try(
    simplifile.create_directory_all(target)
    |> result.map_error(fn(e) { IoError(simplifile.describe_error(e)) }),
  )
  case install_mode(package) {
    HardlinkMode -> hardlink_dir_contents(source_path, target)
    CopyMode -> copy_dir_contents(source_path, target)
  }
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
) -> Result(Nil, InstallerError) {
  case packages {
    [] -> Ok(Nil)
    [pkg, ..rest] -> {
      use _ <- result.try(install_package(pkg, project_dir))
      install_each(rest, project_dir)
    }
  }
}

fn install_target(pkg: ResolvedPackage, project_dir: String) -> String {
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

fn warn_platform_mismatch(package: ResolvedPackage) -> Nil {
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
        True -> Nil
        False ->
          io.println(
            "\u{26a0} "
            <> package.name
            <> "@"
            <> package.version
            <> " may not be compatible with "
            <> current_os
            <> "/"
            <> current_arch,
          )
      }
    }
    _, _ -> Nil
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
