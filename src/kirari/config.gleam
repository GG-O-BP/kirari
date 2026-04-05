//// gleam.toml 파싱/직렬화 및 의존성 조작
//// gleam 네이티브 섹션([dependencies], [dev-dependencies])과
//// kirari 확장 섹션([npm-dependencies], [dev-npm-dependencies], [security])을 통합 관리

import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import gleam/time/calendar
import gleam/time/duration
import kirari/types.{
  type Dependency, type GitDep, type KirConfig, type Override, type PackageInfo,
  type PathDep, type Registry, type SecurityConfig, type UrlDep, Dependency,
  GitDep, GitSource, Hex, KirConfig, Npm, Override, PackageInfo, PathDep,
  SecurityConfig, UrlDep, UrlSource,
}
import simplifile
import tom.{type Toml}

/// config 모듈 전용 에러 타입
pub type ConfigError {
  FileNotFound(path: String)
  ParseError(detail: String)
  InvalidField(field: String, detail: String)
  WriteError(path: String, detail: String)
}

// ---------------------------------------------------------------------------
// gleam.toml 읽기
// ---------------------------------------------------------------------------

/// 디렉토리에서 gleam.toml을 읽어 KirConfig로 변환
pub fn read_config(directory: String) -> Result(KirConfig, ConfigError) {
  let path = directory <> "/gleam.toml"
  use content <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(_) { FileNotFound(path) }),
  )
  parse_config(content)
}

/// gleam.toml 문자열을 파싱
pub fn parse_config(content: String) -> Result(KirConfig, ConfigError) {
  use doc <- result.try(
    tom.parse(content)
    |> result.map_error(fn(e) { ParseError(string.inspect(e)) }),
  )
  decode_config(doc)
}

fn decode_config(doc: Dict(String, Toml)) -> Result(KirConfig, ConfigError) {
  use package <- result.try(decode_package_info(doc))
  // Hex 의존성: [dependencies], [dev-dependencies] or [dev_dependencies]
  let hex_deps = decode_deps_from_table(doc, ["dependencies"], Hex, False)
  let hex_dev_deps = case
    decode_deps_from_table(doc, ["dev-dependencies"], Hex, True)
  {
    [] -> decode_deps_from_table(doc, ["dev_dependencies"], Hex, True)
    deps -> deps
  }
  // 로컬 경로 의존성
  let path_deps = decode_path_deps_from_table(doc, ["dependencies"], False)
  let path_dev_deps = case
    decode_path_deps_from_table(doc, ["dev-dependencies"], True)
  {
    [] -> decode_path_deps_from_table(doc, ["dev_dependencies"], True)
    deps -> deps
  }
  // npm 의존성: [npm-dependencies], [dev-npm-dependencies]
  let npm_deps = decode_deps_from_table(doc, ["npm-dependencies"], Npm, False)
  let npm_dev_deps =
    decode_deps_from_table(doc, ["dev-npm-dependencies"], Npm, True)
  let security = decode_security_section(doc)
  let overrides = decode_overrides(doc)
  let engines = decode_engines_section(doc)
  let download = decode_download_config(doc)
  // Git 의존성: [git-dependencies], [dev-git-dependencies]
  let git_deps = decode_git_deps_from_table(doc, ["git-dependencies"], False)
  let git_dev_deps =
    decode_git_deps_from_table(doc, ["dev-git-dependencies"], True)
  // URL 의존성: [url-dependencies], [dev-url-dependencies]
  let url_deps = decode_url_deps_from_table(doc, ["url-dependencies"], False)
  let url_dev_deps =
    decode_url_deps_from_table(doc, ["dev-url-dependencies"], True)
  // npm package.json passthrough: [npm-package]
  let npm_package = case tom.get_table(doc, ["npm-package"]) {
    Ok(table) -> table
    Error(_) -> dict.new()
  }
  Ok(KirConfig(
    package: package,
    hex_deps: hex_deps,
    hex_dev_deps: hex_dev_deps,
    npm_deps: npm_deps,
    npm_dev_deps: npm_dev_deps,
    security: security,
    path_deps: path_deps,
    path_dev_deps: path_dev_deps,
    overrides: overrides,
    engines: engines,
    download: download,
    git_deps: git_deps,
    git_dev_deps: git_dev_deps,
    url_deps: url_deps,
    url_dev_deps: url_dev_deps,
    npm_package: npm_package,
  ))
}

/// gleam.toml 최상위 필드에서 패키지 정보 읽기
fn decode_package_info(
  doc: Dict(String, Toml),
) -> Result(PackageInfo, ConfigError) {
  use name <- result.try(
    tom.get_string(doc, ["name"])
    |> result.map_error(fn(_) { InvalidField("name", "required in gleam.toml") }),
  )
  let version = tom.get_string(doc, ["version"]) |> result.unwrap("0.1.0")
  let description = tom.get_string(doc, ["description"]) |> result.unwrap("")
  let target = tom.get_string(doc, ["target"]) |> result.unwrap("erlang")
  let licences = decode_string_array(doc, ["licences"])
  let repository = decode_repository(doc)
  let links = decode_links(doc)
  Ok(PackageInfo(
    name: name,
    version: version,
    description: description,
    target: target,
    licences: licences,
    repository: repository,
    links: links,
  ))
}

fn decode_repository(doc: Dict(String, Toml)) -> Result(String, Nil) {
  case tom.get_table(doc, ["repository"]) {
    Ok(repo_table) ->
      case
        tom.get_string(repo_table, ["type"]),
        tom.get_string(repo_table, ["user"]),
        tom.get_string(repo_table, ["repo"])
      {
        Ok(t), Ok(u), Ok(r) -> Ok(t <> ":" <> u <> "/" <> r)
        _, _, _ -> Error(Nil)
      }
    Error(_) ->
      tom.get_string(doc, ["repository"])
      |> result.map_error(fn(_) { Nil })
  }
}

fn decode_links(doc: Dict(String, Toml)) -> List(#(String, String)) {
  case tom.get_array(doc, ["links"]) {
    Ok(items) ->
      list.filter_map(items, fn(item) {
        case item {
          tom.InlineTable(t) ->
            case tom.get_string(t, ["title"]), tom.get_string(t, ["href"]) {
              Ok(title), Ok(href) -> Ok(#(title, href))
              _, _ -> Error(Nil)
            }
          _ -> Error(Nil)
        }
      })
    Error(_) -> []
  }
}

fn decode_string_array(
  table: Dict(String, Toml),
  path: List(String),
) -> List(String) {
  case tom.get_array(table, path) {
    Ok(items) ->
      list.filter_map(items, fn(item) {
        case item {
          tom.String(s) -> Ok(s)
          _ -> Error(Nil)
        }
      })
    Error(_) -> []
  }
}

fn decode_deps_from_table(
  doc: Dict(String, Toml),
  path: List(String),
  registry: Registry,
  dev: Bool,
) -> List(Dependency) {
  case tom.get_table(doc, path) {
    Ok(table) ->
      dict.to_list(table)
      |> list.filter_map(fn(entry) {
        let #(name, value) = entry
        case value {
          tom.String(constraint) ->
            case parse_alias_constraint(constraint, registry) {
              Ok(#(real_name, real_constraint)) ->
                Ok(Dependency(
                  name: name,
                  version_constraint: real_constraint,
                  registry: registry,
                  dev: dev,
                  optional: False,
                  package_name: Ok(real_name),
                ))
              Error(_) ->
                Ok(Dependency(
                  name: name,
                  version_constraint: constraint,
                  registry: registry,
                  dev: dev,
                  optional: False,
                  package_name: Error(Nil),
                ))
            }
          _ -> Error(Nil)
        }
      })
      |> list.sort(fn(a, b) { string.compare(a.name, b.name) })
    Error(_) -> []
  }
}

/// "npm:react@^18.0.0" 또는 "npm:@scope/pkg@^1.0" 형식 파싱
fn parse_alias_constraint(
  value: String,
  registry: Registry,
) -> Result(#(String, String), Nil) {
  case registry {
    Npm ->
      case string.starts_with(value, "npm:") {
        True -> {
          let rest = string.drop_start(value, 4)
          case string.starts_with(rest, "@") {
            // 스코프 패키지: npm:@scope/name@constraint
            True -> {
              let without_at = string.drop_start(rest, 1)
              case string.split_once(without_at, "@") {
                Ok(#(scope_and_name, constraint)) ->
                  Ok(#("@" <> scope_and_name, constraint))
                Error(_) -> Ok(#(rest, "*"))
              }
            }
            // 일반 패키지: npm:name@constraint
            False ->
              case string.split_once(rest, "@") {
                Ok(#(name, constraint)) -> Ok(#(name, constraint))
                Error(_) -> Ok(#(rest, "*"))
              }
          }
        }
        False -> Error(Nil)
      }
    Hex | types.Git | types.Url -> Error(Nil)
  }
}

fn decode_path_deps_from_table(
  doc: Dict(String, Toml),
  path: List(String),
  dev: Bool,
) -> List(PathDep) {
  case tom.get_table(doc, path) {
    Ok(table) ->
      dict.to_list(table)
      |> list.filter_map(fn(entry) {
        let #(name, value) = entry
        case value {
          tom.InlineTable(t) ->
            case dict.get(t, "path") {
              Ok(tom.String(p)) -> Ok(PathDep(name: name, path: p, dev: dev))
              _ -> Error(Nil)
            }
          _ -> Error(Nil)
        }
      })
      |> list.sort(fn(a, b) { string.compare(a.name, b.name) })
    Error(_) -> []
  }
}

fn decode_git_deps_from_table(
  doc: Dict(String, Toml),
  path: List(String),
  dev: Bool,
) -> List(GitDep) {
  case tom.get_table(doc, path) {
    Ok(table) ->
      dict.to_list(table)
      |> list.filter_map(fn(entry) {
        let #(name, value) = entry
        case value {
          tom.InlineTable(t) ->
            case dict.get(t, "git") {
              Ok(tom.String(url)) -> {
                let tag = case dict.get(t, "tag") {
                  Ok(tom.String(tag_val)) -> Ok(tag_val)
                  _ -> Error(Nil)
                }
                let ref = case tag {
                  Ok(tag_val) -> tag_val
                  Error(_) ->
                    case dict.get(t, "ref") {
                      Ok(tom.String(r)) -> r
                      _ -> "main"
                    }
                }
                let subdir = case dict.get(t, "subdir") {
                  Ok(tom.String(s)) -> Ok(s)
                  _ -> Error(Nil)
                }
                Ok(GitDep(
                  name: name,
                  source: GitSource(
                    url: url,
                    ref: ref,
                    resolved_ref: "",
                    tag: tag,
                    subdir: subdir,
                  ),
                  dev: dev,
                ))
              }
              _ -> Error(Nil)
            }
          _ -> Error(Nil)
        }
      })
      |> list.sort(fn(a, b) { string.compare(a.name, b.name) })
    Error(_) -> []
  }
}

fn decode_url_deps_from_table(
  doc: Dict(String, Toml),
  path: List(String),
  dev: Bool,
) -> List(UrlDep) {
  case tom.get_table(doc, path) {
    Ok(table) ->
      dict.to_list(table)
      |> list.filter_map(fn(entry) {
        let #(name, value) = entry
        case value {
          tom.InlineTable(t) ->
            case dict.get(t, "url") {
              Ok(tom.String(url)) -> {
                let sha256 = case dict.get(t, "sha256") {
                  Ok(tom.String(h)) -> h
                  _ -> ""
                }
                Ok(UrlDep(
                  name: name,
                  source: UrlSource(url: url, sha256: sha256),
                  dev: dev,
                ))
              }
              _ -> Error(Nil)
            }
          _ -> Error(Nil)
        }
      })
      |> list.sort(fn(a, b) { string.compare(a.name, b.name) })
    Error(_) -> []
  }
}

fn decode_overrides(doc: Dict(String, Toml)) -> List(Override) {
  let hex = decode_override_section(doc, ["overrides"], Hex)
  let npm = decode_override_section(doc, ["npm-overrides"], Npm)
  list.append(hex, npm)
}

fn decode_override_section(
  doc: Dict(String, Toml),
  path: List(String),
  registry: Registry,
) -> List(Override) {
  case tom.get_table(doc, path) {
    Ok(table) ->
      dict.to_list(table)
      |> list.filter_map(fn(entry) {
        let #(name, value) = entry
        case value {
          tom.String(constraint) ->
            Ok(Override(
              name: name,
              version_constraint: constraint,
              registry: registry,
            ))
          _ -> Error(Nil)
        }
      })
      |> list.sort(fn(a, b) { string.compare(a.name, b.name) })
    Error(_) -> []
  }
}

fn decode_security_section(doc: Dict(String, Toml)) -> SecurityConfig {
  let exclude_newer =
    tom.get_string(doc, ["security", "exclude-newer"])
    |> result.map_error(fn(_) { Nil })
  let npm_scripts = case tom.get_string(doc, ["security", "npm-scripts"]) {
    Ok("allow") -> types.AllowAll
    Ok("deny") -> types.DenyAll
    _ -> types.DenyAll
  }
  let npm_scripts = case tom.get_array(doc, ["security", "npm-scripts-allow"]) {
    Ok(items) -> {
      let names =
        list.filter_map(items, fn(item) {
          case item {
            tom.String(s) -> Ok(s)
            _ -> Error(Nil)
          }
        })
      case names {
        [] -> npm_scripts
        _ -> types.AllowList(packages: names)
      }
    }
    Error(_) -> npm_scripts
  }
  let provenance = case tom.get_string(doc, ["security", "provenance"]) {
    Ok("ignore") -> types.ProvenanceIgnore
    Ok("warn") -> types.ProvenanceWarn
    Ok("require") -> types.ProvenanceRequire
    _ -> types.ProvenanceWarn
  }
  let license_allow = decode_string_array(doc, ["security", "license-allow"])
  let license_deny = decode_string_array(doc, ["security", "license-deny"])
  let license_policy = case license_allow, license_deny {
    [], [] -> types.LicenseNoPolicy
    allow, [] -> types.LicenseAllow(allow)
    [], deny -> types.LicenseDeny(deny)
    allow, _ -> types.LicenseAllow(allow)
  }
  let audit_ignore = decode_string_array(doc, ["security", "audit-ignore"])
  SecurityConfig(
    exclude_newer: exclude_newer,
    npm_scripts: npm_scripts,
    provenance: provenance,
    license_policy: license_policy,
    audit_ignore: audit_ignore,
  )
}

// ---------------------------------------------------------------------------
// gleam.toml 쓰기
// ---------------------------------------------------------------------------

/// KirConfig를 디렉토리의 gleam.toml에 기록
pub fn write_config(
  config: KirConfig,
  directory: String,
) -> Result(Nil, ConfigError) {
  let path = directory <> "/gleam.toml"
  let content = encode_config(config)
  simplifile.write(path, content)
  |> result.map_error(fn(_) { WriteError(path, "failed to write file") })
}

/// KirConfig를 gleam.toml TOML 문자열로 직렬화
pub fn encode_config(config: KirConfig) -> String {
  [
    encode_top_level(config.package),
    encode_links(config.package.links),
    encode_repository(config.package),
    encode_dep_section("dependencies", config.hex_deps, config.path_deps),
    encode_dep_section(
      "dev-dependencies",
      config.hex_dev_deps,
      config.path_dev_deps,
    ),
    encode_dep_section("npm-dependencies", config.npm_deps, []),
    encode_dep_section("dev-npm-dependencies", config.npm_dev_deps, []),
    encode_git_dep_section("git-dependencies", config.git_deps),
    encode_git_dep_section("dev-git-dependencies", config.git_dev_deps),
    encode_url_dep_section("url-dependencies", config.url_deps),
    encode_url_dep_section("dev-url-dependencies", config.url_dev_deps),
    encode_override_section("overrides", config.overrides, Hex),
    encode_override_section("npm-overrides", config.overrides, Npm),
    encode_security_section(config.security, config.download),
    encode_engines_section(config.engines),
    encode_npm_package_section(config.npm_package),
  ]
  |> list.filter(fn(s) { s != "" })
  |> string.join("\n")
}

fn encode_top_level(pkg: PackageInfo) -> String {
  let lines = ["name = " <> quote(pkg.name)]
  let lines = list.append(lines, ["version = " <> quote(pkg.version)])
  let lines = case pkg.description {
    "" -> lines
    d -> list.append(lines, ["description = " <> quote(d)])
  }
  let lines = case pkg.licences {
    [] -> lines
    ls ->
      list.append(lines, [
        "licences = [" <> string.join(list.map(ls, quote), ", ") <> "]",
      ])
  }
  let lines = case pkg.target {
    "erlang" -> lines
    t -> list.append(lines, ["target = " <> quote(t)])
  }
  string.join(lines, "\n") <> "\n"
}

fn encode_repository(pkg: PackageInfo) -> String {
  case pkg.repository {
    Error(_) -> ""
    Ok(repo) ->
      case string.split_once(repo, ":") {
        Ok(#(repo_type, path)) ->
          case string.split_once(path, "/") {
            Ok(#(user, repo_name)) ->
              "[repository]\ntype = "
              <> quote(repo_type)
              <> "\nuser = "
              <> quote(user)
              <> "\nrepo = "
              <> quote(repo_name)
              <> "\n"
            Error(_) -> ""
          }
        Error(_) -> ""
      }
  }
}

fn encode_dep_section(
  header: String,
  deps: List(Dependency),
  path_deps: List(PathDep),
) -> String {
  case deps, path_deps {
    [], [] -> ""
    _, _ -> {
      let reg_lines =
        list.sort(deps, fn(a, b) { string.compare(a.name, b.name) })
        |> list.map(fn(dep) {
          let value = case dep.package_name {
            Ok(real_name) ->
              quote("npm:" <> real_name <> "@" <> dep.version_constraint)
            Error(_) -> quote(dep.version_constraint)
          }
          #(dep.name, quote_key(dep.name) <> " = " <> value)
        })
      let path_lines =
        list.sort(path_deps, fn(a, b) { string.compare(a.name, b.name) })
        |> list.map(fn(dep) {
          #(
            dep.name,
            quote_key(dep.name) <> " = { path = " <> quote(dep.path) <> " }",
          )
        })
      let all_lines =
        list.append(reg_lines, path_lines)
        |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
        |> list.map(fn(pair) { pair.1 })
      "[" <> header <> "]\n" <> string.join(all_lines, "\n") <> "\n"
    }
  }
}

fn encode_git_dep_section(header: String, deps: List(GitDep)) -> String {
  case deps {
    [] -> ""
    _ -> {
      let lines =
        list.sort(deps, fn(a, b) { string.compare(a.name, b.name) })
        |> list.map(fn(dep) {
          let git_part = "git = " <> quote(dep.source.url)
          let ref_part = case dep.source.tag {
            Ok(tag) -> ", tag = " <> quote(tag)
            Error(_) ->
              case dep.source.ref {
                "main" -> ""
                r -> ", ref = " <> quote(r)
              }
          }
          let subdir_part = case dep.source.subdir {
            Ok(s) -> ", subdir = " <> quote(s)
            Error(_) -> ""
          }
          quote_key(dep.name)
          <> " = { "
          <> git_part
          <> ref_part
          <> subdir_part
          <> " }"
        })
      "[" <> header <> "]\n" <> string.join(lines, "\n") <> "\n"
    }
  }
}

fn encode_url_dep_section(header: String, deps: List(UrlDep)) -> String {
  case deps {
    [] -> ""
    _ -> {
      let lines =
        list.sort(deps, fn(a, b) { string.compare(a.name, b.name) })
        |> list.map(fn(dep) {
          let url_part = "url = " <> quote(dep.source.url)
          let sha_part = case dep.source.sha256 {
            "" -> ""
            h -> ", sha256 = " <> quote(h)
          }
          quote_key(dep.name) <> " = { " <> url_part <> sha_part <> " }"
        })
      "[" <> header <> "]\n" <> string.join(lines, "\n") <> "\n"
    }
  }
}

fn encode_override_section(
  header: String,
  overrides: List(Override),
  registry: Registry,
) -> String {
  let filtered =
    list.filter(overrides, fn(o) { o.registry == registry })
    |> list.sort(fn(a, b) { string.compare(a.name, b.name) })
  case filtered {
    [] -> ""
    _ -> {
      let lines =
        list.map(filtered, fn(o) {
          quote_key(o.name) <> " = " <> quote(o.version_constraint)
        })
      "[" <> header <> "]\n" <> string.join(lines, "\n") <> "\n"
    }
  }
}

fn encode_security_section(
  sec: SecurityConfig,
  dl: types.DownloadConfig,
) -> String {
  let lines = []
  let lines = case sec.exclude_newer {
    Ok(ts) -> ["exclude-newer = " <> quote(ts), ..lines]
    Error(_) -> lines
  }
  // DenyAll이 기본값이므로 생략
  let lines = case sec.npm_scripts {
    types.AllowAll -> ["npm-scripts = " <> quote("allow"), ..lines]
    types.DenyAll -> lines
    types.AllowList(_) -> ["npm-scripts = " <> quote("deny"), ..lines]
  }
  let lines = case sec.npm_scripts {
    types.AllowList(packages) -> {
      let quoted = list.map(packages, quote) |> string.join(", ")
      ["npm-scripts-allow = [" <> quoted <> "]", ..lines]
    }
    _ -> lines
  }
  // ProvenanceWarn이 기본값이므로 생략
  let lines = case sec.provenance {
    types.ProvenanceIgnore -> ["provenance = " <> quote("ignore"), ..lines]
    types.ProvenanceWarn -> lines
    types.ProvenanceRequire -> ["provenance = " <> quote("require"), ..lines]
  }
  // LicenseNoPolicy가 기본값이므로 생략
  let lines = case sec.license_policy {
    types.LicenseAllow(ls) -> {
      let quoted = list.map(ls, quote) |> string.join(", ")
      ["license-allow = [" <> quoted <> "]", ..lines]
    }
    types.LicenseDeny(ls) -> {
      let quoted = list.map(ls, quote) |> string.join(", ")
      ["license-deny = [" <> quoted <> "]", ..lines]
    }
    types.LicenseNoPolicy -> lines
  }
  let lines = case sec.audit_ignore {
    [] -> lines
    ids -> {
      let quoted = list.map(ids, quote) |> string.join(", ")
      ["audit-ignore = [" <> quoted <> "]", ..lines]
    }
  }
  // 다운로드 설정 (기본값 아닌 필드만)
  let lines = list.append(encode_download_lines(dl), lines)
  case lines {
    [] -> ""
    _ -> "[security]\n" <> string.join(list.reverse(lines), "\n") <> "\n"
  }
}

/// [engines] 섹션 디코딩
fn decode_engines_section(doc: Dict(String, Toml)) -> types.EnginesConfig {
  let gleam =
    tom.get_string(doc, ["engines", "gleam"])
    |> result.map_error(fn(_) { Nil })
  let erlang =
    tom.get_string(doc, ["engines", "erlang"])
    |> result.map_error(fn(_) { Nil })
  let node =
    tom.get_string(doc, ["engines", "node"])
    |> result.map_error(fn(_) { Nil })
  types.EnginesConfig(gleam: gleam, erlang: erlang, node: node)
}

/// [engines] 섹션 인코딩
fn encode_engines_section(engines: types.EnginesConfig) -> String {
  let lines = []
  let lines = case engines.erlang {
    Ok(c) -> ["erlang = " <> quote(c), ..lines]
    Error(_) -> lines
  }
  let lines = case engines.gleam {
    Ok(c) -> ["gleam = " <> quote(c), ..lines]
    Error(_) -> lines
  }
  let lines = case engines.node {
    Ok(c) -> ["node = " <> quote(c), ..lines]
    Error(_) -> lines
  }
  case lines {
    [] -> ""
    _ -> "[engines]\n" <> string.join(list.reverse(lines), "\n") <> "\n"
  }
}

/// links 배열 인코딩
fn encode_links(links: List(#(String, String))) -> String {
  case links {
    [] -> ""
    _ -> {
      let entries =
        list.map(links, fn(link) {
          "  { title = "
          <> quote(link.0)
          <> ", href = "
          <> quote(link.1)
          <> " }"
        })
      "links = [\n" <> string.join(entries, ",\n") <> ",\n]\n"
    }
  }
}

/// [npm-package] 섹션 TOML 직렬화
fn encode_npm_package_section(table: Dict(String, Toml)) -> String {
  case dict.is_empty(table) {
    True -> ""
    False -> encode_toml_table("npm-package", table)
  }
}

/// Dict(String, Toml)을 TOML 섹션으로 직렬화 (재귀)
fn encode_toml_table(prefix: String, table: Dict(String, Toml)) -> String {
  let entries =
    dict.to_list(table) |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  // 스칼라 값(Table/ArrayOfTables가 아닌 것)과 하위 테이블 분리
  let #(scalars, sub_tables) =
    list.partition(entries, fn(entry) {
      case entry.1 {
        tom.Table(_) -> False
        tom.ArrayOfTables(_) -> False
        _ -> True
      }
    })
  // 스칼라 값 출력
  let scalar_lines =
    list.map(scalars, fn(entry) {
      quote_key(entry.0) <> " = " <> encode_toml_value(entry.1)
    })
  let header_section = case scalar_lines {
    [] -> ""
    _ -> "[" <> prefix <> "]\n" <> string.join(scalar_lines, "\n") <> "\n"
  }
  // 하위 테이블 출력 (재귀)
  let sub_sections =
    list.map(sub_tables, fn(entry) {
      let sub_prefix = prefix <> "." <> quote_key(entry.0)
      case entry.1 {
        tom.Table(sub) -> encode_toml_table(sub_prefix, sub)
        tom.ArrayOfTables(tables) ->
          list.map(tables, fn(t) { encode_toml_aot_entry(sub_prefix, t) })
          |> string.join("\n")
        _ -> ""
      }
    })
  [header_section, ..sub_sections]
  |> list.filter(fn(s) { s != "" })
  |> string.join("\n")
}

/// [[section]] 엔트리 하나 직렬화
fn encode_toml_aot_entry(prefix: String, table: Dict(String, Toml)) -> String {
  let entries =
    dict.to_list(table) |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  let lines =
    list.map(entries, fn(entry) {
      quote_key(entry.0) <> " = " <> encode_toml_value(entry.1)
    })
  "[[" <> prefix <> "]]\n" <> string.join(lines, "\n") <> "\n"
}

/// TOML 값 직렬화 (스칼라 + 인라인)
fn encode_toml_value(value: Toml) -> String {
  case value {
    tom.String(s) -> quote(s)
    tom.Int(i) -> int.to_string(i)
    tom.Float(f) -> float_to_string(f)
    tom.Bool(True) -> "true"
    tom.Bool(False) -> "false"
    tom.Infinity(tom.Positive) -> "inf"
    tom.Infinity(tom.Negative) -> "-inf"
    tom.Nan(tom.Positive) -> "nan"
    tom.Nan(tom.Negative) -> "-nan"
    tom.Array(items) ->
      "[" <> string.join(list.map(items, encode_toml_value), ", ") <> "]"
    tom.InlineTable(t) -> encode_toml_inline_table(t)
    tom.Table(t) -> encode_toml_inline_table(t)
    tom.ArrayOfTables(tables) ->
      "["
      <> string.join(
        list.map(tables, fn(t) { encode_toml_inline_table(t) }),
        ", ",
      )
      <> "]"
    tom.Date(d) -> encode_toml_date(d)
    tom.Time(t) -> encode_toml_time(t)
    tom.DateTime(d, t, offset) ->
      encode_toml_date(d)
      <> "T"
      <> encode_toml_time(t)
      <> encode_toml_offset(offset)
  }
}

/// 인라인 테이블 직렬화
fn encode_toml_inline_table(table: Dict(String, Toml)) -> String {
  let entries =
    dict.to_list(table)
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
    |> list.map(fn(entry) {
      quote_key(entry.0) <> " = " <> encode_toml_value(entry.1)
    })
  "{ " <> string.join(entries, ", ") <> " }"
}

fn float_to_string(f: Float) -> String {
  let s = string.inspect(f)
  case string.contains(s, ".") {
    True -> s
    False -> s <> ".0"
  }
}

fn encode_toml_date(d: calendar.Date) -> String {
  pad4(d.year)
  <> "-"
  <> pad2(calendar.month_to_int(d.month))
  <> "-"
  <> pad2(d.day)
}

fn encode_toml_time(t: calendar.TimeOfDay) -> String {
  pad2(t.hours) <> ":" <> pad2(t.minutes) <> ":" <> pad2(t.seconds)
}

fn encode_toml_offset(offset: tom.Offset) -> String {
  case offset {
    tom.Local -> ""
    tom.Offset(dur) -> {
      let total_seconds = duration.to_seconds(dur) |> float.truncate
      let total_minutes = total_seconds / 60
      case total_minutes {
        0 -> "Z"
        _ -> {
          let sign = case total_minutes > 0 {
            True -> "+"
            False -> "-"
          }
          let abs_min = int.absolute_value(total_minutes)
          sign <> pad2(abs_min / 60) <> ":" <> pad2(abs_min % 60)
        }
      }
    }
  }
}

fn pad2(n: Int) -> String {
  case n < 10 {
    True -> "0" <> int.to_string(n)
    False -> int.to_string(n)
  }
}

fn pad4(n: Int) -> String {
  case n < 10 {
    True -> "000" <> int.to_string(n)
    False ->
      case n < 100 {
        True -> "00" <> int.to_string(n)
        False ->
          case n < 1000 {
            True -> "0" <> int.to_string(n)
            False -> int.to_string(n)
          }
      }
  }
}

/// [security] 섹션에서 다운로드 설정 디코딩
fn decode_download_config(doc: Dict(String, Toml)) -> types.DownloadConfig {
  let max_retries =
    tom.get_int(doc, ["security", "max-retries"]) |> result.unwrap(3)
  let timeout_sec =
    tom.get_int(doc, ["security", "timeout"]) |> result.unwrap(120)
  let parallel = tom.get_int(doc, ["security", "parallel"]) |> result.unwrap(0)
  let backoff = tom.get_int(doc, ["security", "backoff"]) |> result.unwrap(2000)
  types.DownloadConfig(
    max_retries: max_retries,
    timeout_ms: timeout_sec * 1000,
    parallel: parallel,
    backoff_ms: backoff,
  )
}

/// 다운로드 설정 인코딩 — [security] 섹션에 기본값이 아닌 필드만 추가
fn encode_download_lines(dl: types.DownloadConfig) -> List(String) {
  let lines = []
  let lines = case dl.max_retries != 3 {
    True -> ["max-retries = " <> int.to_string(dl.max_retries), ..lines]
    False -> lines
  }
  let lines = case dl.timeout_ms != 120_000 {
    True -> ["timeout = " <> int.to_string(dl.timeout_ms / 1000), ..lines]
    False -> lines
  }
  let lines = case dl.parallel != 0 {
    True -> ["parallel = " <> int.to_string(dl.parallel), ..lines]
    False -> lines
  }
  let lines = case dl.backoff_ms != 2000 {
    True -> ["backoff = " <> int.to_string(dl.backoff_ms), ..lines]
    False -> lines
  }
  lines
}

/// TOML 키 — 특수문자 포함 시 인용
fn quote_key(key: String) -> String {
  let bare_safe =
    key
    |> string.to_graphemes
    |> list.all(fn(c) {
      case c {
        "_" | "-" -> True
        _ -> {
          let cp = string.to_utf_codepoints(c)
          case cp {
            [cp] -> {
              let n = string.utf_codepoint_to_int(cp)
              { n >= 0x61 && n <= 0x7A }
              || { n >= 0x41 && n <= 0x5A }
              || { n >= 0x30 && n <= 0x39 }
            }
            _ -> False
          }
        }
      }
    })
  case bare_safe {
    True -> key
    False -> quote(key)
  }
}

fn quote(s: String) -> String {
  "\"" <> escape_toml_string(s) <> "\""
}

fn escape_toml_string(s: String) -> String {
  s
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("\n", "\\n")
  |> string.replace("\t", "\\t")
}

// ---------------------------------------------------------------------------
// gleam.toml 정규화 — 문자열 repository를 gleam 호환 테이블로 변환
// ---------------------------------------------------------------------------

/// gleam.toml의 repository 문자열을 gleam 호환 테이블 형식으로 정규화
pub fn normalize_gleam_toml(directory: String) -> Result(Nil, Nil) {
  let path = directory <> "/gleam.toml"
  use content <- result.try(
    simplifile.read(path) |> result.map_error(fn(_) { Nil }),
  )
  use doc <- result.try(tom.parse(content) |> result.map_error(fn(_) { Nil }))
  case tom.get_string(doc, ["repository"]) {
    Ok(repo_str) ->
      case repo_string_to_table(repo_str) {
        Ok(table_str) -> {
          let new_content =
            string.split(content, "\n")
            |> list.map(fn(line) {
              case is_repository_assignment(string.trim(line)) {
                True -> table_str
                False -> line
              }
            })
            |> string.join("\n")
          simplifile.write(path, new_content)
          |> result.map_error(fn(_) { Nil })
        }
        Error(_) -> Ok(Nil)
      }
    Error(_) -> Ok(Nil)
  }
}

fn repo_string_to_table(repo: String) -> Result(String, Nil) {
  use #(repo_type, path) <- result.try(string.split_once(repo, ":"))
  use #(user, repo_name) <- result.try(string.split_once(path, "/"))
  Ok(
    "[repository]\ntype = "
    <> quote(repo_type)
    <> "\nuser = "
    <> quote(user)
    <> "\nrepo = "
    <> quote(repo_name),
  )
}

fn is_repository_assignment(line: String) -> Bool {
  case string.starts_with(line, "repository") {
    True ->
      case string.starts_with(line, "[") {
        True -> False
        False -> string.contains(line, "=")
      }
    False -> False
  }
}

// ---------------------------------------------------------------------------
// 의존성 추가/제거 (순수 함수)
// ---------------------------------------------------------------------------

/// KirConfig에 의존성 추가 (이미 있으면 교체)
pub fn add_dependency(config: KirConfig, dep: Dependency) -> KirConfig {
  case dep.registry, dep.dev {
    Hex, False ->
      KirConfig(..config, hex_deps: upsert_dep(config.hex_deps, dep))
    Hex, True ->
      KirConfig(..config, hex_dev_deps: upsert_dep(config.hex_dev_deps, dep))
    Npm, False ->
      KirConfig(..config, npm_deps: upsert_dep(config.npm_deps, dep))
    Npm, True ->
      KirConfig(..config, npm_dev_deps: upsert_dep(config.npm_dev_deps, dep))
    // Git/Url registry deps는 add_git_dependency/add_url_dependency 사용
    types.Git, _ -> config
    types.Url, _ -> config
  }
}

fn upsert_dep(deps: List(Dependency), dep: Dependency) -> List(Dependency) {
  let filtered = list.filter(deps, fn(d) { d.name != dep.name })
  [dep, ..filtered]
  |> list.sort(fn(a, b) { string.compare(a.name, b.name) })
}

/// KirConfig에서 의존성 제거
pub fn remove_dependency(
  config: KirConfig,
  name: String,
  registry: Registry,
) -> KirConfig {
  let remove = fn(deps: List(Dependency)) {
    list.filter(deps, fn(d) { d.name != name })
  }
  case registry {
    Hex ->
      KirConfig(
        ..config,
        hex_deps: remove(config.hex_deps),
        hex_dev_deps: remove(config.hex_dev_deps),
      )
    Npm ->
      KirConfig(
        ..config,
        npm_deps: remove(config.npm_deps),
        npm_dev_deps: remove(config.npm_dev_deps),
      )
    types.Git -> remove_git_dependency(config, name)
    types.Url -> remove_url_dependency(config, name)
  }
}

/// KirConfig에 Git 의존성 추가
pub fn add_git_dependency(config: KirConfig, dep: GitDep) -> KirConfig {
  case dep.dev {
    False -> KirConfig(..config, git_deps: upsert_git_dep(config.git_deps, dep))
    True ->
      KirConfig(
        ..config,
        git_dev_deps: upsert_git_dep(config.git_dev_deps, dep),
      )
  }
}

/// KirConfig에서 Git 의존성 제거
pub fn remove_git_dependency(config: KirConfig, name: String) -> KirConfig {
  let remove = fn(deps: List(GitDep)) {
    list.filter(deps, fn(d) { d.name != name })
  }
  KirConfig(
    ..config,
    git_deps: remove(config.git_deps),
    git_dev_deps: remove(config.git_dev_deps),
  )
}

/// KirConfig에 URL 의존성 추가
pub fn add_url_dependency(config: KirConfig, dep: UrlDep) -> KirConfig {
  case dep.dev {
    False -> KirConfig(..config, url_deps: upsert_url_dep(config.url_deps, dep))
    True ->
      KirConfig(
        ..config,
        url_dev_deps: upsert_url_dep(config.url_dev_deps, dep),
      )
  }
}

/// KirConfig에서 URL 의존성 제거
pub fn remove_url_dependency(config: KirConfig, name: String) -> KirConfig {
  let remove = fn(deps: List(UrlDep)) {
    list.filter(deps, fn(d) { d.name != name })
  }
  KirConfig(
    ..config,
    url_deps: remove(config.url_deps),
    url_dev_deps: remove(config.url_dev_deps),
  )
}

fn upsert_git_dep(deps: List(GitDep), dep: GitDep) -> List(GitDep) {
  let filtered = list.filter(deps, fn(d) { d.name != dep.name })
  [dep, ..filtered]
  |> list.sort(fn(a, b) { string.compare(a.name, b.name) })
}

fn upsert_url_dep(deps: List(UrlDep), dep: UrlDep) -> List(UrlDep) {
  let filtered = list.filter(deps, fn(d) { d.name != dep.name })
  [dep, ..filtered]
  |> list.sort(fn(a, b) { string.compare(a.name, b.name) })
}

/// deps와 dev-deps 양쪽에 중복 선언된 패키지명 반환
pub fn find_duplicate_deps(config: KirConfig) -> List(String) {
  let hex_names = list.map(config.hex_deps, fn(d) { d.name })
  let hex_dev_names = list.map(config.hex_dev_deps, fn(d) { d.name })
  let npm_names = list.map(config.npm_deps, fn(d) { d.name })
  let npm_dev_names = list.map(config.npm_dev_deps, fn(d) { d.name })
  let hex_dups =
    list.filter(hex_names, fn(n) { list.contains(hex_dev_names, n) })
  let npm_dups =
    list.filter(npm_names, fn(n) { list.contains(npm_dev_names, n) })
  list.append(hex_dups, npm_dups)
}
