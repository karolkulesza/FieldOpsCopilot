# Voice input and the work order

Task 2.3 is two features that share a screen, and the sprint plan defines it twice
because of that: its task card is *dynamic form auto-fill*, and the sequencing
section adds *"2.3 owns the mic → STT → inquiry wiring as well as the form fill"*.
Both are here. They meet in one place — the agent's turn — and nowhere else: the
microphone writes the **question**, the tool fills the **form**, and neither ever
writes into the other's field.

## Structured output goes through the tool registry, not through the prose

The spec's §2.3 asks the agent to convert spoken observations into structured JSON.
The obvious implementation is to look for a `{"form_updates": …}` blob in the
answer and parse it out. This ships a tool instead — `record_work_order_fields` —
and the argument is not tidiness:

* **The schema is enforced at generation time.** Task 1.8 established that this
  build's model emits native function-call tokens, and setting tools switches on
  constrained decoding driven by the declared schema. A scraped blob has no such
  constraint; it has a regex.
* **A malformed call is already handled.** Task 1.6's guard recovers a call the
  model spelled as prose, and 1.9's loop feeds every refusal back so the model can
  correct itself. A scraped blob would need a second brace scanner and a second
  recovery path, neither of which anyone would write.
* **It lands in the goldens.** `test/golden/snapshots/form_autofill.json` pins the
  arguments the model sent, the payload it got back and the exact next-turn prompt
  with that payload embedded. A string nobody snapshots pins nothing.

The tool is **pure**. It writes nothing and holds no sink: `WorkOrderFormViewModel`
reads the *payload* and applies it, which is `_CompletedTool._summarise`'s decision
one layer up — **one parse feeds both readers**, so the screen and the model cannot
disagree about what the call meant.

They can still show different *values*, and that is the next section rather than a
hole in this one: a recorded value is not applied over a field the technician holds.
Stated because an earlier version of this paragraph claimed they "cannot disagree
about what was recorded", which the precedence rule below contradicts.

## A refused field is a successful call

`{"fault_code": "E-102", "elevator_colour": "green"}` records one field and refuses
one. Reporting that as a `ToolFailure` would tell the model its whole call was
rejected when most of it landed, so the refusal travels in the payload:

```json
{"recorded": {"fault_code": "E-102"},
 "refused": [{"field": "elevator_colour", "error": "unknown_field",
              "message": "…the fields are fault_code, required_parts, …"}]}
```

The failure codes are reserved for a call that recorded nothing *because it could
not be read at all* — no `form_updates`, or one that is not an object — which
`ToolArguments` already classifies, now including `requiredMap`.

Those refusals reach the screen as a counted line under the work-order header
("The assistant sent 1 value this form has no field for"), not as their messages:
`RejectedFieldUpdate.message` is written *for the model* ("send the value as text"),
which is `_ResultPanel`'s decision about refused tool calls applied to refused
fields. Wiring them there is review finding **R0-F4** — before it the list reached
nothing at all, under a docstring naming a reader that did not exist.

A non-string value is **refused rather than coerced**, quoting
`ToolArguments.requiredString`: `{"technician_hours": 2}` is the model ignoring a
schema that declares a string, and `2.toString()` would hide that behind a field
that looks correctly filled. The alternative — declaring that one field a JSON
`number` — is coherent and was rejected only because it splits four fields into two
type rules. If a device run shows the model fighting the string type, that is the
change to make.

Field names resolve by a **property rather than a list of spellings**, which is
`ToolCallGuard`'s rule reused: two keys match when they are equal after dropping
case and every non-alphanumeric character, so `faultCode`, `Fault Code` and
`fault-code` all reach the same field without anyone having enumerated them. That
is only correct because the four wire names are distinct under that normalisation,
so a test asserts it rather than the docstring claiming it.

## The technician outranks the agent

A field the technician typed is **never** overwritten. The agent's value is parked
on it and offered:

> Fault code: `E-999`
> _The assistant heard "E-102"_  **Use it** · **Keep mine**

Both alternatives are worse in a way that shows up on a recording: overwriting
means a value vanishing under a thumb mid-dictation, and dropping means the agent
silently failing to record what it heard. An agent update that *agrees* with what
is there clears the offer rather than raising one — a badge beside a field that
already says `E-102` is noise that reads as a defect.

Blank means "erase" from the technician and never from the agent, and that
asymmetry is deliberate: a technician who selects a field and deletes it has said
something, and a model emitting `""` for a field it has nothing to say about has
not.

## The clarification is modal, and dismissing it is an outcome

`clarification` rides on the **same call** that records the fields, so it arrives
while tokens are streaming into a panel the technician is watching. An inline card
would be scrolled past — and a question nobody answers is worse than no question,
because the agent's next turn is written as though it had been asked. So it is a
modal, and it is dismissible for exactly that reason.

Two or more distinct options, or it is not a clarification: a question with one
answer is an assertion, and rendering it as a chooser puts a technician in front of
a dialog whose only move is to agree. Unusable entries are dropped and the *count*
is then checked, because a list of three where one arrived as `null` still asks a
coherent question.

One more thing the second tool changed, and it changed a *sentence* rather than
code: `PromptCompiler.noMatchNotice` told the model "do not call any tool", which
meant "do not look up a part you have no SKU for" when there was one tool and
silently became "and do not fill in the work order" when there were two — on the one
path where the technician's own words are the only source of work-order data. It now
names the lookup and permits the recording (review finding **R0-F6**); the grounding
rule is unchanged, because recording a fault code the technician said out loud is
the opposite of inventing one.

**What answering deliberately does not do is resume the agent's run.**
`AgentLoop.run` is a single stream over one inquiry, and feeding an answer back
mid-run would mean a second input channel into a loop whose whole design is "the
conversation is the prompt". The answer fills the field. That is §2.3's interaction
minus the round trip, and it is stated rather than implied.

Two defects were found here rather than reasoned about. `AgentLoop` runs up to four
turns and each may call the tool, so a **second** clarification can arrive while the
first is on screen; a route built around the request it was pushed with rendered the
first question while the state held the second, so a tap would have written the
option the technician read into the field they were not asked about. The route
follows a listenable instead.

The other is review finding **R0-F2**, and it is worse: the host popped the **root
navigator** whenever a presentation was pending, but the route is pushed one
post-frame callback later — so a clarification cleared inside that window popped the
app's *home* route and left a blank screen. Whether a presentation is *pending* and
whether a route is *up* are now separate questions, and clearing inside the window
cancels the presentation instead of popping something else.

## Voice: the microphone writes the question

Tap the microphone beside the inquiry field, speak, tap again. Partials appear as
they are heard and each completed utterance is committed by
`SttTranscript.segment`, so the line grows the way speech does instead of being
rewritten under the reader. Utterances are joined with a single space, because the
recogniser emits none and concatenating raw gives `VIBRATINGTHE` — a word that is
in no manual, reaching the full-text query.

**Dictation appends to what was typed** rather than replacing it: a technician who
typed half the inquiry and then reached for the microphone must not lose the half
they typed. The base is held on the screen rather than in `DictationState`, so the
controller's line stays a pure transcript.

**And typing takes the field.** The inquiry stays editable while the microphone is
open, because a technician watching `FALK CODE` land has to be able to fix it —
which was a claim the code refuted until review finding R0-F1: the screen rebuilds
the whole line from `base + transcript` on every state change, so a correction was
wiped by the next partial, and by the capture merely ending. An edit during a
capture now releases the mirror and *then* stops the capture, in that order —
stopping first flushes a final transcript through a mirror that is still attached,
which loses the edit through the other door. Stopping rather than only releasing is
what keeps the status line honest: a microphone that stays open while its words stop
arriving reads as broken.

**Diagnose is inert while the microphone is open.** The microphone is writing the
inquiry a run would read, and a prompt compiled from a sentence that is still being
spoken is a question nobody asked.

Every refusal is a *state* rather than a throw, on `MicCaptureStart`'s own
reasoning — no verified speech weights, a denied permission, a microphone that will
not open, a model that will not load. Each draws a sentence; none of them
transcribes anything.

## Two things the widget tests had to be built around

* **A widget test's clock is faked, and advancing it is not the same as giving the
  event loop time.** `MicCaptureSession.stop` completes when the plugin's stream
  delivers `done` — real asynchronous work. Measured with a matched control: eight
  `pump(100ms)`s left the stop unresolved and `frames` still open; eight
  `runAsync(20ms)`s resolved both.
* **The stall watchdog is disabled in the widget tests**, and the reason is
  recorded rather than hidden: it is a real `Timer(5s)` armed for the whole of a
  capture, and `flutter_test` fails any test that ends with one pending — which
  Task 2.1's own source predicted in as many words. Its behaviour is bound at
  millisecond scale by `mic_capture_test.dart`, where it is the subject rather than
  a fixture.

The work-order panel also **refuses to virtualise**: a `ListView` does not build
children below the fold, so a field the agent filled would not exist in the tree
until someone scrolled to it — unreachable by a test and by assistive technology.
Four fields is not a list worth virtualising.

## Owed on a device

⚠️ **TC-VOICE-FILL-01 has never run on hardware.**
`integration_test/voice_inquiry_test.dart` is written and needs no defines; it
provisions the 43.65MB STT set first if it is absent.

```bash
flutter test integration_test/voice_inquiry_test.dart -d <device>
```

It substitutes the **microphone** (Task 2.1's `AudioInput` seam) and plays the
committed fixture in real time at `MicCapture`'s own frame size, for the reason
`stt_test.dart` gives: a live microphone makes the assertion depend on the room.
Everything above that seam is real — frame normalisation, the bounded backlog, the
recogniser on its own isolate with real weights, `DictationController`, and the
screen — so what it proves is the **join**, which is the one thing neither TC-MIC-01
nor TC-STT-STRM-01 covers.

⚠️ **The model has never been observed calling `record_work_order_fields`.** Every
test here scripts the call. What the tool's *description* is worth — whether Gemma
4 reaches for it unprompted on a grounded turn — is a property of the weights and
the description together, and only a device run against the real model can say. The
host suite proves that when the call arrives the form fills; it says nothing about
how often it arrives. That is the single most important thing to watch for on the
next device session.

⚠️ **Also unrun on hardware:** dictation with a *live* microphone (TC-MIC-01 covers
the capture, this would cover the whole chain in a real room), and the clarification
modal on a touch screen.

---

[← Back to the README](../README.md)
