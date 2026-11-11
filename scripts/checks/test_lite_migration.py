import fcntl
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("lite_migration", Path(__file__).resolve().parents[1] / "migrate-local-to-lite.py")
migration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migration)


class LiteMigrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ap-migration-")
        self.root = Path(self.temp.name).resolve()
        self.source = self.root / ".agentpet-local"
        self.source.mkdir(mode=0o700)
        self.destination = self.root / ".agentpet-lite"
        (self.source / "instance.lock").touch(mode=0o600)
        (self.source / "codex-sessions-v1.json").write_text('{"version":1,"sessions":[],"aoAttentionRecords":[]}')
        (self.source / "pets").mkdir()
        (self.source / "pets/pet.png").write_bytes(b"fixture pet")
        self.preferences = self.root / "local-preferences.plist"
        self.values = {"agentpet.care.v2": json.dumps({"pet": {"xp": 42, "totalTokens": 100}}),
                       "agentpet.selectedPet": "pet", "agentpet.usageChart.windowDays": 7,
                       "media": str(self.source / "pets/pet.png"),
                       "note": "Mention " + str(self.source) + " inside text",
                       "nested": json.dumps({"path": str(self.source / "pets/pet.png")}).encode()}
        self.preferences.write_bytes(plistlib.dumps(self.values))
        self.bundle = "io.github.jiziol.agentpet-lite"

    def tearDown(self):
        self.temp.cleanup()

    def plan(self):
        return migration.plan(self.source, self.destination, self.preferences, self.bundle)

    def copy(self):
        return migration.copy_data(self.source, self.destination, self.preferences, self.bundle)

    def ledger(self):
        path = self.source / "usage-v1/ledger.sqlite"
        path.parent.mkdir()
        db = sqlite3.connect(path)
        db.execute("PRAGMA journal_mode=WAL")
        db.execute("CREATE TABLE usage_meta(key TEXT PRIMARY KEY,value TEXT)")
        db.executemany("INSERT INTO usage_meta VALUES(?,?)", [("schema", "1"), ("mode", "formal"), ("start", "original")])
        db.execute("CREATE TABLE usage_sources(id TEXT PRIMARY KEY,state BLOB)")
        db.execute("INSERT INTO usage_sources VALUES('native-instance',?)", (b'{"intervals":[{"start":123}]}',))
        db.execute("CREATE TABLE usage_records(source_id TEXT,id TEXT,record BLOB)")
        db.execute("INSERT INTO usage_records VALUES('native-instance','call-1',?)", (b'{"tokens":100}',))
        db.commit()
        return db

    def test_plan_has_no_destination_or_source_changes(self):
        before = {p.relative_to(self.source): p.read_bytes() for p in self.source.rglob("*") if p.is_file()}
        result = self.plan()
        self.assertFalse(self.destination.exists())
        self.assertEqual(before, {p.relative_to(self.source): p.read_bytes() for p in self.source.rglob("*") if p.is_file()})
        self.assertEqual(len(result["files"]), 2)

    def test_copy_preserves_state_and_rewrites_only_exact_preference_paths(self):
        result = self.copy()
        self.assertEqual((self.source / "codex-sessions-v1.json").read_bytes(),
                         (self.destination / "codex-sessions-v1.json").read_bytes())
        values = plistlib.loads((self.destination / "migrated-preferences.plist").read_bytes())
        self.assertEqual(values["agentpet.care.v2"], self.values["agentpet.care.v2"])
        self.assertEqual(values["media"], str(self.destination / "pets/pet.png"))
        self.assertEqual(values["note"], self.values["note"])
        self.assertEqual(json.loads(values["nested"])["path"], str(self.destination / "pets/pet.png"))
        self.assertEqual(result["sourceBundle"], "local.acerz.agentpet")
        self.assertEqual(result["destinationBundle"], self.bundle)

    def test_wal_backup_preserves_calls_and_original_start(self):
        db = self.ledger()
        try:
            self.assertGreater((self.source / "usage-v1/ledger.sqlite-wal").stat().st_size, 0)
            before = migration.ledger_fingerprint(self.source / "usage-v1/ledger.sqlite")
            result = self.copy()
            self.assertEqual(result["ledger"], before)
            self.assertEqual(migration.ledger_fingerprint(self.destination / "usage-v1/ledger.sqlite"), before)
            self.assertFalse((self.destination / "usage-v1/ledger.sqlite-wal").exists())
        finally:
            db.close()

    def test_existing_target_is_never_overwritten(self):
        self.destination.mkdir()
        with self.assertRaises(migration.MigrationError): self.copy()
        self.assertEqual(list(self.destination.iterdir()), [])

    def test_live_source_lock_refuses_copy(self):
        with (self.source / "instance.lock").open("r+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(migration.MigrationError): self.copy()
        self.assertFalse(self.destination.exists())

    def test_links_inside_durable_data_are_rejected(self):
        (self.source / "pets/link").symlink_to(self.preferences)
        with self.assertRaises(migration.MigrationError): self.copy()
        self.assertFalse(self.destination.exists())

    def test_root_symlink_is_rejected(self):
        alias = self.root / "alias"
        alias.symlink_to(self.source)
        with self.assertRaises(migration.MigrationError):
            migration.copy_data(alias, self.destination, self.preferences, self.bundle)

    def test_hardlinked_file_is_rejected(self):
        os.link(self.preferences, self.source / "pets/linked.plist")
        with self.assertRaises(migration.MigrationError): self.copy()

    def test_runtime_and_historical_app_artifacts_stay_in_source(self):
        (self.source / "animation-work").mkdir()
        (self.source / "animation-work/old.app").write_bytes(b"old application")
        (self.source / "opencode-tui").mkdir()
        (self.source / "opencode-tui/live.json").write_text('{}')
        self.copy()
        self.assertFalse((self.destination / "animation-work").exists())
        self.assertFalse((self.destination / "instance.lock").exists())
        self.assertFalse((self.destination / "opencode-tui").exists())
        self.assertTrue((self.source / "animation-work/old.app").exists())

    def test_copy_failure_removes_only_its_staging_directory(self):
        with patch.object(migration.shutil, "copy2", side_effect=OSError("fixture copy failure")):
            with self.assertRaises(OSError): self.copy()
        self.assertFalse(self.destination.exists())
        self.assertFalse(list(self.root.glob(".agentpet-lite-migration-*")))
        self.assertTrue((self.source / "pets/pet.png").is_file())

    def test_changed_source_refuses_publication(self):
        original = migration.shutil.copy2
        def changing_copy(*args, **kwargs):
            result = original(*args, **kwargs)
            (self.source / "pets/new.png").write_bytes(b"new")
            return result
        with patch.object(migration.shutil, "copy2", side_effect=changing_copy):
            with self.assertRaises(migration.MigrationError): self.copy()
        self.assertFalse(self.destination.exists())

    def test_test_ledger_cannot_become_formal_data(self):
        db = self.ledger()
        db.execute("UPDATE usage_meta SET value='test' WHERE key='mode'"); db.commit(); db.close()
        with self.assertRaises(migration.MigrationError): self.copy()
        self.assertFalse(self.destination.exists())


if __name__ == "__main__":
    unittest.main()
