//// gleam.toml 파싱/직렬화 및 의존성 조작
//// gleam 네이티브 섹션([dependencies], [dev-dependencies])과
//// kirari 확장 섹션([npm-dependencies], [dev-npm-dependencies], [security])을 통합 관리

import gleam/dict.{type Dict}
import gleam/list
import gleam/result
import gleam/string
import kirari/types.{
  type Dependency, type KirConfig, type PackageInfo, type PathDep, type Registry,
  type SecurityConfig, Dependency, Hex, KirConfig, Npm, PackageInfo, PathDep,
  SecurityConfig,
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
  Ok(KirConfig(
    package: package,
    hex_deps: hex_deps,
    hex_dev_deps: hex_dev_deps,
    npm_deps: npm_deps,
    npm_dev_deps: npm_dev_deps,
    security: security,
    path_deps: path_deps,
    path_dev_deps: path_dev_deps,
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
  Ok(PackageInfo(
    name: name,
    version: version,
    description: description,
    target: target,
    licences: licences,
    repository: repository,
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
            Ok(Dependency(
              name: name,
              version_constraint: constraint,
              registry: registry,
              dev: dev,
            ))
          _ -> Error(Nil)
        }
      })
      |> list.sort(fn(a, b) { string.compare(a.name, b.name) })
    Error(_) -> []
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
  SecurityConfig(
    exclude_newer: exclude_newer,
    npm_scripts: npm_scripts,
    provenance: provenance,
    license_policy: license_policy,
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
    encode_repository(config.package),
    encode_dep_section("dependencies", config.hex_deps, config.path_deps),
    encode_dep_section(
      "dev-dependencies",
      config.hex_dev_deps,
      config.path_dev_deps,
    ),
    encode_dep_section("npm-dependencies", config.npm_deps, []),
    encode_dep_section("dev-npm-dependencies", config.npm_dev_deps, []),
    encode_security_section(config.security),
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
          #(
            dep.name,
            quote_key(dep.name) <> " = " <> quote(dep.version_constraint),
          )
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

fn encode_security_section(sec: SecurityConfig) -> String {
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
  case lines {
    [] -> ""
    _ -> "[security]\n" <> string.join(list.reverse(lines), "\n") <> "\n"
  }
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
  }
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
