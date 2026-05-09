#!/usr/bin/env bash
# run_agent.sh — runs a Claude Code agent from an MD instruction file with lock protection
#
# Usage:
#   ./run_agent.sh [OPTIONS] <instructions.md>
#
# Options:
#   -l <path>   Lock file path            (default: /tmp/run_agent.lock)
#   -o <path>   Output log file           (default: /tmp/run_agent_<timestamp>.log)
#   -m <model>  Claude model to use       (default: claude-sonnet-4-6)
#   -t <secs>   Max runtime in seconds    (default: 3600)
#   -h          Show this help

set -euo pipefail

# Ensure claude CLI is on PATH (cron has a minimal PATH)
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# ── Defaults ──────────────────────────────────────────────────────────────────
LOCK_FILE="/tmp/run_agent.lock"
LOG_DIR="/tmp/run_agent_logs"
MODEL="claude-sonnet-4-6"
MAX_RUNTIME=3600
INSTRUCTIONS_FILE=""

# ── Parse arguments ───────────────────────────────────────────────────────────
usage() {
  grep '^#' "$0" | sed 's/^# \?//'
  exit 0
}

while getopts "l:o:m:t:h" opt; do
  case $opt in
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

# ── Validate ──────────────────────────────────────────────────────────────────
if [[ -z "$INSTRUCTIONS_FILE" ]]; then
  echo "[run_agent] ERROR: No instructions file provided." >&2
  echo "Usage: $0 [OPTIONS] <instructions.md>" >&2
  exit 1
fi

if [[ ! -f "$INSTRUCTIONS_FILE" ]]; then
  echo "[run_agent] ERROR: Instructions file not found: $INSTRUCTIONS_FILE" >&2
  exit 1
fi

# ── Lock check ────────────────────────────────────────────────────────────────
acquire_lock() {
  if [[ -f "$LOCK_FILE" ]]; then
    local stored_pid
    stored_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")

    if [[ -n "$stored_pid" ]] && kill -0 "$stored_pid" 2>/dev/null; then
      echo "[run_agent] Lock held by PID $stored_pid — previous run still active. Aborting." >&2
      exit 0  # clean exit, not an error; cron will retry next interval
    else
      echo "[run_agent] Stale lock file found (PID $stored_pid not running). Removing."
      rm -f "$LOCK_FILE"
    fi
  fi

  echo $$ > "$LOCK_FILE"
  echo "[run_agent] Lock acquired (PID $$)."
}

release_lock() {
  rm -f "$LOCK_FILE"
  echo "[run_agent] Lock released."
}

# Always release lock on exit (normal, error, or signal)
trap release_lock EXIT

# ── Setup logging ─────────────────────────────────────────────────────────────
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="$LOG_DIR/run_${TIMESTAMP}.log"

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$msg"
  echo "$msg" >> "$LOG_FILE"
}

# ── Main ──────────────────────────────────────────────────────────────────────
acquire_lock

log "Starting agent run"
log "Instructions: $INSTRUCTIONS_FILE"
log "Model: $MODEL"
log "Max runtime: ${MAX_RUNTIME}s"
log "Log: $LOG_FILE"

# Dispatch: .sh files are executed directly; .md files are passed to claude -p
if [[ "$INSTRUCTIONS_FILE" == *.sh ]]; then
  log "Mode: shell script"
  CMD=(timeout "$MAX_RUNTIME" bash "$INSTRUCTIONS_FILE")
else
  log "Mode: claude prompt (model=$MODEL)"
  PROMPT=$(cat "$INSTRUCTIONS_FILE")
  CMD=(timeout "$MAX_RUNTIME" claude --model "$MODEL" -p "$PROMPT")
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
