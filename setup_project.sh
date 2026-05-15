#!/usr/bin/env bash
# Prepare a managed project: load config, ensure local files exist, and clone or pull the repo.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: ./setup_project.sh <project-id|projects/<project>|projects/<project>/repo>

Loads the project config, ensures local control files exist, and clones or syncs
the managed repository under projects/<project>/repo.
EOF
}

if [[ $# -ne 1 ]]; then
  usage >&2
  exit 1
fi

RAW_PROJECT="$1"
PROJECT_ID="$(resolve_project_id "$RAW_PROJECT")"

load_project_config "$PROJECT_ROOT" "$PROJECT_ID"

if ! project_is_active "$PROJECT_ROOT" "$PROJECT_ID"; then
  echo "Project $PROJECT_ID is inactive. Remove it from $(inactive_projects_file "$PROJECT_ROOT") or run ./toggle.sh -p $PROJECT_ID first." >&2
  exit 1
fi

mkdir -p "$PROJECT_HOME_DIR/.ai" "$PROJECT_HOME_DIR/.ai/roles" "$PROJECT_STATE_DIR"
touch "$(inactive_projects_file "$PROJECT_ROOT")"

if [[ ! -f "$PROJECT_HOME_DIR/.ai/manualtasks.md" ]]; then
  cat > "$PROJECT_HOME_DIR/.ai/manualtasks.md" <<'EOF'
# Manual tasks

One-shot requests for the PO to convert into GitHub issues on the next run.

## Pending

<!-- Add one bullet per one-shot request here. -->

## Processed
EOF
fi

ensure_project_checkout "$PROJECT_ROOT"
FORCE_SYNC=1 sync_project_checkout_if_due

echo "Project: $PROJECT_ID"
echo "Config: $PROJECT_HOME_DIR/.ai/config.env"
echo "Role overlays: $PROJECT_HOME_DIR/.ai/roles"
echo "Repo: $REPO_ROOT"
echo "Branch: $(git -C "$REPO_ROOT" branch --show-current)"
echo "Remote: $(git -C "$REPO_ROOT" remote get-url origin)"
