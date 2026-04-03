---
paths:
  - "src/kirari/config*.gleam"
  - "src/kirari/lockfile*.gleam"
  - "src/kirari/export*.gleam"
---

# gleam.toml kirari 확장 / kir.lock 스키마

## gleam.toml 섹션 구조
최상위 필드 (name, version 등) → [dependencies] → [dev-dependencies] → [npm-dependencies] → [dev-npm-dependencies] → [security]

## 예시
[dependencies] 아래에 Hex SemVer: `gleam_stdlib = ">= 0.44.0 and < 2.0.0"`
[npm-dependencies] 아래에 npm SemVer: `highlight.js = "^11.0.0"`
[security] 아래에 `exclude-newer = "2026-04-01T00:00:00Z"`

gleam은 [npm-dependencies], [dev-npm-dependencies], [security] 섹션을 무시한다.
gleam.toml이 유일한 설정 파일이다. kir.toml은 존재하지 않는다.

## kir.lock
- version 필드 + [[package]] 배열 (name, version, registry, sha256)
- 항상 패키지명 사전순 정렬 (diff 친화적)
- CI: `kir install --frozen` — lock과 불일치 시 실패
