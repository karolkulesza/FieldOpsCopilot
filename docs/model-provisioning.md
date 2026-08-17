# Model provisioning

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

## Getting the weights (what a reviewer has to do)

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

## The second model: a committed STT file set (Task 2.0)

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

## What provisioning actually does

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

## Demo-day procedure

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

## OTA model delivery (designed, not built)

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

---

[← Back to the README](../README.md)
