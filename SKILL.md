---
name: arxiv-morning-digest
description: Produces a personalized digest of recent arXiv papers ranked by relevance to the researcher's stated interests in USER.md. Use when the user wants a morning paper digest, a personalized arXiv feed, or asks "what's new on arxiv", "arxiv digest", "arxiv morning digest", "today's papers", "morning digest", or "/digest". Supports daily heartbeat-style runs and on-demand chat runs. For first-time setup, see SETUP.md.
---

# ArXiv Morning Digest

> **First-time setup required.** If this workspace does not yet have a populated `USER.md` (with a `## Research interests` section), stop here, read `SETUP.md`, and complete the setup flow before doing anything else with this skill.

> **Implementation constraint — bash + curl + awk only. RSS for fetching. No Python.**
>
> 1. **Fetch via RSS, not the search API.** Step 5 uses `https://rss.arxiv.org/rss/<category>` feeds. Do **NOT** use `export.arxiv.org/api/query?search_query=...` for the bulk title fetch — observed runs hit HTTP 429 / 503 and waste 4+ minutes on retries. The search API is opt-in fallback only (Step 9 `id_list` lookups for already-shortlisted papers).
> 2. **No Python anywhere.** Do not invoke `python`, `python3`, `xml.etree`, `xml.etree.ElementTree`, `lxml`, `BeautifulSoup`, or any other interpreted helper. Every step has a working `awk`/`sed`/`grep` template — use it verbatim. Generating a `.py` file wastes 1–3 minutes per run for zero functional gain. Temporary `.awk` files in `/tmp` are allowed and preferred over inline `awk '...'` inside nested shell strings, because they avoid quote parsing failures.
> 3. **No improvising alternate data sources** when fetches fail. Do not pivot to `web_search`, listing-page scraping (`/list/cs.CL/new`), or scraping individual `/abs/<id>` pages — they have been observed wasting 5+ minutes on dead ends. The correct response to "RSS unreachable" is to stop and report, not to invent a new pipeline.
> 4. **Templates are the implementation, not suggestions.** Ranking and shortlisting are model passes — those happen in agent reasoning. Everything else (date math, URL building, fetch, XML parsing) is mechanical and has a working template. Copy them, substitute variables, run.

**Runtime budget.** Target wall-clock time is 3–4 minutes per `/digest`. Keep the workflow bounded:
- Fetch at most `MAX_FEEDS` RSS feeds per run (default `4`).
- Use curl timeouts for every network call (`RSS_FETCH_TIMEOUT_SEC`, default `25`; `API_FETCH_TIMEOUT_SEC`, default `45`).
- Send at most `TITLE_MODEL_CAP` titles to the title-shortlisting model pass (default `250`).
- Send at most `SHORTLIST_SIZE` full abstracts to the ranking pass (default `20`).
- Do not call the arXiv API enrichment fallback unless `ENABLE_API_FALLBACK=true` or RSS extraction returns no usable shortlisted entries.
- Do not retry failed mechanical parsing more than once. If the template fails, use the documented fallback or report the failure.

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

**Timezone policy.** All date-based decisions use `TIMEZONE` from USER.md (daily log filename `memory/YYYY-MM-DD.md`, the brief's `Submitted:` field). The watermark `**Window:**` line stored in the daily log is always UTC with `Z` suffix. If `TIMEZONE` is missing from USER.md, fall back to server local time.

There is no weekend short-circuit. `/digest` and scheduled runs may execute on any day; RSS feeds simply return the latest available announcement batch.

**Find the watermark.** Scan recent daily logs for the most recent `**Window:**` line in a single grep pass:

```bash
grep -hE '^\*\*Window:\*\*' memory/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].md 2>/dev/null | tail -1
```

Bash expands the glob in lexicographic (= chronological) order, `grep -h` prints matches in file order, and `tail -1` returns the most recent `**Window:**` line — the latest line in the latest log file that has one (handles same-day re-runs naturally). Take the right-hand side of `→` (e.g. `2026-05-04T07:00Z`) as the previous run's `WINDOW_END_UTC` — that becomes the new watermark.

If the command produces no output, no prior run exists — fall through to the first-run fallback below. (`MAX_LOOKBACK_DAYS` clamps stale watermarks downstream, so an explicit time bound here is unnecessary.)

**First-run fallback.** If no prior digest is found, treat this as a first run. Use `(now_utc - 24h)` as the watermark.

**Compute the new window.**

```
WATERMARK_UTC      = parsed from last digest, or (now - 24h) for first run
WINDOW_START_UTC   = max(WATERMARK_UTC - 12h, now_utc - MAX_LOOKBACK_DAYS days)
WINDOW_END_UTC     = now_utc
```

The 12-hour buffer subtracted from the watermark accounts for the gap between upload time and the announcement cycle that makes a paper publicly visible. Dedup in Step 7 will catch any overlap.

The `MAX_LOOKBACK_DAYS` cap prevents catastrophic windows after long absences (vacations, gateway downtime). If the user has been away longer, they get the most recent 4 days, not 4 weeks.

This window is the digest's incremental watermark and reporting range. RSS feeds do not accept date filters; Step 3 fetches the latest announcement batch for each category, and Step 7 handles overlap by filtering previously-briefed ids.

**Re-runs are supported.** Same-day re-triggers (user types `/digest` again after receiving today's digest) proceed through the normal flow rather than short-circuiting. The new window overlaps heavily with the previous run; Step 7's dedup filters out previously-briefed papers using today's log, so the result is "what's new since last time" — which may be 0 papers if nothing fresh has been submitted. The empty-shortlist case is handled in Step 9.

Each successful run (including ones with `**Briefed:** 0`) still writes a `**Window:**` line, advancing the watermark for the next call. The user can keep re-triggering — they'll get up to `DIGEST_SIZE` more papers each time, less if fewer qualify, and a "no more relevant papers" message when the well runs dry.

**Working template.** Single grep + epoch arithmetic — runs in well under 1 second even with hundreds of daily logs. Outputs `$WIN_START_ISO` and `$WIN_END_ISO` for the daily log and final digest header:

```bash
# 1) Find watermark in one pass: last **Window:** line in the chronologically-last log that has one
WATERMARK_ISO=""
WATERMARK_LINE=$(grep -hE '^\*\*Window:\*\*' memory/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].md 2>/dev/null | tail -1)
if [ -n "$WATERMARK_LINE" ]; then
  WATERMARK_ISO=$(printf '%s\n' "$WATERMARK_LINE" | sed -nE 's/.*→[[:space:]]*([0-9-]+T[0-9:]+)Z.*/\1/p')
fi

# 2) First-run fallback if no watermark found
if [ -z "$WATERMARK_ISO" ]; then
  WATERMARK_ISO=$(date -u -d '24 hours ago' '+%Y-%m-%dT%H:%M')
fi

# 3) Compute window using epoch math: max(watermark - 12h, now - MAX_LOOKBACK_DAYS) → now
NOW_EPOCH=$(date -u +%s)
WATERMARK_EPOCH=$(date -u -d "$WATERMARK_ISO" +%s)
WIN_START_EPOCH=$((WATERMARK_EPOCH - 43200))                              # -12h
MIN_START_EPOCH=$((NOW_EPOCH - ${MAX_LOOKBACK_DAYS:-4} * 86400))
[ "$WIN_START_EPOCH" -lt "$MIN_START_EPOCH" ] && WIN_START_EPOCH=$MIN_START_EPOCH
WIN_START_ISO=$(date -u -d "@$WIN_START_EPOCH" '+%Y-%m-%dT%H:%M')
WIN_END_ISO=$(date -u -d "@$NOW_EPOCH"         '+%Y-%m-%dT%H:%M')

echo "Window: ${WIN_START_ISO}Z → ${WIN_END_ISO}Z"
```

## Step 3, choose RSS feeds for the categories

**Use RSS, not the search API.** arXiv's `export.arxiv.org/api/query` endpoint has been observed returning HTTP 429 (rate limit) and 503 (search backend degraded) for minutes at a time, even with conservative spacing. The RSS endpoints at `rss.arxiv.org/rss/<category>` serve the same data with **zero rate limiting** in practice. Use RSS as the default path; treat the search API as opt-in fallback only.

Pattern:

```text
https://rss.arxiv.org/rss/<category>
```

For `ARXIV_CATEGORIES=cs.LG,cs.CL` → 2 feeds. RSS does not accept a date filter — the feed scopes papers naturally to the latest announcement batch (~1–2 days per category). Step 7's id-based dedup handles overlap with previously-briefed papers, so re-running on the same day still works correctly.

If the configured category list exceeds `MAX_FEEDS` (default `4`), fetch only the first `MAX_FEEDS` categories for this run and mention the cap in the final digest header. This keeps network time and title volume bounded.

**Working template.** Reads `$ARXIV_CATEGORIES`; outputs `$FEED_URLS` array for Step 5:

```bash
FEED_URLS=()
IFS=',' read -ra CATS <<< "${ARXIV_CATEGORIES:-cs.LG,cs.CL}"
MAX_FEEDS_VAL="${MAX_FEEDS:-4}"
for cat in "${CATS[@]}"; do
  [ "${#FEED_URLS[@]}" -ge "$MAX_FEEDS_VAL" ] && break
  cat_trimmed=$(echo "$cat" | xargs)  # strip whitespace
  [ -z "$cat_trimmed" ] && continue
  FEED_URLS+=("https://rss.arxiv.org/rss/${cat_trimmed}")
done
echo "Will fetch ${#FEED_URLS[@]} RSS feeds: ${FEED_URLS[*]}"
```

## Step 4, expected fetch volume

RSS feeds have no `max_results` parameter — each feed returns whatever the day's announcement batch contains, typically 30–150 papers per category.

Expect after cross-listing dedup:

- 2 categories → ~150–300 papers
- 3 categories → ~250–450
- 4+ categories → ~400–1000+ (Step 8 will keyword pre-filter to keep the model pass tractable)

`MAX_RESULTS_PER_QUERY` (default `500`) is now used only by the opt-in API fallback path in Step 9 (id_list lookups), not by the RSS fetch.

## Step 5, fetch the RSS feeds

**Bash + curl only.** Do not generate a Python script (e.g. `arxiv_fetch.py`) to wrap curl, manage retries, or parse responses.

Fetch each feed serially without artificial spacing. RSS does **not** need the 15-second spacing of the search API, and adding sleeps creates a 3–12+ second floor for no useful gain. Use `curl --globoff --connect-timeout 8 --max-time "${RSS_FETCH_TIMEOUT_SEC:-25}" -A "<UA>" -L -sS -o <file> -w "%{http_code}"`. Do **not** use `-f`.

If a feed returns non-200, log the failure and continue with the others. Only abort if **every** feed fails.

**Working template.** Reads `$FEED_URLS`; outputs `/tmp/arxiv-rss-<cat>.xml` files (one per category):

```bash
UA="openclaw-arxiv-digest/0.1 (mailto:your-email@example.com)"
mkdir -p /tmp
rm -f /tmp/arxiv-rss-*.xml
SUCCESS_COUNT=0
i=0

for url in "${FEED_URLS[@]}"; do
  i=$((i + 1))
  cat=$(basename "$url")
  out="/tmp/arxiv-rss-${cat}.xml"
  echo "Fetching ${cat} feed (${i}/${#FEED_URLS[@]})..."
  CODE=$(curl --globoff --connect-timeout 8 --max-time "${RSS_FETCH_TIMEOUT_SEC:-25}" -A "$UA" -L -sS -o "$out" -w "%{http_code}" "$url")
  if [ "$CODE" = "200" ]; then
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
  else
    echo "Feed for ${cat} returned HTTP ${CODE} — skipping."
    rm -f "$out"
  fi
done

if [ $SUCCESS_COUNT -eq 0 ]; then
  echo "All RSS feeds failed. Try again in a few minutes."
  exit 1
fi

TOTAL_ITEMS=$(grep -h '<item>' /tmp/arxiv-rss-*.xml 2>/dev/null | wc -l)
echo "Fetched ${SUCCESS_COUNT}/${#FEED_URLS[@]} feeds, ${TOTAL_ITEMS} items total."
```

## Step 6, extract id and title

From the cached RSS files in `/tmp/arxiv-rss-*.xml`, extract id and title per item:

- arXiv id (base form, e.g. `2511.12345` — strip any `vN` suffix)
- title

**Important: in RSS, `<title>` comes BEFORE `<link>` within each `<item>`.** The awk capture must read the title first, then match the id from the link. (This is the opposite of Atom XML, where `<id>` comes first.)

Do not extract abstracts, dates, categories, or authors here. RSS files stay cached; Step 9 will pull what it needs for shortlisted papers only.

**Working template.** Reads `/tmp/arxiv-rss-*.xml`; outputs `/tmp/arxiv-id-title.tsv` (one paper per line, tab-separated `id<TAB>title`):

```bash
cat > /tmp/arxiv-extract-id-title.awk <<'AWK'
  /<item>/ { in_item=1; id=""; title="" }
  in_item && /<title>/ && title=="" {
    line = $0
    sub(/.*<title[^>]*>[[:space:]]*/, "", line)
    if (line ~ /<\/title>/) {
      sub(/[[:space:]]*<\/title>.*/, "", line)
      gsub(/[[:space:]]+/, " ", line)
      gsub(/<!\[CDATA\[/, "", line)
      gsub(/\]\]>/, "", line)
      title = line
    }
  }
  in_item && /<link>/ && id=="" {
    match($0, /[0-9]{4}\.[0-9]+/)
    if (RSTART > 0) id = substr($0, RSTART, RLENGTH)
  }
  /<\/item>/ {
    if (id != "" && title != "") print id "\t" title
    in_item=0
  }
AWK

awk -f /tmp/arxiv-extract-id-title.awk /tmp/arxiv-rss-*.xml | sort -u -k1,1 > /tmp/arxiv-id-title.tsv

echo "Extracted $(wc -l < /tmp/arxiv-id-title.tsv) unique (id, title) pairs."
```

Notes:
- Write awk programs to `/tmp/*.awk` and run `awk -f` instead of embedding single-quoted awk inside a larger `bash -c` string. Nested quoting has caused real parse failures.
- The channel-level `<title>` (e.g. "cs.LG updates on arXiv.org") sits outside any `<item>`, so the `in_item` guard ignores it correctly.
- The CDATA strip handles feeds that wrap titles in `<![CDATA[...]]>`.
- Use `sort -u -k1,1`, **not** `sort -u -t$'\t' -k1,1` — the `$'\t'` ANSI-C quoting fails in some shells (produces zero output silently). Default whitespace separator works fine since the id column has no whitespace.

## Step 7, deduplicate against recent digests

**This step is required.** The 12-hour watermark buffer in Step 2 creates intentional overlap between consecutive runs' windows. Without dedup, papers near the watermark boundary get re-briefed every day until they fall off the lookback edge.

**Extract previously-briefed ids.** From the recent daily log files (matching `MAX_LOOKBACK_DAYS`), pull every arXiv id already briefed:

```bash
ls -1 memory/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].md 2>/dev/null \
  | sort -r | head -"${MAX_LOOKBACK_DAYS:-4}" \
  | xargs -r grep -hoE 'arxiv\.org/abs/[0-9]{4}\.[0-9]+(v[0-9]+)?' 2>/dev/null \
  | sed 's|.*/||; s|v[0-9]*$||' | sort -u > /tmp/arxiv-seen-ids.txt
```

The result is a deduplicated list of ids like `2511.12345`.

**Filter the candidate set.** Remove from Step 6's compact tuples any paper whose id appears in the extracted list. Output `/tmp/arxiv-candidates.tsv`; all later steps must read this file, not the pre-dedup `/tmp/arxiv-id-title.tsv`.

```bash
cat > /tmp/arxiv-filter-seen.awk <<'AWK'
  BEGIN {
    while ((getline line < seen_file) > 0) {
      if (line != "") seen[line] = 1
    }
  }
  {
    id = $1
    if (!(id in seen)) print
  }
AWK

awk -v seen_file="/tmp/arxiv-seen-ids.txt" -f /tmp/arxiv-filter-seen.awk /tmp/arxiv-id-title.tsv > /tmp/arxiv-candidates.tsv

echo "After dedup: $(wc -l < /tmp/arxiv-candidates.tsv) candidates."
```

**Revisions.** Revisions of previously briefed papers (same base id, new `vN`) are filtered out by this step — the user already saw the paper. To re-surface a major revision intentionally, the user can manually delete the relevant `arxiv.org/abs/<id>` link from `memory/YYYY-MM-DD.md`.

## Step 8, semantic shortlist

Pick the path based on candidate count after Step 7's dedup.

**Fast path — candidates ≤ `SHORTLIST_SIZE` (default 20).** Skip the model shortlist entirely; pass the full deduped set directly to Step 9. No culling needed.

```bash
SHORTLIST_IDS=$(awk '{print $1}' /tmp/arxiv-candidates.tsv | xargs)
```

**Standard path — 20 < candidates ≤ `TITLE_MODEL_CAP` (default 250).** Single model pass: read (id, title) tuples from `/tmp/arxiv-candidates.tsv`, apply USER.md interests and non-interests, pick top `SHORTLIST_SIZE` (default 20) by title relevance, and assign those ids to `$SHORTLIST_IDS`. Be generous — borderline matches stay, only obvious mismatches drop.

**Heavy path — candidates > `TITLE_MODEL_CAP`.** Two-stage filter. A model pass over hundreds or thousands of titles burns tokens on obvious mismatches; a cheap keyword pre-filter cuts the volume first.

1. **Keyword pre-filter (mechanical).** Generate a regex OR-pattern from USER.md interests — split each interest into 2–4 key terms and build an alternation. Example for interests `["mechanistic interpretability of attention heads", "retrieval-augmented generation", "LoRA fine-tuning"]`:

   ```bash
   KEYWORDS="mechanistic|interpretability|circuit|attention|head|RAG|retrieval|augment|LoRA|adapter|fine-tun"
   grep -iE "$KEYWORDS" /tmp/arxiv-candidates.tsv > /tmp/arxiv-prefiltered.tsv
   echo "Pre-filtered: $(wc -l < /tmp/arxiv-prefiltered.tsv) of $(wc -l < /tmp/arxiv-candidates.tsv) candidates"
   ```

   If the result is still over `TITLE_MODEL_CAP`, tighten the pattern once (drop generic terms like "model" or "learning"). If it is still over cap after one tightening pass, take the first `TITLE_MODEL_CAP` lines and proceed; do not spend more time iterating on regexes. If the pre-filter returns 0, fall back to the first `TITLE_MODEL_CAP` deduped candidates so a bad keyword regex does not produce a false empty digest.

2. **Model shortlist over the bounded subset.** Same as standard path, but operates on `/tmp/arxiv-prefiltered.tsv` capped to `TITLE_MODEL_CAP`.

   ```bash
   TITLE_MODEL_CAP_VAL="${TITLE_MODEL_CAP:-250}"
   PREFILTER_COUNT=$(wc -l < /tmp/arxiv-prefiltered.tsv 2>/dev/null || echo 0)
   if [ "$PREFILTER_COUNT" -eq 0 ]; then
     head -"$TITLE_MODEL_CAP_VAL" /tmp/arxiv-candidates.tsv > /tmp/arxiv-prefiltered.tsv
   elif [ "$PREFILTER_COUNT" -gt "$TITLE_MODEL_CAP_VAL" ]; then
     head -"$TITLE_MODEL_CAP_VAL" /tmp/arxiv-prefiltered.tsv > /tmp/arxiv-prefiltered-capped.tsv
     mv /tmp/arxiv-prefiltered-capped.tsv /tmp/arxiv-prefiltered.tsv
   fi
   echo "Title model input: $(wc -l < /tmp/arxiv-prefiltered.tsv) candidates"
   ```

**All paths output:** `$SHORTLIST_IDS`, a space-separated list of arXiv ids that pass the shortlist. Cap this list to `SHORTLIST_SIZE` before Step 9 so the abstract-ranking pass is bounded. An empty shortlist is acceptable; Step 9 will report the shortfall.

```bash
SHORTLIST_IDS=$(printf '%s\n' $SHORTLIST_IDS | head -"${SHORTLIST_SIZE:-20}" | xargs)
SHORTLIST_COUNT=$(printf '%s\n' $SHORTLIST_IDS | sed '/^$/d' | wc -l)
echo "Shortlisted ${SHORTLIST_COUNT} ids."
```

## Step 9, rank by relevance

If the shortlist from Step 8 is empty, skip Steps 9–11. Jump to Step 12 to report no relevant papers in this window, then Step 13 to write a daily log entry with `**Briefed:** 0`. Do not invent or pad with weak matches.

Extract the full abstract and authors for the shortlisted ids. RSS items typically include the abstract in `<description>`; that's the primary source.

**Working template — extract from cached RSS first:**

```bash
SHORTLIST_PATTERN=$(echo "$SHORTLIST_IDS" | tr ' ' '|')

cat > /tmp/arxiv-extract-shortlisted.awk <<'AWK'
  BEGIN {
    n = split(pat, arr, "|")
    for (i = 1; i <= n; i++) want[arr[i]] = 1
  }
  /<item>/ { in_item=1; entry=""; matched=0 }
  in_item { entry = entry $0 "\n" }
  in_item && /<link>/ {
    match($0, /[0-9]{4}\.[0-9]+/)
    if (RSTART > 0 && (substr($0, RSTART, RLENGTH) in want)) matched = 1
  }
  /<\/item>/ {
    if (matched) print entry
    in_item = 0
  }
AWK

awk -v pat="$SHORTLIST_PATTERN" -f /tmp/arxiv-extract-shortlisted.awk /tmp/arxiv-rss-*.xml > /tmp/arxiv-shortlisted.xml

echo "Extracted $(grep -c '<item>' /tmp/arxiv-shortlisted.xml) entries from RSS."
```

Read `/tmp/arxiv-shortlisted.xml` directly for ranking. Do not run a second brittle awk pass that tries to extract only `<description>` bodies; it can capture metadata fragments instead of full abstracts even when the XML is fine.

**Fallback if RSS entries or abstracts are missing or truncated.** RSS is the default and should be used as-is when it provides at least one usable shortlisted entry. Do not call the API just because one or more shortlisted ids are missing from RSS; that delays the whole digest for a marginal recall gain. Fetch via the API's `id_list` endpoint only when `ENABLE_API_FALLBACK=true`, or when RSS extraction produced zero usable shortlisted entries:

```bash
RSS_SHORTLISTED_COUNT=$(grep -c '<item>' /tmp/arxiv-shortlisted.xml 2>/dev/null || echo 0)
if [ "${ENABLE_API_FALLBACK:-false}" = "true" ] || [ "$RSS_SHORTLISTED_COUNT" -eq 0 ]; then
  IDS_CSV=$(echo "$SHORTLIST_IDS" | tr ' ' ',')
  URL="https://export.arxiv.org/api/query?id_list=${IDS_CSV}&max_results=${MAX_RESULTS_PER_QUERY:-500}"
  CODE=$(curl --globoff --connect-timeout 8 --max-time "${API_FETCH_TIMEOUT_SEC:-45}" -A "$UA" -L -sS -o /tmp/arxiv-shortlisted-api.xml -w "%{http_code}" "$URL")
  if [ "$CODE" = "200" ]; then
    mv /tmp/arxiv-shortlisted-api.xml /tmp/arxiv-shortlisted.xml
  else
    echo "Focused id_list fallback returned HTTP ${CODE}; ranking available RSS entries only."
    rm -f /tmp/arxiv-shortlisted-api.xml
  fi
fi
```

The agent then reads `/tmp/arxiv-shortlisted.xml` directly for ranking. RSS entries usually contain enough title, description, author, and date information for a concise digest. If one shortlisted id is missing from RSS and API fallback is disabled, rank the available RSS entries rather than waiting.

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

## Step 12, return to the active channel

Return the digest before writing the Daily Log so the user sees results as soon as ranking and briefing are complete. The log append happens afterward in Step 13.

Lead with:

*"Digest for [date], window [WINDOW_START → WINDOW_END], scanned [N] papers, [K] after dedup, [S] shortlisted, top [M] below."*

If `**Briefed:** = 0`, replace the lead-with sentence with:

*"No new relevant papers in this window — scanned [N], [K] after dedup, [S] shortlisted."*

Then include the selected briefs (if any).

For asynchronous scheduled delivery, post as a separate message rather than interrupting an active exchange.

## Step 13, write to the Daily Log

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

## Proactive tuning

If fewer than `DIGEST_SIZE` relevant papers surface for 2 or more days in a row, suggest broadening `ARXIV_CATEGORIES` or loosening the phrasing in `USER.md`.

If the user rejects multiple papers as irrelevant, suggest tightening interests or adding `## Explicit non-interests`.

If the user consistently reads every brief carefully, suggest increasing `DIGEST_SIZE`.

If many runs hit the `MAX_LOOKBACK_DAYS` cap (returning to find a backlog), suggest enabling HEARTBEAT or setting a longer cap.

Offer suggestions, do not edit `USER.md` without asking.

## Environment variables

- `ARXIV_CATEGORIES`, default `cs.LG,cs.CL`
- `DIGEST_SIZE`, default `3`
- `SHORTLIST_SIZE`, default `20`. Caps the candidate pool sent to the rank step (Step 9). Lower = cheaper and faster but more recall risk; higher = more thorough but more tokens.
- `TITLE_MODEL_CAP`, default `250`. Maximum number of title tuples sent to the title-shortlisting model pass.
- `MAX_FEEDS`, default `4`. Maximum number of RSS category feeds fetched per run.
- `RSS_FETCH_TIMEOUT_SEC`, default `25`. Per-feed curl timeout for RSS fetches.
- `API_FETCH_TIMEOUT_SEC`, default `45`. Curl timeout for the focused `id_list` fallback.
- `ENABLE_API_FALLBACK`, default `false`. Set to `true` to enrich shortlisted ids through arXiv `id_list` when RSS entries are incomplete.
- `MAX_RESULTS_PER_QUERY`, default `500`. Upper bound for the focused arXiv API `id_list` fallback used after shortlisting, not for the RSS feed fetch.
- `MAX_LOOKBACK_DAYS`, default `4`. Caps how far back the window extends if the last successful run was long ago (vacation, downtime, etc.).
- `TIMEZONE`, default server local time

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
