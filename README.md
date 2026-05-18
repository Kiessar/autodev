# autodev

Autonomous multi-project development pipeline. One control repo can manage many GitHub repositories, keep an offline checkout for each one, work open GitHub issues on a schedule, run review plus QA, then push and gate the PR.

## Pipeline

```text
bootstrap → issue → po → planner → developer → reviewer → qa → git → release
```

| Stage | Default model | Role |
|---|---|---|
| `bootstrap` | haiku | Creates `ROADMAP.md`, `ARCHITECTURE.md`, and initial status from `VISION.md` |
| `issue` | haiku | Syncs open GitHub issues into the local offline cache |
| `po` | haiku | Replenishes GitHub issues only when the issue pool is running low |
| `planner` | haiku | Selects one open issue for the current run |
| `developer` | sonnet | Implements the selected issue |
| `reviewer` | haiku | Checks correctness, scope, and validation results |
| `qa` | haiku | Audits guidelines, redundancy, coverage, UX, backend, and infrastructure fit |
| `git` | haiku | Commits, pushes the work branch, updates the PR, closes the issue |
| `release` | haiku | Approves the PR only when reviewer + QA are both green |

## How project management works

- Project-local config lives in `projects/<project>/.ai/config.env`.
- Cached clones live in `projects/<project>/repo` and are gitignored.
- Local operator files live in `projects/<project>/.ai/` and are gitignored.
- Per-project runtime state lives in `state/projects/<project>/`.
- Each managed repo keeps its own `.ai/` workspace with active issue, reports, reviews, and issue cache files.
- GitHub is the source of truth for executable work. The local `.ai/issues/open/` directory is just the offline cache.

## Quick start

### 1. Clone autodev and log into GitHub

```bash
git clone git@github.com:Kiessar/autodev.git ~/autodev
cd ~/autodev
gh auth login
```

### 2. Register a project

Create the local project scaffold:

```bash
./create_project.sh yourproject your-org/your-repo
```

That creates:

```text
projects/yourproject/.ai/config.env
projects/yourproject/.ai/manualtasks.md
projects/inactive-projects.txt
```

Edit `projects/yourproject/.ai/config.env` if you want to change branch names or per-run limits.

### 2b. Project activation

Projects listed in `projects/inactive-projects.txt` are paused before any AI stage starts.

```bash
./toggle.sh -p yourproject
```

If a project is inactive, `run_agent.sh -p yourproject ...` exits immediately without spending AI resources.

### 3. Seed the managed repo

If the target repo does not already have these files, copy the templates once:

```bash
cp project-template/VISION.md projects/yourproject/repo/
cp project-template/ROADMAP.md projects/yourproject/repo/
cp project-template/ARCHITECTURE.md projects/yourproject/repo/
```

Fill in `VISION.md`. `ROADMAP.md` and `ARCHITECTURE.md` can be bootstrapped automatically if missing.

### 4. Run a project manually

```bash
./run_agent.sh -p yourproject ./orchestrate.sh
```

### 4b. Set up or refresh the local checkout

```bash
./setup_project.sh yourproject
# or
./setup_project.sh projects/yourproject
```

This loads `projects/yourproject/.ai/config.env`, ensures local control files exist, and clones or pulls `projects/yourproject/repo`.

### 5. Schedule it

```cron
# Every 2 hours
0 */2 * * * /home/chris/autodev/run_agent.sh -p yourproject /home/chris/autodev/orchestrate.sh >> /tmp/run_agent_logs/yourproject/cron.log 2>&1
```

Use one cron line per project. Locks are stored in `projects/<project>/.ai/run_agent.lock`, so they stay with the project metadata instead of relying on `/tmp`.

## Manual one-shot tasks

Each project also gets local operator files:

```text
projects/<project>/.ai/manualtasks.md
projects/<project>/.ai/roles/<role>.md
```

Use the `## Pending` section for one-shot requests such as:

```md
- Make all panel containers use a white background color.
- Ensure all elements adapt correctly to dark and light mode.
```

On the next run, the PO converts those entries into real GitHub issues, then moves them into `## Processed` so they are only ingested once.

## Project-specific role overlays

Each role can also be extended per project with an optional file in:

```text
projects/<project>/.ai/roles/
```

Examples:

```text
projects/<project>/.ai/roles/developer.md
projects/<project>/.ai/roles/reviewer.md
projects/<project>/.ai/roles/po.md
```

Those files are loaded in addition to the shared role playbooks and are the right place for project-specific instructions, conventions, or constraints for that role.

## Project runtime secrets

For local runtime-only secrets, create:

```text
projects/<project>/.ai/.env
```

Example for AutoAITrader:

```bash
chmod 700 projects/AutoAITrader/.ai
cat >> projects/AutoAITrader/.ai/.env <<'EOF'
KRAKEN_PAPER_API_KEY=your-paper-key
KRAKEN_PAPER_API_SECRET=your-paper-secret
KRAKEN_LIVE_API_KEY=your-live-key
KRAKEN_LIVE_API_SECRET=your-live-secret
EOF
chmod 600 projects/AutoAITrader/.ai/.env
```

`run_agent.sh -p <project> ...` sources that file before starting the pipeline, so the managed software can consume environment variables without committing secrets into Git.

## Runtime layout

### Control repo

```text
projects/<project>/.ai/  local project config, manual tasks, and role overlays (gitignored)
projects/<project>/repo  cached local clone (gitignored)
state/projects/<project> per-project logs, progress, sync state (gitignored)
playbooks/               modular participant and reference docs
```

### Managed repo

```text
.ai/
  active/
  done/
  issues/open/
  issues/closed/
  reports/
  reviews/
  state/
```

## Modular participant docs

Each participant has its own markdown file under `playbooks/participants/`. Shared guidance lives under `playbooks/reference/`. The stage prompts in `.agents/` are now thin loaders so agents only pull the references they need, plus an optional project-specific overlay from `projects/<project>/.ai/roles/`.

This replaces the old global notes mechanism. Persistent instructions now belong in tracked playbooks instead of `notes/`.

## Issue and planning policy

- Open GitHub issues are the backlog.
- The PO only creates more issues when the open issue pool drops below `ISSUE_BUFFER_MIN`.
- The planner can choose multiple issues in a single run, up to `MAX_TASKS`, as long as time and review budget remain.
- Each completed issue still goes through reviewer and QA before the runner takes the next one.

## Sync policy

- The managed repo is stored offline in `projects/<project>/repo`.
- Autodev refreshes the checkout from GitHub before every run.
- If local tracked or untracked changes exist, it stashes them, updates the branch from origin, then restores the local work.

## Useful commands

```bash
# Set up or refresh a project checkout
./setup_project.sh yourproject

# Dry-run a project
DRY_RUN=1 ./run_agent.sh -p yourproject ./orchestrate.sh

# Force a sync before the run
FORCE_SYNC=1 ./run_agent.sh -p yourproject ./orchestrate.sh

# Pause or resume a single project
./toggle.sh -p yourproject
```

## Environment overrides

| Variable | Default | Description |
|---|---|---|
| `PROJECT_ID` | from `-p` | Project config ID |
| `REPO_ROOT` | from config | Override the local checkout path |
| `GH_REPO` | from config | `owner/repo` GitHub repository |
| `MAX_TASKS` | `3` | Max implementation issues per run |
| `MAX_REVIEWS_PER_RUN` | `6` | Max review stages per run (reviewer + QA per issue) |
| `MAX_RUNTIME_SECS` | `2700` | Hard runtime limit |
| `SYNC_INTERVAL_SECS` | `14400` | Reserved for sync-related tooling; repo refresh now runs before every execution |
| `ISSUE_BUFFER_MIN` | `3` | When PO replenishes issues |
| `MODEL` | `gpt-5.4` | Fallback model |
| `MODEL_<STAGE>` | see `orchestrate.sh` | Per-stage model override |
| `SKIP_STAGES` | *(empty)* | Space-separated stages to skip |
| `DRY_RUN` | `0` | Print prompts without calling Claude |
| `FORCE_SYNC` | `0` | Kept for compatibility; normal runs already sync before execution |
