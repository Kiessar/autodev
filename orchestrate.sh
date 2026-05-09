#!/usr/bin/env bash
# orchestrate.sh — runs the autonomous agent pipeline
#
# Stages: po → planner → issue → developer → reviewer → git → release
#
# Environment overrides:
#   REPO_ROOT=/path/to/repo     the codebase to work on (required)
#   MAX_TASKS=1                 max implementation tasks per run
#   MAX_RUNTIME_SECS=2700       hard time limit (default: 45 min)
#   MODEL=claude-sonnet-4-6     fallback model for all stages
#   MODEL_PO=...                override model for PO stage
#   MODEL_PLANNER=...           override model for Planner stage
#   MODEL_ISSUE=...             override model for Issue stage
#   MODEL_DEVELOPER=...         override model for Developer stage
#   MODEL_REVIEWER=...          override model for Reviewer stage
#   MODEL_GIT=...               override model for Git stage
#   MODEL_RELEASE=...           override model for Release stage
#   SKIP_STAGES="issue git"     space-separated stages to skip
#   DRY_RUN=1                   print prompts without calling claude
#
# Usage:
#   REPO_ROOT=/path/to/repo ./orchestrate.sh
#   # or via the lock wrapper:
#   REPO_ROOT=/path/to/repo run_agent.sh orchestrate.sh

set -euo pipefail
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
AGENTS_DIR="$PROJECT_ROOT/.agents"
LOG_FILE="$PROJECT_ROOT/state/agent_log.md"
PROGRESS_FILE="$PROJECT_ROOT/state/progress.md"

REPO_ROOT="${REPO_ROOT:-}"
MAX_TASKS="${MAX_TASKS:-1}"
MAX_RUNTIME_SECS="${MAX_RUNTIME_SECS:-2700}"
MODEL="${MODEL:-claude-sonnet-4-6}"
SKIP_STAGES="${SKIP_STAGES:-}"
DRY_RUN="${DRY_RUN:-0}"

# Per-stage model defaults
MODEL_SCRAPER_BUILDER="${MODEL_SCRAPER_BUILDER:-claude-sonnet-4-6}"
MODEL_PO="${MODEL_PO:-claude-haiku-4-5-20251001}"
MODEL_PLANNER="${MODEL_PLANNER:-claude-haiku-4-5-20251001}"
MODEL_ISSUE="${MODEL_ISSUE:-claude-haiku-4-5-20251001}"
MODEL_DEVELOPER="${MODEL_DEVELOPER:-claude-sonnet-4-6}"
MODEL_REVIEWER="${MODEL_REVIEWER:-claude-haiku-4-5-20251001}"
MODEL_GIT="${MODEL_GIT:-claude-haiku-4-5-20251001}"
MODEL_RELEASE="${MODEL_RELEASE:-claude-haiku-4-5-20251001}"

START_TIME=$(date +%s)
TASKS_COMPLETED=0

# ── Validate ──────────────────────────────────────────────────────────────────

if [[ -z "$REPO_ROOT" ]]; then
  echo "ERROR: REPO_ROOT is not set. Example:" >&2
  echo "  REPO_ROOT=/home/chris/claudPlayGround/eventExtractor ./orchestrate.sh" >&2
  exit 1
fi

if [[ ! -d "$REPO_ROOT" ]]; then
  echo "ERROR: REPO_ROOT does not exist: $REPO_ROOT" >&2
  exit 1
fi

# ── Helpers ───────────────────────────────────────────────────────────────────

log() {
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  local msg="[$ts] [$REPO_ROOT] $*"
  echo "$msg"
  echo "$msg" >> "$LOG_FILE"
}

progress() {
  printf '%s\n' "$*" >> "$PROGRESS_FILE"
}

elapsed() {
  echo $(( $(date +%s) - START_TIME ))
}

should_skip() {
  local stage="$1"
  for s in $SKIP_STAGES; do
    [[ "$s" == "$stage" ]] && return 0
  done
  return 1
}

budget_time_ok() {
  local secs
  secs=$(elapsed)
  if [[ $secs -gt $MAX_RUNTIME_SECS ]]; then
    log "BUDGET: Time limit reached (${secs}s > ${MAX_RUNTIME_SECS}s). Stopping."
    progress "  aborted: time limit (${secs}s)"
    return 1
  fi
  return 0
}

budget_ok() {
  budget_time_ok || return 1
  if [[ $TASKS_COMPLETED -ge $MAX_TASKS ]]; then
    log "BUDGET: Task limit reached ($TASKS_COMPLETED >= $MAX_TASKS). Stopping."
    return 1
  fi
  return 0
}

run_stage() {
  local stage="$1"
  local is_task_stage="${2:-false}"
  local prompt_file="$AGENTS_DIR/${stage}_prompt.md"

  if should_skip "$stage"; then
    log "Skipping stage: $stage (SKIP_STAGES)"
    return 0
  fi

  if [[ ! -f "$prompt_file" ]]; then
    log "ERROR: Missing prompt file: $prompt_file"
    return 1
  fi

  local stage_upper
  stage_upper=$(echo "$stage" | tr '[:lower:]' '[:upper:]')
  local stage_model_var="MODEL_${stage_upper}"
  local stage_model="${!stage_model_var:-$MODEL}"

  local full_prompt
  full_prompt="$(printf \
    'PROJECT_ROOT: %s\nREPO_ROOT: %s\nCURRENT_DATE: %s\nELAPSED_SECS: %s\n\n' \
    "$PROJECT_ROOT" "$REPO_ROOT" "$(date '+%Y-%m-%d %H:%M')" "$(elapsed)")$(
    sed \
      -e "s|{{PROJECT_ROOT}}|$PROJECT_ROOT|g" \
      -e "s|{{REPO_ROOT}}|$REPO_ROOT|g" \
      "$prompt_file"
  )"

  log ">>> Stage start: $stage | model=$stage_model"

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "--- DRY RUN: $stage (model=$stage_model) ---"
    echo "$full_prompt" | head -25
    echo "---"
    log "<<< Stage done (dry run): $stage"
    return 0
  fi

  local stage_ok=true
  local stage_out
  stage_out=$(claude -p "$full_prompt" --model "$stage_model" --dangerously-skip-permissions 2>&1) \
    || stage_ok=false

  # Check for rate limit in output before deciding what to log
  if echo "$stage_out" | grep -qi "you've hit your limit\|rate limit\|quota exceeded"; then
    log "~~~ Stage paused (rate limited): $stage | will retry next run"
    progress "  aborted: rate limited at $stage"
    exit 0
  fi

  if $stage_ok; then
    # Print last 5 lines of stage output as a compact summary
    echo "$stage_out" | tail -5
    log "<<< Stage done: $stage | model=$stage_model | elapsed=$(elapsed)s"
    if [[ "$is_task_stage" == "true" ]]; then
      TASKS_COMPLETED=$(( TASKS_COMPLETED + 1 ))
    fi
    return 0
  else
    echo "$stage_out" | tail -10
    log "!!! Stage failed: $stage | elapsed=$(elapsed)s"
    progress "  failed: $stage"
    return 1
  fi
}

# ── Setup ─────────────────────────────────────────────────────────────────────

mkdir -p \
  "$PROJECT_ROOT/state" \
  "$REPO_ROOT/.ai/active" \
  "$REPO_ROOT/.ai/done" \
  "$REPO_ROOT/.ai/reports" \
  "$REPO_ROOT/.ai/reviews" \
  "$REPO_ROOT/.ai/state"

RUN_DATE=$(date '+%Y-%m-%d %H:%M')
REPO_SHORT=$(basename "$REPO_ROOT")
progress ""
progress "## $RUN_DATE | $REPO_SHORT"

log "========================================"
log "Pipeline start"
log "repo=$REPO_ROOT"
log "max_tasks=$MAX_TASKS | max_runtime=${MAX_RUNTIME_SECS}s | model=$MODEL"
[[ -n "$SKIP_STAGES" ]] && log "skipping: $SKIP_STAGES"
log "========================================"

# ── Pipeline ──────────────────────────────────────────────────────────────────

_pending_urls=$(awk '/^## Pending/{f=1;next} /^## /{f=0} f && /^https?:/' \
  "$REPO_ROOT/new_sources.md" 2>/dev/null | wc -l)
if [[ "$_pending_urls" -gt 0 ]]; then
  run_stage "scraper_builder" || { log "Pipeline stopped: scraper_builder failed"; exit 1; }
  budget_time_ok || exit 0
else
  log "Skipping scraper_builder: queue empty"
fi

# Planning gate: skip po/planner/issue when there is nothing new to plan.
# active task → already in flight, go straight to developer
# empty backlog → nothing to pick
# backlog has tasks → run full planning sequence
_active_count=$(find "$REPO_ROOT/.ai/active" -name "*.md" 2>/dev/null | wc -l)
_backlog_count=$(find "$REPO_ROOT/.ai/plan" -name "*.md" \
  -exec grep -l "status: BACKLOG" {} \; 2>/dev/null | wc -l)

if [[ "$_active_count" -gt 0 ]]; then
  log "Planning gate: task in flight — skipping po/planner/issue (active=$_active_count)"
  progress "  planning: skipped (task in flight)"
elif [[ "$_backlog_count" -eq 0 ]]; then
  log "Planning gate: backlog empty — skipping po/planner/issue"
  progress "  planning: skipped (backlog empty)"
else
  log "Planning gate: selecting next task (backlog=$_backlog_count)"
  run_stage "po"        || { log "Pipeline stopped: po stage failed"; exit 1; }
  budget_ok             || exit 0
  run_stage "planner"   || { log "Pipeline stopped: planner stage failed"; exit 1; }
  budget_ok             || exit 0
  run_stage "issue"     || { log "Pipeline stopped: issue stage failed"; exit 1; }
  budget_ok             || exit 0
fi

run_stage "developer" true || { log "Pipeline stopped: developer stage failed"; exit 1; }
budget_time_ok        || exit 0

run_stage "reviewer"  || { log "Pipeline stopped: reviewer stage failed"; exit 1; }
budget_time_ok        || exit 0

run_stage "git"       || { log "Pipeline stopped: git stage failed"; exit 1; }
budget_time_ok        || exit 0

run_stage "release"   || { log "Release gate failed (non-fatal)"; progress "  release: gate error"; }

# ── Done ──────────────────────────────────────────────────────────────────────

progress "  done: elapsed=$(elapsed)s tasks=$TASKS_COMPLETED"

log "========================================"
log "Pipeline complete | elapsed=$(elapsed)s | tasks_completed=$TASKS_COMPLETED"
log "========================================"
