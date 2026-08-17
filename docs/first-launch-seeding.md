# First-launch seeding

The manual and the parts inventory ship as one bundled asset
(`assets/elevator_manual_seed.json`) and are written into the encrypted database by
`DatabaseInitializer.ensureSeeded()`. Three decisions are worth naming, because each
one is answering a way this could go quietly wrong.

**The asset's structure is validated before anything is written.** It is a build
input in the same sense as the model's URL and digest — it lives inside the bundle
and nothing at runtime can repair it — so `SeedBundle.parse` rejects anything the
loader could not honestly apply: wrong shapes and types, missing or blank required
fields, out-of-range `stock`, values longer than the column that will store them,
and duplicate or whitespace-padded keys. It does not validate *meaning*: a manual
citing an unstocked SKU parses fine.

The authoritative list is `SeedBundle.parse`'s docstring, deliberately not repeated
here — this paragraph carried its own copy for two commits and was wrong in both,
first by claiming completeness it did not have and then by omitting the three rules
that gave it completeness.

Two of those rules are worth their own line, because the reason is not obvious:

- **Duplicates are an error rather than a silent dedup.** The write is an upsert, so
  a duplicated id would seed one row short of what the asset appears to declare and
  nothing downstream would look wrong. A whitespace-padded `id` is rejected for the
  same reason — `id` is the primary key and, unlike `code`/`sku`, is deliberately not
  canonicalised, so `"m1"` and `"m1 "` would otherwise pass the duplicate check as
  distinct and produce two manual entries nothing could tell apart.
- **Lengths are checked here rather than left to the column.** Drift's `withLength`
  check runs at insert time, which is *inside* the seeding transaction — correct
  behaviour, but too late to be a parse error. (The bounds are duplicated between
  `kSkuMaxLength`/`kPartNameMaxLength` and the `withLength` literals out of necessity:
  `drift_dev` reads those arguments from the source expression and silently drops a
  named constant, emitting no max at all. A test pins the two together.)

**Seeding runs once, not on every launch.** A `seed_markers` row records which
dataset revision was applied. This is not an optimisation — `inventory_parts.stock`
is operational data that the agent reads and that consuming a part decrements, so
re-applying the asset at every start would roll a technician's work back silently.
Bumping the asset's `revision` re-seeds deliberately, overwriting both the manual
text and the stock levels; a real fleet would *sync* inventory rather than seed it,
which is the offline-sync design in the "narrate, don't build" section.

A re-seed is **upsert-shaped, not replace-shaped**, and the difference is worth
knowing before anything relies on it: rows present in the new asset are overwritten,
but a row *dropped* from the asset survives in the database (a removed manual stays
searchable), and a key omitted from a row — `location`, say — is left at its old
value rather than cleared, because drift leaves absent columns out of the
`DO UPDATE SET`. Deleting content therefore needs a migration, not a revision bump.

**The write is one transaction.** Manuals, inventory and the marker commit together
or not at all. A seed that inserted the manuals and then failed on the inventory
would leave a database that looks healthy, holds a marker it has not earned, and is
therefore skipped forever after.

Two smaller details that carry more weight than they look like:

- **Manual rows go through `upsertManualEntries`**, which is `ON CONFLICT DO
  UPDATE` — *not* `INSERT OR REPLACE`. OR REPLACE deletes the conflicting row
  implicitly, and with `recursive_triggers` off (SQLite's default) that delete
  fires no trigger, so on a **re-seed** the replaced row's terms would stay in the
  FTS index permanently. `COUNT(*)` cannot see that; only a search for a term that
  lived solely in the replaced text can.
- **`inventory_parts.sku` is `COLLATE NOCASE`**, and lookups go through
  `normalizeSku` (trim + upper-case). The two are not the same mechanism: the
  normalisation is what makes a model-supplied `" brk-990-xp "` match, and the
  collation is the backstop for a row written past the normaliser by some other
  path. The collation also keeps equality searchable through the primary-key index,
  which an `upper(sku)` comparison in the query would not.

Schema **v3** carries both of those: it creates `seed_markers` and rewrites
`inventory_parts` to attach the collation (SQLite has no `ALTER COLUMN`, so a
collation change is a table rewrite). As in v2, `Migrator.createTable` creates the
table only — anything else has to be created explicitly, or upgraded installs
diverge from fresh ones.

---

[← Back to the README](../README.md)
