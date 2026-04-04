---
paths:
  - "src/kirari/security*.gleam"
  - "src/kirari/store/**/*.gleam"
  - "src/kirari/store.gleam"
  - "src/kirari/tarball.gleam"
  - "src/kirari/installer.gleam"
---

# 공급망 보안

## 해시 검증
- 모든 다운로드 tarball에 SHA256 → kir.lock 기록과 대조. 불일치 시 즉시 중단
- 해시 비교는 상수 시간 (타이밍 공격 방지)

## Hex CHECKSUM 검증
- Hex tarball 내부의 CHECKSUM 파일을 contents.tar.gz의 SHA256과 대조
- CHECKSUM 없는 구버전 tarball은 건너뛰기 (graceful fallback)

## npm SRI integrity 검증
- npm dist.integrity 필드 파싱 (sha512-... 또는 sha256-...)
- 다운로드된 tarball과 대조, 불일치 시 즉시 중단
- 빈 문자열이면 건너뛰기

## npm Sigstore 서명 검증
- npm registry의 dist.signatures 파싱 (keyid + sig)
- ECDSA 서명 검증은 FFI (Erlang public_key 모듈)
- 공개 키는 npm registry keys 엔드포인트에서 조회, ~/.kir/cache/npm-keys.json에 7일 TTL 캐시
- provenance 정책: ignore | warn (기본) | require
- pipeline에서 다운로드 후 store 전에 검증 수행
- require: 서명 없거나 검증 실패 시 설치 중단
- warn: 경고 출력 후 계속 진행

## npm 스크립트 정책
- SecurityConfig.npm_scripts: DenyAll (기본) | AllowAll | AllowList
- has_scripts=True + DenyAll → Copy 모드 설치 (store 원본 보호)
- has_scripts=True + AllowList → 허용 목록에 있으면 스크립트 실행 가능

## 설치 전략과 보안
- Hex: 항상 hardlink (불변 소스, 스크립트 없음)
- npm has_scripts=False: hardlink (안전)
- npm has_scripts=True: copy (스크립트가 store 원본 오염 방지)

## exclude-newer
- 지정 시각 이후 게시 버전을 해결 후보에서 제외

## 플랫폼 필터링
- npm 패키지의 os/cpu 필드로 현재 플랫폼에 맞지 않는 버전 제외
- "!" prefix는 제외 목록 (e.g., "!win32")

## 파일 안전
- tarball 추출 시 path traversal 거부 (../../)
- 임시 파일은 store와 같은 파티션 (원자적 rename)
- bin: Unix는 심볼릭 링크 + chmod 755, Windows는 .cmd wrapper 생성
- bin 심볼릭 링크는 node_modules/.bin/ 내부로만 생성
