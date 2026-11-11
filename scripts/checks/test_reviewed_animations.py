#!/usr/bin/env python3
"""Importer boundary tests with disposable fixtures, no user media or preferences."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("importer", Path(__file__).resolve().parents[1] / "import-reviewed-animations.py")
importer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(importer)


class ReviewedAnimationsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.source, self.review, self.output = root / "source", root / "review", root / "output"
        self.source.mkdir(); self.review.mkdir()
        (self.source / "pet.json").write_text("original")
        self.clips = []
        for number in range(1, 11):
            name = "clip" + str(number)
            content = name.encode()
            (self.source / (name + ".mov")).write_bytes(content)
            (self.source / (name + ".png")).write_bytes(b"poster")
            self.clips.append(dict(id=name, name=name, file=name + ".mov", poster=name + ".png", sha256=hashlib.sha256(content).hexdigest()))
            if number <= 9:
                folder = self.review / (f"{number:02d}-review")
                folder.mkdir(); (folder / (name + ".mov")).write_bytes(content)
        season = self.review / "season"; season.mkdir()
        (season / "clip10.mov").write_bytes(b"clip10")
        self.write_catalog()
        self.before = self.snapshot(self.source), self.snapshot(self.review)

    def write_catalog(self):
        (self.source / "animations.json").write_text(json.dumps(dict(version=1, clips=self.clips)))

    def snapshot(self, root):
        return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in root.rglob("*") if p.is_file()}

    def build(self):
        return importer.build(self.review, self.source, self.output)

    def test_selected_only_and_read_only_inputs(self):
        result = self.build()
        self.assertEqual(result["clips"], 9)
        self.assertEqual(set(result["groups"]), set(importer.GROUPS))
        self.assertFalse((self.output / "clip10.mov").exists())
        self.assertEqual((self.output / "pet.json").read_text(), "original")
        self.assertEqual((self.snapshot(self.source), self.snapshot(self.review)), self.before)
        entries = json.loads((self.output / "animations.json").read_text())["clips"]
        self.assertEqual([e["purposes"] for e in entries], [[key] for key in importer.GROUPS])

    def test_changed_or_unknown_movie_fails_before_output(self):
        movie = self.review / "01-review/clip1.mov"
        movie.write_bytes(b"changed")
        with self.assertRaises(ValueError): self.build()
        self.assertFalse(self.output.exists())
        movie.unlink(); (movie.parent / "new.mov").write_bytes(b"new")
        with self.assertRaises(ValueError): self.build()
        self.assertFalse(self.output.exists())

    def test_empty_group_and_duplicate_source_rejected(self):
        (self.review / "01-review/clip1.mov").unlink()
        with self.assertRaises(ValueError): self.build()
        self.clips.append(self.clips[0]); self.write_catalog()
        with self.assertRaises(ValueError): self.build()
        self.assertFalse(self.output.exists())

    def test_escape_and_live_output_rejected(self):
        self.clips[-1]["file"] = "../outside.mov"; self.write_catalog()
        with self.assertRaises(ValueError): self.build()
        self.assertFalse(self.output.exists())
        with self.assertRaises(ValueError): importer.build(self.review, self.source, self.source / "child")
        self.output.mkdir(); (self.output / "keep").write_text("keep")
        with self.assertRaises(ValueError): self.build()
        self.assertEqual((self.output / "keep").read_text(), "keep")


if __name__ == "__main__":
    unittest.main()
