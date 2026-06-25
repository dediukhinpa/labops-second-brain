# labops-second-brain

> **Общий мозг команды Claude Code-агентов.** Self-hosted на одном VPS: Postgres 16 + pgvector, набор MCP-серверов (память, гибридный recall, координация роя, задачи) и фоновые воркеры. Markdown-vault как единый источник правды + семантический поиск поверх него. Часть архитектуры **labops** (см. [`labops-tg-plugin`](#связанные-репозитории) и [`labops-agent-architecture`](#связанные-репозитории)).

Это слой **долговременной общей памяти**. Каждый агент держит свою «горячую» память в workspace (`CLAUDE.md`, `hot/`, `warm/`), а `labops-second-brain` — это **L4**: смысловой, общий для всей команды, с поиском по эмбеддингам и строгим разграничением доступа.

---

## Содержание

- [Зачем нужен общий мозг](#зачем-нужен-общий-мозг)
- [Слои памяти](#слои-памяти)
- [Архитектура](#архитектура)
- [MCP-серверы и порты](#mcp-серверы-и-порты)
- [Хранилище: vault + Postgres](#хранилище-vault--postgres)
- [Scopes и RBAC](#scopes-и-rbac)
- [Гибридный recall](#гибридный-recall)
- [dual-write и политика записи](#dual-write-и-политика-записи)
- [Координация роя (inter-agent)](#координация-роя-inter-agent)
- [Инструменты записи](#инструменты-записи)
- [Установка](#установка)
- [Переменные и порты](#переменные-и-порты)
- [Тесты](#тесты)
- [Связанные репозитории](#связанные-репозитории)
- [Лицензия](#лицензия)

---

## Зачем нужен общий мозг

Один агент помнит свою сессию. Команда агентов — нет: знание, добытое одним, недоступно другим, теряется при компакции и не ищется по смыслу. `labops-second-brain` решает это:

| Проблема | Решение |
|---|---|
| Знание заперто в одной сессии | общий слой, доступный всем агентам по MCP |
| Контекст теряется при компакции | важное пишется сразу в vault + БД (dual-write) |
| «Где-то я это уже видел» | семантический recall по эмбеддингам, не grep |
| Кто что может читать/писать | scopes + per-agent токены (RBAC) |
| Рой дёргает друг друга вслепую | inter-agent webhooks с подписью и ретраями |

---

## Слои памяти

```mermaid
flowchart LR
    L1["L1 · Идентичность<br/>CLAUDE.md, rules.md<br/>(в системном промпте)"]
    L2["L2 · Горячая<br/>hot/recent.md, handoff.md<br/>(текущая работа)"]
    L3["L3 · Тёплая<br/>warm/decisions.md<br/>(ротация)"]
    L4["L4 · Общий мозг<br/>labops-second-brain<br/>(vault + pgvector)"]
    L1 --> L2 --> L3 --> L4
```

- **L1–L3 живут в workspace агента** (это слой [`labops-agent-architecture`](#связанные-репозитории)) — личные, быстрые, в контексте сессии.
- **L4 — этот репозиторий** — общий, смысловой, переживает сессии и компакцию. Сюда выгружают решения, ошибки, исследования, заметки о человеке и проекте. Поиск — по смыслу, доступ — по scopes.

---

## Архитектура

```mermaid
flowchart TB
    subgraph agents["Агенты (Claude Code сессии)"]
        A1["агент 1"]; A2["агент 2"]; A3["агент N"]
    end

    subgraph brain["labops-second-brain (один VPS)"]
        MEM["memory-mcp :8767<br/>запись заметок в vault"]
        REC["recall-mcp :8768<br/>гибридный поиск"]
        SW["swarm-mcp :8766<br/>координация роя"]
        TASK["task-mcp :8769<br/>задачи/доска"]
        IW["ingest-worker<br/>чанкинг + эмбеддинги"]
        SWW["swarm-worker<br/>доставка webhooks"]
        PG[("Postgres 16 + pgvector<br/>documents · embeddings ·<br/>agent_tokens · audit ·<br/>swarm_outbox · tasks")]
        VAULT["vault/ (Markdown SSOT)"]
    end

    A1 & A2 & A3 -- "MCP (HTTP, Bearer/HMAC)" --> MEM & REC & SW & TASK
    MEM --> VAULT
    MEM --> PG
    IW -- "следит за vault, считает эмбеддинги" --> PG
    REC --> PG
    SW --> SWW --> A1
```

- **MCP-серверы** — точки входа для агентов (HTTP, аутентификация Bearer-токеном или HMAC-подписью).
- **ingest-worker** — следит за изменениями vault, режет документы на чанки с контекстом и считает эмбеддинги (FastEmbed `multilingual-e5-large`).
- **swarm-worker** — асинхронно доставляет inter-agent webhooks с ретраями.
- **core-mcp** — режим, агрегирующий memory+swarm+task в одном процессе (см. tool-gating ниже).

---

## MCP-серверы и порты

| Сервер | Порт | Назначение | systemd |
|---|---|---|---|
| `memory-mcp` | **8767** | запись заметок в vault (decision/runbook/error/external/personal/project), дедуп по sha256 | `memory-mcp.service` |
| `recall-mcp` | **8768** | гибридный поиск (semantic + lexical + rerank), кросс-линки | `recall-mcp.service` |
| `swarm-mcp` | **8766** | координация роя: outbox, inter-agent сообщения | `swarm-mcp.service` |
| `task-mcp` | **8769** | задачи, доска, supervisor агентов | `task-mcp.service` |
| `ingest-worker` | — | чанкинг + эмбеддинги (watermark по изменениям) | `ingest-worker.service` |
| `swarm-worker` | — | доставка webhooks (5 ретраев, exp backoff) | `swarm-worker.service` |

**tool-gating:** переменная `SECOND_BRAIN_TOOLS` (дефолт `core`) определяет, какие инструменты сервер отдаёт клиентам. Новый memory-инструмент виден только если он есть в `CORE_TOOLS_BY_SERVER` (`services/shared/tool_gating.py`), а не только в коде.

---

## Хранилище: vault + Postgres

- **vault/** — каталог Markdown-файлов, **единственный источник правды** (human-readable, git-friendly). Каждая заметка = `.md` с YAML-frontmatter.
- **Postgres + pgvector** — индекс поверх vault: `documents`, `embeddings` (вектор на чанк), `agent_tokens` (RBAC), `audit` (кто что писал), `swarm_outbox`, `tasks`. БД — производная; правда — в vault.

Документ проходит: запись через `memory-mcp` → файл в vault + строка в `documents` → `ingest-worker` режет на чанки и считает эмбеддинги → доступен в `recall`.

---

## Scopes и RBAC

**Scope** = первая папка пути в vault. Разрешённый список — `services/memory_mcp/path_guard.py` (`ALLOWED_SCOPES`):

| Scope | Что хранит |
|---|---|
| `10-strategy` / `10-system` | стратегия, системные заметки |
| `15-personal` | про человека: ФИО, навыки, опыт, жизненные ситуации |
| `20-daily` / `20-metrics` | дневные логи, метрики |
| `30-decisions` | архитектурные/продуктовые решения |
| `40-projects` | бизнес: бухгалтерия, договора, регламенты, переписка, коммтайна |
| `50-external` / `50-knowledge` | внешние источники, исследования, статьи |
| `60-tasks` | задачи |
| `70-runbooks` | воспроизводимые процессы |
| `80-error-patterns` | баги и их фиксы |
| `90-inbox` | входящее, не разобранное |

**RBAC:** у каждого агента — токен в `agent_tokens` с `can_read_scopes` / `can_write_scopes`. `*` = доступ к любому scope. Токены выдаёт `scripts/issue-agent-token.py` (raw-секрет печатается один раз, в БД — sha256).

---

## Гибридный recall

`recall-mcp` не grep, а смысловой поиск:

1. **Semantic** — эмбеддинг запроса (e5, с правильными префиксами `query:`/`passage:`) → cosine по pgvector.
2. **Lexical** — полнотекстовый сигнал.
3. **Fusion (RRF)** — объединение рангов semantic+lexical.
4. **Rerank** — переупорядочивание top-кандидатов.
5. **Cross-link** — связанные заметки (`cross_link.py`).

Кэш запросов-эмбеддингов (`recall_mcp/cache.py`) и веса источников (`source_weights.py`) — для скорости и релевантности.

---

## dual-write и политика записи

- **dual-write:** важное пишется в ДВА места сразу — локальный canonical `.md` (в workspace агента) **и** общий слой через `memory-mcp`. Идемпотентно по sha256 (повтор тела — no-op). Локальный `.md` — главный, second_brain — общий для команды.
- **recall перед записью** — чтобы не плодить дубли.
- **пиши сразу** — компакция/конец сессии НЕ выгружают знание автоматически.

Полная политика «что и когда писать» — в `labops-agent-architecture` (`SECONDBRAIN_WRITE_RULES.md`, @-импортится в CLAUDE.md каждого агента).

---

## Координация роя (inter-agent)

Агенты дёргают друг друга через **inter-agent webhooks** (не напрямую):

- отправитель кладёт сообщение в `swarm_outbox` (через `swarm-mcp`);
- `swarm-worker` доставляет его получателю, статусы `pending|delivered|acked|failed`;
- **5 ретраев** с экспоненциальным backoff, потом `failed` (нужен ручной replay);
- запросы подписаны **HMAC** (`x-hermes-signature`/`x-hermes-timestamp`, секреты в `migrations/004_hmac_secrets.sql` + `issue-hmac-secret.py`), плюс Bearer-токены.

Подробности — `docs/INTER-AGENT-WEBHOOKS.md`.

---

## Инструменты записи

| Инструмент | Scope по умолчанию | Что фиксирует |
|---|---|---|
| `create_decision_note` | `30-decisions` | архитектурные/продуктовые решения, API-контракты, правила |
| `create_runbook_note` | `70-runbooks` | воспроизводимые процессы |
| `create_error_pattern_note` | `80-error-patterns` | баг + фикс + как не повторить |
| `create_external_note` | `50-external` | внешние источники/исследования (+ `source_url`) |
| `create_personal_note` | `15-personal` | про человека |
| `create_project_note` | `40-projects` | про бизнес/проект |
| `append_daily_log` | `20-daily` | дневной прогресс |
| `create_handoff` | — | выгрузка перед компакцией/в конце сессии |
| `supersede_decision` | `30-decisions` | устаревшее решение |

Recall: `recall(...)`. Координация: `swarm_*`. Задачи: `task_*`.

---

## Установка

Требования: **Ubuntu 22.04**, root/sudo. Без Docker — нативно (apt + venv + systemd).

```bash
sudo bash scripts/install.sh
```

Идемпотентные шаги: проверка платформы → apt (Python 3.11, Postgres 16 + pgvector, Caddy) → системный пользователь `second_brain` → `/opt/second_brain` + venv → роль/БД + расширение `vector` → секреты (0600) → миграции → предзагрузка модели эмбеддингов (`multilingual-e5-large`, ~1.3 ГБ) → рендер и установка systemd-юнитов → `systemctl enable --now` → **smoke-test** → печать admin-токена.

**Зависимость от других репо:**
- Если на машине **уже есть агенты** (поставлен [`labops-agent-architecture`](#связанные-репозитории)) — установщик до-регистрирует их токены (`issue-agent-token.py`), не перетирая существующие.
- Если мозг ставится **первым** — токены агентам выдаются позже, при установке агентов.

Установка считается успешной только при зелёном **smoke-test** в конце.

---

## Переменные и порты

Полный референс — [`.env.example`](.env.example). Ключевое:

| Переменная | Назначение |
|---|---|
| `MCP_MEMORY_PORT` / `MCP_RECALL_PORT` / `MCP_SWARM_PORT` / `MCP_TASK_PORT` | порты серверов (8767/8768/8766/8769) |
| `SERVICE_USER` | системный пользователь (`second_brain`) |
| `INSTALL_DIR` | каталог установки (`/opt/second_brain`) |
| `DOMAIN` / `ACME_EMAIL` | для Caddy + TLS (опционально) |
| `WEBHOOK_BEARER_FILE` / `WEBHOOK_HMAC_SECRET_FILE` | секреты inter-agent auth |
| `SECOND_BRAIN_TOOLS` | tool-gating (`core` по умолчанию) |

> `.env.example` документирует и переменные смежных слоёв (агенты/скиллы/инсталлятор из `labops-agent-architecture`) — это полный референс экосистемы; для самого мозга достаточно перечисленных выше.

---

## Тесты

```bash
# в активированном venv с зависимостями
python -m pytest tests/ -q
```

`scripts/install.sh` прогоняет `smoke-test.sh` в конце установки (живые сервисы + БД). Юнит/контрактные тесты (`tests/`, 400+) проверяют scopes, RBAC, tool-gating, recall, HMAC, swarm. `scripts/gbrain_doctor.py`/`scripts/check_env_sync.py` — диагностика окружения.

---

## Связанные репозитории

| Репозиторий | Роль | Связь |
|---|---|---|
| [`labops-tg-plugin`](#) | Telegram-канал к сессии агента | независим |
| **labops-second-brain** (этот) | общий мозг: память + recall + координация | агенты ходят сюда по MCP |
| [`labops-agent-architecture`](#) | воркспейсы агентов, автостарт, Developer + скилл создания агентов | регистрирует токены здесь, пишет в L4 |

---

## Лицензия

Apache 2.0 — см. [LICENSE](LICENSE).
