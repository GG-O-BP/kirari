//// SBOM 생성 — SPDX 2.3 / CycloneDX 1.5 JSON 형식

import gleam/dict.{type Dict}
import kirari/resolver.{type VersionInfo}
import kirari/sbom/cyclonedx
import kirari/sbom/spdx
import kirari/types.{type KirConfig, type KirLock}

/// SBOM 출력 형식
pub type SbomFormat {
  Spdx
  CycloneDx
}

/// SBOM 생성 에러
pub type SbomError {
  MissingLockfile
  MissingConfig
  SerializationError(detail: String)
}

/// SBOM JSON 문자열 생성
pub fn generate(
  config: KirConfig,
  lock: KirLock,
  version_infos: Dict(String, VersionInfo),
  format: SbomFormat,
) -> Result(String, SbomError) {
  case format {
    Spdx -> Ok(spdx.generate(config, lock, version_infos))
    CycloneDx -> Ok(cyclonedx.generate(config, lock, version_infos))
  }
}

/// 문자열에서 SbomFormat 파싱
pub fn parse_format(s: String) -> Result(SbomFormat, Nil) {
  case s {
    "spdx" -> Ok(Spdx)
    "cyclonedx" | "cdx" -> Ok(CycloneDx)
    _ -> Error(Nil)
  }
}
