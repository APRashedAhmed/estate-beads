# estate-beads

Beads work-tracking for the estate: create, claim, report, accept, release and guard bd

## Install
`/plugin install estate-beads@homelab-plugins` (or standalone via this repo's `marketplace.json`).

## Components
<!-- list skills / agents / commands / hooks as you add them -->

## Dependencies
Stdlib-only. <!-- list any non-stdlib runtime dependency here; prefer stdlib-only -->

## Telemetry
This plugin emits no telemetry.
<!-- If it emits events via the agentic-telemetry facade (emit_event), list each event + when it
     fires in a table here, vendor the catalog as registry.d/<prefix>.yml, and deposit it from
     install.sh. Re-scaffold with --with-telemetry to generate that structure. See
     guidelines/telemetry-contract.md and the usage-aware-execution exemplar. -->

## Decisions
Architecture decisions live in `decisions/` (managed by adr-tools — `adr new` to add one,
`adr check` runs at pre-commit). Plans/specs/audits/learnings go to the plugin's PerAnkh folder.

## Conventions
- Namespace prefix for state files / launchers: `eb-`; for env vars (uppercase): `EB_`
  (shorten it if `estate-beads` is long — keep it collision-safe in shared `~/.claude/state/`).
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
| skills | TODO | TODO | TODO | TODO | TODO — portability-contract.md §12 (U4) |
| catalog entry | TODO | TODO | TODO | TODO | TODO — portability-contract.md §13 (U7) |
| agent delivery | TODO | TODO | TODO | TODO | TODO — portability-contract.md §11 (U4/U7), Codex ships no plugin-level subagents; delivery is by lifecycle deposit to `~/.codex/agents/` |
| `session_opened` (`SessionStart` → `bd prime` + `BEADS_ACTOR` export + advisory crash sweep) | Observe (records/exports; rejects nothing) | Not available — Claude-only exemption, Operator direction (2026-09-24), design §12.8 | advisory | fail-open | `tests/eb-session.test.sh` |
| `before_mutation` (`PreToolUse(Bash)` → `scripts/eb-guard.py`, the `bd` verb guard) | Prevent (governed seam, fails closed on a recognized `bd` invocation the tokenizer cannot parse) | Not available — Claude-only exemption, Operator direction (2026-09-24), design §12.8 | governed | deny | `tests/eb-guard.test.sh`, `tests/fixtures/guard/*.json` |
| `SessionEnd` (release this session's claims) — **no seam in the seven-seam vocabulary**; not amended (design §12.8) | Observe (acts deterministically on this session's own claims; rejects nothing — the least-wrong of the six §3 values for a non-rejecting seam) | Not available — Claude-only exemption, Operator direction (2026-09-24), design §12.8 | advisory | fail-open | `tests/eb-session.test.sh` |
| after_mutation | TODO | TODO | TODO | TODO | TODO — not built this unit |
| subagent_admitted | TODO | TODO | TODO | TODO | TODO — not built this unit; see "Known gaps" (P5 FAIL) |
| subagent_closed | TODO | TODO | TODO | TODO | TODO — not built this unit |
| turn_closed | TODO | TODO | TODO | TODO | TODO — not built this unit |
| config_changed | TODO | Not available — Claude-only event (§4) | TODO | TODO | TODO |

## Known gaps

- **Subagent actor keying (P5 FAIL, U1).** `$CLAUDE_ENV_FILE` is null at `SubagentStart`, so a
  subagent cannot get its own `<session_id>/<agent_id>` `BEADS_ACTOR` this way. Subagent claims
  stay keyed under the **main session's** bare session id. `[unverified]`: whether a `PreToolUse`
  hook firing on the subagent's own Bash calls receives `agent_id` in its payload — a candidate
  fix, not built or probed here.
- **Transition-window scratch `bd init` (P2 PARTIAL, U1).** A `permissions.deny` rule on `bd init`
  in the live settings wins over this hook's `allow` (confirmed by probe, not inferred). Until
  U8's retirement commit B removes the settings deny rules, scratch `bd init` for probing/testing
  is only possible under an isolated settings source
  (`claude -p --setting-sources "" --settings <file>`), not in a normal session — this guard's
  scratch-form allow is inert against the live deny in the meantime.
- **`bd` verb aliases not covered by the guard.** The decision table denies specific verbs
  (`init` unqualified, `delete`, `remember`, `edit`, `sql`, `create`, `close`,
  `update --status closed`, `update --append-notes`) and allows everything else, including
  unknown verbs, per the plan's literal table. `bd` 1.3.0 ships several alias/adjacent
  subcommands not in that table — `bd q` (quick create, `create`'s alias), `bd note` (append-note
  alias of `--append-notes`), `bd unclaim`/`bd reclaim`/`bd assign`/`bd set-state` (claim/assign
  paths adjacent to `--claim`/`--status`) — that route around the corresponding deny. Recorded
  as a follow-up for U4/U7, not fixed here (out of this unit's literal spec).
- **`SessionEnd` timing margin, n=1.** Measured 750–900ms on a scratch db
  (`tests/eb-session.test.sh`) for **one** claimed Bead; each `bead-release.sh` chain is ~4 `bd`
  invocations (~600ms), so a session releasing two or more claims risks exceeding Claude's
  documented ~1.5s total `SessionEnd` budget (portability-contract.md §5.5) — the harness, not
  `hooks.json`'s own `"timeout": 5`, is what actually caps this. Not fixed here; flagged for U7.
- **Wrapper/keyword commands the guard does not special-case.** `bash -c "bd close x"`, `sh -c
  ...`, `eval "..."`, `xargs bd ...`, `timeout 5 bd ...`, `nohup bd ...`, `time bd ...`, `sudo bd
  ...`, `if bd close x; then ...`, `! bd ...` all fall to "first token isn't `bd`" and are
  allowed — same class of gap as the verb aliases above, not covered by the plan's literal
  decision table. The quoted-string cases (`bash -c 'bd close x'` as a literal string argument)
  are spec-sanctioned by the "quoted text → allow" row; the executable-wrapper cases are not.
- **Scratch-allow reachability, checked live:** `git -C $SEAT_ROOT/scratch rev-parse --git-dir`
  and `git -C $SEAT_ROOT rev-parse --git-dir` both report "not a git repository" — the scratch
  form's cwd-outside-git-repo check is satisfiable at the estate's actual scratch path.
- **`update --status open` id detection is the first non-flag token**, so a flag value that
  itself looks positional (e.g. an id-shaped `--if-assignee` value preceding the real id) could
  be misread as the id. The failure direction is safe (an unresolvable/wrong id makes `bd show`
  fail, which fails closed to deny), never a false allow.

## Install / Update / Uninstall
- **Install:** `bash scripts/install.sh` (idempotent; non-interactive with `--yes`).
- **Update:** re-run `bash scripts/install.sh` (idempotent; reconciles installed state to this version).
- **Uninstall:** `bash scripts/uninstall.sh` removes the mechanism and preserves your data;
  `bash scripts/uninstall.sh --purge-data` also removes accumulated data.
