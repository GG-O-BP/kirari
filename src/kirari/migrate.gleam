//// 마이그레이션 — gleam.toml + package.json → KirConfig 변환 (kir init 용)

import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import kirari/types.{
  type Dependency, type KirConfig, type PathDep, Dependency, Hex, KirConfig, Npm,
  PackageInfo, PathDep,
}
import simplifile
import tom.{type Toml}

/// migrate 모듈 전용 에러 타입
pub type MigrateError {
  FileNotFound(path: String)
  ParseError(detail: String)
  InvalidField(field: String, detail: String)
}

// ---------------------------------------------------------------------------
// gleam.toml 읽기
// ---------------------------------------------------------------------------

/// gleam.toml을 읽어 KirConfig로 변환
pub fn read_gleam_toml(directory: String) -> Result(KirConfig, MigrateError) {
  let path = directory <> "/gleam.toml"
  use content <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(_) { FileNotFound(path) }),
  )
  use doc <- result.try(
    tom.parse(content)
    |> result.map_error(fn(e) { ParseError(string.inspect(e)) }),
  )
  decode_gleam_toml(doc)
}

fn decode_gleam_toml(doc: Dict(String, Toml)) -> Result(KirConfig, MigrateError) {
  use name <- result.try(
    tom.get_string(doc, ["name"])
    |> result.map_error(fn(_) { InvalidField("name", "required in gleam.toml") }),
  )
  let version = tom.get_string(doc, ["version"]) |> result.unwrap("0.1.0")
  let description = tom.get_string(doc, ["description"]) |> result.unwrap("")
  let target = tom.get_string(doc, ["target"]) |> result.unwrap("erlang")
  let licences = decode_string_array(doc, ["licences"])
  let repository = decode_gleam_repository(doc)

  let hex_deps = decode_gleam_deps(doc, "dependencies", False)
  let hex_dev_deps = decode_gleam_deps(doc, "dev-dependencies", False)
  // gleam.toml은 dev_dependencies (underscore)도 사용
  let hex_dev_deps = case hex_dev_deps {
    [] -> decode_gleam_deps(doc, "dev_dependencies", False)
    _ -> hex_dev_deps
  }
  let path_deps = decode_gleam_path_deps(doc, "dependencies", False)
  let path_dev_deps = case
    decode_gleam_path_deps(doc, "dev-dependencies", True)
  {
    [] -> decode_gleam_path_deps(doc, "dev_dependencies", True)
    deps -> deps
  }

  let package =
    PackageInfo(
      name: name,
      version: version,
      description: description,
      target: target,
      licences: licences,
      repository: repository,
    )

  Ok(
    KirConfig(
      package: package,
      hex_deps: hex_deps,
      hex_dev_deps: hex_dev_deps,
      npm_deps: [],
      npm_dev_deps: [],
      security: types.default_security_config(),
      path_deps: path_deps,
      path_dev_deps: path_dev_deps,
      overrides: [],
    ),
  )
}

fn decode_gleam_repository(doc: Dict(String, Toml)) -> Result(String, Nil) {
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
    Error(_) -> Error(Nil)
  }
}

fn decode_gleam_deps(
  doc: Dict(String, Toml),
  section: String,
  dev: Bool,
) -> List(Dependency) {
  case tom.get_table(doc, [section]) {
    Ok(table) ->
      dict.to_list(table)
      |> list.filter_map(fn(entry) {
        let #(name, value) = entry
        case value {
          tom.String(constraint) ->
            Ok(Dependency(
              name: name,
              version_constraint: constraint,
              registry: Hex,
              dev: dev,
              optional: False,
            ))
          _ -> Error(Nil)
        }
      })
      |> list.sort(fn(a, b) { string.compare(a.name, b.name) })
    Error(_) -> []
  }
}

fn decode_gleam_path_deps(
  doc: Dict(String, Toml),
  section: String,
  dev: Bool,
) -> List(PathDep) {
  case tom.get_table(doc, [section]) {
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

// ---------------------------------------------------------------------------
// package.json 읽기
// ---------------------------------------------------------------------------

/// package.json에서 npm 의존성 목록 추출
pub fn read_package_json(
  directory: String,
) -> Result(List(Dependency), MigrateError) {
  let path = directory <> "/package.json"
  use content <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(_) { FileNotFound(path) }),
  )
  parse_package_json(content)
}

/// package.json 문자열에서 npm 의존성 파싱
pub fn parse_package_json(
  content: String,
) -> Result(List(Dependency), MigrateError) {
  let decoder = {
    use deps <- decode.optional_field(
      "dependencies",
      dict.new(),
      decode.dict(decode.string, decode.string),
    )
    use dev_deps <- decode.optional_field(
      "devDependencies",
      dict.new(),
      decode.dict(decode.string, decode.string),
    )
    decode.success(#(deps, dev_deps))
  }

  use pair <- result.try(
    json.parse(content, decoder)
    |> result.map_error(fn(e) { ParseError(string.inspect(e)) }),
  )

  let #(deps, dev_deps) = pair
  let npm_deps =
    dict.to_list(deps)
    |> list.map(fn(entry) {
      let #(name, constraint) = entry
      Dependency(
        name: name,
        version_constraint: constraint,
        registry: Npm,
        dev: False,
        optional: False,
      )
    })
  let npm_dev_deps =
    dict.to_list(dev_deps)
    |> list.map(fn(entry) {
      let #(name, constraint) = entry
      Dependency(
        name: name,
        version_constraint: constraint,
        registry: Npm,
        dev: True,
        optional: False,
      )
    })

  Ok(
    list.append(npm_deps, npm_dev_deps)
    |> list.sort(fn(a, b) { string.compare(a.name, b.name) }),
  )
}

// ---------------------------------------------------------------------------
// 내부 헬퍼
// ---------------------------------------------------------------------------

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
