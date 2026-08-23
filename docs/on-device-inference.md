# On-device inference

The language model is **Gemma 4 E2B** in a `.litertlm` container, executed by
[`flutter_gemma`](https://pub.dev/packages/flutter_gemma) with the
[`flutter_gemma_litertlm`](https://pub.dev/packages/flutter_gemma_litertlm)
engine - Google's LiteRT-LM runtime reached over `dart:ffi`. It sits behind the
same `LlmEngine` interface the fake implements, so nothing upstream of the
interface knows which is bound.

## Model selection

| Model | Size | Tool calling | Role here |
|---|---|---|---|
| **Gemma 4 E2B** (`.litertlm`) | 2.59 GB | **Native** function-call tokens | Shipped |
| Gemma 3 1B (`.litertlm`) | 0.58 GB | Prompt-injected declaration, JSON parsed back out | Low-RAM fallback, same interface |
| FunctionGemma 270M | 284 MB | Native, tool-calling specialist | Not shipped - see below |

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

## Why the engine runs on its own isolate

`IsolateInferenceHost` spawns a dedicated isolate and speaks a four-message
protocol to it - load, generate, stop, shutdown - with every message encoded as
a plain map so the wire format is unit-testable on the host.

Being precise about what this buys, because the plugin is not naïve about
threading either: LiteRT-LM already runs engine and conversation creation inside
`Isolate.run`, and streams generated chunks from a native decode thread through
a `NativeCallable.listener`. Part of what the boundary guarantees, the plugin
already happens to do.

"Happens to do" is the point. The frame-budget promise has to survive a plugin
upgrade, a swap to the MediaPipe `.task` engine (whose threading is not the
same), and a fallback model. An isolate at *this app's* seam is a guarantee about
our own architecture rather than a bet on a dependency's internals - and it
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

## Tool calling

Tools are declared as `ToolDefinition`s whose `parameters` map is a JSON-Schema
object, validated at registration by `tool_schema.dart`. That validation earns its
place because the same map feeds two consumers that read it completely differently,
and neither rejects a bad one:

- **Gemma 4** - the map goes to the SDK untouched as `tools_json`, and a native
  template renders the declaration from it. Passing tools also switches on
  constrained decoding, so a malformed schema is at least as likely to fail inside
  the native engine as to produce a usable declaration - with no Dart stack to read.
- **Gemma 3** - no native declaration; the plugin writes the map into the prompt
  *verbatim*. A plausible-looking `{'sku': 'String'}` neither throws nor degrades. It
  teaches the model a shape nothing downstream agrees with, and the tool call comes
  back with arguments the registry cannot read.

Either way the symptom appears two layers away as "the model is bad at tool calling",
so the shape is checked where the mistake is.

A second plugin detail is equally quiet, and what it gates depends on the family:
`supportsFunctionCalls` must be set whenever tools are passed. On Gemma 4 the
declaration reaches the model regardless, but `InferenceChat` only *reads back* the
structured calls when the flag is true - so the model emits a perfectly good tool call
that is parsed and then dropped. On the Gemma 3 fallback the flag gates the
declaration too: the tools are never mentioned to the model at all, and the plugin
logs "Tools will be ignored".

## What the engine does not do yet

Each `generate()` call is one **stateless** turn: a fresh chat, no history from
the previous call. That is what the fake does and what the golden suite depends
on - every committed transcript's second prompt **begins with the first prompt
verbatim** and appends a transcript block, because there is nowhere else for the
conversation to live. Feeding a tool *result* back for a second model turn is the
agent loop's job (see [docs/agent-loop.md](agent-loop.md)), and it extends the interface rather than quietly
inheriting an accumulated conversation.

What travels in that block is *not* uniform, and two attempts at a tidier sentence
here were both false. "The first turn in full" is wrong:
`e305_degraded_text_call`'s second prompt carries no `[ASSISTANT]` block at all,
because the loop drops the echo whenever the guard read the turn's *text* - and that
golden's own test asserts it. "The tool call and result travel in every case" is
wrong too: `recovery_ladder`'s second prompt carries a `[TOOL CALL REJECTED]` block
and neither of the others, because its first turn was a guard refusal. What every
multi-turn golden does carry, verified over all five: the previous prompt as a
prefix, a call **or** a rejection block, and a `[CONTINUE]` instruction.

## Measured on the demo device (iPad Air M4, iOS 26.5, 2026-06-14)

Three runs on the physical device against the real 2.59GB artifact: two on the backend the
engine chose (Metal) and one with the backend forced to CPU to narrow down the stall described
below. The simulator figures are kept only because the *comparison* is informative - where they
disagree, the device numbers are the numbers.

| Measurement | iPad Air M4 (2 runs) | iOS 16.4 simulator (3 runs) | iPad Air M4, forced CPU (1 run) |
|---|---|---|---|
| Backend actually initialised | **`gpu`** (Metal) | `cpu` (no Metal on a simulator) | `cpu` (requested and honoured) |
| Model load | **7.0 – 7.2 s** | 10.8 – 13.1 s | 4.4 s |
| Time to first token, `"Say OK"` | **337 / 551 ms** - the <500 ms design target **not met** (1 of 2 runs) | 1.55 – 1.77 s | 488 ms |
| Grounded turn + one tool → structured call | **2.48 – 2.58 s** | 4.6 – 5.4 s | 3.54 s |
| Process RSS after load | **1669 – 1671 MB** (from 364 MB) | 734 – 1266 MB (from 117 – 223 MB) | 1635 MB (from 363 MB) |
| UI isolate, worst gap during load | **1445 – 1728 ms** ⚠️ (87 – 104 frames) | 32 – 90 ms | **2197 ms** ⚠️ |
| UI isolate, worst gap while streaming | **77 – 135 ms** (5 – 8 frames) | 31 – 40 ms | 139 ms |

The tool call is the result that mattered: on real hardware, under grounding, Gemma 4
returns a native structured `get_local_parts_inventory{sku: BRK-990-XP}` through the SDK's
`tool_calls` path - not prose that something had to parse. Both runs, plus every simulator
run.

**The UI-isolate number is bad, and it is the one the simulator most misled us about.**
The isolate boundary keeps a 7-second model load from being a 7-second freeze, but ~1.4–1.7 s
of that load still stalls the UI isolate - **87–104 dropped frames** at a 16.7 ms budget,
reproducible across both runs, and 17× worse than the simulator suggested. Against the design
promise that the UI thread never drops frames, that is a **real violation during model
load**, not a rounding error.

Two neighbouring claims have to be held to the same standard, because an earlier version of
this section softened both:

- **Streaming is far better than the load, and still not compliant.** The worst gap while
  tokens arrive is 77–135 ms - 5–8 dropped frames, not zero. Calling that "genuinely clean"
  (as this section first did) is not something 135 ms against a 16.7 ms budget supports, and it
  has a concrete consequence: the demo is screen-recorded, and an 8-frame hitch
  during streaming is visible in a recording.
- **The <500 ms TTFT design target is not met.** 337 ms and 551 ms on the exact chip class the
  target was set for - one run under, one 10% over. A 1-of-2 pass rate is not a met target, and
  "borderline-met" applied a gentler standard than the same evidence applied to the 500MB
  footprint cap, which is recorded as refuted. Both are measurements that failed, and both are
  now written down as failed.

**One cause has been eliminated, two remain.** A forced-CPU run on the same device
(`--dart-define=FIELDOPS_TEST_BACKEND=cpu`, logged as `requested=cpu backend=cpu` so it was
not a silent fallback) still stalled - **2197 ms, worse than Metal's 1445–1728 ms** - while
loading *faster* overall (4.4 s against 7.0–7.2 s, Metal setup being the difference). So
**first-load Metal pipeline compilation is not the cause.** One run, on one device.

That leaves three, and the CPU run constrains the shape of the first rather than just
supporting it:

- **Memory *traffic*, not resident size.** Across the three device runs, resident size and stall
  length move in **opposite** directions: 1668.6 MB → 1445 ms, 1670.6 MB → 1728 ms, and
  1635.3 MB → **2197 ms**. The lowest-RSS run stalled worst, so "RSS past 1.6GB stalls every
  thread" is not the version of the hypothesis the data supports. What survives is churn rather
  than level - page faults and allocation during the `mmap` walk - which also fits a *faster*
  load stalling *longer*, since the same work is compressed into less time. This matters for the
  side-loaded experiment: someone could remove the download, watch RSS barely move, and wrongly
  conclude the hypothesis is dead. The thing to watch there is fault and allocation activity, not
  the resident figure.
- **The worker's isolate group and its shared heap** - offered by review as an untested
  hypothesis and recorded as one, because it is the only candidate so far that explains the
  direction of the anomaly. `IsolateInferenceHost` uses `Isolate.spawn`, so the worker joins the
  **root isolate's group** and shares its heap; a major GC driven by the worker's allocations
  would therefore pause the UI isolate, even though neither the worker nor the plugin's own
  `Isolate.run` can block it directly. A DevTools timeline showing the stall coinciding with GC
  events would confirm it. Note the remedy space is narrow if it is true: `Isolate.spawnUri`
  would give a separate group and heap but is not available in Flutter's AOT builds, so the
  answer would be reducing worker-side allocation or scheduling the load - not isolating the
  heap.
- Also still open: platform-channel traffic from the worker (`path_provider` and
  `shared_preferences` are marshalled via the root isolate's messenger).

What would still distinguish them: a **side-loaded-weights run**, so no 2.6GB transfer precedes
the load - which also yields the download-free RSS figure this section has to hedge - and a
**DevTools timeline** across `initialize()` to tell a Dart-level block from a process-wide
stall. Until then the mitigation is scheduling rather than architecture: **load the model
before the UI needs to be interactive**, behind the readiness banner. Note the trap in the
obvious implementation - what stalls is the UI isolate, so a spinner shown *during* the load
freezes with it, and a frozen indicator reads as a hang.

**Throughput is still not measured** - and that is a different state from the two failures
above, worth keeping distinct. A one-token answer makes tokens-per-second a restatement of
TTFT (the "1.7 / 2.7 tok/s" the harness prints is exactly that arithmetic and means nothing),
so the 15 tok/s design target is untested rather than missed. It needs a long generation on
device, which the demo run will produce. The TTFT figure above is likewise for a
prefill-light prompt; the grounded prompt's ~400-token prefill sits inside the 2.5 s turn
figure, and no separate TTFT was captured for it.

**The 500MB iOS footprint design target is unreachable, and now measurably so.** 1.67GB of
process RSS on the device, twice, within 2MB of each other - far more consistent than the
simulator's 70% swing, which suggests it is dominated by the model rather than by transfer
noise. It is still an upper bound (the suite streams the artifact through the same process
moments earlier, and `flutter test` reinstalls the app per run so a download-free
measurement needs side-loading), but no reading of 1.67GB rescues a 500MB target. The device
figure is the one of record.

## Platform requirement, and the build failure it can still produce

`flutter_gemma` requires **iOS 16.0** (`background_downloader` requires 14.0), so the
app's deployment target moved from Flutter's default 13.0 to 16.0 - all three
`IPHONEOS_DEPLOYMENT_TARGET` entries in `ios/Runner.xcodeproj/project.pbxproj`. Adopting
on-device Gemma therefore drops iOS 13–15 hardware: a real fleet constraint, not just a
build setting.

**Bumping the target is necessary but not self-enforcing.** If a device build fails with

```
Target Integrity (Xcode): The package product 'flutter-gemma' requires minimum platform
version 16.0 for the iOS platform, but this target supports 13.0
```

the project is not wrong - check
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
`grep 'iOS(' ios/Flutter/ephemeral/.../Package.swift` - it should read `.iOS("16.0")`. The
manifest is regenerated on every build, so this can recur; if it becomes a nuisance,
moving plugin management back to CocoaPods (where the floor is a literal
`platform :ios, '16.0'` in the Podfile) removes the conditional step entirely.

---

[← Back to the README](../README.md)
