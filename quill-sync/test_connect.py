"""Tests for connect.py and its routes: python3 -m unittest test_connect (in quill-sync/)."""

import json
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path

import connect
import server

PDF = b"%PDF-1.4\n%test\n"
PNG = b"\x89PNG\r\n\x1a\nxx"
SOON = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + 3 * 86400))
LATER = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + 9 * 86400))
LONG_AGO = "2020-01-01T00:00:00Z"


def fake_fetch(url, key):
    if url.endswith("/collections"):
        return {"collections": [{"id": "cid", "slug": "courses"}, {"id": "x", "slug": "tasks"}]}
    if "/records?collection=cid" in url:
        return {"result": [
            {"id": "r-cs", "title": "CS 114", "props": {"code": "CS 114"}, "archived_at": None},
            {"id": "r-fys", "title": "FYS SEM", "props": {"code": "FYS SEM"}, "archived_at": None},
            {"id": "r-old", "title": "OLD 101", "props": {"code": "OLD 101"}, "archived_at": "2026-01-01"},
        ]}
    if "/planner?" in url:
        def occ(rid, title, at, kind="due", done=None):
            return {"occurrence": {"kind": kind, "starts_at": at, "completed_at": done, "status": "active"},
                    "record": {"id": rid, "title": title}}
        return [occ("w1", "Mastering Ch 5 ", LATER), occ("w2", "Wiley 3", SOON), occ("w3", "Done one", SOON, done="x"),
                occ("w4", "A test", SOON, kind="event"), occ("w5", "Other course", SOON)]
    if url.endswith("/records/r-cs/relations"):
        return {"g": {"label": "Coursework", "records": [{"id": "w1"}, {"id": "w2"}, {"id": "w3"}, {"id": "w4"}]},
                "s": {"label": "Semester", "records": [{"id": "w5"}]}}
    if url.endswith("/records/r-fys/relations"):
        return {}
    if "/courses/1/assignments" in url:
        return [
            {"id": 11, "name": "Homework 10", "due_at": LATER, "submission_types": ["online_upload"],
             "has_submitted_submissions": False,
             "description": '<a href="https://njit.instructure.com/courses/1/files/501?wrap=1">hw</a>'},
            {"id": 10, "name": "Homework 9", "due_at": SOON, "submission_types": ["online_upload"],
             "has_submitted_submissions": True, "description": ""},
            {"id": 9, "name": "Homework 8", "due_at": LONG_AGO, "submission_types": ["online_upload"],
             "has_submitted_submissions": False, "description": ""},
            {"id": 8, "name": "Quiz", "due_at": SOON, "submission_types": ["online_quiz"],
             "has_submitted_submissions": False, "description": ""},
        ]
    if "/courses/2/assignments" in url:
        return [{"id": 21, "name": "Project", "due_at": SOON, "submission_types": ["online_upload"],
                 "has_submitted_submissions": False, "description": ""}]
    if url.endswith("/files/501"):
        return {"display_name": "Homework10.pdf", "content-type": "application/pdf", "url": "file-501"}
    raise AssertionError(url)


class Fixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        cj = self.root / "courses.json"
        cj.write_text(json.dumps({"courses": [
            {"code": "CS 114", "name": "CS II", "canvasCourseId": 1},
            {"code": "FYS SEM", "name": "Seminar", "canvasCourseId": [2]},
            {"code": "OLD 101", "name": "Old", "canvasCourseId": 3},
            {"code": "NOCANVAS 1", "name": "None"},
        ]}))
        connect.COURSES_JSON = cj
        self.courses = connect.Courses(self.root, fetch=fake_fetch)
        self.courses._download = lambda url: PDF + url.encode()

    def tearDown(self):
        self.tmp.cleanup()


class CoursesTest(Fixture):
    def test_current_courses_with_next_due(self):
        p = self.courses.payload()
        by = {c["code"]: c for c in p["courses"]}
        self.assertEqual(set(by), {"CS 114", "FYS SEM"})  # archived and no-Canvas ones left out
        self.assertEqual(by["CS 114"]["folder"], "/Fall 26/CS 114")
        self.assertEqual(by["FYS SEM"]["folder"], "/Fall 26/FYS")
        # Homework 9 is submitted, Homework 8 is long past, the quiz takes no file
        # next due comes from Cedar (finished and non-due items skipped), not only Canvas
        self.assertEqual(by["CS 114"]["next"], {"name": "Wiley 3", "dueAt": SOON})
        self.assertEqual(by["FYS SEM"]["next"]["name"], "Project")  # Cedar has none: Canvas's
        self.assertEqual([a["name"] for a in by["CS 114"]["assignments"]], ["Homework 9", "Homework 10"])
        self.assertNotIn("html", json.dumps(p))
        self.assertNotIn("_raw", json.dumps(p))

    def test_provision_once(self):
        landed = self.courses.provision()
        self.assertEqual(landed, ["Inbox/Fall 26/CS 114/Homework 10.pdf"])
        dest = self.root / landed[0]
        self.assertTrue(dest.read_bytes().startswith(b"%PDF"))
        dest.unlink()  # Sam deleted it or the inbox took it
        self.assertEqual(self.courses.provision(), [])  # never put back
        self.assertFalse(dest.exists())

    def test_only_listed_assignments_can_be_proposed(self):
        self.assertTrue(self.courses.known_assignment("1", "11"))
        self.assertFalse(self.courses.known_assignment("1", "999"))
        self.assertFalse(self.courses.known_assignment("2", "11"))


class SenderTest(Fixture):
    def setUp(self):
        super().setUp()
        self.calls = []

        class Done:
            returncode, stdout, stderr = 0, "shown", ""

        def run(cmd, **kw):
            self.calls.append(cmd)
            return Done()

        self.sender = connect.Sender(self.root, self.courses, run=run)

    def test_page_and_pdf_go_to_the_shelf(self):
        r = self.sender.to_atlas("/Fall 26/CS 114/Lec 3", "page", PNG)
        self.assertTrue(Path(r["path"]).read_bytes().startswith(b"\x89PNG"))
        self.assertTrue(r["path"].endswith("Lec 3.png"))
        self.assertEqual(self.calls[-1][3:6], ["shelf", "add", r["path"]])
        r = self.sender.to_atlas("/Lec 3", "pdf", PDF)
        self.assertTrue(r["path"].endswith(".pdf"))

    def test_wrong_bytes_are_refused(self):
        with self.assertRaises(ValueError):
            self.sender.to_atlas("/x", "pdf", PNG)
        with self.assertRaises(ValueError):
            self.sender.to_atlas("/x", "page", PDF)
        self.assertEqual(self.calls, [])

    def test_canvas_proposes_only_known_assignments(self):
        r = self.sender.to_canvas("/Fall 26/CS 114/HW 10", "1", "11", PDF)
        self.assertEqual(self.calls[-1][-4:-1], ["canvas-propose", "1", "11"])
        self.assertEqual(self.calls[-1][-1], r["path"])
        n = len(self.calls)
        with self.assertRaises(ValueError):
            self.sender.to_canvas("/x", "1", "999", PDF)
        self.assertEqual(len(self.calls), n)  # nothing proposed

    def test_atlas_failure_is_an_error(self):
        class Bad:
            returncode, stdout, stderr = 1, "", "atlas-tool: hub said 400: nope"

        s = connect.Sender(self.root, self.courses, run=lambda *a, **k: Bad())
        with self.assertRaises(RuntimeError):
            s.to_atlas("/x", "pdf", PDF)


class OcrTest(Fixture):
    def test_reads_once_per_pdf_and_writes_markdown(self):
        pdf = self.root / "Notes/Fall 26/CS 114/Lec 3.pdf"
        pdf.parent.mkdir(parents=True)
        pdf.write_bytes(PDF)
        reads = []
        ocr = connect.Ocr(self.root, quiet=0, recognise=lambda p: reads.append(p) or ["hello\nworld", "", "two"])
        self.assertTrue(ocr.read("/Fall 26/CS 114/Lec 3"))
        text = (self.root / "Text/Fall 26/CS 114/Lec 3.md").read_text()
        self.assertIn("source: quill-handwriting", text)
        self.assertIn("## Page 1\n\nhello\nworld", text)
        self.assertIn("## Page 3\n\ntwo", text)
        self.assertNotIn("## Page 2", text)
        self.assertFalse(ocr.read("/Fall 26/CS 114/Lec 3"))  # same PDF: not read again
        pdf.chmod(0o644)
        pdf.write_bytes(PDF + b"more")
        self.assertTrue(ocr.read("/Fall 26/CS 114/Lec 3"))
        self.assertEqual(len(reads), 2)
        self.assertEqual(connect.Ocr(self.root).seen, ocr.seen)  # survives a restart

    def test_waits_for_a_quiet_note(self):
        pdf = self.root / "Notes/a.pdf"
        pdf.parent.mkdir(parents=True)
        pdf.write_bytes(PDF)
        reads = []
        ocr = connect.Ocr(self.root, quiet=0.4, recognise=lambda p: reads.append(p) or ["x"])
        threading.Thread(target=ocr.run, daemon=True).start()
        ocr.touch("/a")
        time.sleep(0.15)
        ocr.touch("/a")  # still being written: the clock restarts
        time.sleep(0.3)
        self.assertEqual(reads, [])
        time.sleep(0.6)
        self.assertEqual(len(reads), 1)
        ocr.stop()


class RoutesTest(Fixture):
    def setUp(self):
        super().setUp()
        self.sent = []
        link = self.link = server.Link.__new__(server.Link)
        link.courses = self.courses

        class Done:
            returncode, stdout, stderr = 0, "ok", ""

        link.sender = connect.Sender(self.root, self.courses, run=lambda c, **k: self.sent.append(c) or Done())
        link.ocr = connect.Ocr(self.root, quiet=0, recognise=lambda p: ["t"])
        self.httpd, self.inbox = server.serve("127.0.0.1", 0, self.root, "tok", link=link)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def tearDown(self):
        self.inbox.stop()
        self.httpd.shutdown()
        self.httpd.server_close()
        super().tearDown()

    def req(self, method, path, body=None, token="tok"):
        r = urllib.request.Request(f"http://127.0.0.1:{self.port}{path}", data=body, method=method)
        if token:
            r.add_header("Authorization", f"Bearer {token}")
        try:
            with urllib.request.urlopen(r, timeout=10) as resp:
                return resp.status, json.loads(resp.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read() or b"{}")

    def test_courses_route(self):
        code, body = self.req("GET", "/v1/courses")
        self.assertEqual(code, 200)
        self.assertEqual(body["courses"][0]["next"]["name"], "Wiley 3")
        self.assertEqual(self.req("GET", "/v1/courses", token=None)[0], 401)

    def test_send_and_canvas_routes(self):
        code, body = self.req("POST", "/v1/send?note=%2FLec&kind=pdf", PDF)
        self.assertEqual(code, 200, body)
        code, body = self.req("POST", "/v1/canvas?note=%2FHW&course=1&assignment=11", PDF)
        self.assertEqual(code, 200, body)
        self.assertIn("canvas-propose", self.sent[-1])
        self.assertEqual(self.req("POST", "/v1/canvas?note=%2FHW&course=1&assignment=5", PDF)[0], 400)
        self.assertEqual(self.req("POST", "/v1/send?note=x&kind=pdf", PDF, token="bad")[0], 401)
        self.assertEqual(self.req("POST", "/v1/send?note=x&kind=pdf", b"junk")[0], 400)

    def test_pdf_upload_queues_ocr(self):
        code, _ = self.req("PUT", "/v1/pdf?path=%2FLec%201", PDF)
        self.assertEqual(code, 200)
        self.assertIn("/Lec 1", self.link.ocr.pending)


if __name__ == "__main__":
    unittest.main()
