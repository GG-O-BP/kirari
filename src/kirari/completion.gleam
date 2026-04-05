//// 셸 자동완성 스크립트 생성 — bash, zsh, fish

import gleam/list
import gleam/string

// ---------------------------------------------------------------------------
// 명령 트리 정의
// ---------------------------------------------------------------------------

type Cmd {
  Cmd(name: String, subs: List(Cmd), flags: List(String))
}

fn command_tree() -> Cmd {
  Cmd(name: "kir", flags: ["--help", "--version"], subs: [
    Cmd(name: "init", subs: [], flags: []),
    Cmd(name: "install", subs: [], flags: [
      "--frozen", "--exclude-newer", "--offline", "--quiet", "--verify",
    ]),
    Cmd(name: "add", subs: [], flags: ["--npm", "--dev"]),
    Cmd(name: "remove", subs: [], flags: ["--npm"]),
    Cmd(name: "update", subs: [], flags: []),
    Cmd(
      name: "deps",
      subs: [
        Cmd(name: "list", subs: [], flags: ["--json"]),
        Cmd(name: "download", subs: [], flags: []),
      ],
      flags: [],
    ),
    Cmd(name: "tree", subs: [], flags: ["--json"]),
    Cmd(name: "outdated", subs: [], flags: ["--json"]),
    Cmd(name: "why", subs: [], flags: ["--json"]),
    Cmd(name: "diff", subs: [], flags: ["--json"]),
    Cmd(name: "ls", subs: [], flags: ["--json"]),
    Cmd(name: "doctor", subs: [], flags: []),
    Cmd(
      name: "store",
      subs: [
        Cmd(name: "verify", subs: [], flags: ["--quick", "--json"]),
      ],
      flags: [],
    ),
    Cmd(name: "license", subs: [], flags: ["--json"]),
    Cmd(name: "audit", subs: [], flags: ["--json", "--severity"]),
    Cmd(name: "clean", subs: [], flags: ["--store", "--keep-cache"]),
    Cmd(name: "build", subs: [], flags: []),
    Cmd(name: "run", subs: [], flags: []),
    Cmd(name: "test", subs: [], flags: []),
    Cmd(name: "check", subs: [], flags: []),
    Cmd(name: "dev", subs: [], flags: []),
    Cmd(name: "format", subs: [], flags: []),
    Cmd(name: "fix", subs: [], flags: []),
    Cmd(name: "new", subs: [], flags: []),
    Cmd(name: "shell", subs: [], flags: []),
    Cmd(name: "lsp", subs: [], flags: []),
    Cmd(name: "publish", subs: [], flags: ["--replace", "--yes", "--dry-run"]),
    Cmd(
      name: "hex",
      subs: [
        Cmd(name: "retire", subs: [], flags: []),
        Cmd(name: "unretire", subs: [], flags: []),
        Cmd(name: "revert", subs: [], flags: []),
        Cmd(name: "owner", subs: [], flags: []),
      ],
      flags: [],
    ),
    Cmd(
      name: "docs",
      subs: [
        Cmd(name: "build", subs: [], flags: []),
        Cmd(name: "publish", subs: [], flags: []),
        Cmd(name: "remove", subs: [], flags: []),
      ],
      flags: [],
    ),
    Cmd(
      name: "export",
      subs: [
        Cmd(name: "erlang-shipment", subs: [], flags: []),
        Cmd(name: "hex-tarball", subs: [], flags: []),
        Cmd(name: "javascript-prelude", subs: [], flags: []),
        Cmd(name: "typescript-prelude", subs: [], flags: []),
        Cmd(name: "package-interface", subs: [], flags: []),
        Cmd(name: "sbom", subs: [], flags: ["--format", "--output"]),
      ],
      flags: [],
    ),
    Cmd(name: "completion", subs: [], flags: []),
  ])
}

// ---------------------------------------------------------------------------
// 공개 API
// ---------------------------------------------------------------------------

/// bash 완성 스크립트 생성
pub fn generate_bash() -> String {
  let tree = command_tree()
  let subcmds = list.map(tree.subs, fn(c) { c.name })
  let cases = generate_bash_cases(tree.subs, "kir")
  "_kir() {
    local cur prev words cword
    _init_completion || return

    local commands=\"" <> string.join(subcmds, " ") <> "\"

    if [[ $cword -eq 1 ]]; then
        COMPREPLY=($(compgen -W \"$commands\" -- \"$cur\"))
        return
    fi

" <> cases <> "
    case \"${words[1]}\" in
        *)
            COMPREPLY=($(compgen -W \"$commands\" -- \"$cur\"))
            ;;
    esac
}

complete -F _kir kir
"
}

/// zsh 완성 스크립트 생성
pub fn generate_zsh() -> String {
  let tree = command_tree()
  let subcmd_specs =
    list.map(tree.subs, fn(c) { "'" <> c.name <> ":" <> c.name <> " command'" })
  let subcases = generate_zsh_subcases(tree.subs)
  "#compdef kir

_kir() {
    local -a commands
    commands=(
        " <> string.join(subcmd_specs, "\n        ") <> "
    )

    _arguments -C \\
        '1: :->cmd' \\
        '*::arg:->args'

    case $state in
        cmd)
            _describe 'command' commands
            ;;
        args)
            case $words[1] in
" <> subcases <> "
            esac
            ;;
    esac
}

_kir
"
}

/// fish 완성 스크립트 생성
pub fn generate_fish() -> String {
  let tree = command_tree()
  generate_fish_commands(tree.subs, "kir", True)
}

// ---------------------------------------------------------------------------
// bash 생성기
// ---------------------------------------------------------------------------

fn generate_bash_cases(cmds: List(Cmd), parent: String) -> String {
  list.map(cmds, fn(cmd) {
    let all_completions =
      list.append(list.map(cmd.subs, fn(s) { s.name }), cmd.flags)
    let sub_cases = case cmd.subs {
      [] -> ""
      subs -> {
        let inner = generate_bash_cases(subs, parent <> " " <> cmd.name)
        "        if [[ $cword -ge 3 && \"${words[2]}\" == \""
        <> cmd.name
        <> "\" ]]; then\n"
        <> inner
        <> "        fi\n"
      }
    }
    "    "
    <> cmd.name
    <> ")\n"
    <> sub_cases
    <> "        COMPREPLY=($(compgen -W \""
    <> string.join(all_completions, " ")
    <> "\" -- \"$cur\"))\n        ;;\n"
  })
  |> string.join("")
  |> fn(cases) {
    case cases {
      "" -> ""
      c -> "    case \"${words[cword-1]}\" in\n" <> c <> "    esac\n"
    }
  }
}

// ---------------------------------------------------------------------------
// zsh 생성기
// ---------------------------------------------------------------------------

fn generate_zsh_subcases(cmds: List(Cmd)) -> String {
  list.map(cmds, fn(cmd) {
    let flags_and_subs =
      list.append(
        list.map(cmd.flags, fn(f) { "'" <> f <> "'" }),
        list.map(cmd.subs, fn(s) { "'" <> s.name <> "'" }),
      )
    let completions = case flags_and_subs {
      [] -> "_files"
      _ -> "_arguments " <> string.join(flags_and_subs, " ")
    }
    "                "
    <> cmd.name
    <> ")\n                    "
    <> completions
    <> "\n                    ;;\n"
  })
  |> string.join("")
}

// ---------------------------------------------------------------------------
// fish 생성기
// ---------------------------------------------------------------------------

fn generate_fish_commands(
  cmds: List(Cmd),
  parent: String,
  is_root: Bool,
) -> String {
  let condition = case is_root {
    True -> "__fish_use_subcommand"
    False -> "__fish_seen_subcommand_from " <> parent
  }
  let lines =
    list.flat_map(cmds, fn(cmd) {
      let base =
        "complete -c kir -n '" <> condition <> "' -a '" <> cmd.name <> "'\n"
      let flag_lines =
        list.map(cmd.flags, fn(f) {
          let flag_name = string.drop_start(f, 2)
          "complete -c kir -n '__fish_seen_subcommand_from "
          <> cmd.name
          <> "' -l '"
          <> flag_name
          <> "'\n"
        })
      let sub_lines = case cmd.subs {
        [] -> ""
        subs -> generate_fish_commands(subs, cmd.name, False)
      }
      [base, ..list.append(flag_lines, [sub_lines])]
    })
  string.join(lines, "")
}
