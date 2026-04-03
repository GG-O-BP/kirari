import gleam/dict
import gleam/list
import gleeunit
import kirari/pipeline
import kirari/resolver.{ResolveResult}
import kirari/security
import kirari/store
import kirari/types.{Hex, ResolvedPackage}

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// store에 이미 있는 패키지는 skip
// ---------------------------------------------------------------------------

pub fn run_skips_cached_packages_test() {
  // 실제 tarball을 store에 넣고, 같은 sha256으로 pipeline 실행
  let data = create_hex_test_tarball()
  let hash = security.sha256_hex(data)
  let assert Ok(_) = store.store_package(data, hash, "cached", "1.0.0", Hex)
  let pkg =
    ResolvedPackage(
      name: "cached",
      version: "1.0.0",
      registry: Hex,
      sha256: hash,
    )
  let resolve_result = ResolveResult(packages: [pkg], version_infos: dict.new())
  // pipeline.run은 이미 store에 있으므로 다운로드 없이 성공
  let assert Ok(installed) = pipeline.run(resolve_result, test_project_dir())
  assert list.length(installed) == 1
  let assert [p] = installed
  assert p.sha256 == hash
  // 정리
  let _ = simplifile.delete(test_project_dir())
}

// ---------------------------------------------------------------------------
// 빈 패키지 목록
// ---------------------------------------------------------------------------

pub fn run_empty_packages_test() {
  let resolve_result = ResolveResult(packages: [], version_infos: dict.new())
  let assert Ok(installed) = pipeline.run(resolve_result, test_project_dir())
  assert installed == []
  let _ = simplifile.delete(test_project_dir())
}

// ---------------------------------------------------------------------------
// 헬퍼
// ---------------------------------------------------------------------------

fn test_project_dir() -> String {
  case platform.get_home_dir() {
    Ok(home) -> home <> "/.kir/test-pipeline-project"
    Error(_) -> "/tmp/test-pipeline-project"
  }
}

import kirari/platform
import simplifile

@external(erlang, "kirari_test_ffi", "create_hex_test_tarball")
fn create_hex_test_tarball() -> BitArray
