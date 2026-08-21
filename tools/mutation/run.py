#!/usr/bin/env python3
"""Targeted mutation testing for this repository.

Not a mutation *generator*. Every row in `sets/` is a concrete defect somebody
proposed during review — "this guard looks unnecessary", "that boundary is off by
one" — written down as the smallest edit that would introduce it. The harness
applies each one to a clean tree, runs the suites that should notice, and reverts.
A row that survives is a claim the suite does not actually hold.

Usage:

    tools/mutation/run.py --list
    tools/mutation/run.py --set form_autofill --verify     # no tests, seconds
    tools/mutation/run.py --set form_autofill
    tools/mutation/run.py --set stt_engine --only M14-cancel-does-not-release-session

`--verify` is the one to run first, and the one to run after any refactor: it
checks every row's `old` text still matches its declared occurrence count in the
current tree, without running a single test. Source drift makes a row abort rather
than mislead, but finding that out in two seconds beats finding it out forty
suite-runs in.

## The guards, and the finding behind each

Every check below is here because an earlier version of this harness produced a
number that was wrong in a way nobody could see from the output. They are the
interesting part of the file — a harness that reports confidently while measuring
the wrong thing is worse than no harness, because its output gets quoted.

* **Refuses a dirty baseline.** An early harness reverted with `git checkout`
  against an uncommitted tree and silently produced two results against pre-fix
  code. This aborts unless `git status --porcelain` is empty.
* **Asserts a match count on every edit.** Two `str.replace` calls once shared one
  assertion, and `dart format` had rewrapped the source the unasserted one was
  keyed to. Every row states how many times its `old` must occur; a mismatch
  aborts that row instead of running it.
* **Refuses duplicate labels and duplicate edits**, so two rows cannot silently be
  the same experiment.
* **Confirms the edit changed something** before believing a survivor. A row that
  inserted a no-op once reported SURVIVED, which reads as "the tests do not cover
  this" when it meant "this edit changes nothing".
* **Checks the tree after every row by `st_mtime_ns` as well as by `git status`.**
  Both a content hash and `git status` are blind to a mutation the suite repairs by
  rewriting a file back to its original bytes.
* **Reads the `[E]` lines, never the `Failing tests:` summary block**, which the
  reporter truncates with "... and N more" — so a harness keyed to the summary
  under-reports which tests caught a mutation.
* **Unit-checks its own failure-line pattern before touching the tree.** The claim
  that it did was once true of a terminal session and false of the committed file.
  [PATTERN_MUST_MATCH] and [PATTERN_MUST_REJECT] below are that check, and they run
  first, every time.

## What a result means

`KILLED` with `CONFIRMED` is the only fully good outcome: the suite went red *and*
the specific test named in the row's `expect` is among the failures. `KILLED` with
`MISMATCH` means something failed but not the test that was supposed to — often a
compile error, which measures the type system rather than the tests. `SURVIVED`
means the mutation is invisible to the suite; sometimes that is a coverage gap and
sometimes the mutated code is unreachable by construction, and the row's comment
is where that distinction gets recorded.
"""

import argparse
import importlib.util
import json
import os
import pathlib
import re
import subprocess
import sys

SETS_DIR = pathlib.Path(__file__).resolve().parent / "sets"


def repo_root() -> str:
    """The worktree this script lives in.

    Resolved rather than configured: an earlier harness hard-coded an absolute
    path to a per-task worktree, which is both unrunnable for anyone else and a
    silent hazard if the constant outlives the directory.
    """
    proc = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        cwd=pathlib.Path(__file__).resolve().parent,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        raise SystemExit("ABORT: not inside a git worktree")
    return proc.stdout.strip()


WT = repo_root()


def load_set(name: str):
    path = SETS_DIR / f"{name}.py"
    if not path.exists():
        raise SystemExit(
            f"ABORT: no mutation set {name!r}. Available: "
            + ", ".join(sorted(p.stem for p in SETS_DIR.glob("*.py")))
        )
    spec = importlib.util.spec_from_file_location(f"mutation_set_{name}", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def sh(cmd, **kw):
    return subprocess.run(
        cmd, shell=True, cwd=WT, capture_output=True, text=True, **kw
    )


def tree_state():
    """(porcelain, {path: mtime_ns}) for every tracked .dart file and pubspec."""
    listing = sh("git ls-files '*.dart' pubspec.yaml").stdout.split()
    stamps = {}
    for rel in listing:
        try:
            stamps[rel] = os.stat(os.path.join(WT, rel)).st_mtime_ns
        except FileNotFoundError:
            stamps[rel] = None
    return sh("git status --porcelain").stdout, stamps


def run_suites(suites):
    proc = sh(
        "flutter test " + " ".join(suites) + " --reporter expanded --concurrency=1"
    )
    return proc.returncode, proc.stdout + proc.stderr


FAILED_TEST = re.compile(
    r"^\d+:\d+\s+\+\d+(?:\s+~\d+)?(?:\s+-\d+)?:\s+(.+?)\s+\[E\]$"
)

# Real reporter lines, and the name each must yield. Not illustrative — asserted.
PATTERN_MUST_MATCH = {
    "00:03 +44 -1: TC-VM-FORM-01: auto-fill a call the tool refuses fills nothing [E]":
        "TC-VM-FORM-01: auto-fill a call the tool refuses fills nothing",
    "00:12 +120 ~5 -1: parseClarification fewer than two usable options is refused [E]":
        "parseClarification fewer than two usable options is refused",
    "00:01 +9 ~5 -2: ClarificationHost a second question retargets the one overlay [E]":
        "ClarificationHost a second question retargets the one overlay",
}

# Lines that must NOT be read as failures. The last two are summary-block lines:
# the block they come from is truncated, which is why it is never parsed.
PATTERN_MUST_REJECT = [
    "00:24 +973 ~5: All tests passed!",
    "00:07 +276 ~5: some test that merely passed",
    "  /repo/test/foo_test.dart: a name from the truncated summary block",
    "  ... and 14 more",
]


def check_failure_pattern():
    """Aborts if [FAILED_TEST] cannot parse real reporter output."""
    for line, expected in PATTERN_MUST_MATCH.items():
        match = FAILED_TEST.match(line.strip())
        if match is None or match.group(1) != expected:
            raise SystemExit(
                f"ABORT: failure-line pattern rejected a real failure line, or "
                f"captured the wrong name:\n  {line!r}\n  got "
                f"{match and match.group(1)!r}"
            )
    for line in PATTERN_MUST_REJECT:
        if FAILED_TEST.match(line.strip()) is not None:
            raise SystemExit(
                f"ABORT: failure-line pattern matched a line that is not a "
                f"failure:\n  {line!r}"
            )


def failing_test_names(out):
    names = []
    for line in out.splitlines():
        match = FAILED_TEST.match(line.strip())
        if match and match.group(1) not in names:
            names.append(match.group(1))
    return names


def check_rows(mutations):
    """Structural checks over the set itself, before anything is applied."""
    problems = []
    labels = [m["label"] for m in mutations]
    duplicates = {label for label in labels if labels.count(label) > 1}
    if duplicates:
        problems.append(f"duplicate labels: {sorted(duplicates)}")
    edits = [(m["file"], m["old"], m["new"]) for m in mutations]
    if len(set(edits)) != len(edits):
        problems.append("two rows apply the same edit")
    return problems


def verify(mutations):
    """Match-count check for every row, without running any test."""
    bad = []
    for m in mutations:
        path = os.path.join(WT, m["file"])
        try:
            source = open(path).read()
        except FileNotFoundError:
            bad.append(f"{m['label']}: {m['file']} does not exist")
            continue
        found = source.count(m["old"])
        if found != m["count"]:
            bad.append(
                f"{m['label']}: {m['file']} matched {found}, expected {m['count']}"
            )
        elif source.replace(m["old"], m["new"]) == source:
            bad.append(f"{m['label']}: edit changes nothing")
    return bad


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--set", dest="name", help="a module name under sets/")
    parser.add_argument(
        "--list", action="store_true", help="list the available sets and exit"
    )
    parser.add_argument(
        "--verify",
        action="store_true",
        help="check every row still matches the tree, run no tests",
    )
    parser.add_argument("--only", help="run just the row with this label")
    parser.add_argument("--json", dest="json_out", help="write results here")
    args = parser.parse_args()

    if args.list:
        for path in sorted(SETS_DIR.glob("*.py")):
            module = load_set(path.stem)
            summary = (module.__doc__ or "").strip().split("\n")[0]
            print(f"{path.stem:16} {len(module.MUTATIONS):3} rows  {summary}")
        return 0

    if not args.name:
        parser.error("--set is required (or --list)")

    module = load_set(args.name)
    mutations = module.MUTATIONS
    suites = module.SUITES

    problems = check_rows(mutations)
    if problems:
        print("ABORT: " + "; ".join(problems))
        return 1

    if args.only:
        mutations = [m for m in mutations if m["label"] == args.only]
        if not mutations:
            print(f"ABORT: no row labelled {args.only!r}")
            return 1

    if args.verify:
        bad = verify(mutations)
        for line in bad:
            print(f"  DRIFTED {line}")
        print(
            f"\n{len(mutations) - len(bad)}/{len(mutations)} rows match the tree"
            + (" — every row is applicable" if not bad else "")
        )
        return 1 if bad else 0

    check_failure_pattern()

    porcelain, _ = tree_state()
    if porcelain.strip():
        print("ABORT: dirty baseline\n" + porcelain)
        return 1

    baseline_rc, baseline_out = run_suites(suites)
    if baseline_rc != 0:
        print("ABORT: baseline suite is not green")
        print(baseline_out[-3000:])
        return 1
    _, baseline_stamps = tree_state()
    print(f"baseline green: {baseline_out.strip().splitlines()[-1]}")

    results = []
    for m in mutations:
        path = os.path.join(WT, m["file"])
        original = open(path).read()
        occurrences = original.count(m["old"])
        if occurrences != m["count"]:
            results.append(
                dict(
                    label=m["label"],
                    outcome="ABORTED_MATCH_COUNT",
                    found=occurrences,
                    expected=m["count"],
                )
            )
            print(
                f"{m['label']}: ABORTED — matched {occurrences}, "
                f"expected {m['count']}"
            )
            continue

        mutated = original.replace(m["old"], m["new"])
        if mutated == original:
            results.append(dict(label=m["label"], outcome="ABORTED_NO_OP"))
            print(f"{m['label']}: ABORTED — edit changed nothing")
            continue

        open(path, "w").write(mutated)
        try:
            rc, out = run_suites(suites)
        finally:
            sh("git checkout -- .")

        outcome = "KILLED" if rc != 0 else "SURVIVED"
        confirmed_by = []
        failing = failing_test_names(out)
        quoted = re.findall(r"'([^']{8,})'", m["expect"]) + re.findall(
            r"`([^`]{8,})`", m["expect"]
        )
        if outcome != "KILLED":
            expect_check = "n/a"
        elif not quoted:
            expect_check = "UNCHECKED (expect names no quoted test)"
        else:
            hits = {q: [f for f in failing if q in f] for q in quoted}
            missing = [q for q, f in hits.items() if not f]
            expect_check = (
                f"MISMATCH (not in the failures: {missing})"
                if missing
                else "CONFIRMED"
            )
            confirmed_by = sorted({f for found in hits.values() for f in found})
        results.append(
            dict(
                label=m["label"],
                outcome=outcome,
                expect=m["expect"],
                expect_check=expect_check,
                confirmed_by=confirmed_by if outcome == "KILLED" and quoted else [],
                failing=failing,
            )
        )
        print(f"{m['label']}: {outcome} [{expect_check}]")

        porcelain_now, stamps_now = tree_state()
        if porcelain_now.strip():
            print("ABORT: tree dirty after revert\n" + porcelain_now)
            return 1
        collateral = [
            p
            for p, t in stamps_now.items()
            if baseline_stamps.get(p) != t and p != m["file"]
        ]
        if collateral:
            print(f"  note: mtime changed on {collateral}")
            baseline_stamps = stamps_now

    killed = sum(1 for r in results if r["outcome"] == "KILLED")
    survived = [r for r in results if r["outcome"] == "SURVIVED"]
    aborted = [r for r in results if r["outcome"].startswith("ABORTED")]
    print(
        f"\n{killed} killed / {len(survived)} survived / {len(aborted)} aborted "
        f"of {len(mutations)}"
    )
    for r in survived:
        print(f"  SURVIVED {r['label']} — expected: {r['expect']}")
    for r in aborted:
        print(f"  ABORTED  {r['label']} ({r['outcome']})")

    if args.json_out:
        json.dump(results, open(args.json_out, "w"), indent=1)
        print(f"\nwrote {args.json_out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
