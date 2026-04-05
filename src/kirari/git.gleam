//// Git 클라이언트 — shallow clone, ref 해결, content hash 계산
//// HTTPS/HTTP URL만 허용. SSH(git@)와 로컬 경로(file://) 거부.

import gleam/bit_array
import gleam/list
import gleam/result
import gleam/string
import kirari/platform
import kirari/security
import simplifile

// ---------------------------------------------------------------------------
// 에러 타입
// ---------------------------------------------------------------------------

/// Git 모듈 전용 에러 타입
pub type GitError {
  GitNotInstalled
  CloneFailed(url: String, detail: String)
  RefResolveFailed(url: String, ref: String, detail: String)
  InvalidUrl(url: String, reason: String)
  CheckoutFailed(detail: String)
  ConfigParseFailed(detail: String)
  IoError(detail: String)
}

// ---------------------------------------------------------------------------
// URL 검증
// ---------------------------------------------------------------------------

/// Git URL 검증 — HTTPS/HTTP만 허용
pub fn validate_url(url: String) -> Result(Nil, GitError) {
  let lower = string.lowercase(url)
  case
    string.starts_with(lower, "https://")
    || string.starts_with(lower, "http://")
  {
    True ->
      case string.starts_with(lower, "file://") {
        True -> Error(InvalidUrl(url, "file:// URLs are not allowed"))
        False -> Ok(Nil)
      }
    False ->
      case string.starts_with(url, "git@") {
        True ->
          Error(InvalidUrl(url, "SSH URLs (git@) are not supported; use HTTPS"))
        False ->
          Error(InvalidUrl(url, "only https:// and http:// URLs are supported"))
      }
  }
}

// ---------------------------------------------------------------------------
// Git 설치 확인
// ---------------------------------------------------------------------------

/// git CLI 설치 여부 확인
pub fn check_installed() -> Result(Nil, GitError) {
  case platform.run_command("git --version") {
    Ok(_) -> Ok(Nil)
    Error(_) -> Error(GitNotInstalled)
  }
}

// ---------------------------------------------------------------------------
// Ref 해결
// ---------------------------------------------------------------------------

/// ref가 40자 hex commit SHA인지 확인
pub fn is_commit_sha(ref: String) -> Bool {
  string.length(ref) == 40
  && string.to_graphemes(ref)
  |> list.all(fn(c) {
    case c {
      "0"
      | "1"
      | "2"
      | "3"
      | "4"
      | "5"
      | "6"
      | "7"
      | "8"
      | "9"
      | "a"
      | "b"
      | "c"
      | "d"
      | "e"
      | "f" -> True
      _ -> False
    }
  })
}

/// git ls-remote로 ref를 commit SHA로 해결
/// commit SHA가 직접 주어진 경우 그대로 반환 (clone 시 검증)
pub fn resolve_ref(url: String, ref: String) -> Result(String, GitError) {
  case is_commit_sha(ref) {
    True -> Ok(ref)
    False -> {
      let cmd =
        "git ls-remote " <> shell_escape(url) <> " " <> shell_escape(ref)
      case platform.run_command(cmd) {
        Ok(output) -> parse_ls_remote_output(output, url, ref)
        Error(#(_, detail)) ->
          Error(RefResolveFailed(url, ref, strip_output(detail)))
      }
    }
  }
}

/// tag 이름으로 ref 해결 (refs/tags/<tag> 우선)
pub fn resolve_tag(url: String, tag: String) -> Result(String, GitError) {
  let cmd = "git ls-remote --tags " <> shell_escape(url) <> " " <> tag
  case platform.run_command(cmd) {
    Ok(output) -> parse_ls_remote_tag_output(output, url, tag)
    Error(#(_, detail)) ->
      Error(RefResolveFailed(url, tag, strip_output(detail)))
  }
}

fn parse_ls_remote_output(
  output: String,
  url: String,
  ref: String,
) -> Result(String, GitError) {
  let lines =
    string.split(output, "\n")
    |> list.filter(fn(line) { string.trim(line) != "" })
  case lines {
    [] -> Error(RefResolveFailed(url, ref, "ref not found"))
    [first, ..] ->
      case string.split_once(first, "\t") {
        Ok(#(sha, _)) -> {
          let sha = string.trim(sha)
          case is_commit_sha(sha) {
            True -> Ok(sha)
            False ->
              Error(RefResolveFailed(url, ref, "unexpected ls-remote output"))
          }
        }
        Error(_) ->
          Error(RefResolveFailed(url, ref, "unexpected ls-remote output"))
      }
  }
}

fn parse_ls_remote_tag_output(
  output: String,
  url: String,
  tag: String,
) -> Result(String, GitError) {
  let lines =
    string.split(output, "\n")
    |> list.filter(fn(line) { string.trim(line) != "" })
  // ^{} suffix가 있는 annotated tag의 실제 commit을 우선
  let peeled =
    list.find(lines, fn(line) {
      string.contains(line, "refs/tags/" <> tag <> "^{}")
    })
  let target_line = case peeled {
    Ok(line) -> Ok(line)
    Error(_) ->
      list.find(lines, fn(line) { string.contains(line, "refs/tags/" <> tag) })
  }
  case target_line {
    Ok(line) ->
      case string.split_once(line, "\t") {
        Ok(#(sha, _)) -> {
          let sha = string.trim(sha)
          case is_commit_sha(sha) {
            True -> Ok(sha)
            False ->
              Error(RefResolveFailed(url, tag, "unexpected ls-remote output"))
          }
        }
        Error(_) ->
          Error(RefResolveFailed(url, tag, "unexpected ls-remote output"))
      }
    Error(_) -> Error(RefResolveFailed(url, tag, "tag not found"))
  }
}

// ---------------------------------------------------------------------------
// Shallow Clone
// ---------------------------------------------------------------------------

/// shallow clone + 특정 commit checkout
pub fn shallow_clone(
  url: String,
  commit_sha: String,
  dest: String,
) -> Result(Nil, GitError) {
  // git init + fetch --depth 1 방식 (임의 commit SHA 지원)
  use _ <- result.try(
    run_git("git init " <> shell_escape(dest))
    |> result.map_error(fn(e) { CloneFailed(url, e) }),
  )
  use _ <- result.try(
    run_git(
      "git -C "
      <> shell_escape(dest)
      <> " remote add origin "
      <> shell_escape(url),
    )
    |> result.map_error(fn(e) { CloneFailed(url, e) }),
  )
  use _ <- result.try(
    run_git(
      "git -C "
      <> shell_escape(dest)
      <> " fetch --depth 1 origin "
      <> shell_escape(commit_sha),
    )
    |> result.map_error(fn(e) { CloneFailed(url, e) }),
  )
  use _ <- result.try(
    run_git("git -C " <> shell_escape(dest) <> " checkout FETCH_HEAD --quiet")
    |> result.map_error(fn(e) { CheckoutFailed(e) }),
  )
  Ok(Nil)
}

// ---------------------------------------------------------------------------
// 패키지 메타데이터 읽기
// ---------------------------------------------------------------------------

/// clone 디렉토리에서 gleam.toml 내용 읽기
pub fn read_gleam_toml(
  clone_dir: String,
  subdir: Result(String, Nil),
) -> Result(String, GitError) {
  let base = case subdir {
    Ok(sub) -> clone_dir <> "/" <> sub
    Error(_) -> clone_dir
  }
  let path = base <> "/gleam.toml"
  simplifile.read(path)
  |> result.map_error(fn(_) {
    ConfigParseFailed("gleam.toml not found at " <> path)
  })
}

// ---------------------------------------------------------------------------
// Content Hash (CAS 키)
// ---------------------------------------------------------------------------

/// 디렉토리 내 모든 파일의 결정론적 SHA256 해시 계산
/// .git/ 디렉토리 제외, 파일 경로 정렬, 경로+내용을 함께 해싱
pub fn content_hash(
  dir: String,
  subdir: Result(String, Nil),
) -> Result(String, GitError) {
  let base = case subdir {
    Ok(sub) -> dir <> "/" <> sub
    Error(_) -> dir
  }
  use files <- result.try(
    list_files_recursive(base, "")
    |> result.map_error(fn(e) { IoError(e) }),
  )
  let sorted = list.sort(files, string.compare)
  // 각 파일의 "relative_path\0content"를 연결하여 전체 해시 계산
  let combined =
    list.fold(sorted, <<>>, fn(acc, rel_path) {
      let full_path = base <> "/" <> rel_path
      case simplifile.read_bits(full_path) {
        Ok(data) ->
          bit_array.append(
            acc,
            bit_array.append(bit_array.from_string(rel_path <> "\\0"), data),
          )
        Error(_) -> acc
      }
    })
  Ok(security.sha256_hex(combined))
}

/// 재귀적 파일 목록 (.git/ 제외)
fn list_files_recursive(
  base: String,
  prefix: String,
) -> Result(List(String), String) {
  let path = case prefix {
    "" -> base
    _ -> base <> "/" <> prefix
  }
  case simplifile.read_directory(path) {
    Ok(entries) -> {
      let results =
        list.fold(entries, Ok([]), fn(acc, entry) {
          case acc {
            Error(e) -> Error(e)
            Ok(files) -> {
              case entry {
                ".git" -> Ok(files)
                _ -> {
                  let rel = case prefix {
                    "" -> entry
                    _ -> prefix <> "/" <> entry
                  }
                  let full = base <> "/" <> rel
                  case simplifile.is_directory(full) {
                    Ok(True) ->
                      case list_files_recursive(base, rel) {
                        Ok(sub_files) -> Ok(list.append(files, sub_files))
                        Error(e) -> Error(e)
                      }
                    _ -> Ok([rel, ..files])
                  }
                }
              }
            }
          }
        })
      results
    }
    Error(e) -> Error("failed to read directory: " <> string.inspect(e))
  }
}

// ---------------------------------------------------------------------------
// 내부 헬퍼
// ---------------------------------------------------------------------------

fn run_git(cmd: String) -> Result(String, String) {
  platform.run_command(cmd)
  |> result.map_error(fn(e) { strip_output(e.1) })
}

fn shell_escape(s: String) -> String {
  "\"" <> string.replace(s, "\"", "\\\"") <> "\""
}

fn strip_output(s: String) -> String {
  let trimmed = string.trim(s)
  case string.length(trimmed) > 200 {
    True -> string.slice(trimmed, 0, 200) <> "..."
    False -> trimmed
  }
}
