#!/usr/bin/env python3
"""Switch only the exact official AgentPet Antigravity hook, with guarded rollback.
Preserves unrelated Antigravity settings and does not write hook trust approvals.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
from datetime import datetime
from zoneinfo import ZoneInfo

OFFICIAL = '/Applications/AgentPet.app/Contents/MacOS/agentpet'
LOCAL = '/Applications/AgentPet Local.app/Contents/MacOS/agentpet'
EVENTS = ('PreInvocation', 'PreToolUse', 'PostToolUse', 'Stop')

def digest(data):
    return hashlib.sha256(data).hexdigest()

def check_unchanged(path, expected):
    if path.is_symlink() or (path.read_bytes() if path.exists() else None) != expected:
        raise SystemExit('Config changed during migration; refusing to overwrite. Backup retained.')


def atomic(path, data, expected):
    check_unchanged(path, expected)
    temp = path.with_name(path.name + '.agentpet-local.tmp')
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'wb') as f:
        f.write(data)
    try:
        check_unchanged(path, expected)
        os.replace(temp, path)
    finally:
        if temp.exists():
            temp.unlink()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--antigravity-home', type=Path, default=Path.home()/'.gemini/config')
    parser.add_argument('--backup-root', type=Path, default=Path.home()/'.agentpet-local/backups')
    parser.add_argument('--rollback', type=Path, help='backup directory returned by a previous switch')
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--agentpet-bin', type=Path, default=Path(LOCAL), help='installed helper path; default preserves Local migration')
    args = parser.parse_args()
    path = args.antigravity_home/'hooks.json'
    if path.is_symlink():
        raise SystemExit("Refusing a symlink hook config.")
    before = path.read_bytes()
    if args.rollback:
        manifest = json.loads((args.rollback/'manifest.json').read_text())
        if str(path.resolve()) != manifest['path'] or digest(before) != manifest['installedSha256']:
            raise SystemExit('Hook config changed since installation; refusing to overwrite. Merge the backed-up AgentPet entries manually.')
        restored = (args.rollback/'hooks.json').read_bytes()
        if digest(restored) != manifest['originalSha256']:
            raise SystemExit('Backup checksum mismatch.')
        if not args.dry_run:
            atomic(path, restored, before)
        print('Rollback verified' if args.dry_run else 'Original hook configuration restored; normal Antigravity trust rules still apply.')
        return
    document = json.loads(before)
    changes = 0
    for name, spec in document.items():
        if not isinstance(spec, dict):
            continue
        for event in EVENTS:
            kept_entries = []
            for entry in spec.get(event, []):
                kept_handlers = []
                for hook in entry.get('hooks', [entry]):
                    try:
                        command = shlex.split(hook.get('command', ''))
                    except ValueError:
                        command = []
                    owned = command in ([OFFICIAL, 'hook', '--agent', 'antigravity'], [LOCAL, 'hook', '--agent', 'antigravity'])
                    if owned and event == 'PreToolUse':
                        changes += 1
                        continue
                    if owned and command[0] == OFFICIAL:
                        hook['command'] = shlex.join([str(args.agentpet_bin), 'hook', '--agent', 'antigravity'])
                        changes += 1
                    kept_handlers.append(hook)
                if kept_handlers:
                    if 'hooks' in entry:
                        entry['hooks'] = kept_handlers
                        kept_entries.append(entry)
                    else:
                        kept_entries.extend(kept_handlers)
            if kept_entries:
                spec[event] = kept_entries
            elif event in spec:
                del spec[event]
    if not changes:
        raise SystemExit('No exact official AgentPet Antigravity hook found; no files changed.')
    after = (json.dumps(document, ensure_ascii=False, indent=2)+'\n').encode()
    if args.dry_run:
        print(f'Would update/remove {changes} AgentPet Antigravity hook commands; unrelated entries preserved.')
        return
    if not args.agentpet_bin.is_absolute() or not args.agentpet_bin.is_file():
        raise SystemExit('Install and verify the app at --agentpet-bin first (absolute path required).')
    backup = args.backup_root/datetime.now(ZoneInfo('Asia/Shanghai')).strftime('antigravity-%Y%m%d-%H%M%S-%f')
    backup.mkdir(parents=True, mode=0o700)
    os.chmod(args.backup_root, 0o700)
    original = backup/'hooks.json'
    original.write_bytes(before); original.chmod(0o600)
    manifest = {'path': str(path.resolve()), 'originalSha256': digest(before), 'installedSha256': digest(after), 'changedCommands': changes}
    (backup/'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
    atomic(path, after, before)
    print(f'Updated/removed {changes} Antigravity hooks. Backup: {backup}')
    print('The user must review the new hook command in Antigravity if requested. No trust approval was changed.')

if __name__ == '__main__':
    main()
