#!/bin/bash
# bee.sh — Sequential pipeline: each step is a fresh llm_run() call
# Usage: bash bee.sh <project_dir> <worker_id> [task_description]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
if [ -f "${ENV_FILE}" ]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi
source "${SCRIPT_DIR}/llm.sh"

PROJECT_DIR="${1:?Usage: bee.sh <project_dir> <worker_id> [task_description]}"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
# --show-toplevel returns the WORKTREE root, and the queen always hands this
# script a story worktree. Submodules are not checked out in a worktree, so
# the SKILLS_DIR fallback below would resolve to an empty .agent-skills and
# read_skill_first would exit 1 on the first skill. --git-common-dir points
# at the real repository, where the submodule is populated.
REPO_ROOT="$(git -C "${PROJECT_DIR}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null | xargs dirname 2>/dev/null || printf '%s' "${PROJECT_DIR}")"
export SKILLS_DIR="${SKILLS_DIR:-${REPO_ROOT}/.agent-skills}"
export LLM_PROVIDER="${LLM_PROVIDER:-${LLM_BACKEND:-claude}}"
# The queen passes the persistent story worktree, never the repository root.
# Keep provider commands in that same worktree so each ticket sees every prior
# commit for its story.
export LLM_PROJECT_DIR="${LLM_PROJECT_DIR:-$PROJECT_DIR}"
source "${SKILLS_DIR}/developing/project-management/pm_tool.sh"
WORKER_ID="${2:?Worker ID required}"
TASK_DESC="${3:-}"
PM_USER="${PM_USER:-claude}"
PM_PASS="${PM_PASS:-}"
# row_id is parsed out of TASK_DESC below (`row_id=NN`) so each ticket
# gets its own log file: worker_<wid>_<row_id>.log. Easier to triage a
# specific failure than scrolling through a shared worker_<wid>.log.
ROW_ID=$(echo "$TASK_DESC" | grep -oP 'row_id=\K[0-9]+' || echo "0")
LOG_FILE="${PROJECT_DIR}/.tmp/out/worker_${WORKER_ID}_${ROW_ID}.log"
GIT_LOCK="${PROJECT_DIR}/_git.lock"

mkdir -p "${PROJECT_DIR}/.tmp/out"

log() {
  echo "$(date '+%H:%M:%S') [W${WORKER_ID}] $1" | tee -a "$LOG_FILE"
}

# Retry, and never abort the pipeline on a failed status write. PM is remote,
# so one timeout now and then is expected; losing a finished ticket to it is
# not. A ticket died exactly this way: verification passed and the commit was
# made, then a single pm_set_status call failed a second later, the ERR trap
# fired, and a completed ticket was flipped to `debugging`.
#
# Use this for every status write from `in_progress` onward. The gates above
# it keep pm_set_status: before the ticket is claimed, failing loudly is right.
set_status() {
  local rid="$1" st="$2" i
  for i in 1 2 3; do
    if pm_set_status "$rid" "$st" >/dev/null 2>&1; then return 0; fi
    sleep $((i * 3))
  done
  log "warn: could not set status=${st} on ${rid} after 3 tries -- continuing"
  return 0
}

step() {
  local step_name="$1"
  local prompt="$2"
  log "Step: ${step_name}..."
  # llm_run() streams progress from the configured LLM_PROVIDER into
  # $LOG_FILE. Provider changes stay inside llm.sh.
  #
  # Watchdog: the backend has been observed to hang silently after a few
  # minutes (Agent/Explore sub-agent stall or API hangup that doesn't
  # surface in the pipe). Sample the log file every 30s; kill the
  # process if it hasn't grown for 120s. ERR trap then flips the row
  # to `debugging` and the queen advances — trading 120s detection for
  # 780s of otherwise-wasted budget.
  llm_run "${prompt}" "$LOG_FILE" &
  local pipe_pid=$!

  (
    local last=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
    local stuck=0
    while kill -0 "$pipe_pid" 2>/dev/null; do
      sleep 30
      local cur=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
      if [ "$cur" -eq "$last" ]; then
        stuck=$((stuck + 30))
        if [ "$stuck" -ge 120 ]; then
          log "Watchdog: no log growth for 120s — killing ${LLM_PROVIDER} provider"
          llm_stop "$pipe_pid" TERM
          sleep 2
          llm_stop "$pipe_pid" KILL
          break
        fi
      else
        last=$cur
        stuck=0
      fi
    done
  ) &
  local watchdog_pid=$!

  local llm_status=0
  wait "$pipe_pid" 2>/dev/null || llm_status=$?
  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
  return "$llm_status"
}

# If any step fails, signal BLOCKED and exit
trap 'log "Pipeline failed."; pm_set_status "${ROW_ID}" "debugging"; pm_append_doc "${ROW_ID}" "W${WORKER_ID} BLOCKED — pipeline failed"; exit 1' ERR

log "Worker ${WORKER_ID} starting..."
[ -n "$TASK_DESC" ] && log "Task: ${TASK_DESC}"

# ─── Phase 1: Extract row_id from task desc ────────────────────────────────
cd "$PROJECT_DIR" || exit 1
ROW_ID=$(echo "$TASK_DESC" | grep -oP 'row_id=\K[0-9]+' || echo "")

if [ -z "$ROW_ID" ]; then
  log "ERROR: No row_id in task desc"
  echo "BLOCKED" > "$TRIGGER_FILE"
  exit 1
fi

# ─── Phase 2: Rule-based PM context gate (before any worktree mutation) ────
# pm_tool.sh uses lc_api.sh's curl wrapper. It rejects an orphan issue, a
# non-story parent, or a ticket/story document missing the required design
# evidence. No LLM sees or compensates for an invalid ticket.
if ! PARENT_RN=$(pm_require_hive_context "${ROW_ID}"); then
  log "ERROR: invalid hive ticket context; refusing claim"
  pm_set_status "${ROW_ID}" "debugging"
  pm_append_doc "${ROW_ID}" "W${WORKER_ID} BLOCKED — missing verified story parent or required planning context"
  exit 1
fi
EXPECTED_STORY_BRANCH="story/story-${PARENT_RN}"
if [ "$(git branch --show-current)" != "$EXPECTED_STORY_BRANCH" ]; then
  log "ERROR: verified parent requires ${EXPECTED_STORY_BRANCH} story worktree"
  pm_set_status "${ROW_ID}" "debugging"
  exit 1
fi
TICKET_DOC=$(pm_read_ticket_doc "${ROW_ID}")
STORY_DOC=$(pm_read_ticket_doc "${PARENT_RN}")
log "Issue ${ROW_ID} and parent story ${PARENT_RN} docs verified"

# ─── Phase 3: Clean only after verified scope + dependency ──────────────────
log "Cleaning verified story worktree..."
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  git reset --hard HEAD 2>&1 | tee -a "$LOG_FILE"
  git clean -fd 2>&1 | tee -a "$LOG_FILE"
  log "Clean slate restored."
fi

# ─── Phase 4: Claim, then build context ─────────────────────────────────────
set_status "${ROW_ID}" "in_progress"
pm_append_doc "${ROW_ID}" "Picked up by W${WORKER_ID}; issue and parent story ${PARENT_RN} context verified"

CONTEXT=""

for f in AGENT.md AGENTS.md CLAUDE.md README.md; do
  [ -f "${PROJECT_DIR}/${f}" ] && CONTEXT="${CONTEXT}
--- ${f} ---
$(head -200 "${PROJECT_DIR}/${f}")
"
done

# Skill gate: skills are loaded into the first provider prompt before the bee
# is allowed to inspect application code.  A ticket's doc determines the
# additional specialist skills; the complete skill folder is included so the
# worker reads its references, not only the SKILL.md heading.
read_skill_first() {
  # Split these assignments: with set -u, Bash expands skill_dir before
  # the same local command assigns skill.
  local skill="$1"
  local skill_dir="${SKILLS_DIR}/${skill}"
  [ -d "$skill_dir" ] || { log "ERROR: required skill missing: ${skill}"; exit 1; }
  CONTEXT="${CONTEXT}
===== REQUIRED SKILL FIRST: ${skill} ====="
  while IFS= read -r -d '' file; do
    CONTEXT="${CONTEXT}
--- ${file#${SKILLS_DIR}/} ---
$(cat "$file")"
  done < <(find "$skill_dir" -type f \( -name '*.md' -o -name '*.sh' \) -print0 | sort -z)
}

# Every implementation worker reads these before any repository source.
read_skill_first "agent/agentic-hive"
read_skill_first "developing/programming"
read_skill_first "developing/project-management"

# Add the specialist rule set before implementation whenever the ticket scope
# names that surface. The task doc is the authoritative specification.
scope_text="${TASK_DESC} ${TICKET_DOC}"
case "${scope_text,,}" in
  *frontend*|*svelte*|*.svelte*|*.ts*) read_skill_first "developing/svelte" ;;
esac
case "${scope_text,,}" in
  *backend*|*fastapi*|*.py*) read_skill_first "developing/fastapi" ;;
esac
case "${scope_text,,}" in
  *migration*|*postgres*|*sql*) read_skill_first "developing/db-sql" ;;
esac
case "${scope_text,,}" in
  *e2e*|*playwright*|*snapshot*) read_skill_first "developing/e2e" ;;
esac

for f in "${PROJECT_DIR}"/.tmp/llm*.md; do
  [ -f "$f" ] || continue
  CONTEXT="${CONTEXT}
--- $(basename "$f") ---
$(head -200 "$f")
"
done

SHARED="You are Worker ${WORKER_ID}. Dir: ${PROJECT_DIR}

${CONTEXT}

TICKET DOC:
${TICKET_DOC}

PARENT STORY DOC:
${STORY_DOC}

TASK: ${TASK_DESC}

RULES:
- REQUIRED SKILLS ABOVE ARE FIRST. Read every supplied skill section before
  reading or editing repository source; do not begin implementation otherwise.
- ONLY write application code. Do NOT run curl commands to any API or service.
- Status updates are handled by the bash wrapper — never update ticket status yourself.
- Focus ONLY on reading code and implementing the ticket.
- Browser/E2E identity: user=${HIVE_TEST_USER:-<not configured>},
  password=${HIVE_TEST_PASS:-<not configured>}. When configured, use it and
  do not substitute a user named in stale local debug instructions.
- Do NOT run git commit, git add, git merge or git checkout. This wrapper
  commits your work after the pipeline, on the correct branch, with
  "<type>-${ROW_ID}: <ticket title>". If you commit yourself the wrapper finds
  nothing staged and appends "No changes needed" to the ticket doc -- which
  the next bee reads as "this work was never done"."

# ─── Pipeline ────────────────────────────────────────────────────────────────

# Step 1: Implement
step "implement" "${SHARED}

Read relevant source files, then implement the ticket.
Keep changes minimal. ONE ticket only. Follow existing patterns.
After each file change, log what you did."

pm_append_doc "${ROW_ID}" "Implementation step completed"

# Step 2: Test, format, lint
set_status "${ROW_ID}" "testing"
pm_append_doc "${ROW_ID}" "Running tests"

step "test" "${SHARED}

Run tests:
1. Frontend: cd ${PROJECT_DIR}/frontend && npx svelte-check 2>&1 | head -50
2. Frontend: cd ${PROJECT_DIR}/frontend && npm run build 2>&1 | tail -30
3. Backend: python -c 'import ast; ast.parse(open(\"<file>\").read())' for each .py
4. Fix any errors found.
Do NOT commit yet."

pm_append_doc "${ROW_ID}" "Tests completed"

# Step 2b: Programmatic verification gate (bash, not LLM)
#
# The step above is an LLM step. It asks the model to run the checks and fix
# what it finds, and nothing here ever saw the result -- while Step 4 below
# set `merged` unconditionally. So a ticket whose suite was red still ended
# as `merged` and the queen moved on, which is how ticket 61 finished green
# on a failing test. `merged` has to mean a command exited 0, not that the
# model reported success.
#
# Note what the LLM step actually runs: svelte-check, a build, and
# ast.parse per file. ast.parse is a syntax check, not a test -- nothing in
# this pipeline runs the test suite at all unless HIVE_VERIFY_CMD does.
#
# The gate runs before the commit, so a red ticket leaves nothing on the
# story branch; the changes stay in the worktree for the retry to pick up.
#
# HIVE_VERIFY_CMD is the project's own check, run from the story worktree.
# Unset means there is no programmatic gate, and that is said out loud in
# the log and the ticket doc rather than passing quietly.
if [ -n "${HIVE_VERIFY_CMD:-}" ]; then
  log "Verify: ${HIVE_VERIFY_CMD}"
  VERIFY_LOG="${PROJECT_DIR}/.tmp/out/verify_${WORKER_ID}_${ROW_ID}.log"
  if (cd "$PROJECT_DIR" && eval "${HIVE_VERIFY_CMD}") >"$VERIFY_LOG" 2>&1; then
    log "Verify passed"
    pm_append_doc "${ROW_ID}" "Verify passed: ${HIVE_VERIFY_CMD}"
  else
    VERIFY_RC=$?
    log "Verify FAILED (rc=${VERIFY_RC}) -- see ${VERIFY_LOG}"
    # The tail goes in the doc so the next bee reads why it failed instead
    # of only that it did. Bounded: ticket docs are read back in full.
    pm_append_doc "${ROW_ID}" "Verify FAILED (rc=${VERIFY_RC}): ${HIVE_VERIFY_CMD}
$(tail -c 1200 "$VERIFY_LOG")"
    set_status "${ROW_ID}" "debugging"
    log "W${WORKER_ID} stopping: verification failed, ticket left for retry"
    exit 1
  fi
else
  log "No HIVE_VERIFY_CMD set -- 'merged' reflects the LLM self-report only"
  pm_append_doc "${ROW_ID}" "No programmatic verify configured (HIVE_VERIFY_CMD unset)"
fi

# Step 3: Commit + merge (bash, not LLM)
set_status "${ROW_ID}" "review"

while ! mkdir "$GIT_LOCK" 2>/dev/null; do sleep 2; done

TICKET_TITLE=$(echo "$TASK_DESC" | sed 's/ (row_id=.*//' | cut -c1-72)
TYPE_COL=$(python3 -c "import json; print(json.load(open('${PROJECT_DIR}/.tmp/agentic-hive/_col_cache.json')).get('Type',''))" 2>/dev/null || echo "")
TICKET_TYPE=$(pm_row_type "${ROW_ID}" 2>/dev/null || echo "task")

# The ERR trap is off for this block. Under `set -e` any hiccup here aborted
# the pipeline one second after the work was finished and reported only
# "Pipeline failed." -- which is how finished tickets were lost with their
# changes left uncommitted in the worktree. Check each status explicitly and
# say which command failed.
set +e
trap - ERR

git add -A 2>/dev/null
# Never stage the hive's own scratch, env or artefact directories.
git reset -q HEAD .tmp/ .env 2>/dev/null

git diff --cached --quiet
staged=$?

if [ "$staged" -eq 0 ]; then
  log "No changes staged -- nothing to commit"
  pm_append_doc "${ROW_ID}" "No changes needed" || log "warn: doc append failed"
else
  commit_out=$(git commit -m "${TICKET_TYPE}-${ROW_ID}: ${TICKET_TITLE}" 2>&1)
  commit_rc=$?
  if [ "$commit_rc" -eq 0 ]; then
    log "Committed ${TICKET_TYPE}-${ROW_ID}"
    pm_append_doc "${ROW_ID}" "Committed ${TICKET_TYPE}-${ROW_ID}" \
      || log "warn: doc append failed"
  else
    log "COMMIT FAILED (rc=${commit_rc}): ${commit_out}"
    pm_append_doc "${ROW_ID}" "COMMIT FAILED rc=${commit_rc}: ${commit_out}" \
      || log "warn: doc append failed"
    rmdir "$GIT_LOCK" 2>/dev/null
    set_status "${ROW_ID}" "debugging"
    exit 1
  fi
fi

rmdir "$GIT_LOCK" 2>/dev/null || true

# Step 4: Mark merged
set_status "${ROW_ID}" "merged"
pm_append_doc "${ROW_ID}" "W${WORKER_ID} finished"

# ─── Signal complete ─────────────────────────────────────────────────────────
# PM status already set to merged — orchestrator will detect via poll
log "W${WORKER_ID} finished: DONE"
