# Request efficiency

This pipeline is optimized for low request count and high work per request.

## Core rules

1. Batch file reads up front instead of probing one file at a time.
2. Load only the participant doc plus the smallest set of referenced docs needed for the current stage.
3. Operate on one GitHub issue per run, but complete all of that issue's acceptance criteria in the same execution pass.
4. Prefer grouped, surgical edits over many micro-iterations.
5. Use the cached local checkout and issue cache instead of re-pulling the full repository every loop.

## Reading strategy

- First read the active issue, the last relevant review/report, and only the source files directly named by the issue or obvious dependencies.
- Do not walk the whole repository unless the current stage genuinely needs cross-cutting context.
- Reuse previous stage outputs (`project_analysis.md`, `implementation_plan.md`, `latest_review.md`, `latest_qa.md`) to avoid recomputing work.

## Execution strategy

- Do as much useful work as possible in a single request while staying inside one issue's scope.
- Keep issue scope small enough to finish in under 90 minutes.
- If a change naturally contains multiple tightly coupled substeps, execute them together rather than creating artificial extra issues.

## When to stop

- Stop when the current issue would require a broad redesign, cross-cutting refactor, or a second review loop that exceeds the per-run budget.
- Record the blocker clearly instead of continuing with low-confidence partial work.
