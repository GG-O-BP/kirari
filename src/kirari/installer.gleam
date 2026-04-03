//// 프로젝트 설치 — store에서 build/packages, node_modules로 링크/복사

import filepath
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
    store.package_path(package.sha256)
    |> result.map_error(StoreErr),
  )
  let target = install_target(package, project_dir)
  // 기존 디렉토리 제거 후 복사
  let _ = simplifile.delete(target)
  use _ <- result.try(
    simplifile.create_directory_all(target)
    |> result.map_error(fn(e) { IoError(simplifile.describe_error(e)) }),
  )
  copy_dir_contents(source_path, target)
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

fn copy_dir_contents(src: String, dst: String) -> Result(Nil, InstallerError) {
  case simplifile.get_files(src) {
    Ok(files) -> copy_files(files, src, dst)
    Error(e) -> Error(IoError(simplifile.describe_error(e)))
  }
}

fn copy_files(
  files: List(String),
  src_root: String,
  dst_root: String,
) -> Result(Nil, InstallerError) {
  case files {
    [] -> Ok(Nil)
    [file, ..rest] -> {
      let relative = string.drop_start(file, string.length(src_root))
      let dst_file = dst_root <> relative
      // 대상 디렉토리 생성
      let dst_dir = filepath.directory_name(dst_file)
      let _ = simplifile.create_directory_all(dst_dir)
      // 하드링크 시도, 실패 시 복사
      let result = case platform.make_hardlink(file, dst_file) {
        Ok(_) -> Ok(Nil)
        Error(_) ->
          simplifile.copy_file(file, dst_file)
          |> result.map_error(fn(e) { LinkError(simplifile.describe_error(e)) })
      }
      use _ <- result.try(result)
      copy_files(rest, src_root, dst_root)
    }
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
