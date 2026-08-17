# Device test scenarios

Manual end-to-end checks for FieldOps Copilot on a real device. Everything here
runs **offline** — the manual, the warehouse and both models are on the device.

These complement the automated device tests rather than replacing them. Where an
`integration_test` file already owns a property, this document says so and does
not re-assert it by hand.

```bash
flutter run -d <device> \
  --dart-define=FIELDOPS_MODEL_ID=gemma-4-e2b-it-int4 \
  --dart-define=FIELDOPS_MODEL_URI=<resolve URL for the file you licensed> \
  --dart-define=FIELDOPS_MODEL_SHA256=<its sha256> \
  --dart-define=FIELDOPS_MODEL_TOKEN=<token, gated sources only>
```

The STT model needs **no defines** — its source and four SHA-256 pins are
committed on Task 2.0's catalog entry. Wait for both rows of the readiness banner
to read **Model ready** before starting.

## The seeded world

Every expectation below is exact because it comes from
`assets/elevator_manual_seed.json`. If a run disagrees with this table, the
disagreement is the finding.

### Manual entries

| Fault | Title | Part | Key symptoms |
|---|---|---|---|
| **E-102** | Traction Brake Pad Wear & Vibration | `BRK-990-XP` | squealing on deceleration, cabin vibration at terminal landings |
| **E-204** | Proportional Valve Flow Discrepancy | `FLT-440-HYD` | levelling out by >5mm, rough transitions, temperature warning |
| **E-305** | Door Clutches & Belt Slippage | `BELT-330-DRV` | doors cycle three times, obstruction warning, belt squeal |

### Inventory

| SKU | Part | Stock | Location |
|---|---|---|---|
| `BRK-990-XP` | Traction Brake Pad Assembly | 2 | Aisle 4, Shelf B |
| `FLT-440-HYD` | Hydraulic Pilot Valve Filter Mesh | 5 | Aisle 2, Shelf A |
| `BELT-330-DRV` | Door Operator Drive Belt | **0** | Aisle 1, Shelf C |
| `CAL-050-KIT` | Caliper Clearance Shim Kit | 12 | Aisle 4, Shelf A |
| `SNS-770-OPT` | Optical Door Curtain Sensor | 1 | Aisle 3, Shelf D |

`BELT-330-DRV` at zero is the interesting one, and it is seeded that way on
purpose — see scenario 2.

---

## What the recogniser is and is not good at

Read this before running any voice scenario, or a model limitation will look like
a bug.

The STT model is a **20M int8 streaming zipformer**. It handles conversational
English well and mangles anything alphanumeric. Measured on device:

| spoken | heard |
|---|---|
| "took me an hour and a half" | verbatim ✅ |
| "the cabin is vibrating badly" | verbatim ✅ |
| "fault code" | `FOLD COLD` / `FALK CODE` |
| "BRK-990-XP" | `R K 99 YEARS B` |
| "E-102 on car three" | `E 10 ON CAR THREE` — the digit is lost |

Two consequences for how you speak to it:

- **Do not dictate SKUs.** Describe the symptom and let retrieval find the part.
  That is the design: the SKU comes from the manual, not from your voice.
- **Say a fault code digit by digit** — "E one oh two", not "E one hundred and
  two". `spoken_digits.dart` turns `ONE OH TWO` into `102`; it cannot rescue a
  digit the recogniser never emitted. In the run above, "two on" collapsed into
  "on".

**The model has no digit tokens at all.** A raw transcript can never contain a
numeral, so every number you see in a field arrived through normalisation. That is
worth knowing when a number looks wrong: the question is whether the *words* were
heard, not whether the digits were.

---

## Scenarios

Ordered so each builds on the last. 1, 2 and 6 are the ones worth recording.

### 1 · Typed, four fields — the baseline

> Fault code E-102 on car three. Brake pads are worn, I replaced BRK-990-XP.
> Took me an hour and a half, lockout/tagout verified.

**Expect**

- Grounded in *Traction Brake Pad Wear & Vibration (E-102)*
- `record_work_order_fields completed.` on the tool card
- Work order **4 of 4**, every field carrying the agent-origin marker:

| Field | Value |
|---|---|
| Fault code | `E-102` |
| Replacement parts | `BRK-990-XP` |
| Technician hours | `1.5` |
| Safety checkpoints | `lockout/tagout verified` |

`1.5` is the one to look at. Nothing asked the model to convert "an hour and a
half" — the tool schema only says the field exists.

### 2 · The empty shelf

> Doors on car two cycle three times and throw an obstruction warning, and the
> belt squeals when they open. What part do I need and is it in stock?

**Expect**

- Grounded in *Door Clutches & Belt Slippage (E-305)*
- `BELT-330-DRV is carried but out of stock at Aisle 1, Shelf C.`

Read the **prose**, not just the tool card. The thing being tested is whether the
answer says the part is unavailable or quietly invents a quantity. A grounded
tool result contradicted by the sentence next to it is the failure mode this
scenario exists to catch.

This is the strongest demo of the whole app: an assistant with no network that
knows the warehouse shelf is empty.

### 3 · Voice, symptoms only

Tap the microphone and say:

> *The cabin is vibrating badly at the top floor and there's a high-pitched
> squeal when it slows down.*

**Expect**

- A near-verbatim transcript — this is the register the model is good at
- **E-102 retrieved from the symptoms alone**, with no fault code spoken
- `BRK-990-XP` in the answer, which came from the manual rather than from your voice

**Watch the first word.** "The" should be there. A 20M zipformer degrades the
opening of a stream, which cost the first word of every session until the
recogniser was primed with a second of speech at `beginSession`
(`SttConfig.primer`). If a first word goes missing again, that is a regression in
the primer and not in the microphone.

### 4 · Voice, spoken digits

> *Fault code E one oh two on car three, please advise.*

**Expect** `E-102` to reach the fault code field.

Say it **digit by digit**. The raw transcript will contain no numeral anywhere —
watch the inquiry field fill with words and the form field fill with `E-102`, and
that gap is `normalizeSpokenDigits` doing visible work.

### 5 · The technician outranks the agent

1. Dictate scenario 2's symptoms
2. **Before tapping Diagnose**, type `E-305` into the Fault code field yourself
3. Diagnose

**Expect**

- Your `E-305` is **not** overwritten
- If the agent extracts something different, it is parked as a **suggestion**
  beside your value, with the option to take it or keep yours
- Taking it replaces the field; keeping yours drops the offer

This rule is invisible unless provoked, and it is the one the form model is built
around. A related check: start dictating, then type into the inquiry field — the
capture **stops**, because a microphone that stays open while its words stop
arriving reads as broken.

### 6 · One job does not smear into the next

Run scenario 1, then run scenario 2 **without restarting the app**.

**Expect** technician hours and safety checkpoints to be **empty** — not carried
over from the brake job.

A new inquiry drops the agent's fields and keeps anything you typed by hand
(`WorkOrderFormState.forNewInquiry`). Before that existed, a door fault displayed
the brake job's hours under the agent-origin marker, asserting the model had
recorded them for a fault it had never seen. Nothing was invented, which is
exactly what made it convincing.

### 7 · Nothing in the manual

> The coffee machine in the lobby is leaking.

**Expect**

- No procedure, no part number, no invented fault code
- A statement that the offline manual has no entry, and a request for the exact
  code on the controller
- It **may still record what you told it**, and that is deliberate — recording a
  technician's own words is not invention, and the no-match notice was narrowed
  to say so

### 8 · Long answer, scroll release *(1.11 R12-F0 — the one still owed)*

Start a diagnosis that produces a long plan (scenario 1 or 2), and **drag the
answer panel upward while tokens are still arriving**.

**Expect** it to move, and to stay where you put it until the next diagnosis.

Two distinct things, and the first is the one that was broken: the panel was
**unscrollable during generation**, because the auto-scroll's `jumpTo` disposes
the active drag on every token — so a reader trying to look back at step 2 was
simply refused. Found by driving the app by hand, after a device run that could
not exercise it. The fix is bound on the host under both platforms' scroll
physics, but **it has never run on hardware**, which is why this scenario is here
and not in the automated table.

If the drag works but the panel snaps back to the bottom on the next token, that
is the *other* half — auto-scroll failing to release — and worth reporting
separately, because they have different causes.

---

## Covered by automated device tests

Do not re-check these by hand; run the file instead. On a **wirelessly** tethered
iOS device use `flutter run … --publish-port` — `flutter test` cannot launch
there and has no such flag, despite the error message recommending one.

| What | Command |
|---|---|
| Dictated audio → inquiry field, real weights (TC-VOICE-FILL-01) | `flutter run integration_test/voice_inquiry_test.dart -d <device> --publish-port` |
| The clarification overlay under a real finger (TC-UI-CLAR-01) | `flutter run integration_test/clarification_test.dart -d <device> --publish-port` |
| Microphone delivers real PCM (TC-MIC-01) | `integration_test/mic_capture_test.dart` |
| Recogniser loads and streams (TC-STT-INIT-01, TC-STT-STRM-01) | `integration_test/stt_test.dart` |
| Both models coexist (TC-PROV-SET-04) | `integration_test/multi_model_provisioning_test.dart` |

Neither voice file needs `--dart-define`s.

## Known limitation: the agent will not ask a clarifying question

`record_work_order_fields` takes a `clarification` argument for the case where a
value could be one of several specific things, and the work-order panel puts it as
a modal. **Gemma 4 E2B does not use it.**

Two prompts built to force an ambiguity were run on the demo device and both
produced prose instead. The second is the sharper result: given a genuinely
ambiguous door fault it *both* guessed — recording `E-305` and `BELT-330-DRV` —
*and* then asked which part had been fitted, in the answer text. Those are the two
things the argument exists to prevent, in one turn.

So the modal is verified as a **UI** (`integration_test/clarification_test.dart`,
which scripts the question) and unverified as an **interaction**. Trying to
provoke it by hand is not a good use of a device session; if it ever appears
spontaneously, that is worth recording as a finding.

## When something disagrees with this document

Prefer the device. Four defects in this app were found by running it and none of
them were reachable from the host suite — three because a test double was kinder
than the hardware, one because a tool description is not an instruction. A run
that contradicts an expectation here is either a regression or a stale document,
and both are worth chasing.
