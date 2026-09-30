---
name: beads
description: Creates and works Beads in the estate's `bd` tracker. Use when work needs a Bead (new
  recognized work, a resumed unit whose triage row is `migrate`, or a decision Bead blocking one),
  before running `bd create`, `bd ready`, or `bd update --claim`, and when claiming, checkpointing,
  handing off, releasing, or marking a Bead `acceptance-pending`.
---

# beads

<!-- wordsmith: audience=agent function=procedure -->

## Now

!`${CLAUDE_PLUGIN_ROOT}/scripts/bead-context.sh`

If the preflight reports `database: none`, report it to your orchestrator, or to the relevant
Responsibility holder if you have none; never `bd init`.

`bd show --json` returns an **array**. Index it: `jq '.[0]'`. `scripts/bead-read.sh` does this for
you and is the read path to prefer.

## Route

| You are | Go to |
|---|---|
| Creating one Bead — new work, a `migrate` resume, or a rule-8 decision Bead | `references/authoring.md` |
| Creating several Beads from one governing artifact | `references/authoring.md` (batch section) |
| Holding a Bead and working it — claim, checkpoint, hand off, release, report success | `references/working.md` |
| A Bead you reported is `ACCEPTANCE-PENDING review` | `references/working.md` rule 9, and append `references/review-brief.md` to the auditor brief |
| A Bead you reported is `ACCEPTANCE-PENDING operator`, and the operator has said so in chat | `references/working.md` rule 9 (`bead-accept.sh --id <id> --evidence '<message>' --operator`) |
| Reopening a closed Bead on a later FAIL review | `references/working.md` rule 9 |
| Closing a Bead for a §5.4 reason other than `accepted` (`superseded`, `duplicate`, `abandoned`, `infeasible`, `declined`) | `references/working.md` "Closing" (`bead-close.sh`) |

## Scripts

Deployed at `${CLAUDE_PLUGIN_ROOT}/scripts/`. Each takes flags, prints one line on success, and on
failure names what broke and the exact remedy.

| Script | Does |
|---|---|
| `create-bead.sh` | the whole authoring call — labels, metadata, deps, class/budget, the `workunit.yaml` backlink, the migration-log line — then checks itself. Prints the Bead id, or `EXISTS: <id>` |
| `create-beads-batch.sh --artifact <path>` | many Beads from one governing artifact's fenced `yaml` block. Prints one `<key> <id>` line per Bead |
| `check-bead.sh` | the authoring invariants on an existing Bead. Silent on pass |
| `bead-context.sh` | the `## Now` preflight — database path, up to 5 claimed Beads |
| `bead-read.sh` | the faithful read; `--resume` adds the work-unit path; `--next` prints only the current `NEXT:` value, plain |
| `bead-claim.sh --id <id> [--model <sonnet\|opus\|fable>] [--effort <level>]` | claim with the exit-code branch absorbed and `executor.model` and, when known, `executor.effort` recorded. Prints `CLAIMED` or `LOST` |
| `bead-progress.sh` | the rule-5 progress block, rewritten in place |
| `bead-report-success.sh` | rule 9 — evidence, `acceptance-pending`, and a close only under `accept:evidence`. Prints `CLOSED` or `ACCEPTANCE-PENDING <authority>` |
| `bead-accept.sh --id <id> --evidence <path>` | closes an `accept:evidence` Bead already `acceptance-pending`, reclaimed off-script. Prints `CLOSED` |
| `bead-accept.sh --id <id> --evidence '<message>' --operator` | closes an `accept:operator` Bead on the operator's say-so in chat (cite the message, not a file) — refuses without `--operator`; never accepted for `accept:independent` (use `--review` instead). Prints `CLOSED` |
| `bead-accept.sh --review <report>` | the closer for a review verdict. Prints `CLOSED \| ACCEPTANCE-PENDING <authority> \| FAILED <cycles-left> \| HALTED [<reason>] \| INCOMPLETE \| BLOCKED-BY <ids>` (exit 1, nothing changed) |
| `bead-release.sh --id <id> --note <why>` | release a claim: return to open, unassign, record the note. Prints `RELEASED`. Refuses an `acceptance-pending` Bead (awaiting acceptance, not abandoned) unless `--force-pending` is also given |
| `bead-close.sh --id <id> --reason <superseded\|duplicate\|abandoned\|infeasible\|declined> --note <text> [--ref <bead-id>] [--evidence <path>] [--operator]` | the closer for the §5.4 reasons other than `accepted`, gated per contract §5.4's "Who may close" column. Refuses `accepted` (use `bead-accept.sh`), an open blocker, or an open child (contract §1.2 rule 3). Prints `CLOSED <reason>` |
| `bead-reopen.sh --review <report>` | reopen a closed Bead on a later FAIL review citing the closing PASS report. Prints `REOPENED` |

## Not this skill

- The estate cutover, reconciliation runs, and the migration log's **estate-level** entries —
  orchestrator. (A per-Bead migration line is this skill's; `create-bead.sh` writes it.)
- Campaign Beads and the campaign graph — orchestrator.
- Recording an operator ruling — it goes to the governing artifact, never to a Bead.
- Authoring an actual Bead in a headless run or when the source cannot be cited from context —
  spawn `estate-beads:bead-author` (`references/authoring.md`), never the raw `bd create`.
