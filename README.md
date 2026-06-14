# FieldOps Copilot

An offline-first mobile application for field-service technicians maintaining
smart elevators (the fictional **Apex-9** series). It is designed to run entirely
on-device — no cellular connectivity required — combining an on-device language
model, speech-to-text, camera-based OCR, and a local full-text-searchable manual
database to help technicians diagnose faults and produce structured repair plans.

> **Status: vertical slice under construction.** The runnable app shell, the
> engine-abstraction layer, the encrypted database, offline retrieval, model
> provisioning and the **on-device LLM engine** are in place. STT and vision are
> still fakes, and the agent loop that ties retrieval to inference is the next
> task — they slot in behind the interfaces described below.

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
the previous call. That is what the fake does and what the golden suite will
depend on. Feeding a tool *result* back for a second model turn is the agent
loop's job (Task 1.9) and will extend the interface rather than quietly inherit
an accumulated conversation.

### Measured on the demo device (iPad Air M4, iOS 26.5, 2026-06-14)

Two runs on the physical device against the real 2.59GB artifact. The simulator figures
that preceded these are kept below only because the *comparison* is informative — where
they disagree, these are the numbers.

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

That leaves:

- **process-wide memory pressure** — a 2.59GB `mmap` taking RSS past 1.6GB can stall every
  thread in the process without anything Dart-level blocking. The CPU run makes this *more*
  plausible, not less: RSS landed at 1635 MB against Metal's 1669–1671 MB, so the footprint is
  the model rather than a GPU working set, and the stall grew as a share of a shorter load;
- the plugin's own `Isolate.run` for engine creation, or platform-channel traffic from the
  worker (`path_provider` and `shared_preferences` are marshalled via the root isolate's
  messenger).

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
  (engine fakes, database, FTS, model provisioning, widget tests). The HTTP
  transport is covered against a loopback `HttpServer` rather than a mock, because
  the behaviour worth testing is HTTP behaviour: redirect hops, `Content-Length`
  vs. chunked, and which requests carry the access token.
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
