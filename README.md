# kirari

A unified package manager for Gleam that replaces `gleam.toml` + `package.json` with a single `kir.toml`. Manages both Hex and npm dependencies in one workflow. Run it with the `kir` command.

Written in Gleam, targeting Erlang (BEAM).

## Features

- **Single source of truth** — `kir.toml` is the only manifest you need
- **Content-addressable store** — SHA256-based `~/.kir/store` with hardlink installs
- **Parallel downloads** — concurrent dependency fetching
- **Deterministic lockfile** — same input always produces the same `kir.lock`
- **Supply chain security** — `--exclude-newer` and SHA256 hash verification by default
- **FFI detection** — auto-detects undeclared npm imports in `.mjs` files

## Installation

Requires [Gleam](https://gleam.run) and Erlang/OTP.

```sh
git clone https://github.com/GG-O-BP/kirari.git
cd kirari
gleam build
```

## Commands

| Command | Description |
|---------|-------------|
| `kir init` | Migrate from `gleam.toml` + `package.json` to `kir.toml` |
| `kir install` | Resolve and install Hex+npm dependencies, generate `kir.lock` |
| `kir add <pkg> [--npm] [--dev]` | Add a dependency (auto-detects Hex or npm) |
| `kir tree` | Print the unified dependency tree |
| `kir export` | Export `kir.toml` back to `gleam.toml` + `package.json` |

## kir.toml

```toml
[package]
name = "my_app"
version = "1.0.0"
description = "My Gleam application"
target = "erlang"
licences = ["MIT"]

[hex]
gleam_stdlib = ">= 0.44.0 and < 2.0.0"
gleam_json = ">= 3.0.0 and < 4.0.0"

[hex.dev]
gleeunit = ">= 1.0.0 and < 2.0.0"

[npm]
highlight.js = "^11.0.0"

[npm.dev]

[security]
exclude-newer = "2026-04-01T00:00:00Z"
```

## kir.lock

Deterministic TOML lockfile with SHA256 hashes, sorted alphabetically by package name.

```toml
version = 1

[[package]]
name = "gleam_stdlib"
registry = "hex"
sha256 = "702f3bc2..."
version = "0.71.0"
```

CI usage: `kir install --frozen` fails if the lock doesn't match resolved dependencies.

## Comparison with Gleam's Built-in Package Manager

| | Gleam (built-in) | kirari |
|---|---|---|
| **Config file** | `gleam.toml` (Hex only) + separate `package.json` (npm) | `kir.toml` (Hex + npm unified) |
| **Lockfile** | `manifest.toml` | `kir.lock` |
| **Lockfile hash** | `outer_checksum` (SHA256, from Hex registry) | `sha256` (SHA256, computed locally) |
| **npm dependency management** | Not managed; requires separate `package.json` and npm/yarn/pnpm | Native; declared in `kir.toml [npm]`, resolved alongside Hex |
| **Dependency resolution** | PubGrub (backtracking) | Greedy (highest compatible, no backtracking) |
| **Local package store** | Downloads to `build/packages/` per project | Content-addressable `~/.kir/store/` shared across projects |
| **Installation method** | Copy | Hardlink with copy fallback |
| **`exclude-newer`** | Not available | `[security] exclude-newer` limits resolution to versions published before a timestamp |
| **Dependency tree** | `gleam deps tree` | `kir tree` |
| **FFI import detection** | Not available | Scans `.mjs` in `build/packages/` for undeclared npm bare imports |
| **Export** | `gleam export erlang-shipment`, `hex-tarball` | `kir export` generates `gleam.toml` + `package.json` from `kir.toml` |
| **Migration** | N/A | `kir init` reads existing `gleam.toml` + `package.json` into `kir.toml` |
| **Written in** | Rust | Gleam |

## Architecture

```
src/kirari.gleam          Entry point
src/kirari/
  cli.gleam               CLI dispatcher (glint)
  types.gleam             Shared domain types
  config.gleam            kir.toml / gleam.toml / package.json parsing
  semver.gleam            SemVer parsing, Hex + npm constraint matching
  resolver.gleam          Greedy dependency resolution
  lockfile.gleam          kir.lock read/write
  security.gleam          SHA256, path validation, exclude-newer
  registry/hex.gleam      Hex.pm API client
  registry/npm.gleam      npm registry API client
  store.gleam             Content-addressable package store
  installer.gleam         Hardlink/copy installation
  platform.gleam          Erlang FFI wrappers
  tree.gleam              Dependency tree rendering
  export.gleam            Legacy gleam.toml + package.json export
  ffi.gleam               Bare import detection in .mjs files
src/kirari_ffi.erl        Erlang FFI (tar, hardlink, rename)
```

## Development

```sh
gleam build    # Build the project
gleam test     # Run the tests (101 tests)
gleam check    # Type check
gleam format   # Format source code
gleam run      # Run kirari
```

## License

This project is licensed under the [Mozilla Public License 2.0](LICENSE).
