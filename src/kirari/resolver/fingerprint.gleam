//// Config Fingerprint — 의존성 설정의 결정론적 해시 (incremental resolution용)

import gleam/bit_array
import gleam/list
import gleam/string
import kirari/security
import kirari/types.{type KirConfig, type Override}

/// config의 resolution 영향 입력으로부터 SHA256 fingerprint 계산
/// npm_scripts, provenance, license_policy는 pipeline 시점 검사이므로 제외
pub fn compute(config: KirConfig) -> String {
  let lines =
    list.flatten([
      deps_lines("hex", config.hex_deps),
      deps_lines("hex-dev", config.hex_dev_deps),
      deps_lines("npm", config.npm_deps),
      deps_lines("npm-dev", config.npm_dev_deps),
      overrides_lines(config.overrides),
      [exclude_newer_line(config.security.exclude_newer)],
    ])
  let canonical =
    lines
    |> list.sort(string.compare)
    |> string.join("\n")
  security.sha256_hex(bit_array.from_string(canonical))
}

/// 저장된 해시와 현재 config의 fingerprint 비교
pub fn matches(stored_hash: String, config: KirConfig) -> Bool {
  compute(config) == stored_hash
}

// ---------------------------------------------------------------------------
// 내부 헬퍼
// ---------------------------------------------------------------------------

fn deps_lines(prefix: String, deps: List(types.Dependency)) -> List(String) {
  deps
  |> list.map(fn(d) { prefix <> ":" <> d.name <> ":" <> d.version_constraint })
}

fn overrides_lines(overrides: List(Override)) -> List(String) {
  overrides
  |> list.map(fn(o) {
    "override:"
    <> types.registry_to_string(o.registry)
    <> ":"
    <> o.name
    <> ":"
    <> o.version_constraint
  })
}

fn exclude_newer_line(exclude_newer: Result(String, Nil)) -> String {
  case exclude_newer {
    Ok(ts) -> "exclude-newer:" <> ts
    Error(_) -> "exclude-newer:none"
  }
}
