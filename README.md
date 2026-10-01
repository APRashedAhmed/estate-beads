# estate-beads

Beads work-tracking for the estate: create, claim, report, accept, close, release and guard bd

## Install
`/plugin install estate-beads@homelab-plugins` (or standalone via this repo's `marketplace.json`).

## Components
- **Skill** `skills/beads` — one routed skill (`estate-beads:beads`). Router in `SKILL.md`;
  `references/authoring.md` (create one Bead, or many from an artifact), `references/working.md`
  (the thirteen rules), `references/review-brief.md` (the review-acceptance brief fragment),
  `references/wayfinding-operations.md` (the `wayfinder` skill's tracker adapter).
- **Agent** `agents/bead-author.md` (`estate-beads:bead-author`) — the exception-path Bead-authoring
  subagent; a fresh spawn, never a fork.
- **Hooks** `hooks/hooks.json` — `scripts/eb-guard.py` (`PreToolUse(Bash)`), `scripts/eb-session-start.sh`,
  `scripts/eb-session-end.sh`. See the support matrix below.
- **Script** `scripts/bead-scratch.sh` — the only sanctioned `bd init`: a throwaway Beads database
  under a fixed root, with built-in cleanup (`new`/`rm`/`run -- <cmd>`); see
  `skills/beads/references/authoring.md`.

## Dependencies
PyYAML (`python3 -c 'import yaml'`), used by `scripts/lib/frontmatter.py` (review-report
frontmatter) and `scripts/lib/batch.py` (batch-authoring artifact parsing). Everything else is
stdlib-only.

## Telemetry
This plugin emits no telemetry.

## Decisions
Architecture decisions live in `decisions/` (managed by adr-tools — `adr new` to add one,
`adr check` runs at pre-commit). Plans/specs/audits/learnings go to the plugin's PerAnkh folder.

## Conventions
- Namespace prefix for state files / launchers: `eb-`; for env vars (uppercase): `EB_` — collision-safe in shared `~/.claude/state/`.
- Versioning: no `version` field; commit-SHA drives updates. Annotated git tags
  (`git tag -a vX.Y`) are the human-readable release anchors. No CHANGELOG.md.
- Provider shape: this repo is authored **Claude-shape-canonical** — `skills/`, `agents/`,
  `hooks/hooks.json`, `.mcp.json`, `.claude-plugin/plugin.json` are the physical layout Codex
  CLI also reads from. `.codex-plugin/plugin.json` (and, at T1+, `adapters/codex/agents/*.toml`)
  are GENERATED views, never hand-authored — see `scripts/check-views.sh` and
  `guidelines/portability-contract.md` §2.

## Tests
`bash scripts/test.sh` — single entrypoint; runs all suites, exits non-zero on any failure.

## Provider support
Tier: T2 (see guidelines/portability-contract.md)

**T2 scope is Claude-only for now** (design §12.8, Operator direction 2026-09-24, cited in
`reviews/u3-hooks.md`): the neutral engine, Codex shims, a populated Codex `event-map.yaml`, and
Codex acceptance tests are **not built**. `hooks/eb-shim.sh` / `lib/eb_root.py` / `bin/eb-root.sh`
are the U2 scaffold's generic multi-harness scaffolding and are **not wired into `hooks/hooks.json`**
— `PreToolUse`, `SessionStart`, and `SessionEnd` call `scripts/eb-guard.py` /
`scripts/eb-session-start.sh` / `scripts/eb-session-end.sh` directly (vcs-rails shape), each a
single Claude-only script with no shim/engine split. The scaffold's T2 Codex stubs stay stubs.

| Obligation (seam) | Claude Code | Codex CLI | Verdict class | Failure class | Fixture |
| --- | --- | --- | --- | --- | --- |
| skills | Guide — `skills/beads/SKILL.md` + `references/*.md`; frontmatter carries only `name` and `description`, the vendor-neutral minimum (§12) | Guide — plugin-shipped `skills/` works on both harnesses unmodified (§12); `SKILL.md`'s description is 344 characters, over the ~250-character workspace guideline (design rule 5), risking truncation or omission from Codex's capped listing — not fixed this unit | advisory | fail-open | `scripts/check-views.sh` (no generated view for skills; nothing asserts description length) |
| catalog entry | TODO | TODO | TODO | TODO | TODO — portability-contract.md §13 (U7) |
| agent delivery | Guide — `agents/bead-author.md` is canonical, resolves to `estate-beads:bead-author`; its `tools: Bash, Read, Edit` allowlist is the containment boundary | Guide — delivered by lifecycle deposit (§11): `scripts/gen-agents.py` renders `agents/bead-author.md` to the committed `adapters/codex/agents/eb-bead-author.toml`; `scripts/install.sh` deposits it to `${CODEX_HOME:-$HOME/.codex}/agents/eb-bead-author.toml` (confirmed at `scripts/install.sh:7,15-19`) and `scripts/uninstall.sh` removes it; Codex has no per-tool allowlist for a custom agent, so this agent's tool containment does not carry over — not verified against `sandbox_mode` this unit | advisory | fail-open | `scripts/check-views.sh` (drift between `agents/bead-author.md` and the generated TOML); portability-contract.md §11 |
| `session_opened` (`SessionStart` → `bd prime` + `BEADS_ACTOR` export + advisory crash sweep) | Observe (records/exports; rejects nothing) | Not available — Claude-only exemption, Operator direction (2026-09-24), design §12.8 | advisory | fail-open | `tests/eb-session.test.sh` |
| `before_mutation` (`PreToolUse(Bash)` → `scripts/eb-guard.py`, the `bd` verb guard) | Prevent (governed seam, fails closed on a recognized `bd` invocation the tokenizer cannot parse) | Not available — Claude-only exemption, Operator direction (2026-09-24), design §12.8 | governed | deny | `tests/eb-guard.test.sh`, `tests/fixtures/guard/*.json` |
| `SessionEnd` (release this session's claims) — **no seam in the seven-seam vocabulary**; not amended (design §12.8) | Observe (acts deterministically on this session's own claims; rejects nothing — the least-wrong of the six §3 values for a non-rejecting seam) | Not available — Claude-only exemption, Operator direction (2026-09-24), design §12.8 | advisory | fail-open | `tests/eb-session.test.sh` |
| after_mutation | not used | not used | — | — | — |
| subagent_admitted | not used | not used | — | — | see "Known gaps" (P5 FAIL) |
| subagent_closed | not used | not used | — | — | — |
| turn_closed | not used | not used | — | — | — |
| config_changed | not used | Not available — Claude-only event (§4) | — | — | — |

## Known gaps

- **Subagent actor keying (P5 FAIL, U1).** `$CLAUDE_ENV_FILE` is null at `SubagentStart`, so a
  subagent cannot get its own `<session_id>/<agent_id>` `BEADS_ACTOR` this way. Subagent claims
  stay keyed under the **main session's** bare session id. `[unverified]`: whether a `PreToolUse`
  hook firing on the subagent's own Bash calls receives `agent_id` in its payload — a candidate
  fix, not built or probed here.
- **Scratch `bd init` — closed (pa-e38.8).** The guard's old cwd-outside-git-repo allow for `bd
  init` is removed — a cwd-pinned agent (one whose Bash hook payload's cwd is always inside a git
  repository, e.g. a worktree-bound subagent) could never satisfy it, so it could never reach a
  scratch database at all. `scripts/eb-guard.py` now denies EVERY direct `bd init`, unconditionally,
  naming `scripts/bead-scratch.sh` as the replacement. That script opens its databases under a
  fixed root (`${EB_SCRATCH_ROOT:-${XDG_RUNTIME_DIR:-/tmp}/estate-beads-scratch}`, never cwd), so it
  reaches a scratch database from any session — `new`/`rm <path>` for a database that outlives one
  command, `run -- <cmd...>` for one that doesn't (deletes on exit, success or failure). Cleanup
  also runs at `SessionEnd` (the ending session's own folders) and at `SessionStart` (a 24h sweep),
  both touching only folders this script marked. See `skills/beads/references/authoring.md`.
  `tests/_scratch_db.sh` (the test-only helper this script was promoted FROM) stays as-is — it is
  sourced by ~15 existing suites and runs in-process (exports `BEADS_DIR`/`HOME`/`XDG_CONFIG_HOME`
  into the calling test's own shell, which `bead-scratch.sh` deliberately does not do); reworking
  it to call `bead-scratch.sh` was out of scope for this unit.
- **`bd` verb aliases (fix round 1, F1) — closed.** `done`→`close`, `new`/`q`/`create-form`→`create`,
  `note`→`update --append-notes`, and `-s`/`-s=`→`--status` are now canonicalized before judging
  (`scripts/eb-guard.py`'s `VERB_ALIASES` table) and denied with the same message as their
  canonical verb. `bd unclaim`/`bd reclaim`/`bd assign`/`bd set-state` remain genuinely allowed
  (adjacent claim/assign paths, not aliases of a denied verb) — not a gap.
- **Close/create/delete by another route (fix round 2, M2) — closed.** `bd todo done <id>`
  (→ close) and `bd todo add <title>` (→ create) are two-word verbs, judged on the token after
  `todo`; bare `bd todo`/`bd todo list` stay allowed. `bd supersede`/`bd duplicate` (auto-close
  their target — contract §5.4 has no sanctioned non-`accepted` close reason yet; operator ruling
  pending), `bd batch`/`bd import` (reach close/create/update-status in one call), and
  `bd prune`/`bd purge` (permanent delete) are denied outright, each with its own message; no
  script wraps any of them. `bd forget` (the inverse of the already-denied `bd remember`) is
  denied the same way.
- **`bd <verb> --help`/`-h` (fix round 2, m2) — closed.** Allowed regardless of verb, but ONLY as
  the first token after the verb (`bd close --help` allows; `bd close pa-x --reason -h` still
  denies — `-h` there is a flag value, not a help request).
- **Heredoc body with an apostrophe (fix round 2, m2) — closed.** A heredoc BODY line that fails
  `shlex` (ordinary prose like `fix: don't ...`) no longer fails the WHOLE command closed; only
  that body degrades to a per-line first-token check (`cat <<EOF\nbd close ...\nEOF` still
  denies; a commit message merely containing the word "bd" does not).
- **`env -S`/`--split-string` (fix round 2, m3/N5) — closed.** `env -S 'bd close x'` recurses
  into the split string the same way `bash -c`/`eval` do, and this now resolves `env` even after
  a wrapper prefix (`sudo env -S 'bd close x'` — fix round 2, N5: the wrapper-skip that lands on
  `env` no longer also consumes `env`'s own `-S value`, so its flags stay visible to the check
  that reads them).
- **Command-position variable indirection (fix round 2, N3) — narrowed, not blanket.** A
  command-position `$VAR`/`${VAR}` denies ONLY when a `VAR=<literal>` assignment elsewhere in the
  same command text resolves it to a token whose basename is `bd` (`B=bd; $B close x`,
  `B=b; ${B}d close x`) — judged through the same verb-dispatch table as any other `bd`
  invocation once resolved, so the deny message names the actual verb. A `$( )`/backtick command
  substitution in command position (`` $(command -v bd) close x ``) is never resolved this way
  and is ALLOWED, same as an unresolved `$VAR` with no matching assignment
  (`` "${CLAUDE_PLUGIN_ROOT}/scripts/bead-read.sh" --id x && bd show x ``,
  `bd ready | "$HOME/bin/fmt"`, `$EDITOR bd-notes.md`) — this guard never blocks a command merely
  because the word `bd` appears somewhere else in its text (a fix round 1 deviation from design
  §12.1, reverted; see `pa-s2s.8-review-2` N3). The literal `VAR=<literal>` assignment table is
  built from the top-level command text AND any shell-fed heredoc body (`bash <<EOF\nB=bd\n$B
  close x\nEOF` denies). Remaining unlisted wrappers/indirection (`find … -exec bd close`,
  `setsid`, `doas`, `su -c`, `python3 -c os.system(...)`, `$(command -v bd) close x`, a
  parameter-expansion default like `${B:-bd} close x`, or an assignment that only becomes visible
  after crossing a subshell/`bash -c` boundary — `export B=bd; bash -c '$B close x'`) are NOT
  covered — same class as pa-s2s.4-review-2 N1, still a known gap.
- **Heredoc consumer (fix round 2, N4) — closed.** A heredoc fed to a shell/evaluator (`bash`,
  `sh`, `zsh`, `dash`, `ksh`, `eval`, `source`, `.`) executes its body as a command: a body line
  `shlex` cannot parse (e.g. an apostrophe) now fails the WHOLE command closed when it still
  mentions `bd`, so a prefixed/chained `bd` after an earlier unparseable line (`bash <<'EOF'\necho
  it's\nsudo bd close x\nEOF`) can no longer slip past a first-token-only check. A heredoc fed to
  anything else (`cat`, `tee`, a file) stays data: the per-line first-token degrade from fix round
  1 (m2) still applies there (`cat <<'EOF'\nit's bd close time\nEOF` allows).
- **Wrapper/keyword/shell-string commands (fix round 1, F2/F3) — closed.** Shell reserved words
  (`if`/`then`/`else`/`elif`/`do`/`while`/`until`/`!`/`{`/`time`) and wrappers with their own
  options/values (`timeout N`, `nohup`, `sudo [opts]`, `exec`, `command`, `nice [-n N]`,
  `xargs [opts]`) are skipped before landing on `bd`. `bash -c "..."` / `sh -c '...'` / `zsh -c
  ...` / `eval "..."` recurse into the executed string as a nested command — a `bd` token inside
  such a string is an invocation, never merely "quoted text mentioning bd" (that allow row is for
  a genuinely non-executing command, e.g. `echo "run bd close later"`).
- **Global flags before the verb (fix round 1, F5) — closed.** `bd --json close x` / `bd -q close
  x` no longer misread the flag as the verb; `_skip_global_flags` locates the real verb after any
  leading `-`-prefixed global flags (including value-taking ones like `--db`/`--database`/`-C`).
- **`bd reopen` (fix round 1, F6) — closed.** Denied, naming `scripts/bead-reopen.sh` as the
  sanctioned wrapper for the same open-a-closed-Bead transition.
- **`SessionEnd` timing margin (fix round 1, F4) — mitigated, not eliminated.** The
  status+assignee release is now a single batched `bd update <id...> --status open --assignee ""`
  call per distinct assignee (measured ~185ms for 2 ids, vs. ~750-900ms/id for the full
  `bead-release.sh` chain) run synchronously, so the release state lands even under budget
  pressure. The rule-5 progress note (needs a per-Bead `bd show` to preserve COMPLETED/NEXT) is
  backgrounded one job per Bead under a dynamic remaining-budget deadline. Measured: 3 concurrent
  claims release (status+assignee, asserted by `tests/eb-session.test.sh`) in ~1.31s on a scratch
  db, under the ~1.5s shared budget — but the deadline can still truncate the note-writing phase
  for a large claim count; the release state itself is unaffected.
- **Guard inner `bd show` timeout (fix round 2, m4) — closed.** Was equal to the PreToolUse hook
  timeout (10s); now `BD_SHOW_TIMEOUT = 5` in `scripts/eb-guard.py`, strictly under it, so a slow
  `bd show` times out INSIDE the guard's own budget and fails closed (`deny`) rather than running
  out the hook's whole budget and rendering no decision at all (portability-contract.md §7).
- **`update --status open` id detection is the first non-flag token**, so a flag value that
  itself looks positional (e.g. an id-shaped `--if-assignee` value preceding the real id) could
  be misread as the id. The failure direction is safe (an unresolvable/wrong id makes `bd show`
  fail, which fails closed to deny), never a false allow.

## Skill and agent design

Rationale for the shape of `skills/beads` and `agents/bead-author.md`. Not loaded at runtime.
Domain law is contract part 1 §5–§9, §13
(`$SEAT_ROOT/PerAnkh/projects/permaat/workunits/2026-09-17-beads-state-sovereignty/01-estate-beads-contract.md`);
the shape decision is design §3–§6, §11.1, §11.7, §12.7, §13
(`$SEAT_ROOT/PerAnkh/projects/permaat/workunits/2026-09-24-beads-skill-redesign/2026-09-24-beads-skill-redesign-design.md`).

**One routed skill, not two.** `beads` stays one skill because the law names it that way (PRIME,
the contract, the plan all say "the `beads` skill"), the `## Now` preflight is shared, and splitting
into `bead-authoring`/`bead-working` would duplicate that preflight or drop it from one half for a
~50-line router-hop saving (design §3). `authoring-a-bead.md` and `delegating-authoring.md` from the
prior (chezmoi-resident) skill merge into one `references/authoring.md`: the route table already
read "authoring, then delegating" as one path, so DCQ-4 makes inline `create-bead.sh` the default
and the subagent the stated exception, rather than two files always read together.

**Agent and its scripts move into the plugin.** `agents/bead-author.md` and
`scripts/transcript-window.sh` are called only from this skill; co-location is the point of a
plugin (design §4). `agent-spawn-guard.sh` is dropped — the agent's `tools: Bash, Read, Edit` list
already excludes `Agent`, so the hook was redundant, and dropping it removes the plugin's last
dependency on `~/.claude/agents/estate/`.

**The prose/script/hook boundary (design §5).** Every guard the deployed skill stated in prose now
has a mechanism: the `PreToolUse(Bash)` guard (`scripts/eb-guard.py`) denies `bd init` (every direct
invocation, unconditionally — `scripts/bead-scratch.sh` is the only path, pa-e38.8), `delete`,
`remember`, `edit`, `sql`, raw `create`, raw `close`/`update --status closed`, `update --status open`
on a closed Bead, and raw `--append-notes` — each deny message names the sanctioned script. Every prose sentence that only warned about a mistake the hook now makes
unreachable was deleted rather than kept as a redundant warning; see
`$SEAT_ROOT/PerAnkh/projects/permaat/workunits/2026-09-24-beads-skill-redesign/reviews/u4-skill.md`
for the sentence-by-sentence table. Rules 3, 8, 10, and the T1–T5 gate's judgment stay prose — they
are the residue the guard cannot mechanize.

**Review-based acceptance (design §13).** `accept:independent` now means review-accepted: a fresh
auditor (Claude one tier above the executor, or codex at or above the executor's ladder row) emits a verdict frontmatter block (`references/review-brief.md`
is the fragment appended to its brief), and the executor's session runs
`scripts/bead-accept.sh --review <report>` as the sole closer — the reviewer never mutates Bead
state. Rule 9 in `references/working.md` carries this script's full stdout decision vocabulary
verbatim (`CLOSED | ACCEPTANCE-PENDING <authority> | FAILED <cycles-left> | HALTED [<reason>] |
INCOMPLETE | BLOCKED-BY <ids>`), so a change to the script's tokens is a breaking change to the
skill's prose too (m6, fix round 2 residual — the README previously listed only four of the six).
`ACCEPTANCE-PENDING <authority>` fires on a PASS against an `accept:operator` Bead — the review
still leaves it awaiting the operator's say-so, never closing it directly. `BLOCKED-BY <ids>`
(exit 1) fires before any mutation when the Bead has open blockers; nothing changes and the
caller re-runs once they close.

**Close paths for the other §5.4 reasons (design §14).** `scripts/bead-close.sh` is the closer for
`superseded`, `duplicate`, `abandoned`, `infeasible`, and `declined` — gated to the actors contract
§5.4's "Who may close" column names, so far as they are mechanically checkable: `--operator` is the
only verifiable proxy for "the recognition source's owner" (abandoned, infeasible, superseded) and
for "the operator at a recorded selection act" (declined); an executor (actor == the Bead's own
assignee) is refused outright and pointed at `bead-release.sh --note`. `superseded`/`duplicate`
require `--ref <bead-id>`, verified to exist. `infeasible` requires `--evidence <path>`. The guard
(`scripts/eb-guard.py`) denies raw `bd supersede`/`bd duplicate` naming this script. `lapsed` — the
reason named in this Bead's original brief — was retired by the contract before this unit landed
(Operator direction 2026-09-26, in favor of `declined`); `--reason lapsed` is refused outright,
naming the replacement. The script also refuses an open A4 child (contract §1.2 rule 3: a
non-accepted close must cascade to open children in the same action) rather than cascading — no
cascade is built this unit. Prints `CLOSED <reason> | BLOCKED-BY <ids> | REFUSED <why>` (exit 1 on
the last two).

**Register.** SKILL.md is `function=procedure` (a router with two operative facts) and Navigation
shape (~30 lines) rather than the plain-router size the label alone suggests.
`references/authoring.md` is procedure; `references/working.md` and `references/review-brief.md`
are reference. No contents sections, no summaries, per skill-authoring concern 3
(`~/.claude/skills/skill-authoring/references/writing-prose.md`).

**Pitfalls stay at the point of action** (concern 1): the scratch-database recipe and the
`beads.role` warning note sit in `references/authoring.md` beside the commands they concern; the
`notes` `E2BIG` cap sits in `references/working.md` rule 5, beside `bead-progress.sh`. This happened:
Bead `pa-7a5` was created and then deleted against the estate database on 2026-09-21, by a probe
that meant to target a scratch database but relied on cwd for isolation — `bd` ignores cwd
entirely, so a scratch `bd init` aborted and the following `bd create` wrote straight to the estate
database instead. `references/authoring.md`'s scratch-database recipe (`$BEADS_DIR` as the only
scoping lever) is the operative rule that survives; this paragraph is the incident it answers.

## Install / Update / Uninstall
- **Install:** `bash scripts/install.sh` (idempotent; non-interactive with `--yes`).
- **Update:** re-run `bash scripts/install.sh` (idempotent; reconciles installed state to this version).
- **Uninstall:** `bash scripts/uninstall.sh` removes the mechanism and preserves your data;
  `bash scripts/uninstall.sh --purge-data` also removes accumulated data.
- **Checkpoint-registry cutover (manual, operator-owned):** this plugin ships
  `seed/estate-beads-report.yaml`, the checkpoint closeout participant descriptor. The
  checkpointing plugin's registry glob (`ckpt-participants.sh`) only matches
  `~/.claude/checkpoint.d/*.yml` — copy the seed to
  `~/.claude/checkpoint.d/estate-beads-report.yml`, renaming `.yaml` → `.yml` on
  placement; a copy left as `.yaml` is silently invisible to the registry. The
  descriptor's `id: estate-beads-report` must equal the filename stem
  (`estate-beads-report`) — it already does; do not edit `id:` when placing it. The
  checkpointing dispatcher supplies `CKPT_HANDOFF_PATH` (the archived handoff's path)
  as an environment variable to this `kind: shell` participant's run line on a
  closeout event; `scripts/eb-closeout-report.sh` reads it (falling back to `$1`).
