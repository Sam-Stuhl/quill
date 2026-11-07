#!/usr/bin/env python3
"""Copy Notability's PDFs into Quill's inbox, in the same folders (docs/quill-sync.md).

Run as `sam` on the mini; reads Notability's backup (notasync's staging, in the
console account) over the mac-mini-console loopback ssh:

    import_notability.py FOLDER...   (e.g. Other "Fall 26" Highschool)

Safe to run again: a note already in Quill (Notes/) or waiting in the inbox is
skipped. Each note is listed in ~/quill/.quill/imported before it is dropped,
so quill-stage keeps its import render out of the vault (the original is
already there) until Sam writes in it.
"""
import os, subprocess, sys, shutil
from pathlib import Path
Q = Path.home() / "quill"; INBOX = Q / "Inbox"; TMP = Q / ".quill/import-tmp"; LIST = Q / ".quill/imported"
SRC = "Notability/staging/Notability"
for folder in sys.argv[1:]:
    out = subprocess.run(["ssh", "-o", "BatchMode=yes", "mac-mini-console", f"cd ~/{SRC} && find {subprocess.list2cmdline([folder])} -name '*.pdf' -print0"],
                         check=True, capture_output=True).stdout.decode().split("\0")
    rels = sorted(r[2:] if r.startswith("./") else r for r in out if r)
    def in_quill(r):
        d, n = os.path.split(r)
        trimmed = os.path.join(d, n[:-len(".pdf")].strip() + ".pdf")
        return any((Q / ".quill/store" / (p[:-len(".pdf")] + ".sbn2")).exists()
                   or (Q / "Notes" / p).exists() for p in (r, trimmed)) or (INBOX / r).exists()
    todo = [r for r in rels if not in_quill(r)]
    print(f"{folder}: {len(rels)} notes, {len(todo)} to import", flush=True)
    if not todo: continue
    # Register before dropping, so quill-stage never sends their import render to the vault.
    # Quill trims spaces around a note's name ("Homework 4 .pdf" becomes the
    # note "Homework 4"), so list the trimmed path too.
    have = set(LIST.read_text().splitlines()) if LIST.exists() else set()
    with open(LIST, "a") as f:
        for r in todo:
            d, n = os.path.split(r)
            for path in (r, os.path.join(d, n[:-len(".pdf")].strip() + ".pdf")):
                if path not in have:
                    f.write(path + "\n")
                    have.add(path)
    shutil.rmtree(TMP, ignore_errors=True); TMP.mkdir(parents=True)
    tar = subprocess.Popen(["ssh", "-o", "BatchMode=yes", "mac-mini-console", f"cd ~/{SRC} && tar -cf - -T -"],
                           stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    untar = subprocess.Popen(["tar", "-xf", "-", "-C", str(TMP)], stdin=tar.stdout)
    tar.stdin.write(("\n".join(todo) + "\n").encode()); tar.stdin.close()
    untar.wait(); tar.wait()
    assert untar.returncode == 0 and tar.returncode == 0, "copy failed"
    for r in todo:
        dst = INBOX / r; dst.parent.mkdir(parents=True, exist_ok=True)
        os.rename(TMP / r, dst)
    shutil.rmtree(TMP, ignore_errors=True)
    print(f"{folder}: {len(todo)} in Quill's inbox", flush=True)
