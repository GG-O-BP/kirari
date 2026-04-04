//// npm 레지스트리 API 클라이언트

import gleam/dict
import gleam/dynamic/decode
import gleam/http/request
import gleam/httpc
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import kirari/security

/// npm 레지스트리 에러 타입
pub type NpmError {
  PackageNotFound(name: String)
  ApiError(status: Int, body: String)
  NetworkError(detail: String)
  ParseResponseError(detail: String)
}

/// npm 패키지의 한 버전 정보
pub type NpmPackageVersion {
  NpmPackageVersion(
    version: String,
    published_at: String,
    tarball_url: String,
    dependencies: List(NpmDependency),
    os: List(String),
    cpu: List(String),
    has_scripts: Bool,
    signatures: List(NpmSignature),
    integrity: String,
  )
}

/// npm 의존성 항목
pub type NpmDependency {
  NpmDependency(name: String, constraint: String)
}

/// npm 레지스트리 서명 (Sigstore)
pub type NpmSignature {
  NpmSignature(keyid: String, sig: String)
}

// ---------------------------------------------------------------------------
// API 호출
// ---------------------------------------------------------------------------

/// 패키지의 모든 버전 정보를 npm registry에서 조회
pub fn get_versions(name: String) -> Result(List(NpmPackageVersion), NpmError) {
  let encoded_name = encode_package_name(name)
  let url = "https://registry.npmjs.org/" <> encoded_name
  use req <- result.try(
    request.to(url)
    |> result.map_error(fn(_) { NetworkError("invalid URL: " <> url) }),
  )
  let req =
    request.set_header(req, "accept", "application/vnd.npm.install-v1+json")
  use resp <- result.try(
    httpc.send(req)
    |> result.map_error(fn(e) { NetworkError(string.inspect(e)) }),
  )
  case resp.status {
    200 -> parse_versions_response(resp.body)
    404 -> Error(PackageNotFound(name))
    status -> Error(ApiError(status, resp.body))
  }
}

/// tarball을 다운로드하고 SHA256 해시를 함께 반환
pub fn download_tarball(
  name: String,
  version: String,
  tarball_url: String,
) -> Result(#(BitArray, String), NpmError) {
  use req <- result.try(
    request.to(tarball_url)
    |> result.map_error(fn(_) { NetworkError("invalid URL: " <> tarball_url) }),
  )
  use resp <- result.try(
    httpc.send_bits(
      req
      |> request.set_body(<<>>),
    )
    |> result.map_error(fn(e) { NetworkError(string.inspect(e)) }),
  )
  case resp.status {
    200 -> {
      let hash = security.sha256_hex(resp.body)
      Ok(#(resp.body, hash))
    }
    404 -> Error(PackageNotFound(name <> "@" <> version))
    status -> Error(ApiError(status, ""))
  }
}

// ---------------------------------------------------------------------------
// URL 인코딩
// ---------------------------------------------------------------------------

/// scoped 패키지명 URL 인코딩: @scope/name → @scope%2fname
pub fn encode_package_name(name: String) -> String {
  case string.starts_with(name, "@") {
    True -> string.replace(name, "/", "%2f")
    False -> name
  }
}

// ---------------------------------------------------------------------------
// JSON 파싱 (테스트 가능하도록 public)
// ---------------------------------------------------------------------------

/// npm registry 응답 JSON에서 버전 목록 파싱
pub fn parse_versions_response(
  body: String,
) -> Result(List(NpmPackageVersion), NpmError) {
  let decoder = {
    use versions <- decode.field(
      "versions",
      decode.dict(decode.string, version_value_decoder()),
    )
    use time <- decode.optional_field(
      "time",
      dict.new(),
      decode.dict(decode.string, decode.string),
    )
    decode.success(#(versions, time))
  }

  use #(versions, time) <- result.try(
    json.parse(body, decoder)
    |> result.map_error(fn(e) { ParseResponseError(string.inspect(e)) }),
  )

  let result =
    dict.to_list(versions)
    |> list.map(fn(entry) {
      let #(ver, v) = entry
      let published_at = dict.get(time, ver) |> result.unwrap("")
      NpmPackageVersion(
        version: ver,
        published_at: published_at,
        tarball_url: v.tarball_url,
        dependencies: v.deps,
        os: v.os,
        cpu: v.cpu,
        has_scripts: v.has_scripts,
        signatures: v.signatures,
        integrity: v.integrity,
      )
    })
    |> list.sort(fn(a, b) { string.compare(a.version, b.version) })

  Ok(result)
}

/// version_value_decoder 중간 타입
type VersionValue {
  VersionValue(
    tarball_url: String,
    deps: List(NpmDependency),
    os: List(String),
    cpu: List(String),
    has_scripts: Bool,
    signatures: List(NpmSignature),
    integrity: String,
  )
}

fn version_value_decoder() -> decode.Decoder(VersionValue) {
  use #(tarball_url, signatures, integrity) <- decode.optional_field(
    "dist",
    #("", [], ""),
    dist_decoder(),
  )
  use deps <- decode.optional_field(
    "dependencies",
    dict.new(),
    decode.dict(decode.string, decode.string),
  )
  use os <- decode.optional_field("os", [], decode.list(decode.string))
  use cpu <- decode.optional_field("cpu", [], decode.list(decode.string))
  use scripts <- decode.optional_field(
    "scripts",
    dict.new(),
    decode.dict(decode.string, decode.string),
  )
  let dep_list =
    dict.to_list(deps)
    |> list.map(fn(entry) {
      let #(name, constraint) = entry
      NpmDependency(name: name, constraint: constraint)
    })
    |> list.sort(fn(a, b) { string.compare(a.name, b.name) })
  decode.success(VersionValue(
    tarball_url: tarball_url,
    deps: dep_list,
    os: os,
    cpu: cpu,
    has_scripts: dict.size(scripts) > 0,
    signatures: signatures,
    integrity: integrity,
  ))
}

fn dist_decoder() -> decode.Decoder(#(String, List(NpmSignature), String)) {
  use tarball <- decode.optional_field("tarball", "", decode.string)
  use signatures <- decode.optional_field(
    "signatures",
    [],
    decode.list(signature_decoder()),
  )
  use integrity <- decode.optional_field("integrity", "", decode.string)
  decode.success(#(tarball, signatures, integrity))
}

fn signature_decoder() -> decode.Decoder(NpmSignature) {
  use keyid <- decode.field("keyid", decode.string)
  use sig <- decode.field("sig", decode.string)
  decode.success(NpmSignature(keyid: keyid, sig: sig))
}

// ---------------------------------------------------------------------------
// 레지스트리 서명 공개 키
// ---------------------------------------------------------------------------

/// npm 레지스트리 서명 공개 키
pub type SigningKey {
  SigningKey(keyid: String, pem: String)
}

/// npm 레지스트리에서 서명 공개 키 조회
pub fn get_signing_keys() -> Result(List(SigningKey), NpmError) {
  let url = "https://registry.npmjs.org/-/npm/v1/keys"
  use req <- result.try(
    request.to(url)
    |> result.map_error(fn(_) { NetworkError("invalid URL: " <> url) }),
  )
  use resp <- result.try(
    httpc.send(req)
    |> result.map_error(fn(e) { NetworkError(string.inspect(e)) }),
  )
  case resp.status {
    200 -> parse_keys_response(resp.body)
    status -> Error(ApiError(status, resp.body))
  }
}

fn parse_keys_response(body: String) -> Result(List(SigningKey), NpmError) {
  let decoder = {
    use keys <- decode.field("keys", decode.list(signing_key_decoder()))
    decode.success(keys)
  }
  json.parse(body, decoder)
  |> result.map_error(fn(e) { ParseResponseError(string.inspect(e)) })
}

fn signing_key_decoder() -> decode.Decoder(SigningKey) {
  use keyid <- decode.field("keyid", decode.string)
  use key <- decode.field("key", decode.string)
  decode.success(SigningKey(keyid: keyid, pem: key))
}

/// 캐시에서 키 로드, 없거나 만료되면 조회 후 캐시
pub fn load_or_fetch_signing_keys() -> Result(List(SigningKey), NpmError) {
  let cache_path = signing_keys_cache_path()
  case read_cached_keys(cache_path) {
    Ok(keys) -> Ok(keys)
    Error(_) -> {
      use keys <- result.try(get_signing_keys())
      let _ = write_cached_keys(cache_path, keys)
      Ok(keys)
    }
  }
}

fn signing_keys_cache_path() -> String {
  case platform.get_home_dir() {
    Ok(home) -> home <> "/.kir/cache/npm-keys.json"
    Error(_) -> "/tmp/kir-npm-keys.json"
  }
}

fn read_cached_keys(path: String) -> Result(List(SigningKey), NpmError) {
  // mtime 7일 이내인지 확인
  case platform.get_file_mtime(path) {
    Ok(mtime) -> {
      let now = current_unix_seconds()
      case now - mtime < 604_800 {
        True ->
          case simplifile.read(path) {
            Ok(content) -> parse_cached_keys(content)
            Error(_) -> Error(NetworkError("cache read failed"))
          }
        False -> Error(NetworkError("cache expired"))
      }
    }
    Error(_) -> Error(NetworkError("no cache"))
  }
}

fn parse_cached_keys(content: String) -> Result(List(SigningKey), NpmError) {
  let decoder = decode.list(signing_key_decoder())
  json.parse(content, decoder)
  |> result.map_error(fn(e) { ParseResponseError(string.inspect(e)) })
}

fn write_cached_keys(path: String, keys: List(SigningKey)) -> Result(Nil, Nil) {
  let dir = cache_dir()
  let _ = simplifile.create_directory_all(dir)
  let content =
    json.array(keys, fn(k) {
      json.object([
        #("keyid", json.string(k.keyid)),
        #("key", json.string(k.pem)),
      ])
    })
    |> json.to_string
  simplifile.write(path, content)
  |> result.replace_error(Nil)
}

fn cache_dir() -> String {
  case platform.get_home_dir() {
    Ok(home) -> home <> "/.kir/cache"
    Error(_) -> "/tmp"
  }
}

fn current_unix_seconds() -> Int {
  let ts = platform.get_current_timestamp()
  parse_ts_to_seconds(ts) |> result.unwrap(0)
}

fn parse_ts_to_seconds(ts: String) -> Result(Int, Nil) {
  let cleaned =
    string.replace(ts, "T", "-")
    |> string.replace(":", "-")
    |> string.replace("Z", "")
  case string.split(cleaned, "-") {
    [y_s, mo_s, d_s, h_s, mi_s, s_s] -> {
      use y <- result.try(int.parse(y_s))
      use mo <- result.try(int.parse(mo_s))
      use d <- result.try(int.parse(d_s))
      use h <- result.try(int.parse(h_s))
      use mi <- result.try(int.parse(mi_s))
      use s <- result.try(int.parse(s_s))
      let days = { y - 1970 } * 365 + { y - 1969 } / 4 + month_days(mo) + d - 1
      Ok(days * 86_400 + h * 3600 + mi * 60 + s)
    }
    _ -> Error(Nil)
  }
}

fn month_days(month: Int) -> Int {
  case month {
    1 -> 0
    2 -> 31
    3 -> 59
    4 -> 90
    5 -> 120
    6 -> 151
    7 -> 181
    8 -> 212
    9 -> 243
    10 -> 273
    11 -> 304
    12 -> 334
    _ -> 0
  }
}

import gleam/int
import kirari/platform
import simplifile
