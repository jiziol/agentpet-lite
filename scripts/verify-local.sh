#!/usr/bin/env bash
# portable deliberately excludes XCTest; full must run both SwiftPM test targets.
set -euo pipefail

usage() {
  echo 'Usage: bash scripts/verify-local.sh [full|portable] [--log-dir DIRECTORY]'
}
MODE=full
if [[ $# -gt 0 && ( "$1" == full || "$1" == portable ) ]]; then
  MODE="$1"; shift
fi
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$REPO_ROOT/.build/verification/$(date +%Y%m%d-%H%M%S)-$$"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --log-dir)
      [[ $# -ge 2 && -n "$2" ]] || { usage >&2; exit 2; }
      LOG_DIR="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ "$(uname -s)" == Darwin ]] || { echo 'FAIL: macOS is required.' >&2; exit 1; }
for runtime in xcrun swiftc node python3; do
  command -v "$runtime" >/dev/null || { echo "FAIL: missing $runtime" >&2; exit 1; }
done
node -e 'if (Number(process.versions.node.split(".")[0]) < 22) process.exit(1)' || {
  echo 'FAIL: Node.js 22 or newer is required.' >&2; exit 1;
}
python3 -c 'import sys; sys.exit(sys.version_info < (3, 9))' || {
  echo 'FAIL: Python 3.9 or newer is required.' >&2; exit 1;
}
SWIFT_BIN="$(dirname "$(xcrun --find swiftc)")"
export PATH="$SWIFT_BIN:$PATH"
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
swiftc --version | python3 -c 'import re,sys; s=sys.stdin.read(); m=re.search(r"Swift version (\d+)", s); sys.exit(not m or int(m[1]) < 6)' || {
  echo 'FAIL: Swift 6 or newer is required.' >&2; exit 1;
}
if [[ "$MODE" == full ]]; then
  DEVELOPER_PATH="${DEVELOPER_DIR:-$(xcode-select -p)}"
  [[ -d "$DEVELOPER_PATH/Platforms/MacOSX.platform/Developer/Library/Frameworks/XCTest.framework" ]] || {
    echo 'FAIL: full requires complete Xcode with XCTest. Select it using DEVELOPER_DIR; portable is a separate mode.' >&2
    exit 1
  }
  xcrun xcodebuild -checkFirstLaunchStatus || {
    echo 'FAIL: Xcode first-launch setup is incomplete.' >&2; exit 1;
  }
fi

python3 - "$LOG_DIR" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
if root.exists() and (not root.is_dir() or any(root.iterdir())):
    sys.exit('FAIL: log directory must be new or empty; preserve earlier verification logs.')
PY
mkdir -p "$LOG_DIR"
LOG_DIR="$(cd "$LOG_DIR" && pwd)"
# Keep paths short enough for Darwin's Unix socket limit. All test data is disposable.
VERIFY_ROOT="$(mktemp -d /tmp/ap-verify.XXXXXX)"
mkdir -p "$VERIFY_ROOT/home" "$VERIFY_ROOT/tmp"
export CFFIXED_USER_HOME="$VERIFY_ROOT/home"
export TMPDIR="$VERIFY_ROOT/tmp/" AGENTPET_LOCAL_HOME="$VERIFY_ROOT/home/.agentpet-local"
export CODEX_HOME="$VERIFY_ROOT/home/.codex"
export XDG_CONFIG_HOME="$VERIFY_ROOT/home/.config" XDG_DATA_HOME="$VERIFY_ROOT/home/.local/share"
export XDG_CACHE_HOME="$VERIFY_ROOT/home/.cache" XDG_STATE_HOME="$VERIFY_ROOT/home/.local/state"
export PYTHONDONTWRITEBYTECODE=1
STAGE=preflight
XCTEST_PASSED=false
: > "$LOG_DIR/stages.tsv"
finish() {
  local status=$?
  trap - EXIT
  # Never report success if parsing/interruption prevented the final stage.
  if [[ $status -eq 0 && "$STAGE" != complete ]]; then status=1; fi
  python3 - "$LOG_DIR" "$MODE" "$status" "$STAGE" "$XCTEST_PASSED" <<'PY'
import json, sys
from pathlib import Path
logs, mode, status, stage, xctest = sys.argv[1:]
root = Path(logs)
stages = [line.split('\t') for line in (root/'stages.tsv').read_text().splitlines()]
(root/'summary.json').write_text(json.dumps({
    'mode': mode, 'passed': status == '0', 'exit_code': int(status),
    'last_stage': stage, 'xctest_passed': xctest == 'true',
    'stages': [{'name': name, 'passed': result == '0'} for name, result in stages],
    'xctest': json.loads((root/'xctest-result.json').read_text()) if (root/'xctest-result.json').exists() else None,
}, indent=2) + '\n')
PY
  rm -rf "$VERIFY_ROOT"
  if [[ $status -ne 0 ]]; then echo "FAIL: $STAGE; logs: $LOG_DIR" >&2; fi
  exit "$status"
}
trap finish EXIT
run_check() {
  STAGE="$1"; shift
  echo "[$MODE] $STAGE"
  if "$@" > "$LOG_DIR/$STAGE.log" 2>&1; then
    if [[ "$STAGE" == xctest ]]; then
      python3 scripts/checks/xctest_result.py "$LOG_DIR/$STAGE.log" "$LOG_DIR/xctest-result.json" || {
        local status=$?
        printf '%s\t%s\n' "$STAGE" "$status" >> "$LOG_DIR/stages.tsv"
        return "$status"
      }
    else
      tail -n 3 "$LOG_DIR/$STAGE.log"
    fi
    printf '%s\t0\n' "$STAGE" >> "$LOG_DIR/stages.tsv"
  else
    local status=$?
    printf '%s\t%s\n' "$STAGE" "$status" >> "$LOG_DIR/stages.tsv"
    tail -n 20 "$LOG_DIR/$STAGE.log" >&2
    return "$status"
  fi
}
cd "$REPO_ROOT"
if [[ -e "$REPO_ROOT/.git" ]]; then
  run_check public-file-scope python3 scripts/prepare-source.py --check-index
else
  run_check public-file-scope python3 scripts/prepare-source.py --check-tree
fi
run_check preflight swift -e 'import Foundation
let expected = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]!
guard NSHomeDirectory() == expected, FileManager.default.homeDirectoryForCurrentUser.path == expected else {
    fatalError("Foundation home isolation failed")
}
print("PASS: Foundation home isolation")'
{
  swiftc --version
  node --version
  python3 --version
  if [[ "$MODE" == full ]]; then xcrun xcodebuild -version; fi
} > "$LOG_DIR/runtimes.log" 2>&1
if [[ "$MODE" == full ]]; then
  SWIFTPM_TEST_FLAGS=(--disable-automatic-resolution)
  if [[ -n "${AGENTPET_BUILD_CACHE:-}" ]]; then
    SWIFTPM_TEST_FLAGS+=(--scratch-path "$AGENTPET_BUILD_CACHE")
  fi
  run_check xctest swift test "${SWIFTPM_TEST_FLAGS[@]}"
  XCTEST_PASSED=true
fi
for check in codex-core antigravity-core read-receipts opencode-core human-intervention antigravity-input socket-core hook-ownership archive-core; do
  run_check "$check" bash "scripts/test-$check.sh"
done
run_check strict-regression bash scripts/test-refactor-baseline.sh --regression
run_check codex-migration python3 scripts/checks/test_codex_installer.py
run_check antigravity-migration python3 scripts/checks/test_antigravity_installer.py
run_check hook-migrations python3 scripts/checks/hook_migrations.py
run_check reviewed-animations python3 scripts/checks/test_reviewed_animations.py
run_check dsh-independent-contract python3 scripts/checks/test_dsh_independent_contract.py
run_check lite-identity-migration python3 scripts/checks/test_lite_migration.py
STAGE=complete
echo "PASS: $MODE verification; logs: $LOG_DIR"
if [[ "$MODE" == portable ]]; then echo 'XCTest was not run; use full for the structural-refactoring gate.'; fi
