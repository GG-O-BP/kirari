# Kirari — Gleam 통합 패키지 매니저

gleam.toml + package.json을 kir.toml 하나로 대체.
Hex와 npm 의존성을 단일 워크플로우로 관리. Gleam으로 작성.
CLI 명령어는 `kir`. 프로그램 자체를 지칭할 때는 kirari.

## 빌드

- 빌드: `gleam build`
- 테스트: `gleam test`
- 타입 체크: `gleam check`
- 포맷: `gleam format`
- 실행: `gleam run`

코드 변경 후 `gleam check && gleam test` 반드시 실행.

## 설계 원칙

1. kir.toml이 유일한 정본 — gleam.toml/package.json/manifest.toml은 자동 생성 산출물
2. content-addressable store (~/.kir/store) — SHA256 기반, 하드링크 설치
3. 병렬 다운로드 — gleam/erlang/process 기반, 재시도 3회
4. 결정론적 lockfile — 동일 입력이면 동일 kir.lock 출력
5. 공급망 보안 기본 강제 — --exclude-newer, SHA256 해시 검증

## 명령어

| 명령어 | 역할 |
|--------|------|
| `kir init` | gleam.toml + package.json → kir.toml 마이그레이션 |
| `kir install [--frozen] [--exclude-newer=TS]` | Hex+npm 의존성 해결·다운로드·설치, kir.lock + gleam.toml + manifest.toml 생성 |
| `kir update` | lock 무시, 전체 재해결·재설치 |
| `kir add <pkg> [--npm] [--dev]` | 의존성 추가 후 자동 install |
| `kir remove <pkg> [--npm]` | 의존성 제거 후 자동 reinstall |
| `kir tree` | 통합 의존성 트리 출력 |
| `kir export` | kir.toml → gleam.toml + package.json + manifest.toml 내보내기 |

## 모듈 배치

소스는 src/kirari/ 아래에 모듈별 파일로 배치. 진입점은 src/kirari.gleam.

주요 모듈: cli, config, migrate, lockfile, resolver, pipeline,
registry/hex, registry/npm, store, tarball, installer,
ffi, security, tree, export, types, platform, semver

## Gleam 규칙

- 실패 가능 연산은 Result 반환. panic/todo 금지
- 모듈별 커스텀 에러 타입 정의
- public 함수에 타입 어노테이션 필수
- 내부 불변량 타입은 opaque type
- 타겟: Erlang (BEAM)
