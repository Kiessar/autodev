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

- Tracked project definitions live in `config/projects/<project>.env`.
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

Copy the example config and edit it:

```bash
cp config/projects/example.env config/projects/yourproject.env
```

Set at least:

```bash
PROJECT_ID="yourproject"
GH_REPO="your-org/your-repo"
PROJECT_REPO_DIR="projects/yourproject/repo"
PROJECT_STATE_DIR="state/projects/yourproject"
BASE_BRANCH="main"
WORK_BRANCH="develop"
```

On the first run, autodev will clone the repo with `gh repo clone` into the configured cache path.

### 2b. Project activation

Projects listed in `config/projects/inactive-projects.txt` are paused before any AI stage starts.

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

### 5. Schedule it

```cron
# Every 2 hours
0 */2 * * * /home/chris/autodev/run_agent.sh -p yourproject /home/chris/autodev/orchestrate.sh >> /tmp/run_agent_logs/yourproject/cron.log 2>&1
```

Use one cron line per project. Locks and logs are isolated per project automatically.

## Manual one-shot tasks

Each project also gets a local operator intake file:

```text
projects/<project>/.ai/manualtasks.md
```

Use the `## Pending` section for one-shot requests such as:

```md
- Make all panel containers use a white background color.
- Ensure all elements adapt correctly to dark and light mode.
```

On the next run, the PO converts those entries into real GitHub issues, then moves them into `## Processed` so they are only ingested once.

## Runtime layout

### Control repo

```text
config/projects/         tracked project definitions
projects/<project>/repo  cached local clones (gitignored)
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

Each participant has its own markdown file under `playbooks/participants/`. Shared guidance lives under `playbooks/reference/`. The stage prompts in `.agents/` are now thin loaders so agents only pull the references they need.

This replaces the old global notes mechanism. Persistent instructions now belong in tracked playbooks instead of `notes/`.

## Issue and planning policy

- Open GitHub issues are the backlog.
- The PO only creates more issues when the open issue pool drops below `ISSUE_BUFFER_MIN`.
- The planner chooses one issue per run.
- The developer still completes as much useful work as possible inside that single issue to keep request count low.

## Sync policy

- The managed repo is stored offline in `projects/<project>/repo`.
- Autodev does not pull the repository every loop.
- It syncs only after the configured interval, and only when the checkout is clean and no active issue is already in flight.

## Useful commands

```bash
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
| `MAX_TASKS` | `1` | Max implementation issues per run |
| `MAX_REVIEWS_PER_RUN` | `2` | Max review stages per run |
| `MAX_RUNTIME_SECS` | `2700` | Hard runtime limit |
| `SYNC_INTERVAL_SECS` | `14400` | Minimum delay between repo syncs |
| `ISSUE_BUFFER_MIN` | `3` | When PO replenishes issues |
| `MODEL` | `claude-sonnet-4-6` | Fallback model |
| `MODEL_<STAGE>` | see `orchestrate.sh` | Per-stage model override |
| `SKIP_STAGES` | *(empty)* | Space-separated stages to skip |
| `DRY_RUN` | `0` | Print prompts without calling Claude |
| `FORCE_SYNC` | `0` | Sync the cached checkout before the run |
