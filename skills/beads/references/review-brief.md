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

End your report with this frontmatter block, filled in exactly:

```yaml
bead: <bead-id>
verdict: PASS | FAIL | INCOMPLETE
reviewer: { model: <haiku|sonnet|opus|fable>, effort: <level> }
spawn: fresh
prior: <path to the report this one supersedes, on a re-review only>
reason: coverage | reshape | bounds-not-set   # INCOMPLETE only, optional
```

- **PASS** = no BLOCKER and no MAJOR finding.
- **Tier rule**: you must outrank the Bead's `executor.model` on the ladder
  haiku < sonnet < opus < fable (same tier only at fable). The closer refuses a reviewer that does
  not.
- **Re-review**: set `prior` to the report you are superseding; the closer chains the evidence
  through it.
- Write the report to `reviews/<bead-id>-review-<n>.md` under the governing work unit.

The caller runs the closer on your report (`scripts/bead-accept.sh --review <report>`); you never
mutate Bead state.
