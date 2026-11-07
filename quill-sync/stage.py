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

    stage.py [--once] [--interval 0.25]

Python 3.9 compatible (console's /usr/bin/python3). Standard library only.
"""

import argparse
import json
import os
import sys
import tempfile
import time
from pathlib import Path

HOME = Path.home()
SOURCE = Path(os.environ.get("QUILL_NOTES", "/Users/sam/quill/Notes"))
STAGING = Path(os.environ.get("QUILL_STAGING", HOME / "Quill/staging"))
VAULT = Path(os.environ.get("QUILL_VAULT", HOME / "console-volumes/vault-ingest/ingest"))
STATE_DIR = Path(os.environ.get("QUILL_STATE_DIR", HOME / ".local/state/quill-stage"))
ROUTER_MANIFEST = Path(
    os.environ.get("QUILL_ROUTER_MANIFEST", HOME / ".local/state/notasync-quill/manifest.json")
)


def log(event, **fields):
    print(json.dumps({"t": time.strftime("%Y-%m-%dT%H:%M:%S"), "ev": event, **fields},
                     ensure_ascii=False), flush=True)


class Stager:
    def __init__(self, source=SOURCE, staging=STAGING, vault=VAULT, state_dir=STATE_DIR,
                 router_manifest=ROUTER_MANIFEST):
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
                dest = self.staging / self._staged_name(rel)
                try:
                    dst = dest.stat()
                    if dst.st_size == st.st_size and dst.st_mtime_ns == st.st_mtime_ns:
                        continue
                except FileNotFoundError:
                    pass
                self._copy(src, dest, st)
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
