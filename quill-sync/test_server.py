"""Tests for quill-sync's server: python3 -m unittest test_server (in quill-sync/)."""

import json
import os
import stat
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import quote

import server

TOKEN = "test-token"
PDF = b"%PDF-1.4\n%test\n"


class ServerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        server.SCAN_INTERVAL = 0.05
        server.STABLE_FOR = 0.2
        self.httpd, self.inbox = server.serve("127.0.0.1", 0, self.root, TOKEN,
                                              viewers=frozenset({"sam@example.com"}))
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def tearDown(self):
        self.inbox.stop()
        self.httpd.shutdown()
        self.httpd.server_close()
        self.tmp.cleanup()

    def req(self, method, path, body=None, token=TOKEN, headers=None):
        r = urllib.request.Request(f"http://127.0.0.1:{self.port}{path}", data=body, method=method)
        if token:
            r.add_header("Authorization", f"Bearer {token}")
        for k, v in (headers or {}).items():
            r.add_header(k, v)
        try:
            with urllib.request.urlopen(r, timeout=10) as resp:
                data = resp.read()
                ctype = resp.headers.get("Content-Type")
                return resp.status, json.loads(data) if ctype == "application/json" else data
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read() or b"{}")

    def put(self, rel, data, mtime=None, kind="file"):
        h = {"X-Mtime": str(mtime)} if mtime else {}
        return self.req("PUT", f"/v1/{kind}?path={quote(rel)}", data, headers=h)

    # 1
    def test_upload_lands_at_mirrored_path(self):
        self.assertEqual(self.put("/School/CS 114/lec 1.sbn2", b"bson", 1700000000000)[0], 200)
        self.assertEqual(self.put("/School/CS 114/lec 1.sbn2.0", b"asset")[0], 200)
        self.assertEqual(self.put("/School/CS 114/lec 1", PDF, kind="pdf")[0], 200)
        f = self.root / ".quill/store/School/CS 114/lec 1.sbn2"
        self.assertEqual(f.read_bytes(), b"bson")
        self.assertEqual(f.stat().st_mtime_ns // 1_000_000, 1700000000000)
        pdf = self.root / "Notes/School/CS 114/lec 1.pdf"
        self.assertEqual(pdf.read_bytes(), PDF)
        self.assertEqual(stat.S_IMODE(pdf.stat().st_mode), 0o444)
        leftovers = [p for p in self.root.rglob(".*.tmp")]
        self.assertEqual(leftovers, [])

    # 2
    def test_repeated_uploads_keep_newest(self):
        for i in range(5):
            self.put("/a", PDF + str(i).encode(), kind="pdf")
        self.assertEqual((self.root / "Notes/a.pdf").read_bytes(), PDF + b"4")

    def test_rejects_non_note_and_non_pdf(self):
        self.assertEqual(self.put("/a.txt", b"x")[0], 400)
        self.assertEqual(self.put("/a", b"not pdf", kind="pdf")[0], 400)

    # 3
    def test_delete_moves_to_trash(self):
        self.put("/n.sbn2", b"bson")
        self.put("/n.sbn2.0", b"asset")
        self.put("/n", PDF, kind="pdf")
        self.assertEqual(self.req("DELETE", "/v1/file?path=/n.sbn2")[0], 200)
        self.assertEqual(self.req("DELETE", "/v1/file?path=/n.sbn2.0")[0], 200)
        self.assertFalse((self.root / "Notes/n.pdf").exists())
        self.assertFalse((self.root / ".quill/store/n.sbn2").exists())
        trashed = sorted(p.name for p in (self.root / ".quill/trash").rglob("*") if p.is_file())
        self.assertEqual(trashed, ["n.pdf", "n.sbn2", "n.sbn2.0"])
        # deleting again is harmless
        self.assertEqual(self.req("DELETE", "/v1/file?path=/n.sbn2")[1]["moved"], False)

    # 4
    def test_path_traversal_refused(self):
        for bad in ["../x.sbn2", "/../x.sbn2", "/a/../../x.sbn2", "/.quill/x.sbn2", "x.sbn2", "/a//b.sbn2"]:
            self.assertEqual(self.put(bad, b"x")[0], 400, bad)
        self.assertEqual(self.put("/../../etc", PDF, kind="pdf")[0], 400)
        self.assertFalse((self.root.parent / "x.sbn2").exists())

    # 5
    def test_token_required(self):
        self.assertEqual(self.req("GET", "/v1/manifest", token=None)[0], 401)
        self.assertEqual(self.req("GET", "/v1/manifest", token="wrong")[0], 401)
        self.assertEqual(self.req("PUT", "/v1/file?path=/a.sbn2", b"x", token="wrong")[0], 401)
        self.assertEqual(self.req("GET", "/v1/health", token=None)[0], 200)

    # 6
    def test_inbox_offer_wake_and_ack(self):
        status, body = self.req("GET", "/v1/inbox?wait=0")
        self.assertEqual(body["items"], [])
        version = body["version"]

        def drop():
            time.sleep(0.3)
            (self.root / "Inbox/School").mkdir(parents=True)
            (self.root / "Inbox/School/hw 3.pdf").write_bytes(PDF)
            (self.root / "Inbox/notes.txt").write_text("nope")

        threading.Thread(target=drop).start()
        t0 = time.monotonic()
        _, body = self.req("GET", f"/v1/inbox?wait=10&since={version}")
        woke = time.monotonic() - t0
        self.assertLess(woke, 1.5)
        self.assertEqual(len(body["items"]), 1)
        item = body["items"][0]
        self.assertEqual((item["folder"], item["name"], item["ext"]), ("/School/", "hw 3.pdf", ".pdf"))

        status, data = self.req("GET", f"/v1/inbox/{item['id']}")
        self.assertEqual((status, data), (200, PDF))

        _, res = self.req("POST", f"/v1/inbox/{item['id']}/ack", json.dumps({"note": "/School/hw 3"}).encode())
        self.assertEqual(res["delivered"]["note"], "/School/hw 3")
        self.assertFalse((self.root / "Inbox/School").exists())
        delivered = [p.name for p in (self.root / ".quill/delivered").rglob("*.pdf")]
        self.assertEqual(delivered, ["hw 3.pdf"])
        # second ack is harmless
        self.assertEqual(self.req("POST", f"/v1/inbox/{item['id']}/ack", b"{}")[0], 200)
        # the unsupported file stays and is never offered
        _, body = self.req("GET", "/v1/inbox?wait=0")
        self.assertEqual(body["items"], [])
        self.assertTrue((self.root / "Inbox/notes.txt").exists())

    def test_inbox_waits_for_stable_size(self):
        f = self.root / "Inbox/big.pdf"
        with open(f, "wb") as fh:
            fh.write(PDF)
            fh.flush()
            for _ in range(4):
                time.sleep(0.06)
                fh.write(b"x" * 1000)
                fh.flush()
                _, body = self.req("GET", "/v1/inbox?wait=0")
                for it in body["items"]:
                    self.assertEqual(it["size"], f.stat().st_size)
        time.sleep(0.3)
        _, body = self.req("GET", "/v1/inbox?wait=1")
        self.assertEqual(body["items"][0]["size"], len(PDF) + 4000)

    def test_inbox_offers_old_files_at_once(self):
        f = self.root / "Inbox/moved.pdf"
        f.write_bytes(PDF)
        os.utime(f, (time.time() - 60, time.time() - 60))
        _, body = self.req("GET", "/v1/inbox?wait=0")
        version = body["version"]
        t0 = time.monotonic()
        _, body = self.req("GET", f"/v1/inbox?wait=5&since={version}" if not body["items"] else "/v1/inbox?wait=0")
        self.assertEqual([i["name"] for i in body["items"]], ["moved.pdf"])
        self.assertLess(time.monotonic() - t0, 0.2 + server.STABLE_FOR / 2)

    # 7
    def test_manifest(self):
        self.put("/x/y.sbn2", b"abc", 1700000000123)
        self.put("/x/y", PDF, 1700000000123, kind="pdf")
        _, m = self.req("GET", "/v1/manifest")
        self.assertEqual(m["files"], {"/x/y.sbn2": {"size": 3, "mtime": 1700000000123}})
        self.assertEqual(m["pdfs"], {"/x/y": 1700000000123})

    # 8: live view
    def test_live_view_viewer_auth_is_read_only(self):
        self.put("/School/n", PDF, 1700000000000, kind="pdf")
        me = {"Tailscale-User-Login": "sam@example.com"}
        status, page = self.req("GET", "/live", token=None, headers=me)
        self.assertEqual(status, 200)
        self.assertIn(b"Quill live", page)
        _, body = self.req("GET", "/v1/notes", token=None, headers=me)
        self.assertEqual(body["notes"], [{"path": "/School/n", "mtime": 1700000000000}])
        status, data = self.req("GET", "/v1/pdf?path=/School/n", token=None, headers=me)
        self.assertEqual((status, data), (200, PDF))
        # an unlisted login, or no login, gets nothing
        self.assertEqual(self.req("GET", "/v1/notes", token=None,
                                  headers={"Tailscale-User-Login": "eve@example.com"})[0], 401)
        self.assertEqual(self.req("GET", "/live", token=None)[0], 401)
        # and a viewer can never write or read the native store
        self.assertEqual(self.req("PUT", "/v1/pdf?path=/x", PDF, token=None, headers=me)[0], 401)
        self.assertEqual(self.req("GET", "/v1/manifest", token=None, headers=me)[0], 401)
        self.assertEqual(self.req("GET", "/v1/pdf?path=/missing")[0], 404)
        self.assertEqual(self.req("GET", "/v1/pdf?path=/../etc")[0], 400)

    def test_live_changes_wake_on_pdf_and_delete(self):
        _, body = self.req("GET", "/v1/changes")
        seq = body["seq"]
        threading.Timer(0.3, lambda: self.put("/a", PDF, 1700000000000, kind="pdf")).start()
        t0 = time.monotonic()
        _, body = self.req("GET", f"/v1/changes?since={seq}&wait=10")
        self.assertLess(time.monotonic() - t0, 2)
        self.assertEqual(body["changed"], {"/a": 1700000000000})
        seq = body["seq"]
        self.put("/a.sbn2", b"bson")
        self.req("DELETE", "/v1/file?path=/a.sbn2")
        _, body = self.req("GET", f"/v1/changes?since={seq}&wait=1")
        self.assertEqual(body["changed"], {"/a": None})
        # nothing new: returns empty after the wait
        _, body = self.req("GET", f"/v1/changes?since={body['seq']}&wait=0.2")
        self.assertEqual(body["changed"], {})


class PutCommandTest(unittest.TestCase):
    def test_put_copies_into_inbox(self):
        with tempfile.TemporaryDirectory() as d:
            os.environ["QUILL_ROOT"] = d
            src = Path(d) / "src.pdf"
            src.write_bytes(PDF)

            class A:
                file = str(src)
                to = "School/CS 114"
                wait = False
                timeout = 1

            server.cmd_put(A)
            self.assertEqual((Path(d) / "Inbox/School/CS 114/src.pdf").read_bytes(), PDF)
            del os.environ["QUILL_ROOT"]


if __name__ == "__main__":
    unittest.main()
