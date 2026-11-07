#!/usr/bin/env python3
"""quill-stage: copies Quill's PDFs to a staging folder the vault router reads.

Runs as the mini's `console` account (LaunchAgent com.samstuhl.quill-stage),
because the router is a container on console's Colima, which can only see
console's home. Quill sync (server.py, `sam` account) writes ~sam/quill/Notes;
this copies each PDF that changed into ~console/Quill/staging, keeping the
folder layout and mtime, and never deletes anything. The router (notasync's
own image, a second instance with config notasync-quill.yaml) then files them
into the vault with companion notes, exactly like Notability's PDFs.

Name clash guard: notasync overwrites a vault file of the same name, so a new
Quill note whose name is already used by a vault file the Quill router does not
own is staged as "<name> (Quill).pdf". The choice is remembered, so the note
keeps that name for good.

Hold: the router files a PDF only once it has seen the staged copy unchanged on
two passes a second apart. While Sam writes, Quill sends a new PDF every couple
of seconds, so a copy staged each time never holds still and the vault would
wait until he pauses. So a note's staged copy is replaced at most every HOLD
seconds: the first change after a quiet spell is staged at once, and while he
keeps writing the vault still updates every few seconds.

Imported notes: notes brought into Quill from elsewhere (the Notability
library, 2026-11-07) already have their PDF in the vault. Their paths are listed
in ~sam/quill/.quill/imported (one PDF path under Notes per line), and such a
note is not staged until its PDF changes after the first one Quill renders,
that is, until Sam writes in it. Then it replaces the Notability original in
place (no duplicate): the vault file notasync placed, found through notasync's
own manifest, wherever the nightly sorter has since filed it, keeping its
companion note. The write goes through the vault-ingest container (invariant
I6), and notasync's staged copy of that note moves to ~/Notability/retired,
so notasync never puts the old version back. Only if no original can be found
does the note go through the Quill router like a new one.

    stage.py [--once] [--interval 0.25]

Python 3.9 compatible (console's /usr/bin/python3). Standard library only.
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HOLD = 2.5

HOME = Path.home()
SOURCE = Path(os.environ.get("QUILL_NOTES", "/Users/sam/quill/Notes"))
STAGING = Path(os.environ.get("QUILL_STAGING", HOME / "Quill/staging"))
VAULT = Path(os.environ.get("QUILL_VAULT", HOME / "console-volumes/vault-ingest/ingest"))
STATE_DIR = Path(os.environ.get("QUILL_STATE_DIR", HOME / ".local/state/quill-stage"))
IMPORTED = Path(os.environ.get("QUILL_IMPORTED", "/Users/sam/quill/.quill/imported"))
NOTASYNC_MANIFEST = Path(
    os.environ.get("QUILL_NOTASYNC_MANIFEST", HOME / ".local/state/notasync/manifest.json")
)
NOTABILITY_STAGING = Path(os.environ.get("QUILL_NOTABILITY_STAGING", HOME / "Notability/staging"))
RETIRED = Path(os.environ.get("QUILL_RETIRED", HOME / "Notability/retired"))
INGEST_IN_CONTAINER = "/data/ingest"
DOCKER = "/usr/local/bin/docker"


def trimmed(rel):
    d, n = os.path.split(rel)
    return os.path.join(d, n[: -len(".pdf")].strip() + ".pdf")


def docker_write(src, vault_path, vault_root):
    """Write src over vault_path from inside the vault-ingest container (I6)."""
    env = {**os.environ, "PATH": "/usr/local/bin:/usr/bin:/bin"}
    names = subprocess.run([DOCKER, "ps", "--format", "{{.Names}}"], check=True,
                           capture_output=True, text=True, env=env).stdout.split()
    container = next(n for n in names if n.startswith("vault-ingest-"))
    inside = INGEST_IN_CONTAINER + "/" + Path(vault_path).relative_to(vault_root).as_posix()
    with open(src, "rb") as data:
        subprocess.run(
            [DOCKER, "exec", "-i", "-u", "1993", container, "sh", "-c",
             'd=$(dirname "$1"); t="$d/.$(basename "$1").quill-tmp"; cat > "$t" && mv "$t" "$1"',
             "sh", inside],
            stdin=data, check=True, capture_output=True, env=env, timeout=60)


ROUTER_MANIFEST = Path(
    os.environ.get("QUILL_ROUTER_MANIFEST", HOME / ".local/state/notasync-quill/manifest.json")
)


def log(event, **fields):
    print(json.dumps({"t": time.strftime("%Y-%m-%dT%H:%M:%S"), "ev": event, **fields},
                     ensure_ascii=False), flush=True)


class Stager:
    def __init__(self, source=SOURCE, staging=STAGING, vault=VAULT, state_dir=STATE_DIR,
                 router_manifest=ROUTER_MANIFEST, imported=IMPORTED,
                 notasync_manifest=NOTASYNC_MANIFEST, notability_staging=NOTABILITY_STAGING,
                 retired=RETIRED, writer=docker_write):
        self.source = source
        self.staging = staging
        self.vault = vault
        self.router_manifest = router_manifest
        self.state_file = state_dir / "names.json"
        state_dir.mkdir(parents=True, exist_ok=True)
        staging.mkdir(parents=True, exist_ok=True)
        # source rel path -> staged rel path (decided once, kept forever)
        self.names = {}
        if self.state_file.exists():
            self.names = json.loads(self.state_file.read_text(encoding="utf-8"))
        self._vault_names = None
        self._last_staged = {}  # source rel path -> monotonic time last staged
        self.imported_file = imported
        self._imported = set()
        self._imported_mtime = None
        # imported rel path -> [size, mtime_ns] of its first PDF, or "live" once written in
        self.notasync_manifest = notasync_manifest
        self.notability_staging = notability_staging
        self.retired = retired
        self.writer = writer
        # Quill rel path -> {"vault": path, "size": n, "mtime": ns} once it replaced its original
        self.takeover_file = state_dir / "takeover.json"
        self.takeover = {}
        if self.takeover_file.exists():
            self.takeover = json.loads(self.takeover_file.read_text(encoding="utf-8"))
        self.baseline_file = state_dir / "imported-baseline.json"
        self.baseline = {}
        if self.baseline_file.exists():
            self.baseline = json.loads(self.baseline_file.read_text(encoding="utf-8"))

    def _imported_paths(self):
        try:
            m = self.imported_file.stat().st_mtime_ns
        except FileNotFoundError:
            return self._imported
        if m != self._imported_mtime:
            lines = self.imported_file.read_text(encoding="utf-8").splitlines()
            self._imported = {l for l in lines if l.strip()}
            self._imported_mtime = m
        return self._imported

    def _original_rel(self, rel):
        """The Notability path a Quill note was imported from (Quill trims names)."""
        paths = self._imported_paths()
        candidates = sorted((p for p in paths if trimmed(p) == rel), key=lambda p: p == rel)
        return candidates[0] if candidates else rel

    def _find_original(self, rel):
        orig = self._original_rel(rel)
        try:
            entries = json.loads(self.notasync_manifest.read_text(encoding="utf-8"))["entries"]
        except (OSError, ValueError, KeyError):
            entries = {}
        entry = entries.get("Notability/" + orig) or entries.get(orig) or {}
        vp = entry.get("vault_path")
        if vp and Path(vp).exists():
            return Path(vp), orig
        return self._find_by_name(os.path.basename(vp or orig)), orig

    def _find_by_name(self, name):
        hits = []
        for dirpath, dirnames, filenames in os.walk(self.vault):
            dirnames[:] = [d for d in dirnames if not d.startswith(".")]
            if name in filenames:
                hits.append(Path(dirpath) / name)
        return hits[0] if len(hits) == 1 else None

    def _replace_original(self, rel, src, st):
        """Write an edited imported note over its Notability original. False if none."""
        t = self.takeover.get(rel)
        if t and t["size"] == st.st_size and t["mtime"] == st.st_mtime_ns:
            return True
        vault_path = Path(t["vault"]) if t else None
        if vault_path is None or not vault_path.exists():
            if t:
                vault_path = self._find_by_name(Path(t["vault"]).name)
            else:
                vault_path, orig = self._find_original(rel)
                if vault_path is not None:
                    self._retire(orig)
        if vault_path is None:
            log("no-original", source=rel, note="staged like a new note")
            return False
        now = time.monotonic()
        if now - self._last_staged.get(rel, -HOLD) < HOLD:
            return True
        self.writer(src, vault_path, self.vault)
        self._last_staged[rel] = now
        self.takeover[rel] = {"vault": str(vault_path), "size": st.st_size, "mtime": st.st_mtime_ns}
        tmp = self.takeover_file.with_name(self.takeover_file.name + ".tmp")
        tmp.write_text(json.dumps(self.takeover, ensure_ascii=False, indent=1), encoding="utf-8")
        os.replace(tmp, self.takeover_file)
        log("replaced-original", source=rel, vault=str(vault_path), bytes=st.st_size)
        return True

    def _retire(self, orig):
        staged = self.notability_staging / "Notability" / orig
        if staged.exists():
            dest = self.retired / "Notability" / orig
            dest.parent.mkdir(parents=True, exist_ok=True)
            os.replace(staged, dest)
            log("retired-notability-copy", source=orig, to=str(dest))

    def _hold_imported(self, rel, st):
        """True while an imported note still has only the PDF Quill rendered on import."""
        if rel not in self._imported_paths():
            return False
        seen = self.baseline.get(rel)
        if seen == "live":
            return False
        now = [st.st_size, st.st_mtime_ns]
        if seen is None:
            self.baseline[rel] = now
        elif seen == now:
            return True
        else:
            self.baseline[rel] = "live"
            log("imported-note-edited", source=rel)
        tmp = self.baseline_file.with_name(self.baseline_file.name + ".tmp")
        tmp.write_text(json.dumps(self.baseline, ensure_ascii=False, indent=1), encoding="utf-8")
        os.replace(tmp, self.baseline_file)
        return self.baseline[rel] != "live"

    def _save(self):
        tmp = self.state_file.with_name(self.state_file.name + ".tmp")
        tmp.write_text(json.dumps(self.names, ensure_ascii=False, indent=1), encoding="utf-8")
        os.replace(tmp, self.state_file)

    def _owned_by_router(self):
        """Vault paths the Quill router already owns (its manifest)."""
        try:
            data = json.loads(self.router_manifest.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return set()
        entries = data.get("entries", data) if isinstance(data, dict) else {}
        owned = set()
        for entry in entries.values() if isinstance(entries, dict) else []:
            if isinstance(entry, dict) and entry.get("vault_path"):
                owned.add(Path(entry["vault_path"]).name)
        return owned

    def _vault_has(self, name):
        if self._vault_names is None:
            names = set()
            for dirpath, dirnames, filenames in os.walk(self.vault):
                dirnames[:] = [d for d in dirnames if not d.startswith(".")]
                names.update(filenames)
            self._vault_names = names
        return name in self._vault_names

    def _staged_name(self, rel):
        if rel in self.names:
            return self.names[rel]
        parent, name = os.path.split(rel)
        staged = rel
        if self._vault_has(name) and name not in self._owned_by_router():
            stem = name[: -len(".pdf")]
            staged = os.path.join(parent, f"{stem} (Quill).pdf")
            log("renamed", source=rel, staged=staged, reason="name already in the vault")
        taken = set(self.names.values())
        n = 2
        while staged in taken:
            stem = os.path.join(parent, name[: -len(".pdf")])
            staged = f"{stem} (Quill {n}).pdf"
            n += 1
        self.names[rel] = staged
        self._save()
        return staged

    def pass_once(self):
        self._vault_names = None
        copied = 0
        if not self.source.is_dir():
            return 0
        for dirpath, dirnames, filenames in os.walk(self.source):
            dirnames[:] = [d for d in dirnames if not d.startswith(".")]
            for name in filenames:
                if name.startswith(".") or not name.endswith(".pdf"):
                    continue
                src = Path(dirpath) / name
                rel = src.relative_to(self.source).as_posix()
                try:
                    st = src.stat()
                except FileNotFoundError:
                    continue
                if self._hold_imported(rel, st):
                    continue
                if rel in self._imported_paths():
                    try:
                        if self._replace_original(rel, src, st):
                            continue
                    except Exception as e:  # retried next pass; never a duplicate meanwhile
                        log("replace-failed", source=rel, error=repr(e))
                        continue
                dest = self.staging / self._staged_name(rel)
                try:
                    dst = dest.stat()
                    if dst.st_size == st.st_size and dst.st_mtime_ns == st.st_mtime_ns:
                        continue
                except FileNotFoundError:
                    pass
                now = time.monotonic()
                if now - self._last_staged.get(rel, -HOLD) < HOLD:
                    continue  # still being written: picked up on a later pass
                self._copy(src, dest, st)
                self._last_staged[rel] = now
                copied += 1
                log("staged", source=rel, staged=dest.relative_to(self.staging).as_posix(),
                    bytes=st.st_size)
        return copied

    @staticmethod
    def _copy(src, dest, st):
        dest.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=".quill-stage-", dir=dest.parent)
        try:
            with os.fdopen(fd, "wb") as out, open(src, "rb") as inp:
                while True:
                    chunk = inp.read(1 << 20)
                    if not chunk:
                        break
                    out.write(chunk)
                out.flush()
                os.fsync(out.fileno())
            os.chmod(tmp, 0o644)
            os.utime(tmp, ns=(st.st_atime_ns, st.st_mtime_ns))
            os.replace(tmp, dest)
        finally:
            try:
                os.unlink(tmp)
            except FileNotFoundError:
                pass


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--once", action="store_true")
    ap.add_argument("--interval", type=float, default=0.25)
    args = ap.parse_args()
    stager = Stager()
    if args.once:
        stager.pass_once()
        return
    log("start", source=str(SOURCE), staging=str(STAGING))
    while True:
        try:
            stager.pass_once()
        except Exception as e:  # keep going whatever one pass hits
            log("error", error=repr(e))
        time.sleep(args.interval)


if __name__ == "__main__":
    sys.exit(main())
