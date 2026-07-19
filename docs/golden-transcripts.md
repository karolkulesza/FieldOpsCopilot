# Golden transcripts

Seven scripted agent runs, each snapshotted whole into
`test/golden/snapshots/<scenario>.json` and compared byte-for-byte on every CI
run. The suite lives in `test/golden/` and splits three ways: the scenarios
(`llm_golden_test.dart`), the serializer (`transcript_snapshot.dart`) and the
comparator (`golden_file.dart`).

Only the **model** is faked. Retrieval, prompt compilation, the loop, the guard,
the registry and the database are the real ones, over the real seeded asset — so
a golden is a statement about the whole vertical slice rather than about one
class.

## What a golden buys that a property test does not

The per-layer suites assert *properties*: this prompt contains that marker, that payload
reached the next turn. A golden asserts the **whole artefact**, which is the only
assertion that notices a change nobody thought to write a property about — a
reworded preamble, a reordered document field, an extra blank line between
transcript blocks, a fault code that stopped resolving, a tool payload that
gained a key. Every one of those changes the string a 2.6GB model is asked to
reason about, and none of them fails a single other test in this repo.

## The seven scenarios

| Scenario | What it pins |
|---|---|
| `e102_native_tool_call` | The canonical happy path: code resolved structurally, one document compiled, a native tool call, the real stock figure in the second prompt. |
| `e305_degraded_text_call` | The guard's text path, a name the model misspelled and the guard canonicalised, a zero-stock payload, and `escapeQuotes` over a hostile inquiry. |
| `no_manual_match` | Retrieval empty → the no-match notice → no tool called. |
| `iteration_cap` | Four turns with a *different* SKU each time, so the cap is what stops it rather than the repeat short circuit. |
| `recovery_ladder` | A guard refusal, then a `missing_parameter` from the registry, then a good call, then the answer — exactly `maxTurns` turns *and* an answer. Holds the suite's widest prompt at 2363 characters — effectively tied with `iteration_cap`'s 2347. |
| `unknown_tool_repeated` | An unresolvable name reaching `dispatch` as `unknown_tool` (not a guard failure), then the same call replayed rather than re-executed. |
| `form_autofill` | The work-order path: the work order recorded, one field refused *beside* the recorded ones, a clarification asked on the same call, and the payload carried back into turn 2's prompt. |

**The registry here is the production pair, not a subset** — it is what builds the
loop's `ToolCallGuard`, so the set of known names is part of what these files pin.
Adding the second tool was not inert, and the diff is the evidence: the
`unknown_tool` payload quotes the registry's own `available tools:` list, so
`unknown_tool_repeated` moved by exactly the new tool's name.

## Why the snapshots look the way they do

Four rules, each a decision rather than a formatting preference:

1. **Multi-line strings are stored as arrays of lines.** A one-document grounded
   prompt is 933 characters over 14 lines, and the widest prompt in the suite is
   2363; as one JSON string a one-word change to the preamble produces a diff
   nobody can read. Splitting on `\n` is lossless and makes the diff
   line-precise.
2. **The files are 7-bit ASCII.** `jsonEncode` passes U+0085, U+2028, U+2029 and
   U+007F through raw, and two of those are Unicode *mandatory* line breaks — so
   a golden could otherwise hold a character that editors and diff tools treat as
   a newline while the harness's own line count does not. They are re-escaped as
   `\uXXXX`, which keeps the file valid JSON and lossless (asserted, not argued).
3. **Nothing environmental is recorded** — no timestamps, no temp paths, no
   durations. `ToolFailure.cause` is deliberately absent: it quotes the database
   file path, which is a fresh temp directory every run.
4. **`Set`-typed retrieval hits are sorted.** They iterate in insertion order
   today, but that is a property of `LinkedHashSet` rather than of the type.

## Regenerating

```bash
UPDATE_GOLDENS=1 flutter test test/golden
```

Two properties of that flag matter more than the convenience. A rewrite that
**changes** a file still fails the test, so one `flutter test` invocation with the
flag set by accident cannot turn a real regression green — it can only be green
when the flag changed nothing. (Stated at that width deliberately: *two*
invocations in one job would be green, because the first rewrites and fails and
the second matches. Worth not over-claiming rather than engineering around.) And
the diff is printed in the rewrite report too: a regenerated golden nobody read is
the same problem as a golden nobody wrote.

## What mutation testing changed

**47 mutations, 0 survivors** — 25 against the serializer, 17 against the
comparator, and 5 against the committed snapshots themselves. That last group is
the most direct evidence this suite can produce, and it exists because the suite ships
no `lib/` code: its production artefacts are the harness *and the goldens*, so
tampering with a golden's stock figure, its turn count, a line of its grounded
prompt, its rejection reason or its trailing newline is a mutation like any other.
Every one of the five failed a test (3, 4, 4, 1 and 4 tests respectively). A
golden that can be edited with the suite still green is decoration.

Every row failed at least one test; the widest is `reconcileGolden` always
returning `match`, at 13. Exactly one row — the mutation that makes the golden
write fire on any mismatch — causes a write to a file it did not edit, and the
harness detects that by mtime, which sees it whether or not the write persists.

Per-row counts are a reading of one run rather than an invariant: a
provisioning test flakes occasionally under `--concurrency=8`, so a row can carry
±1 unrelated failure. **And the exposure runs the opposite way from the obvious
guess.** A survivor is not "a row with no failures" — it is
a row whose suite **exit code was 0**. A flake only ever *adds* a failure, so it
cannot rescue a killed row; what it can do is **mask a survivor**, by making a
mutation with no genuine failures exit non-zero and be reported `KILLED`. So the
0-survivor result does depend on the flake not landing on a would-be survivor,
which is the only direction in which this noise can change a conclusion rather than
a number. The harness now names the known-flaky tests and reports a row whose
failing set is a *subset* of them as `INCONCLUSIVE` rather than as a kill, so the
case is detected instead of assumed away.

Two more rows are refused the same way, on the same principle — a kill is a failure
the mutation *caused*, so a row with nothing attributable to point at is not one. A
non-zero exit that names no test at all is `INCONCLUSIVE`. And a mutation that does
not **compile** is `COMPILE_ERROR`.

That last case is worth describing accurately, because two earlier attempts at it
here were wrong in the same direction. Measured, by breaking
`transcript_snapshot.dart` and running the harness's own command: **499 of the 554
tests execute and pass.** What fails is the *loading* of the files that import the
mutated library — `llm_golden_test.dart` and `golden_harness_test.dart` — which
loses exactly their 55 tests, and 554 − 55 = 499. So it is not "no test runs"; it is
that **the tests which could have judged this mutation are precisely the ones that
never ran**, while the rest of the suite carries on passing. The reporter's
`loading <path>` lines are then captured by the harness's parser as though they were
failing tests, so the row arrives with a non-zero exit and a failing set containing
nothing the mutation's behaviour caused — and before this was fixed it was recorded
as `KILLED`: a row about which **nothing was learned**, filed as a kill, with several
pieces of apparent evidence. At worst that hides a mutation that would have
*survived*; some non-compiling mutations would have been killed and were filed
correctly by accident. Which of the two it was is exactly what cannot be known, since
the tests that would have decided it are the ones that did not run.

Nor is the captured set an enumeration of what broke: **3** `loading` names were
captured against **2** actual `Failed to load` failures, the extra one an unrelated
suite file — a reporter artefact rather than a list.

The bug was unreachable-by-accident rather than by design — the old detector wanted
two substrings on one line that the runner prints on separate lines. It
changes none of the numbers above, since no row in any completed sweep has a
`loading` entry, but it was live for the next mutation anyone wrote.

**The first version of these numbers came from a harness that could corrupt its
own inputs, and that is the most useful thing this task learned.** It reverted the
file it had *edited*, not the surface a mutation can *damage* — and one mutation
makes the suite overwrite a committed golden.

What that cost depends on a race, which is the point. Under `--concurrency=8` the
corrupting test and the scenario test that reads the same golden run in either
order, and the mutated write fires on any mismatch — so the scenario test *repairs*
the golden as a side effect if it runs second. Two runs of the identical harness
landed on opposite sides: one self-healed and reported a clean 44/44 (only the
corrupting row itself saw a dirty tree), and one did not, so nine later rows
carried collateral failures and the last five never ran at all. **A harness that
can silently repair its own damage is worse than one that crashes, because only the
crash tells you.**

The fix is mechanical, not attentional: revert the whole surface, assert the whole
surface is clean before each row, and detect per-row collateral **by mtime** rather
than by `git status` or a content hash — neither of which can see a
damage-then-repair pair, since the repair restores the original bytes. That last
part is itself a corrected claim: the first version checked `git status` after the
run and therefore reported nothing on the run that self-healed.

Four properties had **correct code and nothing holding it there** — three found
while designing the mutation set, and one the review found afterwards:

* **The `Set` sort.** No scenario retrieves two hits whose insertion order
  differs from sorted order, so removing the sort left every test green. It is
  now bound by a test that builds the disagreeing case by hand — which is why
  `sortedHits` is public rather than private.
* **`verifyGolden`'s `fail()`.** TC-GOLD-02 deliberately goes through
  `reconcileGolden` (it needs a *value*, since a test cannot assert that a
  failure was readable if the failure aborts it), which left the abort itself
  unbound: deleting it made all six scenario tests pass unconditionally.
* **The update-flag predicate.** Inline, it could only ever be exercised with
  whatever the ambient environment held, so widening it to `value != null` stayed
  green in a normal run. Extracted as `updateRequested(String?)` and tested
  against eight spellings.
* **The golden write itself** (found in review). `verifyGolden` baked in both the
  `File` and the environment read, and Dart cannot change the process environment
  in-process — so under `flutter test` the rewrite branch never executed at all,
  and deleting both of its statements left the whole suite green. The test that
  *claimed* to bind it wrote the file itself and never called the function. Now
  `applyGolden(file:, update:)` takes both as parameters and three tests exercise
  it in a scratch directory. Same defect class as the prompt compiler's `assert`ed clamp, one
  layer further out: the code that checks the code is code.

The pattern is the one this repo keeps recording: the lines a golden suite cannot
check are exactly the lines *of the golden suite*, and they need ordinary tests
like anything else.

## What this suite cannot do

* **It cannot notice a field the serializer never recorded.** Deleting a key from
  the serializer breaks a golden — the committed files *are* the regression guard
  for its completeness — but adding a field to `AgentTurn` and forgetting to
  serialise it is invisible. Flutter has no mirrors, so there is no mechanical
  guard; the mitigation is that `transcript_snapshot.dart` lists what it
  deliberately leaves out.

  **That guard is not uniform, either.** It is total for the top-level and
  per-turn keys, which every golden has; below them it thins out with coverage.
  Invocations per golden are 1, 1, 4, 0, 2, 2, so the invocation and outcome keys
  are guarded by five of six. Rejections are 0, 0, 0, 0, 1, 0 — so the two keys
  under `_rejection` are guarded by `recovery_ladder` **alone**. That is the thin
  spot, and naming it is better than averaging it away.
* **It cannot tell a good transcript from a bad one.** A golden says "this is what
  the code does", never "this is what the code should do" — which is why each
  scenario carries semantic assertions beside the byte comparison. Without them a
  serializer that emitted `{}` would keep every one of them green forever.
* **It is not a model evaluation, and it is not a device test.** The run is
  deterministic only because `FakeLlmEngine` is; a golden over the device engine
  would be a flake generator.

---

[← Back to the README](../README.md)
