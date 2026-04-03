---
paths:
  - "src/kirari/config*.gleam"
  - "src/kirari/lockfile*.gleam"
  - "src/kirari/export*.gleam"
---

# kir.toml / kir.lock 스키마

## kir.toml 섹션 순서
[package] → [hex] → [hex.dev] → [npm] → [npm.dev] → [security]

## 예시
[hex] 아래에 Hex SemVer: `gleam_stdlib = ">= 0.44.0 and < 2.0.0"`
[npm] 아래에 npm SemVer: `highlight.js = "^11.0.0"`
[security] 아래에 `exclude-newer = "2026-04-01T00:00:00Z"`

## kir.lock
- version 필드 + [[package]] 배열 (name, version, registry, sha256)
- 항상 패키지명 사전순 정렬 (diff 친화적)
- CI: `kir install --frozen` — lock과 불일치 시 실패
