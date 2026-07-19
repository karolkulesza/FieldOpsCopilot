# Agent tools: the registry

`lib/services/ai/` is the seam between a model that emits a **structured
tool-call event** — a name plus a JSON-decoded argument map, produced by weights
and therefore untrusted — and a Dart executor with a real signature.

`ToolRegistry` owns both directions, and keeping them on one object is what keeps
them from disagreeing — **so long as a tool's `definition` is stable**:
`registry.definitions` is what goes into `LlmEngine.generate(tools: …)`, and
`registry.dispatch(call)` is what routes the result back. A tool the model was told
about is a tool the registry can execute, because the declaration and the dispatch
key are the *same* string, `definition.name`.

Both hedges were earned in review rather than written up front. This paragraph used
to say the halves were "impossible to disagree, by construction" while the dispatch
key came from a separate overridable getter — precisely how they *could* disagree.
Deleting that getter fixed it; documenting the one hazard left then showed
"impossible" was *still* too strong, because the dispatch map is snapshotted at
construction while the declarations are recomputed per call. Both corrections
are described below.

**The set is validated at construction**, not at the first `generate()`. That is
the rule the inference layer arrived at from the other side: neither consumer of a tool
definition rejects a bad one (see _Tool calling_ in
[docs/on-device-inference.md](on-device-inference.md)), so a malformed schema
surfaces two layers away as "the model is bad at tool calling". `ToolRegistry`
runs the same `assertToolDefinitionsUsable` both `LlmEngine` implementations run,
so a registry that *builds* cannot produce a definition the device rejects.

What is load-bearing there is *what the validator is handed*, not when it runs:
`definitions` is derived from the full tool list, so it still contains both of two
tools sharing a name and the duplicate check can fire. Hand it a name-keyed
collection instead and that pair collapses into one entry, silently disarming the
check. Making that substitution kills exactly one test,
`rejects two tools registered under the same name`, which is the evidence for this
paragraph. (An earlier version cited that evidence by an id from a working
document that does not ship with this repo, so the reader could not follow it;
the test name is the reference that survives.)

The statement *order* in the constructor is **not** load-bearing, and an earlier
version of this section said it was — claiming "a test restores that ordering and
fails" when no such test exists and swapping the two statements leaves all tests
green. Caught in review, and it is this project's most-repeated failure
mode: a claim asserting a regression guard that nothing implements. The mutation
evidence was right; **four** prose descriptions of it were wrong — and the fourth,
found only after the first correction, was the comment on the test the false claim had
named as the guard. The count is stated as four rather than three because the first
correction said three and missed one.

The dispatch key is `definition.name` — the same string the declaration carries.
That is also a correction: `AgentTool` used to expose an overridable `name` getter
defaulting to `definition.name`, and the registry routed on *it*, so a subclass
overriding one getter would be declared under one name and dispatched under
another, permanently `unknown_tool`. Rather than assert the two agree, the second
name was deleted — the registry now reads `definition.name` and nothing else.
Precisely: a subclass can still define a `name` member of its own, but nothing in
the registry consults one, so it cannot affect what is declared or what is
dispatchable. That is narrower than "divergence is impossible", and it is what the
code actually buys. A test pins the invariant directly: every declared name
resolves and dispatches.

## A bad call is data, not an exception

Everything the *model* can get wrong comes back as a `ToolFailure` value with a
JSON payload, never as a throw: a hallucinated tool name, a missing or mistyped
argument, a SKU that does not exist. The agent loop's recovery for all of them is
identical — feed the payload back so the model can correct itself on the next
turn — and a loop that had to catch exceptions here would be one `on Object` away
from swallowing real defects. The database layer had already applied the same reasoning one
layer down: `inventoryPartBySku` returns `null` for an unknown SKU rather than
throwing.

Which is why the `catch` in `dispatch` is `on Exception` and **not** `on Object`.
An `Error` means the *app* is broken, not the call, and reporting it to the model
as `execution_failed` would hand it to something that will paraphrase it to a
technician and try again. The split was measured rather than assumed, and the
measurement corrected a guess:

- `SqliteException` is declared `implements Exception`, so a genuine SQL failure
  is **recoverable** — it becomes `execution_failed` and the loop survives it.
  Covered by a test that provokes a real one from the driver, not a synthetic
  stand-in.
- drift's closed-database guard raises **`StateError`**, an `Error`, so it
  **propagates**. This suite originally asserted the opposite, on the assumption
  that a closed connection was a recoverable condition. drift's own
  classification is the better one: closing the database out from under a running
  agent loop is a lifecycle defect in this app, not something a model can retry
  its way out of.

`ToolFailure.cause` carries the underlying error for logs and tests and is
deliberately **absent from `payload`**. An exception's `toString()` routinely
quotes file paths, SQL and row values, and the payload is prompt text — the
design's device boundary includes the prompt. A test asserts the driver's message, which
names the offending table, does not appear in the encoded payload.

## `get_local_parts_inventory`

The first tool, and the one the canonical demo path calls. It is thin because
the database layer built the query for this call site and put the properties it needs
*inside* it: the SKU is canonicalised on the way in (trim + upper-case, because
from here the argument arrives from the model in whatever casing the weights
emitted), `inventory_parts.sku` is `COLLATE NOCASE` as a backstop for rows
written past the normaliser, and the lookup goes through the primary-key index.

Two payload shapes, and the difference between them is the point:

| Case | Payload |
|---|---|
| Found | `{"sku": "BRK-990-XP", "in_stock": 2, "aisle": "Aisle 4, Shelf B"}` |
| Not carried | `{"sku": "NOPE-000-XX", "found": false}` |

A distinct shape rather than `in_stock: 0`, because "we do not carry this part"
and "we carry it and have none" are different sentences to a technician, and the
model can only tell them apart if the payload does. `BELT-330-DRV` is seeded at
zero stock precisely so a test can hold the two apart. `sku` echoes the **stored**
row rather than the model's spelling, so the next turn quotes the canonical form.
`aisle` is present-and-`null` when a row has no location — an omitted key is
indistinguishable from a tool that does not report locations, and a placeholder
string would be text the database does not contain.

A blank `sku` is a **missing parameter**, not an empty warehouse. That could
plausibly have gone the other way and been one line shorter:
`inventoryPartBySku('  ')` already returns `null`, which would render as a normal
"not carried" answer. It would also be a lie about what happened — nothing was
looked up — and it invites the model to tell a technician a part is unavailable
when it never named one. Absent, `null` and blank all report
`missing_parameter` with distinct messages.

A non-string `sku` is rejected rather than coerced with `toString()`. Coercion is
tempting and wrong: `{"sku": true}` would become a lookup for `TRUE`, which
resolves to nothing and is indistinguishable from a real miss. It is also
unnecessary on the primary path, where Gemma 4's constrained decoding is driven
by this very schema.

**Scope note, because the design was two-minded about this tool's signature.** One
description gives `get_local_parts_inventory(sku_or_name)`, but the only lookup that
exists is exact-SKU. A name search needs a different query (full-text over
`inventory_parts.name`, which is not indexed) and a different answer shape —
several rows, or a disambiguation question. The tool declares
`sku` only — the narrower reading, deliberately. Name search is a
separate tool, not a widened parameter.

---

[← Back to the README](../README.md)
