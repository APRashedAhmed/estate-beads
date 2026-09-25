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

| Obligation (seam) | Claude Code | Codex CLI | Verdict class | Failure class | Fixture |
| --- | --- | --- | --- | --- | --- |
| skills | TODO | TODO | TODO | TODO | TODO — portability-contract.md §12 |
| catalog entry | TODO | TODO | TODO | TODO | TODO — portability-contract.md §13 |
| agent delivery | TODO | TODO | TODO | TODO | TODO — portability-contract.md §11, Codex ships no plugin-level subagents; delivery is by lifecycle deposit to `~/.codex/agents/` |
| session_opened | TODO | TODO | TODO | TODO | TODO — portability-contract.md §4 |
| before_mutation | TODO | TODO | TODO | TODO — Codex cell is `Degraded` until hook trust is armed for the current hook hash (§3) | TODO — portability-contract.md §4 |
| after_mutation | TODO | TODO | TODO | TODO | TODO — portability-contract.md §4 |
| subagent_admitted | TODO | TODO | TODO | TODO | TODO — portability-contract.md §4 |
| subagent_closed | TODO | TODO | TODO | TODO | TODO — portability-contract.md §4 |
| turn_closed | TODO | TODO | TODO | TODO | TODO — portability-contract.md §4 |
| config_changed | TODO | Not available — Claude-only event (§4) | TODO | TODO | TODO |

## Install / Update / Uninstall
- **Install:** `bash scripts/install.sh` (idempotent; non-interactive with `--yes`).
- **Update:** re-run `bash scripts/install.sh` (idempotent; reconciles installed state to this version).
- **Uninstall:** `bash scripts/uninstall.sh` removes the mechanism and preserves your data;
  `bash scripts/uninstall.sh --purge-data` also removes accumulated data.
