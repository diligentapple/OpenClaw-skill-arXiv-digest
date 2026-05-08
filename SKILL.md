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

**Working template.** Run this; outputs `$WIN_START_API` and `$WIN_END_API` for use in Step 3:

```bash
# 1) Find watermark from recent logs (most recent **Window:** line within 14 days)
WATERMARK_ISO=""
for f in $(ls -1 memory/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].md 2>/dev/null | sort -r | head -14); do
  line=$(grep -E '^\*\*Window:\*\*' "$f" 2>/dev/null | tail -1)
  if [ -n "$line" ]; then
    WATERMARK_ISO=$(echo "$line" | sed -E 's/.*→[[:space:]]*([0-9-]+T[0-9:]+)Z.*/\1/')
    break
  fi
done

# 2) First-run fallback if no watermark found
if [ -z "$WATERMARK_ISO" ]; then
  WATERMARK_ISO=$(date -u -d '24 hours ago' '+%Y-%m-%dT%H:%M')
fi

# 3) Compute window: max(watermark - 12h, now - MAX_LOOKBACK_DAYS) → now
WIN_START_ISO=$(date -u -d "$WATERMARK_ISO - 12 hours" '+%Y-%m-%dT%H:%M')
MIN_START_ISO=$(date -u -d "${MAX_LOOKBACK_DAYS:-4} days ago" '+%Y-%m-%dT%H:%M')
WIN_START_EPOCH=$(date -u -d "$WIN_START_ISO" +%s)
MIN_START_EPOCH=$(date -u -d "$MIN_START_ISO" +%s)
[ "$WIN_START_EPOCH" -lt "$MIN_START_EPOCH" ] && WIN_START_ISO="$MIN_START_ISO"
WIN_END_ISO=$(date -u '+%Y-%m-%dT%H:%M')

# 4) arXiv API format: YYYYMMDDHHMM
WIN_START_API=$(echo "$WIN_START_ISO" | tr -d '-T:')
WIN_END_API=$(echo "$WIN_END_ISO"   | tr -d '-T:')

echo "Window: ${WIN_START_ISO}Z → ${WIN_END_ISO}Z  (API: $WIN_START_API → $WIN_END_API)"
```

## Step 3, plan the single fetch query

**One query covers everything.** Do not split per interest. Build one compound query that captures every paper newly submitted to the user's `ARXIV_CATEGORIES` within the time window. Relevance filtering happens later — by title in Step 8, then by full abstract in Step 9.

Pattern:

```text
cat:(<cat1> OR <cat2> ...) AND submittedDate:[<WINDOW_START_UTC> TO <WINDOW_END_UTC>]
```

Example for `ARXIV_CATEGORIES=cs.LG,cs.CL`:

```text
cat:(cs.LG OR cs.CL) AND submittedDate:[202605041000 TO 202605081000]
```

Sort with `sortBy=submittedDate&sortOrder=descending` so the most recent papers appear first — important if the response gets truncated at `MAX_RESULTS_PER_QUERY`. URL-encode parentheses and spaces when building the actual `curl` URL.

Default categories come from `ARXIV_CATEGORIES`, default `cs.LG,cs.CL`.

**Working template.** Reads `$ARXIV_CATEGORIES`, `$WIN_START_API`, `$WIN_END_API`, `$MAX_RESULTS_PER_QUERY`; outputs `$URL` for Step 5:

```bash
# Convert "cs.LG,cs.CL" → "cat:cs.LG+OR+cat:cs.CL"
CATS=$(echo "${ARXIV_CATEGORIES:-cs.LG,cs.CL}" | sed 's/,/+OR+cat:/g')
URL="http://export.arxiv.org/api/query?\
search_query=cat:${CATS}+AND+submittedDate:[${WIN_START_API}+TO+${WIN_END_API}]\
&sortBy=submittedDate&sortOrder=descending\
&max_results=${MAX_RESULTS_PER_QUERY:-500}"

echo "Query URL: $URL"
```

## Step 4, set fetch size

Set `max_results = MAX_RESULTS_PER_QUERY` (default `500`). Since this is a single query covering all categories for the full window, the cap needs to be high enough to catch a busy multi-day window. A typical 4-day `cs.LG + cs.CL` window returns ~300–600 papers; 500 is a comfortable upper bound.

The date filter from Step 2 plus `sortBy=submittedDate&sortOrder=descending` ensures any truncation drops the oldest first. Raise to `1000` for very active categories or longer windows.

## Step 5, fetch papers in one request

**Bash + curl only.** Do not generate a Python script (e.g. `arxiv_fetch.py`) to wrap curl, manage retries, or parse responses. A single inline shell block does the fetch. The agent's own reasoning replaces what code would otherwise do; a Python wrapper wastes 1–3 minutes of generation time for zero functional benefit.

A single `curl` call retrieves every candidate paper. Use `--globoff` so bracketed `submittedDate:[...]` queries are not treated as URL globs. **Do NOT use `-f`** (fail-on-non-2xx) — it makes curl exit non-zero on 429 and interacts badly with shells running `set -e`.

Emit a brief status line before the fetch — e.g. *"Fetching arXiv papers for the last 4 days in cs.LG, cs.CL..."* — so the user knows work is happening.

**Retry policy.** Capture the HTTP status from `-w "%{http_code}"`. If it is not `200`, sleep `ARXIV_MIN_INTERVAL_SEC` seconds (default 15) and retry once. If the retry also fails, respond exactly:

*"arXiv API unreachable — fetch failed. Try again in a few minutes."*

Then stop. Without a successful fetch, there is nothing to rank.

There is no per-query rate spacing because there is only one query. `ARXIV_MIN_INTERVAL_SEC` is reused as the retry backoff; that's the only place it applies in the single-query design.

**Working template.** Reads `$URL`; outputs `/tmp/arxiv-all.xml`:

```bash
UA="openclaw-arxiv-digest/0.1 (mailto:your-email@example.com)"
echo "Fetching arXiv papers..."

CODE=$(curl --globoff -A "$UA" -L -sS -o /tmp/arxiv-all.xml -w "%{http_code}" "$URL")

if [ "$CODE" != "200" ]; then
  echo "First attempt: HTTP $CODE, retrying after ${ARXIV_MIN_INTERVAL_SEC:-15}s..."
  sleep "${ARXIV_MIN_INTERVAL_SEC:-15}"
  CODE=$(curl --globoff -A "$UA" -L -sS -o /tmp/arxiv-all.xml -w "%{http_code}" "$URL")
fi

if [ "$CODE" != "200" ]; then
  echo "arXiv API unreachable — HTTP $CODE after retry. Try again in a few minutes."
  exit 1
fi

PAPER_COUNT=$(grep -c '<entry>' /tmp/arxiv-all.xml)
echo "Fetched $PAPER_COUNT papers."
```

## Step 6, extract id and title

From the cached XML in `/tmp/arxiv-all.xml`, extract **only id and title** per paper:

- arXiv id (base form, e.g. `2511.12345` — strip any `vN` suffix from the atom `<id>` URL so dedup matches in Step 7)
- title

Do not extract abstracts, dates, categories, or authors here. The full XML stays cached; Step 9 will pull the fields it needs for shortlisted papers only. Limiting Step 6 to two fields keeps the extraction to a single shell pass — not a per-paper loop, which is the actual source of "blocking" when running over hundreds of candidates.

**Use one shell call.** A single `awk` or `grep` invocation produces all `<id, title>` pairs across the cached file. Do not iterate paper-by-paper.

Deduplicate by arXiv id (in case a paper cross-lists between categories).

**Working template.** Reads `/tmp/arxiv-all.xml`; outputs `/tmp/arxiv-id-title.tsv` (one paper per line, tab-separated `id<TAB>title`):

```bash
awk '
  /<entry>/         { in_entry=1; id=""; title="" }
  in_entry && /<id>http:\/\/arxiv\.org\/abs\// && id=="" {
    match($0, /[0-9]{4}\.[0-9]+/)
    if (RSTART > 0) id = substr($0, RSTART, RLENGTH)
  }
  in_entry && /<title>/ && title=="" {
    line = $0
    sub(/.*<title[^>]*>[[:space:]]*/, "", line)
    if (line ~ /<\/title>/) {
      sub(/[[:space:]]*<\/title>.*/, "", line)
      gsub(/[[:space:]]+/, " ", line)
      title = line
    }
  }
  /<\/entry>/ {
    if (id != "" && title != "") print id "\t" title
    in_entry=0
  }
' /tmp/arxiv-all.xml | sort -u -t$'\t' -k1,1 > /tmp/arxiv-id-title.tsv

echo "Extracted $(wc -l < /tmp/arxiv-id-title.tsv) unique (id, title) pairs."
```

The `sort -u -t$'\t' -k1,1` deduplicates by the id column. The awk handles the feed-level `<title>arXiv Query: ...</title>` correctly — it's outside any `<entry>`, so it gets ignored.

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

Read the compact tuples from Step 6 (id, title) for all surviving candidates. Apply USER.md interests and non-interests, judging relevance from the title alone — generic-titled papers may slip through to Step 9 where the full abstract gives the final signal.

Select up to `SHORTLIST_SIZE` papers (default `30`) that are plausibly relevant. Be generous — borderline matches stay; only obvious mismatches drop. The point is to keep recall high while bounding the token cost of the next step.

Output: a list of arXiv ids that pass the shortlist.

If fewer than `SHORTLIST_SIZE` plausibly-relevant papers exist, return fewer — do not pad with weak matches. An empty shortlist is acceptable; downstream steps will report the shortfall.

## Step 9, rank by relevance

If the shortlist from Step 8 is empty, skip Steps 9–11. Jump to Step 12 to write a daily log entry with `**Briefed:** 0`, then Step 13 to report no relevant papers in this window. Do not invent or pad with weak matches.

Extract the full abstract and authors for **all** shortlisted ids from `/tmp/arxiv-all.xml` in **a single shell pass** — one `awk` invocation. Do not loop one shell call per id; that's N extra processes for no information gain.

**Working template.** Reads `$SHORTLIST_IDS` (space-separated arXiv ids from Step 8) and `/tmp/arxiv-all.xml`; outputs `/tmp/arxiv-shortlisted.xml` containing only the matched `<entry>` blocks:

```bash
# Build a regex alternation pattern from shortlisted ids
SHORTLIST_PATTERN=$(echo "$SHORTLIST_IDS" | tr ' ' '|')

awk -v pat="$SHORTLIST_PATTERN" '
  BEGIN {
    n = split(pat, arr, "|")
    for (i = 1; i <= n; i++) want[arr[i]] = 1
  }
  /<entry>/ { in_entry=1; entry=""; matched=0 }
  in_entry { entry = entry $0 "\n" }
  in_entry && /<id>http:\/\/arxiv\.org\/abs\// {
    match($0, /[0-9]{4}\.[0-9]+/)
    if (RSTART > 0 && (substr($0, RSTART, RLENGTH) in want)) matched = 1
  }
  /<\/entry>/ {
    if (matched) print entry
    in_entry = 0
  }
' /tmp/arxiv-all.xml > /tmp/arxiv-shortlisted.xml

echo "Extracted $(grep -c '<entry>' /tmp/arxiv-shortlisted.xml) full entries for ranking."
```

The agent then reads `/tmp/arxiv-shortlisted.xml` directly — it contains the title, summary (full abstract), authors, and dates for the shortlisted papers, ready for semantic ranking.

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

**Locked format — do not improvise.** Step 2's watermark parser reads the `**Window:**` line written here. Changing the bold-asterisk markup, the `→` Unicode arrow, the `Z` suffix, or the timestamp shape will break next-run incremental sync. Use the template below verbatim — the only fields you fill are `{placeholder}` values.

If today's log already contains a digest section (e.g. from an earlier same-day re-run), **append** a new `## ArXiv Digest` section rather than overwriting the existing one. Step 2's watermark scan picks the most recent `**Window:**` line regardless of which section it's in.

**Required structure** (literal characters — only the `{placeholders}` get substituted):

```text
## ArXiv Digest
**Run at:** {RUN_AT}
**Window:** {WIN_START_ISO}Z → {WIN_END_ISO}Z
**Categories:** {ARXIV_CATEGORIES}
**Scanned:** {SCANNED}
**After dedup:** {AFTER_DEDUP}
**Shortlisted:** {SHORTLISTED}
**Briefed:** {BRIEFED}

{BRIEFS}
```

**Concrete example** (what a real filled entry looks like):

```text
## ArXiv Digest
**Run at:** 2026-05-08 07:03 +0900
**Window:** 2026-05-04T22:00Z → 2026-05-08T22:03Z
**Categories:** cs.LG, cs.CL
**Scanned:** 412
**After dedup:** 387
**Shortlisted:** 30
**Briefed:** 3

**Mechanistic Interpretability of Attention Heads in GPT-3 Class Models**

**TL;DR:** Identifies attention heads responsible for indirect object identification and demonstrates surgical ablation.
**What's new:** First fine-grained circuit-level explanation that generalizes across model scales.
**Why this matters to you:** Directly extends mechanistic interpretability of transformer attention heads.

_Smith, Jones, Wang · 2026-05-07 · arxiv.org/abs/2511.12345_

[two more briefs in identical format, separated by blank lines]
```

**Format invariants Step 2 depends on:**
- `**Window:**` literal, double-asterisk bold (no `*Window:*`, no `# Window`)
- One space, then `{start}Z`, one space, `→` (Unicode U+2192, not `->`), one space, `{end}Z`
- Both timestamps as ISO `YYYY-MM-DDTHH:MM` (no seconds), with `Z` suffix marking UTC

**Working template.** Reads variables computed in earlier steps and the `$BRIEFS` string composed in Step 11; appends to today's log:

```bash
TZ_VAL="${TIMEZONE:-UTC}"
TODAY=$(TZ="$TZ_VAL" date '+%Y-%m-%d')
RUN_AT=$(TZ="$TZ_VAL" date '+%Y-%m-%d %H:%M %z')
LOG="memory/${TODAY}.md"
mkdir -p memory

# Header — exact format required (Step 2 parses **Window:**)
{
  echo ""
  echo "## ArXiv Digest"
  echo "**Run at:** ${RUN_AT}"
  echo "**Window:** ${WIN_START_ISO}Z → ${WIN_END_ISO}Z"
  echo "**Categories:** ${ARXIV_CATEGORIES}"
  echo "**Scanned:** ${SCANNED}"
  echo "**After dedup:** ${AFTER_DEDUP}"
  echo "**Shortlisted:** ${SHORTLISTED}"
  echo "**Briefed:** ${BRIEFED}"
  echo ""
} >> "$LOG"

# Briefs — printf '%s\n' is safe against % and other shell-special chars
printf '%s\n' "$BRIEFS" >> "$LOG"

echo "Wrote digest to $LOG"
```

If the skill is running from an automated schedule and the fetch fails after its retry policy, append a brief error note to today's Daily Log and stay silent. **Do not write a `**Window:**` line on failure** — the next run should use the previous successful run's watermark, not advance past a failed run.

## Step 13, return to the active channel

Lead with:

*"Digest for [date], window [WINDOW_START → WINDOW_END], scanned [N] papers, [K] after dedup, [S] shortlisted, top [M] below."*

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
- `SHORTLIST_SIZE`, default `30`. Caps the candidate pool sent to the rank step (Step 9). Lower = cheaper and faster but more recall risk; higher = more thorough but more tokens.
- `MAX_RESULTS_PER_QUERY`, default `500`. Upper bound on papers returned by the single arXiv fetch. Raise for active categories or longer windows.
- `MAX_LOOKBACK_DAYS`, default `4`. Caps how far back the window extends if the last successful run was long ago (vacation, downtime, etc.).
- `SKIP_WEEKENDS`, default `true`
- `TIMEZONE`, default server local time
- `ARXIV_MIN_INTERVAL_SEC`, default `15`. Retry backoff after a failed fetch. With the single-query design no inter-query spacing is needed; this only applies if the first attempt returns non-200. arXiv's burst protection has been observed rejecting calls at 5–8s gaps, so 15s reliably clears the cooldown.

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
