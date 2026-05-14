# Runtime model

Autodev manages many projects from one control repository.

## Project resolution

- Tracked project definitions live in `config/projects/<project>.env`.
- Cached local clones live in `projects/<project>/repo`.
- Project-local operator files live in `projects/<project>/.ai/`.
- Per-project runtime state lives in `state/projects/<project>/`.
- The runner resolves a project ID first, then derives `GH_REPO`, `REPO_ROOT`, branch names, sync cadence, and issue buffer settings from config.

## Repository sync

- Treat `projects/<project>/repo` as an offline working cache.
- Clone with `gh repo clone` when the cache is missing.
- Do not pull every loop.
- Sync only when the sync interval has expired and the working tree is clean and no active task is already in progress.

## Local AI workspace inside each managed repo

```
.ai/
  active/        selected issue currently being executed
  done/          completed issue records
  issues/open/   offline cache of open GitHub issues
  issues/closed/ offline cache of non-open issues
  reports/       stage summaries and analysis
  reviews/       reviewer and QA verdicts
  state/         implementation status and known failures
```

## Project-local operator intake

- `projects/<project>/.ai/manualtasks.md` is a local one-shot intake file.
- The PO must convert pending entries there into deduplicated GitHub issues on the next run.
- After intake, processed entries should be moved to the `Processed` section so they are not recreated.

## Status flow

```
GitHub open issue
  -> .ai/issues/open/ISSUE-<n>.md
  -> .ai/active/ISSUE-<n>.md status: READY
  -> IN_PROGRESS
  -> REVIEW
  -> QA_REVIEW
  -> READY_FOR_COMMIT
  -> DONE or BLOCKED
```

## GitHub-first planning model

- Open GitHub issues are the executable backlog.
- The Issue participant keeps the local cache in sync.
- The PO only replenishes issues when the open issue pool is below `ISSUE_BUFFER_MIN`.
- The Planner selects one small, actionable open issue from the cache for the current run.
