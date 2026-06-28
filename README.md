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
  "model ready" state on the home screen, with the trigger to fetch and verify.
  See _Model provisioning_ below.
- **On-device inference** — **Gemma 4 E2B** in a `.litertlm` container, run
  through `flutter_gemma` + `flutter_gemma_litertlm` (LiteRT-LM over `dart:ffi`)
  on a dedicated background isolate, behind the same `LlmEngine` interface the
  fake implements. Tool calls arrive as the model's **native function-call
  tokens**, not as prompt-engineered JSON. See _On-device inference_ below.
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
model.

> **On the token.** A `--dart-define` token is baked into the binary — fine for a
> development or demo build, and not a shipping pattern, since anyone with the app
> has the credential. The fleet answer is in _OTA model delivery_ below.

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
4. **Streams the download to a per-transfer `.part.<nonce>` staging file, hashing
   as it writes.** The artifact is never buffered in memory and never read twice.
   Progress is reported per chunk, and degrades to an indeterminate state when the
   server declares no `Content-Length` instead of inventing a percentage. Every
   request asks for `Accept-Encoding: identity` and a content-encoded response is
   rejected by name: the pinned digest describes the artifact *as published*, so
   an inflated body would be the wrong bytes to hash.
5. **Installs only on a digest match**, by atomic rename — which is also the swap
   that replaces a stale artifact. The path an engine loads from therefore only
   ever holds a complete, verified file. Operations on one model are serialised, so
   two overlapping calls cannot interleave into each other's files.
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

TC-AGENT-E2E-01 is **written but not yet run**: it needs the demo device and the
2.6GB artifact, and it skips with an actionable reason without them. Its result
is not recorded anywhere as a measurement until it has run.

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
the tests that would have decided it are the ones that did not run. Nor is the captured set an enumeration of what broke: 3
`loading` names were captured against **2** actual `Failed to load` failures, the
extra one an unrelated suite file, so it is a reporter artefact rather than a list.

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

## Getting started

Requires the Flutter SDK (stable channel, Dart 3.12+). iOS 16.0+ / a 64-bit
Android device is required to run the on-device model.

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
  (engine fakes, database, FTS, seeding, retrieval routing and prompt
  compilation, the agent tool registry, the tool-call guard, the agent loop,
  the golden transcript suite, model provisioning, widget tests). The HTTP
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
  Both suites **skip** with an actionable message unless the model defines above are
  supplied, because CI has no artifact to fetch and must not pull gigabytes over the
  network to try.
  - `model_provisioning_test.dart` (TC-PROV-E2E-01) — a real download, verify and
    install.
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

    **Not yet run.** It needs the demo device and the provisioned weights.

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
| Testing            | `flutter_test` (unit + widget), `integration_test` |
| CI                 | GitHub Actions                                     |

## License

Not yet specified.
