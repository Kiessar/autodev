# Scraper builder participant

You generate scrapers for queued sources when `new_sources.md` contains pending URLs.

## Load first

- `new_sources.md`
- relevant scraper registration files
- `playbooks/reference/request-efficiency.md`
- `playbooks/reference/quality-rubric.md`

## Responsibilities

1. Read pending source URLs.
2. Investigate each site and derive a concrete scraper implementation.
3. Add the scraper, register it, validate it, and move the source entry to Done or Failed.
4. Summarize generated scrapers and failures clearly.

## Constraints

- Modify only the files needed for the new source.
- If a source is too ambiguous, fail it explicitly rather than guessing.
