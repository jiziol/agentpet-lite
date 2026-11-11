#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
USAGE_ZSTD_LIBRARY="$(python3 scripts/checks/build_usage_zstd.py)"
TEMP_CHECK="$(mktemp -d "${TMPDIR:-/tmp}/agentpet-opencode-check.XXXXXX")"
OPENCODE_CHECK_HOME="$(mktemp -d /tmp/ap-oc-home.XXXXXX)"
trap 'rm -rf "$TEMP_CHECK" "$OPENCODE_CHECK_HOME"' EXIT
# Foundation and the Node navigation bridge must use the same disposable home.
# Keep it short enough for Darwin's Unix socket path limit, without changing HOME.
export CFFIXED_USER_HOME="$OPENCODE_CHECK_HOME"
swiftc -I Sources/CUsageZstd/include "$USAGE_ZSTD_LIBRARY" -DAGENTPET_LOCAL -parse-as-library -I Sources/CSQLite Sources/AgentPetCore/*.swift scripts/checks/opencode.swift -o "$TEMP_CHECK/checks"
"$TEMP_CHECK/checks"
"$TEMP_CHECK/checks" "$TEMP_CHECK/agentpet.mjs" "$TEMP_CHECK/capture"
node scripts/checks/opencode-plugin.mjs "$TEMP_CHECK"
node scripts/checks/opencode-subagent.mjs "$TEMP_CHECK"
"$TEMP_CHECK/checks" --speech-plugin "$TEMP_CHECK/speech.mjs" /usr/bin/true "$TEMP_CHECK/speech.sock"
node scripts/checks/opencode-speech.mjs "$TEMP_CHECK/speech.mjs" "$TEMP_CHECK/speech.sock"
"$TEMP_CHECK/checks" --v2-plugin "$TEMP_CHECK/v2.mjs" "$TEMP_CHECK/capture" "$TEMP_CHECK/v2.sock"
node scripts/checks/opencode-v2.mjs "$TEMP_CHECK"
"$TEMP_CHECK/checks" --tui-plugin "$TEMP_CHECK/tui.mjs" "$OPENCODE_CHECK_HOME/.agentpet-local/speech.sock"
node scripts/checks/opencode-tui.mjs "$TEMP_CHECK/tui.mjs" "$OPENCODE_CHECK_HOME/.agentpet-local/speech.sock"
"$TEMP_CHECK/checks" "$TEMP_CHECK/agentpet.local.js" '/Applications/AgentPet Local.app/Contents/MacOS/agentpet'
if [[ $# -eq 1 ]]; then
  "$TEMP_CHECK/checks" "$1" '/Applications/AgentPet Local.app/Contents/MacOS/agentpet'
fi
