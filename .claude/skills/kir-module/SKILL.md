---
name: kir-module
description: 새 Gleam 모듈과 테스트 스캐폴딩
argument-hint: "<모듈명>"
disable-model-invocation: true
allowed-tools: Read Write Bash Glob
---

# 새 모듈 생성

$ARGUMENTS 이름으로 모듈과 테스트를 생성.

1. src/kirari/ 아래에 모듈명.gleam 생성 — 모듈 문서 주석, 커스텀 에러 타입, public 함수 스텁
2. test/kirari/ 아래에 모듈명_test.gleam 생성 — gleeunit + 기본 테스트
3. `kir build`로 컴파일 확인
