#!/usr/bin/env python3
"""Bounded, read-only diagnostic for one real desktop turn ending.
Does not create turns, send messages, change hooks, or retain conversation text.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--session-id', required=True)
    parser.add_argument('--timeout', type=int, default=180)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    home = Path(os.environ.get('CODEX_HOME', Path.home()/'.codex'))
    local = Path(os.environ.get('AGENTPET_LOCAL_HOME', Path.home()/'.agentpet-local'))
    snapshot = local/'codex-sessions-v1.json'
    candidates = [(int(p.stem.removeprefix('state_')), p) for p in home.glob('state_*.sqlite') if p.stem.removeprefix('state_').isdigit()]
    db = sqlite3.connect(f'file:{max(candidates)[1]}?mode=ro', uri=True)
    row = db.execute('SELECT rollout_path FROM threads WHERE id=?', (args.session_id,)).fetchone()
    db.close()
    if not row:
        raise SystemExit('No exact native session metadata.')
    path = Path(row[0])

    def session():
        try:
            return next((s for s in json.loads(snapshot.read_text())['sessions'] if s['id'] == args.session_id), {})
        except (OSError, ValueError, KeyError):
            return {}

    turn = session().get('codexTurnID')
    if not turn:
        raise SystemExit('Native turn identity has not attached; refusing to guess.')
    report = {'sessionFingerprint': hashlib.sha256(args.session_id.encode()).hexdigest()[:12],
              'status': 'awaiting_real_terminal', 'timeoutSeconds': args.timeout}

    def save():
        args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n')
        args.output.chmod(0o600)
    save()
    last_mtime = None
    deadline = time.monotonic() + args.timeout
    terminal = None
    while time.monotonic() < deadline:
        try:
            mtime = path.stat().st_mtime_ns
            if mtime != last_mtime:
                last_mtime = mtime
                with path.open('rb') as f:
                    f.seek(0, 2)
                    size = f.tell()
                    f.seek(max(0, size-262144))
                    lines = f.read(262144).splitlines()
                for line in reversed(lines):
                    try:
                        value = json.loads(line)
                    except ValueError:
                        continue
                    payload = value.get('payload', {})
                    if value.get('type') == 'event_msg' and payload.get('turn_id') == turn and payload.get('type') in ('task_complete', 'turn_aborted'):
                        error = payload.get('error')
                        result = 'cancelled' if payload['type'] == 'turn_aborted' else ('failed' if error is not None else 'completed')
                        terminal = (result, value['timestamp'])
                        break
            if terminal:
                current = session()
                result, timestamp = terminal
                at = datetime.fromisoformat(timestamp.replace('Z', '+00:00')).timestamp()-978307200
                passed = (current.get('codexTurnID') == turn and current.get('state') == 'done' and
                          current.get('codexTurnResult') == result and abs(current.get('turnEndedAt', -1)-at) < .001)
                report.update(status='passed' if passed else 'awaiting_agentpet_terminal',
                              nativeResult=result, agentpetState=current.get('state'),
                              agentpetResult=current.get('codexTurnResult'), frozenAtNativeEnd=passed,
                              checkedAt=datetime.now(timezone.utc).isoformat())
                save()
                if passed:
                    print('PASS: real native terminal reconciled, result matches and clock freezes.')
                    return
        except OSError:
            pass
        time.sleep(1)
    report['status'] = 'timeout_without_confirmed_match'
    save()
    print('No verified terminal match before diagnostic timeout; not a pass.')


if __name__ == '__main__':
    main()
