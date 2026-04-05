# kirari

## DO NOT USE THIS

**This is an experimental project built purely for learning purposes. Do not use it.**

**Use the official Gleam tooling (`gleam add`, `gleam build`, etc.) for all your projects.**

This project exists solely to explore package manager internals (PubGrub resolution, content-addressable storage, supply chain security) by implementing them in Gleam. It is not intended to be used as a real tool, nor to replace or compete with Gleam's built-in package manager. It will not be maintained for practical use.

---

An experimental package manager for Gleam. Extends `gleam.toml` with `[npm-dependencies]`, `[overrides]`, and `[security]` sections to manage both Hex and npm dependencies in one workflow. Run it with the `kir` command.

Written in Gleam, targeting Erlang (BEAM).

## Features

- **Single config file** — `gleam.toml` is the only manifest, extended with kirari sections
- **Registry-specific store** — Hex, npm, Git, and URL packages stored separately under `~/.kir/store/{hex,npm,git,url}/` with optimized strategies per ecosystem
- **Content-addressable store** — SHA256-based with hardlink installs (copy fallback for npm packages with install scripts)
- **npm metadata sidecar** — `.meta` JSON files track scripts, bin entries, platform constraints, and provenance
- **Parallel downloads** — concurrent dependency fetching with configurable retry (`--max-retries`), timeout (`--timeout`), parallelism (`--parallel`), and backoff; settings in `[security]` section or CLI flags
- **Deterministic lockfile** — same input always produces the same `kir.lock`, with platform-aware fields
- **Supply chain security** — `--exclude-newer`, SHA256 hash verification, Hex tarball CHECKSUM verification, npm SRI integrity verification, npm Sigstore ECDSA signature verification with registry key caching
- **npm script policy** — configurable `npm-scripts` policy (deny/allow/allowlist) to block untrusted install scripts
- **Platform-aware resolution** — respects npm `os` and `cpu` fields, filters incompatible packages during resolution, warns on install-time platform mismatch
- **Bin executables** — auto-creates `node_modules/.bin/` symlinks (Unix) or `.cmd` wrappers (Windows)
- **Store GC** — `kir clean --store` with immutability-aware retention (Hex: never expires, npm: 90 days); selective cleanup with `--only=pkg`, `--keep=pkg`, `--max-age=N`, `--dry-run`; customizable store path via `KIR_STORE` env var
- **Package integrity manifests** — `.kir-manifest` file generated per package at store time, recording SHA256 of every file; `kir store verify` re-hashes all files to detect corruption, tampering, or missing files (Level 3 full / Level 2 `--quick`)
- **License compliance** — SPDX 2.3 expression parser, per-dependency license auditing with allow/deny policy, `kir license` command
- **Vulnerability audit** — `kir audit` checks installed packages against GitHub Advisory Database (Hex/Erlang) and npm bulk advisory API, with severity filtering, `--json` output for CI, and configurable ignore list
- **Deprecation warnings** — Hex retired and npm deprecated packages are flagged during install
- **Duplicate declaration warning** — detects packages declared in both `[dependencies]` and `[dev-dependencies]`
- **Dependency overrides** — `[overrides]` and `[npm-overrides]` sections force specific version constraints on any transitive dependency, resolving conflicts that would otherwise be unsolvable
- **PubGrub dependency resolution** — backtracking solver with learned clauses, human-readable conflict explanation ("Because X depends on Y..."), lock preference, exclude-newer filtering, graph-based conflict analysis with actionable suggestions (constraint relaxation, override, alternative version)
- **Incremental resolution** — config fingerprint (SHA256) stored in `kir.lock`; `kir build/run/test/check/dev` skip resolution entirely when nothing changed (3-tier: SkipAll / InstallOnly / FullResolve)
- **npm dist-tags** — `kir add express@latest`, `kir add pkg@next`: dist-tags resolved from npm registry to concrete `^version` constraints at add time; direct dependency dist-tags pre-resolved before PubGrub solver
- **SemVer 2.0.0 compliant** — pre-release identifier sorting, build metadata parsing (`+build` ignored in comparison), single-digit version padding (`"1"` → `1.0.0`), unified constraint parser accepting both Hex (`>= 1.0.0 and < 2.0.0`, `~> 1.2`) and npm (`^1.0.0`, `~1.0.0`, `1.0.0 - 2.0.0`) syntax in any dependency section
- **Deterministic lockfile metadata** — `kir.lock` includes generation timestamp and kirari version for auditability
- **JSON output mode** — `--json` flag on 8 query commands (`deps list`, `tree`, `outdated`, `why`, `diff`, `ls`, `license`, `store verify`) for CI/CD and tooling integration
- **Shell completion** — `kir completion bash|zsh|fish` generates shell-specific completion scripts with all commands and flags
- **Post-install integrity verification** — `kir install --verify` re-hashes installed packages against `.kir-manifest` after installation to detect corruption
- **HTTP 304 caching** — ETag/Last-Modified conditional requests for registry metadata, cached at `~/.kir/cache/registry/`; falls back to cache on network failure; `kir update` forces fresh requests; `kir clean` invalidates cache
- **Download progress** — real-time progress bar during parallel downloads showing package count, speed (`[========>   ] 5/12  1.2 MB/s`); supports NO_COLOR, non-TTY, and `--quiet` mode
- **Dev dependency isolation** — BFS reachability from production roots classifies transitive packages as dev-only; `kir.lock` and `kir tree` annotate dev packages; shared transitive dependencies correctly marked as production when reachable from both dev and prod
- **Offline mode** — `kir install --offline` resolves from registry cache and installs from store cache without any network access; fails fast with clear error listing missing packages
- **Parallel registry prefetch** — direct dependency versions fetched concurrently via Erlang processes before PubGrub solver starts, warming the version cache to minimize sequential registry lookups during resolution
- **Verbose/debug logging** — `--verbose` shows detailed progress (resolution decisions, fingerprint comparisons, lockfile writes); `--debug` adds internal traces; `KIR_LOG` env var as alternative; 4-level system (Silent/Normal/Verbose/Debug) backed by Erlang `persistent_term`
- **Lockfile version migration** — automatic schema migration on read (v1 → v2 → ...); rejects future versions with clear upgrade message; `--frozen` mode blocks migration to preserve CI reproducibility
- **Engine constraints** — `[engines]` section in `gleam.toml` declares required Gleam, Erlang/OTP, and Node.js versions; `kir install` validates before resolution and fails with clear mismatch messages; `kir doctor` shows constraint status
- **npm package aliases** — `my-react = "npm:react@^18.0.0"` installs a package under a different local name; supports scoped packages (`npm:@scope/pkg@^1.0`); alias-aware resolver, lockfile, and config round-trip
- **Init templates** — `kir init --template=advanced` applies predefined security settings (provenance=require, license allow-list) and engine constraints; `basic` template is the default
- **Hash pinning** — `.kir-hashes` independent TOML allowlist for per-package SHA256 verification; multiple known-good hashes per package for hash rotation; `kir hash pin <pkg>` and `kir hash verify` CLI commands; pipeline verifies pins before store
- **Git dependencies** — `[git-dependencies]` section with `{ git = "url", ref = "main" }` / `{ git = "url", tag = "v1.0.0" }` syntax; shallow clone, ref-to-commit-SHA resolution, transitive dependency extraction from `gleam.toml`; subdir support for monorepos; deterministic content-hash CAS storage
- **URL dependencies** — `[url-dependencies]` section with `{ url = "https://...", sha256 = "..." }` syntax; tarball download with SHA256 verification, transitive dependency extraction; CLI `kir add <name> --url=<url>`
- **Lock conflict resolution** — `kir lock resolve` automatically detects git merge conflict markers in `kir.lock`, re-resolves from `gleam.toml`, and writes a clean lockfile with diff preview; supports `--dry-run`
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
kir add express@latest --npm # Add npm package by dist-tag
kir add mylib --git=https://github.com/user/mylib.git --tag=v1.0.0  # Git dep
kir add legacy --url=https://example.com/pkg.tar.gz --sha256=abc123  # URL dep
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
| `kir init [--template=basic\|advanced]` | Add kirari sections to `gleam.toml`, merge `package.json` npm deps, apply template |
| `kir install [--frozen] [--exclude-newer=<TS>] [--offline] [--quiet] [--verify] [--verbose] [--debug] [--max-retries=<N>] [--timeout=<S>] [--parallel=<N>]` | Resolve and install dependencies, generate `kir.lock` |
| `kir update [pkg...]` | Update all or specific dependencies to latest compatible versions |
| `kir add <pkg[@version]> [--npm] [--dev]` | Add a dependency and install (`kir add gleam_json@3`, `kir add @types/node --npm`, `kir add express@latest --npm`) |
| `kir add <name> --git=<url> [--ref=<R>] [--tag=<T>] [--subdir=<P>] [--dev]` | Add a Git dependency |
| `kir add <name> --url=<url> [--sha256=<H>] [--dev]` | Add a URL tarball dependency |
| `kir remove <pkg> [--npm] [--git] [--url]` | Remove a dependency and reinstall |
| `kir deps list [--json]` | List all dependencies with versions and registries |
| `kir deps download` | Download dependencies without installing |
| `kir tree [--json]` | Print the full dependency tree with transitive dependencies |
| `kir clean [--store] [--keep-cache] [--dry-run] [--only=<pkgs>] [--keep=<pkgs>] [--max-age=<N>]` | Remove `build/` and `node_modules/`; `--store` runs store GC with optional selective filtering |

### Inspection

| Command | Description |
|---------|-------------|
| `kir outdated [--json]` | List outdated dependencies with latest available versions |
| `kir why <pkg> [--json]` | Explain why a package is installed (direct or transitive) |
| `kir diff [--json]` | Preview lock changes before running `kir update` |
| `kir ls [--json]` | List installed packages with paths and verification status |
| `kir doctor` | Diagnose environment (Erlang, Gleam, store, config, lock) |
| `kir store verify [--quick] [--json]` | Verify cached package integrity (full SHA256 re-hash or `--quick` file count check) |
| `kir license [--json]` | Audit dependency licenses against allow/deny policy |
| `kir audit [--json] [--severity=<LEVEL>]` | Audit dependencies for known vulnerabilities (GHSA + npm advisory) |
| `kir lock resolve [--dry-run]` | Re-resolve `kir.lock` from `gleam.toml` (fixes git merge conflicts) |
| `kir hash pin <pkg>` | Pin current SHA256 of a package to `.kir-hashes` allowlist |
| `kir hash verify` | Verify installed packages against `.kir-hashes` allowlist |

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

### Shell Completion

| Command | Description |
|---------|-------------|
| `kir completion bash` | Generate bash completion script |
| `kir completion zsh` | Generate zsh completion script |
| `kir completion fish` | Generate fish completion script |

**Setup:**

```sh
# bash — add to ~/.bashrc
eval "$(kir completion bash)"

# zsh — add to ~/.zshrc (or save to fpath)
kir completion zsh > ~/.zfunc/_kir

# fish
kir completion fish | source
```

### Flags

- `--frozen` — Verify lockfile matches resolution without downloading or installing. For CI.
- `--exclude-newer=<TIMESTAMP>` — Exclude versions published after the given RFC 3339 timestamp.
- `--offline` — Install from cached store only, skip registry (for `install`).
- `--quiet` — Suppress output for CI (for `install`).
- `--npm` — Force npm registry (for `add` and `remove`).
- `--git=<URL>` — Git repository URL (for `add`). Also `--git` boolean flag (for `remove`).
- `--url=<URL>` — Tarball download URL (for `add`). Also `--url` boolean flag (for `remove`).
- `--ref=<REF>` — Git ref: branch name or commit SHA (for `add --git`, default `main`).
- `--tag=<TAG>` — Git tag (for `add --git`, takes precedence over `--ref`).
- `--subdir=<PATH>` — Subdirectory in Git repo for monorepos (for `add --git`).
- `--sha256=<HASH>` — Expected SHA256 hash for URL tarball verification (for `add --url`).
- `--dev` — Add as dev dependency (for `add`).
- `--replace` — Replace existing version on Hex (for `publish`).
- `--yes` — Skip confirmation prompt (for `publish`).
- `--dry-run` — Simulate publish without uploading (for `publish`).
- `--store` — Also garbage-collect `~/.kir/store/` when cleaning (for `clean`).
- `--keep-cache` — Preserve Gleam compilation cache when cleaning (for `clean`).
- `--verify` — Verify installed package integrity after install (for `install`).
- `--json` — Machine-readable JSON output (for `deps list`, `tree`, `outdated`, `why`, `diff`, `ls`, `license`, `store verify`, `audit`).
- `--severity=<LEVEL>` — Minimum severity to report: `low`, `moderate`, `high`, `critical` (for `audit`).
- `--quick` — Fast integrity check: manifest exists + file count only, skip SHA256 re-hash (for `store verify`).
- `--verbose` — Show detailed progress: resolution decisions, fingerprint comparisons, pipeline stats (for `install`). Also via `KIR_LOG=verbose` env var.
- `--debug` — Show internal debug traces in addition to verbose output (for `install`). Also via `KIR_LOG=debug` env var.
- `--max-retries=<N>` — Maximum download retry attempts, overrides `[security] max-retries` (for `install`).
- `--timeout=<SECONDS>` — Per-package download timeout in seconds, overrides `[security] timeout` (for `install`).
- `--parallel=<N>` — Maximum concurrent downloads (0 = unbounded), overrides `[security] parallel` (for `install`).
- `--only=<PACKAGES>` — Comma-separated package names to target for store GC (for `clean --store`).
- `--keep=<PACKAGES>` — Comma-separated package names to preserve during store GC (for `clean --store`).
- `--max-age=<DAYS>` — Override retention days for store GC (for `clean --store`).

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
highlight.js = "^11.0.0"           # npm caret syntax
lodash = ">= 4.17.0 and < 5.0.0"  # Hex-style syntax also works
my-react = "npm:react@^18.0.0"     # npm package alias

[dev-npm-dependencies]
@types/node = "^18.0.0"
vitest = "~> 3.1"                  # Hex-style works here too

[git-dependencies]
my_lib = { git = "https://github.com/user/my_lib.git", ref = "main" }
pinned = { git = "https://github.com/user/pinned.git", tag = "v1.0.0" }
mono_pkg = { git = "https://github.com/user/mono.git", ref = "main", subdir = "packages/lib" }

[url-dependencies]
legacy = { url = "https://example.com/pkg-1.0.0.tar.gz", sha256 = "a1b2c3..." }

[overrides]
gleam_json = ">= 3.0.0 and < 4.0.0"   # Force version for all dependents

[npm-overrides]
semver = "^7.6.0"                       # Override transitive npm constraint
postcss = ">= 8.4.0 and < 9.0.0"       # Hex-style works here too

[security]
exclude-newer = "2026-04-01T00:00:00Z"
npm-scripts = "deny"
npm-scripts-allow = ["esbuild", "sharp"]
provenance = "warn"
license-allow = ["MIT", "Apache-2.0", "BSD-3-Clause", "ISC"]
audit-ignore = ["GHSA-xxxx-xxxx-xxxx"]
max-retries = 5
timeout = 300
parallel = 4

[engines]
gleam = ">= 1.0.0"
erlang = ">= 26"
node = ">= 18.0.0"
```

`[dependencies]` and `[dev-dependencies]` are native Gleam sections. `[npm-dependencies]`, `[dev-npm-dependencies]`, `[git-dependencies]`, `[dev-git-dependencies]`, `[url-dependencies]`, `[dev-url-dependencies]`, `[overrides]`, `[npm-overrides]`, `[security]`, and `[engines]` are kirari extensions that Gleam silently ignores.

### Version constraint syntax

kirari accepts both Hex and npm version constraint formats in any dependency section. You can use whichever style you prefer, regardless of registry.

| Syntax | Example | Meaning |
|--------|---------|---------|
| Hex range | `">= 1.0.0 and < 2.0.0"` | `>= 1.0.0` AND `< 2.0.0` |
| Hex pessimistic | `"~> 1.2"` | `>= 1.2.0` and `< 2.0.0` |
| Hex pessimistic (3-part) | `"~> 1.2.3"` | `>= 1.2.3` and `< 1.3.0` |
| Hex OR | `">= 1.0.0 or >= 3.0.0"` | Either range matches |
| npm caret | `"^1.2.3"` | `>= 1.2.3` and `< 2.0.0` |
| npm tilde | `"~1.2.3"` | `>= 1.2.3` and `< 1.3.0` |
| npm range | `">=1.0.0 <2.0.0"` | Space-separated AND |
| npm hyphen | `"1.2.3 - 2.3.4"` | `>= 1.2.3` and `<= 2.3.4` |
| npm OR | `"^1.0.0 \|\| ^2.0.0"` | Either range matches |
| Exact | `"== 1.0.0"` or `"1.0.0"` | Exactly `1.0.0` |
| Any | `"*"` or `""` | Any version |
| npm dist-tag | `"latest"`, `"next"`, `"canary"` | Resolved to concrete version at `kir add` time |
| npm alias | `"npm:react@^18.0.0"` | Install `react` under a different local name |

### Dependency overrides

Override transitive dependency constraints when packages require incompatible versions of a shared dependency. Overrides replace all constraints (direct and transitive) for the named package.

```toml
[overrides]
gleam_json = ">= 3.0.0 and < 4.0.0"

[npm-overrides]
semver = "^7.6.0"
```

When overrides are active, `kir install` prints them before resolving:

```
Overrides:
  gleam_json → ">= 3.0.0 and < 4.0.0" (hex)
  semver → "^7.6.0" (npm)
Resolving dependencies...
```

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
| `max-retries` | integer | `3` | Maximum download retry attempts per package |
| `timeout` | integer (seconds) | `120` | Per-package download timeout |
| `parallel` | integer | `0` (unbounded) | Maximum concurrent downloads (0 = no limit) |
| `backoff` | integer (ms) | `2000` | Delay between retry attempts |

### Engine constraints

Declare required runtime versions. `kir install` validates these before resolution and fails with a clear message if any constraint is not satisfied. All fields are optional.

| Key | Example | Description |
|-----|---------|-------------|
| `gleam` | `">= 1.0.0"` | Gleam compiler version (detected via `gleam --version`) |
| `erlang` | `">= 26"` | Erlang/OTP version (detected via `erl`) |
| `node` | `">= 18.0.0"` | Node.js version (detected via `node --version`) |

Constraints use the same syntax as dependency version constraints (Hex-style recommended). If a runtime is not installed and no constraint is declared, it is silently skipped.

## kir.lock

Deterministic TOML lockfile with SHA256 hashes, sorted alphabetically by package name.

```toml
version = 3
config-fingerprint = "a1b2c3d4..."

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

[[package]]
git_ref = "abc1234def567890abc1234def567890abc12345"
git_url = "https://github.com/user/my_lib.git"
license = "MIT"
name = "my_lib"
registry = "git"
sha256 = "e5f6a7b8..."
version = "0.5.0"

[[package]]
name = "legacy"
registry = "url"
sha256 = "d4e5f6a7..."
source_url = "https://example.com/pkg-1.0.0.tar.gz"
version = "1.0.0"
```

Fields `dev`, `has_scripts`, `license`, `os`, `cpu`, and `package_name` are only emitted when non-empty/applicable. `package_name` stores the real npm registry name for aliased packages (e.g., `package_name = "react"` when the local name is `my-react`). `dev = true` marks packages only reachable from dev dependencies (not in production dependency graph). `config-fingerprint` is the SHA256 of all resolution-affecting config inputs (deps, overrides, exclude-newer, git/url deps) — used for incremental resolution to skip re-solving when nothing changed. Git packages include `git_url`, `git_ref` (resolved commit SHA), and optional `git_subdir`. URL packages include `source_url`.

The lockfile `version` field tracks the schema version (currently 3). Older lockfiles are automatically migrated on read. Lockfiles from newer versions of kirari are rejected with a clear upgrade message. `kir install --frozen` rejects lockfiles that need migration.

CI usage: `kir install --frozen` fails if the lock doesn't match resolved dependencies.

## How kirari works with Gleam

kirari is a package manager, not a compiler. It extends `gleam.toml` with extra sections and manages the full dependency lifecycle. The Gleam compiler reads the same `gleam.toml` but ignores kirari's sections.

```
gleam.toml (single source of truth)
    │
    ├── [dependencies], [dev-dependencies]     ← Gleam reads these
    ├── [npm-dependencies], [dev-npm-dependencies]  ← kirari reads, Gleam ignores
    ├── [git-dependencies], [dev-git-dependencies] ← kirari reads, Gleam ignores
    ├── [url-dependencies], [dev-url-dependencies] ← kirari reads, Gleam ignores
    ├── [overrides], [npm-overrides]           ← kirari reads, Gleam ignores
    ├── [security]                             ← kirari reads, Gleam ignores
    └── [engines]                              ← kirari reads, Gleam ignores
    │
    ▼
kir install
    │
    ├── Resolve (platform-aware os/cpu filtering)
    ├── Download → Verify (SHA256 + SRI integrity + Sigstore ECDSA)
    ├── Store (Hex → ~/.kir/store/hex/, npm → ~/.kir/store/npm/, Git → git/, URL → url/)
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
| **Dependency resolution** | PubGrub (backtracking) | PubGrub (backtracking, learned clauses, conflict explanation + suggestion engine, incremental fingerprint-based skip) |
| **Local package store** | Global tarball cache + extracts to `build/packages/` per project | Content-addressable `~/.kir/store/` shared across projects, registry-separated (`hex/`, `npm/`) |
| **Installation method** | Extract from tarball | Hardlink (immutable packages) or copy (npm with scripts) |
| **npm bin executables** | Not managed | Auto-creates `node_modules/.bin/` symlinks (Unix) or `.cmd` wrappers (Windows) |
| **Platform-aware resolution** | Not available | Respects npm `os`/`cpu` fields |
| **`exclude-newer`** | Not available | `[security] exclude-newer` or `--exclude-newer` flag |
| **npm script policy** | Not available | `[security] npm-scripts` with deny/allow/allowlist |
| **Provenance verification** | Not available | npm Sigstore ECDSA signature verification with registry key caching (warn/require/ignore) |
| **SRI integrity** | Not available | Verifies npm `dist.integrity` field (sha256/sha512) |
| **Hex tarball verification** | `outer_checksum` (SHA256 of entire tarball) | `outer_checksum` + inner `CHECKSUM` file (SHA256 of VERSION+metadata+contents) |
| **Store GC** | Not available | `kir clean --store` — selective by package name, `--dry-run` preview, `--max-age` override |
| **Dependency tree** | `gleam deps tree` | `kir tree` (full transitive tree with cycle detection) |
| **License compliance** | Not available | SPDX 2.3 expression parsing, allow/deny policy, `kir license` audit |
| **Deprecation warnings** | Not available | Hex retirement and npm deprecation warnings during install |
| **Outdated check** | Not available | `kir outdated` lists packages with newer versions available |
| **Why installed** | Not available | `kir why <pkg>` shows dependency chain (direct or transitive) |
| **Lock diff** | Not available | `kir diff` previews changes before `kir update` |
| **Installed list** | Not available | `kir ls` shows installed packages with paths and status |
| **Environment diagnosis** | Not available | `kir doctor` checks Erlang, Gleam, store, config, lock |
| **Store verification** | Not available | `kir store verify` — file-level SHA256 re-hash with `.kir-manifest`, detects corruption/tampering/missing files |
| **Vulnerability audit** | Not available | `kir audit` checks against GitHub Advisory Database + npm advisory API, with severity filtering and JSON output |
| **FFI import detection** | Not available | Warns about undeclared npm bare imports after install |
| **Dependency overrides** | Not available | `[overrides]` and `[npm-overrides]` force version constraints on transitive dependencies |
| **Selective update** | Not available | `kir update <pkg>` updates specific packages only |
| **Offline install** | Not available | `kir install --offline` resolves from registry cache and installs from store cache without network |
| **Dev dependency isolation** | Not available | BFS reachability classifies transitive deps as dev-only; `kir.lock` and `kir tree` annotate |
| **Parallel registry prefetch** | Not available | Direct dependencies fetched concurrently before PubGrub solver starts |
| **Export** | `gleam export erlang-shipment`, `hex-tarball` | `kir export` + all gleam export subcommands via passthrough |
| **Publishing** | `gleam publish`, `gleam hex retire/unretire` | `kir publish --dry-run`, `kir hex retire/unretire/revert/owner` |
| **JSON output** | Not available | `--json` on 8 query commands for CI/CD pipelines |
| **Shell completion** | Not available | `kir completion bash\|zsh\|fish` with all commands and flags |
| **Post-install verification** | Not available | `kir install --verify` re-hashes installed files against `.kir-manifest` |
| **Registry metadata caching** | Not available | HTTP 304 (ETag/Last-Modified) caching with network failure fallback |
| **Download progress** | Not available | Real-time progress bar with speed display, NO_COLOR/quiet support |
| **Verbose/debug output** | Not available | `--verbose`/`--debug` flags + `KIR_LOG` env var, 4-level structured logging |
| **Lockfile migration** | Not available | Automatic schema migration (v1 → v2 → ...), future version rejection |
| **Engine constraints** | Not available | `[engines]` section: Gleam/Erlang/Node.js version validation before install |
| **Download configuration** | Not available | `[security] max-retries`/`timeout`/`parallel`/`backoff` + CLI flag overrides |
| **Lock conflict resolution** | Not available | `kir lock resolve` detects merge markers, re-resolves from gleam.toml, writes clean lockfile |
| **Selective store cleanup** | Not available | `kir clean --store --only=pkg --keep=pkg --dry-run --max-age=N` |
| **npm package aliases** | Not available | `"npm:react@^18"` syntax, alias-aware resolver/lockfile/installer |
| **Init templates** | Not available | `kir init --template=advanced` applies security + engine presets |
| **Hash pinning** | Not available | `.kir-hashes` independent allowlist, `kir hash pin/verify`, pipeline integration |
| **Git dependencies** | Not available | `[git-dependencies]` with ref/tag/subdir, shallow clone, commit SHA lockfile pinning |
| **URL dependencies** | Not available | `[url-dependencies]` with SHA256 verification, tarball download and extraction |
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
    progress.gleam        Download progress actor (Erlang process, package-level bar + speed)
    log.gleam             Structured logging (4-level, persistent_term, KIR_LOG env, lazy eval)
    engines.gleam         Engine constraint validation (Gleam/Erlang/Node.js version checks)
    lock_resolve.gleam    Git merge conflict resolution for kir.lock (re-resolve + diff)
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
    fingerprint.gleam     Config fingerprint for incremental resolution (SHA256 of deps+overrides)
    conflict.gleam        Conflict analysis — structured causes, alternative suggestions, rich formatting
  git.gleam               Git client — URL validation, ref resolution, shallow clone, content hash
  hashpin.gleam           Hash pinning — .kir-hashes independent allowlist, pipeline verification
  lockfile.gleam          kir.lock read/write + structured diff + merge conflict detection
  pipeline.gleam          Download → verify → store → install orchestration
  security.gleam          SHA256, path validation, exclude-newer, SRI integrity, Sigstore ECDSA
  registry/hex.gleam      Hex.pm API client (versions, deps, license)
  registry/npm.gleam      npm registry API client + signing key cache
  registry/cache.gleam    HTTP 304 caching (ETag/Last-Modified, conditional requests, offline fallback)
  store.gleam             Store router — delegates to registry-specific modules
  store/
    types.gleam           StoreError, StoreResult shared types
    cas.gleam             Content-addressable storage shared helpers
    hex.gleam             Hex-specific CAS store (~/.kir/store/hex/)
    npm.gleam             npm-specific CAS store (~/.kir/store/npm/) + metadata sidecar
    metadata.gleam        npm .meta JSON sidecar read/write
    git.gleam             Git-specific CAS store (~/.kir/store/git/) — directory copy, .git excluded
    url.gleam             URL-specific CAS store (~/.kir/store/url/) — tarball extraction
    gc.gleam              Store GC (Hex: immutable/never expires, npm: 90-day retention, selective by name)
    manifest.gleam        Package integrity manifest — per-file SHA256 generation and verification
  tarball.gleam           Hex double-tar + CHECKSUM verification, npm tgz extraction
  installer.gleam         Registry-aware installation (hardlink/copy) + bin symlinks/cmd wrappers
  platform.gleam          Erlang FFI wrappers + OS/time utilities
  tree.gleam              Recursive dependency tree with transitive deps + cycle detection
  export.gleam            manifest.toml + packages.toml + package.json export
  completion.gleam        Shell completion generators (bash, zsh, fish)
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
