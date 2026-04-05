//// CycloneDX 1.5 JSON 생성

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

/// CycloneDX 1.5 JSON 문자열 생성
pub fn generate(
  config: KirConfig,
  lock: KirLock,
  version_infos: Dict(String, VersionInfo),
) -> String {
  let app_ver = platform.app_version() |> result.unwrap("unknown")
  let timestamp = platform.get_current_timestamp()
  let serial = "urn:uuid:" <> platform.uuid_v4()
  let root_purl =
    "pkg:hex/" <> config.package.name <> "@" <> config.package.version
  let root_license = case config.package.licences {
    [] -> "NOASSERTION"
    ls -> string.join(ls, " OR ")
  }
  let components =
    list.map(lock.packages, fn(pkg) { component(pkg, version_infos) })
  let dep_entries =
    list.map(lock.packages, fn(pkg) { dependency_entry(pkg, version_infos) })
  let root_dep_purls =
    list.map(lock.packages, fn(pkg) { json.string(pkg_purl(pkg)) })
  let doc =
    json.object([
      #("bomFormat", json.string("CycloneDX")),
      #("specVersion", json.string("1.5")),
      #("serialNumber", json.string(serial)),
      #("version", json.int(1)),
      #(
        "metadata",
        json.object([
          #("timestamp", json.string(timestamp)),
          #(
            "tools",
            json.preprocessed_array([
              json.object([
                #("name", json.string("kirari")),
                #("version", json.string(app_ver)),
              ]),
            ]),
          ),
          #(
            "component",
            json.object([
              #("type", json.string("application")),
              #("name", json.string(config.package.name)),
              #("version", json.string(config.package.version)),
              #("bom-ref", json.string(root_purl)),
              #(
                "licenses",
                json.preprocessed_array([
                  json.object([
                    #(
                      "license",
                      json.object([
                        #("id", json.string(root_license)),
                      ]),
                    ),
                  ]),
                ]),
              ),
            ]),
          ),
        ]),
      ),
      #("components", json.preprocessed_array(components)),
      #(
        "dependencies",
        json.preprocessed_array([
          json.object([
            #("ref", json.string(root_purl)),
            #("dependsOn", json.preprocessed_array(root_dep_purls)),
          ]),
          ..dep_entries
        ]),
      ),
    ])
  json.to_string(doc)
}

fn component(
  pkg: ResolvedPackage,
  version_infos: Dict(String, VersionInfo),
) -> json.Json {
  let purl = pkg_purl(pkg)
  let key = pkg.name <> ":" <> types.registry_to_string(pkg.registry)
  let license_str = case pkg.license {
    "" -> "NOASSERTION"
    l -> l
  }
  let hashes = case pkg.sha256 {
    "" -> []
    hash -> [
      json.object([
        #("alg", json.string("SHA-256")),
        #("content", json.string(hash)),
      ]),
    ]
  }
  let _ = dict.get(version_infos, key)
  json.object([
    #("type", json.string("library")),
    #("name", json.string(pkg.name)),
    #("version", json.string(pkg.version)),
    #("bom-ref", json.string(purl)),
    #("purl", json.string(purl)),
    #("hashes", json.preprocessed_array(hashes)),
    #(
      "licenses",
      json.preprocessed_array([
        json.object([
          #("license", json.object([#("id", json.string(license_str))])),
        ]),
      ]),
    ),
  ])
}

fn dependency_entry(
  pkg: ResolvedPackage,
  version_infos: Dict(String, VersionInfo),
) -> json.Json {
  let purl = pkg_purl(pkg)
  let key = pkg.name <> ":" <> types.registry_to_string(pkg.registry)
  let child_purls = case dict.get(version_infos, key) {
    Ok(vi) ->
      list.map(vi.dependencies, fn(d) {
        let child_reg = types.registry_to_string(d.registry)
        let child_key = d.name <> ":" <> child_reg
        case dict.get(version_infos, child_key) {
          Ok(child_vi) ->
            json.string(make_purl(d.name, child_vi.version, d.registry))
          Error(_) ->
            json.string(make_purl(d.name, d.version_constraint, d.registry))
        }
      })
    Error(_) -> []
  }
  json.object([
    #("ref", json.string(purl)),
    #("dependsOn", json.preprocessed_array(child_purls)),
  ])
}

fn pkg_purl(pkg: ResolvedPackage) -> String {
  make_purl(pkg.name, pkg.version, pkg.registry)
}

fn make_purl(name: String, version: String, registry: types.Registry) -> String {
  case registry {
    Hex -> "pkg:hex/" <> name <> "@" <> version
    Npm -> {
      let encoded = case string.starts_with(name, "@") {
        True -> string.replace(name, "/", "%2F")
        False -> name
      }
      "pkg:npm/" <> encoded <> "@" <> version
    }
    types.Git -> "pkg:generic/" <> name <> "@" <> version <> "?vcs_url=git"
    types.Url -> "pkg:generic/" <> name <> "@" <> version <> "?download_url=url"
  }
}
