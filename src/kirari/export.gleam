//// 내보내기 — manifest.toml, packages.toml, package.json 생성

import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import gleam/string_tree.{type StringTree}
import gleam/time/calendar
import gleam/time/duration
import kirari/resolver
import kirari/semver
import kirari/types.{type KirConfig, type KirLock, Hex}
import simplifile
import tom

/// JSON pretty-print (Erlang OTP 27+ json:format/1)
@external(erlang, "kirari_ffi", "json_pretty")
fn json_pretty(input: StringTree) -> String

/// export 에러 타입
pub type ExportError {
  WriteError(path: String, detail: String)
}

/// kir export: manifest.toml + packages.toml + package.json 생성
pub fn export(
  config: KirConfig,
  lock: Result(KirLock, Nil),
  version_infos: Result(Dict(String, resolver.VersionInfo), Nil),
  directory: String,
) -> Result(List(String), ExportError) {
  let written = []
  // manifest.toml
  let written = case lock {
    Ok(l) -> {
      let path = directory <> "/manifest.toml"
      case simplifile.write(path, to_manifest_toml(config, l, version_infos)) {
        Ok(_) -> [path, ..written]
        Error(_) -> written
      }
    }
    Error(_) -> written
  }
  // build/packages/packages.toml
  let written = case lock {
    Ok(l) -> {
      let path = directory <> "/build/packages/packages.toml"
      let _ = simplifile.create_directory_all(directory <> "/build/packages")
      case simplifile.write(path, to_packages_toml(l)) {
        Ok(_) -> [path, ..written]
        Error(_) -> written
      }
    }
    Error(_) -> written
  }
  // package.json (npm 의존성 또는 [npm-package] 섹션이 있을 때)
  let has_npm =
    !list.is_empty(config.npm_deps)
    || !list.is_empty(config.npm_dev_deps)
    || !dict.is_empty(config.npm_package)
  case has_npm {
    False -> Ok(list.reverse(written))
    _ -> {
      let path = directory <> "/package.json"
      use _ <- result.try(
        simplifile.write(path, to_package_json(config))
        |> result.map_error(fn(_) { WriteError(path, "failed to write") }),
      )
      Ok(list.reverse([path, ..written]))
    }
  }
}

/// kir install/update/add/remove 후: packages.toml만 생성
/// manifest.toml은 gleam이 직접 생성 (requirements 필드를 정확히 채우기 위해)
/// config는 현재 미사용이나, manifest.toml 직접 생성 전환 시 필요
pub fn write_build_metadata(
  _config: KirConfig,
  lock: KirLock,
  directory: String,
) -> Result(Nil, ExportError) {
  let pkgs_path = directory <> "/build/packages/packages.toml"
  let _ = simplifile.create_directory_all(directory <> "/build/packages")
  let _ = simplifile.write(pkgs_path, to_packages_toml(lock))
  Ok(Nil)
}

/// package.json 문자열 생성 — 자동 파생 + [npm-package] passthrough + 의존성
pub fn to_package_json(config: KirConfig) -> String {
  // 1. 자동 파생 필드 (gleam.toml 기본 섹션)
  let derived = derive_fields(config)
  // 2. [npm-package] raw TOML → JSON entries (자동 파생 override)
  let npm_entries =
    dict.to_list(config.npm_package)
    |> list.map(fn(pair) { #(pair.0, toml_to_json(pair.1)) })
  let merged =
    list.fold(npm_entries, derived, fn(acc, entry) {
      dict.insert(acc, entry.0, entry.1)
    })
  // 3. dependencies/devDependencies (kirari 관리, 최우선)
  let merged = case config.npm_deps {
    [] -> merged
    deps -> {
      let dep_entries =
        list.map(deps, fn(d) {
          #(
            d.name,
            json.string(semver.hex_to_npm_constraint(d.version_constraint)),
          )
        })
      dict.insert(merged, "dependencies", json.object(dep_entries))
    }
  }
  let merged = case config.npm_dev_deps {
    [] -> merged
    deps -> {
      let dep_entries =
        list.map(deps, fn(d) {
          #(
            d.name,
            json.string(semver.hex_to_npm_constraint(d.version_constraint)),
          )
        })
      dict.insert(merged, "devDependencies", json.object(dep_entries))
    }
  }
  // 4. npm 표준 필드 순서로 정렬
  let sorted = sort_npm_fields(dict.to_list(merged))
  json.object(sorted)
  |> json.to_string_tree
  |> json_pretty
  <> "\n"
}

/// gleam.toml 기본 섹션에서 자동 파생 필드 생성
fn derive_fields(config: KirConfig) -> Dict(String, json.Json) {
  let pkg = config.package
  let fields = dict.new()
  // name
  let fields = dict.insert(fields, "name", json.string(pkg.name))
  // version
  let fields = dict.insert(fields, "version", json.string(pkg.version))
  // description
  let fields = case pkg.description {
    "" -> fields
    d -> dict.insert(fields, "description", json.string(d))
  }
  // license (licences → SPDX expression)
  let fields = case pkg.licences {
    [] -> fields
    [single] -> dict.insert(fields, "license", json.string(single))
    multiple ->
      dict.insert(
        fields,
        "license",
        json.string("(" <> string.join(multiple, " OR ") <> ")"),
      )
  }
  // repository
  let fields = case pkg.repository {
    Error(_) -> fields
    Ok(repo) -> dict.insert(fields, "repository", repository_to_json(repo))
  }
  // homepage (links에서 title="Website" 항목)
  let fields = case list.find(pkg.links, fn(link) { link.0 == "Website" }) {
    Ok(link) -> dict.insert(fields, "homepage", json.string(link.1))
    Error(_) -> fields
  }
  // engines.node
  let fields = case config.engines.node {
    Ok(node_constraint) ->
      dict.insert(
        fields,
        "engines",
        json.object([#("node", json.string(node_constraint))]),
      )
    Error(_) -> fields
  }
  fields
}

/// repository 문자열을 npm package.json 형식 JSON으로 변환
fn repository_to_json(repo: String) -> json.Json {
  case string.split_once(repo, ":") {
    Ok(#(repo_type, path)) -> {
      let url = case repo_type {
        "github" -> "git+https://github.com/" <> path <> ".git"
        "gitlab" -> "git+https://gitlab.com/" <> path <> ".git"
        "bitbucket" -> "git+https://bitbucket.org/" <> path <> ".git"
        _ -> repo
      }
      json.object([
        #("type", json.string("git")),
        #("url", json.string(url)),
      ])
    }
    Error(_) -> json.string(repo)
  }
}

// ---------------------------------------------------------------------------
// npm 필드 순서
// ---------------------------------------------------------------------------

/// npm 관례 필드 순서
const npm_field_order = [
  "name", "version", "description", "keywords", "homepage", "bugs", "license",
  "author", "contributors", "funding", "files", "exports", "main", "type",
  "browser", "bin", "man", "directories", "repository", "scripts", "gypfile",
  "config", "dependencies", "devDependencies", "peerDependencies",
  "peerDependenciesMeta", "bundleDependencies", "optionalDependencies",
  "overrides", "engines", "os", "cpu", "libc", "devEngines", "private",
  "publishConfig", "workspaces",
]

fn sort_npm_fields(
  entries: List(#(String, json.Json)),
) -> List(#(String, json.Json)) {
  let order_map =
    list.index_map(npm_field_order, fn(field, idx) { #(field, idx) })
    |> dict.from_list
  let max_idx = list.length(npm_field_order)
  list.sort(entries, fn(a, b) {
    let a_idx = dict.get(order_map, a.0) |> result.unwrap(max_idx)
    let b_idx = dict.get(order_map, b.0) |> result.unwrap(max_idx)
    case a_idx == b_idx {
      True -> string.compare(a.0, b.0)
      False -> int.compare(a_idx, b_idx)
    }
  })
}

// ---------------------------------------------------------------------------
// TOML → JSON 변환
// ---------------------------------------------------------------------------

/// TOML 값을 JSON 값으로 재귀 변환
fn toml_to_json(value: tom.Toml) -> json.Json {
  case value {
    tom.String(s) -> json.string(s)
    tom.Int(i) -> json.int(i)
    tom.Float(f) -> json.float(f)
    tom.Bool(b) -> json.bool(b)
    tom.Array(items) -> json.preprocessed_array(list.map(items, toml_to_json))
    tom.Table(d) | tom.InlineTable(d) -> table_to_json(d)
    tom.ArrayOfTables(tables) ->
      json.preprocessed_array(list.map(tables, table_to_json))
    tom.Date(d) -> json.string(date_to_string(d))
    tom.Time(t) -> json.string(time_to_string(t))
    tom.DateTime(d, t, offset) ->
      json.string(
        date_to_string(d)
        <> "T"
        <> time_to_string(t)
        <> offset_to_string(offset),
      )
    tom.Infinity(_) | tom.Nan(_) -> json.null()
  }
}

fn table_to_json(d: Dict(String, tom.Toml)) -> json.Json {
  json.object(
    dict.to_list(d)
    |> list.map(fn(pair) { #(pair.0, toml_to_json(pair.1)) }),
  )
}

fn date_to_string(d: calendar.Date) -> String {
  pad4(d.year)
  <> "-"
  <> pad2(calendar.month_to_int(d.month))
  <> "-"
  <> pad2(d.day)
}

fn time_to_string(t: calendar.TimeOfDay) -> String {
  pad2(t.hours) <> ":" <> pad2(t.minutes) <> ":" <> pad2(t.seconds)
}

fn offset_to_string(offset: tom.Offset) -> String {
  case offset {
    tom.Local -> ""
    tom.Offset(dur) -> {
      let total_minutes = float.truncate(duration.to_seconds(dur)) / 60
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

/// manifest.toml 문자열 생성
pub fn to_manifest_toml(
  config: KirConfig,
  lock: KirLock,
  version_infos: Result(Dict(String, resolver.VersionInfo), Nil),
) -> String {
  let header = "# This file was generated by kirari\n"
  let hex_packages =
    list.filter(lock.packages, fn(p) {
      p.registry == Hex || p.registry == types.Git || p.registry == types.Url
    })
    |> list.sort(fn(a, b) { string.compare(a.name, b.name) })
  let package_entries =
    list.map(hex_packages, fn(p) {
      let reqs = get_package_requirements(p.name, version_infos)
      "  { name = "
      <> quote(p.name)
      <> ", version = "
      <> quote(p.version)
      <> ", build_tools = [\"gleam\"], requirements = ["
      <> string.join(list.map(reqs, quote), ", ")
      <> "], otp_app = "
      <> quote(p.name)
      <> ", source = \"hex\", outer_checksum = "
      <> quote(string.uppercase(p.sha256))
      <> " }"
    })
  let packages_section =
    "packages = [\n" <> string.join(package_entries, ",\n") <> "\n]\n"
  let all_hex_deps =
    list.append(config.hex_deps, config.hex_dev_deps)
    |> list.sort(fn(a, b) { string.compare(a.name, b.name) })
  let req_entries =
    list.map(all_hex_deps, fn(d) {
      d.name <> " = { version = " <> quote(d.version_constraint) <> " }"
    })
  let requirements_section = case req_entries {
    [] -> ""
    _ -> "\n[requirements]\n" <> string.join(req_entries, "\n") <> "\n"
  }
  header <> "\n" <> packages_section <> requirements_section
}

fn get_package_requirements(
  name: String,
  version_infos: Result(Dict(String, resolver.VersionInfo), Nil),
) -> List(String) {
  case version_infos {
    Ok(vis) -> {
      let key = name <> ":hex"
      case dict.get(vis, key) {
        Ok(vi) ->
          list.map(vi.dependencies, fn(d) { d.name })
          |> list.sort(string.compare)
        Error(_) -> []
      }
    }
    Error(_) -> []
  }
}

/// packages.toml 문자열 생성 (gleam build 다운로드 스킵용)
pub fn to_packages_toml(lock: KirLock) -> String {
  let hex_packages =
    list.filter(lock.packages, fn(p) {
      p.registry == Hex || p.registry == types.Git || p.registry == types.Url
    })
    |> list.sort(fn(a, b) { string.compare(a.name, b.name) })
  let entries =
    list.map(hex_packages, fn(p) { p.name <> " = " <> quote(p.version) })
  "[packages]\n" <> string.join(entries, "\n") <> "\n"
}

fn quote(s: String) -> String {
  "\""
  <> s
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  <> "\""
}
