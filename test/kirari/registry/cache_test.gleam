//// HTTP 304 캐시 모듈 단위 테스트

import gleam/string
import gleeunit
import kirari/registry/cache
import simplifile

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// cache_key 결정론적
// ---------------------------------------------------------------------------

pub fn response_body_fresh_test() {
  let resp = cache.Fresh("hello")
  let assert "hello" = cache.response_body(resp)
}

pub fn response_body_not_modified_test() {
  let resp = cache.NotModified("cached")
  let assert "cached" = cache.response_body(resp)
}

pub fn response_body_fallback_test() {
  let resp = cache.Fallback("fallback")
  let assert "fallback" = cache.response_body(resp)
}

// ---------------------------------------------------------------------------
// 읽기/쓰기 라운드트립
// ---------------------------------------------------------------------------

pub fn write_and_read_entry_test() {
  let entry =
    cache.CacheEntry(
      etag: "\"abc123\"",
      last_modified: "Wed, 03 Apr 2026 12:00:00 GMT",
      body: "{\"test\": true}",
      cached_at: 1_775_000_000,
      url: "https://example.com/test-write-read",
    )
  let assert Ok(Nil) = cache.write_entry(entry)
  let assert Ok(read_back) =
    cache.read_entry("https://example.com/test-write-read")
  let assert True = read_back.etag == entry.etag
  let assert True = read_back.last_modified == entry.last_modified
  let assert True = read_back.body == entry.body
  let assert True = read_back.cached_at == entry.cached_at
  let assert True = read_back.url == entry.url
}

// ---------------------------------------------------------------------------
// 캐시 미스
// ---------------------------------------------------------------------------

pub fn read_nonexistent_returns_cache_miss_test() {
  let assert Error(cache.CacheMiss) =
    cache.read_entry("https://example.com/nonexistent-" <> unique_suffix())
}

// ---------------------------------------------------------------------------
// fetch_offline — 캐시 없으면 CacheMiss
// ---------------------------------------------------------------------------

pub fn fetch_offline_miss_test() {
  let assert Error(cache.CacheMiss) =
    cache.fetch_offline("https://example.com/offline-miss-" <> unique_suffix())
}

pub fn fetch_offline_hit_test() {
  let url = "https://example.com/offline-hit-" <> unique_suffix()
  let entry =
    cache.CacheEntry(
      etag: "",
      last_modified: "",
      body: "offline body",
      cached_at: 0,
      url: url,
    )
  let assert Ok(Nil) = cache.write_entry(entry)
  let assert Ok("offline body") = cache.fetch_offline(url)
}

// ---------------------------------------------------------------------------
// invalidate_all — 디렉토리가 없어도 에러 아님
// ---------------------------------------------------------------------------

pub fn invalidate_all_no_error_test() {
  let assert Ok(Nil) = cache.invalidate_all()
}

// ---------------------------------------------------------------------------
// 헬퍼
// ---------------------------------------------------------------------------

fn unique_suffix() -> String {
  let ts =
    simplifile.read("gleam.toml")
    |> fn(r) {
      case r {
        Ok(s) -> string.length(s)
        Error(_) -> 0
      }
    }
  "u" <> string.inspect(ts)
}
