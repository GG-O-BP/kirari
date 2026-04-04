//// 설치 파이프라인 — 다운로드 → 저장 → 설치 오케스트레이션

import gleam/dict
import gleam/erlang/process
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import kirari/installer
import kirari/registry/hex
import kirari/registry/npm
import kirari/resolver.{type ResolveResult}
import kirari/security
import kirari/store
import kirari/types.{
  type ResolvedPackage, type SecurityConfig, Hex, Npm, ResolvedPackage,
}

/// pipeline 에러 타입
pub type PipelineError {
  DownloadError(name: String, version: String, detail: String)
  StoreErr(store.StoreError)
  InstallErr(installer.InstallerError)
  ProvenanceErr(name: String, detail: String)
}

/// pipeline 실행 결과
pub type PipelineResult {
  PipelineResult(
    packages: List(ResolvedPackage),
    bin_map: List(#(String, List(#(String, String)))),
  )
}

/// 해결된 패키지를 다운로드 → 저장 → 설치
pub fn run(
  resolve_result: ResolveResult,
  project_dir: String,
  security: SecurityConfig,
) -> Result(PipelineResult, PipelineError) {
  // 0. npm 서명 키 로드 (ProvenanceIgnore가 아닐 때만)
  let npm_keys = load_npm_keys(security.provenance)
  let ctx =
    DownloadContext(
      version_infos: resolve_result.version_infos,
      npm_keys: npm_keys,
      provenance: security.provenance,
    )
  // 1. 다운로드 & 저장 (sha256 + has_scripts 업데이트)
  use download_results <- result.try(download_and_store_all(
    resolve_result.packages,
    ctx,
  ))
  let updated = list.map(download_results, fn(dr) { dr.package })
  let bin_map =
    list.filter_map(download_results, fn(dr) {
      case dr.bin {
        [] -> Error(Nil)
        bins -> Ok(#(dr.package.name, bins))
      }
    })
  // 2. 스크립트 정책 경고
  warn_scripts(updated, security)
  // 3. 프로젝트에 설치
  use _ <- result.try(
    installer.install_all(updated, project_dir)
    |> result.map_error(InstallErr),
  )
  // 4. bin 심볼릭 링크
  use _ <- result.try(
    installer.link_bins(bin_map, project_dir)
    |> result.map_error(InstallErr),
  )
  // 5. 불필요한 패키지 정리
  use _ <- result.try(
    installer.clean_stale(updated, project_dir)
    |> result.map_error(InstallErr),
  )
  Ok(PipelineResult(packages: updated, bin_map: bin_map))
}

// ---------------------------------------------------------------------------
// 스크립트 정책 경고
// ---------------------------------------------------------------------------

fn warn_scripts(
  packages: List(ResolvedPackage),
  security: SecurityConfig,
) -> Nil {
  let violators =
    list.filter(packages, fn(pkg) {
      pkg.has_scripts && !is_script_allowed(pkg.name, security.npm_scripts)
    })
  list.each(violators, fn(pkg) {
    io.println(
      "\u{26a0} "
      <> pkg.name
      <> "@"
      <> pkg.version
      <> " has install scripts (blocked by npm-scripts policy)",
    )
  })
}

fn is_script_allowed(name: String, policy: types.ScriptPolicy) -> Bool {
  case policy {
    types.AllowAll -> True
    types.DenyAll -> False
    types.AllowList(packages) -> list.contains(packages, name)
  }
}

// ---------------------------------------------------------------------------
// 다운로드 & 저장
// ---------------------------------------------------------------------------

type DownloadResult {
  DownloadResult(package: ResolvedPackage, bin: List(#(String, String)))
}

type DownloadContext {
  DownloadContext(
    version_infos: dict.Dict(String, resolver.VersionInfo),
    npm_keys: List(#(String, String)),
    provenance: types.ProvenancePolicy,
  )
}

fn load_npm_keys(policy: types.ProvenancePolicy) -> List(#(String, String)) {
  case policy {
    types.ProvenanceIgnore -> []
    _ ->
      case npm.load_or_fetch_signing_keys() {
        Ok(keys) -> list.map(keys, fn(k) { #(k.keyid, k.pem) })
        Error(_) -> []
      }
  }
}

fn download_and_store_all(
  packages: List(ResolvedPackage),
  ctx: DownloadContext,
) -> Result(List(DownloadResult), PipelineError) {
  // 이미 store에 있는 패키지와 다운로드 필요한 패키지 분리
  let #(cached, to_download) =
    list.partition(packages, fn(pkg) {
      case pkg.sha256 {
        "" -> False
        hash ->
          case store.has_package(hash, pkg.registry) {
            Ok(True) -> True
            _ -> False
          }
      }
    })
  let cached_results =
    list.map(cached, fn(pkg) { DownloadResult(package: pkg, bin: []) })
  // 병렬 다운로드
  use downloaded <- result.try(download_parallel(to_download, ctx))
  Ok(
    list.append(cached_results, downloaded)
    |> list.sort(fn(a, b) { types.compare_packages(a.package, b.package) }),
  )
}

fn download_parallel(
  packages: List(ResolvedPackage),
  ctx: DownloadContext,
) -> Result(List(DownloadResult), PipelineError) {
  case packages {
    [] -> Ok([])
    _ -> {
      let subject = process.new_subject()
      let count = list.length(packages)
      list.each(packages, fn(pkg) {
        process.spawn(fn() {
          let result = download_and_store_one(pkg, ctx)
          process.send(subject, result)
        })
      })
      collect_results(subject, count, [])
    }
  }
}

fn collect_results(
  subject: process.Subject(Result(DownloadResult, PipelineError)),
  remaining: Int,
  acc: List(DownloadResult),
) -> Result(List(DownloadResult), PipelineError) {
  case remaining {
    0 -> Ok(acc)
    _ ->
      case process.receive(subject, 120_000) {
        Ok(Ok(dr)) -> collect_results(subject, remaining - 1, [dr, ..acc])
        Ok(Error(e)) -> Error(e)
        Error(_) -> Error(DownloadError("", "", "download timeout (120s)"))
      }
  }
}

fn download_and_store_one(
  pkg: ResolvedPackage,
  ctx: DownloadContext,
) -> Result(DownloadResult, PipelineError) {
  // 이미 store에 있으면 skip
  let already_stored = case pkg.sha256 {
    "" -> False
    hash ->
      case store.has_package(hash, pkg.registry) {
        Ok(True) -> True
        _ -> False
      }
  }
  case already_stored {
    True -> Ok(DownloadResult(package: pkg, bin: []))
    False -> {
      // tarball URL 조회 (빈 문자열이면 기본 URL 생성)
      let key = pkg.name <> ":" <> types.registry_to_string(pkg.registry)
      let tarball_url = case dict.get(ctx.version_infos, key) {
        Ok(vi) -> vi.tarball_url
        Error(_) -> ""
      }
      let tarball_url = resolve_tarball_url(pkg, tarball_url)
      // 다운로드 (3회 재시도)
      use #(data, sha256) <- result.try(download_with_retry(pkg, tarball_url, 3))
      // npm Sigstore 서명 검증 (다운로드 후, store 전)
      use _ <- result.try(verify_provenance_if_npm(pkg, data, ctx))
      // npm SRI integrity 검증
      use _ <- result.try(verify_sri_if_npm(pkg, data, ctx))
      // store에 저장
      use store_result <- result.try(
        store.store_package(data, sha256, pkg.name, pkg.version, pkg.registry)
        |> result.map_error(StoreErr),
      )
      let updated_pkg =
        ResolvedPackage(
          ..pkg,
          sha256: sha256,
          has_scripts: store_result.has_scripts,
        )
      Ok(DownloadResult(package: updated_pkg, bin: store_result.bin))
    }
  }
}

fn verify_provenance_if_npm(
  pkg: ResolvedPackage,
  data: BitArray,
  ctx: DownloadContext,
) -> Result(Nil, PipelineError) {
  case pkg.registry {
    Hex -> Ok(Nil)
    Npm -> {
      let key = pkg.name <> ":" <> types.registry_to_string(pkg.registry)
      let signatures = case dict.get(ctx.version_infos, key) {
        Ok(vi) -> vi.signatures
        Error(_) -> []
      }
      security.verify_npm_provenance(
        data,
        signatures,
        ctx.npm_keys,
        ctx.provenance,
      )
      |> result.map_error(fn(detail) { ProvenanceErr(pkg.name, detail) })
    }
  }
}

fn verify_sri_if_npm(
  pkg: ResolvedPackage,
  data: BitArray,
  ctx: DownloadContext,
) -> Result(Nil, PipelineError) {
  case pkg.registry {
    Hex -> Ok(Nil)
    Npm -> {
      let key = pkg.name <> ":" <> types.registry_to_string(pkg.registry)
      let integrity = case dict.get(ctx.version_infos, key) {
        Ok(vi) -> vi.integrity
        Error(_) -> ""
      }
      security.verify_sri_integrity(data, integrity)
      |> result.map_error(fn(_) {
        DownloadError(pkg.name, pkg.version, "SRI integrity mismatch")
      })
    }
  }
}

fn resolve_tarball_url(pkg: ResolvedPackage, url: String) -> String {
  case url {
    "" ->
      case pkg.registry {
        Hex ->
          "https://repo.hex.pm/tarballs/"
          <> pkg.name
          <> "-"
          <> pkg.version
          <> ".tar"
        Npm -> {
          let base = case string.split(pkg.name, "/") {
            [_scope, name, ..] -> name
            _ -> pkg.name
          }
          "https://registry.npmjs.org/"
          <> npm.encode_package_name(pkg.name)
          <> "/-/"
          <> base
          <> "-"
          <> pkg.version
          <> ".tgz"
        }
      }
    _ -> url
  }
}

fn download_with_retry(
  pkg: ResolvedPackage,
  tarball_url: String,
  attempts: Int,
) -> Result(#(BitArray, String), PipelineError) {
  case download_tarball(pkg, tarball_url) {
    Ok(result) -> Ok(result)
    Error(e) ->
      case attempts > 1 {
        True -> {
          process.sleep(2000)
          download_with_retry(pkg, tarball_url, attempts - 1)
        }
        False -> Error(e)
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
