# kirari

A unified package manager for Gleam that replaces `gleam.toml` + `package.json` with a single `kir.toml`. Manages both Hex and npm dependencies in one workflow.

Written in Gleam, targeting Erlang (BEAM).

## Features

- **Single source of truth** — `kir.toml` is the only manifest you need
- **Content-addressable store** — SHA256-based `~/.kir/store` with hardlink installs
- **Parallel downloads** — concurrent dependency fetching
- **Deterministic lockfile** — same input always produces the same `kir.lock`
- **Supply chain security** — `--exclude-newer` and SHA256 hash verification by default

## Commands

| Command | Description |
|---------|-------------|
| `kir init` | Migrate from `gleam.toml` + `package.json` to `kir.toml` |
| `kir install` | Resolve and install Hex+npm dependencies, generate `kir.lock` |
| `kir add <pkg>` | Add a dependency (auto-detects Hex or npm) |
| `kir tree` | Print the unified dependency tree |
| `kir export` | Export `kir.toml` back to `gleam.toml` + `package.json` |

## Development

```sh
gleam build   # Build the project
gleam test    # Run the tests
gleam check   # Type check
gleam format  # Format source code
gleam run     # Run the project
```

## License

This project is licensed under the [Mozilla Public License 2.0](LICENSE).
