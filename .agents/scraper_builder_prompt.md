You are an expert Python web-scraping engineer working on the eventExtractor project.

REPO_ROOT: {{REPO_ROOT}}

## Task

Read `{{REPO_ROOT}}/new_sources.md`, build a scraper for each pending URL, and update the file.

---

## Step 1 — Read the queue

Open `{{REPO_ROOT}}/new_sources.md` and collect all non-empty, non-comment lines under the `## Pending` section.

If there are no pending URLs, print "No pending sources." and exit immediately — do nothing else.

---

## Step 2 — For each pending URL

Process URLs one at a time. For each URL:

### 2a. Investigate the site

Fetch the URL with a standard browser User-Agent and examine the HTML. Answer:

- What CSS selector uniquely identifies event links? (look for `<a href="...">` with a consistent path)
- Is there a date-filter form? GET params or POST body?
- Is there pagination or a "load more" button?
- Does the page need JavaScript to render? → `requires_selenium = True`

Fetch one event detail page and answer:
- `name` — `<h1>`? `<meta property="og:title">`? JSON-LD?
- `description` — `<meta name="description">`? long `<p>` block? Try `extract_jsonld_event(soup)` first.
- `datetimes` — `<time datetime="...">` elements? German date string like "13. Mai 2025, 18:00 Uhr"? Use `parse_german_datetime`.
- `location` — address block, `itemprop="location"`, table row "Ort" / "Veranstaltungsort"?
- `price` — "€", "Eintritt", "Gebühr", "kostenlos"?
- `category` — breadcrumb, JSON-LD `genre`, URL path segment?

### 2b. Choose a source_id

Derive a short, snake_case `source_id` from the domain name, e.g.:
- `stadttheater-braunschweig.de` → `stadttheater_bs`
- `events.wolfsburg.de` → `wolfsburg_events`

Check that no file already exists at `{{REPO_ROOT}}/scrapers/sources/<source_id>.py`. If it does, mark as DONE (already implemented) and skip.

### 2c. Generate the scraper

Write a complete Python file to `{{REPO_ROOT}}/scrapers/sources/<source_id>.py`.

**Required structure:**

```python
"""
Scraper for <site name>.
<One line about any quirks: Selenium needed, no date filter, etc.>
"""
from datetime import datetime
from bs4 import BeautifulSoup
from scrapers.base import BaseScraper
from scrapers.registry import register
from utils.dates import dedupe_datetimes, parse_german_datetime
from utils.events import empty_event, generate_event_id
from utils.http import get_links_http, make_request          # or get_links_selenium
from utils.text import clean_text, extract_description, first_match, first_price_text
from utils.structured import extract_jsonld_event, jsonld_to_event


@register
class <ClassName>Scraper(BaseScraper):
    source_id = "<source_id>"
    name      = "<Human Readable Name>"
    example_event_url = "<one stable detail URL>"

    _list_url = "<URL>"

    def get_event_links(self, date_from=None, date_to=None) -> list[str]:
        ...

    def scrape_event(self, url: str) -> dict | None:
        ev = empty_event()
        # ... extraction logic ...
        ev["source"]     = self.source_id
        ev["scraped_at"] = datetime.utcnow().isoformat()
        ev["id"]         = generate_event_id(ev)
        return ev
```

**Rules:**
- Use only `requests` + `beautifulsoup4` unless JavaScript is required (then `get_links_selenium`)
- All field extractors must handle missing elements gracefully — never raise on a missing tag
- Set `ev["source"]`, `ev["scraped_at"]`, and `ev["id"]` before returning
- No placeholder `pass` statements — every method must be real working code
- Use German date helpers if the site uses German date strings

### 2d. Register the scraper

Add the import to the single-line import in `{{REPO_ROOT}}/scrapers/__init__.py`:

```python
# Current line looks like:
from scrapers.sources import die_region, bs_live, ...  # noqa: F401

# Append <source_id> to the import list.
```

### 2e. Test the scraper

Run:
```bash
cd {{REPO_ROOT}} && python -m pytest tests/ -q --tb=short 2>&1 | tail -20
```

Also do a quick smoke test — import the scraper and call `get_event_links()`:
```bash
cd {{REPO_ROOT}} && python -c "
from scrapers import *
from scrapers.registry import get_scraper
s = get_scraper('<source_id>')
links = s.get_event_links()
print(f'Found {len(links)} links')
print(links[:3])
" 2>&1
```

### 2f. Update new_sources.md

**On success:** move the URL from `## Pending` to `## Done` with today's date and the scraper filename:
```
| 2026-05-07 | https://example.de/events | scrapers/sources/example_de.py | 12 links found |
```

**On failure** (site unreachable, structure too complex, Selenium would be needed but unavailable, etc.):
Move the URL to `## Failed` with a brief reason:
```
| 2026-05-07 | https://example.de | Requires login — cannot scrape |
```

---

## Step 3 — Summary

After processing all pending URLs, print a summary:
- How many scrapers were generated
- How many failed (with reasons)
- Whether existing tests still pass

---

## Constraints

- Do NOT modify any existing scraper files
- Do NOT modify `run.py`, `scrapers/base.py`, or any utility in `utils/`
- Only touch: `scrapers/sources/<source_id>.py`, `scrapers/__init__.py`, `new_sources.md`
- If a site is ambiguous or you cannot determine the event link pattern after one attempt, mark it FAILED with a clear reason — do not guess
