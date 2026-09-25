---
id: ADR-000
title: ADR format and conventions (estate-beads pointer)
description: >
  This repo defers to the canonical ADR-000 format contract shipped by the
  adr-tools plugin and declares any project-specific section/field additions
  here. Read before authoring or editing any ADR in this repo.
date: 2026-09-24
status: active
supersedes: ~
tags: [meta, process]
extra_sections: []
extra_fields: []
---

## Context
This repo's ADRs follow a shared cross-project format whose canonical definition
lives in the adr-tools plugin. Duplicating it here would drift (ADR-001 Rule 1),
so this file is a thin pointer that links to canonical and records only this
project's additions.

## Decision
Defer to the canonical ADR-000 in adr-tools: https://github.com/APRashedAhmed/adr-tools/blob/main/decisions/ADR-000-adr-format-and-conventions.md
Project-specific additions are declared in this file's `extra_sections` and
`extra_fields` frontmatter and enforced by `adr check`.
Offline: `adr rules 000 --dir <adr-tools-clone>/decisions`.

## Rules
1. Every ADR in this repo MUST satisfy the canonical ADR-000 contract (required
   frontmatter fields and body sections) as shipped by the adr-tools plugin.
2. Project-specific required sections MUST be listed in `extra_sections`;
   project-specific required frontmatter fields in `extra_fields`. The contract
   `adr check` enforces is the union of canonical and these extras.
3. The canonical required set is a floor: this file MUST NOT be used to remove a
   canonical-required section or field.
4. `TEMPLATE.md` is generated from the effective contract by `adr sync-template`
   and MUST NOT be hand-edited.
5. When writing or reviewing an ADR, the `adr-writer` skill MUST be used.
