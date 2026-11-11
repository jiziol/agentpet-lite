#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
USAGE_ZSTD_LIBRARY="$(python3 scripts/checks/build_usage_zstd.py)"
RECEIPT_CHECK="$(mktemp -d "${TMPDIR:-/tmp}/agentpet-receipt-check.XXXXXX")"
trap 'rm -rf "$RECEIPT_CHECK"' EXIT
swiftc -I Sources/CUsageZstd/include "$USAGE_ZSTD_LIBRARY" -parse-as-library -I Sources/CSQLite Sources/AgentPetCore/*.swift scripts/checks/read_receipts.swift -o "$RECEIPT_CHECK/checks"
"$RECEIPT_CHECK/checks"
