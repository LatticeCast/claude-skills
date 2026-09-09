# Prepare — Write Runner Scripts

After planning creates tickets in LatticeCast PM, prepare the runner scripts before starting bees.

**IMPORTANT: Do NOT `cp` from example-scripts/. Write each script file from scratch**, referencing `example-scripts/` as a pattern guide. Each project may need different context, skills, test commands, or bee pipeline steps.

## Step 1: Create directories

```bash
mkdir -p .tmp/agentic-hive .tmp/out
```

## Step 2: Write each script

Read the example scripts in `.agent-skills/agent/agentic-hive/example-scripts/` to understand the patterns, then **write customized versions** for this project:

### 2a. `run.sh` — project-specific wrapper
- Set `TABLE_ID` for this project's PM table
- Call `start.sh` with project dir, max cycles, num workers

### 2b. `start.sh` — tmux session setup
- Validate PM is running
- Kill existing session
- Start queen in tmux window 0

### 2c. `stop.sh` — kill session
- Kill tmux session, clean up lock files

### 2d. `queen.sh` — pure rule-based task dispatch (NO LLM)
- Cache column IDs at startup (`_col_cache.json`)
- Recover orphaned in_progress tickets
- Loop: query todo → spawn bees → poll PM until merged/debugging → cleanup

### 2e. `bee.sh` — bash infra + LLM code
- Extract row_id from task description
- Set status to `in_progress` immediately (bash, not LLM)
- Build context from AGENTS.md (with CLAUDE.md fallback), README.md, skills, ticket doc
- Pipeline: implement → test → review → merge → merged
- PM status updates via bash helpers (never LLM)
- Sources `llm.sh` for the actual LLM call — don't inline a provider CLI here

### 2f. LLM adapter helpers — copy, don't rewrite

Copy these three files as-is from `example-scripts/`:

- `llm.sh` — selects and runs `LLM_PROVIDER=claude|codex`
- `format_claude_stream.py` — formats Claude stream-json events
- `format_codex_stream.py` — formats Codex JSONL events

Provider-specific CLI details belong in `llm.sh`; `bee.sh` stays
provider-neutral.

### 2g. `.env` — per-project values

Write `.tmp/agentic-hive/.env` from `.env.example`:

```bash
LC_API=http://localhost:13491/api/v1
PM_USER=lattice
PM_PASS=
TABLE_ID=pm
WORKSPACE_ID=<uuid>
PROJECT_DIR=/abs/path/to/project
SKILLS_DIR=/abs/path/to/project/.agent-skills
LLM_PROVIDER=claude
LLM_PROJECT_DIR=/abs/path/to/project
HIVE_VERIFY_CMD=<project check, e.g. docker compose exec -T e2e pytest . -q>
MONITOR_CODEX_SESSION_ID=
# CLAUDE_MODEL=sonnet
# CODEX_MODEL=gpt-5.6-codex
```

That's it. The helpers (`pm_*`, `lc_*`) are sourced from the skill,
not duplicated per project:

```bash
# at the top of queen.sh / bee.sh:
set -a
source "${SCRIPT_DIR}/.env"
set +a
source "${SKILLS_DIR}/developing/project-management/pm_tool.sh"
# pm_tool.sh auto-sources its bundled lc_api.sh
```

### 2h. Monitor configuration

Read [monitor.md](monitor.md) before selecting a monitor. For the Codex cron
bridge, write `monitor-cron.sh` from the example and set
`MONITOR_CODEX_SESSION_ID`. Do not automate terminal input with `send-keys` or
`C-m`.

## Customization points per project

When writing scripts, tailor these to the specific project:

| What | Customize |
|------|-----------|
| **Context files** | Which files to load (AGENTS.md, CLAUDE.md, README.md, .tmp/llm*.md) |
| **Skills loaded** | Which `Skill(developing-*)` to include in bee prompt |
| **Test commands** | FE: svelte-check, build. BE: pytest, ast.parse. Or project-specific |
| **Num workers** | 1 for simple tasks, 2-3 for parallel stories |
| **Bee prompt** | Task-specific rules, file restrictions, coding patterns |

## File layout after prepare

```
.tmp/agentic-hive/
├── .env                    ← per-project: LC_API, WORKSPACE_ID, TABLE_ID, …
├── .env.example            ← template for the local .env
├── run.sh                  ← bash run.sh — calls start.sh
├── start.sh                ← tmux session setup
├── stop.sh                 ← kill session
├── queen.sh                ← pure rule-based task dispatch
├── bee.sh                  ← bash infra + LLM code
├── llm.sh                  ← Claude/Codex provider adapter
├── format_claude_stream.py ← Claude stream-json formatter
├── format_codex_stream.py  ← Codex JSONL formatter
└── monitor-cron.sh         ← optional cron → Codex resume bridge
```

PM/LC helpers (`pm_*`, `lc_*`) live in the skill submodule, not in
`.tmp/agentic-hive/`. Scripts source them from `${SKILLS_DIR}`.

## Checklist before running

- [ ] LatticeCast PM running (`curl localhost:13491/api/v1/status`)
- [ ] `TABLE_ID` set in `.tmp/agentic-hive/.env`
- [ ] All 5 written scripts + the 3 copied LLM helpers in place, all `chmod +x`
- [ ] `_col_cache.json` will be auto-created by queen at startup
