# kirari

A unified package manager for Gleam. Extends `gleam.toml` with `[npm-dependencies]` and `[security]` sections to manage both Hex and npm dependencies in one workflow. Run it with the `kir` command.

Written in Gleam, targeting Erlang (BEAM).

## Features

- **Single config file** — `gleam.toml` is the only manifest, extended with kirari sections
- **Content-addressable store** — SHA256-based `~/.kir/store` with hardlink installs
- **Parallel downloads** — concurrent dependency fetching with automatic retry
- **Deterministic lockfile** — same input always produces the same `kir.lock`
- **Supply chain security** — `--exclude-newer` and SHA256 hash verification by default
- **FFI detection** — warns about undeclared npm imports in `.mjs` files after install
- **`gleam build` compatible** — gleam ignores kirari sections; auto-generates `manifest.toml` + `packages.toml`

## Installation

Requires [Erlang/OTP](https://www.erlang.org/) 28 or later.

### Linux/macOS

```sh
curl -fsSL https://github.com/GG-O-BP/kirari/releases/latest/download/kirari-linux-x86_64.tar.gz | tar -xz -C /usr/local/lib
sudo ln -sf /usr/local/lib/erlang-shipment/kir /usr/local/bin/kir
kir --version
```

### Windows

```powershell
# Download kirari-windows-x86_64.zip from GitHub Releases
Expand-Archive kirari-windows-x86_64.zip -DestinationPath C:\kirari
[Environment]::SetEnvironmentVariable("Path", $env:Path + ";C:\kirari\erlang-shipment", "User")
# Restart terminal, then:
kir --version
```

### Quick Start

```sh
cd my-gleam-project
kir init                     # Add kirari sections to gleam.toml
kir add gleam_json           # Add a Hex package
kir add highlight.js --npm   # Add an npm package
kir install                  # Resolve and install all dependencies
kir build                    # Build the project
kir test                     # Run tests
```

### Build from Source

Requires [Gleam](https://gleam.run) and Erlang/OTP.

```sh
git clone https://github.com/GG-O-BP/kirari.git
cd kirari
gleam build
```

## Commands

### Dependency Management

| Command | Description |
|---------|-------------|
| `kir init` | Add kirari sections to `gleam.toml`, merge `package.json` npm deps |
| `kir install [--frozen] [--exclude-newer=<TS>]` | Resolve and install dependencies, generate `kir.lock` |
| `kir update` | Update all dependencies to latest compatible versions (ignores lock) |
| `kir add <pkg> [--npm] [--dev]` | Add a dependency and install (auto-detects Hex or npm) |
| `kir remove <pkg> [--npm]` | Remove a dependency and reinstall |
| `kir deps list` | List all dependencies with versions and registries |
| `kir deps download` | Download dependencies without installing |
| `kir tree` | Print the unified dependency tree |
| `kir clean` | Remove `build/` and `node_modules/` directories |

### Build & Run

These commands sync dependencies via `~/.kir/store/` before delegating to Gleam:

| Command | Description |
|---------|-------------|
| `kir build` | Sync dependencies, then `gleam build` |
| `kir run` | Sync dependencies, then `gleam run` |
| `kir test` | Sync dependencies, then `gleam test` |
| `kir check` | Sync dependencies, then `gleam check` |
| `kir dev` | Sync dependencies, then `gleam dev` |

These pass through to Gleam directly:

| Command | Description |
|---------|-------------|
| `kir format` | Format source code |
| `kir fix` | Rewrite deprecated code |
| `kir new` | Create a new Gleam project |
| `kir shell` | Start an Erlang shell |
| `kir lsp` | Run the language server |
| `kir docs build` | Build documentation |
| `kir docs publish` | Publish documentation |
| `kir docs remove` | Remove published documentation |

### Publishing

| Command | Description |
|---------|-------------|
| `kir publish [--replace] [--yes]` | Publish package to Hex |
| `kir hex retire <pkg> <ver> <reason> [msg]` | Retire a release from Hex |
| `kir hex unretire <pkg> <ver>` | Un-retire a release from Hex |

### Export

| Command | Description |
|---------|-------------|
| `kir export` | Export `manifest.toml` + `packages.toml` + `package.json` |
| `kir export erlang-shipment` | Export precompiled Erlang for deployment |
| `kir export hex-tarball` | Export package as tarball for Hex publishing |
| `kir export javascript-prelude` | Export JavaScript prelude module |
| `kir export typescript-prelude` | Export TypeScript prelude module |
| `kir export package-interface` | Export package interface as JSON |

### Flags

- `--frozen` — Verify lockfile matches resolution without downloading or installing. For CI.
- `--exclude-newer=<TIMESTAMP>` — Exclude versions published after the given RFC 3339 timestamp.
- `--npm` — Force npm registry (for `add` and `remove`).
- `--dev` — Add as dev dependency (for `add`).
- `--replace` — Replace existing version on Hex (for `publish`).
- `--yes` — Skip confirmation prompt (for `publish`).

## gleam.toml

kirari extends `gleam.toml` with additional sections that the Gleam compiler ignores:

```toml
name = "my_app"
version = "1.0.0"
description = "My Gleam application"
licences = ["MIT"]

[dependencies]
gleam_stdlib = ">= 0.44.0 and < 2.0.0"
gleam_json = ">= 3.0.0 and < 4.0.0"

[dev-dependencies]
gleeunit = ">= 1.0.0 and < 2.0.0"

[npm-dependencies]
highlight.js = "^11.0.0"

[dev-npm-dependencies]
@types/node = "^18.0.0"

[security]
exclude-newer = "2026-04-01T00:00:00Z"
```

`[dependencies]` and `[dev-dependencies]` are native Gleam sections. `[npm-dependencies]`, `[dev-npm-dependencies]`, and `[security]` are kirari extensions that Gleam silently ignores.

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

## How kirari works with Gleam

kirari is a package manager, not a compiler. It extends `gleam.toml` with extra sections and manages the full dependency lifecycle. The Gleam compiler reads the same `gleam.toml` but ignores kirari's sections.

```
gleam.toml (single source of truth)
    │
    ├── [dependencies], [dev-dependencies]     ← Gleam reads these
    ├── [npm-dependencies], [dev-npm-dependencies]  ← kirari reads, Gleam ignores
    └── [security]                             ← kirari reads, Gleam ignores
    │
    ▼
kir install
    │
    ├── kir.lock                    ← deterministic lockfile
    ├── manifest.toml               ← auto-generated for gleam build
    ├── build/packages/packages.toml ← auto-generated for gleam build
    └── ~/.kir/store/ → build/packages/ (hardlinks)

gleam build (reads gleam.toml + manifest.toml, skips download)
```

**Rules:**
- Edit `gleam.toml` only. Never edit `manifest.toml` directly.
- Use `kir add`/`kir remove` instead of `gleam add`/`gleam remove`.
- `gleam build`, `gleam test`, `gleam run` work as usual after `kir install`.

## Comparison with Gleam's Built-in Package Manager

| | Gleam (built-in) | kirari |
|---|---|---|
| **Config file** | `gleam.toml` (Hex only) + separate `package.json` (npm) | `gleam.toml` with extended sections (Hex + npm unified) |
| **Lockfile** | `manifest.toml` | `kir.lock` |
| **Lockfile hash** | `outer_checksum` (SHA256, from Hex registry) | `sha256` (SHA256, computed locally) |
| **npm dependency management** | Not managed; requires separate `package.json` and npm/yarn/pnpm | Native; declared in `gleam.toml [npm-dependencies]`, resolved alongside Hex |
| **Dependency resolution** | PubGrub (backtracking) | Greedy (highest compatible, no backtracking, diamond conflict detection) |
| **Local package store** | Downloads to `build/packages/` per project | Content-addressable `~/.kir/store/` shared across projects |
| **Installation method** | Copy | Hardlink with copy fallback |
| **`exclude-newer`** | Not available | `[security] exclude-newer` or `--exclude-newer` flag |
| **Dependency tree** | `gleam deps tree` | `kir tree` |
| **FFI import detection** | Not available | Warns about undeclared npm bare imports after install |
| **Export** | `gleam export erlang-shipment`, `hex-tarball` | `kir export` + all gleam export subcommands via passthrough |
| **Publishing** | `gleam publish`, `gleam hex retire/unretire` | `kir publish`, `kir hex retire/unretire` (delegates to gleam) |
| **Written in** | Rust | Gleam |

## Architecture

```
src/kirari.gleam          Entry point
src/kirari/
  cli.gleam               CLI dispatcher (glint)
  types.gleam             Shared domain types
  config.gleam            gleam.toml parsing/serialization (native + kirari sections)
  migrate.gleam           package.json migration for kir init
  semver.gleam            SemVer parsing, Hex + npm constraint matching
  resolver.gleam          Dependency resolution with transitive deps + diamond conflict detection
  lockfile.gleam          kir.lock read/write
  pipeline.gleam          Download → store → install orchestration
  security.gleam          SHA256, path validation, exclude-newer
  registry/hex.gleam      Hex.pm API client
  registry/npm.gleam      npm registry API client
  store.gleam             Content-addressable package store
  tarball.gleam           Hex double-tar + npm tgz extraction
  installer.gleam         Hardlink/copy installation
  platform.gleam          Erlang FFI wrappers
  tree.gleam              Dependency tree rendering
  export.gleam            manifest.toml + packages.toml + package.json export
  ffi.gleam               Bare import detection in .mjs files
src/kirari_ffi.erl        Erlang FFI (tar, hardlink, rename)
```

## Development

```sh
gleam build    # Build the project
gleam test     # Run the tests
gleam check    # Type check
gleam format   # Format source code
gleam run      # Run kirari
```

### Deployment

```sh
gleam export erlang-shipment
# Run with: build/erlang-shipment/entrypoint.sh
```

## License

This project is licensed under the [Mozilla Public License 2.0](LICENSE).
