//// SPDX 2.3 JSON 생성

import gleam/dict.{type Dict}
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import kirari/platform
import kirari/resolver.{type VersionInfo}
import kirari/types.{
  type KirConfig, type KirLock, type ResolvedPackage, Hex, Npm,
}

/// SPDX 2.3 JSON 문자열 생성
pub fn generate(
  config: KirConfig,
  lock: KirLock,
  version_infos: Dict(String, VersionInfo),
) -> String {
  let app_ver = platform.app_version() |> result.unwrap("unknown")
  let timestamp = platform.get_current_timestamp()
  let doc_ns =
    "https://spdx.org/spdxdocs/"
    <> config.package.name
    <> "-"
    <> config.package.version
    <> "-"
    <> platform.uuid_v4()
  let root_spdx_id = "SPDXRef-RootPackage"
  let root_pkg = root_package(config, root_spdx_id)
  let dep_packages =
    list.map(lock.packages, fn(pkg) { dep_package(pkg, version_infos) })
  let all_packages = [root_pkg, ..dep_packages]
  let relationships =
    list.map(lock.packages, fn(pkg) {
      relationship(root_spdx_id, pkg_spdx_id(pkg))
    })
  let doc =
    json.object([
      #("spdxVersion", json.string("SPDX-2.3")),
      #("dataLicense", json.string("CC0-1.0")),
      #("SPDXID", json.string("SPDXRef-DOCUMENT")),
      #("name", json.string(config.package.name)),
      #("documentNamespace", json.string(doc_ns)),
      #(
        "creationInfo",
        json.object([
          #("created", json.string(timestamp)),
          #(
            "creators",
            json.preprocessed_array([
              json.string("Tool: kirari-" <> app_ver),
            ]),
          ),
        ]),
      ),
      #("packages", json.preprocessed_array(all_packages)),
      #(
        "relationships",
        json.preprocessed_array([
          relationship("SPDXRef-DOCUMENT", root_spdx_id),
          ..relationships
        ]),
      ),
    ])
  json.to_string(doc)
}

fn root_package(config: KirConfig, spdx_id: String) -> json.Json {
  let license_str = case config.package.licences {
    [] -> "NOASSERTION"
    ls -> string.join(ls, " OR ")
  }
  json.object([
    #("SPDXID", json.string(spdx_id)),
    #("name", json.string(config.package.name)),
    #("versionInfo", json.string(config.package.version)),
    #("downloadLocation", json.string("NOASSERTION")),
    #("licenseConcluded", json.string(license_str)),
    #("licenseDeclared", json.string(license_str)),
    #("copyrightText", json.string("NOASSERTION")),
    #("primaryPackagePurpose", json.string("APPLICATION")),
  ])
}

fn dep_package(
  pkg: ResolvedPackage,
  version_infos: Dict(String, VersionInfo),
) -> json.Json {
  let spdx_id = pkg_spdx_id(pkg)
  let purl = pkg_purl(pkg)
  let key = pkg.name <> ":" <> types.registry_to_string(pkg.registry)
  let download_url = case dict.get(version_infos, key) {
    Ok(vi) if vi.tarball_url != "" -> vi.tarball_url
    _ -> "NOASSERTION"
  }
  let license_str = case pkg.license {
    "" -> "NOASSERTION"
    l -> l
  }
  let supplier = case pkg.registry {
    Hex -> "Organization: hex.pm"
    Npm -> "Organization: npmjs.com"
    types.Git -> "Organization: git"
    types.Url -> "Organization: url"
  }
  let checksums = case pkg.sha256 {
    "" -> []
    hash -> [
      json.object([
        #("algorithm", json.string("SHA256")),
        #("checksumValue", json.string(hash)),
      ]),
    ]
  }
  json.object([
    #("SPDXID", json.string(spdx_id)),
    #("name", json.string(pkg.name)),
    #("versionInfo", json.string(pkg.version)),
    #("supplier", json.string(supplier)),
    #("downloadLocation", json.string(download_url)),
    #("checksums", json.preprocessed_array(checksums)),
    #("licenseConcluded", json.string(license_str)),
    #("licenseDeclared", json.string(license_str)),
    #("copyrightText", json.string("NOASSERTION")),
    #(
      "externalRefs",
      json.preprocessed_array([
        json.object([
          #("referenceCategory", json.string("PACKAGE-MANAGER")),
          #("referenceType", json.string("purl")),
          #("referenceLocator", json.string(purl)),
        ]),
      ]),
    ),
  ])
}

fn relationship(from: String, to: String) -> json.Json {
  json.object([
    #("spdxElementId", json.string(from)),
    #("relatedSpdxElement", json.string(to)),
    #("relationshipType", json.string("DEPENDS_ON")),
  ])
}

fn pkg_spdx_id(pkg: ResolvedPackage) -> String {
  "SPDXRef-Package-" <> sanitize_id(pkg.name) <> "-" <> sanitize_id(pkg.version)
}

fn pkg_purl(pkg: ResolvedPackage) -> String {
  case pkg.registry {
    Hex -> "pkg:hex/" <> pkg.name <> "@" <> pkg.version
    Npm -> {
      let name = case string.starts_with(pkg.name, "@") {
        True -> string.replace(pkg.name, "/", "%2F")
        False -> pkg.name
      }
      "pkg:npm/" <> name <> "@" <> pkg.version
    }
    types.Git ->
      "pkg:generic/" <> pkg.name <> "@" <> pkg.version <> "?vcs_url=git"
    types.Url ->
      "pkg:generic/" <> pkg.name <> "@" <> pkg.version <> "?download_url=url"
  }
}

/// SPDX ID에 허용되지 않는 문자를 하이픈으로 교체
fn sanitize_id(s: String) -> String {
  string.to_graphemes(s)
  |> list.map(fn(c) {
    case is_spdx_id_char(c) {
      True -> c
      False -> "-"
    }
  })
  |> string.concat
}

fn is_spdx_id_char(c: String) -> Bool {
  case c {
    "a"
    | "b"
    | "c"
    | "d"
    | "e"
    | "f"
    | "g"
    | "h"
    | "i"
    | "j"
    | "k"
    | "l"
    | "m"
    | "n"
    | "o"
    | "p"
    | "q"
    | "r"
    | "s"
    | "t"
    | "u"
    | "v"
    | "w"
    | "x"
    | "y"
    | "z"
    | "A"
    | "B"
    | "C"
    | "D"
    | "E"
    | "F"
    | "G"
    | "H"
    | "I"
    | "J"
    | "K"
    | "L"
    | "M"
    | "N"
    | "O"
    | "P"
    | "Q"
    | "R"
    | "S"
    | "T"
    | "U"
    | "V"
    | "W"
    | "X"
    | "Y"
    | "Z"
    | "0"
    | "1"
    | "2"
    | "3"
    | "4"
    | "5"
    | "6"
    | "7"
    | "8"
    | "9"
    | "."
    | "-" -> True
    _ -> False
  }
}
