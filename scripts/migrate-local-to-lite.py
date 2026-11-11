#!/usr/bin/env python3
"""Copy a stopped Local installation's durable data into a new Lite data root.

Planning is read-only. Copying never overwrites a destination or changes the
source, client configuration, preferences domain, login item or installed app.
The caller imports the prepared preferences only after checking the report.
"""
from pathlib import Path
from contextlib import contextmanager, closing
import argparse
import fcntl
import hashlib
import json
import os
import plistlib
import shutil
import sqlite3
import stat
import tempfile


DURABLE = ("codex-sessions-v1.json", "approval-gate.json", "pets", "sounds", "history", "usage-v1", "queue")
SOURCE_BUNDLE = "local.acerz.agentpet"


class MigrationError(ValueError):
    pass


def private_path(path, directory=None):
    path = Path(os.path.abspath(path))
    for parent in [*reversed(path.parents), path]:
        if parent.is_symlink():
            raise MigrationError("Symbolic-link paths are not migrated: " + str(parent))
    info = path.lstat()
    if info.st_uid != os.getuid():
        raise MigrationError("Source is not owned by the current user: " + str(path))
    if directory is True and not stat.S_ISDIR(info.st_mode):
        raise MigrationError("Expected a directory: " + str(path))
    if directory is False and (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1):
        raise MigrationError("Expected a private regular file: " + str(path))
    return path


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def files_in(source):
    rows = []
    for name in DURABLE:
        path = source / name
        if not path.exists() and not path.is_symlink():
            continue
        if path.is_symlink():
            raise MigrationError("Symbolic-link data is not migrated: " + str(path))
        candidates = [path] + sorted(path.rglob("*")) if path.is_dir() else [path]
        for item in candidates:
            if item.is_symlink():
                raise MigrationError("Symbolic-link data is not migrated: " + str(item))
            if item.is_dir():
                private_path(item, directory=True)
                continue
            private_path(item, directory=False)
            relative = item.relative_to(source).as_posix()
            if relative in ("usage-v1/ledger.sqlite-wal", "usage-v1/ledger.sqlite-shm"):
                continue  # SQLite's backup API includes committed WAL contents.
            rows.append({"path": relative, "bytes": item.stat().st_size, "sha256": digest(item)})
    return rows


def ledger_fingerprint(path):
    with closing(sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=2)) as db:
        db.execute("PRAGMA query_only=ON")
        if db.execute("PRAGMA quick_check").fetchone() != ("ok",):
            raise MigrationError("Usage ledger integrity check failed")
        metadata = dict(db.execute("SELECT key,value FROM usage_meta"))
        if metadata.get("schema") != "1" or metadata.get("mode") != "formal":
            raise MigrationError("Only a compatible formal usage ledger can migrate")
        result = {}
        for table, order in [("usage_meta", "key"), ("usage_sources", "id"), ("usage_records", "source_id,id")]:
            h = hashlib.sha256()
            count = 0
            for row in db.execute("SELECT * FROM " + table + " ORDER BY " + order):
                for cell in row:
                    blob = cell if isinstance(cell, bytes) else json.dumps(cell, ensure_ascii=False).encode()
                    h.update(len(blob).to_bytes(8, "big")); h.update(blob)
                count += 1
            result[table] = {"rows": count, "sha256": h.hexdigest()}
        return result


def rewrite_preferences(value, source, destination):
    """Rewrite exact app-owned paths; never replace mentions inside user text."""
    if isinstance(value, dict):
        return {key: rewrite_preferences(item, source, destination) for key, item in value.items()}
    if isinstance(value, list):
        return [rewrite_preferences(item, source, destination) for item in value]
    if isinstance(value, (str, bytes)):
        text = value if isinstance(value, str) else None
        if text is not None and (text == str(source) or text.startswith(str(source) + "/")):
            return str(destination) + text[len(str(source)):]
        # Several app preference values contain JSON data rather than plists.
        try:
            decoded = json.loads(value)
        except (ValueError, UnicodeError, TypeError):
            return value
        if not isinstance(decoded, (dict, list)):
            return value
        rewritten = rewrite_preferences(decoded, source, destination)
        if rewritten == decoded:
            return value
        result = json.dumps(rewritten, ensure_ascii=False, separators=(",", ":"))
        return result if isinstance(value, str) else result.encode()
    return value


@contextmanager
def stopped_source(source):
    path = private_path(source / "instance.lock", directory=False)
    fd = os.open(path, os.O_RDWR | os.O_NOFOLLOW)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise MigrationError("Quit AgentPet Local normally before copying") from error
        yield
    finally:
        os.close(fd)


def plan(source, destination, preferences, target_bundle):
    source = private_path(source, directory=True)
    destination = Path(os.path.abspath(destination))
    private_path(destination.parent, directory=True)
    if destination.exists() or destination.is_symlink():
        raise MigrationError("Destination already exists; it will not be overwritten")
    if source == destination or source in destination.parents or destination in source.parents:
        raise MigrationError("Source and destination must be independent directories")
    if not target_bundle or target_bundle == SOURCE_BUNDLE:
        raise MigrationError("A distinct Lite Bundle ID is required")
    preferences = private_path(preferences, directory=False)
    values = plistlib.loads(preferences.read_bytes())
    if not isinstance(values, dict):
        raise MigrationError("Invalid preferences export")
    if not (source / "codex-sessions-v1.json").is_file():
        raise MigrationError("Local session snapshot is missing")
    # Validate before copying any data; do not treat an unsupported ledger as empty.
    ledger = source / "usage-v1/ledger.sqlite"
    if ledger.exists():
        private_path(ledger, directory=False)
    fingerprint = ledger_fingerprint(ledger) if ledger.exists() else None
    return {"protocol": 1, "sourceRoot": str(source), "destinationRoot": str(destination),
            "sourceBundle": SOURCE_BUNDLE, "destinationBundle": target_bundle,
            "files": files_in(source), "preferenceKeys": sorted(values),
            "preferencesSHA256": digest(preferences), "ledger": fingerprint}


def copy_data(source, destination, preferences, target_bundle):
    source = private_path(source, directory=True)
    destination = Path(os.path.abspath(destination))
    with stopped_source(source):
        report = plan(source, destination, preferences, target_bundle)
        stage = Path(tempfile.mkdtemp(prefix=".agentpet-lite-migration-", dir=destination.parent))
        try:
            copied = []
            for row in report["files"]:
                original, target = source / row["path"], stage / row["path"]
                target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                if row["path"] == "usage-v1/ledger.sqlite":
                    with closing(sqlite3.connect(original.as_uri() + "?mode=ro", uri=True)) as src:
                        with closing(sqlite3.connect(target)) as dst:
                            src.backup(dst)
                            dst.execute("PRAGMA journal_mode=DELETE")
                    os.chmod(target, 0o600)
                    if ledger_fingerprint(target) != report["ledger"]:
                        raise MigrationError("Copied ledger differs from the source")
                else:
                    shutil.copy2(original, target, follow_symlinks=False)
                    if digest(target) != row["sha256"]:
                        raise MigrationError("Copied file differs: " + row["path"])
                copied.append({"path": row["path"], "sha256": digest(target)})
            # Detect new/changed queued events or durable files during the copy.
            if files_in(source) != report["files"]:
                raise MigrationError("Source changed during copying; nothing was installed")
            values = plistlib.loads(Path(preferences).read_bytes())
            if digest(Path(preferences)) != report["preferencesSHA256"]:
                raise MigrationError("Preferences export changed during copying")
            prepared = rewrite_preferences(values, source, destination)
            pref = stage / "migrated-preferences.plist"
            pref.write_bytes(plistlib.dumps(prepared)); os.chmod(pref, 0o600)
            report.update(copied=copied, status="copied", preparedPreferencesSHA256=digest(pref))
            marker = stage / "local-migration-v1.json"
            marker.write_text(json.dumps(report, indent=2) + "\n"); os.chmod(marker, 0o600)
            if destination.exists() or destination.is_symlink():
                raise MigrationError("Destination appeared during copying")
            os.rename(stage, destination)
            return report
        finally:
            if stage.exists():
                shutil.rmtree(stage)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["plan", "copy"])
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--destination", required=True, type=Path)
    parser.add_argument("--preferences", required=True, type=Path)
    parser.add_argument("--target-bundle", required=True)
    parser.add_argument("--report", required=True, type=Path)
    args = parser.parse_args()
    if args.report.exists():
        parser.error("Report already exists; preserve earlier results")
    action = plan if args.action == "plan" else copy_data
    result = action(args.source, args.destination, args.preferences, args.target_bundle)
    args.report.write_text(json.dumps(result, indent=2) + "\n")
    os.chmod(args.report, 0o600)
    print("Migration " + args.action + " complete; source preserved")


if __name__ == "__main__":
    main()
