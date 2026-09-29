---
wordsmith: { audience: agent, function: reference }
---

# Review-brief fragment (append when a Bead is under acceptance)

Append this fragment, filled in, to any auditor brief when the artifact under review is a Bead
reported `ACCEPTANCE-PENDING review` (contract §5.3–§5.5, design §13). The reviewer is a fresh
spawn, never a fork.

---

This review accepts or rejects Bead `<bead-id>` against its acceptance condition:

> <acceptance condition, quoted>

**Executor model / effort:** `<sonnet|opus|fable>` / `<level|unrecorded>` — the caller states
these; they are the Bead's `metadata.executor.model` and `executor.effort`, the values your tier
must meet (see below). The closer re-checks it
against the live Bead independently; this line lets you check it too before you write a verdict.

Put this frontmatter block at the top of the report, fenced by `---` lines exactly as
`scripts/lib/frontmatter.py` parses (it reads only a leading fence — line 1 must be `---`):

```
---
bead: <bead-id>
verdict: PASS | FAIL | INCOMPLETE
reviewer: { vendor: <claude|codex>, model: <model>, effort: <level> }   # vendor absent = claude; codex needs model and effort
spawn: fresh
prior: null   # an ABSOLUTE path to the report this one supersedes, on a re-review only
reason: coverage | reshape | bounds-not-set   # INCOMPLETE only, optional
---
```

- **PASS** = no BLOCKER and no MAJOR finding.
- **Tier rule**: a Claude reviewer must be one tier above the Bead's `executor.model` on the ladder
  sonnet < opus < fable (same tier only at fable); reviewer effort is not checked. A codex reviewer
  must sit at or above the executor's row in `scripts/lib/verifier-ladder.json` (row from
  `executor.model` and `executor.effort`; unrecorded effort takes the strictest row). The closer
  refuses a reviewer that does not, and any `model@effort` not on that ladder.
- **Codex review**: the dispatcher writes this frontmatter and attests `spawn: fresh`; codex
  writes the audit body.
- **Re-review**: set `prior` to the report you are superseding, as an **absolute path** — the
  closer resolves and records its own `--review <report>` path with `realpath` before writing it
  anywhere, and a later reopen string-compares `prior` against that recorded value.
- Write the report to `reviews/<bead-id>-review-<n>.md` under the governing work unit.

The caller runs the closer on your report (`scripts/bead-accept.sh --review <report>`); you never
mutate Bead state.
