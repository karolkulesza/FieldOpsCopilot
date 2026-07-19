# Testing

```bash
flutter analyze
flutter test                                    # 1177 host tests, hermetic
```

Three tiers, and the interesting part is what each one *cannot* answer — which is
why the next one exists.

| Tier | Where | What it needs | What it settles |
|---|---|---|---|
| **Host** | `test/` | nothing | every decision the app makes over a scripted backend |
| **Live host** | `test/services/audio/sherpa_recognizer_live_test.dart` | the real 43MB weights, opt-in | that the real recogniser produces the transcript the logic is written against |
| **Device** | `integration_test/` | a real device, real weights | that arm64 silicon can load and run any of it |

Above all three sits **mutation testing**, which is not a tier but a question
asked of the tiers: *if this line were wrong, would anything go red?*

## Mutation testing, and why it is the load-bearing part

A test suite reports its own size. It does not report its own strength, and the
gap between the two is where this project spent most of its review time.

The method is deliberately unclever. Take a line the code depends on, change it to
something a careless author might plausibly have written, run the **whole** suite,
and record whether anything failed. A mutation that survives is a line no test
constrains — whatever the argument for it says. Three rules make the results worth
quoting:

1. **The mutation has to be a defect someone would actually write.** Not `x + 1`
   → `x - 1` at random; the specific wrong thing — a `>=` that should be `>`, a
   `finally` deleted, a `noRetry` policy dropped, a guard clause emptied.
2. **A `NO_OP` is not a survivor.** If the edit did not change the file, the run
   proves nothing about the tests. That distinction caught a script bug that would
   otherwise have published "nine of eleven sites are unbound" from seven
   measurements that never ran — see [the demo screen](demo-screen.md).
3. **A fix whose own mutation survives has not been demonstrated.** One "fix" in
   this repo was reverted on exactly that basis.

Recorded runs, each against the whole suite at the tree it names:

| Subject | Result | Written up in |
|---|---|---|
| The agent loop and the `escapeQuotes` change it forced | 36 mutations, 0 survivors | [The agent loop](agent-loop.md) |
| The golden harness and serializer | 47 mutations, 0 survivors | [Golden transcripts](golden-transcripts.md) |
| The tool-call guard | 33 mutations, 0 survivors | [Tool-call guard](tool-call-guard.md) |
| Every `retry: noRetry` site | 14 mutations, 8 survivors — recorded, not engineered around | [The demo screen](demo-screen.md) |

That last row is the one worth reading. Eight survivors published as survivors is
a more useful artefact than a table of zeros, because it says exactly which claims
in this repo rest on an argument rather than on a test.

**The harness that applies the mutations is not in this repository.** It is a
local script, so the counts above are reported rather than reproducible from a
clone. Each individual mutation is described in the linked docs precisely enough
to re-apply by hand, which is how they were checked.

## The live-STT suite

`test/services/audio/sherpa_recognizer_live_test.dart` is the one host test that
loads the real native library and the real 43MB streaming zipformer. It exists
because the alternative was shipping TC-STT-STRM-01 written and unrun.

It is possible at all because `sherpa_onnx_macos` ships a macOS framework in the
pub cache, and `SherpaRecognizerRuntime.nativeLibraryPath` can be pointed at it —
a parameter that exists for this and nothing else; production passes `null`.

```bash
# 43.6MB, ungated, apache-2.0 — the same four files the app provisions.
R=https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-en-20M-2023-02-17/resolve/main
mkdir -p /tmp/fieldops-stt && cd /tmp/fieldops-stt
for f in encoder-epoch-99-avg-1.int8.onnx decoder-epoch-99-avg-1.int8.onnx \
         joiner-epoch-99-avg-1.int8.onnx tokens.txt; do curl -sLO "$R/$f"; done

flutter test test/services/audio/sherpa_recognizer_live_test.dart \
  --dart-define=FIELDOPS_STT_MODEL_DIR=/tmp/fieldops-stt \
  --dart-define=FIELDOPS_SHERPA_LIB=$HOME/.pub-cache/hosted/pub.dev/sherpa_onnx_macos-1.13.5/macos
```

It **skips itself** unless those defines are supplied, so CI stays hermetic — the
skip is what keeps it out of CI, not the `live-stt` tag, which exists only to
silence the analyzer's unknown-tag warning.

It is not a substitute for the device run. What it moves from *unverified* to
*measured* is everything except "an arm64 device can load this" — and it is how
the first-word defect was finally reproduced without a device in the room. See
[Speech to text](speech-to-text.md).

## CI

`.github/workflows/ci.yaml` runs on every push to `main` and every pull request:
`pub get`, a codegen freshness check, `dart format --set-exit-if-changed`,
`flutter analyze`, `flutter test`. Host tier only — `flutter test` does not pick
up `integration_test/`, so no CI job ever needs a device or a gigabyte of weights.

Two of those steps are decisions rather than defaults.

**The Flutter version is pinned, and the pin is the point.** `channel: stable`
alone resolves whatever Flutter shipped most recently. Runs through 2026-08-12
resolved 3.44.9 and were green; on 2026-08-13 the *same commits* resolved 3.47.0
and went red on `main` — the freshness gate below firing on Google's release
rather than on any drift in this repo. A gate that reports on its own toolchain
moving is a gate people learn to ignore. So the version is pinned to 3.44.9, and
raising it is a deliberate change with its own suite run, the way every other
pinned thing here is treated: the model SHA-256s, the SQLCipher KDF iterations,
the `sherpa_onnx` version.

**Generated Drift code is committed, so CI regenerates it and fails on a diff.**
`*.g.dart` can drift silently from the tables it is generated from — which already
happened once here and was caught only by human review. The step runs *before*
analyze and test, deliberately: if generation changes the sources, everything
after it should be judged against the regenerated code rather than the committed
snapshot.

The check is two commands, and the second one is not redundant:

```bash
dart run build_runner build --delete-conflicting-outputs
git diff --exit-code
test -z "$(git ls-files --others --exclude-standard)"
```

`git diff --exit-code` compares the worktree to the index, which on a fresh
checkout equals `HEAD` — so a *modified* generated file is caught. It cannot see an
**untracked** one, so a newly generated output that was never committed would slip
through; the `ls-files --others` check closes that.

One note for reproducing it locally: with a warm `.dart_tool/build` cache,
`build_runner` writes zero outputs and will not restore a stale in-source file, so
a local pass proves nothing. Delete `.dart_tool/build`, or use a fresh clone.

## The tiers in detail

- **Unit tier** (`test/`) — pure Dart, deterministic, runs in CI on every commit
  (engine fakes, database, FTS, seeding, retrieval routing and prompt
  compilation, the agent tool registry, the tool-call guard, the agent loop,
  the golden transcript suite, model provisioning, microphone capture, the STT
  config/protocol/worker/host and the STT engine, spoken-digit normalisation, the
  startup wiring, the demo viewmodel, widget tests). The widget suite is split on
  purpose — see *Two things a host test cannot tell you* in
  [the demo screen](demo-screen.md); rendering tests inject state, wiring tests
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
  `UPDATE_GOLDENS=1 flutter test test/golden`; see [Golden transcripts](golden-transcripts.md) for
  what the flag deliberately will not let you do.
- **Integration tier** (`integration_test/`) — on-device runs against real
  backends. `flutter test` does not pick this directory up, so CI stays host-only.
  Exactly two files need `--dart-define`s — `model_provisioning_test.dart` and
  `llm_inference_test.dart`, because the Gemma weights are gated and their URI and
  digest are build-time inputs. Both **skip** with an actionable message when the
  defines are absent, so CI has nothing to fetch. Everything else in the directory
  runs from a clean clone: the STT model's source and its four SHA-256 pins are
  committed on the catalog entry, and the microphone needs no model at all.

  Nine files, and their state is uneven on purpose — a device run is a thing
  someone has to sit down and do, so which ones have actually happened is recorded
  per file rather than averaged into a claim about the tier.
  - `model_provisioning_test.dart` (TC-PROV-E2E-01) — a real download, verify and
    install.
  - `stt_test.dart` (TC-STT-INIT-01, TC-STT-STRM-01) — loads the streaming
    zipformer on a background isolate and transcribes the recorded fixture, with
    fuzzy containment rather than exact equality. No defines; it provisions the
    43.65MB set first if it is absent. ✅ **Both ACs passed on the demo iPad**
    (Air M4 / iOS 26.5), 3/3, on 2026-07-12 — load 430ms from an `absent` install,
    then 101 frames → 25 transcripts in 391ms, with a transcript **byte-identical
    to the host run**. See [speech to text](speech-to-text.md).
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
  - `agent_loop_e2e_test.dart` (TC-AGENT-E2E-01) — the whole retrieve-to-answer slice with
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
    have supplied them. (This paragraph said "Not yet run" until it was corrected:
    the run had already happened, in commit `9afeb5b`, which recorded the result
    elsewhere and left this document behind.) The companion `-01b` **failed on its
    premise**, which is the more valuable half — see *The no-match path* in
    [the demo screen](demo-screen.md).
  - `demo_flow_test.dart` (TC-UI-DEMO-01) — the same slice again, but through the
    **UI**, and it is the only test in the repo that pumps `FieldOpsApp` with no
    overrides at all. That is the whole reason it exists on top of the suite above:
    it is the only place the startup's three real wirings run as the app performs them —
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
    check, and that the stream closes cleanly, which the STT engine's `transcribe` needs
    in order to ever emit a final transcript. (The cadence assertion used to be
    described as the only place a substituted rate is observable. It is not: a
    *silent* substitution is not a state either platform reaches, and the one
    reachable coercion faults the capture first — see *The format-coercion
    tripwire* in [microphone capture](microphone-capture.md).) Needs no
    `--dart-define`. It
    **skips** on the first run: it raises the OS permission prompt, which no
    `WidgetTester` gesture can dismiss, because that dialog is not in the Flutter
    view hierarchy. Grant it and run again.
  - `multi_model_provisioning_test.dart` (TC-PROV-SET-04) — the LLM and the STT
    set installed side by side, proving the second install leaves the first alone
    and that the two models' paths are disjoint. No defines.
  - `voice_inquiry_test.dart` (TC-VOICE-FILL-01) — dictated audio becoming the
    text in the inquiry field, through the real recogniser and the real screen,
    with the **microphone** substituted for the committed fixture so the assertion
    does not depend on the room. ⚠️ **Run once, failed on a defect in its own
    fixture, not re-run since the fix** — so it has never been observed to pass.
    See [voice and work order](voice-and-work-order.md).
  - `clarification_test.dart` (TC-UI-CLAR-01) — the clarification modal under a
    real finger. Verified as a UI and **unverified as an interaction**, and the
    file says so in those words: Gemma 4 E2B does not use the `clarification`
    argument, and a test that drove the model until it happened to comply would be
    measuring the prompt it took to get there. No defines.

---

[← Back to the README](../README.md)
