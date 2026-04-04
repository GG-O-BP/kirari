//// GitHub Advisory Database REST API 클라이언트 — Hex/Erlang 패키지 취약점 조회

import gleam/dynamic/decode
import gleam/http/request
import gleam/httpc
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import kirari/audit.{type Advisory, Advisory}
import kirari/platform
import kirari/types.{Hex}
import simplifile

// ---------------------------------------------------------------------------
// 에러 타입
// ---------------------------------------------------------------------------

pub type GhsaError {
  NetworkError(detail: String)
  ApiError(status: Int, body: String)
  ParseError(detail: String)
  RateLimited(detail: String)
}

// ---------------------------------------------------------------------------
// 공개 API
// ---------------------------------------------------------------------------

/// Erlang 생태계 advisory를 GitHub Advisory Database에서 조회 (캐시 사용)
pub fn fetch_advisories() -> Result(List(Advisory), GhsaError) {
  let cache_path = cache_file_path()
  case read_cache(cache_path) {
    Ok(advisories) -> Ok(advisories)
    Error(_) -> {
      use advisories <- result.try(fetch_all_pages())
      let _ = write_cache(cache_path, advisories)
      Ok(advisories)
    }
  }
}

/// 캐시 없이 직접 조회 (테스트용)
pub fn fetch_advisories_fresh() -> Result(List(Advisory), GhsaError) {
  fetch_all_pages()
}

// ---------------------------------------------------------------------------
// HTTP 페이지네이션
// ---------------------------------------------------------------------------

fn fetch_all_pages() -> Result(List(Advisory), GhsaError) {
  do_fetch_pages(1, [])
}

fn do_fetch_pages(
  page: Int,
  acc: List(Advisory),
) -> Result(List(Advisory), GhsaError) {
  use advisories <- result.try(fetch_page(page))
  case advisories {
    [] -> Ok(acc)
    _ -> do_fetch_pages(page + 1, list.append(acc, advisories))
  }
}

fn fetch_page(page: Int) -> Result(List(Advisory), GhsaError) {
  let url =
    "https://api.github.com/advisories?ecosystem=erlang&per_page=100&page="
    <> string.inspect(page)
  use req <- result.try(
    request.to(url)
    |> result.map_error(fn(_) { NetworkError("invalid URL: " <> url) }),
  )
  let req = request.set_header(req, "accept", "application/vnd.github+json")
  let req = request.set_header(req, "x-github-api-version", "2022-11-28")
  let req = case platform.get_env("GITHUB_TOKEN") {
    Ok(token) -> request.set_header(req, "authorization", "Bearer " <> token)
    Error(_) -> req
  }
  use resp <- result.try(
    httpc.send(req)
    |> result.map_error(fn(e) { NetworkError(string.inspect(e)) }),
  )
  case resp.status {
    200 -> parse_advisories_response(resp.body)
    403 -> Error(RateLimited("GitHub API rate limit exceeded"))
    429 -> Error(RateLimited("GitHub API rate limit exceeded"))
    status -> Error(ApiError(status, resp.body))
  }
}

// ---------------------------------------------------------------------------
// JSON 파싱
// ---------------------------------------------------------------------------

/// GHSA API 응답 파싱 — advisory 배열에서 Erlang 취약점 추출
fn parse_advisories_response(body: String) -> Result(List(Advisory), GhsaError) {
  let decoder = decode.list(raw_advisory_decoder())
  case json.parse(body, decoder) {
    Ok(raw_list) -> Ok(list.flat_map(raw_list, raw_to_advisories))
    Error(e) -> Error(ParseError(string.inspect(e)))
  }
}

/// GHSA advisory JSON 구조
type RawAdvisory {
  RawAdvisory(
    ghsa_id: String,
    cve_id: String,
    summary: String,
    severity: String,
    html_url: String,
    vulnerabilities: List(RawVulnerability),
  )
}

type RawVulnerability {
  RawVulnerability(
    package_name: String,
    ecosystem: String,
    vulnerable_range: String,
    patched_versions: String,
  )
}

fn raw_advisory_decoder() -> decode.Decoder(RawAdvisory) {
  use ghsa_id <- decode.field("ghsa_id", decode.string)
  use cve_id <- decode.optional_field("cve_id", "", nullable_string_decoder())
  use summary <- decode.optional_field("summary", "", nullable_string_decoder())
  use severity <- decode.optional_field(
    "severity",
    "unknown",
    nullable_string_decoder(),
  )
  use html_url <- decode.optional_field(
    "html_url",
    "",
    nullable_string_decoder(),
  )
  use vulns <- decode.field(
    "vulnerabilities",
    decode.list(raw_vulnerability_decoder()),
  )
  decode.success(RawAdvisory(
    ghsa_id: ghsa_id,
    cve_id: cve_id,
    summary: summary,
    severity: severity,
    html_url: html_url,
    vulnerabilities: vulns,
  ))
}

fn raw_vulnerability_decoder() -> decode.Decoder(RawVulnerability) {
  use pkg <- decode.field("package", package_decoder())
  use range <- decode.optional_field(
    "vulnerable_version_range",
    "",
    nullable_string_decoder(),
  )
  use patched <- decode.optional_field(
    "first_patched_version",
    "",
    patched_version_decoder(),
  )
  decode.success(RawVulnerability(
    package_name: pkg.0,
    ecosystem: pkg.1,
    vulnerable_range: range,
    patched_versions: patched,
  ))
}

fn package_decoder() -> decode.Decoder(#(String, String)) {
  use name <- decode.field("name", decode.string)
  use ecosystem <- decode.field("ecosystem", decode.string)
  decode.success(#(name, ecosystem))
}

fn patched_version_decoder() -> decode.Decoder(String) {
  decode.one_of(decode.string, [
    {
      use id <- decode.field("identifier", decode.string)
      decode.success(id)
    },
    decode.success(""),
  ])
}

/// null을 빈 문자열로 처리하는 디코더
fn nullable_string_decoder() -> decode.Decoder(String) {
  decode.one_of(decode.string, [decode.success("")])
}

// ---------------------------------------------------------------------------
// Raw → Advisory 변환
// ---------------------------------------------------------------------------

fn raw_to_advisories(raw: RawAdvisory) -> List(Advisory) {
  let aliases = case raw.cve_id {
    "" -> []
    cve -> [cve]
  }
  let severity =
    audit.severity_from_string(raw.severity)
    |> result.unwrap(audit.Unknown)
  list.filter_map(raw.vulnerabilities, fn(v) {
    case string.lowercase(v.ecosystem) {
      "erlang" -> {
        let range = normalize_ghsa_range(v.vulnerable_range)
        let patched = case v.patched_versions {
          "" -> ""
          ver -> ">= " <> ver
        }
        Ok(Advisory(
          id: raw.ghsa_id,
          aliases: aliases,
          summary: raw.summary,
          severity: severity,
          vulnerable_range: range,
          patched_versions: patched,
          url: raw.html_url,
          package_name: v.package_name,
          registry: Hex,
        ))
      }
      _ -> Error(Nil)
    }
  })
}

/// GHSA 범위를 Hex semver 형식으로 정규화
/// ">= 1.0.0, < 1.7.14" → ">= 1.0.0 and < 1.7.14"
pub fn normalize_ghsa_range(range: String) -> String {
  range
  |> string.replace(", ", " and ")
  |> string.replace(",", " and ")
  |> normalize_version_parts
}

/// 불완전 버전을 3자리로 패딩 ("< 2.0" → "< 2.0.0")
fn normalize_version_parts(range: String) -> String {
  string.split(range, " and ")
  |> list.map(fn(part) {
    let trimmed = string.trim(part)
    normalize_single_constraint(trimmed)
  })
  |> string.join(" and ")
}

fn normalize_single_constraint(part: String) -> String {
  case string.split_once(part, " ") {
    Ok(#(op, ver)) -> {
      let ver_trimmed = string.trim(ver)
      op <> " " <> pad_version(ver_trimmed)
    }
    Error(_) -> part
  }
}

fn pad_version(ver: String) -> String {
  let parts = string.split(ver, ".")
  case list.length(parts) {
    1 -> ver <> ".0.0"
    2 -> ver <> ".0"
    _ -> ver
  }
}

// ---------------------------------------------------------------------------
// 캐싱 — ~/.kir/cache/ghsa-erlang.json, TTL 1시간
// ---------------------------------------------------------------------------

fn cache_file_path() -> String {
  case platform.get_home_dir() {
    Ok(home) -> home <> "/.kir/cache/ghsa-erlang.json"
    Error(_) -> "/tmp/kir-ghsa-erlang.json"
  }
}

fn cache_dir() -> String {
  case platform.get_home_dir() {
    Ok(home) -> home <> "/.kir/cache"
    Error(_) -> "/tmp"
  }
}

fn read_cache(path: String) -> Result(List(Advisory), GhsaError) {
  case platform.get_file_mtime(path) {
    Ok(mtime) -> {
      let now = platform.current_unix_seconds()
      // 1시간 = 3600초
      case now - mtime < 3600 {
        True ->
          case simplifile.read(path) {
            Ok(content) -> parse_cached_advisories(content)
            Error(_) -> Error(NetworkError("cache read failed"))
          }
        False -> Error(NetworkError("cache expired"))
      }
    }
    Error(_) -> Error(NetworkError("no cache"))
  }
}

fn parse_cached_advisories(content: String) -> Result(List(Advisory), GhsaError) {
  let decoder = decode.list(cached_advisory_decoder())
  json.parse(content, decoder)
  |> result.map_error(fn(e) { ParseError(string.inspect(e)) })
}

fn cached_advisory_decoder() -> decode.Decoder(Advisory) {
  use id <- decode.field("id", decode.string)
  use aliases <- decode.field("aliases", decode.list(decode.string))
  use summary <- decode.field("summary", decode.string)
  use severity_str <- decode.field("severity", decode.string)
  use vulnerable_range <- decode.field("vulnerable_range", decode.string)
  use patched_versions <- decode.field("patched_versions", decode.string)
  use url <- decode.field("url", decode.string)
  use package_name <- decode.field("package_name", decode.string)
  use registry_str <- decode.field("registry", decode.string)
  let severity =
    audit.severity_from_string(severity_str) |> result.unwrap(audit.Unknown)
  let registry = types.registry_from_string(registry_str) |> result.unwrap(Hex)
  decode.success(Advisory(
    id: id,
    aliases: aliases,
    summary: summary,
    severity: severity,
    vulnerable_range: vulnerable_range,
    patched_versions: patched_versions,
    url: url,
    package_name: package_name,
    registry: registry,
  ))
}

fn write_cache(path: String, advisories: List(Advisory)) -> Result(Nil, Nil) {
  let dir = cache_dir()
  let _ = simplifile.create_directory_all(dir)
  let content =
    json.array(advisories, fn(a) {
      json.object([
        #("id", json.string(a.id)),
        #("aliases", json.array(a.aliases, json.string)),
        #("summary", json.string(a.summary)),
        #("severity", json.string(audit.severity_to_string(a.severity))),
        #("vulnerable_range", json.string(a.vulnerable_range)),
        #("patched_versions", json.string(a.patched_versions)),
        #("url", json.string(a.url)),
        #("package_name", json.string(a.package_name)),
        #("registry", json.string(types.registry_to_string(a.registry))),
      ])
    })
    |> json.to_string
  simplifile.write(path, content)
  |> result.replace_error(Nil)
}
