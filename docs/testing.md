# Testing

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
  `UPDATE_GOLDENS=1 flutter test test/golden`; see [Golden transcripts](golden-transcripts.md) for
  what the flag deliberately will not let you do.
- **Integration tier** (`integration_test/`) — on-device runs against real
  backends. `flutter test` does not pick this directory up, so CI stays host-only.
  `model_provisioning_test.dart` and `llm_inference_test.dart` **skip** with an
  actionable message unless the model defines above are supplied, because CI has no
  artifact to fetch and must not pull gigabytes over the network to try. (This
  sentence read "Both suites" while the directory held four files, which was
  already loose, and became wrong with the fifth: `mic_capture_test.dart`
  needs no defines at all. The sixth, `stt_test.dart`, also needs
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
    have supplied them. (This paragraph said "Not yet run" until it was corrected:
    the run had already happened, in commit `9afeb5b`, which recorded the result
    elsewhere and left this document behind.) The companion `-01b` **failed on its
    premise**, which is the more valuable half — see _The no-match path_ above.
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
    reachable coercion faults the capture first — see _The format-coercion
    tripwire_ above.) Needs no `--dart-define`. It
    **skips** on the first run: it raises the OS permission prompt, which no
    `WidgetTester` gesture can dismiss, because that dialog is not in the Flutter
    view hierarchy. Grant it and run again.

---

[← Back to the README](../README.md)
