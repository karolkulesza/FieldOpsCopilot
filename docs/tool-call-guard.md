# The defensive tool-call guard

`ToolCallGuard` is the degraded path into `dispatch`, and it is deliberately
small. Device runs confirmed that Gemma 4 emits **native
function-call tokens**, so the plugin delivers a structured `LlmToolCall` on the
happy path and this guard's original premise - "coerce noisy model output into
valid JSON" - mostly evaporated. Two shapes are left:

| Input | Result |
|---|---|
| A well-formed native event | `GuardedCall` holding the **same instance**, unchanged |
| A native event with an unusable name or unserialisable arguments | `GuardFailure` |
| A call emitted as prose, a fenced block or a JSON blob | `GuardedCall` extracted from the text |
| Anything else | `GuardFailure` - the loop treats the turn as carrying no tool call |

**Why a text path is needed at all, on the plugin's own evidence.** It would be
reasonable to assume the runtime parses a textual tool call if the model emits
one. For the model this app ships, it does not.
`FunctionCallFormatFactory.create` maps `ModelType.gemma4` to
`SdkPassthroughFunctionCallFormat`, whose implementation is **five** overrides
returning constants - `isFunctionCallStart` → `false`, `isDefinitelyText` →
`true`, `isFunctionCallComplete` → `false`, `parse(String)` → **`null`**, and
`parseAll(String)` → **`const []`**
(`flutter_gemma-1.4.1/lib/core/parsing/sdk_passthrough_function_call_format.dart`,
`grep -c '@override'` → 5). Every other model family in that factory gets a real
text parser; Gemma 4 gets none, because it is expected to deliver structured calls
through the SDK instead.

This paragraph originally said "four" and omitted `parseAll` - because the grep
that produced the list was truncated at twenty lines, while the prose claimed the
file had been read. **An enumeration is only as good as the read that
produced it**, and a `head`-limited grep is not a read of the file.

The override that carries the argument is `parse` → `null`, not `parseAll`. A
first correction of this passage called `parseAll` "the sharpest available
statement" because it is what the plugin uses for multi-call text parsing - but
`FunctionCallFormat` supplies a *concrete default* `parseAll` that delegates to
`parse` and returns `[]` when it yields `null`
(`function_call_format.dart:23-27`), so for this class the explicit override is
belt-and-braces rather than the load-bearing line. The ranking arrived
second-hand and was adopted and hardened here without opening the base class - a
trap this project had already recorded once: **a second-hand claim needs measuring
too**, and this instance was caught from the same side that introduced it. Reading
one more file would have settled it.

Either way the conclusion is the plugin's, not this document's: a Gemma 4 turn that
spells a call out in prose reaches the app as plain text that nothing will parse.
That is this guard's entire reason to exist, and it is a stronger argument than the
one this section originally made from first principles.

**Extract-and-parse only.** A string-aware scan finds the *extent* of a JSON
object and `jsonDecode` decides whether it is one. There is no bracket repair, no
quote balancing, no salvaging of truncated JSON: something that does not decode
is not a tool call, which is a cheaper answer than a wrong one. Nothing
enumerates wrapper syntax either - because the scan starts a candidate at every
`{`, a fenced code block, a `<tool_call>` tag, a JSON array and OpenAI's nested
`{"type": "function", "function": {…}}` envelope are all the same input to it.
That last one is why the file no longer contains an explicit envelope-unwrapping
recursion; see below.

## A guard failure is not an unknown tool

The load-bearing distinction. A `GuardFailure` means **"there is no tool call
here"** - never "that tool does not exist". A name the guard cannot resolve is
passed through *unchanged*, so `dispatch` answers `unknown_tool` with the payload
it already has written for the model. Reporting it here as well would give one
condition two different reports depending on which layer noticed first.

That is also why lenient name matching lives here and exact matching lives in the
registry: **one** forgiving place rather than two. A near-miss resolves by exact
equality after dropping case and every non-alphanumeric character - a property,
not a list of spellings - so `GET_LOCAL_PARTS_INVENTORY`,
`getLocalPartsInventory`, `get-local-parts-inventory` and
`functions.get_local_parts_inventory` all reach the declared name. It is
deliberately **not** fuzzy matching: no edit distance, no prefix scoring, because
the cost of guessing wrong is dispatching to the wrong tool, which is worse than
an `unknown_tool` the model can recover from. Two declared names that normalise
alike make the guard refuse to guess rather than pick one.

## Text has to prove it is a call; a native event does not

A native event arrived through the runtime's function-calling path, so it *is* a
call. A JSON object sitting in prose is not, and the rule for promoting one is:
it names a tool this build knows, **or** it is shaped like a call (a name and an
arguments key). Without that rule, `{"name": "Bob", "age": 3}` in an answer
becomes a call to a tool named `Bob` and the loop reports a tool failure for a
sentence. The second half of the disjunction is what keeps the paragraph above
true: `{"tool": "invented_tool", "arguments": {}}` *is* an attempt, so it passes
through under the name the model chose and the registry reports `unknown_tool`.

Absent arguments become `{}`, and unreadable arguments are a failure. This is
the inventory tool's blank-SKU reasoning one layer up: a tool may legitimately take no
arguments, and for one that does not, `{}` reaches the registry as
`missing_parameter` - accurate, because the model named no value. Answering the
same way for arguments that *were* supplied in a shape nothing can read would
describe a call that never happened. Positional arguments are refused for the
same reason: mapping `["BRK-990-XP"]` onto `sku` works only for a
single-parameter tool and silently mis-assigns the moment a tool takes two.

One residual is recorded rather than engineered around: a model that echoes a
tool *declaration* back as text reads as a call whose arguments are the JSON
schema, because a declaration and a call share their key names. The outcome is a
`missing_parameter` - a recoverable turn - and the available discriminators are
exactly the enumerate-the-attack shape this repo learned to avoid.

## Why the encodability check is structural

A native event's arguments are ordinary Dart values; nothing upstream constrains
them. The isolate wire's `decodeEvent` checks that the arguments *are* a `Map`
and never inspects the values, and `FakeLlmEngine` scripts whatever a test hands
it. What breaks is the agent loop putting the attempted call into the next turn:
`jsonEncode` throws `JsonUnsupportedObjectError`, which is an **`Error`** - not
something the loop's `on Exception` recovery catches.

So the guard walks the map with a predicate instead of encoding-and-catching,
because catching that would mean `on Error`, the shape the registry rejected on
purpose. Non-finite doubles are rejected on measurement rather than assumption:
`jsonEncode(double.nan)` throws exactly as a `DateTime` does. The predicate is
deliberately *narrower* than `jsonEncode`, which falls back to calling `toJson()`
on an unknown object - a tool argument that is only serialisable through
someone's `toJson()` is not something a model can have sent.

**Both paths run the probe, and the reason this paragraph used to say otherwise is
worth keeping.** It claimed arguments recovered from text could skip the check
because they came out of `jsonDecode` and were therefore "JSON-encodable by
construction". Decoded does not imply re-encodable: a numeric literal that
overflows a double decodes to `Infinity`, which `jsonEncode` refuses.
`jsonDecode('{"n": 1e400}')` produces one, so
`{"tool": …, "arguments": {"qty": 1e400}}` handed the agent loop precisely the
value whose serialisation throws the uncatchable `Error` the paragraph above is
about - while the native path rejected the identical value. Raised in review.
The lesson generalises past this file: **a claim that some property holds
"by construction" is a claim about a constructor someone has to have read.** The
model-text path is the *more* likely source of an absurd numeric literal, not the
less.

## What mutation testing changed

The suite was green and 27 mutations were run against it, each against the whole
suite under `--reporter expanded` (the default reporter truncates its failing
list, which had already produced two wrong counts elsewhere in this project). That first run was against a
**432**-test suite, not the 433 an earlier draft of this paragraph claimed: the
fix commit below replaced one ordering test with two, so 433 is the count for
every run *after* the fixes, and stating it for the run that found them described
a measurement against a tree that no longer existed. Two mutations survived, and
**neither was a missing test - each was a defect the tests had been shaped
around**:

- **The envelope recursion was dead code.** `_callFromObject` recursed into an
  object found under a name key so the OpenAI envelope would resolve. Deleting
  the recursion killed nothing: the positional scan already offers the inner
  object as its own candidate once the outer one is rejected for carrying no name
  string. The scan had been doing the work the whole time while a test comment
  credited the recursion - a false claim about first-party code, which is this
  project's most-repeated failure mode. Deleted rather than re-documented.
- **Name resolution had the wrong precedence.** Candidates were tried pass-major
  (both spellings exact, then both normalised), which let a *segment's* exact
  match beat the *whole name's* normalised match: with `getparts` and `parts`
  both registered, `get.parts` resolved to `parts` - a different tool than the
  model named. It is now candidate-major.

The second is the more useful one, because the mutation that exposed it deleted
the exact-match pass and *survived*, and chasing why showed the test meant to
bind that pass had been passing on the **ambiguity** rule instead - a test that
passed for a reason unrelated to the criterion it was mapped to, the pattern
this project keeps recording. It is replaced by two tests that bind the
real ordering, each needing a fixture where the two candidate orders disagree.
Adversarial review then ran its own mutations and found more: 38 of them, of
which **14 survived**.

That review raised **twenty-two findings** against this file in all, and even the
total is a lesson: it was restated wrongly three times - once the category *split*
below was recomputed without revisiting the *sum*, and once the count was closed
on an approving pass just before a final one found three more. **A total is a
claim, and a total maintained by hand goes stale every time it is touched** -
including the time you expect to be the last.

Four of the twenty-two came out of the mutations - two from survivors,
one from a survivor of the first batch of fixes, and one from the *kill-list* of a
mutation that died (it killed the test beside the one whose criterion it was). The
rest came from re-reading source and re-measuring claims, which is the cheaper half
of the work and found the most serious defect.

Exactly one was **behavioural** - the encodability hole above, where
shipped code did the wrong thing.

Two were **correct code with nothing holding it there**, the category this project
keeps rediscovering. One: `renamedFrom` was guarded on the native path ten times
over and on the text path not at all. The other is a gap in the encodability fix
itself - the probe
reads the *decoded* arguments, but `object` is also in scope and also a
`Map<String, Object?>`, so swapping the subject compiles, passes everything, and
reopens the hole for arguments delivered as a JSON *string*, whose value is then a
perfectly encodable `String` that nothing looks through.

Eighteen were **claims** - in comments, docstrings and this document - that the
code, the dependency, or the measurement did not support. The
twenty-second is a formatting lapse, kept in its own category rather than rounded
into the claims so the ratio stays honest. Eighteen of twenty-two, against one
behavioural defect: that ratio is the most useful thing this exercise measured about
itself.
The kill-list finding is the one worth reading twice, because it took a second look
to classify correctly
and the correction is the interesting part. `a brace inside a string value does not
truncate the object` used `"A}B{C"`, a **balanced** `}`…`{` pair a plain brace
counter walks straight through, so the test was green with or without the behaviour
it named. That looks like an unbound property - but string-awareness *was* bound,
measurably, by the escaped-quote test beside it: the mutation removing string
tracking killed exactly that one test, before and after the fixture fix. So nothing
was unguarded; what was wrong was a **comment crediting a vacuous test with a guard
it did not provide**, which is the same species as the envelope-recursion comment,
and it belongs here rather than above.

The suite now stands at **438 tests and 33 mutations, 0 survivors**. Six of those
mutations were added to bind the fixes review produced - the text-path encodability
probe, string-mode entry in the brace scan, each alias list's preference order,
text-path `renamedFrom`, and the probe's *subject* - and one more to bind the
resolution-ordering defect caught earlier. They are described rather than cited by
id, because the harness lives outside this repo and an id is a reference a reader
cannot follow.

The corrections in this section are themselves worth keeping, because it exists to
be accurate about measurement and each version of it was not. It claimed "six of
review's mutations survived, four became findings" - the actual record was 13
survivors in the first sweep alone, 7 of which fed 2 findings, so both numbers
were wrong and both had been copied from a summary rather than counted. It said "33
mutations" while two entries were byte-identical edits, i.e. 32 distinct ones; that
slot now holds the probe-subject mutation. **A count of mutations is a claim like any other,
and a list is not a set.**

And then the sharpest one, because it is this section's own prescription failing:
the fix for that duplicate was **claimed before it existed**. This paragraph
asserted that "the harness is checked for duplicate (anchor, replacement) pairs"
when the harness contained no such check - the check had been run once, by hand, in
a throwaway one-liner, and writing it up as a property of the tool was the same
move as calling a truncated grep a read of the file. Review grepped for the check and
found nothing. **A mechanical check is only mechanical once it is in the
tool**; `mutate.py` now refuses to run when two mutations share an `(anchor,
replacement)` pair, and that refusal was verified by re-inserting the duplicate and
watching it fire - because a guard nobody has watched fail is the thing this whole
section is about.

The first version of that guard keyed uniqueness on the mutations' **labels**, so
it caught a duplicate edit under a new label but waved through a whole-row
copy-paste - which is precisely how an unnoticed duplicate arises. It now compares
the edit itself, and both shapes were falsified against throwaway copies before it
was trusted.

The harness also refuses two mutations that share a **label** with different edits,
which is a distinct hazard surfaced in review as a non-blocking note: run-over-run
comparisons key by label, and the results JSON is a list of
`{label: …}`, so such a pair would be run and measured and then collapse into one
the moment anybody diffed two runs - measured and silently dropped. Also falsified
(exit 1, `34 mutations but only 33 distinct labels`).

One process note worth keeping, because it is a lesson this repo had already
written down: the harness reverts with `git checkout`, so it **requires a
committed baseline**. This repo had written that down once already, and this harness hit it anyway -
the first revert destroyed both uncommitted fixes, which had to be re-applied.
It now refuses to run when the file under mutation is dirty.

---

[← Back to the README](../README.md)
