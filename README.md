<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/labops-logo-dark.svg">
    <img src="assets/labops-logo.svg" alt="LabOps.ai" width="280">
  </picture>
</p>

<h1 align="center">labops-second-brain</h1>

<p align="center"><em>AI operations — from inside the profession</em></p>

<p align="center">
  <a href="https://labopsai.pro"><img src="https://img.shields.io/badge/%F0%9F%8C%90%20labopsai.pro-6E56CF?style=for-the-badge" alt="labopsai.pro"></a>
  <a href="./LICENSE"><img src="https://img.shields.io/badge/License-Proprietary-CC2B2B?style=for-the-badge" alt="License: Proprietary"></a>
  <img src="https://img.shields.io/badge/Built%20by-LabOps.ai-111111?style=for-the-badge" alt="Built by LabOps.ai">
</p>

<p align="center"><a href="README.md"><b>English</b></a> · <a href="README.ru.md">Русский</a></p>

<p align="center">
  <b>Part of labops:</b>
  <a href="https://github.com/dediukhinpa/labops-tg-plugin">tg-plugin</a> ·
  <b>second-brain</b> ·
  <a href="https://github.com/dediukhinpa/labops-agent-architecture">agent-architecture</a>
</p>

> **A shared brain for a team of Claude Code agents.** Self-hosted on a single VPS: Postgres 16 + pgvector, a set of MCP servers (memory, hybrid recall, swarm coordination, tasks) and background workers. A Markdown vault as the single source of truth + semantic search on top of it. Part of the **labops** architecture (see [`labops-tg-plugin`](#part-of-labops) and [`labops-agent-architecture`](#part-of-labops)).

This is the **long-term shared memory** layer. Each agent keeps its own "hot" memory in its workspace (`CLAUDE.md`, `hot/`, `warm/`), while `labops-second-brain` is **L4**: semantic, shared across the whole team, with embedding search and strict access control.

> [!IMPORTANT]
> **Platform:** built for **Linux + systemd + Postgres peer-auth** (OS user == pg role, usually `second_brain`). Not Docker, not macOS/Windows.

---

## Why a shared memory backend

A single agent remembers its own session. A team of agents does not: knowledge gained by one is invisible to the others, is lost on compaction, and cannot be searched by meaning. `labops-second-brain` solves this — a shared layer reachable by every agent over MCP, with semantic recall, dual-write so nothing is lost on compaction, scoped RBAC, and signed inter-agent webhooks instead of blind direct calls.

| Problem | Solution |
|---|---|
| Knowledge locked inside one session | a shared layer reachable by all agents over MCP |
| Context lost on compaction | important things are written straight to the vault + DB (dual-write) |
| "I've seen this somewhere before" | semantic recall over embeddings, not grep |
| Who may read/write what | scopes + per-agent tokens (RBAC) |
| The swarm pokes each other blindly | inter-agent webhooks with signatures and retries |

---

## Quickstart

> [!TIP]
> If you have no time to read — this is the necessary and sufficient set.

**1. Get the repo, then run the installer** on a clean Ubuntu 22.04+ host as root. It installs Postgres 16 + pgvector from `apt.postgresql.org` for you.

```bash
# If you installed labops-agent-architecture first, this repo is ALREADY at
# ~/labops-second-brain (its installer cloned it — but did NOT install it).
# Otherwise clone it yourself:
git clone https://github.com/dediukhinpa/labops-second-brain.git ~/labops-second-brain

cd ~/labops-second-brain    # the installer uses relative paths — run it from the repo root

# a) manually:
sudo bash scripts/install.sh

# b) or hand it to a Claude Code agent (it follows AGENT.md and asks you to
#    confirm destructive steps — root-level provisioning, systemd units, etc.):
claude
#   in the session, paste:
#   "Прочитай и выполни инструкции из AGENT.md — разверни Second Brain,
#    Path A (VPS + inbox-agent). Подтверждай со мной каждый деструктивный шаг."
```

**2. Fill in only the required variables** in `.env` (everything else is generated / optional — see the Quick Start block at the top of [`.env.example`](.env.example)):

- `PG_HOST` — DB host (default is the unix socket `/var/run/postgresql` → peer-auth, no password needed), `PG_DATABASE`, `PG_USER`;
- `MCP_MEMORY_PORT` / `MCP_MEMORY_ROUTER_PORT` / `MCP_AGENT_ROUTER_PORT` — server ports (defaults `5001` / `5002` / `5000`);
- `PG_PASSWORD` is needed **only** with a TCP host; leave it empty for peer-auth.

The install is considered successful only when the **smoke-test** at the end is green (if it fails, see [Troubleshooting](#troubleshooting)).

**3. First write + query (via MCP).** Issue a per-agent Bearer token on the VPS, wire it into the agent's `.mcp.json`, then write and recall:

```bash
# issue a token (printed once — save it)
sudo -u second_brain python /opt/second_brain/scripts/issue-agent-token.py \
  --agent my-agent --scopes '*'
```

> [!WARNING]
> The raw secret is printed once — save it; the DB stores only its sha256.

```jsonc
// ~/.claude/.mcp.json on the agent host
{
  "mcpServers": {
    "second_brain-memory": { "url": "http://<VPS>:5001/mcp", "headers": { "Authorization": "Bearer <token>" } },
    "second_brain-memory_router": { "url": "http://<VPS>:5002/mcp", "headers": { "Authorization": "Bearer <token>" } },
    "second_brain-agent_router":  { "url": "http://<VPS>:5000/mcp", "headers": { "Authorization": "Bearer <token>" } }
  }
}
```

```text
# write — the agent calls the memory tool
create_decision_note(title="Use pgvector for recall", body="...", scope="decisions")

# query — the agent calls recall
recall(query="how do we store embeddings")
```

To probe the brain directly without an agent:

```bash
curl -sS -H "Authorization: Bearer <token>" http://<VPS>:5002/mcp/
# expect 406 with an MCP error body (live upstream). 401 → wrong token. Connection refused → firewall.
```

---

## Memory layers

```mermaid
%%{init: {'theme':'base','themeVariables':{'primaryColor':'#EDE9FE','primaryTextColor':'#4C1D95','primaryBorderColor':'#8B5CF6','lineColor':'#8B5CF6','secondaryColor':'#F1F5F9','tertiaryColor':'#ffffff','clusterBkg':'transparent','clusterBorder':'#B794F4','fontFamily':'Helvetica,Arial,sans-serif'}}}%%
flowchart LR
    L1["L1 · Identity<br/>CLAUDE.md, rules.md<br/>(in the system prompt)"]
    L2["L2 · Hot<br/>hot/recent.md, handoff.md<br/>(current work)"]
    L3["L3 · Warm<br/>warm/decisions.md<br/>(rotation)"]
    L4["L4 · Shared brain<br/>labops-second-brain<br/>(vault + pgvector)"]
    L1 --> L2 --> L3 --> L4
    classDef brand fill:#8B5CF6,stroke:#6D28D9,color:#ffffff,font-weight:bold
    classDef ext fill:#CCFBF1,stroke:#0D9488,color:#0F766E
    classDef store fill:#FEF3C7,stroke:#D97706,color:#92400E
    classDef sys fill:#E2E8F0,stroke:#334155,color:#1E293B
    linkStyle default stroke:#8B5CF6,stroke-width:1.5px
    class L4 brand
    class L1,L2,L3 sys
```

- **L1–L3 live in the agent's workspace** (that is the [`labops-agent-architecture`](#part-of-labops) layer) — personal, fast, in the session context.
- **L4 — this repository** — shared, semantic, surviving sessions and compaction. Decisions, errors, research, notes about the person and the project are flushed here. Search is by meaning; access is by scopes.

---

## Architecture

```mermaid
%%{init: {'theme':'base','themeVariables':{'primaryColor':'#EDE9FE','primaryTextColor':'#4C1D95','primaryBorderColor':'#8B5CF6','lineColor':'#8B5CF6','secondaryColor':'#F1F5F9','tertiaryColor':'#ffffff','clusterBkg':'transparent','clusterBorder':'#B794F4','fontFamily':'Helvetica,Arial,sans-serif'}}}%%
flowchart LR
    subgraph agents["Agents (Claude Code sessions)"]
        A1["agent 1"]; A2["agent 2"]; A3["agent N"]
    end

    subgraph brain["labops-second-brain (single VPS)"]
        MEM["memory-mcp :5001<br/>writes notes to the vault"]
        REC["memory_router-mcp :5002<br/>hybrid search"]
        SW["agent_router-mcp :5000<br/>agent routing"]
        TASK["task-mcp :5003<br/>tasks/board"]
        IW["ingest-worker<br/>chunking + embeddings"]
        SWW["agent_router-worker<br/>webhook delivery"]
        PG[("Postgres 16 + pgvector<br/>documents · embeddings ·<br/>agent_tokens · audit ·<br/>swarm_outbox · tasks")]
        VAULT["vault/ (Markdown SSOT)"]
    end

    A1 & A2 & A3 -- "MCP (HTTP, Bearer/HMAC)" --> MEM & REC & SW & TASK
    MEM --> VAULT
    MEM --> PG
    IW -- "watches the vault, computes embeddings" --> PG
    REC --> PG
    SW --> SWW --> A1
    classDef brand fill:#8B5CF6,stroke:#6D28D9,color:#ffffff,font-weight:bold
    classDef ext fill:#CCFBF1,stroke:#0D9488,color:#0F766E
    classDef store fill:#FEF3C7,stroke:#D97706,color:#92400E
    classDef sys fill:#E2E8F0,stroke:#334155,color:#1E293B
    linkStyle default stroke:#8B5CF6,stroke-width:1.5px
    class MEM,REC,SW,TASK brand
    class A1,A2,A3 ext
    class PG,VAULT store
    class IW,SWW sys
```

- **MCP servers** — the entry points for agents (HTTP, authenticated with a Bearer token or an HMAC signature).
- **ingest-worker** — watches the vault for changes, splits documents into context-aware chunks and computes embeddings (FastEmbed `multilingual-e5-large`).
- **agent_router-worker** — asynchronously delivers inter-agent webhooks with retries.
- **core-mcp** — a mode that aggregates memory+agent_router+task in a single process (see tool-gating below).

### MCP servers & ports

| Server | Port | Purpose | systemd |
|---|---|---|---|
| `memory-mcp` | **5001** | writes notes to the vault (decision/error/external/personal/project), dedup by sha256 | `memory-mcp.service` |
| `memory_router-mcp` | **5002** | hybrid search (semantic + lexical + rerank), cross-links | `memory_router-mcp.service` |
| `agent_router-mcp` | **5000** | swarm coordination: outbox, inter-agent messages | `agent_router-mcp.service` |
| `task-mcp` | **5003** | tasks, board, agent supervisor | `task-mcp.service` |
| `ingest-worker` | — | chunking + embeddings (watermark over changes) | `ingest-worker.service` |
| `agent_router-worker` | — | webhook delivery (5 retries, exp backoff) | `agent_router-worker.service` |

**tool-gating:** the `SECOND_BRAIN_TOOLS` variable (default `core`) decides which tools the server exposes to clients. A new memory tool is visible only if it is present in `CORE_TOOLS_BY_SERVER` (`services/shared/tool_gating.py`), not just in the code.

---

## Storage: vault + Postgres

- **vault/** — a directory of Markdown files, the **single source of truth** (human-readable, git-friendly). Each note = a `.md` file with YAML frontmatter.
- **Postgres + pgvector** — an index on top of the vault: `documents`, `embeddings` (a vector per chunk), `agent_tokens` (RBAC), `audit` (who wrote what), `swarm_outbox`, `tasks`. The DB is derived; the truth is in the vault.

A document flows: written via `memory-mcp` → a file in the vault + a row in `documents` → `ingest-worker` splits it into chunks and computes embeddings → available in `recall`.

> [!NOTE]
> `ingest-worker` only embeds what arrived through a `memory-mcp` write (a row in `documents` + a job in the queue). `.md` files **dropped into the vault by hand** (bypassing `memory-mcp`) are NOT indexed automatically and are not found in recall.

---

## Scopes & RBAC

Scopes are plain semantic names — simply **top-level folders in the vault** into which knowledge is sorted (strategy, decisions, inbox, etc.). Each scope is a separate "shelf", and read/write access is granted as a list of these shelves. The easiest start for a newcomer is to issue yourself a token with `scopes='*'` (access to every shelf — handy for admin and tests) and narrow the rights later, once it is clear who needs what.

**Scope** = the first folder of a path in the vault. The allowed list is `services/memory_mcp/path_guard.py` (`ALLOWED_SCOPES`):

| Scope | What it stores |
|---|---|
| `strategy` / `system` | strategy, system notes |
| `personal` | about the person: name, skills, experience, life situations |
| `daily` / `metrics` | daily logs, metrics |
| `decisions` | architectural/product decisions |
| `projects` | business: accounting, contracts, policies, correspondence, commercial secrets |
| `external` / `knowledge` | external sources, research, articles, reproducible processes |
| `tasks` | tasks |
| `error-patterns` | bugs and their fixes |
| `inbox` | incoming, unsorted |

**RBAC:** each agent has a token in `agent_tokens` with `can_read_scopes` / `can_write_scopes`. `*` = access to any scope. Tokens are issued by `scripts/issue-agent-token.py` (the raw secret is printed once; the DB stores its sha256).

---

## Hybrid recall, dual-write, inter-agent

<details>
<summary><b>Hybrid recall</b> — semantic search, not grep</summary>

`memory_router-mcp` is not grep, but semantic search:

1. **Semantic** — embed the query (e5, with the correct `query:`/`passage:` prefixes) → cosine over pgvector.
2. **Lexical** — a full-text signal.
3. **Fusion (RRF)** — merging semantic+lexical ranks.
4. **Rerank** — reordering the top candidates.
5. **Cross-link** — related notes (`cross_link.py`).

A query-embedding cache (`memory_router_mcp/cache.py`) and per-source weights (`source_weights.py`) exist for speed and relevance.

</details>

<details>
<summary><b>dual-write</b> — write policy</summary>

- **dual-write:** important things are written to TWO places at once — a local canonical `.md` (in the agent's workspace) **and** the shared layer via `memory-mcp`. Idempotent by sha256 (a repeated body is a no-op). The local `.md` is primary; second_brain is shared across the team.
- **recall before writing** — so as not to breed duplicates.
- **write immediately** — compaction / end of session do NOT flush knowledge automatically.

The full "what and when to write" policy lives in `labops-agent-architecture` (`SECONDBRAIN_WRITE_RULES.md`, @-imported into each agent's CLAUDE.md).

</details>

<details>
<summary><b>Swarm coordination (inter-agent)</b> — signed webhooks</summary>

Agents poke each other through **inter-agent webhooks** (not directly):

- the sender puts a message into `swarm_outbox` (via `agent_router-mcp`);
- `agent_router-worker` delivers it to the recipient, statuses `pending|delivered|acked|failed`;
- **5 retries** with exponential backoff, then `failed` (a manual replay is needed);
- requests are signed with **HMAC** (`x-hermes-signature`/`x-hermes-timestamp`, secrets in `migrations/004_hmac_secrets.sql` + `issue-hmac-secret.py`), plus Bearer tokens.

Details — `docs/INTER-AGENT-WEBHOOKS.md`.

</details>

---

## Write tools

| Tool | Default scope | What it records |
|---|---|---|
| `create_decision_note` | `decisions` | architectural/product decisions, API contracts, rules |
| `create_error_pattern_note` | `error-patterns` | a bug + its fix + how not to repeat it |
| `create_external_note` | `external` | external sources/research (+ `source_url`) |
| `create_personal_note` | `personal` | about the person |
| `create_project_note` | `projects` | about the business/project |
| `append_daily_log` | `daily` | daily progress |
| `create_handoff` | — | a flush before compaction / at the end of a session |
| `supersede_decision` | `decisions` | an outdated decision |

Recall: `recall(...)`. Coordination: `agent_router_*`. Tasks: `task_*`.

---

## Installation & deployment

<details>
<summary><b>Native install (Ubuntu 22.04, no Docker)</b></summary>

Requirements: **Ubuntu 22.04**, root/sudo. No Docker — native (apt + venv + systemd).

```bash
sudo bash scripts/install.sh
```

Idempotent steps: platform check → apt (Python 3.11, Postgres 16 + pgvector) → system user `second_brain` → `/opt/second_brain` + venv → role/DB + `vector` extension → secrets (0600) → migrations → preload the embedding model (`multilingual-e5-large`, ~1.3 GB) → render and install the systemd units → `systemctl enable --now` → **smoke-test** → print the admin token.

**Dependency on the other repos:**
- The canonical install order is `labops-agent-architecture` → `labops-tg-plugin` → `labops-second-brain` — but these are three **separate** `install.sh` scripts, each run by the operator. `labops-agent-architecture`'s `install.sh` only **clones** this repo to `~/labops-second-brain`; it does **not** run `scripts/install.sh` for you. You install this repo yourself, either manually (`sudo bash scripts/install.sh`) or by handing it to a Claude Code agent with the `AGENT.md` prompt — see step 1 above.
- If this repo (or any of the three `labops-*` repos) is private, cloning it standalone (or letting `labops-agent-architecture` clone it) on a machine with no `gh` CLI and no SSH key configured requires a `GITHUB_TOKEN` env var (fine-grained PAT, `Contents: Read` on this repo, issued from the repo-owner GitHub account).
- If **agents already exist** on the machine (`labops-agent-architecture` is installed) — the installer auto-connects them via `scripts/connect-agents.sh`: for every workspace under `~/.claude-lab/*/.claude` still carrying the `CHANGE_ME` placeholder it issues a real token (scopes from the agent's `agent.env`) and patches **both** `agent.env` and `.mcp.json` (with `*.bak-connect` backups; agents that already hold a real token are left alone). Restart the agent services afterwards (`systemctl restart claude-agent-<name>`). Opt out with `SKIP_AGENT_CONNECT=1`; re-run standalone any time: `sudo bash scripts/connect-agents.sh`.

The install is considered successful only when the **smoke-test** at the end is green.

A manual, human-driven walkthrough (no Claude Code agent required) lives in [`docs/setup.md`](docs/setup.md).

</details>

<details>
<summary><b>Troubleshooting</b> — the smoke-test gate and <code>SKIP_SMOKE_GATE</code></summary>

**The smoke-test (or the embedding-probe) fails the install.** At the very end `install.sh` runs `smoke-test.sh` (live MCP services + DB), and at step 11 it checks that the embedding model really computes a vector. Any failure is a **HARD stop** by default (`die`), and the install is considered unconfirmed. This is intentional: better a red gate than a "green" install with silently broken recall.

Diagnose: `journalctl -u 'second_brain-*' -n 200`, then re-run `sudo bash scripts/install.sh` (idempotent).

**Emergency bypass — `SKIP_SMOKE_GATE=1`.** If you need to push the install through despite a failing gate (e.g. the network to the service has not come up yet and you are fixing it separately), run:

```bash
sudo SKIP_SMOKE_GATE=1 bash scripts/install.sh
```

> [!IMPORTANT]
> `SKIP_SMOKE_GATE=1` turns a smoke-test and embedding-probe failure into a **warning** instead of a stop. Use it only deliberately and temporarily: an install with this flag is **not confirmed**, and recall may be degraded to lexical-only. Remove the flag and re-run as soon as the cause is fixed.

</details>

---

## Env & ports

The full reference is [`.env.example`](.env.example). The essentials:

| Variable | Purpose |
|---|---|
| `MCP_MEMORY_PORT` / `MCP_MEMORY_ROUTER_PORT` / `MCP_AGENT_ROUTER_PORT` / `MCP_TASK_PORT` | server ports (5001/5002/5000/5003) |
| `SERVICE_USER` | system user (`second_brain`) |
| `INSTALL_DIR` | install directory (`/opt/second_brain`) |
| `WEBHOOK_BEARER_FILE` / `WEBHOOK_HMAC_SECRET_FILE` | inter-agent auth secrets |
| `SECOND_BRAIN_TOOLS` | tool-gating (`core` by default) |

> `.env.example` also documents the variables of adjacent layers (agents/skills/installer from `labops-agent-architecture`) — it is the full ecosystem reference; for the brain itself the ones listed above are enough. See the Quick Start block at the top of [`.env.example`](.env.example).

**Tests:**

```bash
# inside an activated venv with dependencies
python -m pytest tests/ -q
```

`scripts/install.sh` runs `smoke-test.sh` at the end of the install (live services + DB). The unit/contract tests (`tests/`, 400+) cover scopes, RBAC, tool-gating, recall, HMAC, agent_router. `scripts/gbrain_doctor.py` / `scripts/check_env_sync.py` are environment diagnostics.

---

## Data & privacy

**Self-hosted by design.** second_brain runs on the operator's own server / VPS — all memory data (Postgres + the file vault) stays on their infrastructure. There is no telemetry and no analytics callback.

The only outbound network calls are one-time model downloads from the configured model hub (HuggingFace, used by FastEmbed):

| Endpoint | Purpose | When |
|---|---|---|
| `huggingface.co` / `cdn-lfs.huggingface.co` | Download the embedding model (`intfloat/multilingual-e5-large`) and the reranker (`jinaai/jina-reranker-v2-base-multilingual`) via FastEmbed / `huggingface_hub` | First run only — then cached and served offline |
| Operator-configured agent gateways (`AGENT_GATEWAYS`) | HMAC-signed inter-agent webhooks for swarm coordination | Optional; only to hosts you configure (typically localhost / your own agents) |

After the models are downloaded, embeddings and reranking run **fully locally** on the host CPU — recall never sends note text to an external service. There is no LLM-provider call: contextual chunking is computed locally without an API (see `services/ingest_worker/context.py`).

> [!IMPORTANT]
> Your memory content — notes, vault files, and embeddings — never leaves the host. The Postgres database is local and embeddings are computed locally; the model hub only ever receives a model-file request, never your data.

Secrets (DB password, agent tokens, HMAC keys) live in `.env` / the vault with `chmod 600` and are never committed.

---

## Part of labops

| Repository | Role | Link |
|---|---|---|
| [`labops-tg-plugin`](https://github.com/dediukhinpa/labops-tg-plugin) | Telegram channel into an agent session | independent |
| **labops-second-brain** (this) | the shared brain: memory + recall + coordination | agents reach it over MCP |
| [`labops-agent-architecture`](https://github.com/dediukhinpa/labops-agent-architecture) | agent workspaces, autostart, Developer + the agent-creation skill | registers tokens here, writes to L4 |

---

## License

Proprietary — © 2026 LabOps.ai. All rights reserved. See [LICENSE](./LICENSE).
