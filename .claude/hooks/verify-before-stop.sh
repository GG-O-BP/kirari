#!/bin/bash
# Stop hook: kir check 타입 검증 + 무한루프 방지

INPUT=$(cat)

# 무한루프 방지: stop_hook_active가 true면 즉시 통과
if echo "$INPUT" | grep -q '"stop_hook_active".*true'; then
  exit 0
fi

# kir check 시도, 실패 시 gleam check 폴백
OUTPUT=$(kir check 2>&1 || gleam check 2>&1)
if [ $? -ne 0 ]; then
  echo "$OUTPUT" >&2
  echo "kir check 실패. 타입 에러를 수정해주세요." >&2
  exit 2
fi

exit 0
