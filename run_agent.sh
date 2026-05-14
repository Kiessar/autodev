#!/usr/bin/env bash
# run_agent.sh — runs a Claude Code agent from an instruction file with lock protection
#
# Usage:
#   ./run_agent.sh [OPTIONS] <instructions.md|script.sh>
#
# Options:
#   -p <project> Project config ID         (projects/<project>/.ai/config.env)
#   -l <path>    Lock file path            (default: /tmp/run_agent[_project].lock)
#   -o <path>    Output log directory      (default: /tmp/run_agent_logs[/project])
#   -m <model>   Copilot model to use      (default: gpt-5.4)
#   -t <secs>    Max runtime in seconds    (default: 3600)
#   -h           Show this help

set -euo pipefail

export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/lib/common.sh"

LOCK_FILE=""
LOG_DIR=""
MODEL="gpt-5.4"
MAX_RUNTIME=3600
INSTRUCTIONS_FILE=""
PROJECT_ID="${PROJECT_ID:-}"

usage() {
  grep '^#' "$0" | sed 's/^# \?//'
  exit 0
}

while getopts "p:l:o:m:t:h" opt; do
  case $opt in
    p) PROJECT_ID="$OPTARG" ;;
    l) LOCK_FILE="$OPTARG" ;;
    o) LOG_DIR="$OPTARG" ;;
    m) MODEL="$OPTARG" ;;
    t) MAX_RUNTIME="$OPTARG" ;;
    h) usage ;;
    *) echo "Unknown option: -$OPTARG" >&2; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

INSTRUCTIONS_FILE="${1:-}"

if [[ -z "$INSTRUCTIONS_FILE" ]]; then
  echo "[run_agent] ERROR: No instructions file provided." >&2
  echo "Usage: $0 [OPTIONS] <instructions.md|script.sh>" >&2
  exit 1
fi

if [[ ! -f "$INSTRUCTIONS_FILE" ]]; then
  echo "[run_agent] ERROR: Instructions file not found: $INSTRUCTIONS_FILE" >&2
  exit 1
fi

if [[ -n "$PROJECT_ID" ]]; then
  load_project_config "$PROJECT_ROOT" "$PROJECT_ID"
  if ! project_is_active "$PROJECT_ROOT" "$PROJECT_ID"; then
    echo "[run_agent] Project $PROJECT_ID is inactive. Aborting before agent execution."
    exit 0
  fi
fi

LOCK_FILE="${LOCK_FILE:-/tmp/run_agent${PROJECT_ID:+_${PROJECT_ID}}.lock}"
LOG_DIR="${LOG_DIR:-/tmp/run_agent_logs${PROJECT_ID:+/$PROJECT_ID}}"

acquire_lock() {
  if [[ -f "$LOCK_FILE" ]]; then
    local stored_pid
    stored_pid="$(cat "$LOCK_FILE" 2>/dev/null || echo "")"

    if [[ -n "$stored_pid" ]] && kill -0 "$stored_pid" 2>/dev/null; then
      echo "[run_agent] Lock held by PID $stored_pid — previous run still active. Aborting." >&2
      exit 0
    fi

    echo "[run_agent] Stale lock file found (PID $stored_pid not running). Removing."
    rm -f "$LOCK_FILE"
  fi

  mkdir -p "$(dirname "$LOCK_FILE")"
  echo $$ > "$LOCK_FILE"
  echo "[run_agent] Lock acquired (PID $$)."
}

release_lock() {
  rm -f "$LOCK_FILE"
  echo "[run_agent] Lock released."
}

trap release_lock EXIT

mkdir -p "$LOG_DIR"
TIMESTAMP="$(date +"%Y%m%d_%H%M%S")"
LOG_FILE="$LOG_DIR/run_${TIMESTAMP}.log"

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$msg"
  echo "$msg" >> "$LOG_FILE"
}

acquire_lock

if [[ -n "$PROJECT_ID" ]]; then
  export PROJECT_ID GH_REPO REPO_ROOT PROJECT_HOME_DIR PROJECT_STATE_DIR WORK_BRANCH BASE_BRANCH
  export SYNC_INTERVAL_SECS ISSUE_BUFFER_MIN MAX_TASKS MAX_REVIEWS_PER_RUN
fi

log "Starting agent run"
log "Instructions: $INSTRUCTIONS_FILE"
[[ -n "$PROJECT_ID" ]] && log "Project: $PROJECT_ID ($GH_REPO)"
log "Model: $MODEL"
log "Max runtime: ${MAX_RUNTIME}s"
log "Log: $LOG_FILE"

if [[ "$INSTRUCTIONS_FILE" == *.sh ]]; then
  log "Mode: shell script"
  CMD=(timeout "$MAX_RUNTIME" bash "$INSTRUCTIONS_FILE")
  [[ -n "$PROJECT_ID" ]] && CMD+=(-p "$PROJECT_ID")
else
  log "Mode: copilot prompt (model=$MODEL)"
  PROMPT="$(cat "$INSTRUCTIONS_FILE")"
  CMD=(timeout "$MAX_RUNTIME" copilot --allow-all --autopilot --model "$MODEL" -p "$PROMPT")
fi

if "${CMD[@]}" 2>&1 | tee -a "$LOG_FILE"; then
  log "Agent run completed successfully."
else
  EXIT_CODE=$?
  if [[ $EXIT_CODE -eq 124 ]]; then
    log "ERROR: Agent run timed out after ${MAX_RUNTIME}s."
  else
    log "ERROR: Agent run failed with exit code $EXIT_CODE."
  fi
  exit $EXIT_CODE
fi
