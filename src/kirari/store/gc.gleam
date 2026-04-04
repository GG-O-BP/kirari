//// Store garbage collection — 레지스트리별 보존 정책

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
  GcPolicy(max_age_days: Int)
}

/// GC 실행 결과
pub type GcResult {
  GcResult(removed_count: Int)
}

/// GC 에러
pub type GcError {
  IoError(detail: String)
}

/// Hex 기본 정책: 0 = GC 안 함 (Hex 패키지는 불변)
pub fn hex_default_policy() -> GcPolicy {
  GcPolicy(max_age_days: 0)
}

/// npm 기본 정책: 90일 보존
pub fn npm_default_policy() -> GcPolicy {
  GcPolicy(max_age_days: 90)
}

/// 양쪽 store GC — Hex는 불변이므로 기본 skip, npm만 실행
pub fn gc_all() -> Result(#(GcResult, GcResult), GcError) {
  let hex_result = GcResult(removed_count: 0)
  use npm_result <- result.try(gc_npm(npm_default_policy()))
  Ok(#(hex_result, npm_result))
}

/// Hex store GC — max_age_days=0이면 skip (불변 패키지)
pub fn gc_hex(policy: GcPolicy) -> Result(GcResult, GcError) {
  case policy.max_age_days {
    0 -> Ok(GcResult(removed_count: 0))
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
  Ok(GcResult(removed_count: removed))
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
  Ok(GcResult(removed_count: removed))
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
