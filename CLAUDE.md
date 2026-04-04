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
2. 레지스트리별 분리 store — ~/.kir/store/hex/, ~/.kir/store/npm/ 각각 최적화
3. Hex: trust-and-cache (불변 레지스트리, 영구 캐시, 항상 hardlink, CHECKSUM 검증)
4. npm: verify-and-guard (메타데이터 사이드카, 스크립트 정책, 플랫폼 인식, Sigstore 검증)
5. 병렬 다운로드 — gleam/erlang/process 기반, 재시도 3회
6. 결정론적 lockfile — 동일 입력이면 동일 kir.lock 출력, 플랫폼 필드 포함
7. 공급망 보안 기본 강제 — --exclude-newer, SHA256, Hex CHECKSUM, npm SRI integrity, npm Sigstore ECDSA (키 캐시), 스크립트 차단
8. 라이선스 정책 — SPDX 2.3 표현식 파싱, allow-list/deny-list 정책, kir.lock에 license 필드 저장

## 명령어

| 명령어 | 역할 |
|--------|------|
| `kir init` | gleam.toml에 kirari 섹션 추가 + package.json npm 의존성 병합 |
| `kir install [--frozen] [--exclude-newer=TS] [--offline] [--quiet]` | Hex+npm 의존성 해결·다운로드·설치, kir.lock + manifest.toml 생성 |
| `kir update [pkg...]` | lock 무시 전체 재해결, 또는 특정 패키지만 선택적 업데이트 |
| `kir add <pkg[@version]> [--npm] [--dev]` | 의존성 추가 후 자동 install |
| `kir remove <pkg> [--npm]` | 의존성 제거 후 자동 reinstall |
| `kir deps list` | 의존성 목록 출력 |
| `kir deps download` | 의존성 다운로드 (설치 없이) |
| `kir tree` | 전이 의존성 포함 전체 트리 출력 (resolver 실행, 순환 방지) |
| `kir outdated` | 업데이트 가능한 패키지 목록 |
| `kir why <pkg>` | 패키지 설치 이유 (직접/전이 의존성 체인) |
| `kir diff` | lock 변경 내역 미리보기 (update 전후) |
| `kir ls` | 설치된 패키지 목록 + 경로 + 검증 상태 |
| `kir doctor` | 환경 진단 (Erlang, Gleam, store, config, lock) |
| `kir store verify` | 캐시 패키지 무결성 검증 |
| `kir license` | 의존성 라이선스 감사 (SPDX 파싱, allow/deny 정책) |
| `kir audit [--json] [--severity=LEVEL]` | CVE/advisory 취약점 검사 (GHSA + npm audit) |
| `kir clean [--store] [--keep-cache]` | build/ + node_modules/ 삭제, --store로 GC |
| `kir build/run/test/check/dev` | 의존성 동기화 후 gleam 명령어 실행 |
| `kir format/fix/new/shell/lsp` | gleam 명령어 직접 위임 |
| `kir docs build/publish/remove` | gleam docs 위임 |
| `kir publish [--replace] [--yes] [--dry-run]` | Hex 퍼블리시 |
| `kir hex retire/unretire/revert/owner` | Hex 릴리스 관리 (gleam 위임) |
| `kir export` | manifest.toml + packages.toml + package.json 내보내기 |
| `kir export erlang-shipment/hex-tarball/...` | gleam export 위임 |

## 모듈 배치

소스는 src/kirari/ 아래에 모듈별 파일로 배치. 진입점은 src/kirari.gleam.

주요 모듈: cli, config, migrate, lockfile, resolver, pipeline,
registry/hex, registry/npm, tarball, installer,
ffi, security, tree, export, types, platform, semver, spdx, license

cli 서브모듈 (책임별 분리):
- cli.gleam — 라우터 (명령어 등록, glint 디스패치)
- cli/error.gleam — KirError 타입 + format_error
- cli/output.gleam — 색상, 경고 출력, gleam 명령 실행
- cli/install.gleam — 워크플로우 커맨드 (init, install, update, add, remove, clean, publish)
- cli/query.gleam — 조회 커맨드 (outdated, why, diff, ls, doctor, store verify, license)

resolver 서브모듈 (PubGrub 알고리즘):
- resolver.gleam — facade (공개 API, 레지스트리 조회, peer 검증)
- resolver/pubgrub.gleam — PubGrub solver 메인 루프 (unit propagation, decision, conflict resolution)
- resolver/term.gleam — Term, PackageRef, Relation 타입
- resolver/incompatibility.gleam — Incompatibility, 원인 추적, 충돌 설명 생성
- resolver/partial_solution.gleam — PartialSolution (할당, 결정 레벨, 백트래킹)

store 모듈 (레지스트리별 분리):
- store.gleam — 라우터 (hex/npm 위임, 타입 re-export)
- store/types.gleam — StoreError, StoreResult 공유 타입
- store/cas.gleam — CAS 공통 헬퍼 (store_root, has_package, package_path, package_dir)
- store/hex.gleam — Hex 전용 CAS (~/.kir/store/hex/)
- store/npm.gleam — npm 전용 CAS (~/.kir/store/npm/) + .meta 사이드카
- store/metadata.gleam — npm .meta JSON 읽기/쓰기
- store/gc.gleam — GC (Hex: 불변/never expires, npm: 90일 보존)

## Gleam 규칙

- 실패 가능 연산은 Result 반환. panic/todo 금지
- 모듈별 커스텀 에러 타입 정의
- public 함수에 타입 어노테이션 필수
- 내부 불변량 타입은 opaque type
- 타겟: Erlang (BEAM)
