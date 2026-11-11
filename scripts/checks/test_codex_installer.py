#!/usr/bin/env python3
import json
from pathlib import Path
import subprocess
import sys
import tempfile

script = Path(__file__).resolve().parents[1]/'install-codex-local.py'
with tempfile.TemporaryDirectory(prefix='agentpet-installer-') as temp:
    home = Path(temp)/'codex'; home.mkdir()
    backups = Path(temp)/'backups'
    helper = Path(temp)/"AgentPet Lite.app/Contents/MacOS/agentpet"
    helper.parent.mkdir(parents=True)
    helper.write_text('#!/bin/sh\nexit 0\n')
    path = home/'hooks.json'
    original = json.dumps({'unrelated': {'preserve': True}, 'hooks': {'Stop': [{'hooks': [{'type': 'command', 'command': '"/Applications/AgentPet.app/Contents/MacOS/agentpet" hook --agent codex'}, {'type': 'command', 'command': 'echo unrelated'}]}]}}).encode()
    path.write_bytes(original)
    base = [sys.executable,str(script),'--codex-home',str(home),'--backup-root',str(backups),'--agentpet-bin',str(helper)]
    def run(*args):
        return subprocess.run(base+list(args),capture_output=True)
    assert run('--dry-run').returncode == 0 and path.read_bytes() == original
    assert run().returncode == 0
    installed = path.read_bytes()
    data = json.loads(installed)
    assert data['unrelated'] == {'preserve': True}
    assert data['hooks']['Stop'][0]['hooks'][1]['command'] == 'echo unrelated'
    assert 'AgentPet Lite.app' in data['hooks']['Stop'][0]['hooks'][0]['command']
    assert run().returncode != 0 and path.read_bytes() == installed
    backup = next(backups.iterdir())
    path.write_bytes(installed+b' ')
    assert run('--rollback',str(backup)).returncode != 0
    assert path.read_bytes() == installed+b' '
    path.write_bytes(installed)
    assert run('--rollback',str(backup)).returncode == 0 and path.read_bytes() == original
    print('PASS: dry run, exact ownership, unrelated entries, repeat install, conflict-safe rollback and byte-exact restore')
