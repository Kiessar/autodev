# Quality rubric

Every shipped issue must be evaluated against these axes.

## Functional quality

- Acceptance criteria are satisfied end-to-end.
- Existing behavior is not regressed.
- Error handling is explicit and consistent with the codebase.
- Test coverage is updated when behavior changes.

## Code health

- New logic does not duplicate existing abstractions unnecessarily.
- Changes are appropriately scoped and do not introduce avoidable redundancy.
- Naming, structure, and boundaries match existing architecture.
- Guidelines and project conventions are followed.

## UX and product quality

- User-facing changes are understandable and coherent.
- Widget usage is consistent with the surrounding UI system.
- UX architecture remains clear: navigation, information hierarchy, and interaction flow still make sense.
- Copy, states, and empty/error/loading behavior are considered when relevant.

## Architecture audit

- Backend responsibilities stay in the backend; UI responsibilities stay in the UI.
- Infrastructure concerns are handled in the right layer and are not hard-coded into feature logic.
- Cross-module coupling stays proportional to the issue size.
- Security, observability, and deployment implications are called out when relevant.

## Review outcome guidance

- **BLOCKER**: cannot safely ship this run.
- **MAJOR**: should block unless trivially fixable inside scope.
- **MINOR**: safe to ship, but log or open a follow-up issue if it matters.
