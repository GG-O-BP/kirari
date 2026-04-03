---
paths:
  - "src/kirari/security*.gleam"
  - "src/kirari/store*.gleam"
---

# 공급망 보안

## 해시 검증
- 모든 다운로드 tarball에 SHA256 → kir.lock 기록과 대조. 불일치 시 즉시 중단
- 해시 비교는 상수 시간 (타이밍 공격 방지)

## exclude-newer
- 지정 시각 이후 게시 버전을 해결 후보에서 제외

## 파일 안전
- tarball 추출 시 path traversal 거부 (../../)
- 임시 파일은 store와 같은 파티션 (원자적 rename)
- 심볼릭 링크 추종 금지
