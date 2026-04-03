import gleam/list
import gleeunit
import kirari/migrate
import kirari/types.{Npm}
import tom

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// gleam.toml 파싱
// ---------------------------------------------------------------------------

pub fn parse_gleam_toml_test() {
  let gleam_toml =
    "name = \"test_app\"
version = \"2.0.0\"
description = \"Test\"
licences = [\"MPL-2.0\"]

[dependencies]
gleam_stdlib = \">= 0.44.0 and < 2.0.0\"

[dev_dependencies]
gleeunit = \">= 1.0.0 and < 2.0.0\"
"
  let assert Ok(doc) = tom.parse(gleam_toml)
  let assert Ok(name) = tom.get_string(doc, ["name"])
  assert name == "test_app"
}

// ---------------------------------------------------------------------------
// package.json 파싱
// ---------------------------------------------------------------------------

pub fn parse_package_json_test() {
  let json_str =
    "{
  \"dependencies\": {
    \"highlight.js\": \"^11.0.0\",
    \"lodash\": \"^4.17.0\"
  },
  \"devDependencies\": {
    \"@types/node\": \"^18.0.0\"
  }
}"
  let assert Ok(deps) = migrate.parse_package_json(json_str)
  assert list.length(deps) == 3

  let assert Ok(highlight) = list.find(deps, fn(d) { d.name == "highlight.js" })
  assert highlight.registry == Npm
  assert highlight.dev == False
  assert highlight.version_constraint == "^11.0.0"

  let assert Ok(types_node) = list.find(deps, fn(d) { d.name == "@types/node" })
  assert types_node.dev == True
}

pub fn parse_package_json_empty_deps_test() {
  let json_str = "{}"
  let assert Ok(deps) = migrate.parse_package_json(json_str)
  assert deps == []
}
