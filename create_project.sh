#!/usr/bin/env bash
# Create a managed project folder with default local autodev config.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"

usage() {
  cat <<'EOF'
Usage: ./create_project.sh <project-name> [owner/repo]

Creates:
  projects/<project-name>/
  projects/<project-name>/.ai/config.env
  projects/<project-name>/.ai/manualtasks.md
  projects/inactive-projects.txt (if missing)
EOF
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage >&2
  exit 1
fi

PROJECT_ID="$1"
GH_REPO_VALUE="${2:-}"
PROJECT_HOME_DIR="$PROJECT_ROOT/projects/$PROJECT_ID"
PROJECT_AI_DIR="$PROJECT_HOME_DIR/.ai"
PROJECT_ROLES_DIR="$PROJECT_AI_DIR/roles"
CONFIG_FILE="$PROJECT_AI_DIR/config.env"
MANUAL_TASKS_FILE="$PROJECT_AI_DIR/manualtasks.md"
INACTIVE_FILE="$PROJECT_ROOT/projects/inactive-projects.txt"

mkdir -p "$PROJECT_AI_DIR" "$PROJECT_ROLES_DIR"
touch "$INACTIVE_FILE"

if [[ -e "$CONFIG_FILE" ]]; then
  echo "ERROR: Config already exists: $CONFIG_FILE" >&2
  exit 1
fi

cat > "$CONFIG_FILE" <<EOF
PROJECT_ID="$PROJECT_ID"
GH_REPO="${GH_REPO_VALUE}"
WORK_BRANCH="develop"
BASE_BRANCH="main"
SYNC_INTERVAL_SECS=14400
ISSUE_BUFFER_MIN=3
MAX_TASKS=3
MAX_REVIEWS_PER_RUN=6
DEFAULT_RUN_INTERVAL_HOURS=2
EOF

if [[ ! -f "$MANUAL_TASKS_FILE" ]]; then
  cat > "$MANUAL_TASKS_FILE" <<'EOF'
# Manual tasks

One-shot requests for the PO to convert into GitHub issues on the next run.

## Pending

<!-- Add one bullet per one-shot request here. -->

## Processed
EOF
fi

echo "Created managed project: $PROJECT_ID"
echo "Config: $CONFIG_FILE"
echo "Manual tasks: $MANUAL_TASKS_FILE"
echo "Role overlays: $PROJECT_ROLES_DIR"
if [[ -z "$GH_REPO_VALUE" ]]; then
  echo "Next: edit GH_REPO in $CONFIG_FILE before running the project."
fi
