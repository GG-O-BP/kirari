//// Store garbage collection — 레지스트리별 보존 정책

import gleam/dict
import gleam/list
import gleam/result
import gleam/string
import kirari/platform
import kirari/store/hex as hex_store
import kirari/store/metadata
import kirari/store/npm as npm_store
import simplifile

/// GC 보존 정책
pub type GcPolicy {
  GcPolicy(
    max_age_days: Int,
    /// 지정 시 이 패키지만 제거 (빈 리스트 = 전체)
    only: List(String),
    /// 지정 시 이 패키지는 보존
    keep: List(String),
    /// True면 제거하지 않고 대상만 반환
    dry_run: Bool,
  )
}

/// 개별 GC 대상 항목
pub type GcEntry {
  GcEntry(name: String, version: String, sha256: String)
}

/// GC 실행 결과
pub type GcResult {
  GcResult(removed_count: Int, removed_packages: List(GcEntry))
}

/// GC 에러
pub type GcError {
  IoError(detail: String)
}

/// Hex 기본 정책: 0 = GC 안 함 (Hex 패키지는 불변)
pub fn hex_default_policy() -> GcPolicy {
  GcPolicy(max_age_days: 0, only: [], keep: [], dry_run: False)
}

/// npm 기본 정책: 90일 보존
pub fn npm_default_policy() -> GcPolicy {
  GcPolicy(max_age_days: 90, only: [], keep: [], dry_run: False)
}

/// 양쪽 store GC — Hex는 불변이므로 기본 skip, npm만 실행
pub fn gc_all() -> Result(#(GcResult, GcResult), GcError) {
  let hex_result = GcResult(removed_count: 0, removed_packages: [])
  use npm_result <- result.try(gc_npm(npm_default_policy()))
  Ok(#(hex_result, npm_result))
}

/// 이름 매핑 기반 선택적 GC — lockfile에서 SHA256→(name, version) 매핑 전달
pub fn gc_selective(
  policy: GcPolicy,
  name_map: dict.Dict(String, #(String, String)),
) -> Result(#(GcResult, GcResult), GcError) {
  let hex_policy =
    GcPolicy(..policy, max_age_days: case policy.max_age_days {
      0 -> 0
      n -> n
    })
  use hex_result <- result.try(gc_hex_selective(hex_policy, name_map))
  use npm_result <- result.try(gc_npm_selective(policy))
  Ok(#(hex_result, npm_result))
}

/// Hex 선택적 GC — name_map으로 이름 기반 필터링
fn gc_hex_selective(
  policy: GcPolicy,
  name_map: dict.Dict(String, #(String, String)),
) -> Result(GcResult, GcError) {
  case policy.max_age_days {
    0 -> Ok(GcResult(removed_count: 0, removed_packages: []))
    _ -> {
      use root <- result.try(
        hex_store.store_root()
        |> result.map_error(fn(_) { IoError("failed to get hex store root") }),
      )
      gc_by_mtime_filtered(root, policy, name_map)
    }
  }
}

/// npm 선택적 GC — .meta에서 이름 추출하여 필터링
fn gc_npm_selective(policy: GcPolicy) -> Result(GcResult, GcError) {
  use root <- result.try(
    npm_store.store_root()
    |> result.map_error(fn(_) { IoError("failed to get npm store root") }),
  )
  gc_by_meta_filtered(root, policy)
}

/// Hex store GC — max_age_days=0이면 skip (불변 패키지)
pub fn gc_hex(policy: GcPolicy) -> Result(GcResult, GcError) {
  case policy.max_age_days {
    0 -> Ok(GcResult(removed_count: 0, removed_packages: []))
    _ -> {
      use root <- result.try(
        hex_store.store_root()
        |> result.map_error(fn(_) { IoError("failed to get hex store root") }),
      )
      gc_by_mtime(root, policy)
    }
  }
}

/// npm store GC — .meta 파일의 stored_at 기반
pub fn gc_npm(policy: GcPolicy) -> Result(GcResult, GcError) {
  use root <- result.try(
    npm_store.store_root()
    |> result.map_error(fn(_) { IoError("failed to get npm store root") }),
  )
  gc_by_meta(root, policy)
}

// ---------------------------------------------------------------------------
// 내부 구현
// ---------------------------------------------------------------------------

fn gc_by_mtime(root: String, policy: GcPolicy) -> Result(GcResult, GcError) {
  let now = current_unix_seconds()
  let cutoff = now - policy.max_age_days * 86_400
  use prefixes <- result.try(
    list_dirs(root)
    |> result.map_error(fn(_) { IoError("failed to list store prefixes") }),
  )
  let removed =
    list.fold(prefixes, 0, fn(count, prefix) {
      let prefix_dir = root <> "/" <> prefix
      case list_dirs(prefix_dir) {
        Ok(entries) ->
          list.fold(entries, count, fn(c, entry) {
            let path = prefix_dir <> "/" <> entry
            case platform.get_file_mtime(path) {
              Ok(mtime) if mtime < cutoff -> {
                let _ = simplifile.delete(path)
                c + 1
              }
              _ -> c
            }
          })
        Error(_) -> count
      }
    })
  Ok(GcResult(removed_count: removed, removed_packages: []))
}

fn gc_by_meta(root: String, policy: GcPolicy) -> Result(GcResult, GcError) {
  let now = current_unix_seconds()
  let cutoff = now - policy.max_age_days * 86_400
  use prefixes <- result.try(
    list_dirs(root)
    |> result.map_error(fn(_) { IoError("failed to list store prefixes") }),
  )
  let removed =
    list.fold(prefixes, 0, fn(count, prefix) {
      let prefix_dir = root <> "/" <> prefix
      case simplifile.read_directory(prefix_dir) {
        Ok(entries) -> {
          let meta_files =
            list.filter(entries, fn(e) { string.ends_with(e, ".meta") })
          list.fold(meta_files, count, fn(c, meta_file) {
            let meta_path = prefix_dir <> "/" <> meta_file
            let sha256 = string.drop_end(meta_file, string.length(".meta"))
            case metadata.read_metadata(meta_path) {
              Ok(meta) ->
                case is_expired(meta.stored_at, cutoff) {
                  True -> {
                    let pkg_dir = prefix_dir <> "/" <> sha256
                    let _ = simplifile.delete(pkg_dir)
                    let _ = simplifile.delete(meta_path)
                    c + 1
                  }
                  False -> c
                }
              Error(_) -> c
            }
          })
        }
        Error(_) -> count
      }
    })
  Ok(GcResult(removed_count: removed, removed_packages: []))
}

/// Hex mtime GC with name-based filtering
fn gc_by_mtime_filtered(
  root: String,
  policy: GcPolicy,
  name_map: dict.Dict(String, #(String, String)),
) -> Result(GcResult, GcError) {
  let now = current_unix_seconds()
  let cutoff = now - policy.max_age_days * 86_400
  use prefixes <- result.try(
    list_dirs(root)
    |> result.map_error(fn(_) { IoError("failed to list store prefixes") }),
  )
  let #(removed, entries) =
    list.fold(prefixes, #(0, []), fn(acc, prefix) {
      let prefix_dir = root <> "/" <> prefix
      case list_dirs(prefix_dir) {
        Ok(dir_entries) ->
          list.fold(dir_entries, acc, fn(a, entry) {
            let #(c, es) = a
            let path = prefix_dir <> "/" <> entry
            let name_info = dict.get(name_map, entry)
            case
              should_gc_package(name_info, policy),
              platform.get_file_mtime(path)
            {
              True, Ok(mtime) if mtime < cutoff -> {
                case policy.dry_run {
                  False -> {
                    let _ = simplifile.delete(path)
                    Nil
                  }
                  True -> Nil
                }
                let ge = case name_info {
                  Ok(#(n, v)) -> GcEntry(name: n, version: v, sha256: entry)
                  Error(_) ->
                    GcEntry(name: "unknown", version: "", sha256: entry)
                }
                #(c + 1, [ge, ..es])
              }
              _, _ -> a
            }
          })
        Error(_) -> acc
      }
    })
  Ok(GcResult(removed_count: removed, removed_packages: entries))
}

/// npm meta GC with name-based filtering
fn gc_by_meta_filtered(
  root: String,
  policy: GcPolicy,
) -> Result(GcResult, GcError) {
  let now = current_unix_seconds()
  let cutoff = now - policy.max_age_days * 86_400
  use prefixes <- result.try(
    list_dirs(root)
    |> result.map_error(fn(_) { IoError("failed to list store prefixes") }),
  )
  let #(removed, entries) =
    list.fold(prefixes, #(0, []), fn(acc, prefix) {
      let prefix_dir = root <> "/" <> prefix
      case simplifile.read_directory(prefix_dir) {
        Ok(dir_entries) -> {
          let meta_files =
            list.filter(dir_entries, fn(e) { string.ends_with(e, ".meta") })
          list.fold(meta_files, acc, fn(a, meta_file) {
            let #(c, es) = a
            let meta_path = prefix_dir <> "/" <> meta_file
            let sha256 = string.drop_end(meta_file, string.length(".meta"))
            case metadata.read_metadata(meta_path) {
              Ok(meta) -> {
                let name_info = Ok(#(meta.name, meta.version))
                case
                  should_gc_package(name_info, policy),
                  is_expired(meta.stored_at, cutoff)
                {
                  True, True -> {
                    case policy.dry_run {
                      False -> {
                        let pkg_dir = prefix_dir <> "/" <> sha256
                        let _ = simplifile.delete(pkg_dir)
                        let _ = simplifile.delete(meta_path)
                        Nil
                      }
                      True -> Nil
                    }
                    let ge =
                      GcEntry(
                        name: meta.name,
                        version: meta.version,
                        sha256: sha256,
                      )
                    #(c + 1, [ge, ..es])
                  }
                  _, _ -> a
                }
              }
              Error(_) -> a
            }
          })
        }
        Error(_) -> acc
      }
    })
  Ok(GcResult(removed_count: removed, removed_packages: entries))
}

/// 이름 기반 GC 필터 — only/keep 목록에 따라 제거 대상 여부 판단
fn should_gc_package(
  name_info: Result(#(String, String), Nil),
  policy: GcPolicy,
) -> Bool {
  case name_info {
    Error(_) ->
      // 이름 불명 — only가 지정되면 제외, 아니면 포함
      case policy.only {
        [] -> True
        _ -> False
      }
    Ok(#(name, _)) -> {
      // keep 목록에 있으면 보존
      case list.contains(policy.keep, name) {
        True -> False
        False ->
          // only 목록이 비어있지 않으면 해당 패키지만
          case policy.only {
            [] -> True
            only_list -> list.contains(only_list, name)
          }
      }
    }
  }
}

fn is_expired(stored_at: String, cutoff_seconds: Int) -> Bool {
  case platform.parse_timestamp_to_seconds(stored_at) {
    Ok(ts) -> ts < cutoff_seconds
    Error(_) -> False
  }
}

fn current_unix_seconds() -> Int {
  platform.current_unix_seconds()
}

fn list_dirs(path: String) -> Result(List(String), Nil) {
  simplifile.read_directory(path)
  |> result.replace_error(Nil)
}
