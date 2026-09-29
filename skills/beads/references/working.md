---
wordsmith: { audience: agent, function: reference }
---

# Working a Bead — the thirteen rules

Contract part 1 §9 and §13 as amended
(`$SEAT_ROOT/PerAnkh/projects/permaat/workunits/2026-09-17-beads-state-sovereignty/01-estate-beads-contract.md`).
They bind every session that touches a Bead. The `PreToolUse(Bash)` guard
(`scripts/eb-guard.py`) enforces several of them mechanically — where it does, the rule below states
only what survives as judgment; the guard's own deny message carries the rest.

## Rules

1. **Find work.** `bd ready` filtered to your project or your assignment. Work you were handed beats
   self-selection.
2. **Claim before you start.** Run `scripts/bead-claim.sh --id <id> [--model <sonnet|opus|fable>]`
   and branch on its one word: `CLAIMED` → proceed; `LOST` → pick other work. Never work an unclaimed
   or other-claimed Bead. A Bead whose `tier:` is above your own is not yours to claim. Pass `--model`
   when the session model cannot be auto-detected — the script refuses the claim without it, because
   the acceptance closer needs `executor.model` to evaluate the reviewer tier rule (rule 9).
3. **A claim is not permission.** Before acting, check capability, authority, capacity, resources,
   safety, responsibility, and that the governing artifacts exist. Any fail: release the claim with a
   note, or escalate (rule 8). This seam is judgment, every time; nothing mechanises it.
4. **Respect blocking edges.** Do not start blocked work. Do not add edges to mirror document
   lineage.
5. **Keep substance in artifacts, with one exception.** Specs, plans, findings, evidence and
   reasoning live in repositories and work-unit directories; the Bead gets references and short
   notes. The exception is exactly one three-line progress block plus the work-unit pointer in
   `notes`. Write it with `scripts/bead-progress.sh --id <id> --completed … --in-progress … --next …`,
   which rewrites in place at every checkpoint — one current block, never a history. When the next
   step does not fit `NEXT:`, pass `--design-file <path>` and have `NEXT:` summarise it. Progress
   narrative, per-item state tables, findings and decisions beyond those four lines stay forbidden.
   The `notes` size cap you'd hit going around the script is the shell's, not `bd`'s — 120 KiB stored
   fine, 130 KiB failed with rc=126, the shell's `E2BIG` on `--notes "$(cat file)"`. There is no
   bd-side cap to raise and no file flag for `notes`; `bead-progress.sh`'s four-line block keeps you
   out of reach of it.
6. **Create new Beads rarely.** A child or blocking Bead only for work *necessary* to yours that
   passes T1–T5 (`references/authoring.md`), citing your Bead as `recognized-by` and linked
   `discovered-from`. Useful but unnecessary → proposal intake. Steps of your own work are never
   Beads. Recognized work that is wanted but not funded now is deferred with one stated trigger
   under `## Trigger` (contract §1.2), never lapsed.
7. **Hand off on the Bead and in the work-unit.** See the carrier table and resume order below. A
   claim never outlives its session: release it yourself with
   `scripts/bead-release.sh --id <id> --note "<why>"` unless the same actor resumes, and the
   SessionEnd hook releases anything you leave claimed when the session ends anyway.
8. **Escalate instead of inferring.** For a missing authority or capability, or a needed ruling:
   write an ADR-016 packet, create a decision Bead that blocks yours, move to other work. Address the
   nearest receiver admitted to decide — your orchestrator, or the relevant Responsibility holder;
   the operator only for an operator-reserved class or when no other receiver is admitted.
9. **Report success; do not self-close.** Run
   `scripts/bead-report-success.sh --id <id> --evidence "<what you checked, where the artifacts are>"`.
   It adds the evidence line and the `acceptance-pending` label, then branches on the Bead's `accept:`
   label — it is the authority closing, never you:

   - `accept:evidence` → closes now, prints `CLOSED`.
   - `accept:operator` → prints `ACCEPTANCE-PENDING operator` and stops. On the operator's
     say-so in chat (design §11.6), the agent — in that later session, since the ruling always
     arrives after this one ends — runs
     `scripts/bead-accept.sh --id <id> --evidence '<the operator's message, cited>' --operator`,
     which prints `CLOSED`. This is the SAME `--id --evidence` form `accept:evidence` uses, plus
     the required `--operator` flag (the form refuses an `accept:operator` Bead without it, and
     never accepts `--operator` for `accept:independent` — that mode always requires
     `--review <report>`); the evidence cited is the operator's own words, not a file.
   - `accept:independent` → prints `ACCEPTANCE-PENDING review`. Spawn a fresh auditor one tier above
     your `executor.model` (same tier only when you are `fable`, the top of the ladder; never a
     fork — a forked reviewer shares the very context the review exists to check), with
     `references/review-brief.md` appended to its brief. An orchestrator does the same for the
     units it delegated. Take the report it returns and run `scripts/bead-accept.sh --review
     <report>`, then branch on its line:
     - `CLOSED` — accepted; you are done.
     - `FAILED <cycles-left>` — the closer wrote a new `NEXT:` at the report's path and decremented
       the budget; resume from that `NEXT:`. At zero cycles the closer instead prints `HALTED`.
     - `HALTED [<reason>]` — stop; the `halt:*` label already returns the Bead to the operator.
     - `INCOMPLETE` — the Bead is unchanged and no cycle was spent; re-brief the reviewer.
     - `BLOCKED-BY <ids>` (exit 1) — the Bead has open blockers; nothing was changed. Re-run the
       closer once they close.

   Either closer form may run from a session other than the one that claimed the Bead — the
   claiming session's session id stays the recorded `assignee` (the audit trail of who did the
   work); `bd` records no closer-actor field of its own (verified: `bd show --json`/`--long` and
   `bd history --json` all show "beads" as the committer, never the actor who ran `bd close`), so
   when the closer's actor differs it is recorded parenthetically inside the same `EVIDENCE:`
   line — `EVIDENCE: <path> (closed by <actor>)` — never a second, free-text note line (rule 5
   sanctions only the one append).

   A later FAIL review citing the closing PASS report reopens a closed Bead through
   `scripts/bead-reopen.sh --review <report>`, which prints `REOPENED`.
10. **Never close on a runtime's exit code, and never abandon.** A failed attempt leaves the work
    needed: release the claim, return the Bead to open, note what failed. Abandonment is proposed in
    a note, never performed by the executor. The other §5.4 close reasons (`superseded`, `duplicate`,
    `abandoned`, `infeasible`, `declined`) go through `scripts/bead-close.sh --id <id> --reason <word>
    --note <text> [--ref <bead-id>] [--evidence <path>] [--operator]`, gated per contract §5.4's "Who
    may close" column; it prints `CLOSED <reason>`, `BLOCKED-BY <ids>`, or `REFUSED <why>` (exit 1 on
    the last two).
11. **If Beads is unavailable**, finish the unit in hand, record the pending Beads update in the
    work-unit handoff, and start no new Bead work. Never record lifecycle in another tracker.
12. **Before closing your session**, check every Bead you claimed is closed, `acceptance-pending`, or
    released with a note.
13. **Read as JSON, escalate skew, keep the store local.** `bd show --json` is the only faithful read
    path, and it returns an **array** — index `.[0]`, or use `scripts/bead-read.sh --id <id>`. Plain
    `bd show`'s table renderer truncates cells to about 36 characters, but only on a TTY — in the
    non-TTY capture an agent always reads, long titles print in full, so you cannot tell from the
    output whether truncation happened. Read `--json` regardless. Escalate a schema-version skew
    error under rule 8; never set `BD_IGNORE_SCHEMA_SKEW=1`. The live database directory stays on
    writer-host local disk — never NFS or any sync-replicated path; the off-host copy is a discrete
    push at a session boundary.

## The carrier table (rule 7)

Each carrier holds what only it can hold.

| Carrier | Holds |
|---|---|
| The **Bead** | identity, lifecycle, the rule-5 block, the resume directive |
| The **handoff** | session posture, environment gotchas, open steps, operator questions, coordination across several Beads |
| The **governing artifact** | every operator ruling, written as a dated `Operator direction (YYYY-MM-DD)` marker before you stop — never left in the handoff, never written to the Bead |

## Resume order (rule 7)

`scripts/bead-read.sh --id <id> --resume`, then the work-unit handoff, then the work-unit anchor.
`--next` alone prints just the current `NEXT:` value from rule 5's block, plain text, for a caller
that wants the next action without the rest of the read.

Each rule above names its script at the point of action; `SKILL.md`'s Scripts table is the full
list. Rules 3, 8 and 10's note content are judgment and stay here in prose.
