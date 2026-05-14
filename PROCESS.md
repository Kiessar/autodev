# Development & Production Process

## Overview

Two independent processes can coexist on the same server:

| | Production | Auto-dev |
|---|---|---|
| **What it does** | Runs the production workload | Works one GitHub issue, reviews it, and updates the PR |
| **Source of truth** | `main` branch | Open GitHub issues + cached local checkout |
| **Cron** | project-specific | project-specific |
| **DB writes** | Yes, if the app does that in production | No, unless the issue explicitly changes code that later ships |
| **Human required** | Optional, depending on your app | Only for the eventual PR merge if you keep that manual |

## Multi-project model

The control repo can manage multiple GitHub repositories at once.

```text
projects/<project>/.ai/config.env   local project definition
projects/<project>/.ai/manualtasks.md
projects/<project>/repo             offline cached checkout
state/projects/<project>/           project-local runtime logs and sync markers
```

Each project gets:

- its own cron entry
- its own lock file
- its own local cached checkout
- its own local operator intake file at `projects/<project>/.ai/manualtasks.md`
- its own `.ai/` workspace inside the managed repository

## Auto-dev stages

```text
bootstrap → issue → po → planner → developer → reviewer → qa → git → release
```

1. **Bootstrap** — if only `VISION.md` exists, generate `ROADMAP.md`, `ARCHITECTURE.md`, and bootstrap status.
2. **Issue** — sync open GitHub issues into `.ai/issues/open/`.
3. **PO** — replenish issues only when the open issue pool is low.
4. **Planner** — select one open issue and create `.ai/active/ISSUE-<n>.md`.
5. **Developer** — implement the active issue on `develop`.
6. **Reviewer** — verify correctness and tests.
7. **QA** — audit guidelines, redundancy, coverage, UX, widget usage, backend architecture, and infrastructure fit.
8. **Git** — commit, push, close the issue, and update or open the PR.
9. **Release** — auto-approve the PR only when reviewer + QA both pass.

## Branch model

```text
main     <- protected integration / production branch
develop  <- long-lived autodev work branch
```

- Autodev works on `develop`.
- PRs flow from `develop` to `main`.
- The release stage can approve a PR; it does not merge it directly.

## Offline cache and sync policy

- The managed repository is cloned once with `gh repo clone`.
- Autodev keeps that checkout locally and does not pull every run.
- Sync happens only when:
  - the configured sync interval has elapsed
  - the working tree is clean
  - there is no active issue already in progress

This keeps the loop efficient and avoids wasting a full repo pull on every cron tick.

## Project activation guard

- `projects/inactive-projects.txt` is the project deactivation list.
- If a project ID is listed there, `run_agent.sh -p <project>` exits before any AI stage starts.
- This is the safety valve for preventing concurrent or unwanted development on a project.

## Backlog policy

- GitHub issues are the executable backlog.
- The local issue cache is only for offline planning and reduced API churn.
- `projects/<project>/.ai/manualtasks.md` is a one-shot intake source for the PO.
- The PO should spend time on vision analysis and creating new issues only when the queue is running low.
- Pending manual tasks are still converted on the next run even if the issue pool is already healthy.
- Each run should still focus on a single issue so implementation + review + QA can stay tight.

## Review policy

- One implementation issue per run by default.
- Review stages are budgeted per run with `MAX_REVIEWS_PER_RUN`.
- Reviewer and QA are distinct:
  - **Reviewer** checks correctness and acceptance criteria.
  - **QA** checks broader quality, redundancy, coverage, UX, widget usage, backend, and infrastructure architecture.

## Promotion checklist

Before merging an autodev PR into `main`:

- [ ] reviewer approved
- [ ] QA approved
- [ ] no open blocker in `.ai/state/known_failures.md`
- [ ] scope still matches the selected issue
- [ ] tests/validation are green for the touched area

## Operational notes

- Initialize or refresh a managed checkout with `./setup_project.sh <project>`.
- Pause one project with `./toggle.sh -p <project>`.
- Run a project manually with `./run_agent.sh -p <project> ./orchestrate.sh`.
- Force a checkout sync with `FORCE_SYNC=1`.
- Global notes injection is gone; tracked playbooks now carry persistent process guidance.
