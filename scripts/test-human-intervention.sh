#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
USAGE_ZSTD_LIBRARY="$(python3 scripts/checks/build_usage_zstd.py)"
ATTENTION_CHECK="$(mktemp -d "${TMPDIR:-/tmp}/agentpet-attention-check.XXXXXX")"
trap 'rm -rf "$ATTENTION_CHECK"' EXIT
swiftc -I Sources/CUsageZstd/include "$USAGE_ZSTD_LIBRARY" -parse-as-library -I Sources/CSQLite Sources/AgentPetCore/*.swift scripts/checks/human_intervention.swift -o "$ATTENTION_CHECK/checks"
"$ATTENTION_CHECK/checks"
"$ATTENTION_CHECK/checks" "$ATTENTION_CHECK/pi.mjs" "$ATTENTION_CHECK/capture"
node scripts/checks/pi-plugin.mjs "$ATTENTION_CHECK"
