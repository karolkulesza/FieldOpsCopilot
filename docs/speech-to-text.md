# Speech to text

`sherpa-onnx` running a **streaming zipformer** (en, 20M params, int8) on a
dedicated background isolate, behind `SttEngine`. Four files, 43.65MB, provisioned
from a committed ungated source (see
[docs/model-provisioning.md](model-provisioning.md)) — no build-time defines.

```
MicCaptureSession.frames ─▶ SherpaSttEngine ─▶ IsolateSttHost ═╗ isolate boundary
    Stream<MicFrame>          (state machine)                  ║
                                                               ▼
                          SttTranscript ◀── SherpaRecognizerRuntime ──▶ libsherpa
                         (text, rawText,        (every FFI call)
                          isFinal, segment)
```

The layering repeats the inference engine's, deliberately: `sherpa_recognizer.dart` is the only file
in `lib/` that imports `package:sherpa_onnx`, `stt_config.dart` speaks this app's
vocabulary rather than the plugin's, and `SherpaSttEngine` takes an `SttHost` rather
than building one — so the engine's contract is verified on the host and the device
tests only have to prove the device part.

## The isolate is load-bearing here, not insurance

The LLM's isolate is a guarantee about *our* architecture rather than a bet on a
dependency: LiteRT-LM already keeps its worst work off the caller. sherpa-onnx has
nothing to insure. **Every entry point of its Dart API is a synchronous FFI call
that runs to completion on the calling thread**, read in
`sherpa_onnx-1.13.5/lib/src/`:

- `OnlineRecognizer(config)` is a *constructor* that loads three ONNX graphs —
  359–530ms (median 384) over ten consecutive runs here, 371–476ms over four on a
  second host.
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

## One request, one reply — and that is the flow control

Inference is one request, many replies: a turn streams tokens back until `LlmDone`.
Recognition is **one request, one reply, every time**. A chunk of audio goes over
and the transcripts it produced come back — frequently none, and the reply arrives
anyway, because *the reply is the sender's permission to send again*.

That is the back-pressure, and it composes with what the capture layer already built:

1. `SherpaSttEngine` **pauses its subscription for the whole hand-off** and resumes
   it on the reply, so at most one chunk is ever in flight.
2. A paused subscription propagates to `MicCaptureSession`'s pause-aware pump.
3. The mic's bounded backlog then does its job — drop oldest, and report what was
   lost as `MicFrame.precedingGapBytes`.
4. The gap crosses the port and the worker **bridges it with silence of its own
   duration, before the audio that followed it**.

Step 4 is the reason `SttEngine.transcribe` was widened from `Stream<Uint8List>` to
`Stream<MicFrame>`. The interface was first declared over raw buffers, before capture established
that dropped audio has to travel *with* the audio; a caller bridging the two with
`.map((f) => f.bytes)` would discard the gap in one inconspicuous line, which is
exactly the loss the field exists to prevent. A recogniser fed a silent splice
returns a fluent transcript of a sentence nobody said. Bridging **before** rather
than after matters too: silence placed after the audio moves the pause past the
words it separated and changes where the endpointer splits them.

`MicFrame` moved to its own file so `lib/engines/` can name it without importing
`mic_capture.dart` and dragging `package:record` into the layer that exists to keep
plugins out. `mic_capture.dart` re-exports it, so every existing import still
resolves.

## The model cannot say "102", and that is not cosmetic

The pinned model ships a **502-entry BPE vocabulary in which no token contains a
digit** — the only two entries with digits are the `#0` and `#1` blank placeholders
at ids 500 and 501. A technician saying "E one oh two" is transcribed
`E ONE OH TWO`, and no amount of configuration changes that.

Left alone, that silently breaks the feature this app is *for*.
`RetrievalRouter` is why a fault code reaches the manual's indexed `code` column
ahead of full-text search, and its `faultCodePattern` requires `\d{2,4}`. So every
dictated inquiry would skip the structured lookup and fall through to FTS —
returning a plausible answer grounded in whatever bm25 ranked first. The agent loop's
device run already recorded how reachable that is: stop words match, so almost any
English sentence is a full-text hit.

`spoken_digits.dart` rewrites runs of digit words as digits. The floor is **three**
consecutive digit words, or **two** when a single-letter designator immediately
precedes them (`B THREE FOUR` → `B 34`).

It was two flat, justified by "a run of two or more is not prose — English says 'one
oh two' only when spelling something out", and **running the shipped function
refuted that**:

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

**What remains is a class, not a curiosity, and that too is a correction.**
This paragraph used to offer one artificial input (`A ONE TWO` → `A 12`).
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
and the text survives in the residual — a wasted lookup, not a wrong answer. The
actual harm measured above is gone: the *silent* skip of the structured lookup, and codes fabricated
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

## Tail padding, and a claim measured at the wrong width

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

Same shape as this project's recurring failure — a correct check described at the wrong
width — caught by running the comparison instead of asserting the conclusion.

## Endpointing, segments, and partials

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
This paragraph used to claim the guard was "the ratio below 1:1", and measurement
refuted it: a chunk emits nothing until decoding begins, so the count is
structurally under the frame count whatever the filter does, and deleting the filter
left all five tests green at 101 → 90 transcripts. It now fails at partial 1.

## Running the real model without a device

The one suite in `test/` that loads the real native library and the real weights.
It exists because the alternative was shipping TC-STT-STRM-01 written and unrun, the
way TC-MIC-01 once shipped — and it is possible only because
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
said "on iOS and Android the only value that works" until review checked the
plugin — true of Android, false of iOS for that second reason.
The whole-stack leg needs it because the worker builds its own runtime *after* the
isolate hop, so a library path held on the host side never reaches it — and macOS
cannot resolve `SherpaOnnxC.framework/SherpaOnnxC` by bare name.

## The fixture

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
"okay", `FALK CODE` for "fault code"): the acceptance criteria are **fuzzy
containment**, deliberately, and pinning the whole string would turn a library upgrade into a
failure.

## What the mutation pass found

**40 targeted mutations, 40 killed, 0 survived, 0 aborted** — and every killed row
**confirmed by the test its `expect` names** — run with `--concurrency=1` against
`test/services/audio` and `test/engines` (baseline 277 passing, 5 skipped).

The pass was **re-run after the review-driven fixes, not before them** — a rule this
project keeps re-learning, and for a blunt reason: fixes made in a correction
round introduce claims and values with nothing holding them, and the only ones
caught cheaply are the ones whose mutations run after the fix. Two rows had gone stale against the
changed source and were repaired rather than dropped (one keyed to
`minimumDigitRun = 2`, which the digit-floor correction raised to 3; one keyed to the `await drain()` that
the deadlock fix deleted — its *property* survives, so the row now breaks the emission
ordering directly and a new test binds it). Thirteen rows were added over the code the
fixes introduced, including **two surviving mutations written from outside the
set**, kept as rows so that regression cannot return quietly.

A focused set rather than a full sweep, chosen on one principle
— one mutation per decision that would fail *silently* if it were wrong. The ones
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
| the digit floor back to 2 | the six fabricated fault codes measured above return |
| a two-letter word counts as a designator | `NO-12` and `IS-01` come back |
| the run swallows non-whitespace again | `ONE 5 TWO` → `12`, deleting content |
| `toWire` drops `nativeLibraryPath` | the field's whole purpose — crossing the hop — is void |
| the slot taken at the call site again | an unlistened stream wedges the engine until disposal |
| the fake's `onCancel` stops releasing | a fixed deadlock returns as a leak |

**The harness is a recorded artifact, not a tracked file.** It lives outside
version control, as every mutation harness in this project has — so "the committed
harness" means the archived copy beside its results, and the
only way to tie a results JSON to the harness that produced it is to re-run. That
was done once and got a byte-identical JSON after normalising the worktree path. Worth
knowing for anyone copying the pattern: tracking the harness would make the record
diffable instead of reproducible-on-demand.

The harness refuses a dirty baseline, asserts the match count on every edit,
refuses duplicate labels and duplicate edits, verifies each edit actually changes
the source before believing a survivor, and re-checks the whole tracked surface by
`st_mtime_ns` after every row — each of those guards is one that an earlier harness
in this project lacked and paid for.

**The harness checks its own claims, and that check found three things — all of them
in fixes twenty minutes old.** Review noted that "killed" did not
establish *which* test held a property, because the harness only kept the last six
failure lines. It now compares each row's `expect` against the tests that actually
failed, and the first run of that check reported three survivors and three mismatches:

* **`if (!begun) return;` in `release` was dead** — every path reaching it had
  `begun == true`, because the only way it could be false was a begin that threw, which
  returns earlier. Deleted rather than kept as decoration.
* **`if (!settled) begun = true;` changed nothing observable** — after that cancel
  `_transcribing` is false, so no later `release` reads `begun` again. Removed.
* **One row measured the mutation rather than the suite** — it inserted a statement
  immediately before a `return`, so it changed nothing. A shape this project has
  recorded before, where a
  survivor reads as "untested" when it means "this edit does nothing". Dropped.

**And the checker itself was wrong twice before it was right**, which is the part worth
carrying. It first read failing test names out of `flutter test`'s `Failing tests:`
block — which the default reporter **truncates** ("… and 14 more"), an instrument
defect this project had already recorded, verbatim — so it flagged killed rows as mismatches. Rewritten to read
the expanded reporter's `[E]` lines, it then matched nothing at all, because this suite
always reports 5 skips and the pattern required the pass and fail counters to be
adjacent. A checker that cannot parse its input reports on itself.

So the pattern is now checked **inside the harness**, against four reporter lines it must
accept (with the exact name it must capture from each) and four it must reject, and the
run aborts before touching the tree if any of them disagrees. That guard exists because
review caught this paragraph claiming it while the harness had
none — the check had only ever run in a shell — which is the same shape as the prose
findings above, aimed at the instrument instead of the code.

Two further tightenings. A row whose `expect` names several tests needs **all** of
them in the failure list rather than any one, and each row records *which* failing
tests confirmed it. String matching cannot settle whether a confirming test failed
*because of* the mutation or merely as collateral — a row was demonstrated reaching
CONFIRMED off pure collateral — so the confirming names are recorded rather than
asserted, which is what let that audit be done by hand across all forty rows.

Its collateral detector printed **eleven** `mtime changed` notes on the 40-row pass, and
they are an artifact of the harness rather than damage. Reverting a row rewrites the
mutated file and so moves its mtime, and the check excludes only the *current* row's
file — so the first row to use a different file reports its predecessor's. Said here
rather than left as an unexplained line in a log, because an unexplained note is
indistinguishable from a real one.

**Eleven and not twelve, because the detector rebases its reference each time it
fires** (`baseline_stamps = stamps_now`): a file used by exactly one row has its
post-revert mtime captured in that new reference and leaves nothing stale for the
next transition to report. The 40-row set has twelve file transitions and one
single-row group, so the transition out of it is silent.

That clause is worth more than the arithmetic. The
count itself had said "six" since the 24-row pass — exact then, carried unchanged
through the 37-, 39- and 40-row re-runs in a section whose other figures were updated
each time. The correction then shipped with a *rule that predicts
twelve*, caught by applying the rule and getting the wrong answer.
Both halves are the same failure at different scales: **a number that is not re-derived
goes stale, and a rule that is not applied is not checked.**

## Wired into the app — and not through the seam that was there

The hazard this section used to hand forward has been taken rather than repeated,
so it is worth stating what was done with it. `sttEngineProvider` **still binds
`FakeSttEngine`**, because it is the DI seam and every host test resolves it.
What the screen resolves is a different provider, `dictationEngineProvider`, which
answers the real recogniser or `null`.

The reason is the one the demo screen gives for `agentEngineProvider`, and it is *stronger*
here rather than weaker: a scripted transcript fakes the **question**, so retrieval,
the compiled prompt, the tool call and the form are all genuine work done on words
nobody said — nothing looks wrong anywhere. `SttEngine`, `SttHost` and
`SttRecognizerRuntime` are now in `no_fake_in_production_test.dart`'s
`scriptableContracts`, on the condition that file's own comment set: *"If a future
feature puts one of them there, it belongs here."*

See [Voice input and the work order](voice-and-work-order.md).

## Owed on a device

✅ **Both ACs passed on the demo iPad (Air M4 / iOS 26.5), 3/3, on 2026-07-12** — load 430ms (worker 249ms) from an `absent` install, then 101 frames → 25 transcripts in 391ms with a transcript **byte-identical to the host run**.

**They failed on the first attempt, on a defect no host test could see**, which is the clearest justification this stack has for the device tier existing. `IsolateSttHost._teardown` completed `_workerLost` with an error on a *clean* shutdown; `IntegrationTestWidgetsFlutterBinding` reported that as an unhandled error and failed all three tests **after their bodies had passed**. My first fix was also wrong — a real `onError` handler instead of `ignore()`, which the device rejected identically — and the design answer was that the completion was never needed at all, because `_gate` serialises requests so a clean teardown has no racer to release. Every host suite was green throughout, *including* the whole-stack live run that spawns a real isolate, loads the real weights and disposes the engine.

Still device-unverified: **more than one utterance through the endpointer** (the fixture is one segment, one final), the gap bridge against a real dropped buffer, and the `recognizerLost` distinction.

The original owed-run text is kept below, because what it says about *why* the device tier matters is exactly what the run then demonstrated.

⚠️ **TC-STT-INIT-01 and TC-STT-STRM-01 had not run on hardware.**
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
3. Load and decode times on arm64 mobile silicon **next to the LLM**. Process RSS
   measured at 1.67GB with Gemma resident refuted the 500MB design cap (see
   [docs/on-device-inference.md](on-device-inference.md));
   whether a 43MB recogniser alongside it is free is unmeasured.

Also unrun on hardware: the endpoint path with **more than one utterance** (the
fixture is one), the gap bridge against a real dropped buffer, and the
`recognizerLost` distinction — all host-bound only.

---

[← Back to the README](../README.md)
