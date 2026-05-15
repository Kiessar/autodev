#!/usr/bin/env bash

resolve_path_from_root() {
  local root="$1"
  local path="$2"

  if [[ "$path" == /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s/%s\n' "$root" "$path"
  fi
}

resolve_project_id() {
  local value="$1"

  if [[ -z "$value" ]]; then
    return 1
  fi

  value="${value%/}"

  if [[ "$value" == */.ai ]]; then
    basename "$(dirname "$value")"
    return 0
  fi

  if [[ "$value" == */.ai/config.env ]]; then
    basename "$(dirname "$(dirname "$value")")"
    return 0
  fi

  if [[ "$value" == */repo ]]; then
    basename "$(dirname "$value")"
    return 0
  fi

  if [[ "$value" == projects/* ]]; then
    value="${value#projects/}"
    printf '%s\n' "${value%%/*}"
    return 0
  fi

  printf '%s\n' "$value"
}

inactive_projects_file() {
  local project_root="$1"
  printf '%s/projects/inactive-projects.txt\n' "$project_root"
}

available_project_ids() {
  local project_root="$1"
  local projects_dir="$project_root/projects"

  if [[ ! -d "$projects_dir" ]]; then
    return 0
  fi

  find "$projects_dir" -mindepth 3 -maxdepth 3 -type f -name "config.env" -print \
    | while read -r config_path; do
        basename "$(dirname "$(dirname "$config_path")")"
      done \
    | sort
}

load_project_config() {
  local project_root="$1"
  local project_id="$2"
  local config_path="$project_root/projects/$project_id/.ai/config.env"

  local override_max_tasks="${MAX_TASKS:-}"
  local override_max_reviews="${MAX_REVIEWS_PER_RUN:-}"
  local override_sync_interval="${SYNC_INTERVAL_SECS:-}"
  local override_issue_buffer="${ISSUE_BUFFER_MIN:-}"
  local override_work_branch="${WORK_BRANCH:-}"
  local override_base_branch="${BASE_BRANCH:-}"
  local override_repo_root="${REPO_ROOT:-}"
  local override_project_home_dir="${PROJECT_HOME_DIR:-}"

  if [[ ! -f "$config_path" ]]; then
    echo "ERROR: Project config not found: $config_path" >&2
    local known_projects
    known_projects="$(available_project_ids "$project_root" | paste -sd ', ' -)"
    if [[ -n "$known_projects" ]]; then
      echo "Known projects: $known_projects" >&2
    fi
    return 1
  fi

  # shellcheck disable=SC1090
  source "$config_path"

  PROJECT_ID="${PROJECT_ID:-$project_id}"
  GH_REPO="${GH_REPO:-}"
  PROJECT_HOME_DIR="${PROJECT_HOME_DIR:-projects/$PROJECT_ID}"
  PROJECT_REPO_DIR="${PROJECT_REPO_DIR:-$PROJECT_HOME_DIR/repo}"
  PROJECT_STATE_DIR="${PROJECT_STATE_DIR:-state/projects/$PROJECT_ID}"
  WORK_BRANCH="${WORK_BRANCH:-develop}"
  BASE_BRANCH="${BASE_BRANCH:-main}"
  SYNC_INTERVAL_SECS="${SYNC_INTERVAL_SECS:-14400}"
  ISSUE_BUFFER_MIN="${ISSUE_BUFFER_MIN:-3}"
  MAX_TASKS="${MAX_TASKS:-1}"
  MAX_REVIEWS_PER_RUN="${MAX_REVIEWS_PER_RUN:-2}"
  DEFAULT_RUN_INTERVAL_HOURS="${DEFAULT_RUN_INTERVAL_HOURS:-2}"

  [[ -n "$override_repo_root" ]] && REPO_ROOT="$override_repo_root"
  [[ -n "$override_project_home_dir" ]] && PROJECT_HOME_DIR="$override_project_home_dir"
  [[ -n "$override_work_branch" ]] && WORK_BRANCH="$override_work_branch"
  [[ -n "$override_base_branch" ]] && BASE_BRANCH="$override_base_branch"
  [[ -n "$override_sync_interval" ]] && SYNC_INTERVAL_SECS="$override_sync_interval"
  [[ -n "$override_issue_buffer" ]] && ISSUE_BUFFER_MIN="$override_issue_buffer"
  [[ -n "$override_max_tasks" ]] && MAX_TASKS="$override_max_tasks"
  [[ -n "$override_max_reviews" ]] && MAX_REVIEWS_PER_RUN="$override_max_reviews"

  REPO_ROOT="${REPO_ROOT:-$(resolve_path_from_root "$project_root" "$PROJECT_REPO_DIR")}"
  PROJECT_HOME_DIR="$(resolve_path_from_root "$project_root" "$PROJECT_HOME_DIR")"
  PROJECT_STATE_DIR="$(resolve_path_from_root "$project_root" "$PROJECT_STATE_DIR")"

  export PROJECT_ID GH_REPO REPO_ROOT PROJECT_HOME_DIR PROJECT_STATE_DIR WORK_BRANCH BASE_BRANCH
  export SYNC_INTERVAL_SECS ISSUE_BUFFER_MIN MAX_TASKS MAX_REVIEWS_PER_RUN
  export DEFAULT_RUN_INTERVAL_HOURS
}

project_is_active() {
  local project_root="$1"
  local project_id="$2"
  local inactive_file
  inactive_file="$(inactive_projects_file "$project_root")"

  if [[ ! -f "$inactive_file" ]]; then
    return 0
  fi

  if awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    { print $1 }
  ' "$inactive_file" | grep -Fxq "$project_id"; then
    return 1
  fi

  return 0
}

project_has_active_task() {
  local repo_root="$1"
  find "$repo_root/.ai/active" -maxdepth 1 -type f -name "*.md" -print -quit 2>/dev/null | grep -q .
}

repo_has_local_changes() {
  local repo_root="$1"

  if [[ -n "$(git -C "$repo_root" status --porcelain 2>/dev/null)" ]]; then
    return 0
  fi

  return 1
}

ensure_work_branch() {
  local repo_root="$1"
  local work_branch="$2"
  local base_branch="$3"

  git -C "$repo_root" fetch --prune origin >/dev/null 2>&1 || true

  if git -C "$repo_root" show-ref --verify --quiet "refs/heads/$work_branch"; then
    git -C "$repo_root" checkout "$work_branch" >/dev/null 2>&1
    return 0
  fi

  if git -C "$repo_root" show-ref --verify --quiet "refs/remotes/origin/$work_branch"; then
    git -C "$repo_root" checkout -b "$work_branch" "origin/$work_branch" >/dev/null 2>&1
    return 0
  fi

  if git -C "$repo_root" show-ref --verify --quiet "refs/remotes/origin/$base_branch"; then
    git -C "$repo_root" checkout -b "$work_branch" "origin/$base_branch" >/dev/null 2>&1
    return 0
  fi

  git -C "$repo_root" checkout -b "$work_branch" >/dev/null 2>&1
}

ensure_project_checkout() {
  local project_root="$1"

  if [[ -z "$GH_REPO" ]]; then
    echo "ERROR: GH_REPO is not set for $PROJECT_ID." >&2
    return 1
  fi

  mkdir -p "$PROJECT_HOME_DIR/.ai" "$(dirname "$REPO_ROOT")" "$PROJECT_STATE_DIR"

  if [[ ! -d "$REPO_ROOT/.git" ]]; then
    gh repo clone "$GH_REPO" "$REPO_ROOT" >/dev/null
    printf '%s\n' "$(date +%s)" > "$PROJECT_STATE_DIR/last_sync_at"
  fi

  ensure_work_branch "$REPO_ROOT" "$WORK_BRANCH" "$BASE_BRANCH"
}

sync_project_checkout_if_due() {
  local now
  now="$(date +%s)"
  local stashed=0
  local stash_ref=""
  local stash_label="autodev-sync-$PROJECT_ID-$now"
  local sync_ok=0

  if repo_has_local_changes "$REPO_ROOT"; then
    git -C "$REPO_ROOT" stash push --include-untracked -m "$stash_label" >/dev/null
    stash_ref="$(git -C "$REPO_ROOT" stash list --format='%gd %gs' | awk -v label="$stash_label" '$0 ~ label { print $1; exit }')"
    if [[ -n "$stash_ref" ]]; then
      stashed=1
      echo "[autodev] Stashed local changes for $PROJECT_ID before sync." >&2
    fi
  fi

  if git -C "$REPO_ROOT" fetch --prune origin >/dev/null 2>&1; then
    ensure_work_branch "$REPO_ROOT" "$WORK_BRANCH" "$BASE_BRANCH"

    if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/remotes/origin/$WORK_BRANCH"; then
      git -C "$REPO_ROOT" pull --rebase origin "$WORK_BRANCH" >/dev/null 2>&1
    elif git -C "$REPO_ROOT" show-ref --verify --quiet "refs/remotes/origin/$BASE_BRANCH"; then
      git -C "$REPO_ROOT" rebase "origin/$BASE_BRANCH" >/dev/null 2>&1
    fi
    sync_ok=1
  fi

  if [[ "$stashed" -eq 1 ]]; then
    if ! git -C "$REPO_ROOT" stash pop --index "$stash_ref" >/dev/null 2>&1; then
      echo "[autodev] ERROR: Restoring stashed local changes failed for $PROJECT_ID." >&2
      echo "[autodev] Resolve conflicts in $REPO_ROOT before the next run." >&2
      return 1
    fi
    echo "[autodev] Restored local changes for $PROJECT_ID after sync." >&2
  fi

  if [[ "$sync_ok" -ne 1 ]]; then
    echo "[autodev] ERROR: Failed to sync $PROJECT_ID from origin." >&2
    return 1
  fi

  printf '%s\n' "$now" > "$PROJECT_STATE_DIR/last_sync_at"
}
