//// FFI bare import 감지 — build/packages/ 내 .mjs 파일 정적 분석

import gleam/list
import gleam/option
import gleam/regexp
import gleam/result
import gleam/string
import kirari/types.{type Dependency, type KirConfig, Dependency, Npm}
import simplifile

/// 감지된 FFI import 항목
pub type FfiDetection {
  FfiDetection(package_name: String, source_file: String)
}

/// ffi 에러 타입
pub type FfiError {
  IoError(detail: String)
}

/// build/packages/ 내 .mjs 파일에서 bare npm import를 감지
pub fn detect_npm_imports(
  project_dir: String,
) -> Result(List(FfiDetection), FfiError) {
  let packages_dir = project_dir <> "/build/packages"
  case simplifile.get_files(packages_dir) {
    Ok(files) -> {
      let mjs_files = list.filter(files, fn(f) { string.ends_with(f, ".mjs") })
      let detections = list.flat_map(mjs_files, scan_file_for_imports)
      Ok(
        detections
        |> list.unique
        |> list.sort(fn(a, b) { string.compare(a.package_name, b.package_name) }),
      )
    }
    Error(_) -> Ok([])
  }
}

/// 감지된 import 중 kir.toml [npm]에 선언되지 않은 것만 필터
pub fn find_undeclared(
  detections: List(FfiDetection),
  config: KirConfig,
) -> List(FfiDetection) {
  let declared_names =
    list.append(config.npm_deps, config.npm_dev_deps)
    |> list.map(fn(d) { d.name })
  list.filter(detections, fn(d) {
    !list.contains(declared_names, d.package_name)
  })
}

/// 미선언 패키지를 Dependency 목록으로 변환
pub fn to_dependencies(detections: List(FfiDetection)) -> List(Dependency) {
  detections
  |> list.map(fn(d) { d.package_name })
  |> list.unique
  |> list.map(fn(name) {
    Dependency(
      name: name,
      version_constraint: "*",
      registry: Npm,
      dev: False,
      optional: False,
    )
  })
}

// ---------------------------------------------------------------------------
// 내부 구현
// ---------------------------------------------------------------------------

fn scan_file_for_imports(file_path: String) -> List(FfiDetection) {
  case simplifile.read(file_path) {
    Ok(content) ->
      string.split(content, "\n")
      |> list.filter_map(fn(line) { extract_bare_import(line, file_path) })
    Error(_) -> []
  }
}

fn extract_bare_import(
  line: String,
  file_path: String,
) -> Result(FfiDetection, Nil) {
  let trimmed = string.trim(line)
  // import ... from "specifier" 또는 import "specifier"
  use specifier <- result.try(extract_from_specifier(trimmed))
  case is_bare_import(specifier) {
    True ->
      Ok(FfiDetection(
        package_name: to_package_name(specifier),
        source_file: file_path,
      ))
    False -> Error(Nil)
  }
}

fn extract_from_specifier(line: String) -> Result(String, Nil) {
  // from "spec" | from 'spec' | import "spec"
  case
    regexp.from_string(
      "(?:from\\s+[\"']([^\"']+)[\"']|^import\\s+[\"']([^\"']+)[\"'])",
    )
  {
    Error(_) -> Error(Nil)
    Ok(re) ->
      case regexp.scan(re, line) {
        [match, ..] ->
          case match.submatches {
            [option.Some(spec), ..] -> Ok(spec)
            [option.None, option.Some(spec), ..] -> Ok(spec)
            _ -> Error(Nil)
          }
        [] -> Error(Nil)
      }
  }
}

/// bare import: 상대 경로, URL, Node.js 내장 모듈이 아닌 것
fn is_bare_import(specifier: String) -> Bool {
  !string.starts_with(specifier, ".")
  && !string.starts_with(specifier, "/")
  && !string.starts_with(specifier, "http://")
  && !string.starts_with(specifier, "https://")
  && !string.starts_with(specifier, "node:")
}

/// specifier를 패키지명으로 변환
/// "lodash/merge" → "lodash"
/// "@scope/pkg/deep" → "@scope/pkg"
fn to_package_name(specifier: String) -> String {
  case string.starts_with(specifier, "@") {
    True -> {
      // @scope/name/... → @scope/name
      case string.split(specifier, "/") {
        [scope, name, ..] -> scope <> "/" <> name
        _ -> specifier
      }
    }
    False -> {
      // name/path → name
      case string.split_once(specifier, "/") {
        Ok(#(name, _)) -> name
        Error(_) -> specifier
      }
    }
  }
}
