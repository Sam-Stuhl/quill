"""Tests for stage.py: python3 -m unittest test_stage (in quill-sync/)."""

import json
import os
import tempfile
import time
import unittest
from pathlib import Path

import stage


class StageTest(unittest.TestCase):
    def setUp(self):
        stage.HOLD = 0
        self.tmp = tempfile.TemporaryDirectory()
        r = Path(self.tmp.name)
        self.src, self.stg, self.vault = r / "Notes", r / "staging", r / "vault"
        for d in (self.src, self.vault):
            d.mkdir()
        self.manifest = r / "router/manifest.json"
        self.imported = r / "imported"
        self.make = lambda: stage.Stager(self.src, self.stg, self.vault, r / "state", self.manifest,
                                         self.imported)

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, rel, data, mtime=1_700_000_000):
        p = self.src / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)
        os.utime(p, (mtime, mtime))

    def test_copies_changes_keeps_mtime_never_deletes(self):
        self.write("Fall 26/CS 114/Lec 1.pdf", b"%PDF 1")
        s = self.make()
        self.assertEqual(s.pass_once(), 1)
        out = self.stg / "Fall 26/CS 114/Lec 1.pdf"
        self.assertEqual(out.read_bytes(), b"%PDF 1")
        self.assertEqual(int(out.stat().st_mtime), 1_700_000_000)
        self.assertEqual(s.pass_once(), 0)  # unchanged: nothing copied
        self.write("Fall 26/CS 114/Lec 1.pdf", b"%PDF 1 more", 1_700_000_100)
        self.assertEqual(s.pass_once(), 1)
        self.assertEqual(out.read_bytes(), b"%PDF 1 more")
        (self.src / "Fall 26/CS 114/Lec 1.pdf").unlink()
        s.pass_once()
        self.assertTrue(out.exists())
        self.assertEqual(list(self.stg.rglob(".quill-stage-*")), [])

    def test_name_taken_in_vault_gets_quill_suffix_for_good(self):
        (self.vault / "School/CS 114").mkdir(parents=True)
        (self.vault / "School/CS 114/Lec 2.pdf").write_bytes(b"notability's")
        self.write("CS 114/Lec 2.pdf", b"%PDF quill")
        s = self.make()
        s.pass_once()
        self.assertTrue((self.stg / "CS 114/Lec 2 (Quill).pdf").exists())
        self.assertFalse((self.stg / "CS 114/Lec 2.pdf").exists())
        # A restart keeps the decision.
        self.write("CS 114/Lec 2.pdf", b"%PDF quill 2", 1_700_000_500)
        self.make().pass_once()
        self.assertEqual((self.stg / "CS 114/Lec 2 (Quill).pdf").read_bytes(), b"%PDF quill 2")

    def test_name_owned_by_quill_router_is_not_renamed(self):
        (self.vault / "x").mkdir()
        (self.vault / "x/Lec 3.pdf").write_bytes(b"ours")
        self.manifest.parent.mkdir(parents=True)
        self.manifest.write_text(json.dumps({"version": 1, "entries": {
            "CS 114/Lec 3.pdf": {"vault_path": str(self.vault / "x/Lec 3.pdf")}}}))
        self.write("CS 114/Lec 3.pdf", b"%PDF")
        self.make().pass_once()
        self.assertTrue((self.stg / "CS 114/Lec 3.pdf").exists())

    def test_hold_lets_a_note_being_written_settle(self):
        stage.HOLD = 0.3
        s = self.make()
        out = self.stg / "n.pdf"
        self.write("n.pdf", b"%PDF 1", 1_700_000_000)
        self.assertEqual(s.pass_once(), 1)  # first change: at once
        self.write("n.pdf", b"%PDF 2", 1_700_000_001)
        self.assertEqual(s.pass_once(), 0)  # held
        self.assertEqual(out.read_bytes(), b"%PDF 1")
        time.sleep(0.35)
        self.assertEqual(s.pass_once(), 1)  # newest after the hold
        self.assertEqual(out.read_bytes(), b"%PDF 2")
        # another note is not held by this one's
        self.write("m.pdf", b"%PDF m")
        self.assertEqual(s.pass_once(), 1)

    def test_imported_note_waits_until_written_in(self):
        self.imported.write_text("Fall 26/CS 114/Old lec.pdf\n")
        (self.vault / "School").mkdir()
        (self.vault / "School/Old lec.pdf").write_bytes(b"notability's")
        s = self.make()
        self.write("Fall 26/CS 114/Old lec.pdf", b"%PDF import render", 1_700_000_000)
        self.write("Fall 26/CS 114/New lec.pdf", b"%PDF new", 1_700_000_000)
        self.assertEqual(s.pass_once(), 1)  # only the new note
        self.assertEqual(self.make().pass_once(), 0)  # still held after a restart
        self.write("Fall 26/CS 114/Old lec.pdf", b"%PDF import render + ink", 1_700_000_050)
        self.assertEqual(s.pass_once(), 1)
        self.assertEqual((self.stg / "Fall 26/CS 114/Old lec (Quill).pdf").read_bytes(),
                         b"%PDF import render + ink")
        self.write("Fall 26/CS 114/Old lec.pdf", b"%PDF more ink", 1_700_000_090)
        self.assertEqual(self.make().pass_once(), 1)  # live for good


if __name__ == "__main__":
    unittest.main()
