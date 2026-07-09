# knowledge

Knowledge base. Compiled artifacts, documentation for agents.

## What goes here

- Distilled write-ups synthesized from `external/` forwards
- Internal playbooks, including step-by-step how-to procedures
- Glossary entries, concept explanations, reference cards
- Vendor / API / provider notes (quirks, rate limits, gotchas)
- Stable how-things-work documentation for your stack
- Lessons learned that have been generalized into a principle

## What does NOT go here

- Raw forwards — `external/`
- Decision records — `decisions/`
- Active project notes — `projects/<slug>/notes/`

## Promote pipeline

`external/` (raw forwards) → reviewer reads + extracts → `knowledge/` (distilled). The knowledge file should back-link to all sources it was synthesized from, so future agents can verify provenance.

## Typical authors

- `inbox-agent`, in batch compile mode
- `coordinator-agent`, when a topic accumulates enough signal
- You, when you write up a piece of stable know-how

## Cadence

- Add: weekly compile run, or ad hoc when an insight forms
- Update: when the underlying knowledge changes (vendor updates API, etc.)
- Read: any time an agent is unsure about a domain

## Frontmatter

```yaml
---
type: knowledge
created: '2026-05-16T10:00:00Z'
updated: '2026-05-16T10:00:00Z'
agent: inbox-agent
tags: [mcp, spec]
related: ['external/2026-05-10-mcp-spec-thread.md']
---
```

## Naming

```
mcp-streamable-http-quirks.md
postgres-pgvector-tuning.md
claude-code-skill-discovery.md
```
