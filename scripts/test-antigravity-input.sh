#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
USAGE_ZSTD_LIBRARY="$(python3 scripts/checks/build_usage_zstd.py)"
AGY_INPUT_CHECK="$(mktemp -d "${TMPDIR:-/tmp}/agentpet-agy-input.XXXXXX")"
trap 'rm -rf "$AGY_INPUT_CHECK"' EXIT
swiftc -I Sources/CUsageZstd/include "$USAGE_ZSTD_LIBRARY" -parse-as-library -I Sources/CSQLite Sources/AgentPetCore/*.swift scripts/checks/antigravity_input.swift -o "$AGY_INPUT_CHECK/checks"
"$AGY_INPUT_CHECK/checks" "$@"
