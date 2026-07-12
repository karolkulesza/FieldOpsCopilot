# FieldOps Copilot

An offline-first mobile application for field-service technicians maintaining
smart elevators (the fictional **Apex-9** series). It is designed to run entirely
on-device — no cellular connectivity required — combining an on-device language
model, speech-to-text, camera-based OCR, and a local full-text-searchable manual
database to help technicians diagnose faults and produce structured repair plans.

> **Status: vertical slice under construction.** The runnable app shell, the
> engine-abstraction layer, the encrypted database, offline retrieval, model
> provisioning, the **on-device LLM engine**, the **agent loop** that ties
> retrieval to inference, and the **golden snapshot suite** that pins the whole
> transcript on every CI run are in place. STT and vision are still fakes, and
> the demo screen that puts the loop on screen is the next task — it slots in
> behind the interfaces described below.

## What's implemented so far

- **Runnable Flutter app** (iOS + Android) with a Material 3 UI and a single
  screen: type a fault, tap **Diagnose**, watch the on-device model stream a
  grounded repair plan and check the local warehouse on the way. See _The demo
  screen_ below.
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
- **Deterministic fakes** for each engine, enabling fast, device-free unit tests.
  They are reachable only by *overriding a provider in a test* — the production
  graph never falls back to one, because an app that answers fluently from a
  script on a device where the model never ran is indistinguishable from a working
  app in a screen recording.
- **Seed dataset** (`assets/elevator_manual_seed.json`) — three Apex-9 manual
  entries (fault code, symptoms, procedure, required tools/parts) and five parts
  inventory rows, applied to the local database on first launch.
- **First-launch seeding** — a validated, transactional loader that applies the
  bundled dataset once, records what it applied, and does not overwrite stock a
  technician has changed. See _First-launch seeding_ below.
- **Encrypted local database** — a [drift](https://drift.simonbinder.eu/)
  schema (technician profile, parts inventory, work orders) stored in an
  encrypted SQLite file. See _Data persistence & encryption_ below.
- **Offline manual retrieval** — an FTS5 index over the manual's prose with the
  `porter` stemmer and `bm25()` ranking, an exact-match column for fault codes,
  and a query sanitizer that stops raw dictated text from becoming an FTS5
  syntax error. See _Offline retrieval_ below.
- **Hybrid retrieval routing & prompt compilation** — the router that extracts
  fault codes from free text, sends them to the structured column, full-text
  searches the remainder and merges the two code-hits-first; and the compiler
  that turns the result into the grounded `[MANUAL DOCUMENT]` / `[USER INQUIRY]`
  prompt, including the no-match block that tells the model not to invent one.
  See _Hybrid retrieval routing_ below.
- **Agent tool registry** — Dart-native tools declared to the model in
  plugin-native format and validated at registration, plus the dispatcher that
  routes a structured tool-call event to its executor. Ships
  `get_local_parts_inventory` over the local warehouse table. Anything the model
  got wrong (unknown tool, missing or mistyped argument, unstocked SKU) comes
  back as a payload the agent loop can feed back, not as a throw. See _Agent
  tools_ below.
- **Defensive tool-call guard** — the degraded path into the registry: it
  validates a native tool-call event, extracts a call the model emitted as prose
  or JSON text instead of native tokens, canonicalises a near-miss tool name, and
  reports "there is no tool call here" as a typed value rather than a throw. See
  _The defensive tool-call guard_ below.
- **Agent orchestration loop** — grounded prompt → model → native tool call →
  local execution → result fed back → grounded answer, with a hard turn cap and
  a repeat-call short circuit. Because `generate()` is a stateless single turn,
  the loop carries the conversation as text, and the transcript it appends is
  built so the model cannot forge the loop's own block markers. See _The agent
  loop_ below.
- **`llm_golden` snapshot suite** — six scripted agent runs whose entire
  transcript (retrieval, every prompt sent, every token returned, every tool call
  and its payload, the event sequence and the stop reason) is committed as JSON
  and compared byte-for-byte on every CI run. Catches the regressions a property
  test never thinks to assert: a reworded preamble, a reordered document field,
  a fault code that stopped resolving. See _Golden transcripts_ below.
- **Model provisioning** — download-with-progress, streaming SHA-256 verification
  against a pinned digest, atomic install into no-backup storage, and a visible
  "model ready" state on the demo screen, with the trigger to fetch and verify.
  See _Model provisioning_ below.
- **The demo screen, and the end-to-end wiring under it** — the encrypted database
  opened with a real key, the first-launch seed triggered as a *dependency* rather
  than a call order, the device engine loaded before the UI needs to be
  interactive, and a Riverpod viewmodel folding the agent loop's event stream into
  UI state. This is the screen the portfolio recording is made from. See _The demo
  screen_ below.
- **On-device inference** — **Gemma 4 E2B** in a `.litertlm` container, run
  through `flutter_gemma` + `flutter_gemma_litertlm` (LiteRT-LM over `dart:ffi`)
  on a dedicated background isolate, behind the same `LlmEngine` interface the
  fake implements. Tool calls arrive as the model's **native function-call
  tokens**, not as prompt-engineered JSON. See _On-device inference_ below.
- **Microphone capture** — 16-bit little-endian mono PCM at 16 kHz off the device
  microphone via `package:record`, behind an `AudioInput` seam. A bounded backlog
  so a stalled recogniser cannot grow audio without a ceiling, and a per-frame gap
  count so audio lost that way cannot be lost *silently*. See _Microphone capture_
  below.
- **Test suite** — a host tier covering the engine fakes, database + FTS, model
  provisioning, the inference isolate and its wire protocol, and widgets; plus an
  on-device integration tier for the model itself. (Deliberately no count here: the
  number went stale in three consecutive review rounds. `flutter test` is the source of
  truth, and per-task counts live in the sprint plan, which is a dated snapshot.)
- **CI** — GitHub Actions running a codegen-freshness gate (`build_runner build`
  followed by `git diff --exit-code` plus an untracked-output check, since generated
  Drift code is committed and can drift from its sources), then `dart format`,
  `flutter analyze`, and `flutter test` on every push and pull request. Reproducing
  the gate locally needs a **cold** build: with a warm `.dart_tool/build` cache
  build_runner writes zero outputs and leaves a stale in-source file alone, so the
  check passes without having verified anything.

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
│   ├── tool_schema.dart      # The JSON-Schema shape a tool must declare
│   ├── providers.dart        # Riverpod providers (bind fakes today)
│   ├── impl/
│   │   └── gemma_llm_engine.dart  # Real LlmEngine: Gemma 4 on an isolate
│   └── fakes/                # In-memory implementations for tests + skeleton
│                             #   (enforce the same rules as the device engine)
└── services/
    ├── inference/
    │   ├── inference_config.dart    # Model path, family, backend, context window
    │   ├── inference_protocol.dart  # Encoded messages across the isolate boundary
    │   ├── inference_isolate.dart   # The worker: load / generate / stop / shutdown
    │   ├── gemma_runtime.dart       # The only file that imports flutter_gemma
    │   └── providers.dart           # Riverpod providers for the above
    ├── database/
    │   ├── tables.dart               # Drift table definitions
    │   ├── tables/
    │   │   └── manual_fts_table.dart # Structured manual entries (backs the FTS index)
    │   ├── fts_query_sanitizer.dart  # Free text → safe FTS5 MATCH expression
    │   ├── seed_data.dart            # Seed asset → validated rows (no DB access)
    │   ├── database_initializer.dart # First-launch seeding, transactional
    │   ├── database_service.drift    # FTS5 virtual table, sync triggers, ranked query
    │   ├── database_service.dart     # Encrypted drift database (+ .g.dart codegen)
    │   └── ...
    ├── rag/
    │   ├── retrieval_router.dart     # Free text → code lookup + FTS, merged code-first
    │   └── prompt_compiler.dart      # Retrieval → the grounded [MANUAL DOCUMENT] prompt
    ├── ai/
    │   ├── base_tool.dart            # AgentTool contract, typed arguments, ToolOutcome
    │   ├── tool_registry.dart        # Declares tools to the model; routes calls back
    │   ├── tool_call_guard.dart      # Degraded path: malformed events, calls as text
    │   └── tools/
    │       └── get_parts_inventory_tool.dart  # Offline warehouse lookup by SKU
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
covers the technician profile, the local parts inventory, work orders, the manual
entries backing the FTS index, and a record of which seed dataset has been applied
(schema version 3).

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

## First-launch seeding

The manual and the parts inventory ship as one bundled asset
(`assets/elevator_manual_seed.json`) and are written into the encrypted database by
`DatabaseInitializer.ensureSeeded()`. Three decisions are worth naming, because each
one is answering a way this could go quietly wrong.

**The asset's structure is validated before anything is written.** It is a build
input in the same sense as the model's URL and digest — it lives inside the bundle
and nothing at runtime can repair it — so `SeedBundle.parse` rejects anything the
loader could not honestly apply: wrong shapes and types, missing or blank required
fields, out-of-range `stock`, values longer than the column that will store them,
and duplicate or whitespace-padded keys. It does not validate *meaning*: a manual
citing an unstocked SKU parses fine.

The authoritative list is `SeedBundle.parse`'s docstring, deliberately not repeated
here — this paragraph carried its own copy for two commits and was wrong in both,
first by claiming completeness it did not have and then by omitting the three rules
that gave it completeness.

Two of those rules are worth their own line, because the reason is not obvious:

- **Duplicates are an error rather than a silent dedup.** The write is an upsert, so
  a duplicated id would seed one row short of what the asset appears to declare and
  nothing downstream would look wrong. A whitespace-padded `id` is rejected for the
  same reason — `id` is the primary key and, unlike `code`/`sku`, is deliberately not
  canonicalised, so `"m1"` and `"m1 "` would otherwise pass the duplicate check as
  distinct and produce two manual entries nothing could tell apart.
- **Lengths are checked here rather than left to the column.** Drift's `withLength`
  check runs at insert time, which is *inside* the seeding transaction — correct
  behaviour, but too late to be a parse error. (The bounds are duplicated between
  `kSkuMaxLength`/`kPartNameMaxLength` and the `withLength` literals out of necessity:
  `drift_dev` reads those arguments from the source expression and silently drops a
  named constant, emitting no max at all. A test pins the two together.)

**Seeding runs once, not on every launch.** A `seed_markers` row records which
dataset revision was applied. This is not an optimisation — `inventory_parts.stock`
is operational data that the agent reads and that consuming a part decrements, so
re-applying the asset at every start would roll a technician's work back silently.
Bumping the asset's `revision` re-seeds deliberately, overwriting both the manual
text and the stock levels; a real fleet would *sync* inventory rather than seed it,
which is the offline-sync design in the "narrate, don't build" section.

A re-seed is **upsert-shaped, not replace-shaped**, and the difference is worth
knowing before anything relies on it: rows present in the new asset are overwritten,
but a row *dropped* from the asset survives in the database (a removed manual stays
searchable), and a key omitted from a row — `location`, say — is left at its old
value rather than cleared, because drift leaves absent columns out of the
`DO UPDATE SET`. Deleting content therefore needs a migration, not a revision bump.

**The write is one transaction.** Manuals, inventory and the marker commit together
or not at all. A seed that inserted the manuals and then failed on the inventory
would leave a database that looks healthy, holds a marker it has not earned, and is
therefore skipped forever after.

Two smaller details that carry more weight than they look like:

- **Manual rows go through `upsertManualEntries`**, which is `ON CONFLICT DO
  UPDATE` — *not* `INSERT OR REPLACE`. OR REPLACE deletes the conflicting row
  implicitly, and with `recursive_triggers` off (SQLite's default) that delete
  fires no trigger, so on a **re-seed** the replaced row's terms would stay in the
  FTS index permanently. `COUNT(*)` cannot see that; only a search for a term that
  lived solely in the replaced text can.
- **`inventory_parts.sku` is `COLLATE NOCASE`**, and lookups go through
  `normalizeSku` (trim + upper-case). The two are not the same mechanism: the
  normalisation is what makes a model-supplied `" brk-990-xp "` match, and the
  collation is the backstop for a row written past the normaliser by some other
  path. The collation also keeps equality searchable through the primary-key index,
  which an `upper(sku)` comparison in the query would not.

Schema **v3** carries both of those: it creates `seed_markers` and rewrites
`inventory_parts` to attach the collation (SQLite has no `ALTER COLUMN`, so a
collation change is a table rewrite). As in v2, `Migrator.createTable` creates the
table only — anything else has to be created explicitly, or upgraded installs
diverge from fresh ones.

## Hybrid retrieval routing & the grounded prompt

The previous two sections describe two lookup mechanisms; this one is the code
that decides between them. `RetrievalRouter` (`lib/services/rag/`) turns raw
technician text into a set of grounding documents, and `PromptCompiler` turns
those into the string the model actually sees.

### What the router does

1. **Pull fault codes out of the text** and look each one up on the structured,
   indexed `code` column — exact match, never FTS.
2. **Search what is left.** The spans of codes that *resolved* are cut out before
   the text reaches `FtsQuerySanitizer`; the residual is sanitized and matched.
3. **Merge, code hits first, de-duplicated.** A document both legs found appears
   once, in the code leg's position.

Two things about that are worth more than a bullet.

**A code that resolves is cut from the residual; a code that misses is left in
it.** The code pattern is deliberately loose — `E-102`, `E102`, `e 102`, and the
unicode-dash forms a dictation layer can produce — because the alternative is a
technician's `E 102` silently missing the structured column. Loose means false
positives: `Torx T20` reads as a candidate. So a candidate changes nothing until
it has been *verified by lookup*. A miss costs one indexed query returning
`null`, and the words stay searchable — which in that example is what finds the
right entry anyway, since the E-102 procedure names the Torx T20 driver. Cutting
candidates unconditionally would delete real search terms to buy nothing.

**A code-only query has no residual, and an empty `MATCH` is a syntax error**
rather than an empty result. `"E-102"` therefore takes the code leg alone and
never builds an expression. The guard itself lives in
`DatabaseService.searchManualEntriesByTerms` (Task 1.2 put it on the expression
builder for exactly this caller); the router's own branch just avoids the round
trip.

`RetrievalResult` records which leg produced what — `codeHitIds`, `ftsHitIds`,
`resolvedCodes`, `unresolvedCodes`, `searchedTerms` — rather than only the merged
list. That is not diagnostics for its own sake: `entries.length >
codeHitIds.length` looks like a test for "did full text contribute" and is not
one, because when every full-text hit is also a code hit the merged list grows by
nothing. The router shipped with that bug for one commit.

### What the prompt looks like

The layout is the product spec's §5.2 — preamble, `[MANUAL DOCUMENT]` block,
`[USER INQUIRY]` block — and the model is told to answer **only** from the
document block.

```text
You are an offline Field Service Assistant.
Based ONLY on the verified technical manual document below, answer the user's inquiry and formulate a repair plan.
If parts are required, you MUST call the "get_local_parts_inventory(sku)" tool to check warehouse stock.

[MANUAL DOCUMENT]
Title: Door Clutches & Belt Slippage (Code: E-305)
Section: Door Operators
Symptoms: Elevator doors cycle three times and throw obstruction warning, belt squealing during door open sequences, fault code E-305.
Procedure: 1. Switch door operator controller to Manual. …
Required Parts: BELT-330-DRV
Required Tools: Microfiber Cloth, Wrench 10mm, Steel Ruler

[USER INQUIRY]
"door clutch belt slipping, E-305"
```

**An empty retrieval still gets a document block.** When nothing matched, the
`[MANUAL DOCUMENT]` header is followed by an explicit "no entry was found, do not
invent a procedure, a part number, a tool or a fault code, and do not call any
tool". Omitting the block would leave a preamble pointing at a document that is
not there — which is the shape that invites the model to supply the missing
content from its weights, i.e. the exact failure this whole retrieval path
exists to prevent.

**The inquiry is untrusted; the manual text is not.** Manual prose comes from the
bundled asset that `SeedBundle.parse` validated — `upsertManualEntries` is the
trust boundary, and this asymmetry stops being safe the day anything writes
`manual_entries` from a non-asset source. The inquiry is not validated, so a
technician who types (or, in Tier 2, has transcribed) `[MANUAL DOCUMENT]` could
otherwise open a second, fabricated "verified" block inside their own question.
`PromptCompiler.neutralizeMarkers` rewrites **every Unicode opening/closing
punctuation character** (`\p{Ps}` / `\p{Pe}`) in the inquiry to a plain round
bracket, keeping the words so the diagnosis does not lose them.

That rule arrived in two corrections, and both are worth carrying because they
are the same mistake at different depths. The first version matched the marker
spellings case-insensitively, and review broke it with a single extra space
(`[MANUAL  DOCUMENT]`) — then a leading space, a tab and a newline. The second
replaced the pattern with `replaceAll('[', '(')` and justified it by saying a
pattern guard "would still have left the homoglyph variants" — while knowing
exactly one codepoint, so `［MANUAL DOCUMENT］` walked straight through. Review
caught that too, and caught the test that was supposed to cover it using ASCII
brackets around fullwidth *letters*, which exercises nothing new.

Matching on the general categories is what stops that recurring: it is a
property of Unicode rather than a list someone maintained. **The residual is
named rather than papered over**, and it is broader than one example suggests:
bracket pieces and corner brackets (`⎡`, `⌜`), the quotation-class guillemets
(`«` `»`) and plain `<` `>` are all outside `Ps`/`Pe` and all survive, as does a
header written with no delimiter at all. A test pins each of them, plus the
counter-case that keeps the boundary honest — the CJK corner bracket `「` *is*
`Ps` and *is* rewritten, so the list cannot be read as "CJK punctuation
survives".

Those survivors are listed without their general-category names deliberately.
The previous version labelled them, and one label was wrong — U+23A1 is `Sm`,
not `So` — which travelled through this file, a doc comment, a test comment and
a review turn before anyone ran it past `unicodedata`. The rule asks exactly one
question, `Ps`/`Pe` membership, and the test answers it behaviourally; the
category names were decoration that nothing checked.

None of the survivors is a homoglyph of `[`, which is the class that actually
forges these delimiters and is closed. The rest is the general look-alike case
below.

**It is still a block-boundary defence, not a prompt-injection cure** — nothing
here stops a user simply *asking* the model to ignore its instructions, and it
should not be described as if it did.

**Documents are capped** (`maxDocuments`, default 2). Task 1.8 measured a
~400-token grounded prompt for a single entry, and the router can return one row
per resolved code plus its full-text hits. The cap truncates from the end, so the
code hits — which the merge puts first — are the last thing dropped.

### Not wired into the app

Like the seeding engine before it, this is a library with tests and no
production call site: binding a `DatabaseService` needs an encryption key, which
Task 1.1 deferred to the demo screen. Task 1.11 owns the key, the seed trigger
and the wiring; Task 1.9's agent loop is the first consumer of the compiled
prompt.

## Model provisioning

The language model is **not in this repository and cannot be**. The artifact is
0.6–2.6GB, well past what belongs in git or in an app-store binary, and its use is
governed by [Google's Gemma terms](https://ai.google.dev/gemma/terms). So the app
ships a *description* of the artifact it expects and fetches the bytes at runtime.

Whether a **download** needs an access token is a per-repository fact, not a
property of Gemma, and this is worth stating precisely because the task this was
built from assumed otherwise. Measured against the live hosts on 2026-07-30: the
LiteRT-LM rebuild `litert-community/gemma-4-E2B-it-litert-lm` reports
`gated: false` and serves an anonymous request, while
`litert-community/Gemma3-1B-IT` reports `gated: auto` and does need a token.
Accepting the licence still governs *using* the model either way. Provisioning
therefore treats the URL and the token as independent inputs and assumes neither.

### Getting the weights (what a reviewer has to do)

1. **Accept the [Gemma terms](https://ai.google.dev/gemma/terms)** — this governs
   use of the model regardless of how you obtain it.
2. **Pick the artifact.** LiteRT-LM builds live in repositories separate from the
   base models; `litert-community` publishes the current ones (on HuggingFace,
   [search `gemma litert`](https://huggingface.co/models?search=gemma+litert)). The
   two this catalog names:

   | Target | Repository → file | Size | Token |
   |---|---|---|---|
   | Gemma 4 E2B — primary | `litert-community/gemma-4-E2B-it-litert-lm` → `gemma-4-E2B-it.litertlm` | 2.59 GB | not needed |
   | Gemma 3 1B — low-RAM fallback | `litert-community/Gemma3-1B-IT` → `gemma3-1b-it-int4.litertlm` | 0.58 GB | needed (`gated: auto`) |

   The same repositories also carry NPU-specific builds (`_Google_Tensor_G5`,
   `_qualcomm_*`, `_intel_*`) and `-web` variants; the plain file is the portable
   one.
3. **Get the SHA-256.** Hashing the artifact always works and is the answer if
   anything below is ambiguous:

   ```bash
   shasum -a 256 <file>
   ```

   For a **public** repository you can skip the download entirely, because
   HuggingFace publishes the LFS object id, which is the content digest:

   ```bash
   curl -s -X POST \
     https://huggingface.co/api/models/litert-community/gemma-4-E2B-it-litert-lm/paths-info/main \
     -H 'Content-Type: application/json' \
     -d '{"paths":["gemma-4-E2B-it.litertlm"]}' | jq -r '.[0].lfs.oid'
   ```

   For a **gated** repository this shortcut does not work unauthenticated, in two
   different ways worth knowing before you trust the output: `paths-info` answers
   `401 Access to model … is restricted`, and `…/tree/main` answers with the real
   file size but the digest **redacted to 64 asterisks** — the right length for a
   SHA-256, which is exactly what makes it easy to paste by mistake. Add
   `-H "Authorization: Bearer $HF_TOKEN"`, or just hash the file.

   If a published digest and your local hash disagree, **resolve it before
   pinning** — do not pick one. It means either the host rotated the file at that
   ref (pin a revision instead: `…/resolve/<commit-sha>/…`, where the `sha` comes
   from `GET /api/models/<repo>`, which is better practice than `main` for a
   reproducible build anyway) or your local copy is damaged or partial (re-fetch and
   re-hash). Pinning a digest the source does not serve makes **every** download
   fail as `ModelCorrupt`, and the report will blame bytes the host sent correctly.

   The one thing that cannot happen quietly is a *malformed* pin: only 64 lower-case
   hex characters count as pinned, so a redacted or truncated value is reported as
   "hash not pinned" and nothing is ever fetched, rather than surfacing later as a
   phantom corruption.
4. **Run with the URL and hash supplied** (add `FIELDOPS_MODEL_TOKEN=<token>` only
   for a gated source):

```bash
flutter run \
  --dart-define=FIELDOPS_MODEL_ID=gemma-4-e2b-it-int4 \
  --dart-define=FIELDOPS_MODEL_URI=https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm \
  --dart-define=FIELDOPS_MODEL_SHA256=181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c
```

Point at the `huggingface.co/…/resolve/…` URL rather than the CDN URL it redirects
to — the latter is signed and short-lived. That redirect is cross-origin, which is
the case the transport's credential scoping exists for: a token, if you supply one,
is not forwarded to the download host.

**Why the URL and hash are build inputs rather than constants in the source.** A
URL is revision-specific and a hash is bytes-specific. Hard-coding either would
mean committing a guess about a file this repository has never downloaded — and a
wrong pinned hash is indistinguishable, at runtime, from a corrupt download. A
descriptor missing either one therefore **refuses to provision** and the home
screen says which piece is missing; it never installs weights it cannot verify.

The same reasoning applies to the license link the app shows an operator: it points
at the Gemma terms, which resolve, rather than at a repository path — model hosts
answer `401` for gated *and* non-existent repositories alike, so a repository URL
written into the source could not be validated even in principle.

`FIELDOPS_MODEL_ID` selects a catalog entry (file name, documented size, license
page). `FIELDOPS_MODEL_URI` and `FIELDOPS_MODEL_SHA256` apply to that active
**LLM** — the STT model below needs no defines at all.

> **On the token.** A `--dart-define` token is baked into the binary — fine for a
> development or demo build, and not a shipping pattern, since anyone with the app
> has the credential. The fleet answer is in _OTA model delivery_ below.

### The second model: a committed STT file set (Task 2.0)

Task 2.2 needs a **second** model resident — a streaming speech-to-text
zipformer — and Task 2.0 extends provisioning to carry it. It differs from the
LLM in both of the ways that shaped 1.7, and each difference is deliberate:

* **It is a set of four files, not one** — served individually from the
  repository, not as an archive, so there is no unpacking step and no
  partial-extraction failure mode. Each file carries its own pinned SHA-256; the
  set is `ready` only when *every* file is present and vouched for, and an
  install that fails on file 3 of 4 installs nothing.
* **Its source and pins are committed in the catalog**, because
  [`csukuangfj/sherpa-onnx-streaming-zipformer-en-20M-2023-02-17`](https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-en-20M-2023-02-17)
  is `apache-2.0` and ungated (`gated: false`, measured via the HuggingFace API,
  2026-08-10). Gemma's URL and hash are build inputs *because that artifact is
  licence-gated*; where the gate does not exist, committing the config is
  strictly better — no token, no `--dart-define`, and TC-PROV-CFG-01 pins that
  the two configuration paths stay independent.

  | File | Size | SHA-256 source |
  |---|---|---|
  | `encoder-epoch-99-avg-1.int8.onnx` | 42.85 MB | LFS object id via `paths-info` |
  | `decoder-epoch-99-avg-1.int8.onnx` | 0.54 MB | LFS object id via `paths-info` |
  | `joiner-epoch-99-avg-1.int8.onnx` | 0.26 MB | LFS object id, cross-checked by hashing the served bytes |
  | `tokens.txt` | 5 KB | non-LFS, downloaded and hashed directly |

The home screen's readiness banner shows **one row per provisioned model**, each
with its own status and its own download/verify action. The rows are independent
on purpose: the agent runs on the LLM alone, so a missing STT set renders as one
warning row while Diagnose stays enabled (TC-PROV-MULTI-01).

**On-disk layout moved to per-model directories** —
`models/<model id>/<file>` with a `<file>.receipt.json` sidecar each — because
two models' files must not be able to collide. A Task 1.7 flat-layout install
(the demo iPad's 2.59GB Gemma) is migrated by `rename` on the first status
check: same volume, milliseconds, no re-download, and the receipt moves with its
file so the install stays `ready` without re-hashing.

### What provisioning actually does

1. **Nothing, if a receipt already vouches for the file.** A successful
   verification writes a small sidecar recording the digest and size, so the
   startup readiness check costs no re-hash of 2.6GB. The receipt is invalidated
   automatically if the pinned hash moves or the file's size changes. It is a cache
   of a verification, not a security control — it sits in the same app-writable
   directory as the weights, which is why `ready` means "verified earlier, cheaply
   re-confirmed" and an explicit re-hash is a separate operation.
2. **Hashes weights that are already on disk** rather than re-downloading them —
   the side-load path (see below) — and files a receipt if they match.
3. **Fetches a replacement if that hash fails**, in the same call. This is the
   ordinary upgrade path: the pin moves to a new revision while the old artifact
   is still installed. The old file is left in place *until* the new bytes have
   verified, so a device that cannot reach the network is never stripped of the
   only weights it has — and it is never loadable in the meantime either, because
   no receipt vouches for it.
4. **Streams every file of the set to a per-transfer `.part.<nonce>` staging
   directory, hashing as it writes.** No file is ever buffered in memory or read
   twice, and each file's digest is checked against its own pin *as its transfer
   ends* — a wrong pin on file 3 of 4 fails there, not after the whole set.
   Progress is aggregated across the set (with the file position, so the UI can
   say "file 2 of 4"), and degrades to an indeterminate state when a total is
   genuinely unknown instead of inventing a percentage. Every request asks for
   `Accept-Encoding: identity` and a content-encoded response is rejected by
   name: the pinned digest describes the artifact *as published*, so an inflated
   body would be the wrong bytes to hash.
5. **Installs only after every file's digest matches**, renaming staged files
   into the model's directory one by one — each rename an atomic replace, each
   file earning its receipt as it lands. The path an engine loads from therefore
   only ever holds complete, verified files; a transfer that dies partway
   installs nothing and leaves any previous install untouched. (A crash *between
   two renames* can leave a mixed set on disk; the new files have no receipts
   yet, so the set reads `unverified` and the next pass re-hashes in place —
   never `ready` over bytes nothing vouched for.) Operations on one model are
   serialised, so two overlapping calls cannot interleave into each other's
   files; two *different* models do not queue behind each other.
6. **Deletes fetched bytes that fail**, reporting the digest it actually got and
   whether the bytes came from the network or from disk. A body that does not match
   the declared `Content-Length` is reported as a *truncated* or *over-long
   transfer* rather than corruption, so the operator does not go hunting for the
   wrong problem.

Storage is the **application-support directory**, not the cache directory: iOS may
evict `Library/Caches` under storage pressure, and a technician in a basement
cannot re-download 2.6GB. It is marked excluded from backup instead — multi-
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

> **A note for whoever wires the provisioning trigger.** Because a local copy that
> fails the pin is now replaced rather than merely deleted, a *wrong* pinned hash
> (an operator typo) costs a full re-download before it fails, every call. That is
> the right trade-off for the upgrade path, but it means `provision()` should not be
> called unconditionally in a retry loop: treat a `ModelCorrupt` whose origin is the
> download as sticky until the configuration changes.

Weights can also be side-loaded onto a device with the platform tooling (Xcode's
device container browser; on a debuggable Android build, `adb push` followed by
`adb shell run-as com.karolkulesza.field_ops_copilot cp …` into
`files/models/<model id>/` — the per-model directory, since Task 2.0). A
hand-copied file arrives with no receipt, so it reports *present but unverified*
until provisioning hashes it in place — which is the point: bytes nobody
verified are never treated as ready. A file dropped at the old flat
`files/models/` path also still works: the first status check migrates it into
the model's directory by rename.

### OTA model delivery (designed, not built)

Task 1.7 is the **client half** of the delivery story, and it is deliberately the
half worth building: fetch, verify, install, report. The server half is a design
discussion rather than code — bucket layout and revision naming, device-capability
based model selection (E2B vs. 1B by available RAM), staged rollout with a kill
switch, and short-lived signed URLs issued per device by an enterprise backend so
no long-lived credential ever ships inside the app. That last one slots in behind
`modelAccessTokenProvider` without the provisioner changing at all.

The transport is a first-party `dart:io` downloader rather than the model plugin's
network-install API (the sprint plan mentions the latter): `flutter_gemma` is not a
dependency until Task 1.8, and keeping the transfer here means the credential
scoping and the verification order are covered by this repo's own tests against a
loopback server. If 1.8 prefers the plugin's installer, it slots in behind
`ModelDownloader` with those tests still guarding the contract.

Two things this deliberately does *not* do yet, both cheap to add and neither
needed for the demo: resuming an interrupted transfer with a `Range` request, and
cancelling one in flight. A cross-process lock is a third — provisioning serialises
callers within one `ModelProvisioner` (the app has exactly one), which covers every
in-app path but not two OS processes writing the same directory.

## On-device inference

The language model is **Gemma 4 E2B** in a `.litertlm` container, executed by
[`flutter_gemma`](https://pub.dev/packages/flutter_gemma) with the
[`flutter_gemma_litertlm`](https://pub.dev/packages/flutter_gemma_litertlm)
engine — Google's LiteRT-LM runtime reached over `dart:ffi`. It sits behind the
same `LlmEngine` interface the fake implements, so nothing upstream of the
interface knows which is bound.

### Model selection

| Model | Size | Tool calling | Role here |
|---|---|---|---|
| **Gemma 4 E2B** (`.litertlm`) | 2.59 GB | **Native** function-call tokens | Shipped |
| Gemma 3 1B (`.litertlm`) | 0.58 GB | Prompt-injected declaration, JSON parsed back out | Low-RAM fallback, same interface |
| FunctionGemma 270M | 284 MB | Native, tool-calling specialist | Not shipped — see below |

The fallback is a one-line configuration change (`GemmaModelFamily.gemma3`)
because the two differ in *mechanism*, not in interface: Gemma 4 has the SDK
render tool declarations into `<|tool>` tokens and answers with native
tool-call tokens, while Gemma 3 gets a textual declaration in its prompt and has
JSON parsed back out of its output. Both surface as the same structured
`LlmToolCall`.

FunctionGemma 270M is worth naming even though it is not shipped: a 284 MB
tool-calling specialist is very attractive for this workload, and the reason to
pass on it is that the demo needs one model that can *both* choose a tool and
write a grounded repair plan in prose. Two models would mean two sets of weights
resident, which is the memory budget this architecture is trying to protect.

### Why the engine runs on its own isolate

`IsolateInferenceHost` spawns a dedicated isolate and speaks a four-message
protocol to it — load, generate, stop, shutdown — with every message encoded as
a plain map so the wire format is unit-testable on the host.

Being precise about what this buys, because the plugin is not naïve about
threading either: LiteRT-LM already runs engine and conversation creation inside
`Isolate.run`, and streams generated chunks from a native decode thread through
a `NativeCallable.listener`. Part of what the boundary guarantees, the plugin
already happens to do.

"Happens to do" is the point. The frame-budget promise has to survive a plugin
upgrade, a swap to the MediaPipe `.task` engine (whose threading is not the
same), and a fallback model. An isolate at *this app's* seam is a guarantee about
our own architecture rather than a bet on a dependency's internals — and it
additionally contains a crash: an uncaught error in the worker arrives as a
message on a port instead of taking the UI isolate down. The device suite
measures the claim rather than asserting it, by ticking a 16 ms timer on the UI
isolate throughout the model load and reporting the worst gap.

Two consequences worth knowing. The worker needs the root isolate's
`RootIsolateToken` (passed at spawn) because the plugin reaches
`path_provider` and `shared_preferences` over platform channels, and those do
not work on a background isolate without it. And generation is deliberately
**serialised**: an overlapping turn is refused rather than queued, because the
engine runs one conversation at a time and a queued turn would silently inherit
the delay of the one ahead of it.

### Tool calling

Tools are declared as `ToolDefinition`s whose `parameters` map is a JSON-Schema
object, validated at registration by `tool_schema.dart`. That validation earns its
place because the same map feeds two consumers that read it completely differently,
and neither rejects a bad one:

- **Gemma 4** — the map goes to the SDK untouched as `tools_json`, and a native
  template renders the declaration from it. Passing tools also switches on
  constrained decoding, so a malformed schema is at least as likely to fail inside
  the native engine as to produce a usable declaration — with no Dart stack to read.
- **Gemma 3** — no native declaration; the plugin writes the map into the prompt
  *verbatim*. A plausible-looking `{'sku': 'String'}` neither throws nor degrades. It
  teaches the model a shape nothing downstream agrees with, and the tool call comes
  back with arguments the registry cannot read.

Either way the symptom appears two layers away as "the model is bad at tool calling",
so the shape is checked where the mistake is.

A second plugin detail is equally quiet, and what it gates depends on the family:
`supportsFunctionCalls` must be set whenever tools are passed. On Gemma 4 the
declaration reaches the model regardless, but `InferenceChat` only *reads back* the
structured calls when the flag is true — so the model emits a perfectly good tool call
that is parsed and then dropped. On the Gemma 3 fallback the flag gates the
declaration too: the tools are never mentioned to the model at all, and the plugin
logs "Tools will be ignored".

### What the engine does not do yet

Each `generate()` call is one **stateless** turn: a fresh chat, no history from
the previous call. That is what the fake does and what the golden suite depends
on — every committed transcript's second prompt **begins with the first prompt
verbatim** and appends a transcript block, because there is nowhere else for the
conversation to live. Feeding a tool *result* back for a second model turn is the
agent loop's job (Task 1.9), and it extends the interface rather than quietly
inheriting an accumulated conversation.

What travels in that block is *not* uniform, and two attempts at a tidier sentence
here were both false (review finding R2-F1). "The first turn in full" is wrong:
`e305_degraded_text_call`'s second prompt carries no `[ASSISTANT]` block at all,
because 1.9 drops the echo whenever the guard read the turn's *text* — and that
golden's own test asserts it. "The tool call and result travel in every case" is
wrong too: `recovery_ladder`'s second prompt carries a `[TOOL CALL REJECTED]` block
and neither of the others, because its first turn was a guard refusal. What every
multi-turn golden does carry, verified over all five: the previous prompt as a
prefix, a call **or** a rejection block, and a `[CONTINUE]` instruction.

### Measured on the demo device (iPad Air M4, iOS 26.5, 2026-06-14)

Three runs on the physical device against the real 2.59GB artifact: two on the backend the
engine chose (Metal) and one with the backend forced to CPU to narrow down the stall described
below. The simulator figures are kept only because the *comparison* is informative — where they
disagree, the device numbers are the numbers.

| Measurement | iPad Air M4 (2 runs) | iOS 16.4 simulator (3 runs) | iPad Air M4, forced CPU (1 run) |
|---|---|---|---|
| Backend actually initialised | **`gpu`** (Metal) | `cpu` (no Metal on a simulator) | `cpu` (requested and honoured) |
| Model load | **7.0 – 7.2 s** | 10.8 – 13.1 s | 4.4 s |
| Time to first token, `"Say OK"` | **337 / 551 ms** — §3.1's <500 ms target **not met** (1 of 2 runs) | 1.55 – 1.77 s | 488 ms |
| Grounded turn + one tool → structured call | **2.48 – 2.58 s** | 4.6 – 5.4 s | 3.54 s |
| Process RSS after load | **1669 – 1671 MB** (from 364 MB) | 734 – 1266 MB (from 117 – 223 MB) | 1635 MB (from 363 MB) |
| UI isolate, worst gap during load | **1445 – 1728 ms** ⚠️ (87 – 104 frames) | 32 – 90 ms | **2197 ms** ⚠️ |
| UI isolate, worst gap while streaming | **77 – 135 ms** (5 – 8 frames) | 31 – 40 ms | 139 ms |

The tool call is the result that mattered: on real hardware, under grounding, Gemma 4
returns a native structured `get_local_parts_inventory{sku: BRK-990-XP}` through the SDK's
`tool_calls` path — not prose that something had to parse. Both runs, plus every simulator
run.

**The UI-isolate number is bad, and it is the one the simulator most misled us about.**
The isolate boundary keeps a 7-second model load from being a 7-second freeze, but ~1.4–1.7 s
of that load still stalls the UI isolate — **87–104 dropped frames** at a 16.7 ms budget,
reproducible across both runs, and 17× worse than the simulator suggested. Against the spec's
§3.1 promise that the UI thread never drops frames, that is a **real violation during model
load**, not a rounding error.

Two neighbouring claims have to be held to the same standard, because an earlier version of
this section softened both:

- **Streaming is far better than the load, and still not compliant.** The worst gap while
  tokens arrive is 77–135 ms — 5–8 dropped frames, not zero. Calling that "genuinely clean"
  (as this section first did) is not something 135 ms against a 16.7 ms budget supports, and it
  has a concrete consequence: Task 1.11 is the screen-recorded demo, and an 8-frame hitch
  during streaming is visible in a recording.
- **§3.1's <500 ms TTFT target is not met.** 337 ms and 551 ms on the exact chip class the
  spec names — one run under, one 10% over. A 1-of-2 pass rate is not a met target, and
  "borderline-met" applied a gentler standard than the same evidence applied to §3.4's
  footprint cap, which is recorded as refuted. Both are measurements that failed, and both are
  now written down as failed.

**One cause has been eliminated, two remain.** A forced-CPU run on the same device
(`--dart-define=FIELDOPS_TEST_BACKEND=cpu`, logged as `requested=cpu backend=cpu` so it was
not a silent fallback) still stalled — **2197 ms, worse than Metal's 1445–1728 ms** — while
loading *faster* overall (4.4 s against 7.0–7.2 s, Metal setup being the difference). So
**first-load Metal pipeline compilation is not the cause.** One run, on one device.

That leaves three, and the CPU run constrains the shape of the first rather than just
supporting it:

- **Memory *traffic*, not resident size.** Across the three device runs, resident size and stall
  length move in **opposite** directions: 1668.6 MB → 1445 ms, 1670.6 MB → 1728 ms, and
  1635.3 MB → **2197 ms**. The lowest-RSS run stalled worst, so "RSS past 1.6GB stalls every
  thread" is not the version of the hypothesis the data supports. What survives is churn rather
  than level — page faults and allocation during the `mmap` walk — which also fits a *faster*
  load stalling *longer*, since the same work is compressed into less time. This matters for the
  side-loaded experiment: someone could remove the download, watch RSS barely move, and wrongly
  conclude the hypothesis is dead. The thing to watch there is fault and allocation activity, not
  the resident figure.
- **The worker's isolate group and its shared heap** — offered by review as an untested
  hypothesis and recorded as one, because it is the only candidate so far that explains the
  direction of the anomaly. `IsolateInferenceHost` uses `Isolate.spawn`, so the worker joins the
  **root isolate's group** and shares its heap; a major GC driven by the worker's allocations
  would therefore pause the UI isolate, even though neither the worker nor the plugin's own
  `Isolate.run` can block it directly. A DevTools timeline showing the stall coinciding with GC
  events would confirm it. Note the remedy space is narrow if it is true: `Isolate.spawnUri`
  would give a separate group and heap but is not available in Flutter's AOT builds, so the
  answer would be reducing worker-side allocation or scheduling the load — not isolating the
  heap.
- Also still open: platform-channel traffic from the worker (`path_provider` and
  `shared_preferences` are marshalled via the root isolate's messenger).

What would still distinguish them: a **side-loaded-weights run**, so no 2.6GB transfer precedes
the load — which also yields the download-free RSS figure this section has to hedge — and a
**DevTools timeline** across `initialize()` to tell a Dart-level block from a process-wide
stall. Until then the mitigation is scheduling rather than architecture: **load the model
before the UI needs to be interactive**, behind the readiness banner. Note the trap in the
obvious implementation — what stalls is the UI isolate, so a spinner shown *during* the load
freezes with it, and a frozen indicator reads as a hang.

**Throughput is still not measured** — and that is a different state from the two failures
above, worth keeping distinct. A one-token answer makes tokens-per-second a restatement of
TTFT (the "1.7 / 2.7 tok/s" the harness prints is exactly that arithmetic and means nothing),
so the spec's 15 tok/s target is untested rather than missed. It needs a long generation on
device, which Task 1.11's demo run will produce. The TTFT figure above is likewise for a
prefill-light prompt; the grounded prompt's ~400-token prefill sits inside the 2.5 s turn
figure, and no separate TTFT was captured for it.

**The spec's 500MB iOS footprint target is unreachable, and now measurably so.** 1.67GB of
process RSS on the device, twice, within 2MB of each other — far more consistent than the
simulator's 70% swing, which suggests it is dominated by the model rather than by transfer
noise. It is still an upper bound (the suite streams the artifact through the same process
moments earlier, and `flutter test` reinstalls the app per run so a download-free
measurement needs side-loading), but no reading of 1.67GB rescues a 500MB target. The spec
carries the device figure.

### Platform requirement, and the build failure it can still produce

`flutter_gemma` requires **iOS 16.0** (`background_downloader` requires 14.0), so the
app's deployment target moved from Flutter's default 13.0 to 16.0 — all three
`IPHONEOS_DEPLOYMENT_TARGET` entries in `ios/Runner.xcodeproj/project.pbxproj`. Adopting
on-device Gemma therefore drops iOS 13–15 hardware: a real fleet constraint, not just a
build setting.

**Bumping the target is necessary but not self-enforcing.** If a device build fails with

```
Target Integrity (Xcode): The package product 'flutter-gemma' requires minimum platform
version 16.0 for the iOS platform, but this target supports 13.0
```

the project is not wrong — check
`ios/Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage/Package.swift` and it
will say `.iOS("13.0")`. Flutter's Swift Package Manager integration always generates that
manifest with a hardcoded 13.0 (`flutter_tools/.../darwin/darwin.dart`), then raises it in a
**separate, conditional** step that only runs when `xcodebuild -showBuildSettings` yields
`IPHONEOS_DEPLOYMENT_TARGET` (`flutter_tools/.../ios/mac.dart`). That read is slow and can
fail on a cold or loaded machine, and when it does the manifest keeps 13.0 and SPM rejects
the plugin.

Fix by running the step on its own first:

```bash
flutter build ios --config-only --debug    # patches the generated manifest to 16.0
```

Then re-run the build or the integration suite. Verify with
`grep 'iOS(' ios/Flutter/ephemeral/.../Package.swift` — it should read `.iOS("16.0")`. The
manifest is regenerated on every build, so this can recur; if it becomes a nuisance,
moving plugin management back to CocoaPods (where the floor is a literal
`platform :ios, '16.0'` in the Podfile) removes the conditional step entirely.

## Agent tools: the registry

`lib/services/ai/` is the seam between a model that emits a **structured
tool-call event** — a name plus a JSON-decoded argument map, produced by weights
and therefore untrusted — and a Dart executor with a real signature.

`ToolRegistry` owns both directions, and keeping them on one object is what keeps
them from disagreeing — **so long as a tool's `definition` is stable**:
`registry.definitions` is what goes into `LlmEngine.generate(tools: …)`, and
`registry.dispatch(call)` is what routes the result back. A tool the model was told
about is a tool the registry can execute, because the declaration and the dispatch
key are the *same* string, `definition.name`.

Both hedges were earned in review rather than written up front. This paragraph used
to say the halves were "impossible to disagree, by construction" while the dispatch
key came from a separate overridable getter — precisely how they *could* disagree
(R0-F2). Deleting that getter fixed it; documenting the one hazard left then showed
"impossible" was *still* too strong, because the dispatch map is snapshotted at
construction while the declarations are recomputed per call (R2-F2). Both corrections
are described below.

**The set is validated at construction**, not at the first `generate()`. That is
the rule Task 1.8 arrived at from the other side: neither consumer of a tool
definition rejects a bad one (see _Tool calling_ above), so a malformed schema
surfaces two layers away as "the model is bad at tool calling". `ToolRegistry`
runs the same `assertToolDefinitionsUsable` both `LlmEngine` implementations run,
so a registry that *builds* cannot produce a definition the device rejects.

What is load-bearing there is *what the validator is handed*, not when it runs:
`definitions` is derived from the full tool list, so it still contains both of two
tools sharing a name and the duplicate check can fire. Hand it a name-keyed
collection instead and that pair collapses into one entry, silently disarming the
check. Making that substitution kills exactly one test,
`rejects two tools registered under the same name`, which is the evidence for this
paragraph. (An earlier version credited "the test suite's `M4`" — there is no `M4`
in the test suite; it was a row in a review ledger that gets deleted when the review
closes, so the reader could not follow it. R1-F2.)

The statement *order* in the constructor is **not** load-bearing, and an earlier
version of this section said it was — claiming "a test restores that ordering and
fails" when no such test exists and swapping the two statements leaves all tests
green. Caught in review as R0-F1, which is this project's most-repeated failure
mode: a claim asserting a regression guard that nothing implements. The mutation
evidence was right; **four** prose descriptions of it were wrong — and the fourth,
found only in the next review round, was the comment on the test the false claim had
named as the guard. The count is stated as four rather than three because the first
correction said three and missed one (R1-F1).

The dispatch key is `definition.name` — the same string the declaration carries.
That is also a correction: `AgentTool` used to expose an overridable `name` getter
defaulting to `definition.name`, and the registry routed on *it*, so a subclass
overriding one getter would be declared under one name and dispatched under
another, permanently `unknown_tool`. Rather than assert the two agree, the second
name was deleted — the registry now reads `definition.name` and nothing else.
Precisely: a subclass can still define a `name` member of its own, but nothing in
the registry consults one, so it cannot affect what is declared or what is
dispatchable. That is narrower than "divergence is impossible", and it is what the
code actually buys. A test pins the invariant directly: every declared name
resolves and dispatches.

### A bad call is data, not an exception

Everything the *model* can get wrong comes back as a `ToolFailure` value with a
JSON payload, never as a throw: a hallucinated tool name, a missing or mistyped
argument, a SKU that does not exist. The agent loop's recovery for all of them is
identical — feed the payload back so the model can correct itself on the next
turn — and a loop that had to catch exceptions here would be one `on Object` away
from swallowing real defects. Task 1.3 had already applied the same reasoning one
layer down: `inventoryPartBySku` returns `null` for an unknown SKU rather than
throwing.

Which is why the `catch` in `dispatch` is `on Exception` and **not** `on Object`.
An `Error` means the *app* is broken, not the call, and reporting it to the model
as `execution_failed` would hand it to something that will paraphrase it to a
technician and try again. The split was measured rather than assumed, and the
measurement corrected a guess:

- `SqliteException` is declared `implements Exception`, so a genuine SQL failure
  is **recoverable** — it becomes `execution_failed` and the loop survives it.
  Covered by a test that provokes a real one from the driver, not a synthetic
  stand-in.
- drift's closed-database guard raises **`StateError`**, an `Error`, so it
  **propagates**. This suite originally asserted the opposite, on the assumption
  that a closed connection was a recoverable condition. drift's own
  classification is the better one: closing the database out from under a running
  agent loop is a lifecycle defect in this app, not something a model can retry
  its way out of.

`ToolFailure.cause` carries the underlying error for logs and tests and is
deliberately **absent from `payload`**. An exception's `toString()` routinely
quotes file paths, SQL and row values, and the payload is prompt text — §3.2's
device boundary includes the prompt. A test asserts the driver's message, which
names the offending table, does not appear in the encoded payload.

### `get_local_parts_inventory`

The first tool, and the one the spec's §5.2 walkthrough calls. It is thin because
Task 1.3 built the query for this call site and put the properties it needs
*inside* it: the SKU is canonicalised on the way in (trim + upper-case, because
from here the argument arrives from the model in whatever casing the weights
emitted), `inventory_parts.sku` is `COLLATE NOCASE` as a backstop for rows
written past the normaliser, and the lookup goes through the primary-key index.

Two payload shapes, and the difference between them is the point:

| Case | Payload |
|---|---|
| Found | `{"sku": "BRK-990-XP", "in_stock": 2, "aisle": "Aisle 4, Shelf B"}` |
| Not carried | `{"sku": "NOPE-000-XX", "found": false}` |

A distinct shape rather than `in_stock: 0`, because "we do not carry this part"
and "we carry it and have none" are different sentences to a technician, and the
model can only tell them apart if the payload does. `BELT-330-DRV` is seeded at
zero stock precisely so a test can hold the two apart. `sku` echoes the **stored**
row rather than the model's spelling, so the next turn quotes the canonical form.
`aisle` is present-and-`null` when a row has no location — an omitted key is
indistinguishable from a tool that does not report locations, and a placeholder
string would be text the database does not contain.

A blank `sku` is a **missing parameter**, not an empty warehouse. That could
plausibly have gone the other way and been one line shorter:
`inventoryPartBySku('  ')` already returns `null`, which would render as a normal
"not carried" answer. It would also be a lie about what happened — nothing was
looked up — and it invites the model to tell a technician a part is unavailable
when it never named one. Absent, `null` and blank all report
`missing_parameter` with distinct messages.

A non-string `sku` is rejected rather than coerced with `toString()`. Coercion is
tempting and wrong: `{"sku": true}` would become a lookup for `TRUE`, which
resolves to nothing and is indistinguishable from a real miss. It is also
unnecessary on the primary path, where Gemma 4's constrained decoding is driven
by this very schema.

**Scope note, because the spec is two-minded about this tool's signature.** §2.2
describes `get_local_parts_inventory(sku_or_name)`, but the only lookup that
exists is exact-SKU. A name search needs a different query (full-text over
`inventory_parts.name`, which is not indexed) and a different answer shape —
several rows, or the disambiguation question §2.3 describes. The tool declares
`sku` only, which is what the acceptance criteria specify. Name search is a
separate tool, not a widened parameter.

### Not wired into the app

Same position as the seeding engine and the retrieval router: a library with
tests and no production call site, because binding a `DatabaseService` needs the
encryption key Task 1.1 deferred. Task 1.11 owns the key and the wiring; Task
1.9's agent loop is the first consumer of `dispatch`, and the guard below feeds
the degraded path into it. Lenient tool-name matching lives there rather than
here — `dispatch` matches names exactly, because on the primary path Gemma 4's
constrained decoding emits a name that came from this registry.

## The defensive tool-call guard

`ToolCallGuard` is the degraded path into `dispatch`, and it is deliberately
small. Task 1.8 confirmed on the device that Gemma 4 emits **native
function-call tokens**, so the plugin delivers a structured `LlmToolCall` on the
happy path and this task's original premise — "coerce noisy model output into
valid JSON" — mostly evaporated. Two shapes are left:

| Input | Result |
|---|---|
| A well-formed native event | `GuardedCall` holding the **same instance**, unchanged |
| A native event with an unusable name or unserialisable arguments | `GuardFailure` |
| A call emitted as prose, a fenced block or a JSON blob | `GuardedCall` extracted from the text |
| Anything else | `GuardFailure` — the loop treats the turn as carrying no tool call |

**Why a text path is needed at all, on the plugin's own evidence.** It would be
reasonable to assume the runtime parses a textual tool call if the model emits
one. For the model this app ships, it does not.
`FunctionCallFormatFactory.create` maps `ModelType.gemma4` to
`SdkPassthroughFunctionCallFormat`, whose implementation is **five** overrides
returning constants — `isFunctionCallStart` → `false`, `isDefinitelyText` →
`true`, `isFunctionCallComplete` → `false`, `parse(String)` → **`null`**, and
`parseAll(String)` → **`const []`**
(`flutter_gemma-1.4.1/lib/core/parsing/sdk_passthrough_function_call_format.dart`,
`grep -c '@override'` → 5). Every other model family in that factory gets a real
text parser; Gemma 4 gets none, because it is expected to deliver structured calls
through the SDK instead.

This paragraph originally said "four" and omitted `parseAll` — because the grep
that produced the list was truncated at twenty lines, while the prose claimed the
file had been read (R1-F1). **An enumeration is only as good as the read that
produced it**, and a `head`-limited grep is not a read of the file.

The override that carries the argument is `parse` → `null`, not `parseAll`. A
first correction of this passage called `parseAll` "the sharpest available
statement" because it is what the plugin uses for multi-call text parsing — but
`FunctionCallFormat` supplies a *concrete default* `parseAll` that delegates to
`parse` and returns `[]` when it yields `null`
(`function_call_format.dart:23-27`), so for this class the explicit override is
belt-and-braces rather than the load-bearing line. The ranking came from the
review and was adopted and hardened here without opening the base class — the same
"a reviewer's claim needs measuring too" trap Task 1.5 recorded as R3-F1, and the
reviewer caught its own version of it (R2-F3). Reading one more file would have
settled it.

Either way the conclusion is the plugin's, not this README's: a Gemma 4 turn that
spells a call out in prose reaches the app as plain text that nothing will parse.
That is this guard's entire reason to exist, and it is a stronger argument than the
one this section originally made from first principles.

**Extract-and-parse only.** A string-aware scan finds the *extent* of a JSON
object and `jsonDecode` decides whether it is one. There is no bracket repair, no
quote balancing, no salvaging of truncated JSON: something that does not decode
is not a tool call, which is a cheaper answer than a wrong one. Nothing
enumerates wrapper syntax either — because the scan starts a candidate at every
`{`, a fenced code block, a `<tool_call>` tag, a JSON array and OpenAI's nested
`{"type": "function", "function": {…}}` envelope are all the same input to it.
That last one is why the file no longer contains an explicit envelope-unwrapping
recursion; see below.

### A guard failure is not an unknown tool

The load-bearing distinction. A `GuardFailure` means **"there is no tool call
here"** — never "that tool does not exist". A name the guard cannot resolve is
passed through *unchanged*, so `dispatch` answers `unknown_tool` with the payload
it already has written for the model. Reporting it here as well would give one
condition two different reports depending on which layer noticed first.

That is also why lenient name matching lives here and exact matching lives in the
registry: **one** forgiving place rather than two. A near-miss resolves by exact
equality after dropping case and every non-alphanumeric character — a property,
not a list of spellings — so `GET_LOCAL_PARTS_INVENTORY`,
`getLocalPartsInventory`, `get-local-parts-inventory` and
`functions.get_local_parts_inventory` all reach the declared name. It is
deliberately **not** fuzzy matching: no edit distance, no prefix scoring, because
the cost of guessing wrong is dispatching to the wrong tool, which is worse than
an `unknown_tool` the model can recover from. Two declared names that normalise
alike make the guard refuse to guess rather than pick one.

### Text has to prove it is a call; a native event does not

A native event arrived through the runtime's function-calling path, so it *is* a
call. A JSON object sitting in prose is not, and the rule for promoting one is:
it names a tool this build knows, **or** it is shaped like a call (a name and an
arguments key). Without that rule, `{"name": "Bob", "age": 3}` in an answer
becomes a call to a tool named `Bob` and the loop reports a tool failure for a
sentence. The second half of the disjunction is what keeps the paragraph above
true: `{"tool": "invented_tool", "arguments": {}}` *is* an attempt, so it passes
through under the name the model chose and the registry reports `unknown_tool`.

Absent arguments become `{}`, and unreadable arguments are a failure. This is
Task 1.5's blank-SKU reasoning one layer up: a tool may legitimately take no
arguments, and for one that does not, `{}` reaches the registry as
`missing_parameter` — accurate, because the model named no value. Answering the
same way for arguments that *were* supplied in a shape nothing can read would
describe a call that never happened. Positional arguments are refused for the
same reason: mapping `["BRK-990-XP"]` onto `sku` works only for a
single-parameter tool and silently mis-assigns the moment a tool takes two.

One residual is recorded rather than engineered around: a model that echoes a
tool *declaration* back as text reads as a call whose arguments are the JSON
schema, because a declaration and a call share their key names. The outcome is a
`missing_parameter` — a recoverable turn — and the available discriminators are
exactly the enumerate-the-attack shape Task 1.4 learned to avoid.

### Why the encodability check is structural

A native event's arguments are ordinary Dart values; nothing upstream constrains
them. The isolate wire's `decodeEvent` checks that the arguments *are* a `Map`
and never inspects the values, and `FakeLlmEngine` scripts whatever a test hands
it. What breaks is Task 1.9 putting the attempted call into the next turn:
`jsonEncode` throws `JsonUnsupportedObjectError`, which is an **`Error`** — not
something the loop's `on Exception` recovery catches.

So the guard walks the map with a predicate instead of encoding-and-catching,
because catching that would mean `on Error`, the shape Task 1.5 rejected on
purpose. Non-finite doubles are rejected on measurement rather than assumption:
`jsonEncode(double.nan)` throws exactly as a `DateTime` does. The predicate is
deliberately *narrower* than `jsonEncode`, which falls back to calling `toJson()`
on an unknown object — a tool argument that is only serialisable through
someone's `toJson()` is not something a model can have sent.

**Both paths run the probe, and the reason this paragraph used to say otherwise is
worth keeping.** It claimed arguments recovered from text could skip the check
because they came out of `jsonDecode` and were therefore "JSON-encodable by
construction". Decoded does not imply re-encodable: a numeric literal that
overflows a double decodes to `Infinity`, which `jsonEncode` refuses.
`jsonDecode('{"n": 1e400}')` produces one, so
`{"tool": …, "arguments": {"qty": 1e400}}` handed the agent loop precisely the
value whose serialisation throws the uncatchable `Error` the paragraph above is
about — while the native path rejected the identical value. Raised in review as
R0-F1. The lesson generalises past this file: **a claim that some property holds
"by construction" is a claim about a constructor someone has to have read.** The
model-text path is the *more* likely source of an absurd numeric literal, not the
less.

### What mutation testing changed

The suite was green and 27 mutations were run against it, each against the whole
suite under `--reporter expanded` (the default reporter truncates its failing
list, which produced two wrong counts in Task 1.4). That first run was against a
**432**-test suite, not the 433 an earlier draft of this paragraph claimed: the
fix commit below replaced one ordering test with two, so 433 is the count for
every run *after* the fixes, and stating it for the run that found them described
a measurement against a tree that no longer existed. Two mutations survived, and
**neither was a missing test — each was a defect the tests had been shaped
around**:

- **The envelope recursion was dead code.** `_callFromObject` recursed into an
  object found under a name key so the OpenAI envelope would resolve. Deleting
  the recursion killed nothing: the positional scan already offers the inner
  object as its own candidate once the outer one is rejected for carrying no name
  string. The scan had been doing the work the whole time while a test comment
  credited the recursion — a false claim about first-party code, which is this
  project's most-repeated failure mode. Deleted rather than re-documented.
- **Name resolution had the wrong precedence.** Candidates were tried pass-major
  (both spellings exact, then both normalised), which let a *segment's* exact
  match beat the *whole name's* normalised match: with `getparts` and `parts`
  both registered, `get.parts` resolved to `parts` — a different tool than the
  model named. It is now candidate-major.

The second is the more useful one, because the mutation that exposed it deleted
the exact-match pass and *survived*, and chasing why showed the test meant to
bind that pass had been passing on the **ambiguity** rule instead — a test that
passed for a reason unrelated to the criterion it was mapped to, the pattern
Tasks 1.2, 1.4 and 1.8 each recorded. It is replaced by two tests that bind the
real ordering, each needing a fixture where the two candidate orders disagree.
Adversarial review then ran its own mutations and found more. Across two rounds it
wrote 38 of them; **14 survived**.

The review ran **seven rounds** and raised **twenty-two findings** — six, five,
four, two, two, none and three, written out per round so the total is checkable on
the page rather than restated from memory.

That breakdown has been re-stated three times now, and every restatement is the
argument for having it. It said fifteen while round 4 had recomputed the *split*
below without revisiting the *sum*, leaving a README that narrated a finding by ID
in one paragraph and excluded it from the count in another (R4-F1). It said five
rounds, which was true until the approving round landed. Then the reviewer reopened
at **Final Acceptance** and found three more, so six rounds became seven and
nineteen became twenty-two. **A total is a claim, and a total maintained by hand
goes stale every round** — including the round you expect to be the last.

Four of the twenty-two came out of the mutations — R0-F3 and R0-F4 from survivors,
R1-F4 from a survivor of the round-1 fixes, and R0-F2 from the *kill-list* of a
mutation that died (it killed the test beside the one whose criterion it was). The
rest came from re-reading source and re-measuring claims, which is the cheaper half
of the work and found the High.

Exactly one was **behavioural** — the encodability hole above (R0-F1), where
shipped code did the wrong thing.

Two were **correct code with nothing holding it there**, the category this project
keeps rediscovering. R0-F4: `renamedFrom` was guarded on the native path ten times
over and on the text path not at all. R1-F4: a gap in R0-F1's own fix — the probe
reads the *decoded* arguments, but `object` is also in scope and also a
`Map<String, Object?>`, so swapping the subject compiles, passes everything, and
reopens R0-F1 for arguments delivered as a JSON *string*, whose value is then a
perfectly encodable `String` that nothing looks through.

Eighteen were **claims** — in comments, docstrings, this README and the review
ledger — that the code, the dependency, or the measurement did not support. The
twenty-second is a formatting lapse, kept in its own category rather than rounded
into the claims so the ratio stays honest. Eighteen of twenty-two, against one
behavioural defect: that ratio is the most useful thing this task measured about
itself.
R0-F2 is the one worth reading twice, because it took a round to classify correctly
and the correction is the interesting part. `a brace inside a string value does not
truncate the object` used `"A}B{C"`, a **balanced** `}`…`{` pair a plain brace
counter walks straight through, so the test was green with or without the behaviour
it named. That looks like an unbound property — but string-awareness *was* bound,
measurably, by the escaped-quote test beside it: the mutation removing string
tracking killed exactly that one test, before and after the fixture fix. So nothing
was unguarded; what was wrong was a **comment crediting a vacuous test with a guard
it did not provide**, which is the same species as the envelope-recursion comment,
and it belongs here rather than above.

The suite now stands at **438 tests and 33 mutations, 0 survivors**. Six of those
mutations were added to bind the review rounds' fixes — the text-path encodability
probe, string-mode entry in the brace scan, each alias list's preference order,
text-path `renamedFrom`, and the probe's *subject* — and one more to bind the
resolution-ordering defect self-caught before handoff. An earlier version said seven
for the review rounds by counting the last one twice, since round 2 *replaced* a
duplicated slot rather than adding one — "a list is not a set", one paragraph after
coining the phrase. (Described rather than cited by `Mnn` id: the harness lives
outside the repo, and Task 1.5's R1-F2 was exactly a production comment citing a
mutation id the reader could not follow.)

The corrections in this section are themselves worth keeping, because it exists to
be accurate about measurement and each version of it was not. It claimed "six of
the reviewer's mutations survived, four became findings" — the reviewer's ledger
records 13 survivors in round 0 alone, 7 of which fed 2 findings, so both numbers
were wrong and both had been copied from a summary rather than counted. It said "33
mutations" while two entries were byte-identical edits, i.e. 32 distinct ones; that
slot now holds the R1-F4 mutation. **A count of mutations is a claim like any other,
and a list is not a set.**

And then the sharpest one, because it is this section's own prescription failing:
the fix for that duplicate was **claimed before it existed**. This paragraph
asserted that "the harness is checked for duplicate (anchor, replacement) pairs"
when the harness contained no such check — the check had been run once, by hand, in
a throwaway one-liner, and writing it up as a property of the tool was the same
move as calling a truncated grep a read of the file. The reviewer grepped for it and
found nothing (R2-F1). **A mechanical check is only mechanical once it is in the
tool**; `mutate.py` now refuses to run when two mutations share an `(anchor,
replacement)` pair, and that refusal was verified by re-inserting the duplicate and
watching it fire — because a guard nobody has watched fail is the thing this whole
section is about.

And the first version of *that* guard had a hole of its own, found the same way. It
keyed uniqueness on the mutations' **labels** differing, so it caught a duplicate
edit under a new label but waved through a whole-row copy-paste — label included,
which is precisely how an unnoticed duplicate arises. Its reassuring `no duplicates`
was a literal string rather than a derivation, so it would have printed alongside its
own contradicting numbers (R3-F1). The check now compares the edit itself and then
asserts `len(distinct) == len(MUTATIONS)`, and **both** duplicate shapes were
falsified against throwaway copies: differently-labelled and identically-labelled
each exit 1, the clean list exits 0. A guard written to enforce "watch it fail" is
the last place to skip watching it fail — with two shapes to try, trying one is the
same partial-enumeration move the rest of this section documents.

The harness also refuses two mutations that share a **label** with different edits,
which is a distinct hazard the reviewer raised as a non-blocking note: both parties
key their round-over-round comparisons by label, and the results JSON is a list of
`{label: …}`, so such a pair would be run and measured and then collapse into one
the moment anybody diffed two runs — measured and silently dropped. Also falsified
(exit 1, `34 mutations but only 33 distinct labels`).

One process note worth keeping, because it is a lesson this repo had already
written down: the harness reverts with `git checkout`, so it **requires a
committed baseline**. Task 1.5 recorded that, and this harness hit it anyway —
the first revert destroyed both uncommitted fixes, which had to be re-applied.
It now refuses to run when the file under mutation is dirty.

### Not wired into the app

Same as the registry it feeds: a library with tests and no production call site.
Task 1.9's agent loop is the consumer — it decides what a `GuardFailure` *means*
for a turn (feed the message back, or treat the turn as a plain answer), which is
what `GuardFailureReason` exists to let it branch on.

## The agent loop

`lib/services/ai/agent_loop.dart` is the piece the demo is named after: a
grounded prompt goes in, the model answers or asks for a tool, the tool runs
locally, its result goes back to the model, and a grounded answer comes out.

```dart
final loop = AgentLoop(engine: engine, registry: registry);
final result = await loop.runToCompletion(compiler.compile(retrieved));
// result.answer, result.stopReason, result.turns (the transcript)
```

It does not retrieve and it does not compile. It is handed a finished prompt,
because the two halves fail differently and are worth testing apart: retrieval
is a database question with exact answers, and this is a conversation-shaped
question with fuzzy ones. `AgentLoop.run` streams `AgentEvent`s for a UI that
wants live tokens and a "checking inventory…" indicator; `runToCompletion` is
that stream drained.

Everything it consumes already existed. What none of its dependencies could
decide, and this file does, is four things.

### How a turn ends, and how the conversation survives it

`LlmEngine.generate` is a **stateless single turn** — a fresh conversation per
call, closed after. There is no accumulated history to inherit, so the loop
carries the conversation itself, as text, by appending a transcript to the
prompt it was given:

```
<the whole grounded prompt from the compiler>

[ASSISTANT]
Checking the local warehouse.

[TOOL CALL]
{"tool":"get_local_parts_inventory","arguments":{"sku":"BRK-990-XP"}}
[TOOL RESULT]
{"sku":"BRK-990-XP","in_stock":2,"aisle":"Aisle 4, Shelf B"}

[CONTINUE]
The tool results above are the authoritative local warehouse data …
```

A turn ends when the engine's stream closes. `LlmDone` is consumed and carries
no extra information at this layer — waiting for it would hang the loop on a
runtime that closed without emitting one.

### What a `GuardFailure` means for a turn

Task 1.6 built `GuardFailureReason` "for the loop to branch on" and deliberately
left the branch open. It is decided here, and it is not a single rule:

- **`noToolCallFound`** means *there was no call here*. The turn is a plain
  answer and the run ends.
- **Every other reason** — `emptyToolName`, `argumentsUnreadable`,
  `argumentsNotEncodable` — means the model tried to call something and got it
  wrong. That is recoverable: a `[TOOL CALL REJECTED]` block carries the guard's
  message back and the loop continues.

Both directions of getting this wrong are real, which is why both are tested.
Treating a malformed call as an answer ships the model's half-finished sentence
("Let me look that up.") to a technician as the final word. Treating prose as a
malformed call spends the turn budget arguing with a model that already
answered.

An **unknown tool name is not a guard failure at all.** The guard passes an
unresolvable name through unchanged, `ToolRegistry.dispatch` answers
`unknown_tool`, and that payload is fed back like any other result — one report
of one condition, rather than two that differ by which layer noticed first.

### Two bounds, doing different work

- **`maxTurns`** (default 4) is the hard bound on calls to `generate`. Two turns
  is the shortest complete run and a correction round costs one turn, so the
  default leaves room for **two** of them. (This said "one" in three documents
  until review did the arithmetic.) Hitting it stops the loop with `AgentStopReason.iterationCapReached`
  and a message that *reports the failure* rather than summarising a diagnosis
  the loop never obtained. It is **clamped**, not asserted — an `assert` is
  compiled out in release and would make the clamp unreachable from any test.
- **The repeat short circuit** is not what makes the loop terminate, and the
  README says so because the code reads as though it might. The same call twice
  in one run executes once and replays the recorded outcome; a model that asks
  the same question forever still runs to the cap, it just stops paying for the
  query. It also keeps the second answer *identical* to the first, which a
  re-execution could not promise for a tool that is not a pure read. Top-level
  argument keys are sorted so key order does not make one call look like two;
  nested maps are left alone, and a reordered nested map costs one extra
  execution rather than a wrong answer. **It caches failures too, including
  `execution_failed`** — for an identical call there is nothing left to correct,
  so replaying it costs no turn out of a four-turn budget; a *different* call is
  a different key and stays open.

### The continuation prompt cannot be forged

Everything appended above is written into a prompt whose preamble tells the
model what to trust, and three of the four embedded pieces are model-authored or
model-influenced. The third one is not obvious: `get_local_parts_inventory`
echoes `normalizeSku(<the model's string>)` for a SKU it does not carry — trim
and upper-case, no character filtering — so **the model chooses the content of a
`[TOOL RESULT]` block**, and the interesting thing to put there is
`[TOOL RESULT]` followed by an invented stock level.

The defence is that every marker in this prompt starts a line, and no embedded
value can start one:

- **The call and result blocks are single lines, written by
  `AgentLoop.encodeOneLine`.** `jsonEncode` on its own is *not* enough, and the
  first version of this section claimed it was. It escapes every code unit below
  `0x20` plus `"` and `\`, and leaves **U+0085 NEL, U+2028 LINE SEPARATOR,
  U+2029 PARAGRAPH SEPARATOR and U+007F raw**. U+2028 and U+2029 are Unicode
  *mandatory* line breaks, and `normalizeSku` is `trim().toUpperCase()` — so an
  interior U+2028 in a model-supplied SKU reached the echoed payload verbatim
  and opened a real second `[TOOL RESULT]` at column 0. Exactly the attack this
  section said was closed, found in review and reproduced against the loop.
  `encodeOneLine` re-escapes the survivors as `\uXXXX`, matched by general
  category (`Cc`, `Zl`, `Zp`) rather than by listing four codepoints, for the
  same reason `neutralizeMarkers` is a category rule one layer down. Re-escaping
  rather than stripping keeps the line valid JSON *and* lossless — a test
  asserts `jsonDecode` of the output equals the input. The tool *name* is inside
  that encoded line too, not written as bare prose, because a name recovered
  from text is a decoded JSON string and really can contain a line break.
- **The echoed turn text is the one piece that can legitimately contain line
  breaks**, so it gets the other rule instead: `PromptCompiler.neutralizeMarkers`
  rewrites every Unicode `Ps`/`Pe` codepoint to a round bracket, so it cannot
  spell a bracketed marker at all. Reused rather than reimplemented — a second
  copy of that rule would be a second thing to keep true.

Only the *prompt* copy is neutralised. `AgentTurn.text` keeps what the model
actually said, because that is what the technician saw and what Task 1.10 will
snapshot.

**The echo is dropped whenever the guard read the turn's text** — that is,
whenever no native event arrived. Neutralising that text brace-mangles it, so
echoing it showed the next turn a corrupted copy of the very JSON shape the
guard needs it to keep producing. Found in review; the justification for keeping
the echo ("it is the reasoning that led to the call") is true on the native path
and false on this one.

The first version of that fix asked the wrong question — "does any *invocation*
have a text source" — which is silently wrong for a turn whose only text-path
attempt was **refused**, because then there are no invocations at all. That is
the case that can least afford it: with nothing dispatched there is no
`[TOOL CALL]` block beside the echo, so the mangled line is the only rendering
the model sees, directly above an instruction to send well-formed JSON. The loop
already knows the answer (`nativeCalls.isEmpty`) and now records it on the turn
instead of inferring it.

What that costs is stated rather than glossed: `inspectText` scans for a JSON
object *anywhere* in the text, so `"Let me look that up. {…}"` is a legitimate
turn and its first sentence goes with the rest. Showing mangled JSON is worse
than losing a sentence of preamble, and the canonical `[TOOL CALL]` block
carries what the next turn actually needs.

One change this forced upstream: the compiled prompt's `[USER INQUIRY]` block
used to be wrapped in **unescaped** quotes, which Task 1.4 recorded as safe
"only while that block is last". It no longer is, so `PromptCompiler.escapeQuotes`
now escapes the backslash and then the quote — that order, because escaping
quotes first doubles the backslash it just emitted and leaves a live quote
behind. The invariant is checkable without enumerating hostile inputs: delete
every escape pair from the inquiry block and exactly two quotes remain, which
are the delimiters the compiler wrote.

### What propagates rather than being fed back

Two things, both for the reason Task 1.5 established — a value the model can
act on is data, and everything else is a defect:

- **An error on the engine's stream.** A broken runtime is not something the
  model can correct, and a loop that caught it would hand a technician a
  paraphrase of a crash.
- **An `Error` out of a tool.** `AgentTool.execute`'s contract already requires
  a JSON-encodable payload precisely because this loop serialises it, so a
  violation is an app defect. A tool that throws an `Exception` is different and
  is fed back as `execution_failed`.

### The prompt budget, measured

Task 1.9's brief was to measure `maxDocuments` against a real context window
rather than inherit Task 1.4's reasoning about it. Measured on the shipped seed
(`test/services/ai/agent_loop_test.dart`, printed on every run):

| Prompt | Characters |
|---|---|
| Two-document grounded prompt (turn 1) | 1581 |
| After one tool round trip (turn 2) | 2064 (+483) |
| **Ceiling — four turns, the shipped `maxTurns`** | **~2900** |
| A third document, if the cap allowed it | +619 |

The ceiling row exists because the first version of this table stopped at 2064
and the test producing it was named "the widest round-trip prompt the loop can
build" — which it was not, since it drove two turns against a default of four.
The bound is `maxTurns`-scaled, and the number that matters is the last one.

It is approximate for a reason worth naming: each turn appends an echo of what
the model said, so the ceiling moves with the *script*, not just with the loop.
This suite's script measures `[1581, 2038, 2469, 2900]`; a reviewer's, with
longer per-turn text, measured `[1581, 2066, 2525, 2984]`. The shape — one
grounded prompt plus three transcript blocks, monotonically growing — is the
property the test pins; the last digit is not.

**Characters, not tokens.** The tokenizer ships with the weights, so a token
count computed on the host would be a guess wearing a number, and this repo has
already paid for one of those. The host suite bounds the characters as a
regression guard; the device suite (`integration_test/agent_loop_e2e_test.dart`)
is what tests the real 2048-token window, by running the same round trip and
failing if the turn does not complete.

### What the mutation pass found

29 mutations across `agent_loop.dart` and the `escapeQuotes` change it forced
into `prompt_compiler.dart`, each run against the **whole** suite under
`--reporter expanded` — the default reporter truncates its failing list, which
produced two wrong counts in Task 1.4. The harness names a file per mutation
because this task's behaviour spans two, and it refuses a dirty baseline,
duplicate mutation *edits* and duplicate mutation *labels*.

**27 killed on the first pass; 2 survived, and both were gaps in the tests
rather than in the code.** (Review then found a third and fourth hole the set
did not probe at all — see the round-1 additions below.) Both are failure modes this repo had already
recorded, which is the interesting part:

- **Deleting the loop's engine-readiness check killed nothing**, because
  `FakeLlmEngine.generate` *also* throws a `StateError` when it has not been
  initialized — so `throwsA(isA<StateError>())` was green with the check gone.
  A test passing for a reason unrelated to the criterion it was mapped to. It
  now asserts the loop's own message and that the engine was never handed a
  prompt at all.
- **Moving the tool-start event to *after* `dispatch` killed nothing**, because
  the Started → Completed *ordering* is unchanged by it. What that mutation
  breaks is the timing, and an ordered list of events cannot see timing. The
  event exists so a UI can show "checking inventory…" while the query is in
  flight, so the replacement test blocks a tool on a completer and requires
  Started to have arrived while Completed has not.

**After both fixes, all 29 die** — re-measured by running the whole set again
against the tree at the last commit, not carried over from the first pass.

Review round 0 then showed the set had a hole of its own: nothing in it touched
`AgentToolCallRejected` or `AgentToolCallStarted.repeated`, and two probes the
reviewer added survived with zero failing tests. **Five** mutations were added
(M30–M34) — two for the line-terminator re-escaping, two for the unbound stream
signals, one for the dropped echo on the degraded path.

One of the five was itself a bad mutation before it was a passing one, which is
worth recording because it is the harness's own version of the failure this
section keeps describing. M30's first form inserted a *no-op* `replaceAllMapped`
before the real one, so the re-escaping still ran; it reported `SURVIVED`, which
would have read as "the tests do not cover this" when what it actually showed
was "this edit changes nothing". A mutation that does not mutate measures the
mutation, not the suite. Rewritten as two edits that disable the rule for real —
one voiding the pattern, one narrowing the category class to `Cc` so only the
separators slip through.

Review round 1 then found a defect in one of *those* fixes, and with it the
second hole in the set. The R0-F5 fix asked "does any invocation have a text
source", which is exact everywhere except when there are no invocations — the
turn where every text-path attempt was refused, which is the case the finding
was about. The reviewer's `.any` → `.every` probe survived with zero failing
tests, because the two formulations differ *only* on the empty list. Two more
mutations (M35–M36) pin the replacement, and the reviewer's probe is one of
them: promoted into the harness so it is re-run rather than remembered.

**36 mutations, 0 survivors**, one run, whole suite, against the tree at the
last commit. The count is stated here rather than left to the harness's own
output because this section's standard — "a count of mutations is a claim like
any other" — applies to itself, and it had gone stale once already: it read 34
after the set grew to 36.

### Not wired into the app

Same position as 1.3, 1.4, 1.5 and 1.6: a library with tests and no production
call site, because binding a `DatabaseService` needs the encryption key Task 1.1
deferred. **Task 1.11 owns the key, the seed trigger, the engine override and the
composition** — retrieval → compilation → this loop is three lines, and the
integration test writes them out.

### Verified on the demo device (2026-08-05, iPad Air M4, iOS 26.5)

TC-AGENT-E2E-01 **passed** against the real 2.59GB artifact, and the numbers are
measurements rather than estimates:

| | |
|---|---|
| Turn 0 (grounded prompt → native tool call) | prompt **933** chars, 136 chars of text, 1 tool, 0 rejected |
| Turn 1 (tool result → final answer) | prompt **1510** chars, **1401** chars of answer, 0 tools |
| Whole run | `stop=answered`, 2 turns, **11332 ms**, context 2048 tokens |

The answer named `BRK-990-XP`, quoted **2 units** in **Aisle 4, Shelf B**, and
laid out the manual's six procedure steps and three required tools. Those stock
figures come from the device's own database — they are not facts about
elevators, so a model answering from its weights could not have produced them.
That is the whole grounding claim, met end to end.

**What it settles about the prompt budget.** The host suite could only measure
characters; this run puts a real prompt through a real 2048-token window and it
completed. 1510 characters of prompt plus 1401 of generated answer is
comfortably inside it, so `maxDocuments: 2` is not the binding constraint for a
single-code inquiry. It is *not* a measurement of the ceiling — this retrieval
returned one document, not the two the cap allows.

**Still not measured: throughput.** The run reported one total (11332 ms for two
turns), which cannot be split into tokens per second. The suite now prints
per-turn elapsed and generated chars/s, so the next run closes it.

### What the device run found that the host could not

TC-AGENT-E2E-01b — the companion asserting an out-of-scope inquiry retrieves
nothing — **failed on its premise**, at `expect(retrieved.isEmpty, isTrue)`,
before the model was asked anything. Two independent causes:

1. Its fixture said "the hydraulic ram on the loading crane is leaking", and
   `hydraulic` is in the manual: E-204 is *Proportional Valve Flow Discrepancy*
   and its symptoms name the hydraulic manifold. Choosing a hydraulic term as
   the out-of-domain word for an elevator manual was just wrong.
2. **Stop words match, and this one is a property of the retrieval path rather
   than of the fixture.** The sanitizer joins terms with `OR` (deliberately —
   see _Offline retrieval_) and FTS5's `porter` tokenizer removes no stop words,
   so `the`, `on` and `is` each retrieve entries on their own. The fixture would
   have matched with `hydraulic` removed, and so does *"the coffee machine in
   the lobby is broken"*, which contains no elevator word at all.

**Consequence, recorded rather than fixed here.** The no-match block — the thing
that tells the model there is no entry and forbids a tool call — is reachable
far less often than the design assumes. A technician asking about something the
manual does not cover will usually get two *irrelevant* entries and a preamble
instructing the model to answer only from them. That is a plausible route to a
confident wrong answer, which is the failure the whole retrieval path exists to
prevent.

It is **not** fixed in Task 1.9, because the fix belongs to the router and the
obvious versions are all bad: a hand-written stop-word list is the
enumerate-the-attacks shape Task 1.4 already learned to avoid, and any
document-frequency or bm25 threshold tuned against a **three-document** corpus
would be a number with no evidence behind it. It needs a real decision and
probably a bigger corpus. Recorded here, in the sprint plan, and pinned by
`test/services/ai/tc_agent_e2e_premises_test.dart` so it cannot be rediscovered
by accident.

The fixture itself moved to the phrasing TC-RAG-COMP-01 already verified empty,
and both device premises now live in `integration_test/e2e_fixtures.dart` with
host tests asserting them in CI — none of that needed a device, and the run
spent a build, a 2.6GB transfer and four minutes to learn it.

## Golden transcripts

Six scripted agent runs, each snapshotted whole into
`test/golden/snapshots/<scenario>.json` and compared byte-for-byte on every CI
run. The suite lives in `test/golden/` and splits three ways: the scenarios
(`llm_golden_test.dart`), the serializer (`transcript_snapshot.dart`) and the
comparator (`golden_file.dart`).

Only the **model** is faked. Retrieval, prompt compilation, the loop, the guard,
the registry and the database are the real ones, over the real seeded asset — so
a golden is a statement about the whole vertical slice rather than about one
class.

### What a golden buys that a property test does not

Tasks 1.2–1.9 assert *properties*: this prompt contains that marker, that payload
reached the next turn. A golden asserts the **whole artefact**, which is the only
assertion that notices a change nobody thought to write a property about — a
reworded preamble, a reordered document field, an extra blank line between
transcript blocks, a fault code that stopped resolving, a tool payload that
gained a key. Every one of those changes the string a 2.6GB model is asked to
reason about, and none of them fails a single other test in this repo.

### The six scenarios

| Scenario | What it pins |
|---|---|
| `e102_native_tool_call` | The spec's §5.2 walkthrough: code resolved structurally, one document compiled, a native tool call, the real stock figure in the second prompt. |
| `e305_degraded_text_call` | The guard's text path, a name the model misspelled and the guard canonicalised, a zero-stock payload, and `escapeQuotes` over 1.2's hostile inquiry. |
| `no_manual_match` | Retrieval empty → the no-match notice → no tool called. |
| `iteration_cap` | Four turns with a *different* SKU each time, so the cap is what stops it rather than the repeat short circuit. |
| `recovery_ladder` | A guard refusal, then a `missing_parameter` from the registry, then a good call, then the answer — exactly `maxTurns` turns *and* an answer. Holds the suite's widest prompt at 2363 characters — effectively tied with `iteration_cap`'s 2347. |
| `unknown_tool_repeated` | An unresolvable name reaching `dispatch` as `unknown_tool` (not a guard failure), then the same call replayed rather than re-executed. |

### Why the snapshots look the way they do

Four rules, each a decision rather than a formatting preference:

1. **Multi-line strings are stored as arrays of lines.** A one-document grounded
   prompt is 933 characters over 14 lines, and the widest prompt in the suite is
   2363; as one JSON string a one-word change to the preamble produces a diff
   nobody can read. Splitting on `\n` is lossless and makes the diff
   line-precise.
2. **The files are 7-bit ASCII.** `jsonEncode` passes U+0085, U+2028, U+2029 and
   U+007F through raw, and two of those are Unicode *mandatory* line breaks — so
   a golden could otherwise hold a character that editors and diff tools treat as
   a newline while the harness's own line count does not. They are re-escaped as
   `\uXXXX`, which keeps the file valid JSON and lossless (asserted, not argued).
3. **Nothing environmental is recorded** — no timestamps, no temp paths, no
   durations. `ToolFailure.cause` is deliberately absent: it quotes the database
   file path, which is a fresh temp directory every run.
4. **`Set`-typed retrieval hits are sorted.** They iterate in insertion order
   today, but that is a property of `LinkedHashSet` rather than of the type.

### Regenerating

```bash
UPDATE_GOLDENS=1 flutter test test/golden
```

Two properties of that flag matter more than the convenience. A rewrite that
**changes** a file still fails the test, so one `flutter test` invocation with the
flag set by accident cannot turn a real regression green — it can only be green
when the flag changed nothing. (Stated at that width deliberately: *two*
invocations in one job would be green, because the first rewrites and fails and
the second matches. Worth not over-claiming rather than engineering around.) And
the diff is printed in the rewrite report too: a regenerated golden nobody read is
the same problem as a golden nobody wrote.

### What mutation testing changed

**47 mutations, 0 survivors** — 25 against the serializer, 17 against the
comparator, and 5 against the committed snapshots themselves. That last group is
the most direct evidence this task can produce, and it exists because 1.10 ships
no `lib/` code: its production artefacts are the harness *and the goldens*, so
tampering with a golden's stock figure, its turn count, a line of its grounded
prompt, its rejection reason or its trailing newline is a mutation like any other.
Every one of the five failed a test (3, 4, 4, 1 and 4 tests respectively). A
golden that can be edited with the suite still green is decoration.

Every row failed at least one test; the widest is `reconcileGolden` always
returning `match`, at 13. Exactly one row — the mutation that makes the golden
write fire on any mismatch — causes a write to a file it did not edit, and the
harness detects that by mtime, which sees it whether or not the write persists.

Per-row counts are a reading of one run rather than an invariant: a 1.7
provisioning test flakes occasionally under `--concurrency=8`, so a row can carry
±1 unrelated failure. **And the exposure runs the opposite way from the obvious
guess** (review finding R2-F2). A survivor is not "a row with no failures" — it is
a row whose suite **exit code was 0**. A flake only ever *adds* a failure, so it
cannot rescue a killed row; what it can do is **mask a survivor**, by making a
mutation with no genuine failures exit non-zero and be reported `KILLED`. So the
0-survivor result does depend on the flake not landing on a would-be survivor,
which is the only direction in which this noise can change a conclusion rather than
a number. The harness now names the known-flaky tests and reports a row whose
failing set is a *subset* of them as `INCONCLUSIVE` rather than as a kill, so the
case is detected instead of assumed away.

Two more rows are refused the same way, on the same principle — a kill is a failure
the mutation *caused*, so a row with nothing attributable to point at is not one. A
non-zero exit that names no test at all is `INCONCLUSIVE`. And a mutation that does
not **compile** is `COMPILE_ERROR`.

That last case is worth describing accurately, because two earlier attempts at it
here were wrong in the same direction (review finding R4-F1). Measured, by breaking
`transcript_snapshot.dart` and running the harness's own command: **499 of the 554
tests execute and pass.** What fails is the *loading* of the files that import the
mutated library — `llm_golden_test.dart` and `golden_harness_test.dart` — which
loses exactly their 55 tests, and 554 − 55 = 499. So it is not "no test runs"; it is
that **the tests which could have judged this mutation are precisely the ones that
never ran**, while the rest of the suite carries on passing. The reporter's
`loading <path>` lines are then captured by the harness's parser as though they were
failing tests, so the row arrives with a non-zero exit and a failing set containing
nothing the mutation's behaviour caused — and before this was fixed it was recorded
as `KILLED`: a row about which **nothing was learned**, filed as a kill, with several
pieces of apparent evidence. At worst that hides a mutation that would have
*survived*; some non-compiling mutations would have been killed and were filed
correctly by accident. Which of the two it was is exactly what cannot be known, since
the tests that would have decided it are the ones that did not run.

Nor is the captured set an enumeration of what broke: **3** `loading` names were
captured against **2** actual `Failed to load` failures, the extra one an unrelated
suite file — a reporter artefact rather than a list.

The bug was unreachable-by-accident rather than by design — the old detector wanted
two substrings on one line that the runner prints on separate lines (R3-F1). It
changes none of the numbers above, since no row in any completed sweep has a
`loading` entry, but it was live for the next mutation anyone wrote.

**The first version of these numbers came from a harness that could corrupt its
own inputs, and that is the most useful thing this task learned.** It reverted the
file it had *edited*, not the surface a mutation can *damage* — and one mutation
makes the suite overwrite a committed golden.

What that cost depends on a race, which is the point. Under `--concurrency=8` the
corrupting test and the scenario test that reads the same golden run in either
order, and the mutated write fires on any mismatch — so the scenario test *repairs*
the golden as a side effect if it runs second. Two runs of the identical harness
landed on opposite sides: one self-healed and reported a clean 44/44 (only the
corrupting row itself saw a dirty tree), and one did not, so nine later rows
carried collateral failures and the last five never ran at all. **A harness that
can silently repair its own damage is worse than one that crashes, because only the
crash tells you.**

The fix is mechanical, not attentional: revert the whole surface, assert the whole
surface is clean before each row, and detect per-row collateral **by mtime** rather
than by `git status` or a content hash — neither of which can see a
damage-then-repair pair, since the repair restores the original bytes. That last
part is itself a corrected claim: the first version checked `git status` after the
run and therefore reported nothing on the run that self-healed.

Four properties had **correct code and nothing holding it there** — three found
while designing the mutation set, and one the review found afterwards:

* **The `Set` sort.** No scenario retrieves two hits whose insertion order
  differs from sorted order, so removing the sort left every test green. It is
  now bound by a test that builds the disagreeing case by hand — which is why
  `sortedHits` is public rather than private.
* **`verifyGolden`'s `fail()`.** TC-GOLD-02 deliberately goes through
  `reconcileGolden` (it needs a *value*, since a test cannot assert that a
  failure was readable if the failure aborts it), which left the abort itself
  unbound: deleting it made all six scenario tests pass unconditionally.
* **The update-flag predicate.** Inline, it could only ever be exercised with
  whatever the ambient environment held, so widening it to `value != null` stayed
  green in a normal run. Extracted as `updateRequested(String?)` and tested
  against eight spellings.
* **The golden write itself** (found in review). `verifyGolden` baked in both the
  `File` and the environment read, and Dart cannot change the process environment
  in-process — so under `flutter test` the rewrite branch never executed at all,
  and deleting both of its statements left the whole suite green. The test that
  *claimed* to bind it wrote the file itself and never called the function. Now
  `applyGolden(file:, update:)` takes both as parameters and three tests exercise
  it in a scratch directory. Same defect class as 1.4's `assert`ed clamp, one
  layer further out: the code that checks the code is code.

The pattern is the one this repo keeps recording: the lines a golden suite cannot
check are exactly the lines *of the golden suite*, and they need ordinary tests
like anything else.

### What this suite cannot do

* **It cannot notice a field the serializer never recorded.** Deleting a key from
  the serializer breaks a golden — the committed files *are* the regression guard
  for its completeness — but adding a field to `AgentTurn` and forgetting to
  serialise it is invisible. Flutter has no mirrors, so there is no mechanical
  guard; the mitigation is that `transcript_snapshot.dart` lists what it
  deliberately leaves out.

  **That guard is not uniform, either.** It is total for the top-level and
  per-turn keys, which every golden has; below them it thins out with coverage.
  Invocations per golden are 1, 1, 4, 0, 2, 2, so the invocation and outcome keys
  are guarded by five of six. Rejections are 0, 0, 0, 0, 1, 0 — so the two keys
  under `_rejection` are guarded by `recovery_ladder` **alone**. That is the thin
  spot, and naming it is better than averaging it away.
* **It cannot tell a good transcript from a bad one.** A golden says "this is what
  the code does", never "this is what the code should do" — which is why each
  scenario carries semantic assertions beside the byte comparison. Without them a
  serializer that emitted `{}` would keep all six green forever.
* **It is not a model evaluation, and it is not a device test.** The run is
  deterministic only because `FakeLlmEngine` is; a golden over the device engine
  would be a flake generator.

## The demo screen

One screen, and the whole Tier 1 slice behind it: type a fault, tap **Diagnose**,
and the on-device model streams a repair plan grounded in the bundled service
manual, checking the local warehouse table on the way.

```
[ technician types: "cabin vibrating, E-102" ]
        │
        ├─ RetrievalRouter ──── E-102 → structured column; "cabin vibrating" → FTS5
        ├─ PromptCompiler ───── [MANUAL DOCUMENT] + [USER INQUIRY]
        └─ AgentLoop ────────── Gemma 4 E2B → native tool call
                                      │
                                      ├─ get_local_parts_inventory(BRK-990-XP)
                                      │        → {in_stock: 2, aisle: "Aisle 4, Shelf B"}
                                      └─ turn 2 → grounded answer, streamed to screen
```

`lib/views/diagnose_screen.dart` renders it; `lib/viewmodels/field_job_viewmodel.dart`
folds `AgentLoop.run`'s event stream into the state it draws from. The composition
itself really is three lines, which is the point of everything above it:

```dart
final retrieval = await router.retrieve(inquiry);
final prompt = compiler.compile(retrieval);
final loop = AgentLoop(engine: warmup.engine, registry: registry);
```

### The three deferred wirings

Tasks 1.3 through 1.10 each shipped a piece of the slice with no production call
site, and each recorded the same reason: the piece needs a `DatabaseService`, and
opening a database needs an encryption key nobody had decided on. This is where
that ends.

**1. The database, and therefore the key.** `databaseEncryptionKeyProvider` reads
`--dart-define=FIELDOPS_DB_KEY` and falls back to a constant named
`demoDatabaseKey`, whose value is literally `fieldops-demo-key-not-a-secret`.

That name is doing work. A hardcoded key is acceptable for a demo and the brief
says so, but only as a *recorded decision* — and the honest recording is that the
cipher is real while the key management is not. ChaCha20-Poly1305 with pinned KDF
iterations means a database file lifted off the device is ciphertext; a passphrase
compiled into the binary means anyone who can read the app bundle can read the key.
So this protects a stolen **file** and not a stolen **device**, and §3.2's
"sensitive data remains sandboxed on the physical device" is true of the storage
and only partly true of the threat model. The fleet answer — a key generated on
first launch, held in the Keychain or Keystore behind device-passcode protection,
never present in the binary — slots in behind this one provider without touching
anything downstream, and is Appendix A's story.

One operational hazard, because it is silent: the key is part of the database's
identity. Add the define to a build that previously used the demo key and the
existing file cannot be decrypted. It surfaces as a rendered startup failure on the
screen, not as a fresh empty database, which is the failure worth fearing.

**2. The first-launch seed — as a dependency, not a call order.** `ensureSeeded()`
is called by `seedOutcomeProvider`, and everything on the retrieval path takes its
database from `seededDatabaseProvider`, which cannot resolve until that has:

```dart
final seededDatabaseProvider = FutureProvider<DatabaseService>(retry: noRetry, (
  ref,
) async {
  await ref.watch(seedOutcomeProvider.future);
  return ref.watch(appDatabaseProvider.future);
});
```

It is the same `DatabaseService` instance — nothing is wrapped — and the only thing
it adds is an edge in the graph. A `main()` that called `ensureSeeded()` and then
passed the database around would behave identically today, and would be one new
entry point away from a screen querying an empty manual. Here there is no call
order to get wrong, because there is no handle with which to make an unseeded
query. A router over an unseeded database is the nastiest version of this bug: it
answers every inquiry with *nothing*, which the prompt compiler renders as its
no-match block, so the failure looks like a manual that has no entry for anything,
phrased confidently.

**3. The real engine, loaded before the UI needs to be interactive.**
`agentEngineProvider` is the `LlmEngine` seam the screen resolves, and
`EngineWarmupController` calls `initialize()` on it from the screen's own
post-frame callback — so the weights load at app start, never on the Diagnose tap.

**The plan predicted a different mechanism and the prediction does not
type-check**, which is worth stating rather than quietly diverging from: it said
"override `llmEngineProvider` with `deviceLlmEngineProvider` in a `ProviderScope`",
but `llmEngineProvider` is a synchronous `Provider<LlmEngine>` and resolving the
device engine means awaiting a verified model path, so the real binding is
unavoidably a `Future`. Nothing upstream of the `LlmEngine` interface changed,
which was the part of the prediction that mattered.

`agentEngineProvider` answers **`null`** rather than falling back to the fake, and
that is the decision most worth reading here. The fallback is one line and it is
tempting, because it would make the screen work everywhere. What it would produce
is an app that answers a technician's inquiry fluently, in well-formatted prose,
from a scripted list — on a machine where the model never ran. There is no worse
failure mode in this project, because it is indistinguishable from success in a
screen recording, which is the artefact this task exists to make. So `null` is a
first-class answer, the status row says "no verified weights on this device — the
agent cannot run", and the button is dead. Tests reach the fake by overriding
*this* provider, which is a deliberate act in a test file.

### Nothing animates while the model works

This is the design constraint Task 1.8's measurements imposed, and it is the one
thing on this screen that would be wrong in an obvious implementation.

On the demo device (iPad Air M4, iOS 26.5, Metal) Task 1.8 measured the **UI
isolate** stalling **1445–1728ms** while the weights load — roughly 90 dropped
frames at a 16.7ms budget — and dropping **5–8 frames** (77–135ms worst gap) while
tokens stream. Inference genuinely runs on a background isolate the app owns; what
stalls is the load, and the cause is still open (Task 1.8-F eliminated Metal
pipeline compilation with a forced-CPU run that stalled *worse* while loading
faster; memory traffic during the `mmap` walk and a shared-heap GC pause remain
live).

The trap: what stalls is the **UI isolate**, so a spinner displayed *during* the
load freezes with it. A frozen progress indicator reads as a crashed app, which is
strictly worse than a static label that says what is happening. So:

- there is no `CircularProgressIndicator` and no `LinearProgressIndicator` anywhere
  in `diagnose_screen.dart`, and `test/views/diagnose_screen_test.dart` asserts that
  **structurally** — it walks the tree for any `ProgressIndicator` in the loading
  state, the generating state and the tool-running state, rather than trusting this
  paragraph;
- `EngineWarmupController` sets `EngineLoading` *before* awaiting the load, so the
  frame carrying the static row is painted on the other side of an await boundary,
  i.e. before the work that blocks the isolate begins;
- warm-up is kicked off from a post-frame callback, so the first frame exists before
  the stall — calling it synchronously in `initState` would stall the isolate before
  anything was on screen, which is a launch that looks like a hang;
- the **live token stream is the progress indicator**. Text appearing is
  unambiguous evidence of work, it cannot stutter in a way that reads as a hang, and
  it is the most convincing thing in the recording.

One exception stays, and it is a different thing: `ModelReadinessBanner` shows a
determinate bar while *downloading* weights. A download is network I/O with no
UI-isolate stall, and that widget is Task 1.7's.

### All three stop reasons render differently

`AgentStopReason` has three values and `AgentLoop` authors truthful, non-empty text
for every one of them — `answered` carries the model's words, `emptyResponse` and
`iterationCapReached` carry loop-authored messages. That is a trap for the UI: a
screen could render all three identically and look correct in every test, while
handing a technician *"the assistant kept requesting warehouse lookups without
producing an answer, so it was stopped"* in the same panel, with the same styling,
as a repair plan.

So the viewmodel exposes one question — `FieldJobState.isDiagnosis` — and the
screen branches on it once:

| Stop reason           | Header               | What it means                                |
| --------------------- | -------------------- | -------------------------------------------- |
| `answered`            | **Repair plan**      | the model's own words, grounded              |
| `emptyResponse`       | No answer produced   | nothing to render, said out loud rather than shown as a blank panel |
| `iterationCapReached` | Diagnosis stopped    | the loop reports its own failure; it does not invent a diagnosis |

Each outcome panel carries a key derived from the enum
(`diagnose-outcome-<name>`), and there is one test per ending asserting that
exactly its own panel is on screen and the other two are not.

**Task 1.10 handed this task a gap and it is only half closed.** `emptyResponse`
has no golden — two of the three stop reasons do — and adding the third scenario
here was not possible: `test/golden/` exists only on Task 1.10's branch (PR #11),
so there is no file in this tree to add a scenario to. Stacking this task on that
branch to reach it would have dragged 1.10's whole diff into this PR or forced a
rebase of an open PR, which costs a re-run of its 47 mutations. Instead the third
ending is bound where it is actually needed — the viewmodel suite asserts the state
and the widget suite asserts the rendering — and the golden is a one-line follow-up
for whoever lands PR #11. Recorded as unfinished rather than quietly dropped.

### What the screen shows besides the answer

- **A "grounded in" line**, naming the manual entries retrieval found, on screen
  *before* the first token. That ordering is deliberate: a grounding line that
  appears with the answer annotates it, one that appears first frames it. It is the
  architectural claim made visible — a viewer can see which documents the model was
  given and compare them to what it said.
- **A tool-activity line** while a lookup is in flight ("Checking local inventory
  for BRK-990-XP…"), which is possible only because Task 1.9 emits
  `AgentToolCallStarted` *before* running the query. It clears when the lookup
  completes, not when the run ends — a distinction that survived only because a
  mutation caught it: `AgentCompleted` also clears the field, so dropping the clear
  from the completion event left every test green while the indicator would have
  claimed a lookup was running through the entire second turn, over the streaming
  answer.
- **Completed lookups, summarised from the payload** rather than from the
  arguments, so a viewer comparing the line to the answer is checking the grounding
  by eye. Task 1.5's two success shapes stay apart on the page for the reason they
  are apart in the payload: "the warehouse does not carry NOT-A-REAL-SKU" and
  "BELT-330-DRV is carried but out of stock" are different sentences to a
  technician.
- **Refused call attempts**, reported rather than dropped. A technician watching the
  model fumble a call and recover is the agent loop being legible instead of
  magical, and silently hiding them would make a four-turn run look like an
  inexplicably slow two-turn one.

### Failures are screens, not exceptions

A malformed seed asset or a key that no longer opens the database is a **build or
configuration defect**, and Task 1.3 asked for it to fail loudly at startup. Loudly
means legible: the error arrives as an errored `AsyncValue`, the screen renders it
with the message attached, and Diagnose is dead until it is fixed. A grey screen
with a stack trace in a console nobody is reading is the quiet version.

A run that throws is a *different* thing and renders differently: the screen says
what failed and the button comes back, because "that attempt did not work" and
"this app is misconfigured" ask different things of whoever is looking.

`on Exception`, never `on Object` — the rule `ToolRegistry.dispatch` writes down,
one layer up. An `Error` means the app is broken, and dressing it as "the diagnosis
could not be completed" hides a defect behind a plausible operational message.

### A Riverpod 3 default that is wrong for every startup provider here

Worth its own heading because it is a framework behaviour, not a choice, and it
silently converts "fail loudly at startup" into "hang for half a minute, then fail".

`ProviderContainer.defaultRetry` retries a provider whose body threw, with
exponential backoff — 200ms doubling to a 6.4s cap, ten attempts — and it skips
only `Error` and `ProviderException`. Every ordinary `Exception` is retried.
Measured, by removing the policy and sampling: the seed provider's body ran **11
times** and the element was still `AsyncLoading` at 30s, `AsyncError` by 45s.

All three ways this app's startup fails are deterministic — a malformed asset
(`SeedFormatException`), a key that does not open the file (`SqliteException`), a
platform channel with no implementation (`MissingPluginException`) — so a retry
cannot change the outcome. Worse than the delay is what is on screen during it: the
provider stays in `AsyncLoading`, so the UI says "checking…" for half a minute and
*then* reports a failure that was settled on the first attempt.

`lib/services/retry_policy.dart` exports `noRetry`, applied per provider along the
whole startup chain (including 1.7's model-status providers, which sit upstream of
the engine seam and would otherwise hold the chain in `AsyncLoading` regardless of
what the ones below declare). Scoped per provider rather than set container-wide on
purpose: a container-wide default would silently apply to the next provider someone
adds, including one that really is transient and really should back off. Naming the
policy at each site keeps the claim — *this failure is deterministic* — next to the
code that has to be true for it. It is the same rule
`ModelProvisioningController` already writes down for a download that failed its
digest: "a retry moves the same gigabytes and fails the same way."

**How much of that is bound by a test, measured site by site.** Every one of the
eleven `retry: noRetry` sites was mutated individually — the policy deleted, the
whole relevant suite run — at the tree this paragraph ships with. Six die, five
survive:

| bound (deleting `noRetry` fails a test) | unbound (deleting it leaves the suite green) |
|---|---|
| `seedOutcomeProvider` (4 tests) | `appDatabaseProvider` |
| `seededDatabaseProvider` (1) | `retrievalRouterProvider` |
| `modelStorageProvider` (1) | `toolRegistryProvider` |
| `modelProvisionerProvider` (1) | `inferenceConfigProvider` |
| `modelInstallStatusProvider` (1) | `deviceLlmEngineProvider` |
| `agentEngineProvider` (2) | |

The two that matter most are bound deliberately, by build counters:
`seedOutcomeProvider` over a malformed asset, and `modelInstallStatusProvider` over
a `MissingPluginException` from `modelStorageProvider` — the failure every host
widget test actually hits, and the site whose own doc makes the strongest claim in
the set (that the banner would otherwise sit on "Checking model…" for half a minute
before reporting a status it says must be distinguishable from ready and absent).
The other four die as a side effect of those two counters and of tests that would
time out without the policy.

The five survivors are recorded rather than engineered around: each is upstream or
downstream of a bound site, and no test reaches its own failure path. They are not
*wrong* — the policy is right at every site, for the reason above — they are
**unguarded**, which is a different and smaller claim than the one this paragraph
first made. The first version said "bound by a test that counts provider builds"
with no qualifier, which was true of exactly one site out of eleven (review finding
R0-F4).

One methodological note, because it nearly produced a false table. Seven of these
eleven mutations initially came back **`NO_OP`** — a bug in the script that
generated them meant the edit did not change the file at all. The harness reports
that as its own status rather than as `SURVIVED`, which is the distinction Task 1.9
built it for: *a survivor is evidence about the tests only once the edit is
confirmed to change something.* Filed as survivors, they would have produced a
published claim that nine of eleven sites were unbound, from seven measurements
that never ran.

### Two things a host test cannot tell you, found by watching tests fail

Both are recorded because each cost a debugging session and neither is guessable:

- **`pumpEventQueue()` hangs inside `testWidgets`.** It awaits a zero-duration
  `Future.delayed`, whose `Timer` the widget binding *fakes*, so nothing ever fires
  it and the test sits until `pumpAndSettle`'s ten-minute deadline. Real
  asynchronous work in a widget test needs `tester.runAsync`, which is the only way
  the real event loop gets a slice.
- **On the host this slice is too fast to observe.** drift's `NativeDatabase` runs
  sqlite3 **synchronously in-process** (not `createInBackground`), and
  `FakeLlmEngine` replays a turn as fast as it is drained — so retrieval,
  compilation, both model turns and the inventory query all complete inside the
  microtasks `tester.tap` awaits. There is *no frame* in which the run is in flight.
  A test that taps, pumps once and asserts the button is disabled fails, not because
  the button is wrong but because the state came and went between frames. So the
  intermediate rendering is bound by injecting a `thinking` state, and the wired
  test listens to the phase sequence instead of sampling frames. On device the run
  takes seconds and the frames exist, which is what `demo_flow_test.dart` is for.

That is also why the widget suite is split: *rendering* tests inject a
`FieldJobState` and an `EngineWarmupState` and assert what is drawn (synchronous,
un-flakeable, and the only way to reach `EngineLoading` at all on a host), while two
*wiring* tests run the real graph through the button to prove the screen is
connected to the state machine the other suite tested.

### The no-match path: do not demo it yet

Carried in from Task 1.9's device run and unresolved. The words `the`, `on` and `is`
each retrieve manual entries on their own — Task 1.2's sanitizer joins terms with
`OR` and FTS5's `porter` tokenizer removes no stop words — so almost any English
sentence is a full-text hit, and an inquiry the manual has no entry for usually
retrieves two *irrelevant* entries instead of triggering the no-match block. On
stage that renders as a confident, well-formatted answer about the wrong fault.

The screen does the honest thing when retrieval is genuinely empty ("No manual entry
matched. The assistant has been told not to invent a procedure."), and the grounding
line always names what was retrieved, so a viewer can see the mismatch. But the
retrieval fix is not in this task: every obvious version is bad, and a threshold
tuned against a three-document corpus is a number with no evidence. **Keep the demo
on inquiries the manual covers and narrate the no-match design rather than running
it.** Pinned by `test/services/ai/tc_agent_e2e_premises_test.dart` so it cannot be
rediscovered by accident.

### Running it

```bash
flutter run -d <device> \
  --dart-define=FIELDOPS_MODEL_ID=gemma-4-e2b-it-int4 \
  --dart-define=FIELDOPS_MODEL_URI=<resolve URL for the file you licensed> \
  --dart-define=FIELDOPS_MODEL_SHA256=<its sha256>
```

Without the defines the app runs, the banner says the model source is not
configured, and Diagnose stays dead — which is the correct behaviour, not a
degraded one. Add `--dart-define=FIELDOPS_DB_KEY=<passphrase>` to use something
other than the named demo key.

The on-device acceptance test is `integration_test/demo_flow_test.dart`
(TC-UI-DEMO-01). It is the only test in the repo that pumps `FieldOpsApp` with **no
overrides at all**, so it is the only one that exercises the three wirings as the
app performs them: the real application-support directory, `rootBundle` and a real
`AssetBundle`, and the real 2.59GB artifact. Every one of those is faked in the host
suite, so a failure in any of them is invisible to it.

### What the device run measured

**TC-UI-DEMO-01 passed twice** on the demo device (iPad Air M4, iOS 26.5, Metal
backend, real 2.59GB artifact). Both runs were a genuine first launch —
`SeedApplied(revision: 1, manuals: 3, parts: 5, previousRevision: null)`, so the
real asset bundle reached the real database through `rootBundle`.

| | run 1 | run 2 |
|---|---|---|
| warm-up elapsed | 7822ms | 7395ms |
| **worst UI-isolate gap during the load** | **2130ms** (~127 frames) | **1866ms** (~111 frames) |
| frames the no-animation guard was checked on | not instrumented | **60** |
| diagnose flow elapsed | 13296ms | 13665ms |
| **worst UI-isolate gap during the flow** | **247ms** (~14 frames) | **250ms** (~14 frames) |
| answer length | 1401 chars | 1401 chars |
| characters per second, whole flow | ~105 | ~103 |
| stop reason | `answered` | `answered` |

Frame counts are derived on the page (`worstGap / 16.7`), not maintained by hand.

Four things worth stating at the width they were actually measured:

- **The load-time stall is confirmed and is at the high end of Task 1.8's range.**
  1.8 measured 1445ms and 1728ms on the GPU backend and 2197ms forced onto the CPU;
  2130ms and 1866ms sit inside that spread but above both GPU figures. The same
  caveat 1.8 attached to its RSS figure applies here: both of these runs downloaded
  the 2.6GB artifact **in the same process moments earlier**
  (`FIELDOPS_TEST_PROVISION=true`), so they are an upper bound rather than a
  side-loaded measurement. The cause is still Task 1.8-F's open question.
- **The design holds where it matters.** Run 2 asserted, on **60 separate frames of
  the real 7.4-second load**, that no `ProgressIndicator` was in the tree — so the
  ~111 dropped frames land behind a static row, which is the entire point. The
  frame count is asserted to be non-zero, because a guard that never ran is not a
  guard.
- **The 247–250ms gap is *not* comparable to Task 1.8's 77–135ms**, and the
  difference is the measurement window rather than the device. 1.8 timed token
  streaming; this probe spans the whole diagnose flow — retrieval, prompt
  compilation, two model turns, the SQLite inventory query and the loop's
  continuation prompt. It is the honest figure for the flow being screen-recorded,
  and at ~14 dropped frames it is a visible hitch, which is why nothing on the
  screen animates through it.
- **Throughput: this is the long generation the plan asked for, and it yields
  characters, not tokens.** 1401 characters in 13296ms across two turns is ~105
  chars/s — and that window includes retrieval and a tool round trip, so it is a
  *lower bound* on generation speed. It is deliberately **not** converted to
  tokens per second: the app exposes no tokenizer, and multiplying by an assumed
  chars-per-token ratio is arithmetic rather than measurement, which is exactly
  what got Task 1.8's "2.7 tok/s" struck from the record. **§3.1's 15 tok/s target
  therefore remains formally unmeasured**, and closing it needs a token count from
  the runtime rather than another run.

**These two runs are of the code as it stood at `8ca9e6c`, not as it ships**, and
the gap is named rather than left to be inferred. Review round 0 produced changes
after them, and the demo iPad then dropped to wireless tethering, where
`flutter test` cannot launch (`Cannot start app on wirelessly tethered iOS device`)
and `flutter run --publish-port` fails at mDNS VM-service discovery. A cable was
needed and was not available at the time, so a third run was **owed** — and it has
since been made (2026-08-07, iPad Air M4 / iOS 26.5, cabled): warm-up 8540ms with a
worst gap of **2151ms**, flow 13247ms with a worst in-flow gap of **233ms**, 1401
chars at ~106 chars/s, `stop=answered`, 71 loading frames asserted. Two things to
carry from it. The **2151ms warm-up gap is a new worst**, above Task 1.8's
1445–1728ms band — that run was a first launch, so seeding shared the window, but it
is worth re-checking on a warm start. The **233ms in-flow gap is the best of the
three**, which is the figure the recording depends on.

What the third run settled, and what it did not:

* **Still valid, because nothing in the change touches them.** Every number in the
  table above comes from the model, the inference isolate and the database — the
  load time and its stall, the flow's elapsed time and worst gap, the answer text
  and its length, the seed outcome, the stop reason. None of the round-0 changes
  goes near the isolate, the runtime, the prompt or the database. Run 2 also
  exercised the per-frame no-animation guard as it ships (60 frames).
* **Confirmed on device by the third run and by a screen recording of the shipped
  app.** The Markdown formatter renders bold headings and `•` bullets with no raw
  `**` in the finished answer; TC-UI-DEMO-01's formatted-answer assertion executed
  and matched; the outcome panel shows its green ✓ *Repair plan*. Auto-scroll
  *following* is confirmed visually — the panel tracks the growing answer and jumps
  rather than glides.
* **What the third run did *not* settle, and what a fourth is for.** Auto-scroll
  **release** — a reader dragging up mid-generation — was the one thing the run
  could not assert and the recording did not exercise, and driving the real app by
  hand then found it broken (**R12-F0**: the panel was *unscrollable* during
  generation, because `jumpTo` disposes the active drag). Fixed and bound on the
  host under both platforms' physics, but the fix itself has not run on hardware.
* **The error-path colour and icon cannot be reached from the UI at all.**
  `isDiagnosis` is `stopReason == answered`, and a no-match retrieval still ends
  *answered* — the model declines and asks for a fault code, so the panel is
  correctly green. The red ⚠ needs `emptyResponse` or `iterationCapReached`, neither
  reachable by typing. It stays bound by host tests, and this is recorded because
  the obvious manual test for it does not test it.
* **The one thing that would have failed on device and was caught by reading
  instead.** The Markdown fix broke the old `find.text(job.displayText)` assertion:
  `find.text` matches a `Text.rich` by `textSpan.toPlainText()`, i.e. the text after
  the delimiters were consumed, so it compared formatted against raw. The host suite
  could not see it, because every rendering fixture used markup-free answer text.
  Fixed on both sides and bound by a host test carrying the real answer shape — but
  it is the clearest evidence that a rendering change wants a rendering run.

One consistency check fell out of it: the answer was **1401 characters in all three
runs, and 1401 characters in Task 1.9's hand-built device harness** for the same
inquiry. That figure also resolved a scare: run 3's log shows `**Repair Prure:**`
where the screen recording of the same build shows `Repair Procedure:` rendered
correctly. A dropped token would have been a real defect in the streaming
accumulation — but the length is identical across runs, decoding is greedy, and the
*rendered* text is intact, so the corruption is in the **log transport below
`debugPrint`**, not in the app. The 1401 figure is itself computed in-app from
`job.displayText.length`, upstream of any printing, which is what makes the
comparison sound.

The stage matters and an earlier version of this paragraph got it wrong by blaming
`debugPrint` itself: `debugPrintThrottled` wraps *only* when `wrapWidth != null` and
this call site passes none, and its rate limiter defers **whole lines** past a 12KB
budget rather than truncating inside one — so a contiguous four-character elision
mid-word is not a behaviour it has. The loss happens further down, between the device
and the console. **Read answers off the screen, not off the console.** Decoding is greedy, so identical output is expected from an identical
prompt — which makes this evidence that the composition through the viewmodel and
the composition in 1.9's harness build the same prompt. Equal *length* is not proof
of equal text; it is consistent with it, which is as far as this observation goes.

## Microphone capture

Voice is the demo's differentiator, and it starts with bytes off the microphone.
`MicCapture` (`lib/services/audio/mic_capture.dart`) opens the mic and delivers
**16-bit little-endian mono PCM at 16 kHz** — the format `SttEngine.transcribe`
is declared over, and the rate the streaming zipformer of Task 2.2 wants.

`package:record` does the recording. It sits behind an `AudioInput` interface, the
same seam shape `ModelDownloader` uses, and for the same two reasons: the plugin
is imported by exactly one class, and everything *around* the recording runs in
host tests. That split matters more here than it looks, because almost nothing in
this component is about audio hardware:

| What | Where it is decided | How it is checked |
|---|---|---|
| Permission, and the difference between a refusal and a failure to ask | `MicCapture.start` | host |
| No empty buffers, no split samples | `MicCaptureSession._onRawBuffer` | host |
| A bounded backlog, and dropped audio the consumer cannot miss | `MicCaptureSession._enqueue` | host |
| Draining the tail of an utterance on `stop` | `MicCaptureSession.stop` | host |
| A format the platform substituted | `RecordAudioInput.describeFormatMismatch` | host (the decision), device (the wiring) |
| Real hardware produces real PCM at the right cadence | the device | **TC-MIC-01** |

### Four things read out of the plugin's source

Every one of these is a claim about `record` 7.1.1 / `record_ios` 2.1.1 /
`record_android` 2.1.2, arrived at by reading those packages rather than their
READMEs — Task 1.8's rule, which cost that task six review findings to learn.

**The stream has no backpressure, and drops what arrives before you listen.**
`AudioRecorder.startStream` returns a `StreamController.broadcast()` fed from a
platform callback (`_StreamMixin._startRecordStream`), and it `add`s only
`when ctrl.hasListener`. So buffers captured before the first `listen` are gone,
and a subscriber that pauses buffers audio in its subscription with no ceiling.
Both are the session's problem to solve: it subscribes immediately and holds a
**bounded** backlog, two seconds by default.

When that bound is hit the *oldest* audio goes, never the newest — a live
recogniser that falls behind should come back at the present moment with a gap
behind it rather than accumulate lag it can never pay off — and the newest buffer
is always kept, so a bound smaller than one platform buffer degrades to
latest-only instead of to nothing.

**Dropped audio travels with the audio.** `MicFrame.precedingGapBytes` carries
what was lost immediately before that frame. This is the one design choice here
worth arguing about, and the argument is that the alternative failure is
invisible: a recogniser fed a silently spliced stream returns a fluent,
well-formed transcript of a sentence nobody said. A counter on the session
(`droppedByteCount`, also present) is something a consumer has to remember to
read; a field on the frame is in their hands at the moment it matters.

**A second `startStream` closes the first one silently.** `AudioRecorder.startStream`
calls `_stopRecordStream()` before opening (`record` 7.1.1), which closes the
previous controller — so the first consumer's stream *ends with no error*, a
transcript that just stops mid-sentence. `MicCapture.start` therefore answers
`MicCaptureBusy` rather than restarting, and a start after a stop waits on
`MicCaptureSession.released`, because `isCapturing` goes false when the stop is
*asked for* and the recorder comes back later than that.

**`streamBufferSize` means different things on the two platforms, so it is left
unset.** `record_ios` passes it to `AVAudioNode.installTap` as an
`AVAudioFrameCount` — sample *frames*, defaulting to 1024. `record_android` passes
it to `AudioRecord` as `bufferSizeInBytes`. One number cannot mean both, so each
platform keeps its own default rather than this app picking a figure that is right
on one of them.

### The defect the host suite found

`stop()` originally cancelled the raw subscription and *then* released the input.
Buffers the plugin has already handed to its stream but not yet dispatched die
with the subscription, so every capture lost its tail — the last word of "…and the
brake is dragging", every time, with nothing to indicate it had happened. Six
tests failed on it at once.

The order is now: release first, wait for the plugin to close its own stream
(releasing is what closes it), *then* cancel. Which needed one more piece of
state: the window between "stop was asked for" and "no more audio will be
accepted" is precisely where those buffers arrive, so a stream `done` inside it is
the expected end rather than a fault. The wait is bounded (`drainGrace`, 250ms) on Task 1.11's
principle that a seam which hangs reports nothing and a frozen UI reads as a
crash; a test drives a plugin that never closes its stream and asserts both halves
— the audio still arrives, and the wait is a bound.

### What is deliberately not here

**Noise suppression**, even though the spec asks for it. `record_ios` 2.1.1 parses
`noiseSuppress` into its `RecordConfig` and never reads it again: the stream
delegate applies only `echoCancel` and `autoGain`, through
`setVoiceProcessingEnabled`. (`record_android` 2.1.2 *does* honour it, via
`AudioEffectsManager`.) Setting it would therefore be decoration on the device
this project is demoed from — a flag that looks like a feature. Ambient-noise
filtering stays in the narrated appendix where the sprint plan puts it.

**A Riverpod provider.** Nothing consumes microphone audio yet; the STT engine is
Task 2.2 and the form is 2.3, and both own UI this task does not. A provider added
now would construct an `AudioRecorder` — which calls a platform channel in its
constructor — for no reader, and could not be host-tested. Tasks 1.3 through 1.10
all shipped unwired for the same reason; the wiring belongs to the task that has
something to wire it to.

### The format-coercion tripwire, live on Android

`RecordAudioInput` registers
`setOnConfigChanged` and faults the capture if the delivered sample rate, channel
count or encoder differs from what was asked for, because 16-bit PCM at the wrong
rate does not error — it transcribes as nonsense, and a capture that cannot be
trusted is worse than no capture. The *decision* is a pure function and is
host-tested, including the case that matters most: the plugin fires that callback
whenever **any** of bit rate, sample rate or channel count was adjusted
(`RecordConfig.isModified`, both platforms), and bit rate does not exist for a raw
PCM stream — neither platform's PCM encoder reads it. Faulting a good capture
because the platform normalised an unused field would make the tripwire worse than
not watching at all. The *wiring* is host-tested too, by impersonating the platform
on `com.llfbandit.record/configChanged/<recorderId>`.

An earlier version of this section said the callback should never fire at all, on
the reasoning that neither stream path mutates the format. **Review finding R0-F3
refuted the Android half.** `FormatCodecSelector.findCodec` calls
`adjustToDeviceCapabilities(config)` *before* its `MIMETYPE_AUDIO_RAW` early
return, and that assigns `config.numChannels` from the routed input's advertised
channel counts — so on an Android device whose default input does not advertise
mono, a mono request is silently coerced to stereo and the tripwire is **live**.
Such a capture is faulted rather than degraded, deliberately: interleaved stereo
handed to a mono recogniser is every second sample from the wrong channel, and this
app does not downmix. Downmixing is the obvious alternative and belongs with
whoever owns the recogniser. iOS genuinely does not coerce — its stream delegate
resamples through `AVAudioConverter` and throws if it cannot.

### Two spec requirements this seam meets by not doing something

§3.2 asks for recorded audio at rest to be encrypted. Capture here is
**stream-only** — no file is ever written, no path is ever handed to the plugin —
so there is no audio at rest to encrypt. That is a requirement satisfied by a
design choice rather than by a mechanism, which is exactly the kind of thing that
looks unimplemented later, so it is written down here.

§3.1 names transcription as isolate work. `MicCapture`'s own per-buffer work runs
on the UI isolate and is O(1) at roughly sixteen buffers a second — a merge, a
remainder and a queue push — so it does not need one. The isolate boundary the spec
asks for belongs to the recogniser, which is Task 2.2, and it consumes the stream
this produces.

### What actually goes wrong, and what does not

Three fault paths existed here before review, and **two of them cannot happen**.
This is worth its own heading because the corrected version is the opposite of the
intuitive one, and because the comment that got it wrong was confident.

`record` 7.1.1's `_startRecordStream` subscribes to the platform stream with
`onData` and `onError` and **no `onDone`**, and neither native side ever ends its
event channel (`endOfStream` and `FlutterEndOfEventStream` appear nowhere in
`record_ios` 2.1.1 or `record_android` 2.1.2). So the broadcast controller the
session listens to closes only when `_stopRecordStream` closes it — from `stop`,
`cancel`, `dispose`, or a second `startStream`. A stream that ends *by itself* is
not a thing the plugin does, and the three causes the code once attributed to it —
a revoked permission, a route change, another app claiming the input — all go
somewhere else:

| What happens | What the app sees | Handled by |
|---|---|---|
| Android read failure | an **error** on the stream | `onError` → `MicCaptureFault` |
| iOS audio-session interruption | **silence** — the engine pauses under `AudioInterruptionMode.pause` and never resumes, tap still installed | `stallTimeout` |
| the plugin closing its stream | `done` **during** `stop` | the normal end, not a fault |
| a stream ending by itself | cannot happen on either platform today | the `onDone` fault, kept as forward-defence for the seam's contract |

The iOS row is the one that mattered, and it had no answer at all. Silence left the
session `isCapturing` with `frames` open forever — and since `SttEngine.transcribe`
consumes `frames` to completion, a phone call mid-dictation meant a transcript that
never arrived, on the device this project is demoed from. `MicCapture.stallTimeout`
(five seconds, `null` to disable) now faults it. It is re-armed by *any* buffer,
including an empty one, because a quiet room is a stream of near-zero samples
rather than an absence of buffers — so what it measures is a dead input, not a
pause in speech.

## Speech to text

`sherpa-onnx` running a **streaming zipformer** (en, 20M params, int8) on a
dedicated background isolate, behind `SttEngine`. Four files, 43.65MB, provisioned
by Task 2.0 from a committed ungated source — no build-time defines.

```
MicCaptureSession.frames ─▶ SherpaSttEngine ─▶ IsolateSttHost ═╗ isolate boundary
    Stream<MicFrame>          (state machine)                  ║
                                                               ▼
                          SttTranscript ◀── SherpaRecognizerRuntime ──▶ libsherpa
                         (text, rawText,        (every FFI call)
                          isFinal, segment)
```

The layering is Task 1.8's, deliberately: `sherpa_recognizer.dart` is the only file
in `lib/` that imports `package:sherpa_onnx`, `stt_config.dart` speaks this app's
vocabulary rather than the plugin's, and `SherpaSttEngine` takes an `SttHost` rather
than building one — so the engine's contract is verified on the host and the device
tests only have to prove the device part.

### The isolate is load-bearing here, not insurance

Task 1.8's isolate is a guarantee about *our* architecture rather than a bet on a
dependency: LiteRT-LM already keeps its worst work off the caller. sherpa-onnx has
nothing to insure. **Every entry point of its Dart API is a synchronous FFI call
that runs to completion on the calling thread**, read in
`sherpa_onnx-1.13.5/lib/src/`:

- `OnlineRecognizer(config)` is a *constructor* that loads three ONNX graphs —
  359–530ms (median 384) over ten consecutive runs here, 371–476ms over four on the
  reviewer's host.
- `decode(stream)` runs the encoder, decoder and joiner.
- `acceptWaveform` allocates native memory and copies the samples into it.

On the UI isolate that is a dropped frame per decode step for the length of an
utterance. Two more facts came out of the plugin's source rather than its README:

- **The FFI bindings are per-isolate.** `sherpa_onnx.dart` says so in capitals
  ("This must be called in every isolate that uses sherpa-onnx") and the mechanism
  is visible — `initBindings` writes static fields. The worker initialises itself;
  the UI isolate never touches the library.
- **No `RootIsolateToken` is needed**, unlike the inference worker. sherpa reaches
  its library through `DynamicLibrary.open` with no platform channel, and the model
  paths are resolved on the root isolate before spawning, so the worker never calls
  `path_provider` either. That asymmetry is worth knowing: the failure it avoids is
  a null `RootIsolateToken.instance` inside the worker.

`modelType` is passed as the **empty string, and that is the correct value**: sherpa
reads `model_type` from the encoder's own ONNX metadata, and this artifact reports
`zipformer` (v1, `decode_chunk_len=32`, `T=39`, `model_author=k2-fsa`). The example
in the plugin's own `online_recognizer.dart` docstring passes `'zipformer2'` — a
different architecture, and wrong for these weights. Copying the example would have
hard-coded a value the file it describes contradicts.

### One request, one reply — and that is the flow control

Inference is one request, many replies: a turn streams tokens back until `LlmDone`.
Recognition is **one request, one reply, every time**. A chunk of audio goes over
and the transcripts it produced come back — frequently none, and the reply arrives
anyway, because *the reply is the sender's permission to send again*.

That is the back-pressure, and it composes with what Task 2.1 already built:

1. `SherpaSttEngine` **pauses its subscription for the whole hand-off** and resumes
   it on the reply, so at most one chunk is ever in flight.
2. A paused subscription propagates to `MicCaptureSession`'s pause-aware pump.
3. The mic's bounded backlog then does its job — drop oldest, and report what was
   lost as `MicFrame.precedingGapBytes`.
4. The gap crosses the port and the worker **bridges it with silence of its own
   duration, before the audio that followed it**.

Step 4 is the reason `SttEngine.transcribe` was widened from `Stream<Uint8List>` to
`Stream<MicFrame>`. Task 0.2 declared it over raw buffers, before 2.1 established
that dropped audio has to travel *with* the audio; a caller bridging the two with
`.map((f) => f.bytes)` would discard the gap in one inconspicuous line, which is
exactly the loss 2.1 carries the field to prevent. A recogniser fed a silent splice
returns a fluent transcript of a sentence nobody said. Bridging **before** rather
than after matters too: silence placed after the audio moves the pause past the
words it separated and changes where the endpointer splits them.

`MicFrame` moved to its own file so `lib/engines/` can name it without importing
`mic_capture.dart` and dragging `package:record` into the layer that exists to keep
plugins out. `mic_capture.dart` re-exports it, so every Task 2.1 import still
resolves.

### The model cannot say "102", and that is not cosmetic

The pinned model ships a **502-entry BPE vocabulary in which no token contains a
digit** — the only two entries with digits are the `#0` and `#1` blank placeholders
at ids 500 and 501. A technician saying "E one oh two" is transcribed
`E ONE OH TWO`, and no amount of configuration changes that.

Left alone, that silently breaks the feature this app is *for*. Task 1.4's
`RetrievalRouter` is why a fault code reaches the manual's indexed `code` column
ahead of full-text search, and its `faultCodePattern` requires `\d{2,4}`. So every
dictated inquiry would skip the structured lookup and fall through to FTS —
returning a plausible answer grounded in whatever bm25 ranked first. Task 1.9's
device run already recorded how reachable that is: stop words match, so almost any
English sentence is a full-text hit.

`spoken_digits.dart` rewrites runs of digit words as digits. The floor is **three**
consecutive digit words, or **two** when a single-letter designator immediately
precedes them (`B THREE FOUR` → `B 34`).

It was two flat, justified by "a run of two or more is not prose — English says 'one
oh two' only when spelling something out", and **review finding R0-F3 refuted that by
running the shipped function**:

```
OH TWO OF THEM ARE LOOSE   →  02 OF THEM ARE LOOSE
NO ONE TWO WEEKS AGO       →  NO 12 WEEKS AGO
O ONE OF THE DOORS JAMMED  →  01 OF THE DOORS JAMMED
```

And the harm was *worse* than the one the floor existed to prevent, not milder.
`faultCodePattern` takes a **one or two letter** prefix, so a short English word in
front of a false positive manufactures a code candidate — measured through the real
pattern, `IS O ONE OF THE GUIDE SHOES` → `IS-01` and `NO ONE TWO WEEKS AGO` →
`NO-12`. So the step written to stop a dictated inquiry *silently skipping* the
structured lookup was instead making it run that lookup on a code nobody said.

Three is the corpus's own shape rather than a guess: every fault code in the seed
asset is `E-\d{3}`. The single-letter exception is deliberately **narrower than the
router's** `[A-Za-z]{1,2}`, because `NO`, `IS`, `AT`, `IN` and `OF` are all two-letter
English words and it was a two-letter word in front of a two-word run that produced
those candidates.

**What remains is a class, not a curiosity, and review finding R1-F2 made that
correction.** This paragraph used to offer one artificial input (`A ONE TWO` → `A 12`).
Measured, the residue is the approximation idiom of the register this app is used in,
plus a single-letter word nobody had named, plus the two-letter hazard surviving at run
length three:

```
THERE WAS A FOUR FIVE SECOND DELAY  →  … A 45 SECOND DELAY    → A-45
I SAW A TWO THREE MILLIMETRE GAP    →  … A 23 MILLIMETRE GAP  → A-23
I FOUR TWO                          →  I 42                   → I-42
NO ONE TWO THREE OF THEM WORK       →  NO 123 OF THEM WORK    → NO-123
IS O ONE TWO OF THE DOORS           →  IS 012 OF THE DOORS    → IS-012
```

It is kept rather than chased, on a bound rather than a hope: `RetrievalRouter`
verifies every candidate by lookup, so one resolving to no row lands in `unresolved`
and the text survives in the residual — a wasted lookup, not a wrong answer. R0-F3's
actual harm is gone: the *silent* skip of the structured lookup, and codes fabricated
out of a bare `OH TWO`. Every case above is pinned in the residue group of
`spoken_digits_test.dart`, so a future narrowing cannot widen it unnoticed.

The original hazard is still covered: `ONE`, `TWO`, `FOUR` and `O` are ordinary
English, and "one of the guide shoes is loose" survives intact.

The result is `E 102`, deliberately **not** joined into `E-102`:
`faultCodePattern` already spans the space, so a hyphen would change how the
transcript reads without changing what it resolves to. That claim is bound by
running the router's real pattern over the normaliser's real output — together with
the counterfactual, that the un-normalised transcript matches no fault code at all.

Casing is left exactly as the recogniser produced it (upper case, no punctuation).
Nothing downstream is case-sensitive: `faultCodePattern` accepts `[A-Za-z]`, the
FTS5 index uses the `porter` tokenizer, and the fault `code` column is
`COLLATE NOCASE`. `SttTranscript.rawText` carries the verbatim output, so the
normalisation is visible rather than hidden.

### Tail padding, and a claim measured at the wrong width

A streaming zipformer will not emit its last word without trailing audio, because
it decodes with right context. `inputFinished()` does **not** synthesise the frames
the encoder is still waiting for — it only stops the stream accepting more. So the
worker feeds `SttConfig.tailPadding` (0.8s of silence) *before* flushing; padding
sent afterwards is discarded.

This is worth reading as a lesson and not just a setting, because the first version
of the claim above was **too broad and the measurement refuted it**. Run over the
committed fixture, padded and unpadded came back byte-identical — the fixture
carries 0.8s of trailing silence of its own, so the runtime's padding had nothing
left to add. The claim holds at a narrower width: the padding recovers the last word
of a capture that ends **at** the last word, which is what `MicCapture.stop()`
produces when the technician releases the button. The test now strips the fixture's
trailing silence first — the live-microphone case, the only one the padding is for —
and the difference is exactly one word:

```
unpadded  "… THE FALK CODE IS E ONE OH TWO PLEASE"
padded    "… THE FALK CODE IS E ONE OH TWO PLEASE ADVISE"
```

Same shape as Task 1.6's recurring failure — a correct check described at the wrong
width — caught by running the comparison instead of asserting the conclusion.

### Endpointing, segments, and partials

`enableEndpoint` is on, mapped to sherpa's `rule2MinTrailingSilence` (1.2s, its own
default) — the rule that fires *after* something has been decoded, which is the one
a dictation UI cares about. On an endpoint the segment is closed, a final transcript
is emitted, and `reset` starts the next utterance; without the `reset`, `getResult`
keeps returning the closed segment and every later partial repeats it.

`SttTranscript.segment` exists because without it a consumer cannot tell the final
transcript of one utterance from a partial of the next, and a dictation UI that
guesses wrong either appends to the wrong line or overwrites a committed one. A
*silent* segment emits nothing: a final empty transcript would reach a UI as "the
user finished saying nothing", which is indistinguishable from a cleared field.

Partials are emitted only when the hypothesis actually moved. Measured over the
committed fixture, whole stack: **101 frames in, 25 transcripts out** — three quarters
of the chunks produced nothing new. The live test prints that on every run.

What *holds* the filter is that test's property assertion — no partial repeats its
predecessor within a segment — together with a bound below **half** the frame count.
This paragraph used to claim the guard was "the ratio below 1:1", and review finding
R0-F2 refuted it: a chunk emits nothing until decoding begins, so the count is
structurally under the frame count whatever the filter does, and deleting the filter
left all five tests green at 101 → 90 transcripts. It now fails at partial 1.

### Running the real model without a device

The one suite in `test/` that loads the real native library and the real weights.
It exists because the alternative was shipping TC-STT-STRM-01 written and unrun, the
way Task 2.1 had to ship TC-MIC-01 — and it is possible only because
`sherpa_onnx_macos` ships a macOS framework in the pub cache.

```bash
R=https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-en-20M-2023-02-17/resolve/main
mkdir -p /tmp/fieldops-stt && cd /tmp/fieldops-stt
for f in encoder-epoch-99-avg-1.int8.onnx decoder-epoch-99-avg-1.int8.onnx \
         joiner-epoch-99-avg-1.int8.onnx tokens.txt; do curl -sLO "$R/$f"; done

flutter test test/services/audio/sherpa_recognizer_live_test.dart \
  --dart-define=FIELDOPS_STT_MODEL_DIR=/tmp/fieldops-stt \
  --dart-define=FIELDOPS_SHERPA_LIB=$HOME/.pub-cache/hosted/pub.dev/sherpa_onnx_macos-1.13.5/macos
```

It skips itself without the first define, so CI stays hermetic. What it measured,
whole stack — engine → real `IsolateSttHost` → real isolate → real sherpa → real
weights → recorded fixture, on macOS arm64:

| | |
|---|---|
| recognizer load | 359–530ms, median 384, over ten consecutive runs (371–476ms on a second host) |
| frames in / transcripts out | 101 / 25 |
| final transcript | `U K THE CABIN IS VIBRATING BADLY IN THE PANEL IS SHOWING AN ERROR THE FALK CODE IS E 102 PLEASE ADVISE` |

That contains `error` and `102` case-insensitively, which is TC-STT-STRM-01's
criterion, met against the real model. **It is not a substitute for the device
run** — see below for what only hardware can answer.

`SttConfig.nativeLibraryPath` exists because of this suite, and only for it.
Production leaves it null. On Android that is the only value that *works* (the bare
`libsherpa-onnx-c-api.so` resolves from the app's lib directory); on iOS it is the
only value that *means* anything, because that branch of `init_native.dart`
discards the parameter and returns the bare-name open regardless. This sentence
said "on iOS and Android the only value that works" until review finding R0-F8 —
true of Android, false of iOS for that second reason.
The whole-stack leg needs it because the worker builds its own runtime *after* the
isolate hop, so a library path held on the host side never reaches it — and macOS
cannot resolve `SherpaOnnxC.framework/SherpaOnnxC` by bare name.

### The fixture

`test/fixtures/e102_utterance.wav` — 16 kHz mono 16-bit LE, 10.08s, the exact format
`SttEngine.transcribe` is declared over.

It is **macOS `say` output, not a human recording**, and that is stated wherever it
is used because it bounds what it proves: that the pipeline turns real speech-shaped
audio into a transcript, not that the model generalises to a technician in a plant
room. It carries 0.8s of trailing silence for the right-context reason above, and it
is declared as an asset **from `test/fixtures/`** rather than copied into `assets/` —
an integration test runs inside the app, on the device, where the repository's
`test/` directory does not exist, and declaring it in place means the host suite and
the device suite cannot drift onto different audio. The cost is 322KB of release
bundle, stated in `pubspec.yaml` rather than hidden.

The transcript is imperfect and deliberately quoted with its warts (`U K` for
"okay", `FALK CODE` for "fault code"): the ACs are **fuzzy containment**, per the
sprint plan, and pinning the whole string would turn a library upgrade into a
failure.

### What the mutation pass found

**37 targeted mutations, 37 killed, 0 survived, 0 aborted**, run with
`--concurrency=1` against `test/services/audio` and `test/engines` (baseline 267
passing, 5 skipped).

The pass was **re-run after review round 1, not before it** — 1.6's rule, and 2.1's
row is blunter about why: six of its fifteen findings were claims or values introduced
in a *fixing* round with nothing holding them, and the only one caught before handback
was the one whose mutation was run after the fix. Two rows had gone stale against the
changed source and were repaired rather than dropped (`M04` keyed to
`minimumDigitRun = 2`, which R0-F3 raised to 3; `M22` keyed to the `await drain()` that
R0-F1's rewrite deleted — its *property* survives, so the row now breaks the emission
ordering directly and a new test binds it). Thirteen rows were added over the code the
fixes introduced, including **the reviewer's own two surviving mutations** (`N08`,
`N09`), kept as rows so that regression cannot return quietly.

A focused set rather than a 1.6-style full sweep, chosen the way Task 2.0 chose its
ten — one mutation per decision that would fail *silently* if it were wrong. The ones
worth naming, because each is a claim made elsewhere in this section and these are what
hold it:

| mutation | what it would break silently |
|---|---|
| `int16FullScale` 32768 → 32767 | the most negative sample leaves `[-1, 1]` |
| `Endian.little` → `Endian.big` | every sample decodes to noise |
| `minimumDigitRun` 2 → 1 | "one of the guide shoes" becomes "1 of the guide shoes" |
| drop `'O': '0'` | the commonest spoken form of this corpus's codes stops resolving |
| bridge the gap **after** the audio | the pause moves past the words it separated |
| remove the gap cap | a 40-second dropout allocates 40 seconds of silence |
| pad **after** `finishSession` | the padding is discarded and the last word is lost |
| `defaultTailPadding` → zero | same, everywhere, by default |
| remove `subscription.pause()` | back-pressure gone; the port queue grows unbounded |
| `cancelSession: true` → `false` on cancel | a leaked native stream after every abandoned dictation |
| normalise finals only | digits appear all at once, reading as a rewrite |
| `rawText` normalised too | the model's actual output becomes unobservable |
| `_loading ??=` → `=` | two concurrent loads, two recognisers resident |
| fake revives after dispose | the host suite tests a more forgiving world than the device |
| fake emits on the first frame | the fake's ordering stops matching the real engine's |
| the digit floor back to 2 | the six fabricated fault codes R0-F3 found return |
| a two-letter word counts as a designator | `NO-12` and `IS-01` come back |
| the run swallows non-whitespace again | `ONE 5 TWO` → `12`, deleting content |
| `toWire` drops `nativeLibraryPath` | the field's whole purpose — crossing the hop — is void |
| the slot taken at the call site again | an unlistened stream wedges the engine until disposal |
| the fake's `onCancel` stops releasing | R0-F1's deadlock returns as a leak |

The harness refuses a dirty baseline, asserts the match count on every edit,
refuses duplicate labels and duplicate edits, verifies each edit actually changes
the source before believing a survivor, and re-checks the whole tracked surface by
`st_mtime_ns` after every row — each of those guards is one that an earlier task's
harness lacked and paid for (1.5, 1.6, 1.9, 1.10, 2.1 respectively).

Its collateral detector printed six `mtime changed` notes, and they are an artifact
of the harness rather than damage: the revert is `git checkout -- .`, which rewrites
the mutated file and so moves its mtime, and the check excludes only the *current*
row's file — so the first row to use a different file reports its predecessor's.
Said here rather than left as an unexplained line in a log, because an unexplained
note is indistinguishable from a real one.

### Not wired into the app

`sttEngineProvider` still binds `FakeSttEngine`, exactly as Tasks 1.3–1.10 shipped
unwired before 1.11 did the wiring. Nothing in the UI consumes speech yet.

**One hazard to hand to Task 2.3, recorded because the obvious wiring is the wrong
one.** `sttEngineProvider` is the Tier 0 fake seam. Wiring a microphone to it would
produce a demo that transcribes from a script — voice input that looks like it works
on a device where the recogniser never ran. That is the class of deception
`no_fake_in_production_test.dart` exists for, and it does **not** cover this today:
its guarded set is deliberately the *answer* path (`LlmEngine`, `InferenceHost`,
`InferenceRuntime`), and a scripted STT fakes the question rather than the answer —
the same basis on which that file excludes `SeedSource` and `AgentTool`. When 2.3
puts a transcript on screen, `SttEngine` / `SttHost` / `SttRecognizerRuntime` belong
in `scriptableContracts`, and 1.11's rule applies: return **null rather than a
fake**, because a fallback yields an app that is indistinguishable from success in a
screen recording.

### Owed on a device

⚠️ **TC-STT-INIT-01 and TC-STT-STRM-01 have not run on hardware.**
`integration_test/stt_test.dart` is written and needs no defines; it provisions the
43.65MB set first if it is absent.

```bash
flutter test integration_test/stt_test.dart -d <device>
```

The host run above covers the logic, so what the device run adds is specific:

1. **The native library resolves by bare name from inside the app bundle** —
   `SherpaOnnxC.framework/SherpaOnnxC` on iOS, `libsherpa-onnx-c-api.so` on Android
   — with `nativeLibraryPath` null. The host suite has to supply a path, so that is
   precisely the thing it cannot verify.
2. `initBindings` on a spawned isolate in a real engine build.
3. Load and decode times on arm64 mobile silicon **next to the LLM**. Task 1.8
   measured process RSS at 1.67GB with Gemma resident and refuted §3.4's 500MB cap;
   whether a 43MB recogniser alongside it is free is unmeasured.

Also unrun on hardware: the endpoint path with **more than one utterance** (the
fixture is one), the gap bridge against a real dropped buffer, and the
`recognizerLost` distinction — all host-bound only.

## Getting started

Requires the Flutter SDK (stable channel, Dart 3.12+). iOS 16.0+ / a 64-bit
Android device is required to run the on-device model.

```bash
flutter pub get
flutter run
```

Without the model defines the app still runs: the banner reports that the model
source is not configured and **Diagnose** stays disabled, which is the correct
behaviour rather than a degraded one. To run the real thing, pass the defines shown
under *The demo screen → Running it*, then type a fault (`cabin vibrating, E-102`)
and tap **Diagnose**.

(This paragraph used to say "Tap **Run self-test** on the home screen". Task 1.11
deleted that screen and its button, and left this instruction pointing at a control
that no longer exists — review finding R0-F8.)

## Testing

```bash
flutter analyze
flutter test
```

Tests are split into two tiers:

- **Unit tier** (`test/`) — pure Dart, deterministic, runs in CI on every commit
  (engine fakes, database, FTS, seeding, retrieval routing and prompt
  compilation, the agent tool registry, the tool-call guard, the agent loop,
  the golden transcript suite, model provisioning, microphone capture, the STT
  config/protocol/worker/host and the STT engine, spoken-digit normalisation, the
  startup wiring, the demo viewmodel, widget tests). The widget suite is split on purpose — see _Two things
  a host test cannot tell you_ above; rendering tests inject state, wiring tests
  run the real graph. The HTTP
  transport is covered against a loopback `HttpServer` rather than a mock, because
  the behaviour worth testing is HTTP behaviour: redirect hops, `Content-Length`
  vs. chunked, and which requests carry the access token. The seeding suite reads
  the **shipped** asset off disk as well as its own fixtures, so a broken bundled
  JSON cannot pass behind green fixtures and fail on the device. The **router**
  suite goes further and uses nothing but the shipped asset, as do the prompt
  compiler's two AC groups: their expected document ids are a property of that
  exact prose and its porter stems, so a fixture would let them stay green while
  the bundled manual stopped producing them. The compiler's remaining groups —
  layout, the document cap, and the untrusted-inquiry defence — deliberately use
  hand-built entries, because what they assert is the compiler's own formatting
  rather than anything about the corpus. The **golden** suite is the strongest
  version of the same rule: it drives the real router, compiler, loop, guard and
  registry over the shipped asset and snapshots the whole transcript, so a change
  to the bundled manual, to bm25 ranking or to the prompt template all surface as
  a readable diff rather than as nothing. Regenerate with
  `UPDATE_GOLDENS=1 flutter test test/golden`; see _Golden transcripts_ above for
  what the flag deliberately will not let you do.
- **Integration tier** (`integration_test/`) — on-device runs against real
  backends. `flutter test` does not pick this directory up, so CI stays host-only.
  `model_provisioning_test.dart` and `llm_inference_test.dart` **skip** with an
  actionable message unless the model defines above are supplied, because CI has no
  artifact to fetch and must not pull gigabytes over the network to try. (This
  sentence read "Both suites" until Task 2.1, which was already loose with four
  files in this directory and became wrong with the fifth: `mic_capture_test.dart`
  needs no defines at all. Task 2.2 adds a sixth, `stt_test.dart`, which also needs
  none — its model's source and pins are committed. The sentence is now written as
  the two file names it actually means, so a seventh file cannot make it wrong
  again.)
  - `model_provisioning_test.dart` (TC-PROV-E2E-01) — a real download, verify and
    install.
  - `stt_test.dart` (TC-STT-INIT-01, TC-STT-STRM-01) — loads the streaming
    zipformer on a background isolate and transcribes the recorded fixture, with
    fuzzy containment rather than exact equality. No defines; it provisions the
    43.65MB set first if it is absent. ⚠️ **Written and unrun** — see _Speech to
    text → Owed on a device_ for what only hardware answers here, given that the
    same stack already passes against the real weights on the host.
  - `llm_inference_test.dart` (TC-LLM-LOAD-01, TC-LLM-GEN-01, TC-LLM-TOOLCALL-01) —
    loads the provisioned weights, streams a response, and checks that a grounded
    prompt with a registered tool produces a structured tool call. It refuses to load
    weights that are present but unverified. Assertions are behavioural (a call
    naming the tool and the SKU), never exact token equality; decoding is greedy so
    a run is reproducible.

    On a **wirelessly connected** iOS device `flutter test` cannot launch the app
    (`Cannot start app on wirelessly tethered iOS device`) and has no
    `--publish-port` flag to fix it. Run the file through `flutter run` instead,
    which does:

    ```bash
    flutter run integration_test/llm_inference_test.dart -d <device id> \
      --publish-port --dart-define=FIELDOPS_MODEL_URI=... \
      --dart-define=FIELDOPS_MODEL_SHA256=...
    ```

    A USB connection avoids this entirely and is much faster to iterate on.
  - `agent_loop_e2e_test.dart` (TC-AGENT-E2E-01) — the whole Tier 1 slice with
    every hand-written part replaced by the real one: the prompt comes from the
    compiler over the seeded database, the tool is the registry's over that same
    database, and the round trip is the agent loop. Asserts that the loop
    *answered* rather than hitting its cap, that it called the inventory tool for
    the SKU the manual names, and that the answer quotes the stock figure read
    back from the database — a fact a model answering from its weights cannot
    produce by luck. A companion checks the other half of grounding: an inquiry
    the manual does not cover must call no tool and name no SKU.

    **Passed on the demo device** (iPad Air M4, iOS 26.5) against the real 2.59GB
    artifact: 2 turns, 11332ms, `stop=answered`, and an answer quoting *2 units in
    Aisle 4, Shelf B* — database facts, not elevator facts, so the weights could not
    have supplied them. (This paragraph said "Not yet run" until Task 1.11 corrected
    it: the run happened in commit `9afeb5b`, which updated the sprint plan and the
    ledger and left the README behind.) The companion `-01b` **failed on its
    premise**, which is the more valuable half — see _The no-match path_ above.
  - `demo_flow_test.dart` (TC-UI-DEMO-01) — the same slice again, but through the
    **UI**, and it is the only test in the repo that pumps `FieldOpsApp` with no
    overrides at all. That is the whole reason it exists on top of the suite above:
    it is the only place Task 1.11's three wirings run as the app performs them —
    `DatabaseService.openDefault` in the real application-support directory with the
    real key, `ensureSeeded()` through `rootBundle` and a real `AssetBundle`, and
    `deviceLlmEngineProvider` loading the real artifact via the screen's own
    post-frame warm-up. Every one of those is faked in the host suite, so a failure
    in any of them is invisible to all of it.

    It also ticks a 16ms timer on the UI isolate across both the warm-up and the
    generation, so it reports the worst frame gap **for the flow being
    screen-recorded** rather than for a synthetic prompt — and it asserts, on the
    device where the stall is real, that no `ProgressIndicator` is in the tree while
    the weights load. Timings are printed rather than asserted: a threshold that
    fails on a warm device is a flaky test pretending to be an NFR.
  - `mic_capture_test.dart` (TC-MIC-01) — a real microphone, for three seconds.
    Asserts the shape (non-empty buffers, whole samples), the **cadence** — 32000
    bytes per second of wall clock, an end-to-end sanity check on the whole
    request-to-bytes path — that at least one sample is non-zero, because a dead
    input can hand back correctly shaped silence that passes every structural
    check, and that the stream closes cleanly, which Task 2.2's `transcribe` needs
    in order to ever emit a final transcript. (The cadence assertion used to be
    described as the only place a substituted rate is observable. It is not: a
    *silent* substitution is not a state either platform reaches, and the one
    reachable coercion faults the capture first — see _The format-coercion
    tripwire_ above.) Needs no `--dart-define`. It
    **skips** on the first run: it raises the OS permission prompt, which no
    `WidgetTester` gesture can dismiss, because that dialog is not in the Flutter
    view hierarchy. Grant it and run again.

## Tech stack

| Concern            | Choice                                             |
|--------------------|----------------------------------------------------|
| UI framework       | Flutter (Material 3)                               |
| State management   | Riverpod (`flutter_riverpod`)                      |
| Architecture       | MVVMC with engine-abstraction interfaces           |
| Local database     | drift + SQLite3MultipleCiphers (`source: sqlite3mc`) |
| On-device LLM      | Gemma 4 E2B (`.litertlm`) via `flutter_gemma` + `flutter_gemma_litertlm` (LiteRT-LM, `dart:ffi`) |
| Inference threading | Dedicated background isolate with an encoded message protocol |
| Model delivery     | `dart:io` streaming download + `crypto` SHA-256 verify, no-backup storage |
| Audio capture      | `record` (16-bit mono PCM stream) behind an `AudioInput` seam |
| On-device STT      | streaming zipformer (en, 20M, int8) via `sherpa_onnx` (`dart:ffi`) |
| STT threading      | Dedicated background isolate, one-request-one-reply protocol (the reply is the flow control) |
| Testing            | `flutter_test` (unit + widget), `integration_test` |
| CI                 | GitHub Actions                                     |

## License

Not yet specified.
