# FieldOps Copilot

An offline-first Flutter app for elevator field-service technicians. A technician
describes a fault — by voice or by typing — and an **on-device** language model
retrieves the relevant manual entry, checks the local warehouse, and fills in a
structured work order.

**Nothing leaves the device.** No network is required at any point after install:
the manual, the parts inventory, the 2.59GB language model and the speech
recogniser all live locally.

```
"Fault code E-102 on car three. Brake pads are worn, I replaced
 BRK-990-XP. Took me an hour and a half, lockout/tagout verified."

  → retrieved   Traction Brake Pad Wear & Vibration (E-102)
  → tool call   get_local_parts_inventory("BRK-990-XP")
                → 2 in stock at Aisle 4, Shelf B
  → tool call   record_work_order_fields({...})
  → work order  4 of 4 fields filled — including 1.5 hours,
                converted from "an hour and a half"
```

Verified on real hardware — an iPad Air M4 (iOS 26.5) for the inference and
frame-budget measurements, an iPad Pro 11 (iOS 17.5) for the voice and
work-order runs. Every measured figure in the deep dives names the device it came
from. The domain is fictional; the engineering is not.

## Status

| Capability | State |
|---|---|
| Encrypted local database, offline retrieval, first-launch seeding | ✅ shipped |
| Model provisioning — SHA-256 pinned, resumable, atomic | ✅ shipped |
| On-device LLM (Gemma 4 E2B / LiteRT-LM) with native function calling | ✅ shipped |
| Agent loop, tool registry, defensive call guard | ✅ shipped |
| Microphone capture + on-device speech-to-text | ✅ shipped |
| Voice → inquiry → agent → auto-filled work order | ✅ shipped |
| Camera OCR / barcode scanning (`VisionEngine`) | ⬜ still a fake — the one remaining stub |

1179 host tests, 7 golden transcript snapshots, 9 device integration test files.

## Architecture

MVVMC, with **every device capability behind a Dart interface**. That single rule
is what makes an app built around a 2.59GB model and a native recogniser testable
on a laptop with neither installed.

```
┌─ views/ ────────────────┐   Flutter widgets. One screen.
│  diagnose_screen.dart   │
└───────────┬─────────────┘
            │ Riverpod
┌───────────▼─────────────┐   State the screen renders. No plugin types.
│  viewmodels/            │   field_job · dictation · work_order_form
└───────────┬─────────────┘
┌───────────▼─────────────┐   The orchestration. Pure Dart, fully testable.
│  services/ai/           │   agent_loop · tool_registry · tool_call_guard
│  services/rag/          │   retrieval_router · prompt_compiler
└───────────┬─────────────┘
┌───────────▼─────────────┐   The interfaces: LlmEngine, SttEngine,
│  engines/               │   VisionEngine, PlatformTelemetry
└─────┬──────────────┬────┘
      │              │
┌─────▼─────┐  ┌─────▼──────────┐   The only files that import a native
│ impl/     │  │ fakes/         │   plugin — one per capability, each
│ (device)  │  │ (host tests)   │   on its own isolate.
└───────────┘  └────────────────┘
```

Both native runtimes run on **dedicated background isolates**. That is not
defensive habit: `flutter_gemma`'s and `sherpa_onnx`'s Dart APIs are synchronous
blocking FFI, so a decode step on the UI isolate is a dropped frame, measured.

## Six design decisions, and what each cost

### 1 · A fake engine must be unreachable in production, not merely unused

Every capability has a deterministic fake so the host suite can run without a
model. The obvious wiring — fall back to the fake when no weights are installed —
produces something worse than a broken app: one that **answers fluently on a
device where the model never ran**, indistinguishable from a working app in a
screen recording.

So the production graph never falls back. Absent weights resolve to `null` and the
UI says so. A test (`no_fake_in_production_test.dart`) walks the resolved type
system to prove no production path reaches a fake — it is a test about the
*shape of the wiring*, because a convention nobody checks is a convention that
breaks.

**Cost:** every screen must handle a `null` engine. Worth it — that is also the
first-launch state.

### 2 · Structured output goes through the tool registry, not through the prose

The model fills the work order by **calling a tool**, not by emitting a JSON blob
the app scrapes out of its answer. The schema then drives constrained decoding,
the malformed-call guard already covers it, the agent loop already feeds refusals
back, and the exchange lands in the golden snapshots. A scraped blob has none of
that and needs a brace scanner nobody wants to own.

→ [Agent tools](docs/agent-tools.md) · [The tool-call guard](docs/tool-call-guard.md)

### 3 · The technician outranks the agent

A field the technician typed is **never** overwritten. The agent's value parks
beside it as a suggestion they can take or dismiss; typing during dictation takes
the field *and* stops the microphone. A refused field update is a **successful**
tool call — reporting it as a failure would tell the model its whole call was
rejected when most of it landed.

→ [Voice input and the work order](docs/voice-and-work-order.md)

### 4 · Weights that do not verify do not run

Every model file carries a committed SHA-256 pin. Downloads are resumable and
staged in a `.part` directory, renamed into place only after **every** file in the
set verifies. A truncated encoder does not fail cleanly — it transcribes noise,
which reaches a technician as a confident sentence.

**Cost:** the URL and hash are build inputs (`--dart-define`), not constants,
because hard-coding either would commit a guess about a file this repository has
never downloaded.

→ [Model provisioning](docs/model-provisioning.md)

### 5 · The prompt is snapshotted, because a prompt is code

Seven golden scenarios pin the whole loop — compiled prompt, tool calls, payloads,
final transcript — and run on every CI push. A prompt edit that changes model
behaviour fails a test rather than a demo.

This paid out immediately. When a second tool was registered, a sentence saying
*"do not call any tool"* silently changed meaning from "don't invent a part
number" to "and don't fill in the work order either" — on the one path where the
technician's words are the only source of work-order data.

→ [Golden transcripts](docs/golden-transcripts.md)

### 6 · A tool the app depends on is named in the preamble, not just its schema

Found on the device, not in review. Given a four-field inquiry, Gemma 4 E2B called
the inventory tool, wrote a correct plan, left the work order empty, and closed
with *"if you… need to record the work order fields, please let me know."*

It knew the tool existed and treated it as an offer, because the preamble carried
a `MUST` for one tool and a description for the other. **A schema tells a model
what a tool is; the preamble tells it what the job requires.**

→ [Retrieval and the grounded prompt](docs/retrieval-and-prompt.md)

## What the device taught that the host suite could not

Four defects reached a device with a green host suite behind them. Three share one
cause, and it is the most useful thing in this repo:

> **A test double kinder than the hardware is a test that cannot fail.**

- **The first word of every dictation session was lost.** Not our capture — the
  recogniser mangles the opening of a stream. Two fixes reasoned from the code
  failed before a host reproduction found it in minutes, and then refuted three
  further hypotheses before they could become fixes three, four and five.
- **A `RangeError` killed dictation on the first frame.** Mic frames arrive as
  `Uint8List` views at whatever offset the platform allocator returned — 5, here.
  Every test double built frames with `Uint8List.fromList`, which is always
  aligned. 1158 tests were green while dictation died on every session.
- **A work order mixed two jobs**, showing one fault's hours under another's
  fault code, with the agent-origin marker on both.
- **The tool was never called** — decision 6 above.

→ [Speech to text](docs/speech-to-text.md) · [Microphone capture](docs/microphone-capture.md)

## Getting started

Requires the Flutter SDK (stable, Dart 3.12+). iOS 16.0+ or a 64-bit Android
device to run the on-device model.

```bash
flutter pub get
flutter run
```

Without the model defines the app still runs: the banner reports that the model
source is not configured and **Diagnose** stays disabled — the correct behaviour,
not a degraded one. To run the real thing, accept the
[Gemma terms](https://ai.google.dev/gemma/terms) and pass:

```bash
flutter run -d <device> \
  --dart-define=FIELDOPS_MODEL_ID=gemma-4-e2b-it-int4 \
  --dart-define=FIELDOPS_MODEL_URI=<resolve URL for the file you licensed> \
  --dart-define=FIELDOPS_MODEL_SHA256=<its sha256>
```

The speech model needs no defines — its source and four hashes are committed.

Then type a fault (`cabin vibrating, E-102`) and tap **Diagnose**. For driving it
by hand, including what to say to the microphone and what each prompt should
produce, see **[device test scenarios](docs/device-test-scenarios.md)**.

## Testing

```bash
flutter test                                  # 1179 host tests
flutter test --tags live-stt --dart-define=…  # the real recogniser, on the host
flutter run integration_test/<file>.dart -d <device> --publish-port
```

Three things this project does that are worth stealing:

- **Golden transcripts** over the whole agent loop, not just unit assertions.
- **Targeted mutation testing.** Every mutation is a defect a reviewer proposed;
  a fix whose own mutation survives has not been demonstrated, however good the
  argument. One "fix" in this repo was reverted on exactly that basis.
- **A live-model suite on the host.** `sherpa_onnx` ships a macOS framework, so
  the real recogniser runs against real weights in CI-free opt-in tests — which is
  how the first-word defect was finally reproduced without a device.

→ [Testing](docs/testing.md)

## Deep dives

| | |
|---|---|
| [On-device inference](docs/on-device-inference.md) | Gemma 4 E2B over LiteRT-LM, isolates, native function calling, measured frame budgets |
| [The agent loop](docs/agent-loop.md) | Retrieval → prompt → tools → answer, the turn cap, three ways a run ends |
| [Agent tools](docs/agent-tools.md) | The `AgentTool` contract, typed arguments, refusal-as-success |
| [The tool-call guard](docs/tool-call-guard.md) | Calls spelled as prose, invented tools, repeated calls |
| [Retrieval and the grounded prompt](docs/retrieval-and-prompt.md) | Code lookup merged code-first with FTS, and prompt-injection defences |
| [Offline retrieval](docs/offline-retrieval.md) | FTS5, and the exact-match column a fault code needs |
| [Model provisioning](docs/model-provisioning.md) | Pinned hashes, atomic installs, resumable downloads |
| [Data persistence & encryption](docs/data-persistence-and-encryption.md) | drift + SQLite3MultipleCiphers, ChaCha20-Poly1305 |
| [First-launch seeding](docs/first-launch-seeding.md) | Transactional seeding and revision checks |
| [Speech to text](docs/speech-to-text.md) | Streaming zipformer on an isolate, and the first-word defect |
| [Microphone capture](docs/microphone-capture.md) | 16 kHz mono PCM, bounded backlog, stall watchdog |
| [Voice input and the work order](docs/voice-and-work-order.md) | Mic → transcript → agent → form, and precedence |
| [The demo screen](docs/demo-screen.md) | One screen, and the frame measurements that shaped it |
| [Golden transcripts](docs/golden-transcripts.md) | Snapshotting the loop |
| [Testing](docs/testing.md) | Tiers, mutation testing, what a host test cannot tell you |
| [Device test scenarios](docs/device-test-scenarios.md) | Manual end-to-end checks, with expectations from the seed |

## Tech stack

| Concern | Choice |
|---|---|
| UI framework | Flutter (Material 3) |
| State management | Riverpod (`flutter_riverpod`) |
| Architecture | MVVMC with engine-abstraction interfaces |
| Local database | drift + SQLite3MultipleCiphers (`source: sqlite3mc`) |
| On-device LLM | Gemma 4 E2B (`.litertlm`) via `flutter_gemma` + `flutter_gemma_litertlm` (LiteRT-LM, `dart:ffi`) |
| On-device STT | streaming zipformer (en, 20M, int8) via `sherpa_onnx` (`dart:ffi`) |
| Audio capture | `record` (16-bit mono PCM) behind an `AudioInput` seam |
| Threading | One dedicated background isolate per native runtime, encoded message protocols |
| Model delivery | `dart:io` streaming download + `crypto` SHA-256 verify, no-backup storage |
| Testing | `flutter_test`, `integration_test`, golden snapshots, targeted mutation testing |
| CI | GitHub Actions |

## License

Not yet specified.
