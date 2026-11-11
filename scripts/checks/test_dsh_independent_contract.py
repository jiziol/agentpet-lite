#!/usr/bin/env python3
"""Application export safety and independent bridge contract boundaries."""
import importlib.util
from pathlib import Path
import unittest
import subprocess
import tempfile
import json
import zipfile
import shutil

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("source_exporter", root / "prepare-source.py")
exporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(exporter)


class IndependentContractTests(unittest.TestCase):
    def test_consumer_exports_contract_and_tests_without_adapter_or_its_packager(self):
        self.assertTrue(exporter.allowed("docs/dsh-bridge-protocol.md"))
        self.assertTrue(exporter.allowed("Tests/Fixtures/dsh-bridge-v1.json"))
        for name in ["integrations/dsh-agentpet-bridge/package.json", "integrations/dsh-agentpet-bridge/lib/index.js",
                     "integrations/dsh-agentpet-bridge/README.md", "scripts/package-dsh-bridge.py"]:
            self.assertFalse(exporter.allowed(name), name)


class ExporterSafetyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name); self.repo = self.root/'repo'; self.repo.mkdir()
        for name in exporter.ROOT_FILES | {'docs/'+name for name in exporter.PUBLIC_DOCS}:
            p = self.repo/name; p.parent.mkdir(exist_ok=True); p.write_text('fixture\n')
        subprocess.run(['git','init','-q',str(self.repo)],check=True)
        self.git('add','.'); self.git('-c','user.name=Test','-c','user.email=test@example.invalid','commit','-qm','fixture')
    def git(self,*args):
        return subprocess.check_output(['git',*args],cwd=self.repo)
    def test_tracked_only_preserves_but_excludes_diagnostic(self):
        p=self.repo/'Tests/Diagnostic.swift'; p.parent.mkdir(); p.write_text('diagnostic')
        (self.repo/'README.md').write_text('reviewed working-tree edit')
        before=self.git('ls-files','--stage')
        exporter.export(self.repo,self.root/'snapshot',True)
        manifest=json.loads((self.root/'snapshot/source-manifest.json').read_text())
        self.assertEqual(manifest['excluded']['Tests/Diagnostic.swift'],'untracked; excluded by --tracked-only')
        self.assertTrue(p.exists()); self.assertEqual(before,self.git('ls-files','--stage'))
        with zipfile.ZipFile(self.root/'snapshot/agentpet-lite-source-review.zip') as z:
            self.assertEqual(z.read('agentpet-lite/README.md'),b'reviewed working-tree edit')
            self.assertFalse(any('/.git/' in n or n.endswith('Diagnostic.swift') for n in z.namelist()))
            z.extractall(self.root/'extracted')
        exporter.check_tree(self.root/'extracted/agentpet-lite')
    def test_required_guide_missing_is_rejected(self):
        (self.repo/'docs/architecture.md').unlink()
        with self.assertRaises(ValueError): exporter.export(self.repo,self.root/'snapshot',True)
        self.assertFalse((self.root/'snapshot').exists())
    def test_symlink_and_outside_output_rejected(self):
        p=self.repo/'Sources/link'; p.parent.mkdir(); p.symlink_to(self.root/'outside')
        self.git('add','Sources/link')
        with self.assertRaises(ValueError): exporter.export(self.repo,self.root/'snapshot',True)
        with self.assertRaises(ValueError): exporter.export(self.repo,self.repo/'output',True)
    def test_secret_pattern_fails_without_creating_snapshot(self):
        (self.repo/'README.md').write_text('ghp_'+'A'*40)
        with self.assertRaises(ValueError): exporter.export(self.repo,self.root/'snapshot',True)
        self.assertFalse((self.root/'snapshot').exists())
    def test_tree_rejects_private_file_and_ignores_generated_output(self):
        shutil.rmtree(self.repo/'.git')
        build=self.repo/'build'; build.mkdir(); (build/'ignored.log').write_text('build')
        exporter.check_tree(self.repo)
        (self.repo/'AGENTS.md').write_text('private')
        with self.assertRaises(ValueError): exporter.check_tree(self.repo)


if __name__ == "__main__":
    unittest.main(verbosity=2)
