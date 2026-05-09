# autodev

Autonomous development pipeline powered by Claude Code. Runs on a cron, picks tasks from a backlog, implements them, reviews, commits, opens PRs, and gates releases — no human in the loop except PR approval.

## Pipeline

```
po → planner → issue → developer → reviewer → git → release
```

| Stage | Model | Does |
|---|---|---|
| po | haiku | Analyses repo, creates/updates backlog tasks |
| planner | haiku | Picks highest-priority ready task |
| issue | haiku | Creates or links a GitHub issue (dedup-safe) |
| developer | sonnet | Implements the task |
| reviewer | haiku | Runs tests, checks criteria, approves or blocks |
| git | haiku | Commits, pushes `develop`, opens PR to `main` |
| release | haiku | Auto-approves PR if all checks pass |

## Quick Start

### 1. Clone this repo

```bash
git clone git@github.com:Kiessar/autodev.git ~/autodev
```

### 2. Add your project

Option A — plain clone (gitignored in `projects/`):
```bash
git clone git@github.com:yourorg/yourproject.git ~/autodev/projects/yourproject
```

Option B — git submodule (version-locked, tracked in this repo):
```bash
git submodule add git@github.com:yourorg/yourproject.git projects/yourproject
git commit -m "chore: add yourproject as submodule"
```

### 3. Initialise project files

Copy the templates into your project if they don't exist:
```bash
cp ~/autodev/project-template/VISION.md      ~/autodev/projects/yourproject/
cp ~/autodev/project-template/ROADMAP.md     ~/autodev/projects/yourproject/
cp ~/autodev/project-template/ARCHITECTURE.md ~/autodev/projects/yourproject/
```
Fill in `VISION.md` and `ROADMAP.md` — the PO agent reads these every run.

### 4. Set up the cron

```
# Auto-dev — every 2 hours
0 */2 * * * REPO_ROOT=/home/chris/autodev/projects/yourproject /home/chris/autodev/run_agent.sh /home/chris/autodev/orchestrate.sh >> /tmp/run_agent_logs/cron_yourproject.log 2>&1
```

Multiple projects: add one cron line per project with different `REPO_ROOT` and log paths. The lock file is per-run so they don't interfere (use `-l /tmp/autodev_yourproject.lock` to isolate locks).

### 5. Authenticate GitHub CLI

```bash
gh auth login
```

## State

```
state/
  agent_log.md    — structured run markers (gitignored)
  progress.md     — compact append-only changelog (gitignored)
```

Per-project state lives in `$REPO_ROOT/.ai/`:
```
.ai/
  active/     — task currently in progress
  done/       — completed tasks
  plan/       — backlog tasks
  reports/    — stage summaries (dev, git, release)
  reviews/    — reviewer verdicts
  state/      — known_failures.md
```

## Updating

```bash
cd ~/autodev && git pull
```

All projects immediately pick up the updated pipeline on their next cron run.

## Skipping stages

```bash
REPO_ROOT=... SKIP_STAGES="issue release" ./orchestrate.sh
```

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `REPO_ROOT` | *(required)* | Path to the project repo |
| `MAX_TASKS` | `1` | Max tasks per run |
| `MAX_RUNTIME_SECS` | `2700` | Hard time limit (45 min) |
| `MODEL` | `claude-sonnet-4-6` | Fallback model |
| `MODEL_<STAGE>` | see orchestrate.sh | Per-stage model override |
| `SKIP_STAGES` | *(empty)* | Space-separated stages to skip |
| `DRY_RUN` | `0` | Print prompts, don't call Claude |
