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
  )
}

/// npm 의존성 항목
pub type NpmDependency {
  NpmDependency(name: String, constraint: String)
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
      let #(ver, #(tarball_url, deps)) = entry
      let published_at = dict.get(time, ver) |> result.unwrap("")
      NpmPackageVersion(
        version: ver,
        published_at: published_at,
        tarball_url: tarball_url,
        dependencies: deps,
      )
    })
    |> list.sort(fn(a, b) { string.compare(a.version, b.version) })

  Ok(result)
}

fn version_value_decoder() -> decode.Decoder(#(String, List(NpmDependency))) {
  use tarball_url <- decode.optional_field("dist", "", dist_tarball_decoder())
  use deps <- decode.optional_field(
    "dependencies",
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
  decode.success(#(tarball_url, dep_list))
}

fn dist_tarball_decoder() -> decode.Decoder(String) {
  use tarball <- decode.optional_field("tarball", "", decode.string)
  decode.success(tarball)
}
