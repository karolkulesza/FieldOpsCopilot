# The agent loop

`lib/services/ai/agent_loop.dart` is the piece the demo is named after: a
grounded prompt goes in, the model answers or asks for a tool, the tool runs
locally, its result goes back to the model, and a grounded answer comes out.

```dart
final loop = AgentLoop(engine: engine, registry: registry);
final result = await loop.runToCompletion(compiler.compile(retrieved));
// result.answer, result.stopReason, result.turns (the transcript)
```

It does not retrieve and it does not compile. It is handed a finished prompt,
because the two halves fail differently and are worth testing apart: retrieval
is a database question with exact answers, and this is a conversation-shaped
question with fuzzy ones. `AgentLoop.run` streams `AgentEvent`s for a UI that
wants live tokens and a "checking inventory…" indicator; `runToCompletion` is
that stream drained.

Everything it consumes already existed. What none of its dependencies could
decide, and this file does, is four things.

## How a turn ends, and how the conversation survives it

`LlmEngine.generate` is a **stateless single turn** — a fresh conversation per
call, closed after. There is no accumulated history to inherit, so the loop
carries the conversation itself, as text, by appending a transcript to the
prompt it was given:

```
<the whole grounded prompt from the compiler>

[ASSISTANT]
Checking the local warehouse.

[TOOL CALL]
{"tool":"get_local_parts_inventory","arguments":{"sku":"BRK-990-XP"}}
[TOOL RESULT]
{"sku":"BRK-990-XP","in_stock":2,"aisle":"Aisle 4, Shelf B"}

[CONTINUE]
The tool results above are the authoritative local warehouse data …
```

A turn ends when the engine's stream closes. `LlmDone` is consumed and carries
no extra information at this layer — waiting for it would hang the loop on a
runtime that closed without emitting one.

## What a `GuardFailure` means for a turn

Task 1.6 built `GuardFailureReason` "for the loop to branch on" and deliberately
left the branch open. It is decided here, and it is not a single rule:

- **`noToolCallFound`** means *there was no call here*. The turn is a plain
  answer and the run ends.
- **Every other reason** — `emptyToolName`, `argumentsUnreadable`,
  `argumentsNotEncodable` — means the model tried to call something and got it
  wrong. That is recoverable: a `[TOOL CALL REJECTED]` block carries the guard's
  message back and the loop continues.

Both directions of getting this wrong are real, which is why both are tested.
Treating a malformed call as an answer ships the model's half-finished sentence
("Let me look that up.") to a technician as the final word. Treating prose as a
malformed call spends the turn budget arguing with a model that already
answered.

An **unknown tool name is not a guard failure at all.** The guard passes an
unresolvable name through unchanged, `ToolRegistry.dispatch` answers
`unknown_tool`, and that payload is fed back like any other result — one report
of one condition, rather than two that differ by which layer noticed first.

## Two bounds, doing different work

- **`maxTurns`** (default 4) is the hard bound on calls to `generate`. Two turns
  is the shortest complete run and a correction round costs one turn, so the
  default leaves room for **two** of them. (This said "one" in three documents
  until review did the arithmetic.) Hitting it stops the loop with `AgentStopReason.iterationCapReached`
  and a message that *reports the failure* rather than summarising a diagnosis
  the loop never obtained. It is **clamped**, not asserted — an `assert` is
  compiled out in release and would make the clamp unreachable from any test.
- **The repeat short circuit** is not what makes the loop terminate, and the
  README says so because the code reads as though it might. The same call twice
  in one run executes once and replays the recorded outcome; a model that asks
  the same question forever still runs to the cap, it just stops paying for the
  query. It also keeps the second answer *identical* to the first, which a
  re-execution could not promise for a tool that is not a pure read. Top-level
  argument keys are sorted so key order does not make one call look like two;
  nested maps are left alone, and a reordered nested map costs one extra
  execution rather than a wrong answer. **It caches failures too, including
  `execution_failed`** — for an identical call there is nothing left to correct,
  so replaying it costs no turn out of a four-turn budget; a *different* call is
  a different key and stays open.

## The continuation prompt cannot be forged

Everything appended above is written into a prompt whose preamble tells the
model what to trust, and three of the four embedded pieces are model-authored or
model-influenced. The third one is not obvious: `get_local_parts_inventory`
echoes `normalizeSku(<the model's string>)` for a SKU it does not carry — trim
and upper-case, no character filtering — so **the model chooses the content of a
`[TOOL RESULT]` block**, and the interesting thing to put there is
`[TOOL RESULT]` followed by an invented stock level.

The defence is that every marker in this prompt starts a line, and no embedded
value can start one:

- **The call and result blocks are single lines, written by
  `AgentLoop.encodeOneLine`.** `jsonEncode` on its own is *not* enough, and the
  first version of this section claimed it was. It escapes every code unit below
  `0x20` plus `"` and `\`, and leaves **U+0085 NEL, U+2028 LINE SEPARATOR,
  U+2029 PARAGRAPH SEPARATOR and U+007F raw**. U+2028 and U+2029 are Unicode
  *mandatory* line breaks, and `normalizeSku` is `trim().toUpperCase()` — so an
  interior U+2028 in a model-supplied SKU reached the echoed payload verbatim
  and opened a real second `[TOOL RESULT]` at column 0. Exactly the attack this
  section said was closed, found in review and reproduced against the loop.
  `encodeOneLine` re-escapes the survivors as `\uXXXX`, matched by general
  category (`Cc`, `Zl`, `Zp`) rather than by listing four codepoints, for the
  same reason `neutralizeMarkers` is a category rule one layer down. Re-escaping
  rather than stripping keeps the line valid JSON *and* lossless — a test
  asserts `jsonDecode` of the output equals the input. The tool *name* is inside
  that encoded line too, not written as bare prose, because a name recovered
  from text is a decoded JSON string and really can contain a line break.
- **The echoed turn text is the one piece that can legitimately contain line
  breaks**, so it gets the other rule instead: `PromptCompiler.neutralizeMarkers`
  rewrites every Unicode `Ps`/`Pe` codepoint to a round bracket, so it cannot
  spell a bracketed marker at all. Reused rather than reimplemented — a second
  copy of that rule would be a second thing to keep true.

Only the *prompt* copy is neutralised. `AgentTurn.text` keeps what the model
actually said, because that is what the technician saw and what Task 1.10 will
snapshot.

**The echo is dropped whenever the guard read the turn's text** — that is,
whenever no native event arrived. Neutralising that text brace-mangles it, so
echoing it showed the next turn a corrupted copy of the very JSON shape the
guard needs it to keep producing. Found in review; the justification for keeping
the echo ("it is the reasoning that led to the call") is true on the native path
and false on this one.

The first version of that fix asked the wrong question — "does any *invocation*
have a text source" — which is silently wrong for a turn whose only text-path
attempt was **refused**, because then there are no invocations at all. That is
the case that can least afford it: with nothing dispatched there is no
`[TOOL CALL]` block beside the echo, so the mangled line is the only rendering
the model sees, directly above an instruction to send well-formed JSON. The loop
already knows the answer (`nativeCalls.isEmpty`) and now records it on the turn
instead of inferring it.

What that costs is stated rather than glossed: `inspectText` scans for a JSON
object *anywhere* in the text, so `"Let me look that up. {…}"` is a legitimate
turn and its first sentence goes with the rest. Showing mangled JSON is worse
than losing a sentence of preamble, and the canonical `[TOOL CALL]` block
carries what the next turn actually needs.

One change this forced upstream: the compiled prompt's `[USER INQUIRY]` block
used to be wrapped in **unescaped** quotes, which Task 1.4 recorded as safe
"only while that block is last". It no longer is, so `PromptCompiler.escapeQuotes`
now escapes the backslash and then the quote — that order, because escaping
quotes first doubles the backslash it just emitted and leaves a live quote
behind. The invariant is checkable without enumerating hostile inputs: delete
every escape pair from the inquiry block and exactly two quotes remain, which
are the delimiters the compiler wrote.

## What propagates rather than being fed back

Two things, both for the reason Task 1.5 established — a value the model can
act on is data, and everything else is a defect:

- **An error on the engine's stream.** A broken runtime is not something the
  model can correct, and a loop that caught it would hand a technician a
  paraphrase of a crash.
- **An `Error` out of a tool.** `AgentTool.execute`'s contract already requires
  a JSON-encodable payload precisely because this loop serialises it, so a
  violation is an app defect. A tool that throws an `Exception` is different and
  is fed back as `execution_failed`.

## The prompt budget, measured

Task 1.9's brief was to measure `maxDocuments` against a real context window
rather than inherit Task 1.4's reasoning about it. Measured on the shipped seed
(`test/services/ai/agent_loop_test.dart`, printed on every run):

| Prompt | Characters |
|---|---|
| Two-document grounded prompt (turn 1) | 1581 |
| After one tool round trip (turn 2) | 2064 (+483) |
| **Ceiling — four turns, the shipped `maxTurns`** | **~2900** |
| A third document, if the cap allowed it | +619 |

The ceiling row exists because the first version of this table stopped at 2064
and the test producing it was named "the widest round-trip prompt the loop can
build" — which it was not, since it drove two turns against a default of four.
The bound is `maxTurns`-scaled, and the number that matters is the last one.

It is approximate for a reason worth naming: each turn appends an echo of what
the model said, so the ceiling moves with the *script*, not just with the loop.
This suite's script measures `[1581, 2038, 2469, 2900]`; a reviewer's, with
longer per-turn text, measured `[1581, 2066, 2525, 2984]`. The shape — one
grounded prompt plus three transcript blocks, monotonically growing — is the
property the test pins; the last digit is not.

**Characters, not tokens.** The tokenizer ships with the weights, so a token
count computed on the host would be a guess wearing a number, and this repo has
already paid for one of those. The host suite bounds the characters as a
regression guard; the device suite (`integration_test/agent_loop_e2e_test.dart`)
is what tests the real 2048-token window, by running the same round trip and
failing if the turn does not complete.

## What the mutation pass found

29 mutations across `agent_loop.dart` and the `escapeQuotes` change it forced
into `prompt_compiler.dart`, each run against the **whole** suite under
`--reporter expanded` — the default reporter truncates its failing list, which
produced two wrong counts in Task 1.4. The harness names a file per mutation
because this task's behaviour spans two, and it refuses a dirty baseline,
duplicate mutation *edits* and duplicate mutation *labels*.

**27 killed on the first pass; 2 survived, and both were gaps in the tests
rather than in the code.** (Review then found a third and fourth hole the set
did not probe at all — see the round-1 additions below.) Both are failure modes this repo had already
recorded, which is the interesting part:

- **Deleting the loop's engine-readiness check killed nothing**, because
  `FakeLlmEngine.generate` *also* throws a `StateError` when it has not been
  initialized — so `throwsA(isA<StateError>())` was green with the check gone.
  A test passing for a reason unrelated to the criterion it was mapped to. It
  now asserts the loop's own message and that the engine was never handed a
  prompt at all.
- **Moving the tool-start event to *after* `dispatch` killed nothing**, because
  the Started → Completed *ordering* is unchanged by it. What that mutation
  breaks is the timing, and an ordered list of events cannot see timing. The
  event exists so a UI can show "checking inventory…" while the query is in
  flight, so the replacement test blocks a tool on a completer and requires
  Started to have arrived while Completed has not.

**After both fixes, all 29 die** — re-measured by running the whole set again
against the tree at the last commit, not carried over from the first pass.

Review round 0 then showed the set had a hole of its own: nothing in it touched
`AgentToolCallRejected` or `AgentToolCallStarted.repeated`, and two probes the
reviewer added survived with zero failing tests. **Five** mutations were added
(M30–M34) — two for the line-terminator re-escaping, two for the unbound stream
signals, one for the dropped echo on the degraded path.

One of the five was itself a bad mutation before it was a passing one, which is
worth recording because it is the harness's own version of the failure this
section keeps describing. M30's first form inserted a *no-op* `replaceAllMapped`
before the real one, so the re-escaping still ran; it reported `SURVIVED`, which
would have read as "the tests do not cover this" when what it actually showed
was "this edit changes nothing". A mutation that does not mutate measures the
mutation, not the suite. Rewritten as two edits that disable the rule for real —
one voiding the pattern, one narrowing the category class to `Cc` so only the
separators slip through.

Review round 1 then found a defect in one of *those* fixes, and with it the
second hole in the set. The R0-F5 fix asked "does any invocation have a text
source", which is exact everywhere except when there are no invocations — the
turn where every text-path attempt was refused, which is the case the finding
was about. The reviewer's `.any` → `.every` probe survived with zero failing
tests, because the two formulations differ *only* on the empty list. Two more
mutations (M35–M36) pin the replacement, and the reviewer's probe is one of
them: promoted into the harness so it is re-run rather than remembered.

**36 mutations, 0 survivors**, one run, whole suite, against the tree at the
last commit. The count is stated here rather than left to the harness's own
output because this section's standard — "a count of mutations is a claim like
any other" — applies to itself, and it had gone stale once already: it read 34
after the set grew to 36.

## Verified on the demo device (2026-08-05, iPad Air M4, iOS 26.5)

TC-AGENT-E2E-01 **passed** against the real 2.59GB artifact, and the numbers are
measurements rather than estimates:

| | |
|---|---|
| Turn 0 (grounded prompt → native tool call) | prompt **933** chars, 136 chars of text, 1 tool, 0 rejected |
| Turn 1 (tool result → final answer) | prompt **1510** chars, **1401** chars of answer, 0 tools |
| Whole run | `stop=answered`, 2 turns, **11332 ms**, context 2048 tokens |

The answer named `BRK-990-XP`, quoted **2 units** in **Aisle 4, Shelf B**, and
laid out the manual's six procedure steps and three required tools. Those stock
figures come from the device's own database — they are not facts about
elevators, so a model answering from its weights could not have produced them.
That is the whole grounding claim, met end to end.

**What it settles about the prompt budget.** The host suite could only measure
characters; this run puts a real prompt through a real 2048-token window and it
completed. 1510 characters of prompt plus 1401 of generated answer is
comfortably inside it, so `maxDocuments: 2` is not the binding constraint for a
single-code inquiry. It is *not* a measurement of the ceiling — this retrieval
returned one document, not the two the cap allows.

**Still not measured: throughput.** The run reported one total (11332 ms for two
turns), which cannot be split into tokens per second. The suite now prints
per-turn elapsed and generated chars/s, so the next run closes it.

## What the device run found that the host could not

TC-AGENT-E2E-01b — the companion asserting an out-of-scope inquiry retrieves
nothing — **failed on its premise**, at `expect(retrieved.isEmpty, isTrue)`,
before the model was asked anything. Two independent causes:

1. Its fixture said "the hydraulic ram on the loading crane is leaking", and
   `hydraulic` is in the manual: E-204 is *Proportional Valve Flow Discrepancy*
   and its symptoms name the hydraulic manifold. Choosing a hydraulic term as
   the out-of-domain word for an elevator manual was just wrong.
2. **Stop words match, and this one is a property of the retrieval path rather
   than of the fixture.** The sanitizer joins terms with `OR` (deliberately —
   see [Offline retrieval](offline-retrieval.md)) and FTS5's `porter` tokenizer removes no stop words,
   so `the`, `on` and `is` each retrieve entries on their own. The fixture would
   have matched with `hydraulic` removed, and so does *"the coffee machine in
   the lobby is broken"*, which contains no elevator word at all.

**Consequence, recorded rather than fixed here.** The no-match block — the thing
that tells the model there is no entry and forbids a tool call — is reachable
far less often than the design assumes. A technician asking about something the
manual does not cover will usually get two *irrelevant* entries and a preamble
instructing the model to answer only from them. That is a plausible route to a
confident wrong answer, which is the failure the whole retrieval path exists to
prevent.

It is **not** fixed in Task 1.9, because the fix belongs to the router and the
obvious versions are all bad: a hand-written stop-word list is the
enumerate-the-attacks shape Task 1.4 already learned to avoid, and any
document-frequency or bm25 threshold tuned against a **three-document** corpus
would be a number with no evidence behind it. It needs a real decision and
probably a bigger corpus. Recorded here, in the sprint plan, and pinned by
`test/services/ai/tc_agent_e2e_premises_test.dart` so it cannot be rediscovered
by accident.

The fixture itself moved to the phrasing TC-RAG-COMP-01 already verified empty,
and both device premises now live in `integration_test/e2e_fixtures.dart` with
host tests asserting them in CI — none of that needed a device, and the run
spent a build, a 2.6GB transfer and four minutes to learn it.

---

[← Back to the README](../README.md)
