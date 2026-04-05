//// kir lock resolve — git merge conflict 자동 해결
//// gleam.toml에서 처음부터 재해결하여 깨끗한 kir.lock 작성

import gleam/int
import gleam/io
import gleam/list
import gleam/result
import kirari/cli/error.{
  type KirError, ConfigErr, LockErr, ResolveErr, UserError,
}
import kirari/cli/log
import kirari/cli/output
import kirari/config
import kirari/export
import kirari/lockfile
import kirari/resolver
import kirari/resolver/fingerprint
import kirari/types
import simplifile

/// kir lock resolve 메인 — merge conflict 감지 → 재해결 → lockfile 작성
pub fn do_lock_resolve(dir: String, dry_run: Bool) -> Result(Nil, KirError) {
  let lock_path = dir <> "/kir.lock"
  // 1. kir.lock 원본 읽기
  use raw_content <- result.try(
    simplifile.read(lock_path)
    |> result.map_error(fn(_) {
      UserError(detail: "kir.lock not found — run kir install first")
    }),
  )
  // 2. merge conflict marker 감지
  case lockfile.has_merge_conflicts(raw_content) {
    False -> {
      // 충돌 없음 — 정상 lockfile이면 그냥 재해결
      io.println(
        output.color_yellow("Note:")
        <> " no merge conflict markers found in kir.lock",
      )
      io.println("Re-resolving dependencies from gleam.toml...")
    }
    True ->
      io.println("Detected merge conflict markers in kir.lock, re-resolving...")
  }
  // 3. 기존 lock 파싱 시도 (diff용, 실패해도 계속 진행)
  let old_lock = case lockfile.has_merge_conflicts(raw_content) {
    True -> {
      let clean = lockfile.strip_conflict_markers(raw_content)
      lockfile.parse(clean) |> result.map_error(fn(_) { Nil })
    }
    False -> lockfile.parse(raw_content) |> result.map_error(fn(_) { Nil })
  }
  // 4. gleam.toml 읽기
  use cfg <- result.try(
    config.read_config(dir)
    |> result.map_error(ConfigErr),
  )
  // 5. 처음부터 재해결 (기존 lock 무시)
  log.verbose("Running full resolution from gleam.toml...")
  use resolve_result <- result.try(
    resolver.resolve_full(cfg, Error(Nil))
    |> result.map_error(ResolveErr),
  )
  io.println(
    output.color_green("Resolved")
    <> " "
    <> int.to_string(list.length(resolve_result.packages))
    <> " packages",
  )
  // 6. diff 출력
  case old_lock {
    Ok(old) -> {
      let diff_entries = lockfile.diff(old, resolve_result.packages)
      print_diff(diff_entries)
    }
    Error(_) ->
      io.println(output.color_dim(
        "(no diff available — previous lock unparsable)",
      ))
  }
  // 7. lockfile 작성 (dry_run이면 skip)
  let fp = fingerprint.compute(cfg)
  let new_lock =
    lockfile.from_packages_with_fingerprint(resolve_result.packages, fp)
  case dry_run {
    True -> {
      io.println(
        output.color_dim("(dry run) Would write kir.lock with ")
        <> int.to_string(list.length(resolve_result.packages))
        <> " packages",
      )
      Ok(Nil)
    }
    False -> {
      use _ <- result.try(
        lockfile.write(new_lock, dir)
        |> result.map_error(LockErr),
      )
      let _ = export.write_build_metadata(cfg, new_lock, dir)
      io.println(
        output.color_green("Resolved")
        <> " kir.lock written ("
        <> int.to_string(list.length(new_lock.packages))
        <> " packages)",
      )
      Ok(Nil)
    }
  }
}

fn print_diff(entries: List(lockfile.DiffEntry)) -> Nil {
  case entries {
    [] -> io.println(output.color_dim("  (no changes)"))
    _ ->
      list.each(entries, fn(e) {
        case e {
          lockfile.Added(name, version, registry) ->
            io.println(
              output.color_green("  + ")
              <> name
              <> "@"
              <> version
              <> " ("
              <> types.registry_to_string(registry)
              <> ")",
            )
          lockfile.Removed(name, version, registry) ->
            io.println(
              output.color_red("  - ")
              <> name
              <> "@"
              <> version
              <> " ("
              <> types.registry_to_string(registry)
              <> ")",
            )
          lockfile.Changed(name, old_ver, new_ver, registry) ->
            io.println(
              output.color_yellow("  ~ ")
              <> name
              <> " "
              <> old_ver
              <> " → "
              <> new_ver
              <> " ("
              <> types.registry_to_string(registry)
              <> ")",
            )
        }
      })
  }
}
