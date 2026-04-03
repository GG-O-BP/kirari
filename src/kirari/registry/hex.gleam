//// Hex.pm 레지스트리 API 클라이언트

import gleam/dynamic/decode
import gleam/http/request
import gleam/httpc
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import kirari/security

/// Hex 레지스트리 에러 타입
pub type HexError {
  PackageNotFound(name: String)
  ApiError(status: Int, body: String)
  NetworkError(detail: String)
  ParseResponseError(detail: String)
}

/// Hex 패키지의 한 버전 정보
pub type PackageVersion {
  PackageVersion(
    version: String,
    inserted_at: String,
    dependencies: List(VersionDependency),
  )
}

/// 버전의 의존성 항목
pub type VersionDependency {
  VersionDependency(name: String, requirement: String, optional: Bool)
}

// ---------------------------------------------------------------------------
// API 호출
// ---------------------------------------------------------------------------

/// 패키지의 모든 버전 정보를 Hex API에서 조회
pub fn get_versions(name: String) -> Result(List(PackageVersion), HexError) {
  let url = "https://hex.pm/api/packages/" <> name
  use req <- result.try(
    request.to(url)
    |> result.map_error(fn(_) { NetworkError("invalid URL: " <> url) }),
  )
  let req = request.set_header(req, "accept", "application/json")
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

/// 패키지 tarball을 다운로드하고 SHA256 해시를 함께 반환
pub fn download_tarball(
  name: String,
  version: String,
) -> Result(#(BitArray, String), HexError) {
  let url = "https://repo.hex.pm/tarballs/" <> name <> "-" <> version <> ".tar"
  use req <- result.try(
    request.to(url)
    |> result.map_error(fn(_) { NetworkError("invalid URL: " <> url) }),
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
// JSON 파싱 (테스트 가능하도록 public)
// ---------------------------------------------------------------------------

/// Hex API /packages/<name> 응답 JSON에서 버전 목록 파싱
pub fn parse_versions_response(
  body: String,
) -> Result(List(PackageVersion), HexError) {
  let decoder = {
    use releases <- decode.field("releases", decode.list(release_decoder()))
    decode.success(releases)
  }
  json.parse(body, decoder)
  |> result.map_error(fn(e) { ParseResponseError(string.inspect(e)) })
}

fn release_decoder() -> decode.Decoder(PackageVersion) {
  use version <- decode.field("version", decode.string)
  use inserted_at <- decode.optional_field("inserted_at", "", decode.string)
  use deps <- decode.optional_field("requirements", [], requirements_decoder())
  decode.success(PackageVersion(
    version: version,
    inserted_at: inserted_at,
    dependencies: deps,
  ))
}

fn requirements_decoder() -> decode.Decoder(List(VersionDependency)) {
  // Hex requirements는 { "name": { "requirement": "...", "optional": bool, "app": "..." } } 형태
  // 또는 배열로 올 수 있음 — dict로 먼저 시도
  decode.one_of(requirements_as_dict_decoder(), [
    requirements_as_list_decoder(),
  ])
}

fn requirements_as_dict_decoder() -> decode.Decoder(List(VersionDependency)) {
  let entry_decoder = decode.dict(decode.string, requirement_value_decoder())
  decode.map(entry_decoder, fn(d) {
    d
    |> dict.to_list
    |> list.map(fn(entry) {
      let #(name, #(req, opt)) = entry
      VersionDependency(name: name, requirement: req, optional: opt)
    })
    |> list.sort(fn(a, b) { string.compare(a.name, b.name) })
  })
}

fn requirement_value_decoder() -> decode.Decoder(#(String, Bool)) {
  use req <- decode.field("requirement", decode.string)
  use opt <- decode.optional_field("optional", False, decode.bool)
  decode.success(#(req, opt))
}

fn requirements_as_list_decoder() -> decode.Decoder(List(VersionDependency)) {
  decode.list({
    use name <- decode.field("name", decode.string)
    use req <- decode.field("requirement", decode.string)
    use opt <- decode.optional_field("optional", False, decode.bool)
    decode.success(VersionDependency(
      name: name,
      requirement: req,
      optional: opt,
    ))
  })
}

import gleam/dict
