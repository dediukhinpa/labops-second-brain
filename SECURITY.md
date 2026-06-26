# Security policy

LabOps.ai takes the security of this software seriously. Thank you for helping keep it and its users safe.

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

Report privately through either channel:

- **GitHub** — use *Security → Report a vulnerability* (private advisory) on this repository.
- **Email** — `security@labopsai.pro`

Please include: a description of the issue, steps to reproduce (a proof-of-concept if possible), the affected version/commit, and the impact you foresee.

We aim to acknowledge a report within **3 business days** and to share a remediation timeline after triage. Please give us reasonable time to fix the issue before any public disclosure (coordinated disclosure).

## Scope

- **In scope:** the code in this repository — scripts, services, templates.
- **Out of scope:** third-party services this software talks to (Telegram, Anthropic, Groq, …). Report those to the respective vendor. See the **Data & privacy** section of the README for the exact endpoints used.

## Secrets & operator responsibility

This software is **self-hosted**: you run it on your own server and hold your own
credentials. Keep secrets out of git — bot tokens and API keys live in `channel.env` /
`.env` / `.claude/secrets/` with restrictive permissions (`chmod 600`/`640`) and are
never committed. A leaked
*token* is rotated with the provider (BotFather, the Anthropic console, …), not
through this repository. This repo also runs `gitleaks` in CI and ships its own
secret-scan guards to catch accidental commits.

## Supported versions

Security fixes target the latest commit on the default branch (`master`). There are
no separately maintained release branches at this time.
