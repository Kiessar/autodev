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

inactive_projects_file() {
  local project_root="$1"
  printf '%s/config/projects/inactive-projects.txt\n' "$project_root"
}

available_project_ids() {
  local project_root="$1"
  local config_dir="$project_root/config/projects"

  if [[ ! -d "$config_dir" ]]; then
    return 0
  fi

  find "$config_dir" -maxdepth 1 -type f -name "*.env" -printf '%f\n' \
    | sed 's/\.env$//' \
    | sort
}

load_project_config() {
  local project_root="$1"
  local project_id="$2"
  local config_path="$project_root/config/projects/$project_id.env"

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
  PROJECT_REPO_DIR="${PROJECT_REPO_DIR:-projects/$PROJECT_ID/repo}"
  PROJECT_HOME_DIR="${PROJECT_HOME_DIR:-$(dirname "$PROJECT_REPO_DIR")}"
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

  if [[ -z "$GH_REPO" ]]; then
    echo "ERROR: GH_REPO is required in $config_path" >&2
    return 1
  fi

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

  mkdir -p "$(dirname "$REPO_ROOT")" "$PROJECT_STATE_DIR"

  if [[ ! -d "$REPO_ROOT/.git" ]]; then
    gh repo clone "$GH_REPO" "$REPO_ROOT" >/dev/null
    printf '%s\n' "$(date +%s)" > "$PROJECT_STATE_DIR/last_sync_at"
  fi

  ensure_work_branch "$REPO_ROOT" "$WORK_BRANCH" "$BASE_BRANCH"
}

sync_project_checkout_if_due() {
  local now
  now="$(date +%s)"

  if [[ "${FORCE_SYNC:-0}" == "1" ]]; then
    :
  elif [[ -f "$PROJECT_STATE_DIR/last_sync_at" ]]; then
    local last_sync
    last_sync="$(cat "$PROJECT_STATE_DIR/last_sync_at" 2>/dev/null || echo 0)"
    if [[ $(( now - last_sync )) -lt "$SYNC_INTERVAL_SECS" ]]; then
      return 0
    fi
  fi

  if repo_has_local_changes "$REPO_ROOT"; then
    echo "[autodev] Skipping sync for $PROJECT_ID: working tree is not clean." >&2
    return 0
  fi

  if project_has_active_task "$REPO_ROOT"; then
    echo "[autodev] Skipping sync for $PROJECT_ID: active task already in progress." >&2
    return 0
  fi

  git -C "$REPO_ROOT" fetch --prune origin >/dev/null
  ensure_work_branch "$REPO_ROOT" "$WORK_BRANCH" "$BASE_BRANCH"

  if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/remotes/origin/$WORK_BRANCH"; then
    if ! git -C "$REPO_ROOT" merge --ff-only "origin/$WORK_BRANCH" >/dev/null 2>&1; then
      echo "[autodev] Skipping fast-forward for $PROJECT_ID: local $WORK_BRANCH is ahead or diverged." >&2
      return 0
    fi
  elif git -C "$REPO_ROOT" show-ref --verify --quiet "refs/remotes/origin/$BASE_BRANCH"; then
    git -C "$REPO_ROOT" checkout "$WORK_BRANCH" >/dev/null 2>&1
  fi

  printf '%s\n' "$now" > "$PROJECT_STATE_DIR/last_sync_at"
}
