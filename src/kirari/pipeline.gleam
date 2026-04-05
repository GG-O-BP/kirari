//// 설치 파이프라인 — 다운로드 → 저장 → 설치 오케스트레이션

import gleam/bit_array
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import kirari/cli/progress.{type ProgressHandle}
import kirari/git
import kirari/hashpin
import kirari/installer
import kirari/registry/hex
import kirari/registry/npm
import kirari/resolver.{type ResolveResult}
import kirari/security
import kirari/store
import kirari/types.{
  type ResolvedPackage, type SecurityConfig, Git, Hex, Npm, ResolvedPackage, Url,
}

/// pipeline 에러 타입
pub type PipelineError {
  DownloadError(name: String, version: String, detail: String)
  StoreErr(store.StoreError)
  InstallErr(installer.InstallerError)
  ProvenanceErr(name: String, detail: String)
  OfflinePackageMissing(name: String, version: String, registry: types.Registry)
  HashPinMismatch(
    name: String,
    registry: types.Registry,
    actual: String,
    allowed: List(String),
  )
}

/// pipeline 경고 타입 — cli에서 출력 담당
pub type Warning {
  ScriptBlocked(name: String, version: String)
  Deprecated(name: String, version: String, reason: String)
  PlatformMismatch(name: String, version: String, os: String, arch: String)
  PeerDependencyMissing(package: String, peer: String, constraint: String)
  PeerDependencyIncompatible(
    package: String,
    peer: String,
    required: String,
    installed: String,
  )
  OptionalSkipped(name: String, reason: String)
}

/// pipeline 실행 결과
pub type PipelineResult {
  PipelineResult(
    packages: List(ResolvedPackage),
    bin_map: List(#(String, List(#(String, String)))),
    warnings: List(Warning),
  )
}

/// 해결된 패키지를 다운로드 → 저장 → 설치
pub fn run(
  resolve_result: ResolveResult,
  project_dir: String,
  security: SecurityConfig,
  progress: ProgressHandle,
  offline: Bool,
  download_config: types.DownloadConfig,
) -> Result(PipelineResult, PipelineError) {
  // offline: store에 없는 패키지가 있으면 즉시 실패
  use _ <- result.try(check_offline_packages(resolve_result.packages, offline))
  // hash pin 로드 (.kir-hashes, 없으면 빈 목록)
  let hash_pins = case hashpin.read(project_dir) {
    Ok(pins) -> pins
    Error(_) -> hashpin.empty()
  }
  // 0. npm 서명 키 로드 (npm 패키지가 있고 ProvenanceIgnore가 아닐 때만, offline 시 skip)
  let has_npm = list.any(resolve_result.packages, fn(p) { p.registry == Npm })
  let npm_keys = case has_npm && !offline {
    True -> load_npm_keys(security.provenance)
    False -> []
  }
  let ctx =
    DownloadContext(
      version_infos: resolve_result.version_infos,
      npm_keys: npm_keys,
      provenance: security.provenance,
      hash_pins: hash_pins,
    )
  // 1. 다운로드 & 저장 (sha256 + has_scripts 업데이트)
  use download_results <- result.try(download_and_store_all(
    resolve_result.packages,
    ctx,
    progress,
    download_config,
  ))
  let updated = list.map(download_results, fn(dr) { dr.package })
  let bin_map =
    list.filter_map(download_results, fn(dr) {
      case dr.bin {
        [] -> Error(Nil)
        bins -> Ok(#(dr.package.name, bins))
      }
    })
  // 2. 스크립트 정책 경고 + deprecated/retired 경고 + peer 경고 수집
  let peer_warnings =
    list.map(resolve_result.peer_warnings, fn(pw) {
      case pw {
        resolver.PeerMissing(package, peer, constraint) ->
          PeerDependencyMissing(
            package: package,
            peer: peer,
            constraint: constraint,
          )
        resolver.PeerIncompatible(package, peer, required, installed) ->
          PeerDependencyIncompatible(
            package: package,
            peer: peer,
            required: required,
            installed: installed,
          )
      }
    })
  let warnings =
    list.flatten([
      collect_script_warnings(updated, security),
      collect_deprecation_warnings(updated, ctx),
      peer_warnings,
    ])
  // 3. 원자적 설치 (staging → swap, 실패 시 롤백)
  use install_warnings <- result.try(
    installer.install_atomic(updated, bin_map, project_dir)
    |> result.map_error(InstallErr),
  )
  let warnings =
    list.append(
      warnings,
      list.map(install_warnings, fn(w) {
        case w {
          installer.PlatformMismatch(name, version, os, arch) ->
            PlatformMismatch(name: name, version: version, os: os, arch: arch)
        }
      }),
    )
  Ok(PipelineResult(packages: updated, bin_map: bin_map, warnings: warnings))
}

// ---------------------------------------------------------------------------
// 경고 수집 (데이터 반환, 출력은 cli 담당)
// ---------------------------------------------------------------------------

fn collect_script_warnings(
  packages: List(ResolvedPackage),
  security: SecurityConfig,
) -> List(Warning) {
  list.filter_map(packages, fn(pkg) {
    case pkg.has_scripts && !is_script_allowed(pkg.name, security.npm_scripts) {
      True -> Ok(ScriptBlocked(name: pkg.name, version: pkg.version))
      False -> Error(Nil)
    }
  })
}

fn collect_deprecation_warnings(
  packages: List(ResolvedPackage),
  ctx: DownloadContext,
) -> List(Warning) {
  list.filter_map(packages, fn(pkg) {
    let key = pkg.name <> ":" <> types.registry_to_string(pkg.registry)
    case dict.get(ctx.version_infos, key) {
      Ok(vi) if vi.deprecated != "" ->
        Ok(Deprecated(
          name: pkg.name,
          version: pkg.version,
          reason: vi.deprecated,
        ))
      _ -> Error(Nil)
    }
  })
}

fn is_script_allowed(name: String, policy: types.ScriptPolicy) -> Bool {
  case policy {
    types.AllowAll -> True
    types.DenyAll -> False
    types.AllowList(packages) -> list.contains(packages, name)
  }
}

/// offline 모드일 때 store에 없는 패키지 확인
fn check_offline_packages(
  packages: List(ResolvedPackage),
  offline: Bool,
) -> Result(Nil, PipelineError) {
  case offline {
    False -> Ok(Nil)
    True -> {
      let missing =
        list.filter(packages, fn(p) {
          case store.has_package(p.sha256, p.registry) {
            Ok(True) -> False
            _ -> True
          }
        })
      case missing {
        [first, ..] ->
          Error(OfflinePackageMissing(
            name: first.name,
            version: first.version,
            registry: first.registry,
          ))
        [] -> Ok(Nil)
      }
    }
  }
}

/// hash pin 검증 — .kir-hashes에 핀이 있으면 대조
fn verify_hash_pin(
  pkg: ResolvedPackage,
  hash: String,
  ctx: DownloadContext,
) -> Result(Nil, PipelineError) {
  case hashpin.check(ctx.hash_pins, pkg.name, pkg.registry, hash) {
    hashpin.PinMatched(_, _) -> Ok(Nil)
    hashpin.PinMismatch(name, registry, actual, allowed) ->
      Error(HashPinMismatch(
        name: name,
        registry: registry,
        actual: actual,
        allowed: allowed,
      ))
    hashpin.NoPinEntry -> Ok(Nil)
  }
}

// ---------------------------------------------------------------------------
// 다운로드 & 저장
// ---------------------------------------------------------------------------

type DownloadResult {
  DownloadResult(
    package: ResolvedPackage,
    bin: List(#(String, String)),
    bytes_downloaded: Int,
  )
}

type DownloadContext {
  DownloadContext(
    version_infos: dict.Dict(String, resolver.VersionInfo),
    npm_keys: List(#(String, String)),
    provenance: types.ProvenancePolicy,
    hash_pins: hashpin.HashPins,
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
  prog: ProgressHandle,
  dl_config: types.DownloadConfig,
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
  // 캐시된 패키지에 Cached 이벤트 전송
  list.each(cached, fn(pkg) {
    progress.send(prog, progress.Cached(name: pkg.name, version: pkg.version))
  })
  let cached_results =
    list.map(cached, fn(pkg) {
      DownloadResult(package: pkg, bin: [], bytes_downloaded: 0)
    })
  // 병렬 다운로드
  use downloaded <- result.try(download_parallel(
    to_download,
    ctx,
    prog,
    dl_config,
  ))
  Ok(
    list.append(cached_results, downloaded)
    |> list.sort(fn(a, b) { types.compare_packages(a.package, b.package) }),
  )
}

fn download_parallel(
  packages: List(ResolvedPackage),
  ctx: DownloadContext,
  prog: ProgressHandle,
  dl_config: types.DownloadConfig,
) -> Result(List(DownloadResult), PipelineError) {
  case packages {
    [] -> Ok([])
    _ -> {
      let batch_size = case dl_config.parallel {
        0 -> list.length(packages)
        n -> n
      }
      let batches = list_chunk(packages, batch_size)
      download_batches(batches, ctx, prog, dl_config, [])
    }
  }
}

/// 배치 단위 병렬 다운로드 — 각 배치 완료 후 다음 배치 시작
fn download_batches(
  batches: List(List(ResolvedPackage)),
  ctx: DownloadContext,
  prog: ProgressHandle,
  dl_config: types.DownloadConfig,
  acc: List(DownloadResult),
) -> Result(List(DownloadResult), PipelineError) {
  case batches {
    [] -> Ok(acc)
    [batch, ..rest] -> {
      let subject = process.new_subject()
      let count = list.length(batch)
      list.each(batch, fn(pkg) {
        process.spawn(fn() {
          progress.send(
            prog,
            progress.Started(name: pkg.name, version: pkg.version),
          )
          let result = download_and_store_one(pkg, ctx, dl_config)
          case result {
            Ok(dr) ->
              progress.send(
                prog,
                progress.Complete(
                  name: pkg.name,
                  version: pkg.version,
                  bytes: dr.bytes_downloaded,
                ),
              )
            Error(_) ->
              progress.send(
                prog,
                progress.Failed(name: pkg.name, version: pkg.version),
              )
          }
          process.send(subject, result)
        })
      })
      use batch_results <- result.try(collect_results(
        subject,
        count,
        [],
        dl_config.timeout_ms,
      ))
      download_batches(
        rest,
        ctx,
        prog,
        dl_config,
        list.append(acc, batch_results),
      )
    }
  }
}

fn collect_results(
  subject: process.Subject(Result(DownloadResult, PipelineError)),
  remaining: Int,
  acc: List(DownloadResult),
  timeout_ms: Int,
) -> Result(List(DownloadResult), PipelineError) {
  case remaining {
    0 -> Ok(acc)
    _ ->
      case process.receive(subject, timeout_ms) {
        Ok(Ok(dr)) ->
          collect_results(subject, remaining - 1, [dr, ..acc], timeout_ms)
        Ok(Error(e)) -> Error(e)
        Error(_) ->
          Error(DownloadError(
            "",
            "",
            "download timeout (" <> int.to_string(timeout_ms / 1000) <> "s)",
          ))
      }
  }
}

fn download_and_store_one(
  pkg: ResolvedPackage,
  ctx: DownloadContext,
  dl_config: types.DownloadConfig,
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
    True -> Ok(DownloadResult(package: pkg, bin: [], bytes_downloaded: 0))
    False ->
      case pkg.registry {
        Git -> download_and_store_git(pkg, dl_config)
        Url -> download_and_store_url(pkg, ctx, dl_config)
        Hex | Npm -> {
          let key = pkg.name <> ":" <> types.registry_to_string(pkg.registry)
          let tarball_url = case dict.get(ctx.version_infos, key) {
            Ok(vi) -> vi.tarball_url
            Error(_) -> ""
          }
          let tarball_url = resolve_tarball_url(pkg, tarball_url)
          use #(data, sha256) <- result.try(download_with_retry(
            pkg,
            tarball_url,
            dl_config.max_retries,
            dl_config.backoff_ms,
          ))
          let data_size = bit_array.byte_size(data)
          use _ <- result.try(verify_hash_pin(pkg, sha256, ctx))
          use _ <- result.try(verify_provenance_if_npm(pkg, data, ctx))
          use _ <- result.try(verify_sri_if_npm(pkg, data, ctx))
          use store_result <- result.try(
            store.store_package(
              data,
              sha256,
              pkg.name,
              pkg.version,
              pkg.registry,
            )
            |> result.map_error(StoreErr),
          )
          let updated_pkg =
            ResolvedPackage(
              ..pkg,
              sha256: sha256,
              has_scripts: store_result.has_scripts,
            )
          Ok(DownloadResult(
            package: updated_pkg,
            bin: store_result.bin,
            bytes_downloaded: data_size,
          ))
        }
      }
  }
}

/// Git 패키지: clone → content hash → store
fn download_and_store_git(
  pkg: ResolvedPackage,
  dl_config: types.DownloadConfig,
) -> Result(DownloadResult, PipelineError) {
  case pkg.git_source {
    Error(_) ->
      Error(DownloadError(pkg.name, pkg.version, "missing git source info"))
    Ok(gs) -> {
      use tmp_dir <- result.try(
        make_pipeline_temp_dir()
        |> result.map_error(fn(e) {
          DownloadError(pkg.name, pkg.version, "temp dir: " <> e)
        }),
      )
      use _ <- result.try(
        retry_git_clone(
          gs.url,
          gs.resolved_ref,
          tmp_dir,
          dl_config.max_retries,
          dl_config.backoff_ms,
        )
        |> result.map_error(fn(e) {
          DownloadError(pkg.name, pkg.version, "git clone: " <> e)
        }),
      )
      let src_dir = case gs.subdir {
        Ok(sub) -> tmp_dir <> "/" <> sub
        Error(_) -> tmp_dir
      }
      use store_result <- result.try(
        store.store_git_package(src_dir, pkg.sha256, pkg.name, pkg.version)
        |> result.map_error(StoreErr),
      )
      Ok(DownloadResult(
        package: ResolvedPackage(..pkg, sha256: pkg.sha256),
        bin: store_result.bin,
        bytes_downloaded: 0,
      ))
    }
  }
}

fn retry_git_clone(
  url: String,
  commit: String,
  dest: String,
  retries: Int,
  backoff_ms: Int,
) -> Result(Nil, String) {
  case git.shallow_clone(url, commit, dest) {
    Ok(_) -> Ok(Nil)
    Error(_e) if retries > 1 -> {
      let _ = process.sleep(backoff_ms)
      retry_git_clone(url, commit, dest, retries - 1, backoff_ms)
    }
    Error(e) ->
      Error(case e {
        git.CloneFailed(_, d) -> d
        git.CheckoutFailed(d) -> d
        _ -> "clone failed"
      })
  }
}

/// URL 패키지: HTTP download → hash 검증 → store
fn download_and_store_url(
  pkg: ResolvedPackage,
  ctx: DownloadContext,
  dl_config: types.DownloadConfig,
) -> Result(DownloadResult, PipelineError) {
  case pkg.url_source {
    Error(_) ->
      Error(DownloadError(pkg.name, pkg.version, "missing url source info"))
    Ok(us) -> {
      use #(data, sha256) <- result.try(download_with_retry(
        pkg,
        us.url,
        dl_config.max_retries,
        dl_config.backoff_ms,
      ))
      let data_size = bit_array.byte_size(data)
      use _ <- result.try(verify_hash_pin(pkg, sha256, ctx))
      use store_result <- result.try(
        store.store_package(data, sha256, pkg.name, pkg.version, Url)
        |> result.map_error(StoreErr),
      )
      let updated_pkg = ResolvedPackage(..pkg, sha256: sha256)
      Ok(DownloadResult(
        package: updated_pkg,
        bin: store_result.bin,
        bytes_downloaded: data_size,
      ))
    }
  }
}

@external(erlang, "kirari_ffi", "make_temp_dir_system")
fn make_pipeline_temp_dir() -> Result(String, String)

fn verify_provenance_if_npm(
  pkg: ResolvedPackage,
  data: BitArray,
  ctx: DownloadContext,
) -> Result(Nil, PipelineError) {
  case pkg.registry {
    Hex | Git | Url -> Ok(Nil)
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
      |> result.map_error(fn(e) {
        case e {
          security.SignatureError(detail) -> ProvenanceErr(pkg.name, detail)
          _ -> ProvenanceErr(pkg.name, "signature verification failed")
        }
      })
    }
  }
}

fn verify_sri_if_npm(
  pkg: ResolvedPackage,
  data: BitArray,
  ctx: DownloadContext,
) -> Result(Nil, PipelineError) {
  case pkg.registry {
    Hex | Git | Url -> Ok(Nil)
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
        // Git/Url은 자체 URL을 사용하므로 여기에 도달하지 않음
        Git | Url -> ""
      }
    _ -> url
  }
}

fn download_with_retry(
  pkg: ResolvedPackage,
  tarball_url: String,
  attempts: Int,
  backoff_ms: Int,
) -> Result(#(BitArray, String), PipelineError) {
  case download_tarball(pkg, tarball_url) {
    Ok(result) -> Ok(result)
    Error(e) ->
      case attempts > 1 {
        True -> {
          process.sleep(backoff_ms)
          download_with_retry(pkg, tarball_url, attempts - 1, backoff_ms)
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
    Npm | Url ->
      npm.download_tarball(pkg.name, pkg.version, tarball_url)
      |> result.map_error(fn(e) {
        DownloadError(pkg.name, pkg.version, string.inspect(e))
      })
    Git ->
      Error(DownloadError(
        pkg.name,
        pkg.version,
        "Git packages use clone, not tarball download",
      ))
  }
}

// ---------------------------------------------------------------------------
// 유틸리티
// ---------------------------------------------------------------------------

/// 리스트를 최대 size 크기의 배치로 분할
fn list_chunk(items: List(a), size: Int) -> List(List(a)) {
  case items {
    [] -> []
    _ -> {
      let batch = list.take(items, size)
      let rest = list.drop(items, size)
      [batch, ..list_chunk(rest, size)]
    }
  }
}
