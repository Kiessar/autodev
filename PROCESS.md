# Development & Production Process

## Overview

Two completely separate processes run on this server:

| | Production | Auto-Dev |
|---|---|---|
| **What it does** | Runs scrapers, pushes events to DB | Analyzes, implements, reviews, commits |
| **Branch** | `main` | `develop` |
| **Cron** | Every 6 hours | Every hour |
| **DB writes** | Yes — real database | No — never touches production DB |
| **Human required** | No | For PR merge only |

---

## Branches

```
main          ← production-only, protected
  └─ develop  ← auto-dev agent works here
       └─ feature/TASK-NNN  (optional, for large tasks)
```

- **`main`** is what runs in production. Only merged via PR, never pushed directly by the dev agent.
- **`develop`** is where the dev agent commits. Each pipeline run adds one task commit here.
- PRs from `develop` → `main` are opened by the git agent after each completed task.

---

## Production Mode

### What it does

1. `git pull origin main` — gets latest production code
2. Runs `python run.py` (or equivalent entry point)
3. Scrapers execute, validate, and push events to the database
4. Writes logs and run artifacts locally

### When it runs

```
0 */6 * * *   — every 6 hours (adjust to your freshness needs)
```

### What triggers a DB push

The extractor writes to the database on every production run. It is **not** triggered by the dev agent — the two processes are fully independent.

### Cron entry (production)

```bash
0 */6 * * * cd /home/chris/claudPlayGround/eventExtractor && git pull origin main && python run.py >> /tmp/extractor_prod.log 2>&1
```

---

## Development Mode (Auto-Dev)

### What it does

One pipeline run per hour. Six stages:

```
PO → Planner → Issue → Developer → Reviewer → Git
```

1. **PO** — reads VISION.md, ROADMAP.md, git log, tests. Writes analysis and new backlog tasks.
2. **Planner** — picks the highest-priority BACKLOG task whose dependencies are DONE. Moves it to `.ai/active/` with status READY.
3. **Issue** — creates a GitHub issue for the active task.
4. **Developer** — implements the task on `develop`, marks REVIEW when done.
5. **Reviewer** — checks diff, runs tests. Approves (READY_FOR_COMMIT) or blocks (BLOCKED).
6. **Git** — commits atomically, pushes `develop`, opens PR to `main`.

### Lock

A PID-based lock prevents two pipeline runs from overlapping. If a run is still in progress when the next cron fires, the new run aborts cleanly and tries again next hour.

### When dev code reaches production

```
dev agent commits → develop
  → git agent opens PR → main
    → human reviews PR
      → merge → main
        → next production cron picks it up automatically
```

**Human review is the only gate.** The dev agent never touches `main` directly.

---

## Promotion Checklist (before merging a PR)

Before merging a dev agent PR into `main`:

- [ ] Tests pass in CI (or verified locally: `python -m pytest`)
- [ ] `reviews/latest_review.md` shows APPROVE
- [ ] No new entries in `.ai/state/known_failures.md`
- [ ] Changelog entry is accurate
- [ ] Scope matches what the task file described — no surprise changes

---

## Database Push Rules

| Scenario | DB write? |
|---|---|
| Production cron runs | Yes |
| Dev agent implements a task | No |
| Dev agent commits and pushes | No |
| PR merged into `main` | No — next production cron picks it up |
| Manual `python run.py` on `main` | Yes |
| Manual `python run.py` on `develop` | Only if explicitly intended — use `--dry-run` flag if available |

---

## Operational Notes

- **If the dev agent breaks tests**: the reviewer blocks the commit. Fix the blocker task before the next cycle picks it up.
- **If production breaks**: investigate on `main` directly. Do not wait for the dev agent — it works on `develop` and will not help.
- **If the OAuth token expires**: run `claude login` once in the terminal. The cron will resume on the next hour.
- **To pause the dev agent**: `crontab -e` and comment out the auto-dev line.
- **To pause production**: comment out the production cron line. Database stays as-is until re-enabled.
