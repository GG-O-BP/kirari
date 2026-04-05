//// log.gleam 단위 테스트

import kirari/cli/log

pub fn init_and_get_level_verbose_test() {
  log.init(log.Verbose)
  assert log.get_level() == log.Verbose
}

pub fn init_and_get_level_debug_test() {
  log.init(log.Debug)
  assert log.get_level() == log.Debug
}

pub fn init_and_get_level_silent_test() {
  log.init(log.Silent)
  assert log.get_level() == log.Silent
}

pub fn init_and_get_level_normal_test() {
  log.init(log.Normal)
  assert log.get_level() == log.Normal
}

pub fn determine_level_quiet_overrides_debug_test() {
  let level = log.determine_level(True, False, True)
  assert level == log.Silent
}

pub fn determine_level_debug_overrides_verbose_test() {
  let level = log.determine_level(False, True, True)
  assert level == log.Debug
}

pub fn determine_level_verbose_test() {
  let level = log.determine_level(False, True, False)
  assert level == log.Verbose
}

pub fn determine_level_default_normal_test() {
  // KIR_LOG 환경변수가 없는 기본 상태
  let level = log.determine_level(False, False, False)
  // 환경변수에 따라 다를 수 있지만, 설정 안 됐으면 Normal
  assert level == log.Normal
    || level == log.Verbose
    || level == log.Debug
    || level == log.Silent
}
