//// 의존성 트리 출력 — 유니코드 박스 문자 사용

import gleam/list
import gleam/string
import kirari/types.{type KirConfig, type KirLock}

/// 트리 노드
pub type TreeNode {
  TreeNode(
    name: String,
    version: String,
    registry: String,
    children: List(TreeNode),
  )
}

/// KirConfig(직접 의존성)과 KirLock(해결된 전체 패키지)에서 트리 구성
pub fn build(config: KirConfig, lock: KirLock) -> List(TreeNode) {
  let direct_names =
    list.flatten([
      list.map(config.hex_deps, fn(d) { #(d.name, d.registry) }),
      list.map(config.hex_dev_deps, fn(d) { #(d.name, d.registry) }),
      list.map(config.npm_deps, fn(d) { #(d.name, d.registry) }),
      list.map(config.npm_dev_deps, fn(d) { #(d.name, d.registry) }),
    ])

  list.filter_map(direct_names, fn(pair) {
    let #(name, registry) = pair
    case
      list.find(lock.packages, fn(p) {
        p.name == name && p.registry == registry
      })
    {
      Ok(pkg) ->
        Ok(
          TreeNode(
            name: pkg.name,
            version: pkg.version,
            registry: types.registry_to_string(pkg.registry),
            children: [],
          ),
        )
      Error(_) -> Error(Nil)
    }
  })
  |> list.sort(fn(a, b) { string.compare(a.name, b.name) })
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
      let line =
        prefix
        <> connector
        <> node.name
        <> " v"
        <> node.version
        <> " ("
        <> node.registry
        <> ")"
      let child_lines = render_nodes(node.children, child_prefix)
      [line, ..list.append(child_lines, render_indexed(rest, prefix, total))]
    }
  }
}
