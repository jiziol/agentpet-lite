#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
USAGE_ZSTD_LIBRARY="$(python3 scripts/checks/build_usage_zstd.py)"
if [[ $# != 1 || ! -x "$1" ]]; then
  echo 'Usage: bash scripts/test-integration-setup.sh /absolute/path/to/AgentPet\ Local.app/Contents/MacOS/agentpet' >&2
  exit 2
fi
TEST_STAGE="$(mktemp -d /tmp/ap-integration-setup.XXXXXX)"
trap 'rm -rf "$TEST_STAGE"' EXIT
swiftc -I Sources/CUsageZstd/include "$USAGE_ZSTD_LIBRARY" -DAGENTPET_LOCAL -parse-as-library -I Sources/CSQLite Sources/AgentPetCore/*.swift scripts/checks/integration-setup.swift -o "$TEST_STAGE/setup"
python3 scripts/checks/test_integration_native.py "$TEST_STAGE/setup" "$1" "$TEST_STAGE/report.json"
# The report contains synthetic paths/events only. Optional destination must be
# outside the repository for a durable private record.
if [[ -n "${AGENTPET_INTEGRATION_REPORT:-}" ]]; then
  cp "$TEST_STAGE/report.json" "$AGENTPET_INTEGRATION_REPORT"
fi
