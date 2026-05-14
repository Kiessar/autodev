#!/usr/bin/env bash
# Toggle the autodev pipeline on/off globally or for a single project.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/lib/common.sh"

PROJECT_ID="${PROJECT_ID:-}"

usage() {
  cat <<'EOF'
Usage: ./toggle.sh [-p project]

- Without -p, toggles the global pipeline flag.
- With -p, toggles the project in projects/inactive-projects.txt.
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
  INACTIVE_FILE="$(inactive_projects_file "$PROJECT_ROOT")"
  TMP_FILE="${INACTIVE_FILE}.tmp"
  mkdir -p "$(dirname "$INACTIVE_FILE")"
  touch "$INACTIVE_FILE"

  if project_is_active "$PROJECT_ROOT" "$PROJECT_ID"; then
    awk -v project="$PROJECT_ID" '
      { print }
      END { print project }
    ' "$INACTIVE_FILE" > "$TMP_FILE"
    mv "$TMP_FILE" "$INACTIVE_FILE"
    rm -f "$PROJECT_STATE_DIR/disabled"
    echo "Project $PROJECT_ID: OFF"
  else
    awk -v project="$PROJECT_ID" '
      /^[[:space:]]*#/ { print; next }
      /^[[:space:]]*$/ { next }
      $1 != project { print }
    ' "$INACTIVE_FILE" > "$TMP_FILE"
    mv "$TMP_FILE" "$INACTIVE_FILE"
    rm -f "$PROJECT_STATE_DIR/disabled"
    echo "Project $PROJECT_ID: ON"
  fi
else
  DISABLED_FILE="$PROJECT_ROOT/state/disabled"
  mkdir -p "$PROJECT_ROOT/state"
  if [[ -f "$DISABLED_FILE" ]]; then
    rm "$DISABLED_FILE"
    echo "Pipeline: ON"
  else
    touch "$DISABLED_FILE"
    echo "Pipeline: OFF"
  fi
fi
