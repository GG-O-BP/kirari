//// 설치 파이프라인 — 다운로드 → 저장 → 설치 오케스트레이션

import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/result
import gleam/string
import kirari/installer
import kirari/registry/hex
import kirari/registry/npm
import kirari/resolver.{type ResolveResult}
import kirari/store
import kirari/types.{type ResolvedPackage, Hex, Npm, ResolvedPackage}

/// pipeline 에러 타입
pub type PipelineError {
  DownloadError(name: String, version: String, detail: String)
  StoreErr(store.StoreError)
  InstallErr(installer.InstallerError)
}

/// 해결된 패키지를 다운로드 → 저장 → 설치
pub fn run(
  resolve_result: ResolveResult,
  project_dir: String,
) -> Result(List(ResolvedPackage), PipelineError) {
  // 1. 다운로드 & 저장 (sha256 업데이트)
  use updated <- result.try(download_and_store_all(
    resolve_result.packages,
    resolve_result.version_infos,
  ))
  // 2. 프로젝트에 설치
  use _ <- result.try(
    installer.install_all(updated, project_dir)
    |> result.map_error(InstallErr),
  )
  // 3. 불필요한 패키지 정리
  use _ <- result.try(
    installer.clean_stale(updated, project_dir)
    |> result.map_error(InstallErr),
  )
  Ok(updated)
}

fn download_and_store_all(
  packages: List(ResolvedPackage),
  version_infos: dict.Dict(String, resolver.VersionInfo),
) -> Result(List(ResolvedPackage), PipelineError) {
  // 이미 store에 있는 패키지와 다운로드 필요한 패키지 분리
  let #(cached, to_download) =
    list.partition(packages, fn(pkg) {
      case pkg.sha256 {
        "" -> False
        hash ->
          case store.has_package(hash) {
            Ok(True) -> True
            _ -> False
          }
      }
    })
  // 병렬 다운로드
  use downloaded <- result.try(download_parallel(to_download, version_infos))
  Ok(
    list.append(cached, downloaded)
    |> list.sort(types.compare_packages),
  )
}

fn download_parallel(
  packages: List(ResolvedPackage),
  version_infos: dict.Dict(String, resolver.VersionInfo),
) -> Result(List(ResolvedPackage), PipelineError) {
  case packages {
    [] -> Ok([])
    _ -> {
      let subject = process.new_subject()
      let count = list.length(packages)
      list.each(packages, fn(pkg) {
        process.spawn(fn() {
          let result = download_and_store_one(pkg, version_infos)
          process.send(subject, result)
        })
      })
      collect_results(subject, count, [])
    }
  }
}

fn collect_results(
  subject: process.Subject(Result(ResolvedPackage, PipelineError)),
  remaining: Int,
  acc: List(ResolvedPackage),
) -> Result(List(ResolvedPackage), PipelineError) {
  case remaining {
    0 -> Ok(acc)
    _ ->
      case process.receive(subject, 120_000) {
        Ok(Ok(pkg)) -> collect_results(subject, remaining - 1, [pkg, ..acc])
        Ok(Error(e)) -> Error(e)
        Error(_) -> Error(DownloadError("", "", "download timeout (120s)"))
      }
  }
}

fn download_and_store_one(
  pkg: ResolvedPackage,
  version_infos: dict.Dict(String, resolver.VersionInfo),
) -> Result(ResolvedPackage, PipelineError) {
  // 이미 store에 있으면 skip
  let already_stored = case pkg.sha256 {
    "" -> False
    hash ->
      case store.has_package(hash) {
        Ok(True) -> True
        _ -> False
      }
  }
  case already_stored {
    True -> Ok(pkg)
    False -> {
      // tarball URL 조회
      let key = pkg.name <> ":" <> types.registry_to_string(pkg.registry)
      let tarball_url = case dict.get(version_infos, key) {
        Ok(vi) -> vi.tarball_url
        Error(_) -> ""
      }
      // 다운로드
      use #(data, sha256) <- result.try(download_tarball(pkg, tarball_url))
      // store에 저장
      use _ <- result.try(
        store.store_package(data, sha256, pkg.name, pkg.version, pkg.registry)
        |> result.map_error(StoreErr),
      )
      Ok(ResolvedPackage(..pkg, sha256: sha256))
    }
  }
}

fn download_tarball(
  pkg: ResolvedPackage,
  tarball_url: String,
) -> Result(#(BitArray, String), PipelineError) {
  case pkg.registry {
    Hex ->
      hex.download_tarball(pkg.name, pkg.version)
      |> result.map_error(fn(e) {
        DownloadError(pkg.name, pkg.version, string.inspect(e))
      })
    Npm ->
      npm.download_tarball(pkg.name, pkg.version, tarball_url)
      |> result.map_error(fn(e) {
        DownloadError(pkg.name, pkg.version, string.inspect(e))
      })
  }
}
