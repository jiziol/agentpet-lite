#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
USAGE_ZSTD_LIBRARY="$(python3 scripts/checks/build_usage_zstd.py)"
SOCKET_CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agentpet-socket-check.XXXXXX")"
trap 'rm -rf "$SOCKET_CHECK_DIR"' EXIT
swiftc -I Sources/CUsageZstd/include "$USAGE_ZSTD_LIBRARY" -swift-version 6 -DSOCKET_PORTABLE -parse-as-library -I Sources/CSQLite Sources/AgentPetCore/*.swift Sources/App/AppFileDescriptorBudget.swift Tests/AgentPetCoreTests/SocketTransportScenarios.swift scripts/checks/socket_main.swift -o "$SOCKET_CHECK_DIR/checks"
python3 - "$SOCKET_CHECK_DIR/checks" <<'PY'
import resource,subprocess,sys
subprocess.run([sys.argv[1]],check=True,timeout=45)
inherited = resource.getrlimit(resource.RLIMIT_NOFILE)
def limits(soft, hard=inherited[1]):
    return lambda: resource.setrlimit(resource.RLIMIT_NOFILE, (soft, hard))
for scenario in ['fd-pressure-unprepared', 'fd-pressure-prepared']:
    subprocess.run([sys.argv[1], scenario], check=True, timeout=15, preexec_fn=limits(256))
subprocess.run([sys.argv[1], 'fd-hard-cap'], check=True, timeout=15, preexec_fn=limits(128, 128))
subprocess.run([sys.argv[1], 'fd-keep-higher'], check=True, timeout=15, preexec_fn=limits(4096))
assert resource.getrlimit(resource.RLIMIT_NOFILE) == inherited
PY
