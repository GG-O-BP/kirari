//// kir.lock 파싱/직렬화 — 결정론적 lockfile 관리

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import kirari/types.{
  type KirLock, type Registry, type ResolvedPackage, Hex, KirLock, Npm,
  ResolvedPackage,
}
import simplifile
import tom.{type Toml}

/// lockfile 모듈 전용 에러 타입
pub type LockfileError {
  FileNotFound(path: String)
  ParseError(detail: String)
  FrozenMismatch(detail: String)
  WriteError(path: String, detail: String)
}

// ---------------------------------------------------------------------------
// 읽기
// ---------------------------------------------------------------------------

/// 디렉토리에서 kir.lock 파일을 읽어 KirLock으로 변환
pub fn read(directory: String) -> Result(KirLock, LockfileError) {
  let path = directory <> "/kir.lock"
  use content <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(_) { FileNotFound(path) }),
  )
  parse(content)
}

/// kir.lock 문자열을 파싱
pub fn parse(content: String) -> Result(KirLock, LockfileError) {
  use doc <- result.try(
    tom.parse(content)
    |> result.map_error(fn(e) { ParseError(string.inspect(e)) }),
  )
  use version <- result.try(
    tom.get_int(doc, ["version"])
    |> result.map_error(fn(_) { ParseError("missing version field") }),
  )
  let packages = decode_packages(doc)
  Ok(KirLock(version: version, packages: packages))
}

fn decode_packages(doc: Dict(String, Toml)) -> List(ResolvedPackage) {
  case tom.get_array(doc, ["package"]) {
    Ok(items) ->
      list.filter_map(items, decode_one_package)
      |> list.sort(types.compare_packages)
    Error(_) -> []
  }
}

fn decode_one_package(toml_val: Toml) -> Result(ResolvedPackage, Nil) {
  case toml_val {
    tom.Table(table) | tom.InlineTable(table) -> {
      use name <- result.try(
        tom.get_string(table, ["name"]) |> result.replace_error(Nil),
      )
      use version <- result.try(
        tom.get_string(table, ["version"]) |> result.replace_error(Nil),
      )
      use registry_str <- result.try(
        tom.get_string(table, ["registry"]) |> result.replace_error(Nil),
      )
      use registry <- result.try(parse_registry(registry_str))
      use sha256 <- result.try(
        tom.get_string(table, ["sha256"]) |> result.replace_error(Nil),
      )
      Ok(ResolvedPackage(
        name: name,
        version: version,
        registry: registry,
        sha256: sha256,
      ))
    }
    _ -> Error(Nil)
  }
}

fn parse_registry(s: String) -> Result(Registry, Nil) {
  case string.lowercase(s) {
    "hex" -> Ok(Hex)
    "npm" -> Ok(Npm)
    _ -> Error(Nil)
  }
}

// ---------------------------------------------------------------------------
// 쓰기
// ---------------------------------------------------------------------------

/// KirLock을 디렉토리의 kir.lock에 기록
pub fn write(lock: KirLock, directory: String) -> Result(Nil, LockfileError) {
  let path = directory <> "/kir.lock"
  let content = encode(lock)
  simplifile.write(path, content)
  |> result.map_error(fn(_) { WriteError(path, "failed to write file") })
}

/// KirLock을 결정론적 TOML 문자열로 직렬화
pub fn encode(lock: KirLock) -> String {
  let header = "version = " <> int.to_string(lock.version) <> "\n"
  let sorted = list.sort(lock.packages, types.compare_packages)
  let package_blocks =
    list.map(sorted, encode_package)
    |> string.join("\n")
  case sorted {
    [] -> header
    _ -> header <> "\n" <> package_blocks
  }
}

fn encode_package(pkg: ResolvedPackage) -> String {
  // 필드를 사전순: name, registry, sha256, version
  "[[package]]\n"
  <> "name = "
  <> quote(pkg.name)
  <> "\n"
  <> "registry = "
  <> quote(types.registry_to_string(pkg.registry))
  <> "\n"
  <> "sha256 = "
  <> quote(pkg.sha256)
  <> "\n"
  <> "version = "
  <> quote(pkg.version)
  <> "\n"
}

fn quote(s: String) -> String {
  "\""
  <> s
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  <> "\""
}

// ---------------------------------------------------------------------------
// 생성 헬퍼
// ---------------------------------------------------------------------------

/// 패키지 목록에서 KirLock 생성 (사전순 정렬)
pub fn from_packages(packages: List(ResolvedPackage)) -> KirLock {
  KirLock(version: 1, packages: list.sort(packages, types.compare_packages))
}

// ---------------------------------------------------------------------------
// 패키지 조회
// ---------------------------------------------------------------------------

/// lock에서 이름+레지스트리로 패키지 검색
pub fn find_package(
  lock: KirLock,
  name: String,
  registry: Registry,
) -> Option(ResolvedPackage) {
  list.find(lock.packages, fn(p) { p.name == name && p.registry == registry })
  |> option.from_result
}

// ---------------------------------------------------------------------------
// frozen 모드 검증
// ---------------------------------------------------------------------------

/// 기존 lock과 새로 해결된 패키지 목록이 일치하는지 검증
pub fn verify_frozen(
  existing: KirLock,
  resolved: List(ResolvedPackage),
) -> Result(Nil, LockfileError) {
  let new_lock = from_packages(resolved)
  let existing_encoded = encode(existing)
  let new_encoded = encode(new_lock)
  case existing_encoded == new_encoded {
    True -> Ok(Nil)
    False -> Error(FrozenMismatch(describe_diff(existing, new_lock)))
  }
}

fn describe_diff(old: KirLock, new: KirLock) -> String {
  let old_names =
    list.map(old.packages, fn(p) {
      p.name
      <> "@"
      <> p.version
      <> " ("
      <> types.registry_to_string(p.registry)
      <> ")"
    })
  let new_names =
    list.map(new.packages, fn(p) {
      p.name
      <> "@"
      <> p.version
      <> " ("
      <> types.registry_to_string(p.registry)
      <> ")"
    })
  let added = list.filter(new_names, fn(n) { !list.contains(old_names, n) })
  let removed = list.filter(old_names, fn(n) { !list.contains(new_names, n) })
  let parts = []
  let parts = case added {
    [] -> parts
    _ -> list.append(parts, ["added: " <> string.join(added, ", ")])
  }
  let parts = case removed {
    [] -> parts
    _ -> list.append(parts, ["removed: " <> string.join(removed, ", ")])
  }
  case parts {
    [] -> "lockfile content differs"
    _ -> string.join(parts, "; ")
  }
}
