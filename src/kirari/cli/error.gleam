//// CLI 에러 타입 — 모든 모듈 에러를 래핑하는 최상위 에러

import gleam/int
import gleam/list
import gleam/string
import kirari/audit
import kirari/cli/engines
import kirari/config
import kirari/export
import kirari/ffi as ffi_detect
import kirari/installer
import kirari/license
import kirari/lockfile
import kirari/migrate
import kirari/pipeline
import kirari/resolver
import kirari/resolver/conflict
import kirari/types

/// 최상위 에러 타입 — 모든 모듈 에러를 래핑
pub type KirError {
  ConfigErr(config.ConfigError)
  MigrateErr(migrate.MigrateError)
  LockErr(lockfile.LockfileError)
  ResolveErr(resolver.ResolverError)
  PipelineErr(pipeline.PipelineError)
  ExportErr(export.ExportError)
  LicenseErr(license.LicenseError)
  AuditErr(audit.AuditError)
  FfiErr(ffi_detect.FfiError)
  EnginesErr(violations: List(engines.EngineViolation))
  UserError(detail: String)
}

/// 에러를 사람이 읽을 수 있는 문자열로 변환
pub fn format_error(error: KirError) -> String {
  case error {
    ConfigErr(e) ->
      case e {
        config.FileNotFound(p) -> "file not found: " <> p
        config.ParseError(d) -> "parse error: " <> d
        config.InvalidField(f, d) -> "invalid field " <> f <> ": " <> d
        config.WriteError(p, d) -> "write error " <> p <> ": " <> d
      }
    MigrateErr(e) ->
      case e {
        migrate.FileNotFound(p) -> "file not found: " <> p
        migrate.ParseError(d) -> "parse error: " <> d
        migrate.InvalidField(f, d) -> "invalid field " <> f <> ": " <> d
      }
    LockErr(e) ->
      case e {
        lockfile.FileNotFound(p) -> "lockfile not found: " <> p
        lockfile.ParseError(d) -> "lockfile parse error: " <> d
        lockfile.FrozenMismatch(d) -> "frozen lockfile mismatch: " <> d
        lockfile.WriteError(p, d) -> "lockfile write error " <> p <> ": " <> d
        lockfile.UnsupportedLockVersion(v, max) ->
          "kir.lock version "
          <> int.to_string(v)
          <> " is newer than supported version "
          <> int.to_string(max)
          <> ". Upgrade kirari."
      }
    ResolveErr(e) ->
      case e {
        resolver.IncompatibleVersions(pkg, cs) ->
          "no compatible version for "
          <> pkg
          <> " (constraints: "
          <> string.join(cs, ", ")
          <> ")"
        resolver.PackageNotFound(name, reg) ->
          "package not found: "
          <> name
          <> " ("
          <> types.registry_to_string(reg)
          <> ")"
        resolver.RegistryError(d) -> "registry error: " <> d
        resolver.CyclicDependency(c) ->
          "cyclic dependency: " <> string.join(c, " → ")
        resolver.ResolutionConflict(explanation, report) ->
          case report {
            Ok(r) -> conflict.format_report(r)
            Error(_) -> "dependency resolution failed:\n" <> explanation
          }
      }
    PipelineErr(e) ->
      case e {
        pipeline.DownloadError(name, ver, d) ->
          "download failed: " <> name <> "@" <> ver <> " — " <> d
        pipeline.StoreErr(se) -> "store error: " <> string.inspect(se)
        pipeline.InstallErr(ie) ->
          case ie {
            installer.RollbackTriggered(d) ->
              "install failed, rolled back to previous state: " <> d
            installer.RollbackFailed(o, r) ->
              "CRITICAL: install failed ("
              <> o
              <> ") and rollback also failed ("
              <> r
              <> "). Manual recovery may be needed."
            _ -> "install error: " <> string.inspect(ie)
          }
        pipeline.ProvenanceErr(name, detail) ->
          "provenance verification failed: " <> name <> " — " <> detail
        pipeline.OfflinePackageMissing(name, version, registry) ->
          "package not available offline: "
          <> name
          <> "@"
          <> version
          <> " ("
          <> types.registry_to_string(registry)
          <> ")"
      }
    ExportErr(e) ->
      case e {
        export.WriteError(p, d) -> "export write error " <> p <> ": " <> d
      }
    AuditErr(e) ->
      case e {
        audit.AdvisoryFetchError(source, detail) ->
          "advisory fetch failed (" <> source <> "): " <> detail
        audit.AdvisoryParseError(source, detail) ->
          "advisory parse error (" <> source <> "): " <> detail
      }
    FfiErr(e) ->
      case e {
        ffi_detect.IoError(d) -> "ffi detection error: " <> d
      }
    LicenseErr(e) ->
      case e {
        license.PolicyConflict(d) -> "license policy conflict: " <> d
      }
    EnginesErr(violations) ->
      "engine constraint not satisfied:\n"
      <> string.join(
        list.map(violations, fn(v) {
          let detected_str = case v.detected {
            Ok(ver) -> ver
            Error(reason) -> reason
          }
          "  "
          <> v.engine
          <> " "
          <> detected_str
          <> " does not satisfy "
          <> v.constraint
        }),
        "\n",
      )
    UserError(d) -> d
  }
}
