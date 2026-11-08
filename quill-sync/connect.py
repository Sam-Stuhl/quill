"""quill-sync's links to the rest of Sam's setup (docs/quill-sync.md, "Connected").

Standard library only, like server.py.

- Courses: the current courses (Cedar's Courses collection) joined with
  ~/school/courses.json for their Canvas ids, each with its upcoming Canvas
  assignments. The app turns that into a notebook folder per course with the next
  due date on it, and `provision` drops each upcoming assignment's PDFs into the
  Inbox of that folder, once.
- Send: a page (PNG) or a finished PDF from Quill goes to ATLAS's shelf, and a PDF
  can be proposed to Canvas (`atlas-tool canvas-propose`), where Sam taps Submit.
  Nothing here submits anything.
- Text: handwriting recognition (ocr.swift, Apple's Vision) of each note's PDF,
  written to Text/<note>.md.

Credentials are read from ~/.claude/.env at the moment of use and never logged.
"""

from __future__ import annotations

import calendar
import hashlib
import json
import os
import re
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

CEDAR = "https://cedar.kosmoskit.com/api/v1"
CANVAS = "https://njit.instructure.com/api/v1"
ENV_FILE = Path(os.environ.get("QUILL_ENV_FILE", Path.home() / ".claude/.env"))
COURSES_JSON = Path(os.environ.get("QUILL_COURSES_JSON", Path.home() / "school/courses.json"))
ATLAS_PY = Path(os.environ.get("QUILL_ATLAS_PY", Path.home() / "repos/atlas/.venv/bin/python"))
SEMESTER_FOLDER = os.environ.get("QUILL_SEMESTER_FOLDER", "Fall 26")
REFRESH_EVERY = 600


def secret(name: str) -> str:
    value = os.environ.get(name, "")
    if value:
        return value
    try:
        for line in ENV_FILE.read_text().splitlines():
            if line.startswith(name + "="):
                return line.split("=", 1)[1].strip().strip("'\"")
    except OSError:
        pass
    return ""


def http_json(url: str, key_name: str, timeout: float = 30):
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {secret(key_name)}", "User-Agent": "quill-sync/1"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read())


def safe_name(name: str) -> str:
    """A file name Quill and the inbox take: no slashes, no control characters."""
    name = re.sub(r"[\\/:*?\"<>|\x00-\x1f]", " ", name)
    return re.sub(r"\s+", " ", name).strip(" .") or "file"


def folder_name(code: str) -> str:
    """Quill's folder for a course: the router's keys ("FYS", not "FYS SEM")."""
    return re.sub(r"\s+SEM$", "", code.strip())


def course_folder(code: str) -> str:
    return f"/{SEMESTER_FOLDER}/{folder_name(code)}"


# -- courses -----------------------------------------------------------------


class Courses:
    def __init__(self, root: Path, fetch=http_json):
        self.root = root
        self.fetch = fetch
        self.state = root / ".quill" / "courses-delivered.json"
        self._payload: dict | None = None
        self._at = 0.0
        self._lock = threading.Lock()

    # Cedar says which courses are current; courses.json says where each lives in Canvas.
    def current(self) -> list[dict]:
        collections = self.fetch(f"{CEDAR}/collections", "CEDAR_API_KEY")
        items = collections.get("collections", collections) if isinstance(collections, dict) else collections
        cid = next(c["id"] for c in items if c.get("slug") == "courses")
        records = self.fetch(f"{CEDAR}/records?collection={cid}&limit=200", "CEDAR_API_KEY")
        records = records.get("result", records) if isinstance(records, dict) else records
        codes = {r["props"].get("code") or r["title"]: r["id"] for r in records if not r.get("archived_at")}
        known = json.loads(COURSES_JSON.read_text())["courses"]
        out = []
        for c in known:
            if c["code"] not in codes:
                continue
            ids = c.get("canvasCourseId")
            ids = ids if isinstance(ids, list) else [ids] if ids else []
            out.append({"code": c["code"], "name": c["name"], "canvas": ids, "record": codes[c["code"]]})
        return out

    def due_dates(self, courses: list[dict]) -> dict:
        """Course record id -> its next unfinished due date in Cedar (Canvas, Wiley,
        Mastering and hand-made alike), as {name, dueAt}."""
        today = time.strftime("%Y-%m-%d", time.gmtime(time.time() - 86400))
        end = time.strftime("%Y-%m-%d", time.gmtime(time.time() + 120 * 86400))
        planner = self.fetch(f"{CEDAR}/planner?start={today}&end={end}", "CEDAR_API_KEY")
        due = {}
        for item in planner:
            o = item["occurrence"]
            if o["kind"] != "due" or o.get("completed_at") or o.get("status") not in (None, "active"):
                continue
            at = o.get("starts_at") or o.get("starts_on")
            if at:
                due.setdefault(item["record"]["id"], []).append((at, item["record"]["title"].strip()))
        out = {}
        for c in courses:
            rels = self.fetch(f"{CEDAR}/records/{c['record']}/relations", "CEDAR_API_KEY")
            ids = {r["id"] for grp in rels.values() if grp["label"] == "Coursework" for r in grp["records"]}
            mine = sorted(d for i in ids for d in due.get(i, []))
            if mine:
                out[c["record"]] = {"name": mine[0][1], "dueAt": mine[0][0]}
        return out

    def assignments(self, canvas_id: int) -> list[dict]:
        url = f"{CANVAS}/courses/{canvas_id}/assignments?per_page=100&order_by=due_at"
        out = []
        for a in self.fetch(url, "CANVAS_TOKEN"):
            if "online_upload" not in (a.get("submission_types") or []):
                continue
            out.append({
                "id": a["id"], "course": canvas_id, "name": a["name"], "dueAt": a.get("due_at"),
                "submitted": bool(a.get("has_submitted_submissions")),
                "html": a.get("description") or "",
            })
        return out

    def refresh(self) -> dict:
        now = time.time()
        courses = []
        current = self.current()
        try:
            cedar_due = self.due_dates(current)
        except (urllib.error.URLError, ValueError, OSError, KeyError):
            cedar_due = {}
        for c in current:
            upcoming = []
            for cid in c["canvas"]:
                try:
                    upcoming += self.assignments(cid)
                except (urllib.error.URLError, ValueError, OSError):
                    continue
            upcoming = [a for a in upcoming if a["dueAt"] and _ts(a["dueAt"]) > now - 86400]
            upcoming.sort(key=lambda a: a["dueAt"])
            pending = [a for a in upcoming if not a["submitted"]]
            courses.append({
                "code": c["code"], "name": c["name"], "folder": course_folder(c["code"]),
                "next": cedar_due.get(c["record"]) or (
                    {"name": pending[0]["name"], "dueAt": pending[0]["dueAt"]} if pending else None),
                "assignments": [_public(a) for a in upcoming[:12]],
                "_raw": upcoming,
            })
        payload = {"generatedAt": int(now * 1000), "courses": courses}
        with self._lock:
            self._payload, self._at = payload, now
        return payload

    def payload(self, force: bool = False) -> dict:
        with self._lock:
            fresh = self._payload is not None and time.time() - self._at < REFRESH_EVERY
            if fresh and not force:
                return self._public_payload(self._payload)
        return self._public_payload(self.refresh())

    @staticmethod
    def _public_payload(p: dict) -> dict:
        return {"generatedAt": p["generatedAt"],
                "courses": [{k: v for k, v in c.items() if k != "_raw"} for c in p["courses"]]}

    def known_assignment(self, course: str, assignment: str) -> bool:
        """Only an assignment Quill itself listed can be proposed (never a free-form id)."""
        p = self.payload()
        return any(str(a["course"]) == str(course) and str(a["id"]) == str(assignment)
                   for c in p["courses"] for a in c["assignments"])

    # -- the course's homework PDFs, delivered through the inbox once ---------

    def _delivered(self) -> dict:
        try:
            return json.loads(self.state.read_text())
        except (OSError, ValueError):
            return {}

    def provision(self) -> list[str]:
        """Put each upcoming assignment's PDFs in the course folder's Inbox. Once each:
        a file Sam moved or deleted in Quill is never put back."""
        self.payload(force=True)
        with self._lock:
            courses = self._payload["courses"]
        done = self._delivered()
        landed = []
        for c in courses:
            for a in c["_raw"]:
                for fid, display, data_url in self._pdfs(a["html"]):
                    key = f"{a['id']}:{fid}"
                    if key in done:
                        continue
                    data = self._download(data_url)
                    if not data or not data.startswith(b"%PDF"):
                        continue
                    base = safe_name(a["name"])
                    stem = base if base.lower() in display.lower() or len(self._pdfs(a["html"])) == 1 \
                        else f"{base} - {safe_name(Path(display).stem)}"
                    dest = self.root / "Inbox" / c["folder"].strip("/") / f"{stem}.pdf"
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    tmp = dest.with_name("." + dest.name + ".part")
                    tmp.write_bytes(data)
                    os.replace(tmp, dest)
                    done[key] = {"to": str(dest.relative_to(self.root)), "at": int(time.time())}
                    landed.append(str(dest.relative_to(self.root)))
        if landed:
            self.state.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.state.with_suffix(".tmp")
            tmp.write_text(json.dumps(done, indent=1))
            os.replace(tmp, self.state)
        return landed

    def _pdfs(self, html: str) -> list[tuple[str, str, str]]:
        out, seen = [], set()
        for m in re.finditer(r"/(?:api/v1/)?(?:courses/\d+/)?files/(\d+)", html):
            fid = m.group(1)
            if fid in seen:
                continue
            seen.add(fid)
            try:
                meta = self.fetch(f"{CANVAS}/files/{fid}", "CANVAS_TOKEN")
            except (urllib.error.URLError, ValueError, OSError):
                continue
            if meta.get("content-type") == "application/pdf" or str(meta.get("display_name", "")).lower().endswith(".pdf"):
                out.append((fid, meta.get("display_name", fid), meta.get("url", "")))
        return out

    def _download(self, url: str) -> bytes | None:
        if not url:
            return None
        try:
            with urllib.request.urlopen(url, timeout=60) as resp:  # pre-signed, no token
                return resp.read()
        except (urllib.error.URLError, OSError):
            return None


def _ts(iso: str) -> float:
    return calendar.timegm(time.strptime(iso, "%Y-%m-%dT%H:%M:%SZ"))


def _public(a: dict) -> dict:
    return {k: a[k] for k in ("id", "course", "name", "dueAt", "submitted")}


# -- send to ATLAS and Canvas -----------------------------------------------------


class Sender:
    def __init__(self, root: Path, courses: Courses, run=subprocess.run):
        self.root = root
        self.courses = courses
        self.run = run

    def save(self, note: str, kind: str, data: bytes) -> Path:
        """Keep what was sent under Sent/<time>/, named for the note."""
        ext = "png" if kind == "page" else "pdf"
        magic = b"\x89PNG" if ext == "png" else b"%PDF"
        if not data.startswith(magic):
            raise ValueError(f"not a {ext}")
        stem = safe_name(Path(note).name) or "note"
        d = self.root / "Sent" / time.strftime("%Y-%m-%dT%H-%M-%S")
        d.mkdir(parents=True, exist_ok=True)
        out = d / f"{stem}.{ext}"
        out.write_bytes(data)
        return out

    def _atlas(self, *args: str) -> str:
        res = self.run([str(ATLAS_PY), "-m", "atlas.tool", *args], capture_output=True, text=True,
                       timeout=120, env={"HOME": str(Path.home()), "PATH": "/usr/bin:/bin"})
        if res.returncode != 0:
            raise RuntimeError((res.stderr or res.stdout).strip()[:300] or "atlas-tool failed")
        return res.stdout.strip()

    def to_atlas(self, note: str, kind: str, data: bytes) -> dict:
        path = self.save(note, kind, data)
        said = self._atlas("shelf", "add", str(path), "--project", "Quill", "--agent", "quill",
                           "--title", path.stem)
        return {"ok": True, "said": said or "on the ATLAS shelf", "path": str(path)}

    def to_canvas(self, note: str, course: str, assignment: str, data: bytes) -> dict:
        if not self.courses.known_assignment(course, assignment):
            raise ValueError("not an assignment of a current course")
        path = self.save(note, "pdf", data)
        said = self._atlas("canvas-propose", str(course), str(assignment), str(path))
        return {"ok": True, "said": said, "path": str(path)}


# -- handwriting to text -----------------------------------------------------------


class Ocr:
    """Recognises a note's handwriting after it has been quiet for a while.

    Recognition costs real CPU on the mini (Intel, Vision on the CPU), so a note is
    read once its PDF has not changed for `quiet` seconds, never while Sam writes,
    and only when the PDF differs from the last one read (sha256)."""

    def __init__(self, root: Path, quiet: float = 45.0, recognise=None):
        self.root = root
        self.quiet = quiet
        self.recognise = recognise or self._swift
        self.pending: dict[str, float] = {}
        self.cv = threading.Condition()
        self.stopped = False
        self.state_file = root / ".quill" / "ocr.json"
        try:
            self.seen = json.loads(self.state_file.read_text())
        except (OSError, ValueError):
            self.seen = {}

    def text_path(self, note: str) -> Path:
        return self.root / "Text" / (note.strip("/") + ".md")

    def touch(self, note: str):
        with self.cv:
            self.pending[note] = time.time()
            self.cv.notify()

    def backfill(self):
        """Queue every note with a PDF but no text yet (quiet, oldest first)."""
        notes = self.root / "Notes"
        for pdf in sorted(notes.rglob("*.pdf"), key=lambda p: p.stat().st_mtime):
            note = "/" + pdf.relative_to(notes).with_suffix("").as_posix()
            if note not in self.seen:
                with self.cv:
                    self.pending.setdefault(note, 0.0)

    def run(self):
        while not self.stopped:
            note = None
            with self.cv:
                now = time.time()
                ready = [n for n, t in self.pending.items() if now - t >= self.quiet]
                if ready:
                    note = min(ready, key=lambda n: self.pending[n])
                    del self.pending[note]
                else:
                    due = min((t + self.quiet - now for t in self.pending.values()), default=2.0)
                    self.cv.wait(timeout=max(0.05, min(2.0, due)))
            if note:
                try:
                    self.read(note)
                except Exception as e:  # one bad PDF must not stop the rest
                    self.log("ocr-failed", note=note, error=repr(e)[:200])

    def stop(self):
        self.stopped = True
        with self.cv:
            self.cv.notify_all()

    def log(self, ev: str, **fields):
        print(json.dumps({"t": time.strftime("%Y-%m-%dT%H:%M:%S"), "ev": ev, **fields}), flush=True)

    def read(self, note: str) -> bool:
        pdf = self.root / "Notes" / (note.strip("/") + ".pdf")
        try:
            sha = hashlib.sha256(pdf.read_bytes()).hexdigest()
        except OSError:
            return False
        if self.seen.get(note) == sha:
            return False
        pages = self.recognise(pdf)
        out = self.text_path(note)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(render_markdown(note, pages), encoding="utf-8")
        self.seen[note] = sha
        self.state_file.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.state_file.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.seen))
        os.replace(tmp, self.state_file)
        self.log("ocr", note=note, pages=len(pages), chars=sum(len(p) for p in pages))
        return True

    @staticmethod
    def binary() -> Path:
        """ocr.swift compiled once (the interpreter would compile it on every note)."""
        src = Path(__file__).with_name("ocr.swift")
        out = Path.home() / ".cache/quill-sync/ocr"
        if not out.exists() or out.stat().st_mtime < src.stat().st_mtime:
            out.parent.mkdir(parents=True, exist_ok=True)
            res = subprocess.run(["/usr/bin/swiftc", "-O", str(src), "-o", str(out)],
                                 capture_output=True, text=True, timeout=600)
            if res.returncode != 0:
                raise RuntimeError("swiftc: " + res.stderr.strip()[:300])
        return out

    @staticmethod
    def _swift(pdf: Path) -> list[str]:
        res = subprocess.run(["/usr/bin/nice", "-n", "19", str(Ocr.binary()), str(pdf)], capture_output=True,
                             text=True, timeout=900)
        if res.returncode != 0:
            raise RuntimeError(res.stderr.strip()[:300])
        return json.loads(res.stdout)


def render_markdown(note: str, pages: list[str]) -> str:
    title = Path(note).name
    body = []
    for i, text in enumerate(pages, 1):
        text = text.strip()
        if text:
            body.append(f"## Page {i}\n\n{text}\n")
    head = (f"---\nsource: quill-handwriting\nnote: \"{note}\"\npages: {len(pages)}\n"
            f"recognised: {time.strftime('%Y-%m-%d')}\n---\n\n# {title}, handwriting\n\n")
    return head + ("\n".join(body) if body else "_No text recognised._\n")
