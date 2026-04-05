---
paths:
  - "src/kirari/config*.gleam"
  - "src/kirari/lockfile*.gleam"
  - "src/kirari/export*.gleam"
  - "src/kirari/license*.gleam"
  - "src/kirari/spdx*.gleam"
  - "src/kirari/resolver/fingerprint.gleam"
---

# gleam.toml kirari 확장 / kir.lock 스키마

## gleam.toml 섹션 구조
최상위 필드 (name, version 등) → [dependencies] → [dev-dependencies] → [npm-dependencies] → [dev-npm-dependencies] → [security]

## 예시
[dependencies] 아래에 Hex SemVer: `gleam_stdlib = ">= 0.44.0 and < 2.0.0"`
[npm-dependencies] 아래에 npm SemVer: `highlight.js = "^11.0.0"`

## [security] 섹션
| 키 | 값 | 기본값 | 설명 |
|----|---|--------|------|
| `exclude-newer` | RFC 3339 timestamp | _(없음)_ | 이 시각 이후 게시 버전 제외 |
| `npm-scripts` | `"deny"`, `"allow"` | `"deny"` | npm 설치 스크립트 허용 여부 |
| `npm-scripts-allow` | string array | `[]` | 스크립트 허용 패키지 목록 (deny 시 예외) |
| `provenance` | `"ignore"`, `"warn"`, `"require"` | `"warn"` | npm Sigstore 서명 검증 정책 |
| `license-allow` | string array | `[]` | 허용 SPDX 라이선스 목록 |
| `license-deny` | string array | `[]` | 금지 SPDX 라이선스 목록 |
| `audit-ignore` | string array | `[]` | kir audit에서 무시할 Advisory ID (GHSA/CVE) |

license-allow와 license-deny는 상호 배타적. 둘 다 지정 시 allow 우선.

gleam은 [npm-dependencies], [dev-npm-dependencies], [security] 섹션을 무시한다.
gleam.toml이 유일한 설정 파일이다. kir.toml은 존재하지 않는다.

## kir.lock
- version 필드 + config-fingerprint 필드 (optional) + [[package]] 배열
- config-fingerprint: config의 resolution 영향 입력 SHA256 (incremental resolution용, 없으면 레거시 lockfile)
- 공통 필드: name, version, registry, sha256
- 조건부 출력: license (비어있지 않을 때), has_scripts (true일 때), os, cpu (있을 때)
- 필드 사전순: cpu, has_scripts, license, name, os, registry, sha256, version
- 항상 패키지명 사전순 정렬 (diff 친화적)
- CI: `kir install --frozen` — lock과 불일치 시 실패
