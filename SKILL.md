---
name: arxiv-morning-digest
description: Produces a personalized digest of recent arXiv papers ranked by relevance to the researcher's stated interests in USER.md. Use when the user wants a morning paper digest, a personalized arXiv feed, or asks "what's new on arxiv", "arxiv digest", "arxiv morning digest", "today's papers", "morning digest", or "/digest". Supports daily heartbeat-style runs and on-demand chat runs. For first-time setup, see SETUP.md.
---

# ArXiv Morning Digest

> **First-time setup required.** If this workspace does not yet have a populated `USER.md` (with a `## Research interests` section), stop here, read `SETUP.md`, and complete the setup flow before doing anything else with this skill.

> **Implementation constraint — no Python, no helper scripts.** This skill runs in **pure Bash + curl**. Do not write `.py` files, helper scripts, or compiled tools to wrap curl, parse XML, or rank papers. XML parsing uses `grep`, `awk`, `sed`, or `xmllint` directly. Ranking and shortlisting are model passes (the agent reasons over the data), not algorithms in code. Generating a Python script wastes minutes and contradicts the design — the agent doing the reasoning is the point, not a workaround.

Follow this workflow to fetch, rank, log, and deliver a personalized arXiv digest. Setup must already be complete — if not, see `SETUP.md`.

## Step 1, read research interests

Read `USER.md` and look for the `## Research interests` section.

If the section exists with at least one interest, proceed to Step 2.

If the section is missing or empty, respond:

*"No research interests configured yet. Type 'set up arxiv digest' to configure, then I'll start delivering each morning."*

Then ensure the memory directory exists and append a status note to today's Daily Log so the run is recorded:

```bash
mkdir -p memory
```

Append (do not overwrite) to `memory/YYYY-MM-DD.md`:

```markdown
## ArXiv Digest
**Status:** Skipped — no research interests configured.
```

Then stop. This single behavior covers both user-triggered and HEARTBEAT-triggered runs — a present user sees the suggestion in chat; an absent user finds the log entry on their next look.

If the user explicitly says "set up arxiv digest", "configure arxiv digest", or "reconfigure my interests", read `SETUP.md` and follow it from the top.

Optionally read `## Explicit non-interests` and use it to deprioritize or exclude papers in later steps.

## Step 2, determine the time window (incremental sync)

The window covers everything since the last successful digest, capped at `MAX_LOOKBACK_DAYS` days (default `4`).

**Timezone policy.** All date-based decisions use `TIMEZONE` from USER.md (weekend check, daily log filename `memory/YYYY-MM-DD.md`, the brief's `Submitted:` field). arXiv API queries (the `submittedDate:[A TO B]` clause) always use UTC. The watermark `**Window:**` line stored in the daily log is always UTC with `Z` suffix. If `TIMEZONE` is missing from USER.md, fall back to server local time.

**Weekend short-circuit.** If today is Saturday or Sunday and `SKIP_WEEKENDS=true` (default), respond exactly:

*"arXiv doesn't publish on weekends, the next digest will catch up Monday morning."*

Then stop.

**Find the watermark.** Scan the last 14 days of daily logs for the most recent `**Window:**` line:

```bash
for f in $(ls -1 memory/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].md 2>/dev/null | sort -r | head -14); do
  line=$(grep -E '^\*\*Window:\*\*' "$f" 2>/dev/null | tail -1)
  if [ -n "$line" ]; then
    echo "$line"
    break
  fi
done
```

This iterates files newest-first and returns the most recent `**Window:** <start> → <end>` line (handling same-day re-runs by taking the last occurrence within a file). Take the right-hand side of `→` (e.g. `2026-05-04T07:00Z`) as the previous run's `WINDOW_END_UTC` — that becomes the new watermark.

If the loop produces no output, no prior run exists within 14 days — fall through to the first-run fallback below.

**First-run fallback.** If no prior digest is found within 14 days, treat this as a first run. Use `(now_utc - 24h)` as the watermark.

**Compute the new window.**

```
WATERMARK_UTC      = parsed from last digest, or (now - 24h) for first run
WINDOW_START_UTC   = max(WATERMARK_UTC - 12h, now_utc - MAX_LOOKBACK_DAYS days)
WINDOW_END_UTC     = now_utc
```

The 12-hour buffer subtracted from the watermark accounts for the gap between arXiv's `submittedDate` (upload time) and the announcement cycle that makes a paper publicly visible. Dedup in Step 7 will catch any overlap.

The `MAX_LOOKBACK_DAYS` cap prevents catastrophic windows after long absences (vacations, gateway downtime). If the user has been away longer, they get the most recent 4 days, not 4 weeks.

**Re-runs are supported.** Same-day re-triggers (user types `/digest` again after receiving today's digest) proceed through the normal flow rather than short-circuiting. The new window overlaps heavily with the previous run; Step 7's dedup filters out previously-briefed papers using today's log, so the result is "what's new since last time" — which may be 0 papers if nothing fresh has been submitted. The empty-shortlist case is handled in Step 9.

Each successful run (including ones with `**Briefed:** 0`) still writes a `**Window:**` line, advancing the watermark for the next call. The user can keep re-triggering — they'll get up to `DIGEST_SIZE` more papers each time, less if fewer qualify, and a "no more relevant papers" message when the well runs dry.

**Format for arXiv API.** Convert both timestamps to `YYYYMMDDHHMM` for the `submittedDate:[A TO B]` query clause.

## Step 3, plan queries in-model

Do not issue one compound query for all interests.

Plan one query per interest, or one query per cluster of closely related interests. Cap total queries at 4.

For each query, identify semantic groups and build an `all:` search with `OR` within groups and `AND` across groups, then append the date window and category filter.

Pattern:

```text
(all:"<domain term>" OR all:"<synonym>") AND (all:"<method term>" OR all:"<synonym>") AND submittedDate:[<WINDOW_START_UTC> TO <WINDOW_END_UTC>] AND (cat:...)
```

Default categories come from `ARXIV_CATEGORIES`, default `cs.LG,cs.CL`.

## Step 4, set fetch size

Set `max_results = MAX_RESULTS_PER_QUERY` per query (default `200`).

The date filter from Step 2 already bounds how many papers can be in scope. `max_results` is just an upper bound to ensure the full window is captured even on busy days. Raise to `500` for very active categories or windows near the 4-day cap.

There is no oversample multiplier in this design. Recall is bounded by the window, not by a heuristic count.

## Step 5, fetch papers serially

**Bash + curl only.** Do not generate a Python script (e.g. `arxiv_fetch.py`) to wrap curl, manage retries, or parse responses. The fetch is a single inline shell block — see the `fetch_query()` pattern below. Writing a Python wrapper costs the user 1–3 minutes of generation time for zero functional benefit, and the agent's own reasoning replaces what code would otherwise do.

Use a single shell call that performs all arXiv fetches serially with `curl` against `https://export.arxiv.org/api/query`. Save each response to a temporary file (e.g. `/tmp/arxiv-q1.xml`, `/tmp/arxiv-q2.xml`) — Step 9 will re-parse them to extract full abstracts for shortlisted papers.

Use `curl --globoff -A "openclaw-arxiv-digest/0.1 (mailto:your-email@example.com)" -L -sS -o <file> -w "%{http_code}"` so bracketed `submittedDate:[...]` queries are not treated as URL globs, requests identify the caller, and the HTTP status code is captured separately from the body. **Do NOT use `-f`** (fail-on-non-2xx) — it makes curl exit non-zero on 429 and interacts badly with shells running `set -e`.

Respect arXiv rate limits by waiting at least `ARXIV_MIN_INTERVAL_SEC` seconds between calls (default `15`). arXiv's published guidance is 3s minimum, but burst protection kicks in harder in practice — observed runs at 5–8s have hit HTTP 429. 15s is the conservative-but-still-reasonable value that reliably avoids burst rejection on first-call attempts.

**Per-query isolation is required.** Do not run fetches under `set -e`; a single query's failure must not abort the rest. Capture each curl's HTTP status code and decide locally whether to retry, skip, or continue. Pattern:

```bash
fetch_query() {
  local url=$1 out=$2
  local code
  code=$(curl --globoff -A "$UA" -L -sS -o "$out" -w "%{http_code}" "$url")
  if [ "$code" = "200" ]; then return 0; fi
  sleep 30  # backoff before single retry
  code=$(curl --globoff -A "$UA" -L -sS -o "$out" -w "%{http_code}" "$url")
  [ "$code" = "200" ]
}
```

If `fetch_query` returns non-zero, the query failed after one retry. Mark it failed and move to the next query — never abort the script.

**Progress narration.** Before each fetch, emit a one-line status to the active output, e.g. *"Fetching query 1 of 3: mechanistic interpretability..."*. The total wait is roughly `(N - 1) × ARXIV_MIN_INTERVAL_SEC` seconds; brief status messages keep the user oriented and the demo from feeling stalled.

**Track failures.** Maintain a count of failed queries. Step 12 records this in the daily log header (`**Failed queries:** N`), and Step 13 prepends a partial-coverage note to the channel message when N > 0 — so the user sees when an interest was lost to rate limiting.

If **all** queries fail, respond exactly:

*"arXiv API unreachable — all queries failed. Try again in a few minutes."*

Then stop.

## Step 6, parse and union to compact metadata

From each Atom XML response, extract a **compact metadata tuple** per paper:

- arXiv id (base form, e.g. `2511.12345` — strip any `vN` suffix from the atom `<id>` URL so dedup matches in Step 7)
- title
- first ~200 characters of summary
- published date
- primary category

Do not load full abstracts yet — that happens in Step 9 only for shortlisted papers, to keep token cost predictable.

Union results across queries and deduplicate by arXiv id.

## Step 7, deduplicate against recent digests

**This step is required.** The 12-hour watermark buffer in Step 2 creates intentional overlap between consecutive runs' windows. Without dedup, papers near the watermark boundary get re-briefed every day until they fall off the lookback edge.

**Extract previously-briefed ids.** From the last 4 daily log files (matching `MAX_LOOKBACK_DAYS`), pull every arXiv id already briefed:

```bash
ls -1 memory/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].md 2>/dev/null \
  | sort -r | head -4 \
  | xargs grep -hoE 'arxiv\.org/abs/[0-9]{4}\.[0-9]+(v[0-9]+)?' 2>/dev/null \
  | sed 's|.*/||; s|v[0-9]*$||' | sort -u
```

The result is a deduplicated list of ids like `2511.12345`.

**Filter the candidate set.** Remove from Step 6's compact tuples any paper whose id appears in the extracted list.

**Revisions.** Revisions of previously briefed papers (same base id, new `vN`) are filtered out by this step — the user already saw the paper. To re-surface a major revision intentionally, the user can manually delete the relevant `arxiv.org/abs/<id>` link from `memory/YYYY-MM-DD.md`.

## Step 8, semantic shortlist (model pass)

**Fast path.** If the candidate count after Step 7 is ≤ `SHORTLIST_SIZE`, skip Step 8 entirely and pass the deduped set directly to Step 9. This step is purely a culling pass; when there's nothing to cull, it adds latency without value. Common on first runs and active days.

The candidate set after dedup may be 50–200 papers. Cull it down to a manageable shortlist for full-abstract ranking — this is the recall pass.

Read the compact tuples from Step 6 (id, title, opening, date, category) for all surviving candidates. Apply USER.md interests and non-interests.

Select up to `SHORTLIST_SIZE` papers (default `10`) that are plausibly relevant. Be generous — borderline matches stay; only obvious mismatches drop. The point is to keep recall high while bounding the token cost of the next step.

Output: a list of arXiv ids that pass the shortlist.

If fewer than `SHORTLIST_SIZE` plausibly-relevant papers exist, return fewer — do not pad with weak matches. An empty shortlist is acceptable; downstream steps will report the shortfall.

## Step 9, rank by relevance

If the shortlist from Step 8 is empty, skip Steps 9–11. Jump to Step 12 to write a daily log entry with `**Briefed:** 0`, then Step 13 to report no relevant papers in this window. Do not invent or pad with weak matches.

Extract the full abstract and authors for **all** shortlisted ids from the cached XML files in **a single shell pass** — one `awk` or `grep -A` invocation across all `/tmp/arxiv-q*.xml` files. Do not loop one shell call per id; that's N extra processes for no information gain.

Rank by semantic relevance to the stated interests, not mere keyword overlap.

A paper can match even if it uses neighboring terminology.

Use non-interests to deprioritize or drop mismatches.

If two papers are equally relevant, prefer the more recently submitted one.

If nothing is strongly relevant, say so instead of padding.

## Step 10, select top N

Keep the top `DIGEST_SIZE` meaningfully relevant papers (default `3`).

If fewer than `DIGEST_SIZE` qualify, deliver only those and mention the shortfall.

## Step 11, generate briefs

Each brief should be visually scannable in under 5 seconds — title, substance, metadata. Use exactly this structure (markdown renders correctly on Telegram, WhatsApp, Slack, and email):

```text
**{Title}**

**TL;DR:** {one plain-language sentence — what the paper actually does}
**What's new:** {one sentence — the specific contribution beyond prior work}
**Why this matters to you:** {one sentence — reference a specific interest from USER.md by name; if multiple match, pick the strongest}

_{Authors} · {YYYY-MM-DD} · arxiv.org/abs/{id}_
```

**Author formatting:** 1–3 authors → list all (e.g. "Smith, Jones, Wang"). 4+ authors → "Smith et al."

**Date formatting:** Use the `Submitted` date from arXiv, formatted in `TIMEZONE` from USER.md (e.g. `2026-05-04`).

Separate consecutive briefs with a blank line.

## Step 12, write to the Daily Log

Ensure the memory directory exists, then append the digest to `memory/YYYY-MM-DD.md` under `## ArXiv Digest`:

```bash
mkdir -p memory
```

If today's log already contains a digest section (e.g. from an earlier same-day re-run), append a new `## ArXiv Digest` section rather than overwriting the existing one. Step 2's watermark scan picks the most recent `**Window:**` line regardless of which section it's in.

The header must include a `**Window:**` line in this exact format, because Step 2 of the next run parses it as the watermark:

```text
## ArXiv Digest
**Run at:** YYYY-MM-DD HH:MM ±HH:MM
**Window:** YYYY-MM-DDTHH:MMZ → YYYY-MM-DDTHH:MMZ
**Categories:** cs.LG, cs.CL
**Queries:** N attempted, M succeeded
**Failed queries:** K   (omit this line if K = 0)
**Scanned:** N candidates
**After dedup:** N
**Shortlisted:** N
**Briefed:** N

[full briefs from Step 11]
```

Both timestamps in the `**Window:**` line are UTC, with `Z` suffix and `→` separator.

If the skill is running from an automated schedule and fails after its retry policy, append the error to today's Daily Log and stay silent. In failure cases, do not write a `**Window:**` line — the next run should use the previous successful run's watermark, not this failed one.

## Step 13, return to the active channel

Lead with:

*"Digest for [date], window [WINDOW_START → WINDOW_END], scanned [N] papers, [K] after dedup, [S] shortlisted, top [M] below."*

If `**Failed queries:** K` was non-zero in Step 12's header, prepend one line before the lead-with sentence:

*"Heads up: [K] of [N_total] queries failed (likely rate-limited). Coverage is partial — affected interests may be missing from this digest."*

If `**Briefed:** = 0`, replace the lead-with sentence with:

*"No new relevant papers in this window — scanned [N], all [K] already briefed in recent digests."*

Then include the selected briefs (if any).

For asynchronous scheduled delivery, post as a separate message rather than interrupting an active exchange.

## Proactive tuning

If fewer than `DIGEST_SIZE` relevant papers surface for 2 or more days in a row, suggest broadening `ARXIV_CATEGORIES` or loosening the phrasing in `USER.md`.

If the user rejects multiple papers as irrelevant, suggest tightening interests or adding `## Explicit non-interests`.

If the user consistently reads every brief carefully, suggest increasing `DIGEST_SIZE`.

If many runs hit the `MAX_LOOKBACK_DAYS` cap (returning to find a backlog), suggest enabling HEARTBEAT or setting a longer cap.

Offer suggestions, do not edit `USER.md` without asking.

## Environment variables

- `ARXIV_CATEGORIES`, default `cs.LG,cs.CL`
- `DIGEST_SIZE`, default `3`
- `SHORTLIST_SIZE`, default `10`. Caps the candidate pool sent to the rank step (Step 9). Lower = cheaper and faster but more recall risk; higher = more thorough but more tokens.
- `MAX_RESULTS_PER_QUERY`, default `200`
- `MAX_LOOKBACK_DAYS`, default `4`. Caps how far back the window extends if the last successful run was long ago (vacation, downtime, etc.).
- `SKIP_WEEKENDS`, default `true`
- `TIMEZONE`, default server local time
- `ARXIV_MIN_INTERVAL_SEC`, default `15`. Wait time between sequential arXiv API calls. arXiv's published guidance is 3s minimum, but burst protection kicks in harder — observed runs at 5–8s have hit HTTP 429. 15s reliably avoids burst rejection. Lower at your own risk.

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
