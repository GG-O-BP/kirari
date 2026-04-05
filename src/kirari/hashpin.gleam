//// Hash Pinning — .kir-hashes 독립 해시 허용 목록 관리
//// kir.lock과 별도로 패키지별 다중 해시를 관리하여 해시 교체, 빌드 재현성 검증 지원

import gleam/dict.{type Dict}
import gleam/list
import gleam/result
import gleam/string
import kirari/security
import kirari/types.{type Registry, type ResolvedPackage, Hex, Npm}
import simplifile
import tom.{type Toml}

/// hashpin 에러 타입
pub type HashpinError {
  FileNotFound(path: String)
  ParseError(detail: String)
  WriteError(path: String, detail: String)
}

/// 인메모리 해시 핀 목록
pub type HashPins {
  HashPins(hex: Dict(String, List(String)), npm: Dict(String, List(String)))
}

/// 해시 검증 결과
pub type PinCheckResult {
  /// 핀이 있고 해시가 일치
  PinMatched(name: String, registry: Registry)
  /// 핀이 있지만 해시 불일치
  PinMismatch(
    name: String,
    registry: Registry,
    actual: String,
    allowed: List(String),
  )
  /// 핀이 없음 — fallback to kir.lock
  NoPinEntry
}

/// 빈 HashPins
pub fn empty() -> HashPins {
  HashPins(hex: dict.new(), npm: dict.new())
}

// ---------------------------------------------------------------------------
// 읽기
// ---------------------------------------------------------------------------

/// 디렉토리에서 .kir-hashes 읽기 (없으면 빈 HashPins 반환)
pub fn read(directory: String) -> Result(HashPins, HashpinError) {
  let path = directory <> "/.kir-hashes"
  case simplifile.read(path) {
    Ok(content) -> parse(content)
    Error(_) -> Ok(empty())
  }
}

/// .kir-hashes 문자열 파싱
pub fn parse(content: String) -> Result(HashPins, HashpinError) {
  use doc <- result.try(
    tom.parse(content)
    |> result.map_error(fn(e) { ParseError(string.inspect(e)) }),
  )
  let hex = decode_registry_section(doc, "hex")
  let npm = decode_registry_section(doc, "npm")
  Ok(HashPins(hex: hex, npm: npm))
}

fn decode_registry_section(
  doc: Dict(String, Toml),
  section: String,
) -> Dict(String, List(String)) {
  case tom.get_table(doc, [section]) {
    Ok(table) ->
      dict.fold(table, dict.new(), fn(acc, key, value) {
        case value {
          tom.Array(items) -> {
            let hashes =
              list.filter_map(items, fn(item) {
                case item {
                  tom.String(s) -> Ok(string.lowercase(s))
                  _ -> Error(Nil)
                }
              })
            dict.insert(acc, key, hashes)
          }
          _ -> acc
        }
      })
    Error(_) -> dict.new()
  }
}

// ---------------------------------------------------------------------------
// 검증
// ---------------------------------------------------------------------------

/// 단일 패키지의 해시를 핀 목록과 대조
pub fn check(
  pins: HashPins,
  name: String,
  registry: Registry,
  actual_hash: String,
) -> PinCheckResult {
  let section = case registry {
    Hex -> pins.hex
    Npm -> pins.npm
  }
  case dict.get(section, name) {
    Ok(allowed) -> {
      let actual_lower = string.lowercase(actual_hash)
      let matched =
        list.any(allowed, fn(h) {
          security.constant_time_equal(h, actual_lower)
        })
      case matched {
        True -> PinMatched(name: name, registry: registry)
        False ->
          PinMismatch(
            name: name,
            registry: registry,
            actual: actual_lower,
            allowed: allowed,
          )
      }
    }
    Error(_) -> NoPinEntry
  }
}

/// 전체 패키지 목록을 핀 목록과 대조 (핀 없는 패키지는 제외)
pub fn check_all(
  pins: HashPins,
  packages: List(ResolvedPackage),
) -> List(PinCheckResult) {
  list.filter_map(packages, fn(pkg) {
    case pkg.sha256 {
      "" -> Error(Nil)
      hash ->
        case check(pins, pkg.name, pkg.registry, hash) {
          NoPinEntry -> Error(Nil)
          result -> Ok(result)
        }
    }
  })
}

// ---------------------------------------------------------------------------
// 쓰기
// ---------------------------------------------------------------------------

/// HashPins를 .kir-hashes TOML 문자열로 직렬��
pub fn encode(pins: HashPins) -> String {
  let hex_section = encode_section("hex", pins.hex)
  let npm_section = encode_section("npm", pins.npm)
  [hex_section, npm_section]
  |> list.filter(fn(s) { s != "" })
  |> string.join("\n")
}

fn encode_section(header: String, entries: Dict(String, List(String))) -> String {
  let sorted =
    dict.to_list(entries)
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  case sorted {
    [] -> ""
    _ -> {
      let lines =
        list.map(sorted, fn(entry) {
          let #(name, hashes) = entry
          let quoted_hashes = list.map(hashes, fn(h) { "\"" <> h <> "\"" })
          name <> " = [" <> string.join(quoted_hashes, ", ") <> "]"
        })
      "[" <> header <> "]\n" <> string.join(lines, "\n") <> "\n"
    }
  }
}

/// .kir-hashes 파일에 기록
pub fn write(pins: HashPins, directory: String) -> Result(Nil, HashpinError) {
  let path = directory <> "/.kir-hashes"
  let content = "# Hash allowlist — managed by kir hash pin\n" <> encode(pins)
  simplifile.write(path, content)
  |> result.map_error(fn(_) { WriteError(path, "failed to write") })
}

// ---------------------------------------------------------------------------
// 핀 추가
// ---------------------------------------------------------------------------

/// 패키지에 해시 추가 (중복 무시)
pub fn add_hash(
  pins: HashPins,
  name: String,
  registry: Registry,
  hash: String,
) -> HashPins {
  let hash_lower = string.lowercase(hash)
  case registry {
    Hex -> {
      let existing = dict.get(pins.hex, name) |> result.unwrap([])
      let updated = case list.contains(existing, hash_lower) {
        True -> existing
        False -> list.append(existing, [hash_lower])
      }
      HashPins(..pins, hex: dict.insert(pins.hex, name, updated))
    }
    Npm -> {
      let existing = dict.get(pins.npm, name) |> result.unwrap([])
      let updated = case list.contains(existing, hash_lower) {
        True -> existing
        False -> list.append(existing, [hash_lower])
      }
      HashPins(..pins, npm: dict.insert(pins.npm, name, updated))
    }
  }
}
