# Wayfinding operations on Beads

<!-- wordsmith: audience=agent function=reference -->

The tracker adapter the `wayfinder` skill consults. Work in flight lives in the estate Beads database
(`$BEADS_DIR`, prefix `pa`). Prose the operator reads, and that a spec later collapses, lives in the
effort's work-unit directory under `$SEAT_ROOT/PerAnkh/projects/<project>/workunits/<date>-<effort>/`.
Beads carry lifecycle; files carry text. Every write follows the `beads` skill; nothing here
overrides it. Vocabulary: the word is **Bead**; the tracker-generic noun is not used (nor is
"issue"), **OPERATOR** and **AUTO** modes (never HITL or AFK), **map Bead** for the effort's epic,
**ready set** for the takeable Beads, **map holder** for the session that loaded the map.

## Conventions

- One effort per work-unit directory. Its **design note** is `<effort>-design.md`, holding four
  sections: `## Destination`, `## Decisions` (dated `Operator direction (YYYY-MM-DD): …` lines, one per
  resolved OPERATOR Bead, each naming its Bead), `## Not yet specified`, `## Out of scope`.
- Research findings land in `<workunit>/research/<NN>-<slug>.md`; decision prototypes under
  `<workunit>/prototypes/<slug>/`. A Bead links its assets by path in its evidence line.
- Bead ids (`pa-xxxx`) are opaque. Refer to maps and Beads by **title** in everything the operator
  reads; the id rides inside.
- Operator rulings are written to the design note, never to a Bead (rule 7 carrier table).
- Authoring passes the T1–T5 gate. The recognition source (T2) for a child Bead is the charting
  invocation or the resolving Bead that surfaced it. Run one `create-beads-batch.sh --artifact
  <path>` call per charting or graduation pass; it is idempotent by unit key.

## Operations

- **Map**: an `epic` Bead, labels `wayfinder:map` and `wf:<effort-slug>`, `--workunit` pointing at
  the effort's work-unit directory. Description holds `## Destination` and `## Standing directives`
  only (never a section named Notes; that is the rule-5 field).
- **Child Bead**: `--parent <map-id>`. Type by kind: `decision` for grilling, `spike` for research and
  prototype, `task` for task. Labels: `wayfinder:<grilling|research|prototype|task>`, `operator` or
  `auto`, **and `wf:<effort-slug>` set explicitly** — the estate's create path passes
  `--no-inherit-labels` with `--parent` (create-bead.sh:156-158), so nothing is inherited.
  Description is `## Question` and nothing else. Accept mode: OPERATOR Beads `accept:evidence` (the
  operator's live answer, recorded in the design note, is the evidence); AUTO Beads
  `accept:independent` (the map holder accepts on next load).
- **Blocking**: native, `bd dep <blocker-id> --blocks <blocked-id>`; run `bd dep cycles` after a
  wiring pass. A Bead surfaced by resolving another also gets
  `bd dep add <new> <resolver> -t discovered-from`. Blocked-by is the live gate; `bd ready` reads it.
- **Ready set**: `bd ready -l wf:<effort-slug> --json`. `bd ready` drops in-progress (claimed), blocked,
  and deferred Beads (verified live 2026-09-24); the explicit effort label scopes it to this map. First
  row wins unless the operator names a Bead.
- **Claim**: `${CLAUDE_PLUGIN_ROOT}/scripts/bead-claim.sh --id <id>` before any work. `CLAIMED` →
  proceed; `LOST` → take the next ready row. Never work an unclaimed Bead.
- **Resolve (OPERATOR)**: 1. append the ruling to the design note's `## Decisions` as
  `Operator direction (YYYY-MM-DD): <ruling> — <Bead title> (pa-xxxx)`; 2.
  `bead-report-success.sh --id <id> --evidence "<design-note path>#<anchor>"` → `CLOSED` (accept:evidence
  closes immediately, with `close_reason: accepted`). 3. Create-then-wire any newly sharp Beads; move
  each graduated patch out of `## Not yet specified`.
- **Resolve (AUTO research / task)**: write the report to `<workunit>/research/`, then
  `bead-report-success.sh --id <id> --evidence "<report path>"` → `ACCEPTANCE-PENDING <authority>`. For
  `accept:independent`, the map holder never closes it directly: it dispatches a fresh reviewer per
  `review-brief.md` and runs `bead-accept.sh --review <report>` on the verdict — PASS closes it, FAIL
  returns it to `open` with the findings path as NEXT. A finding is not a decision until accepted.
- **Decisions so far**: not maintained by hand. It is
  `bd children <map-id> --json | jq '.[] | select(.status=="closed" and ((.labels|index("wayfinder:out-of-scope"))|not)) | {title, id, close_reason}'`
  read beside the design note's `## Decisions`.
- **Not yet specified** and **Out of scope**: sections of the design note, not Bead fields.
- **Rule out of scope**: add label `wayfinder:out-of-scope`, then
  `bead-release.sh --id <id> --note "out of scope: <why>"` to return it to `open` and propose
  abandonment in the note — contract §5.4: an executor never closes a Bead `abandoned`, only the
  recognition source's owner or the operator does. Add one line under the design note's
  `## Out of scope` naming the Bead; it never appears under `## Decisions`.
- **Session load**: `bead-read.sh --id <map-id> --resume` → work-unit path → read the design note, then
  the ready set. Do not read every child body.
- **Map done**: no open children and `## Not yet specified` empty. Report success on the map itself;
  the operator closes it (rule 9). `bd epic status <map-id>` shows the count.
- **Budget and class**: set by the operator on the map Bead as labels or metadata (`class:`,
  `budget:`), read by review; an agent never writes them. This replaces wayfinder's Notes override.
