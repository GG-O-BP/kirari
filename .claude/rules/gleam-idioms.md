---
paths:
  - "src/**/*.gleam"
---

# Gleam 이디엄

## 에러 체이닝
Result 중첩 2단계 이상이면 use + result.try로 플래트하게 작성.

## 꼬리 호출
재귀 함수는 accumulator 패턴 필수. public 함수에서 숨긴다.

## opaque type
내부 불변량이 있는 타입은 opaque + smart constructor로 보호.

## 에러 타입
모듈별 전용 에러 타입. 문자열 에러 금지. 하위→상위 에러 변환은 result.map_error.

## 파이프라인
함수의 첫 인자를 subject로 설계하여 |> 친화적으로 만든다.
