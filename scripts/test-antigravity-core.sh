#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
USAGE_ZSTD_LIBRARY="$(python3 scripts/checks/build_usage_zstd.py)"
TEMP_CHECK="$(mktemp -d "${TMPDIR:-/tmp}/agentpet-core-check.XXXXXX")"
trap 'rm -rf "$TEMP_CHECK"' EXIT
swiftc -I Sources/CUsageZstd/include "$USAGE_ZSTD_LIBRARY" -parse-as-library -I Sources/CSQLite Sources/AgentPetCore/*.swift scripts/checks/antigravity.swift -o "$TEMP_CHECK/checks"
"$TEMP_CHECK/checks"
