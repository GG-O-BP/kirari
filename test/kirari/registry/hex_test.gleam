import gleam/list
import gleeunit
import kirari/registry/hex

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// JSON 파싱 테스트 (모의 응답)
// ---------------------------------------------------------------------------

fn mock_hex_response() -> String {
  "{
  \"releases\": [
    {
      \"version\": \"0.44.0\",
      \"inserted_at\": \"2024-01-15T10:00:00Z\",
      \"requirements\": {}
    },
    {
      \"version\": \"0.45.0\",
      \"inserted_at\": \"2024-03-01T12:00:00Z\",
      \"requirements\": {
        \"gleam_stdlib\": {
          \"requirement\": \">= 0.40.0\",
          \"optional\": false,
          \"app\": \"gleam_stdlib\"
        }
      }
    }
  ]
}"
}

pub fn parse_versions_response_test() {
  let assert Ok(versions) = hex.parse_versions_response(mock_hex_response())
  assert list.length(versions) == 2
}

pub fn parse_version_fields_test() {
  let assert Ok(versions) = hex.parse_versions_response(mock_hex_response())
  let assert Ok(first) = list.first(versions)
  assert first.version == "0.44.0"
  assert first.inserted_at == "2024-01-15T10:00:00Z"
  assert first.dependencies == []
}

pub fn parse_version_with_deps_test() {
  let assert Ok(versions) = hex.parse_versions_response(mock_hex_response())
  let assert [_, second, ..] = versions
  assert list.length(second.dependencies) == 1
  let assert [dep] = second.dependencies
  assert dep.name == "gleam_stdlib"
  assert dep.requirement == ">= 0.40.0"
  assert dep.optional == False
}

pub fn parse_empty_releases_test() {
  let json = "{\"releases\": []}"
  let assert Ok(versions) = hex.parse_versions_response(json)
  assert versions == []
}

pub fn parse_invalid_json_test() {
  let assert Error(hex.ParseResponseError(_)) =
    hex.parse_versions_response("not json")
}

// ---------------------------------------------------------------------------
// requirements 배열 형식 지원
// ---------------------------------------------------------------------------

pub fn parse_requirements_as_list_test() {
  let json =
    "{
  \"releases\": [
    {
      \"version\": \"1.0.0\",
      \"requirements\": [
        {\"name\": \"gleam_stdlib\", \"requirement\": \">= 0.40.0\", \"optional\": false}
      ]
    }
  ]
}"
  let assert Ok(versions) = hex.parse_versions_response(json)
  let assert Ok(v) = list.first(versions)
  assert list.length(v.dependencies) == 1
}
