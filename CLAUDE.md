# Kirari — Gleam 통합 패키지 매니저

gleam.toml 하나로 Hex와 npm 의존성을 단일 워크플로우로 관리. Gleam으로 작성.
CLI 명령어는 `kir`. 프로그램 자체를 지칭할 때는 kirari.

gleam.toml에 kirari 전용 섹션([npm-dependencies], [dev-npm-dependencies], [overrides], [npm-overrides], [security])을 추가.
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
9. incremental resolution — config fingerprint(SHA256)를 kir.lock에 저장, 변경 없으면 resolution 건너뜀 (3-tier: SkipAll/InstallOnly/FullResolve)
10. 충돌 분석 — PubGrub 실패 시 incompatibility tree DFS → 구조화된 원인 + 구체적 대안 제안 (ConflictReport)
11. npm dist-tags — @latest, @next 등 CLI 시점 해결 + resolver 사전 해결
12. 패키지 무결성 매니페스트 — store_package 시 .kir-manifest 생성, kir store verify로 파일 단위 SHA256 재검증
13. JSON 출력 — 8개 query 명령에 --json 플래그, CI/CD 파이프라인 통합
14. 셸 자동완성 — kir completion bash|zsh|fish, 전체 명령 트리 + 플래그 포함
15. HTTP 304 캐싱 — ETag/Last-Modified 기반 조건부 요청, ~/.kir/cache/registry/ 캐시, 네트워크 실패 시 폴백, kir update 시 캐시 무시
16. 다운로드 진행률 — Erlang process 액터 기반, 패키지 단위 진행 바, 속도 표시, NO_COLOR/--quiet 대응
17. dev 전이 의존성 격리 — production 루트 BFS 도달성 분류, ResolvedPackage.dev 필드, kir.lock/tree에 dev 표시
18. 오프라인 모드 — --offline 플래그, resolver/pipeline 전체 관통, 레지스트리 캐시에서만 해결, store 캐시에서만 설치
19. 병렬 레지스트리 조회 — 직접 의존성 Erlang process 병렬 prefetch, PubGrub solver version_cache 워밍업
20. 구조화된 로깅 — --verbose/--debug 플래그, persistent_term 기반 4단계 로그 (Silent/Normal/Verbose/Debug), KIR_LOG 환경변수, lazy 메시지 평가
21. lockfile 버전 마이그레이션 — lock_version 상수(현재 2), 순차 마이그레이션 체인, 미래 버전 거부, frozen 모드 검증
22. engines 필드 — gleam.toml [engines] 섹션, Gleam/Erlang/Node.js 런타임 버전 감지 + semver 제약 검증, install 전 검사
23. 다운로드 파이프라인 설정 — DownloadConfig 타입, [security] max-retries/timeout/parallel/backoff, CLI 플래그 오버라이드, 배치 단위 병렬화
24. 선택적 store 정리 — kir clean --store에 --dry-run/--only/--keep/--max-age, 이름 기반 GC 필터링, lockfile SHA256→name 매핑
25. Git merge conflict 자동 해결 — kir lock resolve, merge marker 감지/제거, gleam.toml에서 재해결, diff 출력

## 명령어

| 명령어 | 역할 |
|--------|------|
| `kir init` | gleam.toml에 kirari 섹션 추가 + package.json npm 의존성 병합 |
| `kir install [--frozen] [--exclude-newer=TS] [--offline] [--quiet] [--verify]` | Hex+npm 의존성 해결·다운로드·설치, kir.lock + manifest.toml 생성 |
| `kir update [pkg...]` | lock 무시 전체 재해결, 또는 특정 패키지만 선택적 업데이트 |
| `kir add <pkg[@version]> [--npm] [--dev]` | 의존성 추가 후 자동 install |
| `kir remove <pkg> [--npm]` | 의존성 제거 후 자동 reinstall |
| `kir deps list [--json]` | 의존성 목록 출력 |
| `kir deps download` | 의존성 다운로드 (설치 없이) |
| `kir tree [--json]` | 전이 의존성 포함 전체 트리 출력 (resolver 실행, 순환 방지) |
| `kir outdated [--json]` | 업데이트 가능한 패키지 목록 |
| `kir why <pkg> [--json]` | 패키지 설치 이유 (직접/전이 의존성 체인) |
| `kir diff [--json]` | lock 변경 내역 미리보기 (update 전후) |
| `kir ls [--json]` | 설치된 패키지 목록 + 경로 + 검증 상태 |
| `kir doctor` | 환경 진단 (Erlang, Gleam, store, config, lock) |
| `kir store verify [--quick] [--json]` | 캐시 패키지 무결성 검증 (.kir-manifest SHA256 재해싱) |
| `kir license [--json]` | 의존성 라이선스 감사 (SPDX 파싱, allow/deny 정책) |
| `kir audit [--json] [--severity=LEVEL]` | CVE/advisory 취약점 검사 (GHSA + npm audit) |
| `kir clean [--store] [--keep-cache]` | build/ + node_modules/ 삭제, --store로 GC |
| `kir build/run/test/check/dev` | 의존성 동기화 후 gleam 명령어 실행 |
| `kir format/fix/new/shell/lsp` | gleam 명령어 직접 위임 |
| `kir docs build/publish/remove` | gleam docs 위임 |
| `kir publish [--replace] [--yes] [--dry-run]` | Hex 퍼블리시 |
| `kir hex retire/unretire/revert/owner` | Hex 릴리스 관리 (gleam 위임) |
| `kir export` | manifest.toml + packages.toml + package.json 내보내기 |
| `kir export sbom [--format=spdx\|cyclonedx] [--output=FILE]` | SBOM 내보내기 |
| `kir export erlang-shipment/hex-tarball/...` | gleam export 위임 |
| `kir completion bash\|zsh\|fish` | 셸 자동완성 스크립트 생성 |

## 모듈 배치

소스는 src/kirari/ 아래에 모듈별 파일로 배치. 진입점은 src/kirari.gleam.

주요 모듈: cli, config, migrate, lockfile, resolver, pipeline,
registry/hex, registry/npm, registry/cache, tarball, installer,
ffi, security, tree, export, types, platform, semver, spdx, license,
completion, sbom, audit

cli 서브모듈 (책임별 분리):
- cli.gleam — 라우터 (명령어 등록, glint 디스패치)
- cli/error.gleam — KirError 타입 + format_error
- cli/output.gleam — 색상, 경고 출력, gleam 명령 실행
- cli/install.gleam — 워크플로우 커맨드 (init, install, update, add, remove, clean, publish)
- cli/query.gleam — 조회 커맨드 (outdated, why, diff, ls, doctor, store verify, license)
- cli/progress.gleam — 다운로드 진행률 액터 (Erlang process 기반, 패키지 단위)

resolver 서브모듈 (PubGrub 알고리즘):
- resolver.gleam — facade (공개 API, 레지스트리 조회, peer 검증, dist-tag 사전 해결)
- resolver/pubgrub.gleam — PubGrub solver 메인 루프 (unit propagation, decision, conflict resolution)
- resolver/term.gleam — Term, PackageRef, Relation 타입
- resolver/incompatibility.gleam — Incompatibility, 원인 추적, 충돌 설명 생성
- resolver/partial_solution.gleam — PartialSolution (할당, 결정 레벨, 백트래킹)
- resolver/fingerprint.gleam — config fingerprint (SHA256), incremental resolution 변경 감지
- resolver/conflict.gleam — 충돌 분석 (DFS, ConflictReport, 대안 제안)

store 모듈 (레지스트리별 분리):
- store.gleam — 라우터 (hex/npm 위임, 타입 re-export)
- store/types.gleam — StoreError, StoreResult 공유 타입
- store/cas.gleam — CAS 공통 헬퍼 (store_root, has_package, package_path, package_dir)
- store/hex.gleam — Hex 전용 CAS (~/.kir/store/hex/)
- store/npm.gleam — npm 전용 CAS (~/.kir/store/npm/) + .meta 사이드카
- store/metadata.gleam — npm .meta JSON 읽기/쓰기
- store/gc.gleam — GC (Hex: 불변/never expires, npm: 90일 보존)
- store/manifest.gleam — 패키지 무결성 매니페스트 (.kir-manifest, 파일 단위 SHA256)

## Gleam 규칙

- 실패 가능 연산은 Result 반환. panic/todo 금지
- 모듈별 커스텀 에러 타입 정의
- public 함수에 타입 어노테이션 필수
- 내부 불변량 타입은 opaque type
- 타겟: Erlang (BEAM)
