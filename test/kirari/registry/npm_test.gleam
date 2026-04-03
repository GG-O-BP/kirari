import gleam/list
import gleeunit
import kirari/registry/npm

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// URL 인코딩
// ---------------------------------------------------------------------------

pub fn encode_package_name_regular_test() {
  assert npm.encode_package_name("lodash") == "lodash"
}

pub fn encode_package_name_scoped_test() {
  assert npm.encode_package_name("@codemirror/view") == "@codemirror%2fview"
}

// ---------------------------------------------------------------------------
// JSON 파싱 테스트 (모의 응답)
// ---------------------------------------------------------------------------

fn mock_npm_response() -> String {
  "{
  \"versions\": {
    \"1.0.0\": {
      \"dist\": {
        \"tarball\": \"https://registry.npmjs.org/foo/-/foo-1.0.0.tgz\"
      },
      \"dependencies\": {
        \"bar\": \"^2.0.0\"
      }
    },
    \"1.1.0\": {
      \"dist\": {
        \"tarball\": \"https://registry.npmjs.org/foo/-/foo-1.1.0.tgz\"
      }
    }
  },
  \"time\": {
    \"1.0.0\": \"2024-01-15T10:00:00Z\",
    \"1.1.0\": \"2024-06-01T12:00:00Z\"
  }
}"
}

pub fn parse_versions_response_test() {
  let assert Ok(versions) = npm.parse_versions_response(mock_npm_response())
  assert list.length(versions) == 2
}

pub fn parse_version_fields_test() {
  let assert Ok(versions) = npm.parse_versions_response(mock_npm_response())
  let assert Ok(v1) = list.find(versions, fn(v) { v.version == "1.0.0" })
  assert v1.published_at == "2024-01-15T10:00:00Z"
  assert v1.tarball_url == "https://registry.npmjs.org/foo/-/foo-1.0.0.tgz"
  assert list.length(v1.dependencies) == 1
  let assert Ok(dep) = list.first(v1.dependencies)
  assert dep.name == "bar"
  assert dep.constraint == "^2.0.0"
}

pub fn parse_version_no_deps_test() {
  let assert Ok(versions) = npm.parse_versions_response(mock_npm_response())
  let assert Ok(v2) = list.find(versions, fn(v) { v.version == "1.1.0" })
  assert v2.dependencies == []
  assert v2.published_at == "2024-06-01T12:00:00Z"
}

pub fn parse_empty_versions_test() {
  let json = "{\"versions\": {}}"
  let assert Ok(versions) = npm.parse_versions_response(json)
  assert versions == []
}

pub fn parse_invalid_json_test() {
  let assert Error(npm.ParseResponseError(_)) =
    npm.parse_versions_response("not json")
}

pub fn parse_no_time_field_test() {
  let json =
    "{
  \"versions\": {
    \"1.0.0\": {
      \"dist\": {\"tarball\": \"https://example.com/foo.tgz\"}
    }
  }
}"
  let assert Ok(versions) = npm.parse_versions_response(json)
  let assert Ok(v) = list.first(versions)
  assert v.published_at == ""
}
