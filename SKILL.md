---
name: arxiv-morning-digest
description: Produces a personalized digest of recent arXiv papers ranked by relevance to the researcher's stated interests in USER.md. Use when the user wants a morning paper digest, a personalized arXiv feed, or asks "what's new on arxiv", "arxiv digest", "arxiv morning digest", "today's papers", "morning digest", or "/digest". Supports daily heartbeat-style runs and on-demand chat runs.
---

# ArXiv Morning Digest

Follow this workflow to fetch, rank, log, and deliver a personalized arXiv digest.

## Step 1, read research interests

Read `USER.md` and extract the `## Research interests` section.

Treat each interest as a natural-language topic, not a keyword list.

If the section is missing or empty, respond exactly:

*"I don't see research interests in your USER.md. Add a '## Research interests' section with 3 to 5 specific topics so I can rank papers meaningfully."*

Then stop.

Optionally read `## Explicit non-interests` and use it to deprioritize or exclude papers.

## Step 2, determine the time window

Use `TIMEZONE` if set, otherwise server local time.

If today is Saturday or Sunday and `SKIP_WEEKENDS=true` (default), respond exactly:

*"arXiv doesn't publish on weekends, next digest runs Monday morning with a 72-hour catch-up window."*

Then stop.

If today is Monday, use a 72-hour window covering Friday 00:00 UTC through Sunday 23:59 UTC.

Otherwise, use a 24-hour window covering yesterday 00:00 UTC through yesterday 23:59 UTC.

Store the range as `WINDOW_START` and `WINDOW_END` in `YYYYMMDDHHMM` format for arXiv queries.

## Step 3, plan queries in-model

Do not issue one compound query for all interests.

Plan one query per interest, or one query per cluster of closely related interests. Cap total queries at 4.

For each query, identify semantic groups and build an `all:` search with `OR` within groups and `AND` across groups, then append the date window and category filter.

Pattern:

```text
(all:"<domain term>" OR all:"<synonym>") AND (all:"<method term>" OR all:"<synonym>") AND submittedDate:[<window>] AND (cat:...)
```

Default categories come from `ARXIV_CATEGORIES`, default `cs.LG,cs.CL`.

## Step 4, oversample

Fetch `DIGEST_SIZE × FETCH_PER_QUERY_MULTIPLIER` papers per query.

Defaults:

- `DIGEST_SIZE=3`
- `FETCH_PER_QUERY_MULTIPLIER=2`

## Step 5, fetch papers serially

Use a single shell call that performs all arXiv fetches serially with `curl` against `https://export.arxiv.org/api/query`.

Use `curl --globoff -A "openclaw-arxiv-digest/0.1 (mailto:your-email@example.com)" -L -f -sS` so bracketed `submittedDate:[...]` queries are not treated as URL globs and requests identify the caller clearly.

Respect arXiv rate limits by waiting at least `ARXIV_MIN_INTERVAL_SEC` seconds between calls, default `5`.

If one query fails with HTTP 429, another non-200 result, timeout, or transport error, retry it once after 15 seconds. If it still fails, skip that query and continue.

If all queries fail, respond exactly:

*"arXiv API unreachable, try again in a few minutes."*

Then stop.

## Step 6, parse and union results

From each Atom XML response, extract:

- arXiv id
- title
- summary
- authors
- published date
- primary category
- abs link

Union results across queries and deduplicate by arXiv id.

## Step 7, deduplicate against recent digests

Read `memory/YYYY-MM-DD.md` for the last 3 days when present.

Extract arXiv ids already briefed and remove them from the current candidate set.

If a current paper is a revision of a previously briefed paper, keep it and annotate the brief with: *"revision of earlier digest entry."*

## Step 8, rank by relevance

Rank by semantic relevance to the stated interests, not mere keyword overlap.

A paper can match even if it uses neighboring terminology.

Use non-interests to deprioritize or drop mismatches.

If nothing is strongly relevant, say so instead of padding.

## Step 9, select top N

Keep the top `DIGEST_SIZE` meaningfully relevant papers.

If fewer than `DIGEST_SIZE` qualify, deliver only those and mention the shortfall.

## Step 10, generate briefs

For each selected paper, use exactly this structure:

```text
📄 [Title]
Authors: [First author et al., or up to 3 names]
Link: https://arxiv.org/abs/[id]

TL;DR: [one sentence, plain language]
Contribution: [what's new or different, one sentence]
Why relevant to you: [reference a specific interest from USER.md by name]
Verdict: Read / Skim / Skip
```

Verdict rubric:

- `Read`: directly extends a stated interest with a non-trivial result
- `Skim`: adjacent, or uses a technique the researcher would want to know about
- `Skip`: tangential but surfaced for completeness

## Step 11, write to the Daily Log

Append the digest to `memory/YYYY-MM-DD.md` under `## ArXiv Digest`.

Include:

- fetch window
- category list
- query labels
- total papers scanned
- kept count
- full briefs

If the skill is running from an automated schedule and fails after its retry policy, append the error to today's Daily Log and stay silent.

## Step 12, return to the active channel

Lead with:

*"Digest for [date], scanned [N] new papers in [categories], top [K] below."*

Then include the selected briefs.

For asynchronous scheduled delivery, post as a separate message rather than interrupting an active exchange.

## Proactive tuning

If fewer than `DIGEST_SIZE` relevant papers surface for 2 or more days in a row, suggest broadening `ARXIV_CATEGORIES` or loosening the phrasing in `USER.md`.

If the user rejects multiple papers as irrelevant, suggest tightening interests or adding `## Explicit non-interests`.

If the user consistently reads every brief carefully, suggest increasing `DIGEST_SIZE`.

Offer suggestions, do not edit `USER.md` without asking.

## Environment variables

- `ARXIV_CATEGORIES`, default `cs.LG,cs.CL`
- `DIGEST_SIZE`, default `3`
- `FETCH_PER_QUERY_MULTIPLIER`, default `2`
- `SKIP_WEEKENDS`, default `true`
- `TIMEZONE`, default server local time
- `ARXIV_MIN_INTERVAL_SEC`, default `5`

## Expected USER.md sections

```markdown
## Research interests
- [specific topic 1]
- [specific topic 2]
- [specific topic 3]

## Explicit non-interests
- [topic to exclude]
```

Prefer 3 to 5 specific interests.

## Tools required

- Read
- Write
- Bash or equivalent shell with `curl`

## Scope boundaries

This skill is for daily discovery and triage.

Use a dedicated paper-reading workflow for deep reads, a search-collector workflow for broader literature collection, and separate review workflows for peer-review preparation.
