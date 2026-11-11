#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
USAGE_ZSTD_LIBRARY="$(python3 scripts/checks/build_usage_zstd.py)"
HOOK_CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agentpet-hook-check.XXXXXX")"
trap 'rm -rf "$HOOK_CHECK_DIR"' EXIT
swiftc -I Sources/CUsageZstd/include "$USAGE_ZSTD_LIBRARY" -swift-version 6 -DHOOK_PORTABLE -parse-as-library -I Sources/CSQLite Sources/AgentPetCore/*.swift Tests/AgentPetCoreTests/HookOwnershipScenarios.swift scripts/checks/hooks_main.swift -o "$HOOK_CHECK_DIR/checks"
"$HOOK_CHECK_DIR/checks"
