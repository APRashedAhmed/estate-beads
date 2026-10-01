---
wordsmith: { audience: agent, function: procedure }
---

# Authoring a Bead

Inline `scripts/create-bead.sh` is the default authoring path. Spawn the fresh
`estate-beads:bead-author` subagent only for the exception case (below). Raw `bd create` is denied
by the `PreToolUse` guard; it names these two scripts as the remedy.

## Is this a Bead at all?

Before the gate: the work survives this session ending or a change of executor, and it is not a
step inside work you already hold. A step goes in the session task list, not here.

## The gate (T1–T5)

Run all five yourself before creating anything. Any fail: create nothing.

| # | Test | Passes | Fails |
|---|---|---|---|
| T1 | Finite | The acceptance condition is stated now and you can decide whether it is met | Recurring, no end state, or "done" is undecidable |
| T2 | Recognized | You can quote a recognition source (below) verbatim | No citation, or one you cannot quote |
| T3 | Independent | Assignable, blockable, resumable, abandonable on its own | A step the same actor finishes inside its parent |
| T4 | Single | `bd search` finds no open Bead for the same work | It mirrors a board row, manifest, or sibling Bead |
| T5 | Routable | Exactly one project key | Two projects, or none |

Recognition sources, cited verbatim in `recognized-by`:

| # | Source | Example citation |
|---|---|---|
| A1 | Operator direction | a journal R-id, or a dated `Operator direction (YYYY-MM-DD)` marker in an artifact |
| A2 | A governing artifact that commissions it | an admitted Spec, Plan, or collapsed workload artifact |
| A3 | An admitted Responsibility or standing control | the Responsibility or control record |
| A4 | Necessity for an already-recognized Bead | that Bead's id, plus the A1–A3 source at its chain's root |

For work selected at a selection act, the A1 citation is `<note>#Selection` and the approval date: the
design or goal note's `## Selection` section carries the dated approval line (contract §1.1). The
review-based recognition path that preceded selection acts is retired (retirement record
`$SEAT_ROOT/iunu/PerMaat/intent/2026-09-26-strategy-stratum-retirement.md`).

Run T4 with a real probe: `bd search "<a few words of the title>"`. The verdict is yours; the probe
only informs it.

Fail routing:

- **Fail T2** → the project's intake (`ideas/`, `refinements/`, `bug-inbox/`, or the proposing
  artifact). Do not create.
- **Fail T5** → resolve ownership first, then return.
- **Fail T1, T3 or T4** → reshape the work, or fold it into the Bead that already covers it.

Default granularity is **one Bead per governing artifact**. Add children only where an item passes
T3 against its siblings.

## Field schema

- **Title** — imperative and finite ("Amend ADR-010 for the Beads backlink"), not a topic.
- **Description** — what the work is, plus the acceptance condition. Longer than a screen means the
  content belongs in an artifact; point at it instead.
- **Labels** — `project:<PerAnkh project key>` always, exactly one. `accept:<evidence|independent|operator>`
  always. `tier:<fable|opus|sonnet>` only when a tier applies, with an optional `effort:<level>` — you
  never choose a tier to admit yourself. `class:<bounded-increment|hardened>` — `create-bead.sh`
  writes the default (`bounded-increment`) explicitly when you omit `--class`.
- **Metadata** — `recognized-by` always; `workunit` when a work-unit exists; `governs` for the spec,
  plan, or workload artifact executed; `packet` for decision Beads; `migrated-from` for migrated
  Beads, repeatable; `key` when authoring from a batch artifact. `budget` — `create-bead.sh` writes
  the default (`{"cycles": 2}`) explicitly when you omit `--budget`; every dimension is a
  non-negative integer. Paths in ADR-025 form (`$SEAT_ROOT/<district>/<repo>/<path>`). These keys are
  hyphenated — `--set-metadata` rejects them, so they go only through `--metadata '<json>'`.
- **Dependencies** — real blocking facts only. Artifact lineage is not a dependency; chronology never
  is; `external:` deps are not used. Pass `--deps "blocked-by:<id>,discovered-from:<id>"`.

## Create one Bead

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/create-bead.sh \
  --title "<imperative finite title>" \
  --type task \
  --description "<what; acceptance condition>" \
  --acceptance "<the condition, decidable>" \
  --project "<key>" \
  --accept "<evidence|independent|operator>" \
  --recognized-by "<citation, verbatim>" \
  [--tier "<fable|opus|sonnet>"] [--effort "<level>"] \
  [--class "<bounded-increment|hardened>"] [--budget "cycles=<n>"] \
  [--workunit "<$SEAT_ROOT/PerAnkh/projects/<project>/workunits/<date>-<slug>/>"] \
  [--governs "<artifact path>"] [--packet "<ADR-016 packet path>"] \
  [--deps "blocked-by:<id>,discovered-from:<id>"] [--parent "<parent id>"] \
  [--key "<stable idempotency key>"] [--label "<extra label>"]... \
  [--migrated-from "<legacy record>"]... \
  --by "<your session id>"
```

It prints the Bead id, checks its own result, and writes the `workunit.yaml` backlink and (when
`--migrated-from` is present) the migration-log line in the same action. On a second call for work
it already created — keyed on `--key` first, then `--migrated-from`, else on an exact `--title`
match — it prints `EXISTS: <id>` and creates nothing; treat that like success. Never pass `--force`; that judgment is
never yours to make. `parent_id` on the created Bead reads null even under `--parent`; parentage is a
`parent-child` entry inside `dependencies` — `check-bead.sh` reads there, and so should you if you
verify it by hand.

## Many Beads from one artifact

For several Beads recognized by the same governing artifact, write a fenced `yaml` block into that
artifact and run:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/create-beads-batch.sh --artifact <path> [--dry-run]
```

Batch-level `project` is required, once for the whole artifact. Per unit: `key` (the idempotency
key), `title`, `description`, `acceptance`, `accept`, `type`, `labels`, `tier`/`effort`, `class`,
`budget`, `parent` (a sibling key or an existing id), `deps` (`blocked-by:<key|id>`,
`discovered-from:<id>`). Batch-level `labels`, `class`, `budget` apply to every unit unless a unit
overrides them. Sibling keys resolve in dependency order; a parent may be a sibling in the same
batch. Rerunning on the same artifact creates only new keys; an existing key whose fields drifted
prints `EXISTS: <id>` plus a one-line diff hint and is never updated in place. One `key id` line per
Bead on stdout.

## The exception: spawning `estate-beads:bead-author`

Use the subagent only when you cannot cite the recognition source from your own context, or in a
headless run without script permission — never as the default path. It is a **fresh spawn, never a
fork**: a forked agent shares the very context whose citation the gate exists to check.

Brief it with one paragraph plus your session id:

| Field | Required | Note |
|---|---|---|
| Title intent | always | imperative and finite; the agent words it |
| `recognized-by` | always | **quoted verbatim.** You supply the citation; the agent never derives one |
| Project key | always | the PerAnkh project; exactly one |
| `accept:` mode | always | `evidence`, `independent`, or `operator` |
| Acceptance condition | always | decidable now |
| Work-unit path | when one exists | the directory; its `workunit.yaml` must already exist |
| `tier:` (+ `effort:`) | when not the default tier for the class | you never set a tier to admit yourself |
| `class:` / `budget:` | when not the default | otherwise the agent's create call omits both and takes the script's defaults |
| `governs`, `packet` | when applicable | the executed artifact; the ADR-016 packet for a decision Bead |
| Deps | when real blocking facts exist | `blocked-by:<id>`, `discovered-from:<id>`; never lineage or chronology |
| Parent | optional | the agent always disables label inheritance |
| `migrated-from` | migrations only | one entry per legacy record replaced |
| Your session id | always | so the agent can open the scoped transcript window |

It returns exactly one line: the Bead id, `EXISTS: <id>`, or `REFUSED: <gate> <reason>`. Anything
longer is a contract violation — treat it as a refusal and re-brief. On a refusal, route per the
fail-routing table above; do not re-brief with the same content and hope. The agent runs
`check-bead.sh` itself, so re-run it yourself only if you edited the Bead afterward.

`recognized-by` stays yours to supply because the agent has not seen the conversation in which the
work was recognized; its transcript window only *checks* your citation against what actually
happened, never derives one. Absent or unquotable → `REFUSED: T2`.

## Migration-on-resume

No Bead is created ahead of need. When you resume a unit whose triage-ledger row is `migrate` and it
has no Bead, author its Bead before anything else.

1. Confirm the `migrate` disposition in the triage record.
2. Re-verify liveness from evidence — a content change in the last four weeks. A `status: active`
   manifest, especially `backfilled: true`, is not a liveness signal. Not live → leave it, and
   record the reclassification rather than creating.
3. Create, with `recognized-by` pointing at the triage record's dated direction marker and one
   `--migrated-from` entry per legacy record it replaces. `--migration-log` defaults to the real
   estate migration log and `--workunit` has no default at all — a dry run against a scratch database
   must pass both explicitly, pointed at scratch paths, or it silently appends the dry run's line to
   the real log.
4. Confirm `beads:` and `lifecycle: beads` landed in `workunit.yaml` (the create call writes both).
5. Confirm the per-Bead migration-log line landed (contract part 4 §6.1; the create call writes it).
6. Claim it (`references/working.md`, rule 2) if you are continuing the work; otherwise leave it
   open.

## Scratch databases: `scripts/bead-scratch.sh`, never a raw `bd init`

`bd` ignores cwd entirely — `$BEADS_DIR` is the only scoping lever. A raw `bd init` can collide with
an already-initialized database ("Found existing Dolt database") and a later `bd create` then writes
straight to the **estate** database instead; cwd gives no protection. `scripts/eb-guard.py` denies
every direct `bd init`, unconditionally — there is no cwd-based exception (pa-e38.8 removed the prior
cwd-outside-git-repo allow: a cwd-pinned agent, one whose Bash hook payload's cwd is always inside a
git repository, could never satisfy it, so it could never reach a scratch database at all).

`scripts/bead-scratch.sh` is the only sanctioned path. It creates its databases under a FIXED root
(`${EB_SCRATCH_ROOT:-${XDG_RUNTIME_DIR:-/tmp}/estate-beads-scratch}`), never under cwd, so it works
identically from any session, cwd-pinned or not:

```bash
bash "$(bash <plugin-root>/bin/eb-root.sh plugin)/scripts/bead-scratch.sh" run -- bd create "..." --json
```

`run -- <cmd...>` creates a scratch database, exports `$BEADS_DIR` for `<cmd...>`, and deletes the
database on exit — success, failure, or an uncaught signal — then exits with `<cmd...>`'s own code.
For a database that must outlive one command, use `new` (prints `BEADS_DIR=<path>/.beads`, one line)
and clean up later with `rm <path>` — `rm` refuses anything not under the scratch root and marked by
this script, so it can never be pointed at the estate database by mistake. Never point `$BEADS_DIR`
at the estate database from a probe. A `bd create`/`bd update` run against a scratch database also
prints `warning: beads.role not configured (GH#2950)` on stderr — noise, not a finding; the estate
database repo sets `beads.role=maintainer`, so it only appears against scratch databases. Tests
exercise this through `tests/bead-scratch.test.sh` and `tests/_scratch_db.sh` (the latter still used
by other suites — see README.md's "Known gaps" for the split).
