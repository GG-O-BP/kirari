//// npm Bulk Advisory API 클라이언트 — npm 패키지 취약점 조회

import gleam/dict
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import kirari/audit.{type Advisory, Advisory}
import kirari/types.{type ResolvedPackage, Npm}

// ---------------------------------------------------------------------------
// 에러 타입
// ---------------------------------------------------------------------------

pub type NpmAuditError {
  NetworkError(detail: String)
  ApiError(status: Int, body: String)
  ParseError(detail: String)
}

// ---------------------------------------------------------------------------
// 공개 API
// ---------------------------------------------------------------------------

/// npm 패키지 목록에 대한 advisory를 bulk API로 조회
pub fn fetch_advisories(
  packages: List(ResolvedPackage),
) -> Result(List(Advisory), NpmAuditError) {
  let npm_packages = list.filter(packages, fn(p) { p.registry == Npm })
  case npm_packages {
    [] -> Ok([])
    _ -> {
      let body = build_request_body(npm_packages)
      fetch_bulk(body)
    }
  }
}

// ---------------------------------------------------------------------------
// HTTP 요청
// ---------------------------------------------------------------------------

fn fetch_bulk(body_json: String) -> Result(List(Advisory), NpmAuditError) {
  let url = "https://registry.npmjs.org/-/npm/v1/security/advisories/bulk"
  use req <- result.try(
    request.to(url)
    |> result.map_error(fn(_) { NetworkError("invalid URL: " <> url) }),
  )
  let req = request.set_method(req, http.Post)
  let req = request.set_header(req, "content-type", "application/json")
  let req = request.set_body(req, body_json)
  use resp <- result.try(
    httpc.send(req)
    |> result.map_error(fn(e) { NetworkError(string.inspect(e)) }),
  )
  case resp.status {
    200 -> parse_bulk_response(resp.body)
    status -> Error(ApiError(status, resp.body))
  }
}

// ---------------------------------------------------------------------------
// 요청 Body 생성
// ---------------------------------------------------------------------------

/// npm 패키지를 bulk API 요청 body로 직렬화
/// { "highlight.js": ["11.9.0"], "esbuild": ["0.21.5"] }
pub fn build_request_body(packages: List(ResolvedPackage)) -> String {
  let pairs =
    list.map(packages, fn(p) { #(p.name, json.array([p.version], json.string)) })
  json.object(pairs)
  |> json.to_string
}

// ---------------------------------------------------------------------------
// 응답 파싱
// ---------------------------------------------------------------------------

/// Bulk advisory 응답 파싱 — advisory ID → advisory 객체 dict
fn parse_bulk_response(body: String) -> Result(List(Advisory), NpmAuditError) {
  let decoder = decode.dict(decode.string, raw_npm_advisory_decoder())
  case json.parse(body, decoder) {
    Ok(advisory_map) ->
      Ok(
        dict.values(advisory_map)
        |> list.map(raw_to_advisory),
      )
    Error(e) -> Error(ParseError(string.inspect(e)))
  }
}

/// npm advisory JSON 구조
type RawNpmAdvisory {
  RawNpmAdvisory(
    id: Int,
    title: String,
    severity: String,
    module_name: String,
    vulnerable_versions: String,
    patched_versions: String,
    url: String,
    cves: List(String),
    github_advisory_id: String,
  )
}

fn raw_npm_advisory_decoder() -> decode.Decoder(RawNpmAdvisory) {
  use id <- decode.field("id", decode.int)
  use title <- decode.optional_field("title", "", decode.string)
  use severity <- decode.optional_field("severity", "unknown", decode.string)
  use module_name <- decode.optional_field("module_name", "", decode.string)
  use vulnerable_versions <- decode.optional_field(
    "vulnerable_versions",
    "",
    decode.string,
  )
  use patched_versions <- decode.optional_field(
    "patched_versions",
    "",
    decode.string,
  )
  use url <- decode.optional_field("url", "", decode.string)
  use cves <- decode.optional_field("cves", [], decode.list(decode.string))
  use github_advisory_id <- decode.optional_field(
    "github_advisory_id",
    "",
    decode.string,
  )
  decode.success(RawNpmAdvisory(
    id: id,
    title: title,
    severity: severity,
    module_name: module_name,
    vulnerable_versions: vulnerable_versions,
    patched_versions: patched_versions,
    url: url,
    cves: cves,
    github_advisory_id: github_advisory_id,
  ))
}

// ---------------------------------------------------------------------------
// Raw → Advisory 변환
// ---------------------------------------------------------------------------

fn raw_to_advisory(raw: RawNpmAdvisory) -> Advisory {
  let severity =
    audit.severity_from_string(raw.severity) |> result.unwrap(audit.Unknown)
  let id = case raw.github_advisory_id {
    "" -> "npm:" <> string.inspect(raw.id)
    ghsa -> ghsa
  }
  let aliases = case raw.cves {
    [] -> []
    cves -> cves
  }
  // npm advisory ID도 alias에 추가 (github_advisory_id와 다를 때)
  let aliases = case raw.github_advisory_id {
    "" -> aliases
    _ -> ["npm:" <> string.inspect(raw.id), ..aliases]
  }
  Advisory(
    id: id,
    aliases: aliases,
    summary: raw.title,
    severity: severity,
    vulnerable_range: raw.vulnerable_versions,
    patched_versions: raw.patched_versions,
    url: raw.url,
    package_name: raw.module_name,
    registry: Npm,
  )
}
