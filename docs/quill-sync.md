# Quill sync: the iPad and a folder on the mini

Sam is moving from Notability to Quill (this fork). Quill sync keeps a folder on
the Mac mini current with what he writes, within seconds, and delivers anything
put in that folder's inbox to Quill without an import step. It is separate from
notasync (Notability to Drive to the vault), which it does not touch.

Status: plan written and implemented 2026-11-06. Measurements are at the end.

## How Saber stores and syncs today

- **Notes on disk.** Each note is `<path>.sbn2` (BSON: pages, strokes, text,
  image references) plus numbered assets `<path>.sbn2.0`, `.1`, ... (images and
  imported PDFs, one file each) and a thumbnail `<path>.sbn2.p` (PNG). They live
  under the app's documents directory, `Saber/`, in the same folder tree Sam
  sees in the app. `.sba` is a zip of one note and its assets.
- **Saving.** The editor saves `autosaveDelay` after the last change (10 s by
  default), never while the pen is down, and on leaving the note. It does not
  save when the app goes to the background.
- **Nextcloud sync.** Every file write enqueues an upload. Paths and contents are
  AES-encrypted with a key derived from the encryption password (`.sbe` files
  under `Saber/` on the server), so the server never sees a readable file.
  Downloads happen only at app start, on pull to refresh and when a note is opened
  in "watching server" mode. There is no push and no PDF anywhere in the
  pipeline.

So Nextcloud as the transport would mean a mini worker holding Sam's encryption
password, decrypting, and rendering `.sbn2` to PDF without Flutter (the strokes
are only drawn by the app's own renderer), and inbound files would sit on the
server until Sam pulled to refresh. That fails the "within seconds" and "readable
files" requirements, so it is rejected.

## Design

The app does what only it can do (render a note to PDF, build a note from a PDF)
and talks to a small service on the mini over Tailscale.

```
iPad: Quill                                    mini (sam): quill-sync
  editor save ──► FileManager.writeFile ──►      PUT /v1/file   ─► .quill/store/<path>.sbn2(.N|.p)
                    QuillSync queue      ──►      PUT /v1/pdf    ─► Notes/<path>.pdf
                    (persisted, retried)  ──►      DELETE /v1/file ─► .quill/trash/
                  ◄── long poll GET /v1/inbox ◄── Inbox/<folder>/<file> (watched)
  headless import (PDF, image, sbn2, sba) ──►     POST /v1/inbox/<id>/ack ─► .quill/delivered/
```

- **Client** (`lib/data/quill_sync/`): hooks `FileManager.writeFile`,
  `moveFile` and `deleteFile`. Every change to a note's files is queued by path
  (the queue holds the latest operation per path, persisted as JSON, so it
  survives a crash or a kill) and uploaded in full; a PDF of the note is rendered
  with the app's own exporter (`EditorExporter.generatePdf`, headless) and
  uploaded, debounced per note. A long poll on the inbox delivers new files the
  moment they appear. On every start and resume it reconciles against the
  server's manifest, which backfills notes written before sync existed and anything
  a lost queue missed.
- **Server** (`quill-sync/server.py`): Python standard library only, a
  LaunchAgent in the `sam` account on loopback `127.0.0.1:8796`, published to the
  tailnet over HTTPS by `tailscale serve --https=8796`
  (`https://sams-mac-mini.tail2add23.ts.net:8796`). HTTPS because iOS App
  Transport Security refuses plain HTTP, and tailnet only like every other `sam`
  service. A bearer token on top (`~/.config/quill-sync/token`, compiled into the
  app at install time from a mode 600 file, never an argument).
- **Faster saves.** The fork's autosave default drops from 10 s to 1 s after the
  last stroke, with a cap so continuous writing still saves every 4 s. A race in
  upstream's save (a stroke added while a save was being written was marked saved
  and never written) is fixed, and the editor now saves when the app goes to the
  background.

Why not sync the folder directly (Syncthing, Files app): iOS gives no app a
background folder sync it controls, the app's own files are not a folder another
app can watch, and the PDF still has to come from Quill.

### Folder layout on the mini

`~/quill` (local disk; the NAS is never a live sync target):

| Path | What | Written by |
| --- | --- | --- |
| `Notes/<folders>/<note>.pdf` | One PDF per note, same folders as in Quill, current within seconds. Read only (mode 444); edits here would be overwritten. | the service |
| `Inbox/<folders>/<file>` | Drop zone. A PDF, image (png, jpg, jpeg, gif, webp, heic), `.sbn2` or `.sba` put here appears in Quill in the same folder (`Inbox/School/hw.pdf` becomes the note `/School/hw`), then moves out. | Sam, agents, `quill-sync put` |
| `.quill/store/` | Native mirror of the app's notes (`.sbn2`, assets, thumbnails): a full copy of every note, for backup and restore. | the service |
| `.quill/trash/<time>/` | Notes and PDFs deleted in Quill, kept, never purged automatically. | the service |
| `.quill/delivered/<time>/` | Inbox files after Quill confirmed the import. | the service |

The native files land there too (decision: yes), because the PDF alone cannot be
turned back into an editable note, and the iPad would otherwise be the only copy.

### Into the vault

Like Notability's (2026-11-07, Sam: "it should basically mimic notability's
functionality"): every note's PDF lands in the Obsidian vault with a companion
note, in the course folder notasync would use, and the nightly sorter files it
into its week folder.

```
~sam/quill/Notes ──quill-stage──► ~console/Quill/staging ──notasync-quill──► vault ingest ──► LiveSync
 (quill-sync)     (console agent,   (mtime kept,          (notasync's image,     (container,
                   every 0.25 s)     never deletes)        second instance)       I6)
```

- `stage.py` is a LaunchAgent in the `console` account, because the router is a
  container on console's Colima, which only mounts console's home and tank.
- `notasync-quill.yaml` is notasync's config format with Notability's routes
  keyed by Quill folders: a Quill folder `Fall 26/CS 114` or just `CS 114`
  lands in `School/Fall 2026/CS 114 - ...`, anything else in `Inbox/Quill/`.
  Companion notes carry `source: quill` (and notasync's `notability_path` key,
  holding the note's path in Quill). notasync's code is not changed.
- Name clashes: notasync replaces a vault file of the same name, so a new
  Quill note whose name a file it does not own already uses (a Notability PDF)
  is staged as `<name> (Quill).pdf`, and keeps that name.
- Deletes in Quill do not delete anything in the vault (notasync's rule).
- Notes imported from Notability (2026-11-07, `quill-sync/import_notability.py`:
  all 339, same folders) are listed in `~/quill/.quill/imported`. Their PDFs are
  already in the vault, so `stage.py` holds each one back until its PDF changes
  after the first render, that is, until Sam writes in it in Quill; then it
  lands as `<name> (Quill).pdf` next to the Notability original.
- While Sam writes, Quill sends a new PDF every couple of seconds, but the
  router files a file only once it is unchanged across two passes. So
  `stage.py` replaces a note's staged copy at most every 2.5 s: the first change
  after a pause goes at once, and the vault keeps updating during writing
  instead of waiting for a pause.
- Install or update: `cat quill-sync/deploy-vault.sh | ssh mac-mini-console bash -s`
  (`-- --status` to check). Tests: `/usr/bin/python3 -m unittest test_stage`.

### Live view

`https://sams-mac-mini.tail2add23.ts.net:8796/live` (2026-11-07): a page on
the server that shows each note's PDF (rendered with pdf.js from jsDelivr) and
redraws it the moment a new one arrives, through a long poll on
`GET /v1/changes`. "Follow the note I'm writing in" switches to whichever note
changed last. Pen up to the page is about 2 s, and it keeps up while writing,
since it does not wait for the vault.

The page needs no token. `tailscale serve` adds the requester's login
(`Tailscale-User-Login`) to what it proxies to loopback, and the server lets in
logins listed in `~/.config/quill-sync/viewers` (one per line; Sam's
`sam.stuhl.personal@gmail.com`). That access is read only: the note list, PDFs
and changes (`/live`, `/v1/notes`, `GET /v1/pdf`, `/v1/changes`), never uploads,
deletes, the inbox or the native store. A process on the mini could forge the
header on loopback, but anything there can already read `~/quill`.

## Latency budget

Pen lifts to PDF current on the mini, at home on Wi-Fi:

| Step | Budget |
| --- | --- |
| autosave delay after the last stroke | 1.0 s |
| serialize and write the note | 0.1 s |
| queue pickup and native upload | 0.2 s |
| PDF render (per page about 0.2 s, 3 pages in parallel) | 0.5 s |
| PDF upload and atomic write | 0.2 s |
| **Total, target** | **under 3 s (p50), under 5 s (p95)** |

Inbound: file stable in `Inbox/` (0.5 s poll, size unchanged for one poll) plus
long poll wake plus download plus import: target under 2 s.

Measured with `quill-sync/measure.py`: each upload records the client's write
time and the server's receive time (`X-Quill-Written-At`), and the server logs
the gap per file. The inbound side logs file seen to ack.

## Conflicts and offline

- **One writer per file, so no conflicts.** The iPad is the only writer of notes;
  the mini never changes an existing note. Inbound files always become a new note
  (a name already taken gets Quill's own " (2)" suffix), never an overwrite.
- **Idempotent uploads.** Every upload is the whole current file, so retrying or
  reordering cannot corrupt anything; the newest write wins, and it is the
  iPad's.
- **Offline.** The queue persists; uploads retry with backoff (1 s doubling to
  30 s) and immediately on resume. The long poll reconnects on its own. Reconcile
  on start and resume catches anything else.
- **Duplicates.** An inbound item is marked delivered on the iPad before it is
  acked; a redelivered id is acked without importing again.
- **Deletes are never inferred.** A note missing on the iPad is not deleted on
  the mini (a reinstall would otherwise trash everything); only an actual delete in
  Quill trashes it, and the trash is kept.

## Failure modes

| Failure | What happens |
| --- | --- |
| Tailscale off on the iPad, or the mini down | Writes queue on the iPad; nothing visible; all of it lands on reconnect. |
| App killed mid-upload | Queue is persisted before the upload; it resumes on next launch. |
| App killed before a save | At most 1 s of strokes since the last pause (the editor now also saves on backgrounding). |
| Partial file dropped in `Inbox/` | Offered only once its size is stable; a failed import is not acked and retries. |
| Unsupported file in `Inbox/` | Left in place and logged; never offered. |
| Bad token or server error | Retried with backoff; logged in Quill's logs (Settings, logs). |
| Disk full on the mini | Upload fails, the queue keeps it, retried. |

## Tests ("flawless" made concrete)

Server (`quill-sync/test_server.py`, unittest, real HTTP on a random port):

1. Uploads land atomically at the mirrored path; PDFs are mode 444.
2. Repeated and out of order uploads of the same file leave the newest.
3. Delete moves the note, its assets and its PDF to trash; nothing is removed.
4. Path traversal and absolute paths are refused.
5. Missing or wrong token is refused.
6. Inbox: a file is offered once stable, long poll wakes within a second of a
   drop, unsupported files are never offered, ack moves it to delivered, and a
   second ack is harmless.
7. Manifest lists the store with mtimes.

Client (`test/quill_sync_test.dart`, against a fake server in the test):

8. Writes, moves and deletes enqueue the right operations, coalesced per path.
9. The queue survives a restart (reload from disk) and drains when the server
   comes back after failures.
10. Inbound PDF and image become real notes (pages sized from the source) in the
    right folder; a taken name gets a suffix; a redelivered id is not imported twice.
11. The autosave race: a change made during a save is saved afterwards.

End to end (manual and measured, on the mini and the iPad): write, watch
`Notes/` update, record pen lift to PDF times; drop a PDF in `Inbox/`, time it
to appear; airplane mode, write, reconnect, check nothing is lost or duplicated.

## Steps

1. Plan (this doc).
2. Server with tests; deploy on the mini as a LaunchAgent; `tailscale serve`.
3. Client module, FileManager hooks, headless import, inbox loop, lifecycle.
4. Editor: autosave default and cap, save race fix, save on background.
5. Client tests; full test run of the touched areas.
6. System map (service, store, secret) and docs.
7. Install on the iPad (USB, Terminal on the MacBook); measure end to end.

## Measured (2026-11-06)

Real app (this fork, iOS 26 simulator on the MacBook, off campus Wi-Fi over
Tailscale) against the live server on the mini, `quill-sync/run-e2e-sim.sh`:

| What | Result |
| --- | --- |
| Pen up to the note's PDF current on the mini (6 strokes, two runs) | p50 1.9 s, max 2.5 s (1 s of it is the autosave delay) |
| Native file upload, server side | well under 0.4 s |
| PDF upload, server side (`measure.py`) | p50 0.52 s, p95 0.89 s |
| File dropped in `Inbox/` to imported in the app and acked | p50 0.32 s, max 0.55 s |
| Imported PDF and image notes rendered back to `Notes/` | yes, original page content included |

Over the tailnet alone (`quill-sync/e2e.py`, MacBook as client): native 60 kB
upload p50 0.13 s, 200 kB PDF p50 0.19 s.

Into the vault (2026-11-07, a PDF uploaded through the server's API on the
mini, four runs): in the vault ingest folder with its companion note 1.9 to
2.3 s later (3.9 s before quill-stage went to 0.25 s and the router to 1 s
polls and settle), in the vault bridge's export 5.8 to 7.4 s later. The rest is
the bridge noticing the new file about 4 s after it lands, its own watcher,
shared with Notability and not changed here. Pen up to the vault is about 4 s,
to Obsidian about 8 s plus the device's own sync.

On the iPad itself (installed 2026-11-07 from the MacBook, which reached the
iPad over the network): a PDF put in `Inbox/` on the mini was a note in Quill
0.19 s later, the iPad's own render of it was back in `Notes/` 0.7 s after
that, and in the vault with its companion note about 2 s later.

Not yet measured on the iPad: pen up with a real Pencil, PDF render
cost for long notes, or behavior after hours offline. The simulator run's only
failure is the test harness under `--no-dds` (integration_test's golden
comparator stream), which `--no-dds` is needed to avoid a Flutter DDS start
failure; every app check in it passed.
