//// npm .meta 사이드카 — 패키지 메타데이터 JSON 읽기/쓰기

import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import kirari/platform
import simplifile

/// npm 패키지 메타데이터
pub type PackageMetadata {
  PackageMetadata(
    name: String,
    version: String,
    stored_at: String,
    has_scripts: Bool,
    scripts: List(String),
    platform: PlatformInfo,
    bin: List(#(String, String)),
    os: List(String),
    cpu: List(String),
  )
}

/// 저장 시점의 시스템 플랫폼
pub type PlatformInfo {
  PlatformInfo(os: String, arch: String)
}

/// metadata 에러 타입
pub type MetadataError {
  ReadError(detail: String)
  WriteError(detail: String)
  ParseError(detail: String)
}

// ---------------------------------------------------------------------------
// package.json에서 메타데이터 추출
// ---------------------------------------------------------------------------

/// npm package.json 내용에서 메타데이터 추출
pub fn extract_from_package_json(
  content: String,
  name: String,
  version: String,
) -> Result(PackageMetadata, MetadataError) {
  let decoder = {
    use scripts <- decode.optional_field(
      "scripts",
      dict.new(),
      decode.dict(decode.string, decode.string),
    )
    use bin <- decode.optional_field("bin", dict.new(), bin_decoder())
    use os <- decode.optional_field("os", [], decode.list(decode.string))
    use cpu <- decode.optional_field("cpu", [], decode.list(decode.string))
    let script_names = dict.keys(scripts) |> list.sort(string.compare)
    let bin_list =
      dict.to_list(bin)
      |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
    decode.success(#(script_names, bin_list, os, cpu))
  }
  case json.parse(content, decoder) {
    Ok(#(script_names, bin_list, os, cpu)) ->
      Ok(PackageMetadata(
        name: name,
        version: version,
        stored_at: platform.get_current_timestamp(),
        has_scripts: script_names != [],
        scripts: script_names,
        platform: PlatformInfo(
          os: platform.get_platform_os(),
          arch: platform.get_platform_arch(),
        ),
        bin: bin_list,
        os: os,
        cpu: cpu,
      ))
    Error(e) -> Error(ParseError(string.inspect(e)))
  }
}

/// bin 필드 디코더 — string 또는 object 형태 모두 처리
fn bin_decoder() -> decode.Decoder(dict.Dict(String, String)) {
  decode.one_of(decode.dict(decode.string, decode.string), [
    // "bin": "cli.js" 축약형 → {"name": "cli.js"} 로 변환 불가 (이름 필요)
    // 실제로는 package.json의 name이 키가 되지만 여기서는 빈 dict 반환
    decode.map(decode.string, fn(path) { dict.from_list([#("_default", path)]) }),
  ])
}

// ---------------------------------------------------------------------------
// package.json 없을 때 기본 메타데이터
// ---------------------------------------------------------------------------

/// package.json을 읽을 수 없을 때 기본 메타데이터 생성
pub fn default_metadata(name: String, version: String) -> PackageMetadata {
  PackageMetadata(
    name: name,
    version: version,
    stored_at: platform.get_current_timestamp(),
    has_scripts: False,
    scripts: [],
    platform: PlatformInfo(
      os: platform.get_platform_os(),
      arch: platform.get_platform_arch(),
    ),
    bin: [],
    os: [],
    cpu: [],
  )
}

// ---------------------------------------------------------------------------
// JSON 직렬화
// ---------------------------------------------------------------------------

/// 메타데이터를 JSON 문자열로 인코딩
pub fn encode_metadata(meta: PackageMetadata) -> String {
  json.object([
    #("name", json.string(meta.name)),
    #("version", json.string(meta.version)),
    #("stored_at", json.string(meta.stored_at)),
    #("has_scripts", json.bool(meta.has_scripts)),
    #("scripts", json.array(meta.scripts, json.string)),
    #(
      "platform",
      json.object([
        #("os", json.string(meta.platform.os)),
        #("arch", json.string(meta.platform.arch)),
      ]),
    ),
    #(
      "bin",
      json.object(
        list.map(meta.bin, fn(entry) { #(entry.0, json.string(entry.1)) }),
      ),
    ),
    #("os", json.array(meta.os, json.string)),
    #("cpu", json.array(meta.cpu, json.string)),
  ])
  |> json.to_string
}

// ---------------------------------------------------------------------------
// JSON 역직렬화
// ---------------------------------------------------------------------------

/// JSON 문자열에서 메타데이터 디코딩
pub fn decode_metadata(
  json_str: String,
) -> Result(PackageMetadata, MetadataError) {
  let decoder = {
    use name <- decode.field("name", decode.string)
    use version <- decode.field("version", decode.string)
    use stored_at <- decode.field("stored_at", decode.string)
    use has_scripts <- decode.field("has_scripts", decode.bool)
    use scripts <- decode.optional_field(
      "scripts",
      [],
      decode.list(decode.string),
    )
    use plat <- decode.field("platform", platform_decoder())
    use bin <- decode.optional_field(
      "bin",
      dict.new(),
      decode.dict(decode.string, decode.string),
    )
    use os <- decode.optional_field("os", [], decode.list(decode.string))
    use cpu <- decode.optional_field("cpu", [], decode.list(decode.string))
    let bin_list =
      dict.to_list(bin)
      |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
    decode.success(PackageMetadata(
      name: name,
      version: version,
      stored_at: stored_at,
      has_scripts: has_scripts,
      scripts: scripts,
      platform: plat,
      bin: bin_list,
      os: os,
      cpu: cpu,
    ))
  }
  json.parse(json_str, decoder)
  |> result.map_error(fn(e) { ParseError(string.inspect(e)) })
}

fn platform_decoder() -> decode.Decoder(PlatformInfo) {
  use os <- decode.field("os", decode.string)
  use arch <- decode.field("arch", decode.string)
  decode.success(PlatformInfo(os: os, arch: arch))
}

// ---------------------------------------------------------------------------
// 파일 I/O
// ---------------------------------------------------------------------------

/// 메타데이터를 파일에 쓰기
pub fn write_metadata(
  meta: PackageMetadata,
  meta_path: String,
) -> Result(Nil, MetadataError) {
  let content = encode_metadata(meta)
  simplifile.write(meta_path, content)
  |> result.map_error(fn(e) { WriteError(simplifile.describe_error(e)) })
}

/// 파일에서 메타데이터 읽기
pub fn read_metadata(
  meta_path: String,
) -> Result(PackageMetadata, MetadataError) {
  use content <- result.try(
    simplifile.read(meta_path)
    |> result.map_error(fn(e) { ReadError(simplifile.describe_error(e)) }),
  )
  decode_metadata(content)
}
