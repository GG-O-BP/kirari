import gleam/list
import gleeunit
import kirari/store/metadata.{PackageMetadata, PlatformInfo}

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// encode/decode 왕복
// ---------------------------------------------------------------------------

pub fn encode_decode_roundtrip_test() {
  let meta =
    PackageMetadata(
      name: "esbuild",
      version: "0.21.5",
      stored_at: "2026-04-04T09:00:00Z",
      has_scripts: True,
      scripts: ["postinstall"],
      platform: PlatformInfo(os: "win32", arch: "x64"),
      bin: [#("esbuild", "bin/esbuild")],
      os: ["win32", "linux"],
      cpu: ["x64"],
    )
  let encoded = metadata.encode_metadata(meta)
  let assert Ok(decoded) = metadata.decode_metadata(encoded)
  assert decoded.name == "esbuild"
  assert decoded.version == "0.21.5"
  assert decoded.has_scripts == True
  assert decoded.scripts == ["postinstall"]
  assert decoded.platform.os == "win32"
  assert decoded.platform.arch == "x64"
  assert decoded.bin == [#("esbuild", "bin/esbuild")]
  assert decoded.os == ["win32", "linux"]
  assert decoded.cpu == ["x64"]
}

// ---------------------------------------------------------------------------
// package.json with scripts
// ---------------------------------------------------------------------------

pub fn extract_with_scripts_test() {
  let json =
    "{
    \"name\": \"esbuild\",
    \"version\": \"0.21.5\",
    \"scripts\": { \"postinstall\": \"node install.js\" },
    \"bin\": { \"esbuild\": \"bin/esbuild\" },
    \"os\": [\"linux\", \"darwin\"],
    \"cpu\": [\"x64\", \"arm64\"]
  }"
  let assert Ok(meta) =
    metadata.extract_from_package_json(json, "esbuild", "0.21.5")
  assert meta.has_scripts == True
  assert meta.scripts == ["postinstall"]
  assert meta.bin == [#("esbuild", "bin/esbuild")]
  assert meta.os == ["linux", "darwin"]
  assert meta.cpu == ["x64", "arm64"]
}

// ---------------------------------------------------------------------------
// package.json without scripts
// ---------------------------------------------------------------------------

pub fn extract_without_scripts_test() {
  let json =
    "{
    \"name\": \"lodash\",
    \"version\": \"4.17.21\"
  }"
  let assert Ok(meta) =
    metadata.extract_from_package_json(json, "lodash", "4.17.21")
  assert meta.has_scripts == False
  assert meta.scripts == []
  assert meta.bin == []
  assert meta.os == []
  assert meta.cpu == []
}

// ---------------------------------------------------------------------------
// bin이 string일 때
// ---------------------------------------------------------------------------

pub fn extract_bin_string_test() {
  let json =
    "{
    \"name\": \"cowsay\",
    \"version\": \"1.0.0\",
    \"bin\": \"./cli.js\"
  }"
  let assert Ok(meta) =
    metadata.extract_from_package_json(json, "cowsay", "1.0.0")
  assert list.length(meta.bin) == 1
}

// ---------------------------------------------------------------------------
// 기본 메타데이터
// ---------------------------------------------------------------------------

pub fn default_metadata_test() {
  let meta = metadata.default_metadata("test", "1.0.0")
  assert meta.name == "test"
  assert meta.has_scripts == False
  assert meta.bin == []
  assert meta.stored_at != ""
}

// ---------------------------------------------------------------------------
// 파일 I/O 왕복
// ---------------------------------------------------------------------------

pub fn write_read_roundtrip_test() {
  let meta =
    PackageMetadata(
      name: "test-pkg",
      version: "2.0.0",
      stored_at: "2026-04-04T10:00:00Z",
      has_scripts: False,
      scripts: [],
      platform: PlatformInfo(os: "linux", arch: "x64"),
      bin: [],
      os: [],
      cpu: [],
    )
  let path = test_meta_path()
  let assert Ok(Nil) = metadata.write_metadata(meta, path)
  let assert Ok(read_back) = metadata.read_metadata(path)
  assert read_back.name == "test-pkg"
  assert read_back.version == "2.0.0"
  assert read_back.has_scripts == False
  // 정리
  let _ = simplifile.delete(path)
}

import kirari/platform
import simplifile

fn test_meta_path() -> String {
  case platform.get_home_dir() {
    Ok(home) -> home <> "/.kir/test-metadata-tmp.meta"
    Error(_) -> "/tmp/test-metadata-tmp.meta"
  }
}
