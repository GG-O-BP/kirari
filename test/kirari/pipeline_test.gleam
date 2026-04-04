import gleam/dict
import gleam/list
import gleeunit
import kirari/pipeline
import kirari/platform
import kirari/resolver.{ResolveResult}
import kirari/security
import kirari/store
import kirari/types.{Hex, ResolvedPackage}
import simplifile

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
      has_scripts: False,
      platform: Error(Nil),
      license: "",
    )
  let resolve_result = ResolveResult(packages: [pkg], version_infos: dict.new())
  let security = types.default_security_config()
  // pipeline.run은 이미 store에 있으므로 다운로드 없이 성공
  let assert Ok(result) =
    pipeline.run(resolve_result, test_project_dir(), security)
  assert list.length(result.packages) == 1
  let assert [p] = result.packages
  assert p.sha256 == hash
  // 정리
  let _ = simplifile.delete(test_project_dir())
}

// ---------------------------------------------------------------------------
// 빈 패키지 목록
// ---------------------------------------------------------------------------

pub fn run_empty_packages_test() {
  let resolve_result = ResolveResult(packages: [], version_infos: dict.new())
  let security = types.default_security_config()
  let assert Ok(result) =
    pipeline.run(resolve_result, test_project_dir(), security)
  assert result.packages == []
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

@external(erlang, "kirari_test_ffi", "create_hex_test_tarball")
fn create_hex_test_tarball() -> BitArray
