# FieldOps Copilot

An offline-first mobile application for field-service technicians maintaining
smart elevators (the fictional **Apex-9** series). It is designed to run entirely
on-device — no cellular connectivity required — combining an on-device language
model, speech-to-text, camera-based OCR, and a local full-text-searchable manual
database to help technicians diagnose faults and produce structured repair plans.

> **Status: walking skeleton.** The project currently contains the runnable app
> shell, the engine-abstraction layer, and deterministic in-memory fakes for
> every on-device capability. The real on-device backends (LLM, STT, vision) are
> not yet wired in — they slot in behind the interfaces described below.

## What's implemented so far

- **Runnable Flutter app** (iOS + Android) with a Material 3 UI and a single
  home screen.
- **Riverpod dependency injection** (`ProviderScope`) as the seam for swapping
  fakes for real on-device engines without touching upstream code.
- **Engine abstraction layer** — a Dart interface per on-device capability:
  - `LlmEngine` — streams both text tokens **and** structured tool-call events
    (`LlmToken`, `LlmToolCall`, `LlmDone`), mirroring a native function-calling
    runtime.
  - `SttEngine` — consumes a 16-bit mono PCM stream and emits partial/final
    transcripts.
  - `VisionEngine` — decodes barcodes/QR codes and OCR text from image bytes.
  - `PlatformTelemetry` — exposes device thermal state and battery status.
- **Deterministic fakes** for each engine, enabling fast, device-free unit tests
  and driving the skeleton UI.
- **Home screen** that exercises the `LlmEngine` streaming contract end-to-end
  against the fake engine (initialise → stream a scripted response token by
  token → render).
- **Seed dataset** (`assets/elevator_manual_seed.json`) — three Apex-9 manual
  entries (fault code, symptoms, procedure, required tools/parts) used to seed
  the local manual database.
- **Encrypted local database** — a [drift](https://drift.simonbinder.eu/)
  schema (technician profile, parts inventory, work orders) stored in an
  encrypted SQLite file. See _Data persistence & encryption_ below.
- **Offline manual retrieval** — an FTS5 index over the manual's prose with the
  `porter` stemmer and `bm25()` ranking, an exact-match column for fault codes,
  and a query sanitizer that stops raw dictated text from becoming an FTS5
  syntax error. See _Offline retrieval_ below.
- **Model provisioning** — download-with-progress, streaming SHA-256 verification
  against a pinned digest, atomic install into no-backup storage, and a visible
  "model ready" state on the home screen. See _Model provisioning_ below.
- **Test suite** — a widget smoke test plus unit tests for all four fakes.
- **CI** — GitHub Actions running `dart format`, `flutter analyze`, and
  `flutter test` on every push and pull request.

## Architecture

The app follows a Model–View–ViewModel–Controller (MVVMC) separation, with all
device-specific capabilities hidden behind Dart interfaces:

```
lib/
├── main.dart                 # Entry point; wraps the app in ProviderScope
├── app.dart                  # MaterialApp + theme
├── views/
│   ├── home_screen.dart      # Skeleton UI exercising the LlmEngine stream
│   └── components/
│       └── model_readiness_banner.dart  # "Are verified weights on this device?"
├── engines/
│   ├── llm_engine.dart       # LlmEngine interface + event/tool types
│   ├── stt_engine.dart       # SttEngine interface
│   ├── vision_engine.dart    # VisionEngine interface
│   ├── platform_telemetry.dart
│   ├── providers.dart        # Riverpod providers (bind fakes today)
│   └── fakes/                # In-memory implementations for tests + skeleton
└── services/
    ├── database/
    │   ├── tables.dart               # Drift table definitions
    │   ├── tables/
    │   │   └── manual_fts_table.dart # Structured manual entries (backs the FTS index)
    │   ├── fts_query_sanitizer.dart  # Free text → safe FTS5 MATCH expression
    │   ├── database_service.drift    # FTS5 virtual table, sync triggers, ranked query
    │   ├── database_service.dart     # Encrypted drift database (+ .g.dart codegen)
    │   └── ...
    └── models/
        ├── model_descriptor.dart     # What artifact to fetch, and what it must hash to
        ├── model_storage.dart        # Layout, receipts, no-backup marking
        ├── model_downloader.dart     # Streaming HTTP transport
        ├── model_provisioner.dart    # Download → verify → atomic install
        └── providers.dart            # Riverpod providers for the above
```

**Why an engine-abstraction seam?** Every heavyweight, device-dependent
capability (model inference, transcription, vision) sits behind a small Dart
interface. Unit tests inject the deterministic fakes and run in pure Dart;
on-device implementations are injected at runtime by overriding the providers in
`ProviderScope`. Nothing upstream depends on a concrete backend.

## Data persistence & encryption

Structured local data lives in an encrypted SQLite database managed by
[drift](https://drift.simonbinder.eu/) (`lib/services/database/`). The schema
covers the technician profile, the local parts inventory, and work orders.

Encryption uses **SQLite3MultipleCiphers**, bundled through the `sqlite3`
package's build hook (`hooks: user_defines: sqlite3: source: sqlite3mc` in
`pubspec.yaml`) — the current replacement for the now-legacy
`sqlcipher_flutter_libs`/`sqflite_sqlcipher` path. Because the hook bundles the
encryption-capable library on every platform (including the host), the same
cipher PRAGMAs run under `flutter test` as on device.

- **Cipher:** ChaCha20-Poly1305 (the SQLite3MultipleCiphers default, an AEAD
  scheme). AES-based schemes are also available on this stack; ChaCha20 is used
  as shipped. KDF iterations are pinned explicitly rather than left to the
  library default.
- **Keying:** the key is applied with `PRAGMA key` inside the `NativeDatabase`
  `setup` callback before any statement runs; a passphrase (KDF-derived) or a
  raw hex key (`x'…'`) is supported.
- **At rest:** the file header and row contents are ciphertext — verified by
  unit tests that assert the raw bytes carry neither the `SQLite format 3`
  magic nor plaintext row data, and that reopening with a wrong key fails.

## Offline retrieval: FTS5 + a structured fault-code column

The manual is searched locally with SQLite's **FTS5** full-text index — no vector
embedding model, no extra weights in RAM. Two lookup paths sit side by side, and
they are deliberately different:

- **Symptom prose → FTS5.** `manual_fts` indexes `title`, `symptoms`,
  `procedure` and `section` with the **`porter` tokenizer**, so morphological
  variants match: a technician's "squealing" finds "squeal", "vibrating" finds
  "vibration". `title` is indexed too — a spoken complaint echoes the heading at
  least as often as the symptom paragraph. Results are ranked with `bm25()`,
  weighted to favour a title hit over the procedure body.
- **Fault code → exact match.** The `code` column (`E-102`) is a **structured
  column, queried by equality** through `idx_manual_entries_code`, and is
  deliberately *not* in the FTS index. Codes tokenize badly — `E-102` becomes the
  junk token `e` plus `102`, which both dilutes the index and throws away the
  identifier's precision. Codes are canonicalised (trimmed, upper-cased) on
  write, and the column is `COLLATE NOCASE` so lookups stay case-insensitive
  *and* index-backed — comparing `upper(code)` instead would wrap the column in a
  function and force a full table scan.

The index is an **external-content** FTS5 table: the text is stored once in
`manual_entries`, and three triggers (`AFTER INSERT`/`UPDATE`/`DELETE`) keep the
index in sync — including the `'delete'` command that unwinds previously indexed
terms on update, so a rewritten row leaves no stale terms behind.

### Why raw user text can't reach `MATCH`

FTS5's query language is not a word list. Bare `AND`/`OR`/`NOT`/`NEAR` are
operators, `(` `)` group, `"` quotes phrases, `*` is a prefix wildcard, `:` binds
a column filter. Real dictated input — `door won't close - "stuck" (E-305)` — is
therefore not merely a bad query, it is a **syntax error**: SQLite raises
`SqliteException: fts5: syntax error near "..."` and the search fails outright.

`FtsQuerySanitizer` (`fts_query_sanitizer.dart`) strips every character that
could be syntax, wraps each surviving term in a quoted phrase (keeping
intra-word hyphens and apostrophes: `E-305`, `won't`), caps the term count, and
joins with `OR`. `OR` rather than `AND` is the deliberate choice: symptom text is
noisy, so `"squealing noise"` must still find the belt entry even though the
manual never says "noise" — recall comes from `OR`, precision from `bm25()`
ranking. Strict `AND` would let one unmatched word return nothing.

## Model provisioning

The language model is **not in this repository and cannot be**. Gemma weights are
license-gated — you accept Google's Gemma terms on HuggingFace or Kaggle and
download with a personal access token — and the artifact is 0.5–2.4GB, well past
what belongs in git or in an app-store binary. So the app ships a *description* of
the artifact it expects and fetches the bytes at runtime.

### Getting the weights (what a reviewer has to do)

1. **Accept the license** for the model you want, with the account that will issue
   the token:
   - Gemma 4 E2B (INT4, LiteRT-LM) — the primary target, ~2.4GB
   - Gemma 3 1B (INT4, LiteRT-LM) — the low-RAM alternative, ~0.5GB
2. **Create an access token** on that account.
3. **Copy the direct download URL** for the exact file you licensed, and
4. **compute its SHA-256** — `shasum -a 256 <file>` — either by downloading it once
   yourself, or from the checksum the host publishes for that revision.
5. Run with all three supplied:

```bash
flutter run \
  --dart-define=FIELDOPS_MODEL_ID=gemma-4-e2b-it-int4 \
  --dart-define=FIELDOPS_MODEL_URI=https://…/gemma-4-e2b-it-int4.litertlm \
  --dart-define=FIELDOPS_MODEL_SHA256=<64 hex chars> \
  --dart-define=FIELDOPS_MODEL_TOKEN=<access token>
```

**Why the URL and hash are build inputs rather than constants in the source.** A
URL is revision-specific and a hash is bytes-specific. Hard-coding either would
mean committing a guess about a file this repository has never downloaded — and a
wrong pinned hash is indistinguishable, at runtime, from a corrupt download. A
descriptor missing either one therefore **refuses to provision** and the home
screen says which piece is missing; it never installs weights it cannot verify.

`FIELDOPS_MODEL_ID` selects a catalog entry (file name, documented size, license
page). `FIELDOPS_MODEL_URI` and `FIELDOPS_MODEL_SHA256` apply to that active
model.

> **On the token.** A `--dart-define` token is baked into the binary — fine for a
> development or demo build, and not a shipping pattern, since anyone with the app
> has the credential. The fleet answer is in _OTA model delivery_ below.

### What provisioning actually does

1. **Nothing, if a receipt already vouches for the file.** A successful
   verification writes a small sidecar recording the digest and size, so the
   startup readiness check costs no re-hash of 2.4GB. The receipt is invalidated
   automatically if the pinned hash moves or the file's size changes.
2. **Hashes weights that are already on disk** rather than re-downloading them —
   the side-load path (see below) — and files a receipt if they match.
3. **Streams a download to a `.part` staging file, hashing as it writes.** The
   artifact is never buffered in memory and never read twice. Progress is
   reported per chunk, and degrades to an indeterminate state when the server
   declares no `Content-Length` instead of inventing a percentage.
4. **Installs only on a digest match**, by atomic rename. The path an engine loads
   from therefore only ever holds a complete, verified file.
5. **Deletes anything that fails**, reporting the digest it actually got. A body
   shorter than the declared `Content-Length` is reported as a *truncated
   transfer*, not corruption, so the operator does not go hunting for the wrong
   problem.

Storage is the **application-support directory**, not the cache directory: iOS may
evict `Library/Caches` under storage pressure, and a technician in a basement
cannot re-download 2.4GB. It is marked excluded from backup instead — multi-
gigabyte weights are reproducible from their source URL, so backing them up burns
the user's iCloud or Android backup quota for no recovery value. The two platforms
do this in completely different places, and both are wired up:

| Platform | Mechanism |
|---|---|
| iOS | `NSURLIsExcludedFromBackupKey` on the directory URL, set natively over a method channel in `ios/Runner/AppDelegate.swift` (no Flutter-side API exists) |
| Android | Declarative: `backup_rules.xml` (API ≤ 30) and `data_extraction_rules.xml` (API 31+) exclude `files/models` from cloud backup **and** device-to-device transfer — a transferred device re-verifies the SHA-256 itself rather than inheriting a receipt written on another machine |

The app reports whether the marking is genuinely in force rather than assuming it,
so it never claims a platform guarantee it did not obtain.

### Demo-day procedure

Never rely on a first-run download over venue Wi-Fi. Provision the device on a
known-good network beforehand: after one successful run the receipt makes the home
screen report **Model ready** offline, with no re-hash and no network.

The home screen distinguishes the states that need different actions — *ready*,
*present but unverified*, *not installed*, *source not configured*, *hash not
pinned* — so a glance before the demo is enough.

Weights can also be side-loaded onto a device with the platform tooling (Xcode's
device container browser; on a debuggable Android build, `adb push` followed by
`adb shell run-as com.karolkulesza.field_ops_copilot cp …` into
`files/models/`). A hand-copied file arrives with no receipt, so it reports
*present but unverified* until provisioning hashes it in place — which is the
point: bytes nobody verified are never treated as ready.

### OTA model delivery (designed, not built)

Task 1.7 is the **client half** of the delivery story, and it is deliberately the
half worth building: fetch, verify, install, report. The server half is a design
discussion rather than code — bucket layout and revision naming, device-capability
based model selection (E2B vs. 1B by available RAM), staged rollout with a kill
switch, and short-lived signed URLs issued per device by an enterprise backend so
no long-lived credential ever ships inside the app. That last one slots in behind
`modelAccessTokenProvider` without the provisioner changing at all.

Two things this deliberately does *not* do yet, both cheap to add and neither
needed for the demo: resuming an interrupted transfer with a `Range` request, and
cancelling one in flight.

## Getting started

Requires the Flutter SDK (stable channel, Dart 3.12+).

```bash
flutter pub get
flutter run
```

Tap **Run self-test** on the home screen to stream a scripted response through
the `LlmEngine` contract.

## Testing

```bash
flutter analyze
flutter test
```

Tests are split into two tiers:

- **Unit tier** (`test/`) — pure Dart, deterministic, runs in CI on every commit
  (engine fakes, database, FTS, model provisioning, widget tests). The HTTP
  transport is covered against a loopback `HttpServer` rather than a mock, because
  the behaviour worth testing is HTTP behaviour: redirect hops, `Content-Length`
  vs. chunked, and which requests carry the access token.
- **Integration tier** (`integration_test/`) — on-device runs against real
  backends. `flutter test` does not pick this directory up, so CI stays host-only.
  `model_provisioning_test.dart` (TC-PROV-E2E-01) does a real download-verify-
  install on a device; it **skips** with an actionable message unless the model
  defines above are supplied, because the weights are license-gated and CI must
  never try to fetch them.

## Tech stack

| Concern            | Choice                                             |
|--------------------|----------------------------------------------------|
| UI framework       | Flutter (Material 3)                               |
| State management   | Riverpod (`flutter_riverpod`)                      |
| Architecture       | MVVMC with engine-abstraction interfaces           |
| Local database     | drift + SQLite3MultipleCiphers (`source: sqlite3mc`) |
| Model delivery     | `dart:io` streaming download + `crypto` SHA-256 verify, no-backup storage |
| Testing            | `flutter_test` (unit + widget), `integration_test` |
| CI                 | GitHub Actions                                     |

## License

Not yet specified.
