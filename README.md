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
│   └── home_screen.dart      # Skeleton UI exercising the LlmEngine stream
├── engines/
│   ├── llm_engine.dart       # LlmEngine interface + event/tool types
│   ├── stt_engine.dart       # SttEngine interface
│   ├── vision_engine.dart    # VisionEngine interface
│   ├── platform_telemetry.dart
│   ├── providers.dart        # Riverpod providers (bind fakes today)
│   └── fakes/                # In-memory implementations for tests + skeleton
└── services/
    └── database/
        ├── tables.dart               # Drift table definitions
        ├── tables/
        │   └── manual_fts_table.dart # Structured manual entries (backs the FTS index)
        ├── fts_query_sanitizer.dart  # Free text → safe FTS5 MATCH expression
        ├── database_service.drift    # FTS5 virtual table, sync triggers, ranked query
        ├── database_service.dart     # Encrypted drift database (+ .g.dart codegen)
        └── ...
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
  column, queried by equality**, and is deliberately *not* in the index. Codes
  tokenize badly — `E-102` becomes the junk token `e` plus `102`, which both
  dilutes the index and throws away the identifier's precision. Codes are
  canonicalised (trimmed, upper-cased) on write and on lookup.

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
  (engine fakes, widget smoke test).
- **Integration tier** — reserved for on-device runs against real backends
  (LLM, STT, vision) using recorded fixtures; added as those backends land.

## Tech stack

| Concern            | Choice                                             |
|--------------------|----------------------------------------------------|
| UI framework       | Flutter (Material 3)                               |
| State management   | Riverpod (`flutter_riverpod`)                      |
| Architecture       | MVVMC with engine-abstraction interfaces           |
| Local database     | drift + SQLite3MultipleCiphers (`source: sqlite3mc`) |
| Testing            | `flutter_test` (unit + widget), `integration_test` |
| CI                 | GitHub Actions                                     |

## License

Not yet specified.
