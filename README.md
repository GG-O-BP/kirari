# kirari

> **This is not a real tool. Do not use it.**
> An experimental project built purely to learn package manager internals.
> Use the official Gleam tooling (`gleam add`, `gleam build`, etc.) for all real projects.

---

## Claude Code Harness Engineering

This project is also an experiment in building a large Gleam codebase with Claude Code.

A `CLAUDE.md` file defines design principles, module layout rules, Gleam coding conventions, and the CLI command spec. The harness was designed so that Claude Code consistently follows these conventions. Key elements:

- **Project convention document (`CLAUDE.md`)**: 30 design principles, per-module responsibility boundaries, and CLI command specs in a single document. Claude Code references this as context when generating code, maintaining a consistent architecture throughout
- **Auto-memory system**: File-based memory (project, feedback, user profile) persists across conversations to prevent context loss. Details like naming conventions (program name = kirari, CLI command = kir) are stored in memory so they're followed without repeated correction
- **kir-reviewer subagent**: A dedicated agent configured to review code against Gleam idioms and kirari conventions, serving as a quality gate
- **kir-test skill**: A dedicated skill that automates test execution and failure analysis, streamlining the verification loop after code changes
- **Build-test loop**: The convention mandates `kir check && kir test` after every code change. Claude Code automatically runs the verification step after writing code

This harness structure enabled building 60+ modules and ~20,000 lines of Gleam code with a consistent architecture.

## What Was Built

A package manager written in Gleam (targeting Erlang/BEAM). Extends `gleam.toml` to manage both Hex and npm dependencies in a single workflow.

### Dependency Resolution: PubGrub Algorithm

A PubGrub backtracking solver implemented from scratch in Gleam.

- Unit propagation, decision-level backtracking, learned clauses
- Human-readable conflict explanation on failure ("Because X depends on Y...")
- Conflict analysis engine: DFS over incompatibility tree to produce structured causes and actionable suggestions (relax constraints, add overrides, try alternative versions)
- Config fingerprint (SHA256) based incremental resolution: skips re-solving when nothing changed

### Content-Addressable Store

Registry-separated CAS under `~/.kir/store/`.

- **Hex**: Immutable package assumption, SHA256-based storage, hardlink installs, permanent cache
- **npm**: `.meta` sidecar for scripts/bin/platform info, copy install for packages with scripts
- **Git**: Shallow clone, ref-to-commit-SHA resolution, directory-copy CAS
- **URL**: Tarball download + SHA256 verification, extraction-based CAS

### Supply Chain Security

Security verification built into the install pipeline.

- Hex tarball dual verification: outer SHA256 + inner CHECKSUM
- npm SRI integrity verification (sha256/sha512)
- npm Sigstore ECDSA signature verification + registry key caching
- `--exclude-newer` timestamp-based version filtering
- `.kir-hashes` independent hash pinning allowlist
- npm script policy (deny/allow/allowlist)
- Package integrity manifest (`.kir-manifest`): per-file SHA256 recording and re-verification

### SemVer Parser

A SemVer 2.0.0 compliant parser that handles both Hex syntax (`~> 1.2`, `>= 1.0.0 and < 2.0.0`) and npm syntax (`^1.0.0`, `~1.0.0`, `1.0.0 - 2.0.0`) in a single parser. Supports pre-release identifier sorting, build metadata parsing, and single-digit padding (`"1"` -> `1.0.0`).

### SPDX License Parser

Parses SPDX 2.3 expressions with a recursive descent parser. Performs license auditing based on allow/deny policies.

### Concurrency

Parallel downloads and registry prefetch using Erlang processes. Direct dependencies are fetched concurrently to warm the PubGrub solver's version cache. Download progress is displayed in real time via an Erlang process-based actor.

### Other Implementations

- Deterministic lockfile (`kir.lock`): same input produces same output, schema version migration chain
- HTTP 304 caching: ETag/Last-Modified conditional requests
- Dev transitive dependency isolation: BFS reachability classification
- npm dist-tag resolution: `@latest`, `@next`, etc. resolved to concrete versions
- npm package aliases: `"npm:react@^18.0.0"` syntax
- Git merge conflict auto-resolution for lockfiles
- Vulnerability audit: GHSA + npm advisory API
- Shell completion generation (bash/zsh/fish)
- Offline mode
- SBOM export (SPDX/CycloneDX)
- Engine constraints: Gleam/Erlang/Node.js runtime version validation

## Module Structure

```
src/kirari.gleam              Entry point
src/kirari/
  cli.gleam                   CLI router
  cli/{install,query,error,output,progress,log,engines,lock_resolve}.gleam
  resolver.gleam              PubGrub facade
  resolver/{pubgrub,term,incompatibility,partial_solution,fingerprint,conflict}.gleam
  store.gleam                 Store router
  store/{cas,hex,npm,git,url,metadata,gc,manifest,types}.gleam
  config.gleam                gleam.toml parser
  lockfile.gleam              kir.lock read/write
  pipeline.gleam              Download-verify-store-install orchestration
  security.gleam              SHA256, SRI, Sigstore, exclude-newer
  semver.gleam                SemVer parser
  spdx.gleam                  SPDX parser
  {license,audit,tree,export,completion,ffi,git,hashpin,...}.gleam
src/kirari_ffi.erl            Erlang FFI
```

## License

[Mozilla Public License 2.0](LICENSE)
