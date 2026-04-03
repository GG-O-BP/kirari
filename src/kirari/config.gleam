//// kir.toml 파싱/직렬화 및 의존성 조작

import gleam/dict.{type Dict}
import gleam/list
import gleam/result
import gleam/string
import kirari/types.{
  type Dependency, type KirConfig, type PackageInfo, type Registry,
  type SecurityConfig, Dependency, Hex, KirConfig, Npm, PackageInfo,
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
// kir.toml 읽기
// ---------------------------------------------------------------------------

/// 디렉토리에서 kir.toml을 읽어 KirConfig로 변환
pub fn read_kir_toml(directory: String) -> Result(KirConfig, ConfigError) {
  let path = directory <> "/kir.toml"
  use content <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(_) { FileNotFound(path) }),
  )
  parse_kir_toml(content)
}

/// kir.toml 문자열을 파싱
pub fn parse_kir_toml(content: String) -> Result(KirConfig, ConfigError) {
  use doc <- result.try(
    tom.parse(content)
    |> result.map_error(fn(e) { ParseError(string.inspect(e)) }),
  )
  decode_kir_config(doc)
}

fn decode_kir_config(doc: Dict(String, Toml)) -> Result(KirConfig, ConfigError) {
  use package <- result.try(decode_package_section(doc))
  let hex_deps = decode_deps_from_table(doc, ["hex"], Hex, False)
  let hex_dev_deps = decode_deps_from_table(doc, ["hex", "dev"], Hex, True)
  let npm_deps = decode_deps_from_table(doc, ["npm"], Npm, False)
  let npm_dev_deps = decode_deps_from_table(doc, ["npm", "dev"], Npm, True)
  let security = decode_security_section(doc)
  Ok(KirConfig(
    package: package,
    hex_deps: hex_deps,
    hex_dev_deps: hex_dev_deps,
    npm_deps: npm_deps,
    npm_dev_deps: npm_dev_deps,
    security: security,
  ))
}

fn decode_package_section(
  doc: Dict(String, Toml),
) -> Result(PackageInfo, ConfigError) {
  use table <- result.try(
    tom.get_table(doc, ["package"])
    |> result.map_error(fn(_) {
      InvalidField("package", "missing [package] section")
    }),
  )
  use name <- result.try(
    tom.get_string(table, ["name"])
    |> result.map_error(fn(_) { InvalidField("package.name", "required") }),
  )
  use version <- result.try(
    tom.get_string(table, ["version"])
    |> result.map_error(fn(_) { InvalidField("package.version", "required") }),
  )
  let description = tom.get_string(table, ["description"]) |> result.unwrap("")
  let target = tom.get_string(table, ["target"]) |> result.unwrap("erlang")
  let licences = decode_string_array(table, ["licences"])
  let repository =
    tom.get_string(table, ["repository"])
    |> result.map_error(fn(_) { Nil })
  Ok(PackageInfo(
    name: name,
    version: version,
    description: description,
    target: target,
    licences: licences,
    repository: repository,
  ))
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
          // sub-table ("dev" 등) 은 건너뛴다
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
  SecurityConfig(exclude_newer: exclude_newer)
}

// ---------------------------------------------------------------------------
// kir.toml 쓰기
// ---------------------------------------------------------------------------

/// KirConfig를 디렉토리의 kir.toml에 기록
pub fn write_kir_toml(
  config: KirConfig,
  directory: String,
) -> Result(Nil, ConfigError) {
  let path = directory <> "/kir.toml"
  let content = encode_kir_toml(config)
  simplifile.write(path, content)
  |> result.map_error(fn(_) { WriteError(path, "failed to write file") })
}

/// KirConfig를 TOML 문자열로 직렬화
pub fn encode_kir_toml(config: KirConfig) -> String {
  [
    encode_package_section(config.package),
    encode_dep_section("hex", config.hex_deps),
    encode_dep_section("hex.dev", config.hex_dev_deps),
    encode_dep_section("npm", config.npm_deps),
    encode_dep_section("npm.dev", config.npm_dev_deps),
    encode_security_section(config.security),
  ]
  |> list.filter(fn(s) { s != "" })
  |> string.join("\n")
}

fn encode_package_section(pkg: PackageInfo) -> String {
  let lines = ["[package]", "name = " <> quote(pkg.name)]
  let lines = list.append(lines, ["version = " <> quote(pkg.version)])
  let lines = case pkg.description {
    "" -> lines
    d -> list.append(lines, ["description = " <> quote(d)])
  }
  let lines = list.append(lines, ["target = " <> quote(pkg.target)])
  let lines = case pkg.licences {
    [] -> lines
    ls ->
      list.append(lines, [
        "licences = [" <> string.join(list.map(ls, quote), ", ") <> "]",
      ])
  }
  let lines = case pkg.repository {
    Ok(url) -> list.append(lines, ["repository = " <> quote(url)])
    Error(_) -> lines
  }
  string.join(lines, "\n") <> "\n"
}

fn encode_dep_section(header: String, deps: List(Dependency)) -> String {
  case deps {
    [] -> ""
    _ -> {
      let sorted = list.sort(deps, fn(a, b) { string.compare(a.name, b.name) })
      let lines =
        list.map(sorted, fn(dep) {
          quote_key(dep.name) <> " = " <> quote(dep.version_constraint)
        })
      "[" <> header <> "]\n" <> string.join(lines, "\n") <> "\n"
    }
  }
}

fn encode_security_section(sec: SecurityConfig) -> String {
  case sec.exclude_newer {
    Ok(ts) -> "[security]\nexclude-newer = " <> quote(ts) <> "\n"
    Error(_) -> ""
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
              // a-z, A-Z, 0-9
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
