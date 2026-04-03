//// 레거시 내보내기 — kir.toml → gleam.toml + package.json

import gleam/json
import gleam/list
import gleam/result
import gleam/string
import kirari/types.{type KirConfig}
import simplifile

/// export 에러 타입
pub type ExportError {
  WriteError(path: String, detail: String)
}

/// gleam.toml과 package.json을 디렉토리에 내보내기
pub fn export(
  config: KirConfig,
  directory: String,
) -> Result(List(String), ExportError) {
  let gleam_path = directory <> "/gleam.toml"
  let written = []

  use _ <- result.try(
    simplifile.write(gleam_path, to_gleam_toml(config))
    |> result.map_error(fn(_) { WriteError(gleam_path, "failed to write") }),
  )
  let written = [gleam_path, ..written]

  // npm 의존성이 있을 때만 package.json 생성
  case list.append(config.npm_deps, config.npm_dev_deps) {
    [] -> Ok(list.reverse(written))
    _ -> {
      let pkg_path = directory <> "/package.json"
      use _ <- result.try(
        simplifile.write(pkg_path, to_package_json(config))
        |> result.map_error(fn(_) { WriteError(pkg_path, "failed to write") }),
      )
      Ok(list.reverse([pkg_path, ..written]))
    }
  }
}

/// KirConfig에서 gleam.toml 문자열 생성
pub fn to_gleam_toml(config: KirConfig) -> String {
  let pkg = config.package
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

  let deps_section = encode_gleam_deps("dependencies", config.hex_deps)
  let dev_deps_section =
    encode_gleam_deps("dev-dependencies", config.hex_dev_deps)

  [
    string.join(lines, "\n") <> "\n",
    deps_section,
    dev_deps_section,
  ]
  |> list.filter(fn(s) { s != "" })
  |> string.join("\n")
}

fn encode_gleam_deps(header: String, deps: List(types.Dependency)) -> String {
  case deps {
    [] -> ""
    _ -> {
      let sorted = list.sort(deps, fn(a, b) { string.compare(a.name, b.name) })
      let lines =
        list.map(sorted, fn(dep) {
          dep.name <> " = " <> quote(dep.version_constraint)
        })
      "[" <> header <> "]\n" <> string.join(lines, "\n") <> "\n"
    }
  }
}

/// KirConfig에서 package.json 문자열 생성
pub fn to_package_json(config: KirConfig) -> String {
  let deps =
    list.map(config.npm_deps, fn(d) {
      #(d.name, json.string(d.version_constraint))
    })
  let dev_deps =
    list.map(config.npm_dev_deps, fn(d) {
      #(d.name, json.string(d.version_constraint))
    })
  let entries = case deps {
    [] -> []
    _ -> [#("dependencies", json.object(deps))]
  }
  let entries = case dev_deps {
    [] -> entries
    _ -> list.append(entries, [#("devDependencies", json.object(dev_deps))])
  }
  json.object(entries)
  |> json.to_string
  <> "\n"
}

fn quote(s: String) -> String {
  "\""
  <> s
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  <> "\""
}
