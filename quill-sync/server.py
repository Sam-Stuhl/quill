#!/usr/bin/env python3
"""quill-sync: the mini's side of Quill sync (docs/quill-sync.md).

Standard library only. Serves on loopback; `tailscale serve --https=8796`
publishes it to the tailnet over HTTPS.

    server.py serve [--host 127.0.0.1] [--port 8796]
    server.py put FILE [--to FOLDER] [--wait]
    server.py status
    server.py delete NOTE...   (asks Quill to delete notes, e.g. "/School/hw (2)")

Root: $QUILL_ROOT or ~/quill. Token: $QUILL_TOKEN_FILE or
~/.config/quill-sync/token (created on first serve, mode 600, never printed).

Live view: /live shows each note's PDF and redraws it the moment a new one
arrives. Besides the token, it lets in tailnet users named in
~/.config/quill-sync/viewers (one Tailscale login per line), which `tailscale
serve` identifies in the Tailscale-User-Login header on requests it proxies to
loopback. That trust is read only: notes, PDFs and changes, never uploads.
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import os
import posixpath
import re
import secrets
import shutil
import sys
import tempfile
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

NOTE_FILE = re.compile(r"\.sbn2?(\.(\d+|p))?$")
INBOX_KINDS = {
    ".pdf", ".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic", ".sbn2", ".sba",
}
SCAN_INTERVAL = 0.5
# A dropped file is offered once its size and mtime have not changed for this long.
STABLE_FOR = 1.0
MAX_BODY = 512 * 1024 * 1024


def now_ms() -> int:
    return int(time.time() * 1000)


def stamp() -> str:
    return time.strftime("%Y-%m-%dT%H-%M-%S") + f".{now_ms() % 1000:03d}"


class Store:
    """Everything on disk under the root."""

    def __init__(self, root: Path):
        self.root = root
        self.notes = root / "Notes"
        self.inbox = root / "Inbox"
        self.meta = root / ".quill"
        self.store = self.meta / "store"
        self.trash = self.meta / "trash"
        self.delivered = self.meta / "delivered"
        for d in (self.notes, self.inbox, self.store, self.trash, self.delivered):
            d.mkdir(parents=True, exist_ok=True)
        self.events = self.meta / "events.jsonl"
        self._log_lock = threading.Lock()
        self._lock = threading.Lock()
        self.on_pdf = None  # called with the note path after each PDF upload (OCR)
        # PDF changes for the live view: note -> (seq, mtime ms or None if deleted)
        self._changes = threading.Condition()
        self._seq = 0
        self._changed: dict[str, tuple[int, int | None]] = {}

    # -- paths ---------------------------------------------------------------

    @staticmethod
    def clean(rel: str | None) -> str:
        """A note path as the app names it: '/School/hw.sbn2'. Raises ValueError."""
        if not rel or not rel.startswith("/") or "\\" in rel or "\x00" in rel:
            raise ValueError("path must start with /")
        parts = rel.split("/")[1:]
        if any(p in ("", ".", "..") or p.startswith(".") for p in parts):
            raise ValueError("bad path segment")
        return posixpath.normpath(rel)

    def under(self, base: Path, rel: str) -> Path:
        target = base / rel.lstrip("/")
        if os.path.commonpath([str(base), str(target)]) != str(base):
            raise ValueError("path escapes root")
        return target

    # -- writes --------------------------------------------------------------

    @staticmethod
    def write_atomic(target: Path, data: bytes, mtime_ms: int | None, mode: int):
        target.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=f".{target.name}.", suffix=".tmp", dir=target.parent)
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(data)
                f.flush()
                os.fsync(f.fileno())
            os.chmod(tmp, mode)
            if mtime_ms:
                os.utime(tmp, ns=(mtime_ms * 1_000_000, mtime_ms * 1_000_000))
            os.replace(tmp, target)
        except BaseException:
            try:
                os.unlink(tmp)
            except FileNotFoundError:
                pass
            raise

    def put_file(self, rel: str, data: bytes, mtime_ms: int | None):
        rel = self.clean(rel)
        if not NOTE_FILE.search(rel):
            raise ValueError("not a note file")
        target = self.under(self.store, rel)
        with self._lock:
            self.write_atomic(target, data, mtime_ms, 0o644)
        return target

    def pdf_path(self, note: str) -> Path:
        note = self.clean(note)
        return self.under(self.notes, note + ".pdf")

    def put_pdf(self, note: str, data: bytes, mtime_ms: int | None):
        if not data.startswith(b"%PDF"):
            raise ValueError("not a pdf")
        target = self.pdf_path(note)
        with self._lock:
            self.write_atomic(target, data, mtime_ms, 0o444)
        self._changed_pdf(self.clean(note), target.stat().st_mtime_ns // 1_000_000)
        if self.on_pdf:
            self.on_pdf(self.clean(note))
        return target

    def _to_trash(self, src: Path, base: Path, bucket: Path):
        if not src.exists():
            return False
        dst = bucket / src.relative_to(base)
        dst.parent.mkdir(parents=True, exist_ok=True)
        os.replace(src, dst)
        self._prune_empty(src.parent, base)
        return True

    @staticmethod
    def _prune_empty(d: Path, base: Path):
        while d != base and d.is_dir():
            try:
                d.rmdir()
            except OSError:
                return
            d = d.parent

    def delete_file(self, rel: str):
        rel = self.clean(rel)
        if not NOTE_FILE.search(rel):
            raise ValueError("not a note file")
        bucket = self.trash / stamp()
        with self._lock:
            moved = self._to_trash(self.under(self.store, rel), self.store, bucket / "store")
            if rel.endswith((".sbn2", ".sbn")):
                note = re.sub(r"\.sbn2?$", "", rel)
                pdf = self.pdf_path(note)
                if pdf.exists():
                    os.chmod(pdf, 0o644)
                    self._changed_pdf(note, None)
                moved |= self._to_trash(pdf, self.notes, bucket / "Notes")
        return moved

    # -- live view -------------------------------------------------------------

    def _changed_pdf(self, note: str, mtime: int | None):
        with self._changes:
            self._seq += 1
            self._changed[note] = (self._seq, mtime)
            self._changes.notify_all()

    def wait_changes(self, since: int | None, timeout: float):
        """PDFs changed after `since` ({note: mtime or None}), waiting up to timeout."""
        with self._changes:
            if since is None or since > self._seq:
                return self._seq, {}
            self._changes.wait_for(lambda: self._seq > since, timeout=timeout)
            return self._seq, {n: m for n, (q, m) in self._changed.items() if q > since}

    def notes_list(self):
        out = []
        for p in self.notes.rglob("*.pdf"):
            if not p.name.startswith("."):
                rel = "/" + p.relative_to(self.notes).as_posix()[: -len(".pdf")]
                out.append({"path": rel, "mtime": p.stat().st_mtime_ns // 1_000_000})
        out.sort(key=lambda n: n["mtime"], reverse=True)
        return out

    # -- reads ---------------------------------------------------------------

    def manifest(self):
        files = {}
        for p in self.store.rglob("*"):
            if p.is_file() and not p.name.startswith("."):
                st = p.stat()
                files["/" + p.relative_to(self.store).as_posix()] = {
                    "size": st.st_size, "mtime": st.st_mtime_ns // 1_000_000,
                }
        pdfs = {}
        for p in self.notes.rglob("*.pdf"):
            if not p.name.startswith("."):
                rel = "/" + p.relative_to(self.notes).as_posix()[: -len(".pdf")]
                pdfs[rel] = p.stat().st_mtime_ns // 1_000_000
        return {"files": files, "pdfs": pdfs}

    # -- events --------------------------------------------------------------

    def log(self, ev: str, **fields):
        line = json.dumps({"t": now_ms(), "ev": ev, **fields}, ensure_ascii=False)
        with self._log_lock:
            with open(self.events, "a", encoding="utf-8") as f:
                f.write(line + "\n")


class Inbox:
    """Watches Inbox/ by polling and offers files once their size is stable."""

    def __init__(self, store: Store):
        self.store = store
        self.cond = threading.Condition()
        self._seen: dict[str, tuple[int, int]] = {}
        self._since: dict[str, float] = {}
        self._first_seen: dict[str, int] = {}
        self.items: dict[str, dict] = {}
        self.version = 0
        self._stop = threading.Event()
        # Notes Sam (or an agent) asked Quill to delete: id -> note path.
        self.deletes: dict[str, str] = {}
        self._deletes_mtime = None
        self._deletes_lock = threading.Lock()

    @property
    def deletes_file(self) -> Path:
        return self.store.meta / "delete-requests.json"

    def _load_deletes(self) -> bool:
        try:
            m = self.deletes_file.stat().st_mtime_ns
        except FileNotFoundError:
            m = None
        if m == self._deletes_mtime:
            return False
        self._deletes_mtime = m
        try:
            new = json.loads(self.deletes_file.read_text(encoding="utf-8")) if m else {}
        except ValueError:
            return False
        changed = new != self.deletes
        self.deletes = new
        return changed

    def ack_delete(self, ident: str):
        with self._deletes_lock:
            reqs = read_delete_requests(self.store)
            note = reqs.pop(ident, None)
            write_delete_requests(self.store, reqs)
        if note is not None:
            self.store.log("delete.done", note=note)
        with self.cond:
            self._load_deletes()
            self.version += 1
            self.cond.notify_all()
        return note

    def scan(self):
        base = self.store.inbox
        current: dict[str, tuple[int, int]] = {}
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [d for d in dirnames if not d.startswith(".")]
            for name in filenames:
                if name.startswith("."):
                    continue
                p = Path(dirpath) / name
                try:
                    st = p.stat()
                except FileNotFoundError:
                    continue
                # ctime too: moving a file into the inbox sets it, so the same file
                # dropped again after an earlier delivery is a new item, not a
                # redelivery the app has already imported and skips.
                current[p.relative_to(base).as_posix()] = (st.st_size, st.st_mtime_ns, st.st_ctime_ns)

        items = {}
        for rel, sig in current.items():
            self._first_seen.setdefault(rel, now_ms())
            ext = posixpath.splitext(rel)[1].lower()
            if ext not in INBOX_KINDS:
                if rel not in self._seen:
                    self.store.log("inbox.unsupported", file=rel)
                continue
            if self._seen.get(rel) != sig:
                # Unchanged since its mtime: a file moved in whole (or sent
                # with `put`, which keeps the source's mtime) is ready at once.
                age = max(0.0, time.time() - sig[1] / 1e9)
                self._since[rel] = time.monotonic() - (age if rel not in self._seen else 0)
            if sig[0] == 0 or time.monotonic() - self._since.get(rel, 0) < STABLE_FOR:
                continue  # may still be being written: offer it on a later scan
            ident = hashlib.sha1(f"{rel}\0{sig[0]}\0{sig[1]}\0{sig[2]}".encode()).hexdigest()[:20]
            folder, name = posixpath.split(rel)
            items[ident] = {
                "id": ident,
                "file": rel,
                "folder": "/" + folder + "/" if folder else "/",
                "name": name,
                "ext": ext,
                "size": sig[0],
                "seen": self._first_seen[rel],
            }
        for rel in list(self._first_seen):
            if rel not in current:
                del self._first_seen[rel]
                self._since.pop(rel, None)
        self._seen = current
        with self.cond:
            deletes_changed = self._load_deletes()
            if items.keys() != self.items.keys() or deletes_changed:
                self.items = items
                self.version += 1
                self.cond.notify_all()

    def run(self):
        while not self._stop.is_set():
            try:
                self.scan()
            except Exception as e:  # keep watching whatever happens
                self.store.log("inbox.error", error=repr(e))
            self._stop.wait(SCAN_INTERVAL)

    def stop(self):
        self._stop.set()

    def wait(self, timeout: float, since: int | None):
        """Items once the inbox differs from version [since] (or has items, if
        [since] is None), or whatever it holds when [timeout] runs out."""
        deadline = time.monotonic() + timeout
        with self.cond:
            while (not self.items and not self.deletes) if since is None else (self.version == since):
                left = deadline - time.monotonic()
                if left <= 0:
                    break
                self.cond.wait(left)
            deletes = [{"id": i, "note": n} for i, n in self.deletes.items()]
            return self.version, list(self.items.values()), deletes

    def get(self, ident: str):
        with self.cond:
            return self.items.get(ident)

    def ack(self, ident: str, note: str | None):
        with self.cond:
            item = self.items.get(ident)
        if item is None:
            return None  # already acked, or gone: harmless
        src = self.store.inbox / item["file"]
        dst = self.store.delivered / stamp() / item["file"]
        dst.parent.mkdir(parents=True, exist_ok=True)
        try:
            os.replace(src, dst)
        except FileNotFoundError:
            return None
        Store._prune_empty(src.parent, self.store.inbox)
        lag = now_ms() - item["seen"]
        self.store.log("inbox.delivered", file=item["file"], note=note, lag_ms=lag)
        with self.cond:
            self.items.pop(ident, None)
            self._seen.pop(item["file"], None)
            self.version += 1
            self.cond.notify_all()
        return {"file": item["file"], "note": note, "lag_ms": lag}


def read_delete_requests(store: Store) -> dict:
    f = store.meta / "delete-requests.json"
    try:
        return json.loads(f.read_text(encoding="utf-8"))
    except (FileNotFoundError, ValueError):
        return {}


def write_delete_requests(store: Store, reqs: dict):
    Store.write_atomic(store.meta / "delete-requests.json",
                       json.dumps(reqs, ensure_ascii=False, indent=1).encode(), None, 0o644)


LIVE_HTML = Path(__file__).with_name("live.html")


def make_handler(store: Store, inbox: Inbox, token: str, viewers: frozenset = frozenset(), link=None):
    class Handler(BaseHTTPRequestHandler):
        server_version = "quill-sync/1"
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):  # quiet: events.jsonl is the log
            pass

        # -- helpers ---------------------------------------------------------

        def _send(self, code: int, body=None, ctype="application/json", headers=None):
            if body is None:
                data = b""
            elif isinstance(body, (bytes, bytearray)):
                data = bytes(body)
            else:
                data = json.dumps(body, ensure_ascii=False).encode()
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            for k, v in (headers or {}).items():
                self.send_header(k, v)
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(data)

        def _authed(self) -> bool:
            got = self.headers.get("Authorization", "")
            want = f"Bearer {token}"
            if hmac.compare_digest(got.encode(), want.encode()):
                return True
            self._send(HTTPStatus.UNAUTHORIZED, {"error": "unauthorized"})
            return False

        def _viewer(self) -> bool:
            """Token, or a listed Tailscale user proxied by tailscale serve (read only)."""
            got = self.headers.get("Authorization", "")
            if hmac.compare_digest(got.encode(), f"Bearer {token}".encode()):
                return True
            login = self.headers.get("Tailscale-User-Login", "")
            if login and login in viewers and self.client_address[0] in ("127.0.0.1", "::1"):
                return True
            self._send(HTTPStatus.UNAUTHORIZED, {"error": "unauthorized"})
            return False

        def _body(self) -> bytes:
            n = int(self.headers.get("Content-Length") or 0)
            if n > MAX_BODY:
                raise ValueError("too large")
            return self.rfile.read(n) if n else b""

        def _route(self):
            u = urlsplit(self.path)
            q = {k: v[0] for k, v in parse_qs(u.query).items()}
            return u.path, q

        def _int(self, name: str):
            v = self.headers.get(name)
            return int(v) if v and v.isdigit() else None

        def _upload_logged(self, ev: str, path: str, size: int):
            written = self._int("X-Quill-Written-At")
            fields = {"path": path, "size": size}
            if written:
                fields["lag_ms"] = now_ms() - written
            store.log(ev, **fields)

        # -- methods ---------------------------------------------------------

        def do_GET(self):
            path, q = self._route()
            if path == "/v1/health":
                return self._send(200, {"ok": True})
            if path in ("/live", "/v1/notes", "/v1/changes") or (path == "/v1/pdf"):
                if not self._viewer():
                    return
                return self._live(path, q)
            if not self._authed():
                return
            if path == "/v1/manifest":
                return self._send(200, store.manifest())
            if path == "/v1/courses":
                if link is None:
                    return self._send(404, {"error": "not configured"})
                try:
                    return self._send(200, link.courses.payload(force=q.get("refresh") == "1"))
                except Exception as e:  # Cedar or Canvas down: the app keeps what it had
                    return self._send(502, {"error": f"courses unavailable: {e!r}"[:200]})
            if path == "/v1/inbox":
                wait = min(float(q.get("wait", 0) or 0), 55.0)
                since = q.get("since")
                since = int(since) if since and since.lstrip("-").isdigit() else None
                version, items, deletes = inbox.wait(wait, since)
                return self._send(200, {"version": version, "items": items, "deletes": deletes})
            m = re.fullmatch(r"/v1/inbox/([0-9a-f]{20})", path)
            if m:
                item = inbox.get(m.group(1))
                if item is None:
                    return self._send(404, {"error": "no such item"})
                try:
                    data = (store.inbox / item["file"]).read_bytes()
                except FileNotFoundError:
                    return self._send(404, {"error": "gone"})
                return self._send(200, data, "application/octet-stream")
            self._send(404, {"error": "not found"})

        def _live(self, path, q):
            if path == "/live":
                return self._send(200, LIVE_HTML.read_bytes(), "text/html; charset=utf-8")
            if path == "/v1/notes":
                return self._send(200, {"notes": store.notes_list()})
            if path == "/v1/changes":
                wait = min(float(q.get("wait", 0) or 0), 55.0)
                since = q.get("since")
                since = int(since) if since and since.isdigit() else None
                seq, changed = store.wait_changes(since, wait)
                return self._send(200, {"seq": seq, "changed": changed})
            try:
                pdf = store.pdf_path(q.get("path"))
                mtime = pdf.stat().st_mtime_ns // 1_000_000
                data = pdf.read_bytes()
            except ValueError as e:
                return self._send(400, {"error": str(e)})
            except FileNotFoundError:
                return self._send(404, {"error": "no such note"})
            return self._send(200, data, "application/pdf",
                              {"X-Mtime": str(mtime), "Cache-Control": "no-store"})

        def do_PUT(self):
            path, q = self._route()
            if not self._authed():
                return
            try:
                data = self._body()
                mtime = self._int("X-Mtime")
                if path == "/v1/file":
                    store.put_file(q.get("path"), data, mtime)
                    self._upload_logged("file", q.get("path"), len(data))
                elif path == "/v1/pdf":
                    store.put_pdf(q.get("path"), data, mtime)
                    self._upload_logged("pdf", q.get("path"), len(data))
                else:
                    return self._send(404, {"error": "not found"})
            except ValueError as e:
                return self._send(400, {"error": str(e)})
            self._send(200, {"ok": True})

        def _send_out(self, path, q):
            """A page or PDF from Quill to ATLAS's shelf, or a PDF proposed to Canvas
            (Sam taps Submit on the card; nothing is submitted here)."""
            if link is None:
                return self._send(404, {"error": "not configured"})
            try:
                data = self._body()
                note = q.get("note") or "note"
                if path == "/v1/send":
                    kind = q.get("kind") if q.get("kind") in ("page", "pdf") else "pdf"
                    res = link.sender.to_atlas(note, kind, data)
                else:
                    res = link.sender.to_canvas(note, q.get("course", ""), q.get("assignment", ""), data)
            except ValueError as e:
                return self._send(400, {"error": str(e)})
            except RuntimeError as e:
                store.log("send.failed", path=path, note=q.get("note"), error=str(e))
                return self._send(502, {"error": str(e)})
            store.log("send" if path == "/v1/send" else "canvas.propose", note=q.get("note"),
                      kind=q.get("kind"), course=q.get("course"), assignment=q.get("assignment"))
            self._send(200, res)

        def do_DELETE(self):
            path, q = self._route()
            if not self._authed():
                return
            if path != "/v1/file":
                return self._send(404, {"error": "not found"})
            try:
                moved = store.delete_file(q.get("path"))
            except ValueError as e:
                return self._send(400, {"error": str(e)})
            store.log("delete", path=q.get("path"), moved=moved)
            self._send(200, {"ok": True, "moved": moved})

        def do_POST(self):
            path, q = self._route()
            if not self._authed():
                return
            if path in ("/v1/send", "/v1/canvas"):
                return self._send_out(path, q)
            d = re.fullmatch(r"/v1/deletes/([0-9a-f]{20})/ack", path)
            if d:
                return self._send(200, {"ok": True, "note": inbox.ack_delete(d.group(1))})
            m = re.fullmatch(r"/v1/inbox/([0-9a-f]{20})/ack", path)
            if not m:
                return self._send(404, {"error": "not found"})
            try:
                body = json.loads(self._body() or b"{}")
            except ValueError:
                body = {}
            res = inbox.ack(m.group(1), body.get("note"))
            self._send(200, {"ok": True, "delivered": res})

    return Handler


def default_root() -> Path:
    return Path(os.environ.get("QUILL_ROOT", Path.home() / "quill"))


def token_file() -> Path:
    return Path(os.environ.get("QUILL_TOKEN_FILE", Path.home() / ".config/quill-sync/token"))


def load_token(create: bool) -> str:
    f = token_file()
    if not f.exists():
        if not create:
            sys.exit(f"no token at {f}")
        f.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(f, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as fh:
            fh.write(secrets.token_urlsafe(32) + "\n")
    return f.read_text().strip()


def load_viewers() -> frozenset:
    f = Path(os.environ.get("QUILL_VIEWERS_FILE", Path.home() / ".config/quill-sync/viewers"))
    try:
        lines = f.read_text().split()
    except FileNotFoundError:
        return frozenset()
    return frozenset(l for l in lines if l and not l.startswith("#"))


class Link:
    """The connections to the rest of Sam's setup (connect.py)."""

    def __init__(self, root: Path):
        import connect

        self.courses = connect.Courses(root)
        self.sender = connect.Sender(root, self.courses)
        self.ocr = connect.Ocr(root)

    def start(self):
        threading.Thread(target=self.ocr.run, daemon=True, name="ocr").start()
        self.ocr.backfill()
        threading.Thread(target=self._provision, daemon=True, name="courses").start()

    def _provision(self):
        import connect

        while True:
            try:
                landed = self.courses.provision()
                if landed:
                    print(json.dumps({"ev": "courses.provisioned", "files": landed}), flush=True)
            except Exception as e:  # Cedar or Canvas down: try again next round
                print(json.dumps({"ev": "courses.failed", "error": repr(e)[:200]}), flush=True)
            time.sleep(connect.REFRESH_EVERY * 3)


def serve(host: str, port: int, root: Path, token: str, viewers: frozenset | None = None,
          link: Link | None = None):
    """Start the server; returns (httpd, inbox) with threads running."""
    store = Store(root)
    if link is not None:
        store.on_pdf = link.ocr.touch
    inbox = Inbox(store)
    threading.Thread(target=inbox.run, daemon=True, name="inbox").start()
    if viewers is None:
        viewers = load_viewers()
    httpd = ThreadingHTTPServer((host, port), make_handler(store, inbox, token, viewers, link))
    httpd.daemon_threads = True
    return httpd, inbox


def cmd_put(args):
    root = default_root()
    store = Store(root)
    src = Path(args.file).expanduser()
    if not src.is_file():
        sys.exit(f"not a file: {src}")
    if src.suffix.lower() not in INBOX_KINDS:
        sys.exit(f"Quill cannot import {src.suffix or 'that'} files: {', '.join(sorted(INBOX_KINDS))}")
    folder = (args.to or "").strip("/")
    if folder:
        Store.clean("/" + folder)
    dest_dir = store.inbox / folder
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / src.name
    if dest.exists():
        sys.exit(f"already waiting in the inbox: {dest}")
    tmp = dest_dir / f".{src.name}.tmp"
    shutil.copyfile(src, tmp)
    # An mtime in the past tells the watcher the file is complete.
    old = time.time() - 2 * STABLE_FOR
    os.utime(tmp, (old, old))
    os.replace(tmp, dest)
    rel = dest.relative_to(store.inbox).as_posix()
    print(f"queued for Quill: Inbox/{rel}")
    if not args.wait:
        return
    deadline = time.time() + args.timeout
    while time.time() < deadline:
        if not dest.exists():
            for line in reversed(store.events.read_text(encoding="utf-8").splitlines()[-200:]):
                ev = json.loads(line)
                if ev.get("ev") == "inbox.delivered" and ev.get("file") == rel:
                    print(f"in Quill as {ev.get('note')} ({ev.get('lag_ms')} ms)")
                    return
            print("delivered")
            return
        time.sleep(0.25)
    sys.exit("not delivered yet (is Quill open and on the tailnet?); it stays queued")


def cmd_delete(args):
    """Ask Quill to delete notes. The app deletes each one (to the server's trash) and acks."""
    store = Store(default_root())
    reqs = read_delete_requests(store)
    for note in args.notes:
        note = "/" + note.strip("/")
        Store.clean(note)  # refuses traversal
        if note in reqs.values():
            continue
        ident = hashlib.sha1(f"{note}\0{time.time()}".encode()).hexdigest()[:20]
        reqs[ident] = note
        print(f"asked Quill to delete {note}")
    write_delete_requests(store, reqs)


def cmd_status(_args):
    root = default_root()
    store = Store(root)
    pending = [p.relative_to(store.inbox).as_posix() for p in store.inbox.rglob("*")
               if p.is_file() and not any(s.startswith(".") for s in p.relative_to(store.inbox).parts)]
    m = store.manifest()
    last = {}
    if store.events.exists():
        for line in store.events.read_text(encoding="utf-8").splitlines()[-2000:]:
            ev = json.loads(line)
            last[ev["ev"]] = ev
    print(json.dumps({
        "root": str(root),
        "notes_pdfs": len(m["pdfs"]),
        "store_files": len(m["files"]),
        "inbox_waiting": pending,
        "last_upload": last.get("pdf") or last.get("file"),
        "last_delivery": last.get("inbox.delivered"),
    }, indent=2, ensure_ascii=False))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("serve")
    s.add_argument("--host", default="127.0.0.1")
    s.add_argument("--port", type=int, default=8796)
    p = sub.add_parser("put", help="send a file to Quill")
    p.add_argument("file")
    p.add_argument("--to", help="Quill folder, e.g. 'School/CS 114'")
    p.add_argument("--wait", action="store_true", help="wait until Quill has it")
    p.add_argument("--timeout", type=float, default=60)
    sub.add_parser("status")
    d = sub.add_parser("delete", help="ask Quill to delete notes")
    d.add_argument("notes", nargs="+", help="note paths without extension, e.g. '/School/hw (2)'")
    args = ap.parse_args()

    if args.cmd == "serve":
        import faulthandler
        import signal

        faulthandler.register(signal.SIGUSR1, all_threads=True)  # kill -USR1 dumps every stack to the log
        token = load_token(create=True)
        link = Link(default_root())
        httpd, _ = serve(args.host, args.port, default_root(), token, link=link)
        link.start()
        print(f"quill-sync on {args.host}:{args.port}, root {default_root()}", flush=True)
        httpd.serve_forever()
    elif args.cmd == "put":
        cmd_put(args)
    elif args.cmd == "delete":
        cmd_delete(args)
    else:
        cmd_status(args)


if __name__ == "__main__":
    main()
