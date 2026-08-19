# Hybrid retrieval routing & the grounded prompt

The previous two sections describe two lookup mechanisms; this one is the code
that decides between them. `RetrievalRouter` (`lib/services/rag/`) turns raw
technician text into a set of grounding documents, and `PromptCompiler` turns
those into the string the model actually sees.

## What the router does

1. **Pull fault codes out of the text** and look each one up on the structured,
   indexed `code` column — exact match, never FTS.
2. **Search what is left.** The spans of codes that *resolved* are cut out before
   the text reaches `FtsQuerySanitizer`; the residual is sanitized and matched.
3. **Merge, code hits first, de-duplicated.** A document both legs found appears
   once, in the code leg's position.

Two things about that are worth more than a bullet.

**A code that resolves is cut from the residual; a code that misses is left in
it.** The code pattern is deliberately loose — `E-102`, `E102`, `e 102`, and the
unicode-dash forms a dictation layer can produce — because the alternative is a
technician's `E 102` silently missing the structured column. Loose means false
positives: `Torx T20` reads as a candidate. So a candidate changes nothing until
it has been *verified by lookup*. A miss costs one indexed query returning
`null`, and the words stay searchable — which in that example is what finds the
right entry anyway, since the E-102 procedure names the Torx T20 driver. Cutting
candidates unconditionally would delete real search terms to buy nothing.

**A code-only query has no residual, and an empty `MATCH` is a syntax error**
rather than an empty result. `"E-102"` therefore takes the code leg alone and
never builds an expression. The guard itself lives in
`DatabaseService.searchManualEntriesByTerms` (Task 1.2 put it on the expression
builder for exactly this caller); the router's own branch just avoids the round
trip.

`RetrievalResult` records which leg produced what — `codeHitIds`, `ftsHitIds`,
`resolvedCodes`, `unresolvedCodes`, `searchedTerms` — rather than only the merged
list. That is not diagnostics for its own sake: `entries.length >
codeHitIds.length` looks like a test for "did full text contribute" and is not
one, because when every full-text hit is also a code hit the merged list grows by
nothing. The router shipped with that bug for one commit.

## What the prompt looks like

The layout is the product spec's §5.2 — preamble, `[MANUAL DOCUMENT]` block,
`[USER INQUIRY]` block — and the model is told to answer **only** from the
document block.

```text
You are an offline Field Service Assistant.
Based ONLY on the verified technical manual document below, answer the user's inquiry and formulate a repair plan.
If parts are required, you MUST call the "get_local_parts_inventory(sku)" tool to check warehouse stock.

[MANUAL DOCUMENT]
Title: Door Clutches & Belt Slippage (Code: E-305)
Section: Door Operators
Symptoms: Elevator doors cycle three times and throw obstruction warning, belt squealing during door open sequences, fault code E-305.
Procedure: 1. Switch door operator controller to Manual. …
Required Parts: BELT-330-DRV
Required Tools: Microfiber Cloth, Wrench 10mm, Steel Ruler

[USER INQUIRY]
"door clutch belt slipping, E-305"
```

**An empty retrieval still gets a document block.** When nothing matched, the
`[MANUAL DOCUMENT]` header is followed by an explicit "no entry was found, do not
invent a procedure, a part number, a tool or a fault code, and do not call any
tool". Omitting the block would leave a preamble pointing at a document that is
not there — which is the shape that invites the model to supply the missing
content from its weights, i.e. the exact failure this whole retrieval path
exists to prevent.

**The inquiry is untrusted; the manual text is not.** Manual prose comes from the
bundled asset that `SeedBundle.parse` validated — `upsertManualEntries` is the
trust boundary, and this asymmetry stops being safe the day anything writes
`manual_entries` from a non-asset source. The inquiry is not validated, so a
technician who types (or, in Tier 2, has transcribed) `[MANUAL DOCUMENT]` could
otherwise open a second, fabricated "verified" block inside their own question.
`PromptCompiler.neutralizeMarkers` rewrites **every Unicode opening/closing
punctuation character** (`\p{Ps}` / `\p{Pe}`) in the inquiry to a plain round
bracket, keeping the words so the diagnosis does not lose them.

That rule arrived in two corrections, and both are worth carrying because they
are the same mistake at different depths. The first version matched the marker
spellings case-insensitively, and review broke it with a single extra space
(`[MANUAL  DOCUMENT]`) — then a leading space, a tab and a newline. The second
replaced the pattern with `replaceAll('[', '(')` and justified it by saying a
pattern guard "would still have left the homoglyph variants" — while knowing
exactly one codepoint, so `［MANUAL DOCUMENT］` walked straight through. Review
caught that too, and caught the test that was supposed to cover it using ASCII
brackets around fullwidth *letters*, which exercises nothing new.

Matching on the general categories is what stops that recurring: it is a
property of Unicode rather than a list someone maintained. **The residual is
named rather than papered over**, and it is broader than one example suggests:
bracket pieces and corner brackets (`⎡`, `⌜`), the quotation-class guillemets
(`«` `»`) and plain `<` `>` are all outside `Ps`/`Pe` and all survive, as does a
header written with no delimiter at all. A test pins each of them, plus the
counter-case that keeps the boundary honest — the CJK corner bracket `「` *is*
`Ps` and *is* rewritten, so the list cannot be read as "CJK punctuation
survives".

Those survivors are listed without their general-category names deliberately.
The previous version labelled them, and one label was wrong — U+23A1 is `Sm`,
not `So` — which travelled through this file, a doc comment, a test comment and
a review turn before anyone ran it past `unicodedata`. The rule asks exactly one
question, `Ps`/`Pe` membership, and the test answers it behaviourally; the
category names were decoration that nothing checked.

None of the survivors is a homoglyph of `[`, which is the class that actually
forges these delimiters and is closed. The rest is the general look-alike case
below.

**It is still a block-boundary defence, not a prompt-injection cure** — nothing
here stops a user simply *asking* the model to ignore its instructions, and it
should not be described as if it did.

**Documents are capped** (`maxDocuments`, default 2). Task 1.8 measured a
~400-token grounded prompt for a single entry, and the router can return one row
per resolved code plus its full-text hits. The cap truncates from the end, so the
code hits — which the merge puts first — are the last thing dropped.

---

[← Back to the README](../README.md)
