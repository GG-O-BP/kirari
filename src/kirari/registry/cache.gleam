//// 레지스트리 메타데이터 HTTP 304 캐싱
//// ETag/Last-Modified 기반 조건부 요청으로 불필요한 네트워크 트래픽 절감

import gleam/bit_array
import gleam/dynamic/decode
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/httpc
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import kirari/platform
import kirari/security
import simplifile

/// 캐시 엔트리 — 디스크에 JSON으로 저장
pub type CacheEntry {
  CacheEntry(
    etag: String,
    last_modified: String,
    body: String,
    cached_at: Int,
    url: String,
  )
}

/// 캐시 에러 타입
pub type CacheError {
  CacheMiss
  CacheReadError(detail: String)
  CacheWriteError(detail: String)
}

/// 캐시 적용 HTTP 응답 결과
pub type CachedResponse {
  /// 200 — 새 데이터, 캐시 갱신됨
  Fresh(body: String)
  /// 304 — 서버가 캐시 유효 확인
  NotModified(body: String)
  /// 네트워크 실패, 캐시 폴백
  Fallback(body: String)
}

// ---------------------------------------------------------------------------
// 캐시 디렉토리 / 키
// ---------------------------------------------------------------------------

fn cache_dir() -> String {
  case platform.get_home_dir() {
    Ok(home) -> home <> "/.kir/cache/registry"
    Error(_) -> "/tmp/kir-cache/registry"
  }
}

fn cache_key(url: String) -> String {
  bit_array.from_string(url)
  |> security.sha256_hex
}

fn cache_path(url: String) -> String {
  cache_dir() <> "/" <> cache_key(url) <> ".json"
}

// ---------------------------------------------------------------------------
// 읽기 / 쓰기
// ---------------------------------------------------------------------------

/// 캐시 엔트리 읽기
pub fn read_entry(url: String) -> Result(CacheEntry, CacheError) {
  case simplifile.read(cache_path(url)) {
    Ok(content) -> parse_entry(content)
    Error(_) -> Error(CacheMiss)
  }
}

/// 캐시 엔트리 쓰기
pub fn write_entry(entry: CacheEntry) -> Result(Nil, CacheError) {
  let dir = cache_dir()
  let _ = simplifile.create_directory_all(dir)
  simplifile.write(cache_path(entry.url), encode_entry(entry))
  |> result.map_error(fn(e) { CacheWriteError(simplifile.describe_error(e)) })
}

/// 전체 캐시 삭제
pub fn invalidate_all() -> Result(Nil, CacheError) {
  let dir = cache_dir()
  case simplifile.is_directory(dir) {
    Ok(True) ->
      simplifile.delete(dir)
      |> result.map_error(fn(e) {
        CacheWriteError(simplifile.describe_error(e))
      })
    _ -> Ok(Nil)
  }
}

// ---------------------------------------------------------------------------
// 조건부 HTTP 요청
// ---------------------------------------------------------------------------

/// 캐싱이 적용된 HTTP GET 요청
/// skip_cache=True면 캐시 무시, 항상 fresh 요청
pub fn fetch_cached(
  url: String,
  extra_headers: List(#(String, String)),
  skip_cache: Bool,
) -> Result(CachedResponse, String) {
  use req <- result.try(
    request.to(url)
    |> result.map_error(fn(_) { "invalid URL: " <> url }),
  )
  let req =
    list.fold(extra_headers, req, fn(r, h) { request.set_header(r, h.0, h.1) })
  let cached = case skip_cache {
    True -> Error(CacheMiss)
    False -> read_entry(url)
  }
  let req = add_conditional_headers(req, cached)
  case httpc.send(req) {
    Ok(resp) -> handle_response(resp, url, cached)
    Error(e) ->
      case cached {
        Ok(entry) -> Ok(Fallback(entry.body))
        Error(_) -> Error("network error: " <> string.inspect(e))
      }
  }
}

/// 오프라인 모드: 캐시에서만 읽기
pub fn fetch_offline(url: String) -> Result(String, CacheError) {
  use entry <- result.try(read_entry(url))
  Ok(entry.body)
}

// ---------------------------------------------------------------------------
// 내부 헬퍼
// ---------------------------------------------------------------------------

fn add_conditional_headers(
  req: request.Request(String),
  cached: Result(CacheEntry, CacheError),
) -> request.Request(String) {
  case cached {
    Ok(entry) -> {
      let r = case entry.etag {
        "" -> req
        etag -> request.set_header(req, "if-none-match", etag)
      }
      case entry.last_modified {
        "" -> r
        lm -> request.set_header(r, "if-modified-since", lm)
      }
    }
    Error(_) -> req
  }
}

fn handle_response(
  resp: Response(String),
  url: String,
  cached: Result(CacheEntry, CacheError),
) -> Result(CachedResponse, String) {
  case resp.status {
    304 ->
      case cached {
        Ok(entry) -> Ok(NotModified(entry.body))
        Error(_) -> Error("304 but no cached entry for " <> url)
      }
    200 -> {
      let entry =
        CacheEntry(
          etag: find_header(resp.headers, "etag"),
          last_modified: find_header(resp.headers, "last-modified"),
          body: resp.body,
          cached_at: platform.current_unix_seconds(),
          url: url,
        )
      let _ = write_entry(entry)
      Ok(Fresh(resp.body))
    }
    404 -> Error("not found: " <> url)
    status -> Error("HTTP " <> string.inspect(status) <> " from " <> url)
  }
}

fn find_header(headers: List(#(String, String)), name: String) -> String {
  let lower = string.lowercase(name)
  list.find(headers, fn(h) { string.lowercase(h.0) == lower })
  |> result.map(fn(h) { h.1 })
  |> result.unwrap("")
}

/// CachedResponse에서 body 추출
pub fn response_body(resp: CachedResponse) -> String {
  case resp {
    Fresh(body) -> body
    NotModified(body) -> body
    Fallback(body) -> body
  }
}

// ---------------------------------------------------------------------------
// JSON 직렬화
// ---------------------------------------------------------------------------

fn encode_entry(entry: CacheEntry) -> String {
  json.object([
    #("etag", json.string(entry.etag)),
    #("last_modified", json.string(entry.last_modified)),
    #("body", json.string(entry.body)),
    #("cached_at", json.int(entry.cached_at)),
    #("url", json.string(entry.url)),
  ])
  |> json.to_string
}

fn parse_entry(content: String) -> Result(CacheEntry, CacheError) {
  let decoder = {
    use etag <- decode.field("etag", decode.string)
    use last_modified <- decode.field("last_modified", decode.string)
    use body <- decode.field("body", decode.string)
    use cached_at <- decode.field("cached_at", decode.int)
    use url <- decode.field("url", decode.string)
    decode.success(CacheEntry(
      etag: etag,
      last_modified: last_modified,
      body: body,
      cached_at: cached_at,
      url: url,
    ))
  }
  json.parse(content, decoder)
  |> result.map_error(fn(e) { CacheReadError(string.inspect(e)) })
}
