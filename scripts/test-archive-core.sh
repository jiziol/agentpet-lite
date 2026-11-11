#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
USAGE_ZSTD_LIBRARY="$(python3 scripts/checks/build_usage_zstd.py)"
ARCHIVE_CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agentpet-archive-check.XXXXXX")"
trap 'rm -rf "$ARCHIVE_CHECK_DIR"' EXIT
swiftc -I Sources/CUsageZstd/include "$USAGE_ZSTD_LIBRARY" -swift-version 6 -DARCHIVE_PORTABLE -parse-as-library -I Sources/CSQLite Sources/AgentPetCore/*.swift Tests/AgentPetCoreTests/ArchiveReliabilityScenarios.swift scripts/checks/archive_main.swift -o "$ARCHIVE_CHECK_DIR/checks"
python3 - "$ARCHIVE_CHECK_DIR/checks" <<'PY'
import subprocess,sys
subprocess.run([sys.argv[1]],check=True,timeout=45)
PY
