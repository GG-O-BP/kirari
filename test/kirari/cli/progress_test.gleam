//// 진행률 표시 모듈 단위 테스트

import gleeunit
import kirari/cli/progress

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// format_bytes
// ---------------------------------------------------------------------------

pub fn format_bytes_zero_test() {
  let assert "0 B" = progress.format_bytes(0)
}

pub fn format_bytes_small_test() {
  let assert "512 B" = progress.format_bytes(512)
}

pub fn format_bytes_kb_test() {
  let assert "10 KB" = progress.format_bytes(10_240)
}

pub fn format_bytes_mb_test() {
  let assert "1.0 MB" = progress.format_bytes(1_048_576)
}

pub fn format_bytes_large_mb_test() {
  let assert "5.2 MB" = progress.format_bytes(5_500_000)
}

// ---------------------------------------------------------------------------
// format_bar
// ---------------------------------------------------------------------------

pub fn format_bar_empty_test() {
  let bar = progress.format_bar(0, 10, 20)
  let assert "[" <> _ = bar
}

pub fn format_bar_full_test() {
  let bar = progress.format_bar(10, 10, 20)
  let assert "[" <> _ = bar
}

pub fn format_bar_half_test() {
  let bar = progress.format_bar(5, 10, 20)
  let assert "[" <> _ = bar
}

pub fn format_bar_zero_total_test() {
  let bar = progress.format_bar(0, 0, 20)
  let assert "[" <> _ = bar
}

// ---------------------------------------------------------------------------
// ProgressHandle — Inactive는 이벤트 무시
// ---------------------------------------------------------------------------

pub fn inactive_send_no_crash_test() {
  progress.send(progress.Inactive, progress.Started("test", "1.0.0"))
  progress.send(progress.Inactive, progress.Complete("test", "1.0.0", 1024))
  progress.send(progress.Inactive, progress.Failed("test", "1.0.0"))
  progress.send(progress.Inactive, progress.Cached("test", "1.0.0"))
  progress.stop(progress.Inactive)
}

// ---------------------------------------------------------------------------
// start + stop — quiet 모드
// ---------------------------------------------------------------------------

pub fn quiet_mode_returns_inactive_test() {
  let handle =
    progress.start(progress.ProgressConfig(
      total_packages: 10,
      quiet: True,
      no_color: True,
    ))
  let assert progress.Inactive = handle
}

pub fn zero_packages_returns_inactive_test() {
  let handle =
    progress.start(progress.ProgressConfig(
      total_packages: 0,
      quiet: False,
      no_color: True,
    ))
  let assert progress.Inactive = handle
}
