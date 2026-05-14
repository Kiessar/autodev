#!/usr/bin/env bash
# orchestrate.sh — runs the autonomous multi-project agent pipeline
#
# Stages: bootstrap → issue → po → planner → developer → reviewer → qa → git → release
#
# Usage:
#   ./orchestrate.sh -p <project>
#   PROJECT_ID=<project> ./orchestrate.sh
#   REPO_ROOT=/path/to/repo GH_REPO=owner/repo ./orchestrate.sh

set -euo pipefail
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
AGENTS_DIR="$PROJECT_ROOT/.agents"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/lib/common.sh"

PROJECT_ID="${PROJECT_ID:-}"
REPO_ROOT="${REPO_ROOT:-}"
GH_REPO="${GH_REPO:-}"
PROJECT_HOME_DIR="${PROJECT_HOME_DIR:-}"
PROJECT_STATE_DIR="${PROJECT_STATE_DIR:-}"
MAX_TASKS="${MAX_TASKS:-1}"
MAX_REVIEWS_PER_RUN="${MAX_REVIEWS_PER_RUN:-2}"
MAX_RUNTIME_SECS="${MAX_RUNTIME_SECS:-2700}"
MODEL="${MODEL:-claude-sonnet-4-6}"
SKIP_STAGES="${SKIP_STAGES:-}"
DRY_RUN="${DRY_RUN:-0}"
FORCE_SYNC="${FORCE_SYNC:-0}"
WORK_BRANCH="${WORK_BRANCH:-develop}"
BASE_BRANCH="${BASE_BRANCH:-main}"
SYNC_INTERVAL_SECS="${SYNC_INTERVAL_SECS:-14400}"
ISSUE_BUFFER_MIN="${ISSUE_BUFFER_MIN:-3}"

MODEL_BOOTSTRAP="${MODEL_BOOTSTRAP:-claude-haiku-4-5-20251001}"
MODEL_PO="${MODEL_PO:-claude-haiku-4-5-20251001}"
MODEL_PLANNER="${MODEL_PLANNER:-claude-haiku-4-5-20251001}"
MODEL_ISSUE="${MODEL_ISSUE:-claude-haiku-4-5-20251001}"
MODEL_DEVELOPER="${MODEL_DEVELOPER:-claude-sonnet-4-6}"
MODEL_REVIEWER="${MODEL_REVIEWER:-claude-haiku-4-5-20251001}"
MODEL_QA="${MODEL_QA:-claude-haiku-4-5-20251001}"
MODEL_GIT="${MODEL_GIT:-claude-haiku-4-5-20251001}"
MODEL_RELEASE="${MODEL_RELEASE:-claude-haiku-4-5-20251001}"

START_TIME="$(date +%s)"
TASKS_COMPLETED=0
REVIEWS_COMPLETED=0

usage() {
  cat <<'EOF'
Usage:
  ./orchestrate.sh -p <project>
  PROJECT_ID=<project> ./orchestrate.sh
  REPO_ROOT=/path/to/repo GH_REPO=owner/repo ./orchestrate.sh
EOF
}

while getopts "p:h" opt; do
  case $opt in
    p) PROJECT_ID="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac
done

if [[ -n "$PROJECT_ID" ]]; then
  load_project_config "$PROJECT_ROOT" "$PROJECT_ID"
elif [[ -n "$REPO_ROOT" ]]; then
  PROJECT_ID="${PROJECT_ID:-$(basename "$REPO_ROOT" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//; s/-*$//')}"
  PROJECT_HOME_DIR="${PROJECT_HOME_DIR:-$(dirname "$REPO_ROOT")}"
  PROJECT_STATE_DIR="${PROJECT_STATE_DIR:-$PROJECT_ROOT/state/projects/$PROJECT_ID}"
  mkdir -p "$PROJECT_STATE_DIR"
else
  echo "ERROR: Provide -p <project> or set REPO_ROOT." >&2
  exit 1
fi

LOG_FILE="$PROJECT_STATE_DIR/agent_log.md"
PROGRESS_FILE="$PROJECT_STATE_DIR/progress.md"
DISABLED_FILE="$PROJECT_STATE_DIR/disabled"

log() {
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  local msg="[$ts] [$PROJECT_ID] [$REPO_ROOT] $*"
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
  local skipped_stage
  for skipped_stage in $SKIP_STAGES; do
    [[ "$skipped_stage" == "$stage" ]] && return 0
  done
  return 1
}

budget_time_ok() {
  local secs
  secs="$(elapsed)"
  if [[ "$secs" -gt "$MAX_RUNTIME_SECS" ]]; then
    log "BUDGET: Time limit reached (${secs}s > ${MAX_RUNTIME_SECS}s). Stopping."
    progress "  aborted: time limit (${secs}s)"
    return 1
  fi
  return 0
}

implementation_budget_ok() {
  budget_time_ok || return 1
  if [[ "$TASKS_COMPLETED" -ge "$MAX_TASKS" ]]; then
    log "BUDGET: Task limit reached ($TASKS_COMPLETED >= $MAX_TASKS)."
    return 1
  fi
  return 0
}

review_budget_ok() {
  budget_time_ok || return 1
  if [[ "$REVIEWS_COMPLETED" -ge "$MAX_REVIEWS_PER_RUN" ]]; then
    log "BUDGET: Review limit reached ($REVIEWS_COMPLETED >= $MAX_REVIEWS_PER_RUN)."
    progress "  review: skipped (budget reached)"
    return 1
  fi
  return 0
}

count_markdown_files() {
  local path="$1"
  find "$path" -maxdepth 1 -type f -name "*.md" 2>/dev/null | wc -l | tr -d ' '
}

render_prompt() {
  local prompt_file="$1"

  printf \
    'PROJECT_ROOT: %s\nPROJECT_ID: %s\nGH_REPO: %s\nREPO_ROOT: %s\nPROJECT_HOME_DIR: %s\nPROJECT_STATE_DIR: %s\nWORK_BRANCH: %s\nBASE_BRANCH: %s\nISSUE_BUFFER_MIN: %s\nCURRENT_DATE: %s\nELAPSED_SECS: %s\n\n' \
    "$PROJECT_ROOT" "$PROJECT_ID" "$GH_REPO" "$REPO_ROOT" "$PROJECT_HOME_DIR" "$PROJECT_STATE_DIR" "$WORK_BRANCH" "$BASE_BRANCH" "$ISSUE_BUFFER_MIN" "$(date '+%Y-%m-%d %H:%M')" "$(elapsed)"

  sed \
    -e "s|{{PROJECT_ROOT}}|$PROJECT_ROOT|g" \
    -e "s|{{PROJECT_ID}}|$PROJECT_ID|g" \
    -e "s|{{GH_REPO}}|$GH_REPO|g" \
    -e "s|{{REPO_ROOT}}|$REPO_ROOT|g" \
    -e "s|{{PROJECT_HOME_DIR}}|$PROJECT_HOME_DIR|g" \
    -e "s|{{PROJECT_STATE_DIR}}|$PROJECT_STATE_DIR|g" \
    -e "s|{{WORK_BRANCH}}|$WORK_BRANCH|g" \
    -e "s|{{BASE_BRANCH}}|$BASE_BRANCH|g" \
    -e "s|{{ISSUE_BUFFER_MIN}}|$ISSUE_BUFFER_MIN|g" \
    "$prompt_file"
}

count_manual_tasks() {
  local manual_tasks_file="$PROJECT_HOME_DIR/.ai/manualtasks.md"

  if [[ ! -f "$manual_tasks_file" ]]; then
    echo 0
    return 0
  fi

  awk '
    /^## Pending/ { in_pending=1; next }
    /^## / { in_pending=0 }
    in_pending && /^[*-] / { count++ }
    END { print count + 0 }
  ' "$manual_tasks_file"
}

run_stage() {
  local stage="$1"
  local stage_kind="${2:-standard}"
  local prompt_file="$AGENTS_DIR/${stage}_prompt.md"

  if should_skip "$stage"; then
    log "Skipping stage: $stage (SKIP_STAGES)"
    return 0
  fi

  if [[ ! -f "$prompt_file" ]]; then
    log "ERROR: Missing prompt file: $prompt_file"
    return 1
  fi

  if [[ "$stage_kind" == "implementation" ]]; then
    implementation_budget_ok || return 0
  elif [[ "$stage_kind" == "review" ]]; then
    review_budget_ok || return 0
  fi

  local stage_upper
  stage_upper="$(echo "$stage" | tr '[:lower:]' '[:upper:]')"
  local stage_model_var="MODEL_${stage_upper}"
  local stage_model="${!stage_model_var:-$MODEL}"
  local full_prompt
  full_prompt="$(render_prompt "$prompt_file")"

  log ">>> Stage start: $stage | model=$stage_model"

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "--- DRY RUN: $stage (model=$stage_model) ---"
    echo "$full_prompt" | head -30
    echo "---"
    log "<<< Stage done (dry run): $stage"
    return 0
  fi

  local stage_ok=true
  local stage_out
  stage_out="$(claude -p "$full_prompt" --model "$stage_model" --dangerously-skip-permissions 2>&1)" \
    || stage_ok=false

  if echo "$stage_out" | grep -qi "you've hit your limit\|rate limit\|quota exceeded"; then
    log "~~~ Stage paused (rate limited): $stage | will retry next run"
    progress "  aborted: rate limited at $stage"
    exit 0
  fi

  if $stage_ok; then
    echo "$stage_out" | tail -5
    log "<<< Stage done: $stage | model=$stage_model | elapsed=$(elapsed)s"
    if [[ "$stage_kind" == "implementation" ]]; then
      TASKS_COMPLETED=$(( TASKS_COMPLETED + 1 ))
    elif [[ "$stage_kind" == "review" ]]; then
      REVIEWS_COMPLETED=$(( REVIEWS_COMPLETED + 1 ))
    fi
    return 0
  fi

  echo "$stage_out" | tail -10
  log "!!! Stage failed: $stage | elapsed=$(elapsed)s"
  progress "  failed: $stage"
  return 1
}

mkdir -p "$PROJECT_STATE_DIR"

if [[ -f "$DISABLED_FILE" ]]; then
  echo "[orchestrate] Pipeline is disabled for $PROJECT_ID. Run ./toggle.sh -p $PROJECT_ID to re-enable."
  exit 0
fi

if [[ -n "$GH_REPO" ]] && ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: gh CLI is required for project-managed runs." >&2
  exit 1
fi

if [[ -n "$GH_REPO" ]]; then
  ensure_project_checkout "$PROJECT_ROOT"
  sync_project_checkout_if_due
fi

if [[ ! -d "$REPO_ROOT" ]]; then
  echo "ERROR: REPO_ROOT does not exist: $REPO_ROOT" >&2
  exit 1
fi

mkdir -p \
  "$PROJECT_HOME_DIR/.ai" \
  "$PROJECT_HOME_DIR/.ai/roles" \
  "$REPO_ROOT/.ai/active" \
  "$REPO_ROOT/.ai/done" \
  "$REPO_ROOT/.ai/issues/open" \
  "$REPO_ROOT/.ai/issues/closed" \
  "$REPO_ROOT/.ai/reports" \
  "$REPO_ROOT/.ai/reviews" \
  "$REPO_ROOT/.ai/state"

if [[ ! -f "$PROJECT_HOME_DIR/.ai/manualtasks.md" ]]; then
  cat > "$PROJECT_HOME_DIR/.ai/manualtasks.md" <<'EOF'
# Manual tasks

One-shot requests for the PO to convert into GitHub issues on the next run.

## Pending

<!-- Add one bullet per one-shot request here. -->

## Processed
EOF
fi

RUN_DATE="$(date '+%Y-%m-%d %H:%M')"
progress ""
progress "## $RUN_DATE | $PROJECT_ID"

log "========================================"
log "Pipeline start"
log "project=$PROJECT_ID repo=$GH_REPO"
log "checkout=$REPO_ROOT"
log "max_tasks=$MAX_TASKS | max_reviews=$MAX_REVIEWS_PER_RUN | max_runtime=${MAX_RUNTIME_SECS}s"
[[ -n "$SKIP_STAGES" ]] && log "skipping: $SKIP_STAGES"
log "========================================"

if [[ -f "$REPO_ROOT/VISION.md" ]] && [[ ! -f "$REPO_ROOT/ROADMAP.md" ]]; then
  log "Bootstrap gate: VISION.md found, ROADMAP.md missing — running bootstrap"
  run_stage "bootstrap" || { log "Pipeline stopped: bootstrap failed"; exit 1; }
  budget_time_ok || exit 0
fi

run_stage "issue" || { log "Pipeline stopped: issue stage failed"; exit 1; }
budget_time_ok || exit 0

_active_count="$(count_markdown_files "$REPO_ROOT/.ai/active")"
_issue_count="$(count_markdown_files "$REPO_ROOT/.ai/issues/open")"
_manual_task_count="$(count_manual_tasks)"

if [[ "$_active_count" -gt 0 ]]; then
  log "Planning gate: active task already in progress — skipping po/planner"
  progress "  planning: skipped (active task present)"
else
  if [[ "$_manual_task_count" -gt 0 ]]; then
    log "Planning gate: manual tasks pending ($_manual_task_count) — running po intake"
    run_stage "po" || { log "Pipeline stopped: po stage failed"; exit 1; }
    budget_time_ok || exit 0
    run_stage "issue" || { log "Pipeline stopped: issue resync failed"; exit 1; }
    budget_time_ok || exit 0
    _issue_count="$(count_markdown_files "$REPO_ROOT/.ai/issues/open")"
  elif [[ "$_issue_count" -le "$ISSUE_BUFFER_MIN" ]]; then
    log "Planning gate: issue pool low (open=$_issue_count, target=$ISSUE_BUFFER_MIN) — running po"
    run_stage "po" || { log "Pipeline stopped: po stage failed"; exit 1; }
    budget_time_ok || exit 0
    run_stage "issue" || { log "Pipeline stopped: issue resync failed"; exit 1; }
    budget_time_ok || exit 0
    _issue_count="$(count_markdown_files "$REPO_ROOT/.ai/issues/open")"
  else
    log "Planning gate: issue pool sufficient (open=$_issue_count) — skipping po"
    progress "  planning: skipped (issue pool sufficient)"
  fi

  if [[ "$_issue_count" -gt 0 ]]; then
    run_stage "planner" || { log "Pipeline stopped: planner stage failed"; exit 1; }
    budget_time_ok || exit 0
  else
    log "Planning gate: no open issues available after sync"
    progress "  planning: skipped (no open issues)"
  fi
fi

_active_count="$(count_markdown_files "$REPO_ROOT/.ai/active")"

if [[ "$_active_count" -gt 0 ]]; then
  run_stage "developer" "implementation" || { log "Pipeline stopped: developer stage failed"; exit 1; }
  budget_time_ok || exit 0

  run_stage "reviewer" "review" || { log "Pipeline stopped: reviewer stage failed"; exit 1; }
  budget_time_ok || exit 0

  run_stage "qa" "review" || { log "Pipeline stopped: qa stage failed"; exit 1; }
  budget_time_ok || exit 0

  run_stage "git" || { log "Pipeline stopped: git stage failed"; exit 1; }
  budget_time_ok || exit 0
else
  log "Execution gate: no active issue selected — skipping developer/reviewer/qa/git"
  progress "  execution: skipped (no active issue)"
fi

run_stage "release" || { log "Release gate failed (non-fatal)"; progress "  release: gate error"; }

progress "  done: elapsed=$(elapsed)s tasks=$TASKS_COMPLETED reviews=$REVIEWS_COMPLETED"

log "========================================"
log "Pipeline complete | elapsed=$(elapsed)s | tasks_completed=$TASKS_COMPLETED | reviews_completed=$REVIEWS_COMPLETED"
log "========================================"
