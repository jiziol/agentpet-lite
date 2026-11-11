"""Exercise the local installers only under temporary config directories."""
from pathlib import Path
import importlib.util
import json
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[2]
checks = 0

def check(value, message):
    global checks
    if not value:
        raise AssertionError(message)
    checks += 1

with tempfile.TemporaryDirectory(prefix='agentpet-hook-migration-') as folder:
    root = Path(folder)
    helper = root / 'AgentPet Lite.app/Contents/MacOS/agentpet'
    helper.parent.mkdir(parents=True)
    helper.write_text('#!/bin/sh\nexit 0\n')
    for name in ('codex', 'antigravity'):
        script = REPO / ('scripts/install-' + name + '-local.py')
        spec = importlib.util.spec_from_file_location('installer_' + name, script)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        path = root / (name + '.json')
        path.write_bytes(b'original')
        module.atomic(path, b'installed', b'original')
        check(path.read_bytes() == b'installed', name + ' atomic install')
        path.write_bytes(b'third-party edit')
        try:
            module.atomic(path, b'wrong', b'installed')
        except SystemExit:
            pass
        else:
            raise AssertionError(name + ' overwrote concurrent edit')
        check(path.read_bytes() == b'third-party edit', name + ' edit preserved')
        path.unlink()
        destination = root / (name + '-target')
        destination.write_bytes(b'original')
        path.symlink_to(destination)
        try:
            module.atomic(path, b'wrong', b'original')
        except SystemExit:
            pass
        else:
            raise AssertionError(name + ' replaced symlink')
        check(path.is_symlink() and destination.read_bytes() == b'original', name + ' link preserved')
    for name, flag in [('codex', '--codex-home'), ('antigravity', '--antigravity-home')]:
        home = root / (name + '-home'); home.mkdir()
        config = home / 'hooks.json'
        owned = {'type': 'command', 'command': '"/Applications/AgentPet.app/Contents/MacOS/agentpet" hook --agent ' + name}
        foreign = {'type': 'command', 'command': 'echo agentpet hook', 'timeout': 7}
        mixed = {'matcher': 'Bash', 'metadata': 42, 'hooks': [owned, foreign]}
        if name == 'codex':
            data = {'hooks': {'PreToolUse': [mixed]}, 'other': True}
        else:
            data = {'agentpet': {'PreToolUse': [mixed], 'PostToolUse': [mixed], 'Stop': [owned, foreign]}, 'other': {'keep': True}}
        before = (json.dumps(data, indent=3) + '\n').encode(); config.write_bytes(before)
        backup_root = root / (name + '-backups')
        args = ['python3', str(REPO / ('scripts/install-' + name + '-local.py')), flag, str(home), '--backup-root', str(backup_root), '--agentpet-bin', str(helper)]
        run = subprocess.run(args, capture_output=True)
        check(run.returncode == 0, name + ' isolated migration: ' + run.stderr.decode())
        after = config.read_bytes(); migrated = json.loads(after)
        mapping = migrated['hooks' if name == 'codex' else 'agentpet']
        event = 'PreToolUse' if name == 'codex' else 'PostToolUse'
        check(mapping[event][0]['hooks'][1] == foreign and mapping[event][0]['metadata'] == 42, name + ' mixed metadata retained')
        if name == 'antigravity':
            check(mapping['PreToolUse'][0]['hooks'] == [foreign], 'agy only owned permission removed')
        backup = next(backup_root.iterdir())
        rollback = args + ['--rollback', str(backup)]
        config.write_bytes(b'{"later_edit":true}')
        check(subprocess.run(rollback, capture_output=True).returncode != 0 and config.read_bytes() == b'{"later_edit":true}', name + ' rollback rejects later edit')
        config.write_bytes(after)
        run = subprocess.run(rollback, capture_output=True)
        check(run.returncode == 0 and config.read_bytes() == before, name + ' byte-exact rollback')
print(f'PASS: {checks} isolated local Hook migration/conflict checks')
