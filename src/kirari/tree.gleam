//// 의존성 트리 출력 — 전이 의존성 포함, 유니코드 박스 문자 사용

import gleam/dict.{type Dict}
import gleam/json
import gleam/list
import gleam/string
import kirari/resolver
import kirari/types.{type KirConfig, type KirLock}

/// 트리 노드
pub type TreeNode {
  TreeNode(
    name: String,
    version: String,
    registry: String,
    children: List(TreeNode),
    dev: Bool,
  )
}

/// KirConfig(직접 의존성), KirLock(해결된 패키지), version_infos(의존성 관계)에서 트리 구성
pub fn build(
  config: KirConfig,
  lock: KirLock,
  version_infos: Dict(String, resolver.VersionInfo),
) -> List(TreeNode) {
  let direct_names =
    list.flatten([
      list.map(config.hex_deps, fn(d) { #(d.name, d.registry) }),
      list.map(config.hex_dev_deps, fn(d) { #(d.name, d.registry) }),
      list.map(config.npm_deps, fn(d) { #(d.name, d.registry) }),
      list.map(config.npm_dev_deps, fn(d) { #(d.name, d.registry) }),
      list.map(config.git_deps, fn(d) { #(d.name, types.Git) }),
      list.map(config.git_dev_deps, fn(d) { #(d.name, types.Git) }),
      list.map(config.url_deps, fn(d) { #(d.name, types.Url) }),
      list.map(config.url_dev_deps, fn(d) { #(d.name, types.Url) }),
    ])

  list.filter_map(direct_names, fn(pair) {
    let #(name, registry) = pair
    case
      list.find(lock.packages, fn(p) {
        p.name == name && p.registry == registry
      })
    {
      Ok(pkg) -> {
        let key = pkg.name <> ":" <> types.registry_to_string(pkg.registry)
        Ok(build_node(key, pkg, lock, version_infos, []))
      }
      Error(_) -> Error(Nil)
    }
  })
  |> list.sort(fn(a, b) { string.compare(a.name, b.name) })
}

/// 재귀적으로 트리 노드 구축 (visited로 순환 방지)
fn build_node(
  key: String,
  pkg: types.ResolvedPackage,
  lock: KirLock,
  version_infos: Dict(String, resolver.VersionInfo),
  visited: List(String),
) -> TreeNode {
  let children = case list.contains(visited, key) {
    // 순환 방지: 이미 방문한 패키지는 children 없이
    True -> []
    False -> {
      let new_visited = [key, ..visited]
      case dict.get(version_infos, key) {
        Ok(vi) ->
          list.filter_map(vi.dependencies, fn(dep) {
            let dep_key =
              dep.name <> ":" <> types.registry_to_string(dep.registry)
            case
              list.find(lock.packages, fn(p) {
                p.name == dep.name && p.registry == dep.registry
              })
            {
              Ok(dep_pkg) ->
                Ok(build_node(
                  dep_key,
                  dep_pkg,
                  lock,
                  version_infos,
                  new_visited,
                ))
              Error(_) -> Error(Nil)
            }
          })
          |> list.sort(fn(a, b) { string.compare(a.name, b.name) })
        Error(_) -> []
      }
    }
  }
  TreeNode(
    name: pkg.name,
    version: pkg.version,
    registry: types.registry_to_string(pkg.registry),
    children: children,
    dev: pkg.dev,
  )
}

/// 트리를 JSON 문자열로 직렬화 (재귀)
pub fn to_json(roots: List(TreeNode)) -> String {
  json.array(roots, node_to_json)
  |> json.to_string
}

fn node_to_json(node: TreeNode) -> json.Json {
  json.object([
    #("name", json.string(node.name)),
    #("version", json.string(node.version)),
    #("registry", json.string(node.registry)),
    #("dev", json.bool(node.dev)),
    #("children", json.array(node.children, node_to_json)),
  ])
}

/// 트리를 문자열로 렌더링
pub fn render(roots: List(TreeNode)) -> String {
  render_nodes(roots, "")
  |> string.join("\n")
}

fn render_nodes(nodes: List(TreeNode), prefix: String) -> List(String) {
  case nodes {
    [] -> []
    _ -> render_indexed(nodes, prefix, list.length(nodes))
  }
}

fn render_indexed(
  nodes: List(TreeNode),
  prefix: String,
  total: Int,
) -> List(String) {
  case nodes {
    [] -> []
    [node, ..rest] -> {
      let index = total - list.length(rest)
      let is_last = index == total
      let connector = case is_last {
        True -> "└── "
        False -> "├── "
      }
      let child_prefix = case is_last {
        True -> prefix <> "    "
        False -> prefix <> "│   "
      }
      let dev_suffix = case node.dev {
        True -> " (dev)"
        False -> ""
      }
      let line =
        prefix
        <> connector
        <> node.name
        <> " v"
        <> node.version
        <> " ("
        <> node.registry
        <> ")"
        <> dev_suffix
      let child_lines = render_nodes(node.children, child_prefix)
      [line, ..list.append(child_lines, render_indexed(rest, prefix, total))]
    }
  }
}
