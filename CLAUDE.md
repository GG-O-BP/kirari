# Kirari — Gleam 통합 패키지 매니저

gleam.toml 하나로 Hex와 npm 의존성을 단일 워크플로우로 관리. Gleam으로 작성.
CLI 명령어는 `kir`. 프로그램 자체를 지칭할 때는 kirari.

gleam.toml에 kirari 전용 섹션([npm-dependencies], [dev-npm-dependencies], [security])을 추가.
gleam 컴파일러는 이 섹션들을 무시하므로 gleam build와 완전 호환.
kir.toml은 존재하지 않는다.

## 빌드

- 빌드: `kir build`
- 테스트: `kir test`
- 타입 체크: `kir check`
- 포맷: `kir format`
- 의존성 설치: `kir install`

코드 변경 후 `kir check && kir test` 반드시 실행.

## 설계 원칙

1. gleam.toml이 유일한 정본 — manifest.toml, packages.toml은 자동 생성 산출물
2. content-addressable store (~/.kir/store) — SHA256 기반, 하드링크 설치
3. 병렬 다운로드 — gleam/erlang/process 기반, 재시도 3회
4. 결정론적 lockfile — 동일 입력이면 동일 kir.lock 출력
5. 공급망 보안 기본 강제 — --exclude-newer, SHA256 해시 검증

## 명령어

| 명령어 | 역할 |
|--------|------|
| `kir init` | gleam.toml에 kirari 섹션 추가 + package.json npm 의존성 병합 |
| `kir install [--frozen] [--exclude-newer=TS]` | Hex+npm 의존성 해결·다운로드·설치, kir.lock + manifest.toml 생성 |
| `kir update` | lock 무시, 전체 재해결·재설치 |
| `kir add <pkg> [--npm] [--dev]` | 의존성 추가 후 자동 install |
| `kir remove <pkg> [--npm]` | 의존성 제거 후 자동 reinstall |
| `kir deps list` | 의존성 목록 출력 |
| `kir deps download` | 의존성 다운로드 (설치 없이) |
| `kir tree` | 통합 의존성 트리 출력 |
| `kir clean` | build/ + node_modules/ 삭제 |
| `kir build/run/test/check/dev` | 의존성 동기화 후 gleam 명령어 실행 |
| `kir format/fix/new/shell/lsp` | gleam 명령어 직접 위임 |
| `kir docs build/publish/remove` | gleam docs 위임 |
| `kir publish [--replace] [--yes]` | Hex 퍼블리시 |
| `kir hex retire/unretire` | Hex 릴리스 관리 (gleam 위임) |
| `kir export` | manifest.toml + packages.toml + package.json 내보내기 |
| `kir export erlang-shipment/hex-tarball/...` | gleam export 위임 |

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
