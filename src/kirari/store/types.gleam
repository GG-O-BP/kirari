//// Store 공유 타입 — 순환 의존성 방지를 위해 별도 모듈

/// store 모듈 전용 에러 타입
pub type StoreError {
  HomeNotFound(detail: String)
  HashMismatch(expected: String, actual: String)
  ExtractError(detail: String)
  IoError(detail: String)
  PathTraversalError(path: String)
}

/// store_package 반환 타입 — 레지스트리별 메타데이터 포함
pub type StoreResult {
  StoreResult(path: String, has_scripts: Bool, bin: List(#(String, String)))
}
