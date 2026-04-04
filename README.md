# kirari

A unified package manager for Gleam. Extends `gleam.toml` with `[npm-dependencies]` and `[security]` sections to manage both Hex and npm dependencies in one workflow. Run it with the `kir` command.

Written in Gleam, targeting Erlang (BEAM).

## Features

- **Single config file** — `gleam.toml` is the only manifest, extended with kirari sections
- **Registry-specific store** — Hex and npm packages stored separately under `~/.kir/store/hex/` and `~/.kir/store/npm/` with optimized strategies per ecosystem
- **Content-addressable store** — SHA256-based with hardlink installs (copy fallback for npm packages with install scripts)
- **npm metadata sidecar** — `.meta` JSON files track scripts, bin entries, platform constraints, and provenance
- **Parallel downloads** — concurrent dependency fetching with automatic retry
- **Deterministic lockfile** — same input always produces the same `kir.lock`, with platform-aware fields
- **Supply chain security** — `--exclude-newer`, SHA256 hash verification, Hex tarball CHECKSUM verification, npm SRI integrity verification, npm Sigstore ECDSA signature verification with registry key caching
- **npm script policy** — configurable `npm-scripts` policy (deny/allow/allowlist) to block untrusted install scripts
- **Platform-aware resolution** — respects npm `os` and `cpu` fields, filters incompatible packages during resolution, warns on install-time platform mismatch
- **Bin executables** — auto-creates `node_modules/.bin/` symlinks (Unix) or `.cmd` wrappers (Windows)
- **Store GC** — `kir clean --store` with immutability-aware retention (Hex: never expires, npm: 90 days); customizable store path via `KIR_STORE` env var
- **License compliance** — SPDX 2.3 expression parser, per-dependency license auditing with allow/deny policy, `kir license` command
- **Vulnerability audit** — `kir audit` checks installed packages against GitHub Advisory Database (Hex/Erlang) and npm bulk advisory API, with severity filtering, `--json` output for CI, and configurable ignore list
- **Deprecation warnings** — Hex retired and npm deprecated packages are flagged during install
- **Duplicate declaration warning** — detects packages declared in both `[dependencies]` and `[dev-dependencies]`
- **PubGrub dependency resolution** — backtracking solver with learned clauses, human-readable conflict explanation ("Because X depends on Y..."), lock preference, exclude-newer filtering
- **SemVer 2.0.0 compliant** — pre-release identifier sorting, build metadata parsing (`+build` ignored in comparison), single-digit version padding (`"1"` → `1.0.0`)
- **Deterministic lockfile metadata** — `kir.lock` includes generation timestamp and kirari version for auditability
- **FFI detection** — warns about undeclared npm imports in `.mjs` files after install
- **`gleam build` compatible** — gleam ignores kirari sections; auto-generates `manifest.toml` + `packages.toml`

## Installation

Requires [Erlang/OTP](https://www.erlang.org/) 28 or later.

### Linux/macOS

```sh
curl -fsSL https://github.com/GG-O-BP/kirari/releases/latest/download/kirari-linux-x86_64.tar.gz | sudo tar -xz -C /usr/local/lib
sudo ln -sf /usr/local/lib/erlang-shipment/kir /usr/local/bin/kir
kir --version
```

### Windows

```powershell
Invoke-WebRequest -Uri "https://github.com/GG-O-BP/kirari/releases/latest/download/kirari-windows-x86_64.zip" -OutFile "$env:TEMP\kirari.zip"
Expand-Archive -Path "$env:TEMP\kirari.zip" -DestinationPath C:\kirari -Force
[Environment]::SetEnvironmentVariable("Path", $env:Path + ";C:\kirari\erlang-shipment", "User")
# Restart terminal, then:
kir --version
```

### Update

To update kirari to the latest version, re-run the installation commands above. Existing files will be overwritten.

**Linux/macOS:**

```sh
curl -fsSL https://github.com/GG-O-BP/kirari/releases/latest/download/kirari-linux-x86_64.tar.gz | sudo tar -xz -C /usr/local/lib
kir --version
```

**Windows:**

```powershell
Invoke-WebRequest -Uri "https://github.com/GG-O-BP/kirari/releases/latest/download/kirari-windows-x86_64.zip" -OutFile "$env:TEMP\kirari.zip"
Expand-Archive -Path "$env:TEMP\kirari.zip" -DestinationPath C:\kirari -Force
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
| `kir install [--frozen] [--exclude-newer=<TS>] [--offline] [--quiet]` | Resolve and install dependencies, generate `kir.lock` |
| `kir update [pkg...]` | Update all or specific dependencies to latest compatible versions |
| `kir add <pkg[@version]> [--npm] [--dev]` | Add a dependency and install (`kir add gleam_json@3`, `kir add @types/node --npm`) |
| `kir remove <pkg> [--npm]` | Remove a dependency and reinstall |
| `kir deps list` | List all dependencies with versions and registries |
| `kir deps download` | Download dependencies without installing |
| `kir tree` | Print the full dependency tree with transitive dependencies |
| `kir clean [--store] [--keep-cache]` | Remove `build/` and `node_modules/`; `--store` runs store GC; `--keep-cache` preserves Gleam compilation cache |

### Inspection

| Command | Description |
|---------|-------------|
| `kir outdated` | List outdated dependencies with latest available versions |
| `kir why <pkg>` | Explain why a package is installed (direct or transitive) |
| `kir diff` | Preview lock changes before running `kir update` |
| `kir ls` | List installed packages with paths and verification status |
| `kir doctor` | Diagnose environment (Erlang, Gleam, store, config, lock) |
| `kir store verify` | Verify cached package integrity in the global store |
| `kir license` | Audit dependency licenses against allow/deny policy |
| `kir audit [--json] [--severity=<LEVEL>]` | Audit dependencies for known vulnerabilities (GHSA + npm advisory) |

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
| `kir publish [--replace] [--yes] [--dry-run]` | Publish package to Hex (`--dry-run` simulates without uploading) |
| `kir hex retire <pkg> <ver> <reason> [msg]` | Retire a release from Hex |
| `kir hex unretire <pkg> <ver>` | Un-retire a release from Hex |
| `kir hex revert` | Revert a published release |
| `kir hex owner` | Manage package ownership |

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
- `--offline` — Install from cached store only, skip registry (for `install`).
- `--quiet` — Suppress output for CI (for `install`).
- `--npm` — Force npm registry (for `add` and `remove`).
- `--dev` — Add as dev dependency (for `add`).
- `--replace` — Replace existing version on Hex (for `publish`).
- `--yes` — Skip confirmation prompt (for `publish`).
- `--dry-run` — Simulate publish without uploading (for `publish`).
- `--store` — Also garbage-collect `~/.kir/store/` when cleaning (for `clean`).
- `--keep-cache` — Preserve Gleam compilation cache when cleaning (for `clean`).
- `--json` — Machine-readable JSON output (for `audit`).
- `--severity=<LEVEL>` — Minimum severity to report: `low`, `moderate`, `high`, `critical` (for `audit`).

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
npm-scripts = "deny"
npm-scripts-allow = ["esbuild", "sharp"]
provenance = "warn"
license-allow = ["MIT", "Apache-2.0", "BSD-3-Clause", "ISC"]
audit-ignore = ["GHSA-xxxx-xxxx-xxxx"]
```

`[dependencies]` and `[dev-dependencies]` are native Gleam sections. `[npm-dependencies]`, `[dev-npm-dependencies]`, and `[security]` are kirari extensions that Gleam silently ignores.

### Security options

| Key | Values | Default | Description |
|-----|--------|---------|-------------|
| `exclude-newer` | RFC 3339 timestamp | _(none)_ | Exclude versions published after this time |
| `npm-scripts` | `"deny"`, `"allow"` | `"deny"` | Whether to allow npm install scripts |
| `npm-scripts-allow` | string array | `[]` | Allowlist of packages whose scripts are permitted (overrides `npm-scripts = "deny"`) |
| `provenance` | `"ignore"`, `"warn"`, `"require"` | `"warn"` | npm Sigstore provenance verification policy — `warn` logs failures, `require` blocks install |
| `license-allow` | string array | `[]` | Allowlist of SPDX license IDs — `kir license` reports violations for packages not matching |
| `license-deny` | string array | `[]` | Denylist of SPDX license IDs — `kir license` reports violations for packages matching |
| `audit-ignore` | string array | `[]` | Advisory IDs (GHSA/CVE) to suppress in `kir audit` results |

## kir.lock

Deterministic TOML lockfile with SHA256 hashes, sorted alphabetically by package name.

```toml
version = 1

[[package]]
license = "Apache-2.0 OR MIT"
name = "gleam_stdlib"
registry = "hex"
sha256 = "702f3bc2..."
version = "0.71.0"

[[package]]
has_scripts = true
license = "MIT"
name = "esbuild"
os = ["linux", "darwin", "win32"]
cpu = ["x64", "arm64"]
registry = "npm"
sha256 = "a1b2c3d4..."
version = "0.21.5"
```

Fields `has_scripts`, `license`, `os`, and `cpu` are only emitted when non-empty/applicable.

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
    ├── Resolve (platform-aware os/cpu filtering)
    ├── Download → Verify (SHA256 + SRI integrity + Sigstore ECDSA)
    ├── Store (Hex → ~/.kir/store/hex/, npm → ~/.kir/store/npm/ + .meta)
    ├── Install (Hex: hardlink, npm: hardlink or copy based on scripts)
    ├── Bin link (Unix: symlink, Windows: .cmd wrapper)
    ├── kir.lock                    ← deterministic lockfile
    ├── manifest.toml               ← auto-generated for gleam build
    └── build/packages/packages.toml ← auto-generated for gleam build

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
| **Dependency resolution** | PubGrub (backtracking) | PubGrub (backtracking, learned clauses, human-readable conflict explanation) |
| **Local package store** | Global tarball cache + extracts to `build/packages/` per project | Content-addressable `~/.kir/store/` shared across projects, registry-separated (`hex/`, `npm/`) |
| **Installation method** | Extract from tarball | Hardlink (immutable packages) or copy (npm with scripts) |
| **npm bin executables** | Not managed | Auto-creates `node_modules/.bin/` symlinks (Unix) or `.cmd` wrappers (Windows) |
| **Platform-aware resolution** | Not available | Respects npm `os`/`cpu` fields |
| **`exclude-newer`** | Not available | `[security] exclude-newer` or `--exclude-newer` flag |
| **npm script policy** | Not available | `[security] npm-scripts` with deny/allow/allowlist |
| **Provenance verification** | Not available | npm Sigstore ECDSA signature verification with registry key caching (warn/require/ignore) |
| **SRI integrity** | Not available | Verifies npm `dist.integrity` field (sha256/sha512) |
| **Hex tarball verification** | `outer_checksum` (SHA256 of entire tarball) | `outer_checksum` + inner `CHECKSUM` file (SHA256 of VERSION+metadata+contents) |
| **Store GC** | Not available | `kir clean --store` — Hex immutable (never expires), npm 90-day retention |
| **Dependency tree** | `gleam deps tree` | `kir tree` (full transitive tree with cycle detection) |
| **License compliance** | Not available | SPDX 2.3 expression parsing, allow/deny policy, `kir license` audit |
| **Deprecation warnings** | Not available | Hex retirement and npm deprecation warnings during install |
| **Outdated check** | Not available | `kir outdated` lists packages with newer versions available |
| **Why installed** | Not available | `kir why <pkg>` shows dependency chain (direct or transitive) |
| **Lock diff** | Not available | `kir diff` previews changes before `kir update` |
| **Installed list** | Not available | `kir ls` shows installed packages with paths and status |
| **Environment diagnosis** | Not available | `kir doctor` checks Erlang, Gleam, store, config, lock |
| **Store verification** | Not available | `kir store verify` checks cached package integrity |
| **Vulnerability audit** | Not available | `kir audit` checks against GitHub Advisory Database + npm advisory API, with severity filtering and JSON output |
| **FFI import detection** | Not available | Warns about undeclared npm bare imports after install |
| **Selective update** | Not available | `kir update <pkg>` updates specific packages only |
| **Offline install** | Not available | `kir install --offline` installs from cache without registry |
| **Export** | `gleam export erlang-shipment`, `hex-tarball` | `kir export` + all gleam export subcommands via passthrough |
| **Publishing** | `gleam publish`, `gleam hex retire/unretire` | `kir publish --dry-run`, `kir hex retire/unretire/revert/owner` |
| **Written in** | Rust | Gleam |

## Architecture

```
src/kirari.gleam          Entry point
src/kirari/
  cli.gleam               CLI router — command registration and dispatch
  cli/
    error.gleam           KirError type + error formatting
    output.gleam          Color helpers, warning printers, gleam command runner
    install.gleam         Workflow commands (init, install, update, add, remove, clean, publish)
    query.gleam           Read-only commands (outdated, why, diff, ls, doctor, license, audit)
  types.gleam             Shared domain types
  config.gleam            gleam.toml parsing/serialization (native + kirari sections)
  migrate.gleam           package.json migration for kir init
  semver.gleam            SemVer parsing, Hex + npm constraint matching
  spdx.gleam              SPDX 2.3 license expression parser (recursive descent)
  license.gleam           License compliance engine (allow/deny policy, violation detection)
  audit.gleam             Vulnerability audit engine (advisory matching, severity filtering, JSON output)
  audit/
    ghsa.gleam            GitHub Advisory Database REST API client (Erlang ecosystem, cached)
    npm_audit.gleam       npm bulk advisory POST API client
  resolver.gleam          Dependency resolution facade (public API, registry fetch, peer validation)
  resolver/
    pubgrub.gleam         PubGrub solver (unit propagation, decision making, conflict resolution)
    term.gleam            Term type (positive/negative version range assertions)
    incompatibility.gleam Incompatibility type, cause tracking, human-readable explanation
    partial_solution.gleam Assignment tracking, decision levels, backtracking
  lockfile.gleam          kir.lock read/write + structured diff
  pipeline.gleam          Download → verify → store → install orchestration
  security.gleam          SHA256, path validation, exclude-newer, SRI integrity, Sigstore ECDSA
  registry/hex.gleam      Hex.pm API client (versions, deps, license)
  registry/npm.gleam      npm registry API client + signing key cache
  store.gleam             Store router — delegates to registry-specific modules
  store/
    types.gleam           StoreError, StoreResult shared types
    cas.gleam             Content-addressable storage shared helpers
    hex.gleam             Hex-specific CAS store (~/.kir/store/hex/)
    npm.gleam             npm-specific CAS store (~/.kir/store/npm/) + metadata sidecar
    metadata.gleam        npm .meta JSON sidecar read/write
    gc.gleam              Store GC (Hex: immutable/never expires, npm: 90-day retention)
  tarball.gleam           Hex double-tar + CHECKSUM verification, npm tgz extraction
  installer.gleam         Registry-aware installation (hardlink/copy) + bin symlinks/cmd wrappers
  platform.gleam          Erlang FFI wrappers + OS/time utilities
  tree.gleam              Recursive dependency tree with transitive deps + cycle detection
  export.gleam            manifest.toml + packages.toml + package.json export
  ffi.gleam               Bare import detection in .mjs files
src/kirari_ffi.erl        Erlang FFI (tar, hardlink, rename, symlink, ECDSA, platform)
```

## Development

```sh
kir build      # Build the project
kir test       # Run the tests
kir check      # Type check
kir format     # Format source code
kir install    # Install dependencies
```

### Deployment

```sh
kir export erlang-shipment
# Run with: build/erlang-shipment/kir --version
```

## License

This project is licensed under the [Mozilla Public License 2.0](LICENSE).
