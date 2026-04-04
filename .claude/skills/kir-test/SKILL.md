---
name: kir-test
description: 테스트 실행 및 실패 분석
argument-hint: "[모듈명 또는 비워두면 전체]"
allowed-tools: Read Grep Bash
---

# 테스트 실행

1. `kir check` — 타입 체크
2. `kir test` — 전체 테스트 ($ARGUMENTS가 있으면 해당 모듈만)
3. 실패 시 테스트 코드와 소스를 읽고 원인 분석 및 수정 제안

보고: 전체 N개 | 성공 N개 | 실패 N개 + 실패 분석
