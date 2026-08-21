# Targeted mutation testing

A test suite that passes tells you nothing about whether it would fail. This
harness asks the second question: it introduces a specific defect, runs the suites
that should notice, and reports whether they did.

**It is not a mutation generator.** Nothing here mutates operators at random. Every
row is a concrete defect somebody proposed while reviewing this code — *"this guard
looks unnecessary"*, *"that boundary is off by one"*, *"the null check is
belt-and-braces"* — written down as the smallest edit that would introduce it. The
rule the project follows is:

> A fix whose own mutation survives has not been demonstrated, however good the
> argument.

One "fix" in this repository was reverted on exactly that basis. Two guards that
review wanted deleted are still there, because deleting them was proposed, mutated,
and the mutation survived for a reason that turned out to be worth writing down at
the call site instead.

## Running it

```bash
tools/mutation/run.py --list
tools/mutation/run.py --set form_autofill --verify      # seconds, runs no tests
tools/mutation/run.py --set form_autofill               # the real sweep
tools/mutation/run.py --set stt_engine --only M14-cancel-does-not-release-session
```

`--verify` first, always. It checks that every row's `old` text still occurs in the
current tree exactly as many times as the row declares, without running a single
test. Rows are keyed to source text, so a refactor makes them drift; drift makes a
row *abort* rather than mislead, but finding that out in two seconds beats finding
it out forty suite-runs into a sweep. It found real drift the first time it ran —
see `M15` in `sets/form_autofill.py`, which is kept with the story attached.

A sweep needs a clean tree and takes a while: one full run of the set's suites per
row, serially, plus a baseline. **It is deliberately not in CI.** A gate that takes
half an hour and needs a pristine worktree is a gate people learn to route around,
and this is a tool for the moment a claim is being made, not for every push.

## The guards, and why each one exists

The checks in `run.py` are the interesting part of it. Each is here because an
earlier version of this harness reported a number that was wrong in a way the
output could not show — and a harness that measures the wrong thing confidently is
worse than none, because its numbers get quoted.

| Guard | The finding behind it |
|---|---|
| Refuses a dirty baseline | A `git checkout` revert against an uncommitted tree silently produced two results against pre-fix code |
| Asserts a match count on every edit | Two `str.replace` calls shared one assertion, and `dart format` had rewrapped the source the unasserted one was keyed to |
| Refuses duplicate labels and duplicate edits | Two rows were silently the same experiment |
| Confirms the edit changed something | A row that inserted a no-op reported SURVIVED — which reads as "the tests do not cover this" but meant "this edit changes nothing" |
| Re-checks the tree by `st_mtime_ns`, not only `git status` | Both a content hash and `git status` are blind to a mutation the suite repairs by rewriting a file back to its original bytes |
| Parses the `[E]` lines, never the `Failing tests:` block | The reporter truncates that block with `... and N more`, so a harness keyed to it under-reports which tests caught the mutation |
| Unit-checks its own failure-line regex before touching the tree | The claim that it did was true of a terminal session and false of the committed file |

The last one runs before anything is applied, against real reporter lines held in
`PATTERN_MUST_MATCH` and `PATTERN_MUST_REJECT`. An instrument that has not been
checked against a known reading is not an instrument.

## Reading a result

| Outcome | Meaning |
|---|---|
| `KILLED` / `CONFIRMED` | The suite went red **and** the specific test the row predicted is among the failures. The only fully good outcome. |
| `KILLED` / `MISMATCH` | Something failed, but not the predicted test — very often a compile error, which measures the type system rather than the tests. Worth rewriting the row. |
| `SURVIVED` | The suite cannot see the defect. Either a coverage gap, or the mutated code is unreachable by construction — the row's comment is where that gets decided and recorded. |
| `ABORTED` | The row no longer applies to the source. Not a result; a maintenance task. |

The `KILLED / MISMATCH` distinction is not pedantry. Three rows in
`sets/form_autofill.py` were rewritten because the first version killed by failing
to compile, which proves nothing about the assertions. They are annotated in place
with what the compile-error version measured and what the replacement measures
instead.

## Measured, on the commit that published this

Both sets, run start to finish from a clean tree:

| Set | Rows | Killed | Survived | Aborted | Kills confirmed |
|---|---|---|---|---|---|
| `stt_engine` | 40 | 40 | 0 | 0 | 40 / 40 |
| `form_autofill` | 19 | 17 | 2 | 0 | 17 / 17 |

"Kills confirmed" is the column that matters more than the kill count: every one of
the 57 kills failed **the specific test its row predicted**, so not one of them is a
compile error wearing a kill's clothes. No row aborted, which is `--verify` having
already done its job.

The two survivors are the two the set says up front will survive, and each says why
at the row rather than in a summary:

- `M12-a-failed-call-fills-the-form` — `ToolOutcome` is sealed and
  `ToolFailure.payload` has no `recorded` key, so `applyPayload` already answers
  `false` for a failure. The guard the row deletes is unreachable by construction.
  It stays, with that written at the call site.
- `M19-close-always-dismisses` — the row expected a tail check to be load-bearing.
  It is not. The plausible story (a question arriving while the route animates out)
  was written up, implemented behind a `_closing` flag, then **measured and
  reverted**: an instrumented trace showed `showDialog`'s future resolving in the
  same frame as the pop, with nothing pending. There is no window.

A survivor that reproduces is worth more than one that is remembered, which is the
argument for keeping both rows in the set instead of deleting them for being green.

## What is here, and what is not

Two sets, covering the two slices where the question mattered most:

| Set | Rows | Slice |
|---|---|---|
| `stt_engine` | 40 | PCM decoding, spoken-digit folding, recogniser config, the isolate worker protocol, both engine implementations |
| `form_autofill` | 19 | Form state, the recording tool, the two viewmodels that write it, the three widgets that show it |

**The other six slices were mutated too, and those sets are not here.** Their
harnesses were each written for one task and predate this shape — separate
hard-coded worktree paths, per-row suite lists, no `--verify` — and publishing them
as-is would mean publishing six scripts that only ran once, on one machine, against
a tree that has since moved. The survivor counts quoted for those slices elsewhere
in the docs are therefore *reported*, not reproducible from a clone; the individual
mutations are described in the deep dives precisely enough to re-apply by hand,
which is how they were checked in the first place.

Being specific about which numbers a reader can reproduce and which they are taking
on trust seemed better than either dropping the un-reproducible ones or letting the
distinction go unmentioned.
