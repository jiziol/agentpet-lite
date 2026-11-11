#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
USAGE_ZSTD_LIBRARY="$(python3 scripts/checks/build_usage_zstd.py)"
R0_CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agentpet-r0-check.XXXXXX")"
trap 'rm -rf "$R0_CHECK_DIR"' EXIT
swiftc -I Sources/CUsageZstd/include "$USAGE_ZSTD_LIBRARY" -parse-as-library -I Sources/CSQLite Sources/AgentPetCore/*.swift scripts/checks/refactor_replay.swift -o "$R0_CHECK_DIR/replay"
"$R0_CHECK_DIR/replay" scripts/checks/fixtures/refactor-baseline/session-events.json
"$R0_CHECK_DIR/replay" --native scripts/checks/fixtures/refactor-baseline/codex-native-metadata.jsonl
swiftc -I Sources/CUsageZstd/include "$USAGE_ZSTD_LIBRARY" -parse-as-library -I Sources/CSQLite Sources/AgentPetCore/*.swift scripts/checks/reliability_baseline.swift -o "$R0_CHECK_DIR/reliability"
if [[ $# -eq 0 ]]; then set -- --baseline; fi
"$R0_CHECK_DIR/reliability" "$@"
