# The demo screen

One screen, and the whole retrieve-to-answer slice behind it: type a fault, tap **Diagnose**,
and the on-device model streams a repair plan grounded in the bundled service
manual, checking the local warehouse table on the way.

```
[ technician types - or dictates - "cabin vibrating, E-102" ]
        │
        ├─ RetrievalRouter ──── E-102 → structured column; "cabin vibrating" → FTS5
        ├─ PromptCompiler ───── [MANUAL DOCUMENT] + [USER INQUIRY]
        └─ AgentLoop ────────── Gemma 4 E2B → native tool call
                                      │
                                      ├─ get_local_parts_inventory(BRK-990-XP)
                                      │        → {in_stock: 2, aisle: "Aisle 4, Shelf B"}
                                      ├─ record_work_order_fields({fault_code, …})
                                      │        → the work-order panel fills, live
                                      └─ turn 2 → grounded answer, streamed to screen
```

The microphone beside the inquiry field and the work-order panel
below the answer are both described under [Voice input and the work order](voice-and-work-order.md); what
matters to *this* section is one layout consequence: the panel is deliberately
**outside** the answer's scroll view, because that view jumps to its own bottom on
every token and `jumpTo` opens with `goIdle()`, which disposes the active drag.
Text fields do not live in a container that jumps.

`lib/views/diagnose_screen.dart` renders it; `lib/viewmodels/field_job_viewmodel.dart`
folds `AgentLoop.run`'s event stream into the state it draws from. The composition
itself really is three lines, which is the point of everything above it:

```dart
final retrieval = await router.retrieve(inquiry);
final prompt = compiler.compile(retrieval);
final loop = AgentLoop(engine: warmup.engine, registry: registry);
```

## The three deferred wirings

Every layer of the slice below this screen shipped with no production call
site, and each recorded the same reason: the piece needs a `DatabaseService`, and
opening a database needs an encryption key nobody had decided on. This is where
that ends.

**1. The database, and therefore the key.** `databaseEncryptionKeyProvider` reads
`--dart-define=FIELDOPS_DB_KEY` and falls back to a constant named
`demoDatabaseKey`, whose value is literally `fieldops-demo-key-not-a-secret`.

That name is doing work. A hardcoded key is acceptable for a demo, but only as a
*recorded decision* - and the honest recording is that the
cipher is real while the key management is not. ChaCha20-Poly1305 with pinned KDF
iterations means a database file lifted off the device is ciphertext; a passphrase
compiled into the binary means anyone who can read the app bundle can read the key.
So this protects a stolen **file** and not a stolen **device**, and the design's
"sensitive data remains sandboxed on the physical device" is true of the storage
and only partly true of the threat model. The fleet answer - a key generated on
first launch, held in the Keychain or Keystore behind device-passcode protection,
never present in the binary - slots in behind this one provider without touching
anything downstream, and is designed but deliberately not built.

One operational hazard, because it is silent: the key is part of the database's
identity. Add the define to a build that previously used the demo key and the
existing file cannot be decrypted. It surfaces as a rendered startup failure on the
screen, not as a fresh empty database, which is the failure worth fearing.

**2. The first-launch seed - as a dependency, not a call order.** `ensureSeeded()`
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

It is the same `DatabaseService` instance - nothing is wrapped - and the only thing
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
post-frame callback - so the weights load at app start, never on the Diagnose tap.

**The original design predicted a different mechanism and the prediction does not
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
from a scripted list - on a machine where the model never ran. There is no worse
failure mode in this project, because it is indistinguishable from success in a
screen recording, which is the artefact this screen exists to make. So `null` is a
first-class answer, the status row says "no verified weights on this device - the
agent cannot run", and the button is dead. Tests reach the fake by overriding
*this* provider, which is a deliberate act in a test file.

## Nothing animates while the model works

This is the design constraint the inference measurements imposed (see
[docs/on-device-inference.md](on-device-inference.md)), and it is the one
thing on this screen that would be wrong in an obvious implementation.

On the demo device (iPad Air M4, iOS 26.5, Metal) the **UI
isolate** was measured stalling **1445–1728ms** while the weights load - roughly 90 dropped
frames at a 16.7ms budget - and dropping **5–8 frames** (77–135ms worst gap) while
tokens stream. Inference genuinely runs on a background isolate the app owns; what
stalls is the load, and the cause is still open (a forced-CPU run that stalled
*worse* while loading faster eliminated Metal pipeline compilation; memory traffic
during the `mmap` walk and a shared-heap GC pause remain live).

The trap: what stalls is the **UI isolate**, so a spinner displayed *during* the
load freezes with it. A frozen progress indicator reads as a crashed app, which is
strictly worse than a static label that says what is happening. So:

- there is no `CircularProgressIndicator` and no `LinearProgressIndicator` anywhere
  in the screen's tree - `diagnose_screen.dart` or any of the components it
  composes - and `test/views/diagnose_screen_test.dart` asserts that
  **structurally** - it walks the tree for any `ProgressIndicator` in the loading
  state, the generating state and the tool-running state, rather than trusting this
  paragraph. The wider wording is deliberate: the widgets this rule is about now
  live under `components/`, and a claim scoped to one file would have quietly
  stopped covering them;
- `EngineWarmupController` sets `EngineLoading` *before* awaiting the load, so the
  frame carrying the static row is painted on the other side of an await boundary,
  i.e. before the work that blocks the isolate begins;
- warm-up is kicked off from a post-frame callback, so the first frame exists before
  the stall - calling it synchronously in `initState` would stall the isolate before
  anything was on screen, which is a launch that looks like a hang;
- the **live token stream is the progress indicator**. Text appearing is
  unambiguous evidence of work, it cannot stutter in a way that reads as a hang, and
  it is the most convincing thing in the recording.

One exception stays, and it is a different thing: `ModelReadinessBanner` shows a
determinate bar while *downloading* weights. A download is network I/O with no
UI-isolate stall, and that widget belongs to provisioning.

## All three stop reasons render differently

`AgentStopReason` has three values and `AgentLoop` authors truthful, non-empty text
for every one of them - `answered` carries the model's words, `emptyResponse` and
`iterationCapReached` carry loop-authored messages. That is a trap for the UI: a
screen could render all three identically and look correct in every test, while
handing a technician *"the assistant kept requesting warehouse lookups without
producing an answer, so it was stopped"* in the same panel, with the same styling,
as a repair plan.

So the viewmodel exposes one question - `FieldJobState.isDiagnosis` - and the
screen branches on it once:

| Stop reason           | Header               | What it means                                |
| --------------------- | -------------------- | -------------------------------------------- |
| `answered`            | **Repair plan**      | the model's own words, grounded              |
| `emptyResponse`       | No answer produced   | nothing to render, said out loud rather than shown as a blank panel |
| `iterationCapReached` | Diagnosis stopped    | the loop reports its own failure; it does not invent a diagnosis |

Each outcome panel carries a key derived from the enum
(`diagnose-outcome-<name>`), and there is one test per ending asserting that
exactly its own panel is on screen and the other two are not.

**The golden suite still leaves a gap here.** `emptyResponse` has no golden - the
other two stop reasons do. The third ending is bound where it is actually needed -
the viewmodel suite asserts the state and the widget suite asserts the rendering -
so nothing is unguarded, but the transcript-level record is incomplete. Recorded as
unfinished rather than quietly dropped.

## What the screen shows besides the answer

- **A "grounded in" line**, naming the manual entries retrieval found, on screen
  *before* the first token. That ordering is deliberate: a grounding line that
  appears with the answer annotates it, one that appears first frames it. It is the
  architectural claim made visible - a viewer can see which documents the model was
  given and compare them to what it said.
- **A tool-activity line** while a lookup is in flight ("Checking local inventory
  for BRK-990-XP…"), which is possible only because the agent loop emits
  `AgentToolCallStarted` *before* running the query. It clears when the lookup
  completes, not when the run ends - a distinction that survived only because a
  mutation caught it: `AgentCompleted` also clears the field, so dropping the clear
  from the completion event left every test green while the indicator would have
  claimed a lookup was running through the entire second turn, over the streaming
  answer.
- **Completed lookups, summarised from the payload** rather than from the
  arguments, so a viewer comparing the line to the answer is checking the grounding
  by eye. The inventory tool's two success shapes stay apart on the page for the reason they
  are apart in the payload: "the warehouse does not carry NOT-A-REAL-SKU" and
  "BELT-330-DRV is carried but out of stock" are different sentences to a
  technician.
- **Refused call attempts**, reported rather than dropped. A technician watching the
  model fumble a call and recover is the agent loop being legible instead of
  magical, and silently hiding them would make a four-turn run look like an
  inexplicably slow two-turn one.

## Failures are screens, not exceptions

A malformed seed asset or a key that no longer opens the database is a **build or
configuration defect**, and this app's rule is that it fails loudly at startup. Loudly
means legible: the error arrives as an errored `AsyncValue`, the screen renders it
with the message attached, and Diagnose is dead until it is fixed. A grey screen
with a stack trace in a console nobody is reading is the quiet version.

A run that throws is a *different* thing and renders differently: the screen says
what failed and the button comes back, because "that attempt did not work" and
"this app is misconfigured" ask different things of whoever is looking.

`on Exception`, never `on Object` - the rule `ToolRegistry.dispatch` writes down,
one layer up. An `Error` means the app is broken, and dressing it as "the diagnosis
could not be completed" hides a defect behind a plausible operational message.

## A Riverpod 3 default that is wrong for every startup provider here

Worth its own heading because it is a framework behaviour, not a choice, and it
silently converts "fail loudly at startup" into "hang for half a minute, then fail".

`ProviderContainer.defaultRetry` retries a provider whose body threw, with
exponential backoff - 200ms doubling to a 6.4s cap, ten attempts - and it skips
only `Error` and `ProviderException`. Every ordinary `Exception` is retried.
Measured, by removing the policy and sampling: the seed provider's body ran **11
times** and the element was still `AsyncLoading` at 30s, `AsyncError` by 45s.

All three ways this app's startup fails are deterministic - a malformed asset
(`SeedFormatException`), a key that does not open the file (`SqliteException`), a
platform channel with no implementation (`MissingPluginException`) - so a retry
cannot change the outcome. Worse than the delay is what is on screen during it: the
provider stays in `AsyncLoading`, so the UI says "checking…" for half a minute and
*then* reports a failure that was settled on the first attempt.

`lib/services/retry_policy.dart` exports `noRetry`, applied per provider along the
whole startup chain (including the model-status providers, which sit upstream of
the engine seam and would otherwise hold the chain in `AsyncLoading` regardless of
what the ones below declare). Scoped per provider rather than set container-wide on
purpose: a container-wide default would silently apply to the next provider someone
adds, including one that really is transient and really should back off. Naming the
policy at each site keeps the claim - *this failure is deterministic* - next to the
code that has to be true for it. It is the same rule
`ModelProvisioningController` already writes down for a download that failed its
digest: "a retry moves the same gigabytes and fails the same way."

**How much of that is bound by a test, measured site by site.** Every one of the
fourteen `retry: noRetry` sites was mutated individually - the policy deleted, the
whole host suite run - at the tree this paragraph ships with. Six die, eight
survive:

| bound (deleting `noRetry` fails a test) | unbound (deleting it leaves the suite green) |
|---|---|
| `seedOutcomeProvider` (4 tests) | `appDatabaseProvider` |
| `seededDatabaseProvider` (1) | `retrievalRouterProvider` |
| `modelStorageProvider` (1) | `toolRegistryProvider` |
| `modelProvisionerProvider` (1) | `inferenceConfigProvider` |
| `modelInstallStatusProvider` (1) | `deviceLlmEngineProvider` |
| `agentEngineProvider` (2) | `sttConfigProvider` |
| | `deviceSttEngineProvider` |
| | `dictationEngineProvider` |

The last three are the speech path, and they were measured after the first eleven
rather than with them: they did not exist when this table was first built, and the
count in this paragraph said "eleven" for as long as it took to notice. All three
survive, which is the expected result and not a happy one - see below.

The two that matter most are bound deliberately, by build counters:
`seedOutcomeProvider` over a malformed asset, and `modelInstallStatusProvider` over
a `MissingPluginException` from `modelStorageProvider` - the failure every host
widget test actually hits, and the site whose own doc makes the strongest claim in
the set (that the banner would otherwise sit on "Checking model…" for half a minute
before reporting a status it says must be distinguishable from ready and absent).
The other four die as a side effect of those two counters and of tests that would
time out without the policy.

The eight survivors are recorded rather than engineered around: each is upstream or
downstream of a bound site, and no test reaches its own failure path. They are not
*wrong* - the policy is right at every site, for the reason above - they are
**unguarded**, which is a different and smaller claim than the one this paragraph
first made. The first version said "bound by a test that counts provider builds"
with no qualifier, which was true of exactly one site.

One methodological note, because it nearly produced a false table. Seven of the
first eleven mutations initially came back **`NO_OP`** - a bug in the script that
generated them meant the edit did not change the file at all. The harness reports
that as its own status rather than as `SURVIVED`, which is the distinction it was
built to make: *a survivor is evidence about the tests only once the edit is
confirmed to change something.* Filed as survivors, they would have produced a
published claim that nine of eleven sites were unbound, from seven measurements
that never ran.

## Two things a host test cannot tell you, found by watching tests fail

Both are recorded because each cost a debugging session and neither is guessable:

- **`pumpEventQueue()` hangs inside `testWidgets`.** It awaits a zero-duration
  `Future.delayed`, whose `Timer` the widget binding *fakes*, so nothing ever fires
  it and the test sits until `pumpAndSettle`'s ten-minute deadline. Real
  asynchronous work in a widget test needs `tester.runAsync`, which is the only way
  the real event loop gets a slice.
- **On the host this slice is too fast to observe.** drift's `NativeDatabase` runs
  sqlite3 **synchronously in-process** (not `createInBackground`), and
  `FakeLlmEngine` replays a turn as fast as it is drained - so retrieval,
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

## The no-match path: do not demo it yet

Carried in from the agent loop's device run and unresolved. The words `the`, `on` and `is`
each retrieve manual entries on their own - the sanitizer joins terms with
`OR` and FTS5's `porter` tokenizer removes no stop words - so almost any English
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

## Running it

```bash
flutter run -d <device> \
  --dart-define=FIELDOPS_MODEL_ID=gemma-4-e2b-it-int4 \
  --dart-define=FIELDOPS_MODEL_URI=<resolve URL for the file you licensed> \
  --dart-define=FIELDOPS_MODEL_SHA256=<its sha256>
```

Without the defines the app runs, the banner says the model source is not
configured, and Diagnose stays dead - which is the correct behaviour, not a
degraded one. Add `--dart-define=FIELDOPS_DB_KEY=<passphrase>` to use something
other than the named demo key.

For driving the app **by hand** on a device - including what to say to the
microphone and what each prompt should produce - see
[`docs/device-test-scenarios.md`](device-test-scenarios.md). Every
expectation there is quoted from the seeded manual and warehouse, so a run that
disagrees with it is a finding rather than a judgement call. It also records what
the 20M recogniser is and is not good at, which is worth reading before dictating
a part number at it.

The on-device acceptance test is `integration_test/demo_flow_test.dart`
(TC-UI-DEMO-01). It is the only test in the repo that pumps `FieldOpsApp` with **no
overrides at all**, so it is the only one that exercises the three wirings as the
app performs them: the real application-support directory, `rootBundle` and a real
`AssetBundle`, and the real 2.59GB artifact. Every one of those is faked in the host
suite, so a failure in any of them is invisible to it.

## What the device run measured

**TC-UI-DEMO-01 passed twice** on the demo device (iPad Air M4, iOS 26.5, Metal
backend, real 2.59GB artifact). Both runs were a genuine first launch -
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

- **The load-time stall is confirmed and is at the high end of the earlier range.**
  The inference runs measured 1445ms and 1728ms on the GPU backend and 2197ms forced onto the CPU;
  2130ms and 1866ms sit inside that spread but above both GPU figures. The same
  caveat attached to the earlier RSS figure applies here: both of these runs downloaded
  the 2.6GB artifact **in the same process moments earlier**
  (`FIELDOPS_TEST_PROVISION=true`), so they are an upper bound rather than a
  side-loaded measurement. The cause is still the open question recorded in
  [docs/on-device-inference.md](on-device-inference.md).
- **The design holds where it matters.** Run 2 asserted, on **60 separate frames of
  the real 7.4-second load**, that no `ProgressIndicator` was in the tree - so the
  ~111 dropped frames land behind a static row, which is the entire point. The
  frame count is asserted to be non-zero, because a guard that never ran is not a
  guard.
- **The 247–250ms gap is *not* comparable to the earlier 77–135ms**, and the
  difference is the measurement window rather than the device. That figure timed token
  streaming; this probe spans the whole diagnose flow - retrieval, prompt
  compilation, two model turns, the SQLite inventory query and the loop's
  continuation prompt. It is the honest figure for the flow being screen-recorded,
  and at ~14 dropped frames it is a visible hitch, which is why nothing on the
  screen animates through it.
- **Throughput: this is the long generation that was owed, and it yields
  characters, not tokens.** 1401 characters in 13296ms across two turns is ~105
  chars/s - and that window includes retrieval and a tool round trip, so it is a
  *lower bound* on generation speed. It is deliberately **not** converted to
  tokens per second: the app exposes no tokenizer, and multiplying by an assumed
  chars-per-token ratio is arithmetic rather than measurement, which is exactly
  what got the earlier "2.7 tok/s" struck from the record. **The 15 tok/s design target
  therefore remains formally unmeasured**, and closing it needs a token count from
  the runtime rather than another run.

**These two runs are of the code as it stood at `8ca9e6c`, not as it ships**, and
the gap is named rather than left to be inferred. Review produced changes
after them, and the demo iPad then dropped to wireless tethering, where
`flutter test` cannot launch (`Cannot start app on wirelessly tethered iOS device`)
and `flutter run --publish-port` fails at mDNS VM-service discovery. A cable was
needed and was not available at the time, so a third run was **owed** - and it has
since been made (2026-08-07, iPad Air M4 / iOS 26.5, cabled): warm-up 8540ms with a
worst gap of **2151ms**, flow 13247ms with a worst in-flow gap of **233ms**, 1401
chars at ~106 chars/s, `stop=answered`, 71 loading frames asserted. Two things to
carry from it. The **2151ms warm-up gap is a new worst**, above the earlier
1445–1728ms band - that run was a first launch, so seeding shared the window, but it
is worth re-checking on a warm start. The **233ms in-flow gap is the best of the
three**, which is the figure the recording depends on.

What the third run settled, and what it did not:

* **Still valid, because nothing in the change touches them.** Every number in the
  table above comes from the model, the inference isolate and the database - the
  load time and its stall, the flow's elapsed time and worst gap, the answer text
  and its length, the seed outcome, the stop reason. None of the round-0 changes
  goes near the isolate, the runtime, the prompt or the database. Run 2 also
  exercised the per-frame no-animation guard as it ships (60 frames).
* **Confirmed on device by the third run and by a screen recording of the shipped
  app.** The Markdown formatter renders bold headings and `•` bullets with no raw
  `**` in the finished answer; TC-UI-DEMO-01's formatted-answer assertion executed
  and matched; the outcome panel shows its green ✓ *Repair plan*. Auto-scroll
  *following* is confirmed visually - the panel tracks the growing answer and jumps
  rather than glides.
* **What the third run did *not* settle, and what a fourth is for.** Auto-scroll
  **release** - a reader dragging up mid-generation - was the one thing the run
  could not assert and the recording did not exercise, and driving the real app by
  hand then found it broken: the panel was *unscrollable* during
  generation, because `jumpTo` disposes the active drag. Fixed and bound on the
  host under both platforms' physics, but the fix itself has not run on hardware.
* **The error-path colour and icon cannot be reached from the UI at all.**
  `isDiagnosis` is `stopReason == answered`, and a no-match retrieval still ends
  *answered* - the model declines and asks for a fault code, so the panel is
  correctly green. The red ⚠ needs `emptyResponse` or `iterationCapReached`, neither
  reachable by typing. It stays bound by host tests, and this is recorded because
  the obvious manual test for it does not test it.
* **The one thing that would have failed on device and was caught by reading
  instead.** The Markdown fix broke the old `find.text(job.displayText)` assertion:
  `find.text` matches a `Text.rich` by `textSpan.toPlainText()`, i.e. the text after
  the delimiters were consumed, so it compared formatted against raw. The host suite
  could not see it, because every rendering fixture used markup-free answer text.
  Fixed on both sides and bound by a host test carrying the real answer shape - but
  it is the clearest evidence that a rendering change wants a rendering run.

One consistency check fell out of it: the answer was **1401 characters in all three
runs, and 1401 characters in the agent loop's hand-built device harness** for the same
inquiry. That figure also resolved a scare: run 3's log shows `**Repair Prure:**`
where the screen recording of the same build shows `Repair Procedure:` rendered
correctly. A dropped token would have been a real defect in the streaming
accumulation - but the length is identical across runs, decoding is greedy, and the
*rendered* text is intact, so the corruption is in the **log transport below
`debugPrint`**, not in the app. The 1401 figure is itself computed in-app from
`job.displayText.length`, upstream of any printing, which is what makes the
comparison sound.

The stage matters and an earlier version of this paragraph got it wrong by blaming
`debugPrint` itself: `debugPrintThrottled` wraps *only* when `wrapWidth != null` and
this call site passes none, and its rate limiter defers **whole lines** past a 12KB
budget rather than truncating inside one - so a contiguous four-character elision
mid-word is not a behaviour it has. The loss happens further down, between the device
and the console. **Read answers off the screen, not off the console.** Decoding is greedy, so identical output is expected from an identical
prompt - which makes this evidence that the composition through the viewmodel and
the composition in that harness build the same prompt. Equal *length* is not proof
of equal text; it is consistent with it, which is as far as this observation goes.

---

[← Back to the README](../README.md)
