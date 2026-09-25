# Sample plan (batch-authoring fixture)

Four units: one epic and two children under it (parent-by-sibling), plus a
fourth unit blocked by one of the children (dep order). Used by
`tests/create-beads-batch.test.sh`.

```yaml
project: sample-proj
labels: [wf:auto]
class: bounded-increment
budget:
  cycles: 3
units:
  - key: epic-a
    title: "Epic A"
    description: "The epic parent for B and C."
    acceptance: "B and C are both closed."
    accept: operator
    type: epic
  - key: unit-b
    title: "Unit B"
    description: "First child of Epic A."
    acceptance: "B's work lands."
    accept: evidence
    parent: epic-a
  - key: unit-c
    title: "Unit C"
    description: "Second child of Epic A, blocked by B."
    acceptance: "C's work lands after B."
    accept: evidence
    parent: epic-a
    deps:
      - "blocked-by:unit-b"
  - key: unit-d
    title: "Unit D"
    description: "Standalone unit, not under the epic."
    acceptance: "D's work lands."
    accept: independent
    labels: [wf:effort:low]
```
