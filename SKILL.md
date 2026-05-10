---
name: arxiv-morning-digest
description: Produces a personalized digest of recent arXiv papers ranked by relevance to the researcher's stated interests in USER.md. Use when the user wants a morning paper digest, a personalized arXiv feed, or asks "what's new on arxiv", "arxiv digest", "arxiv morning digest", "today's papers", "morning digest", or "/digest". Supports daily heartbeat-style runs and on-demand chat runs. For first-time setup, see SETUP.md.
---

# ArXiv Morning Digest

> **First-time setup required.** If this workspace does not yet have a populated `USER.md` (with a `## Research interests` section), stop here, read `SETUP.md`, and complete the setup flow before doing anything else with this skill.

> **Implementation constraint — bash + curl + awk only. RSS first, checked-in recent-list fallback. No Python.**
>
> 1. **Fetch via RSS first, not the search API.** Step 5 uses `https://rss.arxiv.org/rss/<category>` feeds. If RSS returns HTTP 200 but zero `<item>` entries across all requested feeds, the checked-in prepare script falls back to `https://arxiv.org/list/<category>/recent?skip=0&show=$RECENT_LIST_SHOW` to recover the latest recent-list batch. Do **NOT** use `export.arxiv.org/api/query?search_query=...` for the bulk title fetch — observed runs hit HTTP 429 / 503 and waste 4+ minutes on retries. The search API is opt-in fallback only (Step 9 `id_list` lookups for already-shortlisted papers, and required when the title source is recent-list because RSS has no abstracts).
> 2. **No Python anywhere.** Do not invoke `python`, `python3`, `xml.etree`, `xml.etree.ElementTree`, `lxml`, `BeautifulSoup`, or any other interpreted helper. Mechanical steps have checked-in bash or working `awk`/`sed`/`grep` templates — use them verbatim. Generating a `.py` file wastes 1–3 minutes per run for zero functional gain. Temporary `.awk` files in `/tmp` are allowed and preferred over inline `awk '...'` inside nested shell strings, because they avoid quote parsing failures.
> 3. **No improvising alternate data sources** when fetches fail. Do not pivot to `web_search`, ad hoc list-page scraping, or scraping individual `/abs/<id>` pages — they have been observed wasting 5+ minutes on dead ends. The only bulk fallback is the bounded recent-list fallback already implemented in `scripts/arxiv-digest-prepare.sh`, and it runs automatically only when RSS returns zero items. The correct response to "RSS unreachable" is to stop and report, not to invent a new pipeline.
> 4. **Scripts/templates are the implementation, not suggestions.** Ranking and shortlisting are model passes — those happen in agent reasoning. Everything else (date math, URL building, fetch, XML parsing) is mechanical and has a working script or template. Run the checked-in script when one exists.
> 5. **Shell snippets assume bash.** When invoking a multi-line snippet through an exec tool, run it with `bash -c '...'` or place it in a bash file and run `bash <file>`. Do not rely on `sh` compatibility — arrays, `[[ ... ]]`, and several parameter expansions below require bash.

**Runtime budget.** Target wall-clock time is 3–4 minutes per `/digest`. Keep the workflow bounded:
- Fetch at most `MAX_FEEDS` RSS feeds per run (default `4`).
- Use curl timeouts for every network call (`RSS_FETCH_TIMEOUT_SEC`, default `25`; `API_FETCH_TIMEOUT_SEC`, default `45`).
- Send at most `TITLE_MODEL_CAP` titles to the title-shortlisting model pass (default `60`).
- Send at most `SHORTLIST_SIZE` full abstracts to the ranking pass (default `15`).
- Do not call the arXiv API enrichment fallback unless `ENABLE_API_FALLBACK=true` or RSS extraction returns no usable shortlisted entries. Recent-list fallback produces titles only, so Step 9 will use the focused `id_list` API lookup for the already-shortlisted ids.
- Do not retry failed mechanical parsing more than once. If the checked-in script or documented template fails, use the documented fallback or report the failure.

Follow this workflow to fetch, rank, log, and deliver a personalized arXiv digest. Setup must already be complete — if not, see `SETUP.md`.

**Preferred execution shape.** Run Steps 2–8 as one bash exec call using `scripts/arxiv-digest-prepare.sh`. Then perform exactly one model pass over `/tmp/arxiv-prefiltered.tsv` to set `$SHORTLIST_IDS`, one exec for Step 9 extraction, one model pass for ranking/briefing, return the digest in Step 12, and append the log in Step 13. Avoid splitting Steps 2–8 across multiple exec calls during normal runs; those steps have no model dependency.

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

## Step 2, determine the run watermark

The `**Window:**` line is a log marker for the last successful run. It is used to find the previous run's end time and to make the digest auditable. It is **not** a filter for paper retrieval: RSS always returns the latest announcement batch for each category.

**Timezone policy.** All date-based decisions use `TIMEZONE` from USER.md (daily log filename `memory/YYYY-MM-DD.md`, the brief's `Submitted:` field). The watermark `**Window:**` line stored in the daily log is always UTC with `Z` suffix. If `TIMEZONE` is missing from USER.md, fall back to server local time.

There is no date-based short-circuit. `/digest` and scheduled runs execute normally on any day; the prepare script fetches RSS first and uses the official recent-list fallback if RSS returns zero items.

**Find the watermark.** Scan recent daily logs for the most recent `**Window:**` line in a single grep pass:

```bash
grep -hE '^\*\*Window:\*\*' memory/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].md 2>/dev/null | tail -1
```

Bash expands the glob in lexicographic (= chronological) order, `grep -h` prints matches in file order, and `tail -1` returns the most recent `**Window:**` line — the latest line in the latest log file that has one (handles same-day re-runs naturally). Take the right-hand side of `→` (e.g. `2026-05-04T07:00Z`) as the previous run's `WINDOW_END_UTC` — that becomes the new watermark.

If the command produces no output, no prior run exists — fall through to the first-run fallback below.

**First-run fallback.** If no prior digest is found, treat this as a first run. Set both `WINDOW_START_UTC` and `WINDOW_END_UTC` to `now_utc` for the log marker. Do not fabricate a 24-hour or 36-hour paper window; RSS retrieval is independent of this marker and still fetches the latest announcement batch.

**Compute the new log marker.**

```
WATERMARK_UTC      = parsed from last digest, or empty for first run
WINDOW_START_UTC   = max(WATERMARK_UTC - 12h, now_utc - MAX_LOOKBACK_DAYS days), or now_utc for first run
WINDOW_END_UTC     = now_utc
```

For runs after the first successful digest, the 12-hour buffer keeps the log marker conservative around arXiv announcement timing. Dedup in Step 7 handles overlap by paper id.

The `MAX_LOOKBACK_DAYS` cap prevents stale log markers after long absences (vacations, gateway downtime). It does not change how many RSS papers are fetched.

The `**Window:**` value is the digest's watermark/reporting range only. RSS feeds do not accept date filters; Step 3 fetches the latest batch for each category, and Step 7 handles overlap by filtering previously-briefed ids.

RSS can sometimes return HTTP 200 with zero `<item>` entries even though the arXiv recent-list page still has the latest batch. Do not stop at zero RSS items. `scripts/arxiv-digest-prepare.sh` must automatically fetch the bounded recent-list fallback, extract id/title pairs, and continue the normal dedup and keyword-prefilter flow. Only if RSS and the recent-list fallback both produce zero candidates should the run use the `SCANNED=0` message from Step 12 and write the Daily Log with `**Briefed:** 0`.

**Date compatibility.** Prefer epoch arithmetic for all computations. `date -d "@$EPOCH"` works across GNU date and uutils date; parsing ISO strings with `date -u -d "$ISO"` is less portable. If watermark parsing fails, treat it like a missing prior watermark for reporting and proceed rather than retrying with alternate commands.

**Re-runs are supported.** Same-day re-triggers (user types `/digest` again after receiving today's digest) proceed through the normal flow rather than short-circuiting. RSS or recent-list may return the same latest batch; Step 7's dedup filters out previously-briefed papers using today's log, so the result is "what's new since last time" — which may be 0 papers if all returned ids were already briefed. The empty-shortlist case is handled in Step 9.

Each successful run (including ones with `**Briefed:** 0`) still writes a `**Window:**` line, advancing the watermark for the next call. The user can keep re-triggering — they'll get up to `DIGEST_SIZE` more papers each time, less if fewer qualify, and a "no additional relevant unbriefed papers" message when the returned set is exhausted.

**Combined mechanical script for Steps 2–8.** Run the checked-in script once from the skill root. Do not recreate it in `/tmp`; the script is part of the repo so it can be syntax-checked, versioned, and invoked directly. It computes the log marker, chooses feeds, fetches RSS in parallel, extracts titles, deduplicates, scores title keyword matches, caps the title model input, and writes run stats. It outputs:
- `/tmp/arxiv-prefiltered.tsv` — bounded title tuples for the Step 8 model shortlist pass
- `/tmp/arxiv-candidates.tsv` — deduped title tuples
- `/tmp/arxiv-run-stats.env` — shell variables for later steps (`WIN_START_ISO`, `WIN_END_ISO`, `FETCH_SOURCE`, `SCANNED`, `AFTER_DEDUP`, `KEYWORD_PREFILTER_STRICT_MATCHES`, etc.)

The script uses `/tmp/arxiv-digest.lock` to prevent overlapping runs from corrupting shared `/tmp/arxiv-*` outputs. If the lock message appears, stop and ask the user to retry after the active run finishes.

```bash
bash scripts/arxiv-digest-prepare.sh
```

## Step 3, choose RSS feeds for the categories

**Use RSS, not the search API.** arXiv's `export.arxiv.org/api/query` endpoint has been observed returning HTTP 429 (rate limit) and 503 (search backend degraded) for minutes at a time, even with conservative spacing. The RSS endpoints at `rss.arxiv.org/rss/<category>` serve the same data with **zero rate limiting** in practice. Use RSS as the default path; treat the search API as opt-in fallback only.

Pattern:

```text
https://rss.arxiv.org/rss/<category>
```

For `ARXIV_CATEGORIES=cs.LG,cs.CL` → 2 feeds. RSS does not accept a date filter — the feed scopes papers naturally to the latest batch. If RSS returns HTTP 200 but zero items across all requested feeds, `scripts/arxiv-digest-prepare.sh` automatically fetches the official recent-list pages for the same categories and continues with those id/title pairs. Step 7's id-based dedup handles overlap with previously-briefed papers, so re-running on the same day still works correctly.

If the configured category list exceeds `MAX_FEEDS` (default `4`), fetch only the first `MAX_FEEDS` categories for this run and mention the cap in the final digest header. This keeps network time and title volume bounded.

Normally this is handled by `scripts/arxiv-digest-prepare.sh`. Use the snippet below only when debugging category parsing:

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

Fetch feeds in parallel. RSS does **not** need the 15-second spacing of the search API, and adding sleeps creates a 3–12+ second floor for no useful gain. Use `curl --globoff --connect-timeout 8 --max-time "${RSS_FETCH_TIMEOUT_SEC:-25}" -A "<UA>" -L -sS -o <file> -w "%{http_code}"`. Do **not** use `-f`.

If a feed returns non-200, log the failure and continue with the others. Only abort if **every** RSS feed fails. If at least one RSS feed returns 200 but the combined RSS item count is zero, do not stop; the checked-in prepare script fetches `https://arxiv.org/list/<category>/recent?skip=0&show=$RECENT_LIST_SHOW` for the same categories and extracts bounded id/title tuples from those official recent-list pages.

Normally this is handled by `scripts/arxiv-digest-prepare.sh`. If debugging RSS fetch only, use this parallel template:

```bash
UA="openclaw-arxiv-digest/0.1 (mailto:your-email@example.com)"
RSS_FETCH_TIMEOUT_SEC="${RSS_FETCH_TIMEOUT_SEC:-25}"
mkdir -p /tmp
rm -f /tmp/arxiv-rss-*.xml /tmp/arxiv-code-*.txt /tmp/arxiv-err-*.txt

pids=()
for url in "${FEED_URLS[@]}"; do
  cat=$(basename "$url")
  out="/tmp/arxiv-rss-${cat}.xml"
  code_file="/tmp/arxiv-code-${cat}.txt"
  err_file="/tmp/arxiv-err-${cat}.txt"
  echo "Fetching ${cat}..."
  (
    CODE=$(curl --globoff --connect-timeout 8 --max-time "$RSS_FETCH_TIMEOUT_SEC" \
      -A "$UA" -L -sS -o "$out" -w "%{http_code}" "$url" 2>"$err_file" || echo "000")
    CODE="${CODE:0:3}"
    printf '%s\n' "$CODE" > "$code_file"
  ) &
  pids+=($!)
done
for pid in "${pids[@]}"; do
  wait "$pid" || true
done

SUCCESS_COUNT=0
for url in "${FEED_URLS[@]}"; do
  cat=$(basename "$url")
  out="/tmp/arxiv-rss-${cat}.xml"
  CODE=$(cat "/tmp/arxiv-code-${cat}.txt" 2>/dev/null || printf '000')
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

From the cached RSS files in `/tmp/arxiv-rss-*.xml`, extract id and title per item. If RSS produced zero items, the checked-in prepare script instead extracts the same id/title tuple shape from `/tmp/arxiv-list-*.html` recent-list fallback files:

- arXiv id (base form, e.g. `2511.12345` — strip any `vN` suffix)
- title

**Important: in RSS, `<title>` comes BEFORE `<link>` within each `<item>`.** The awk capture must read the title first, then match the id from the link. (This is the opposite of Atom XML, where `<id>` comes first.)

Do not extract abstracts, dates, categories, or authors here. RSS files stay cached when present; Step 9 will pull what it needs for shortlisted papers only. If the source is recent-list, Step 9's focused `id_list` fallback supplies abstracts/authors for the already-shortlisted ids.

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

awk -f /tmp/arxiv-extract-id-title.awk /tmp/arxiv-rss-*.xml | awk -F '\t' '!seen[$1]++' > /tmp/arxiv-id-title.tsv

echo "Extracted $(wc -l < /tmp/arxiv-id-title.tsv) unique (id, title) pairs."
```

Notes:
- Write awk programs to `/tmp/*.awk` and run `awk -f` instead of embedding single-quoted awk inside a larger `bash -c` string. Nested quoting has caused real parse failures.
- The channel-level `<title>` (e.g. "cs.LG updates on arXiv.org") sits outside any `<item>`, so the `in_item` guard ignores it correctly.
- The CDATA strip handles feeds that wrap titles in `<![CDATA[...]]>`.
- Preserve source order when deduplicating ids. Do **not** use `sort -u -k1,1` here; it reorders papers by arXiv id and can make the no-keyword fallback choose older entries instead of the newest feed/list entries.

## Step 7, deduplicate against recent digests

**This step is required.** RSS can return the same latest announcement batch across repeated runs. Without dedup, already-briefed papers can be re-briefed on the next run.

**Extract previously-briefed ids.** From the recent daily log files (matching `MAX_LOOKBACK_DAYS`), pull every arXiv id already briefed:

```bash
ls -1 memory/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].md 2>/dev/null \
  | sort -r | head -"${MAX_LOOKBACK_DAYS:-4}" \
  | xargs -r grep -hoE 'arxiv\.org/abs/[0-9]{4}\.[0-9]+(v[0-9]+)?' 2>/dev/null \
  | sed 's|.*/||; s|v[0-9]*$||' | sort -u > /tmp/arxiv-seen-ids.txt
```

The result is a deduplicated list of ids like `2511.12345`.

**Filter the candidate set.** Remove from Step 6's compact tuples any paper whose id appears in the extracted list. Output `/tmp/arxiv-candidates.tsv`; later title shortlisting normally reads the bounded `/tmp/arxiv-prefiltered.tsv` produced by `scripts/arxiv-digest-prepare.sh`, not the pre-dedup `/tmp/arxiv-id-title.tsv`.

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

Normal runs use `/tmp/arxiv-prefiltered.tsv`, the bounded title input produced by `scripts/arxiv-digest-prepare.sh`. It contains all deduped candidates only when the count is at or below `SHORTLIST_SIZE`; otherwise the script applies scored keyword prefiltering before the model pass. By default it prefers titles with at least 2 distinct interest-keyword hits, tops up toward `TITLE_MODEL_TARGET_MIN` (default 60) if needed, and caps at `TITLE_MODEL_CAP` (default 60). Use `/tmp/arxiv-candidates.tsv` only for debugging the mechanical dedup stage.

Pick the path based on the row count in `/tmp/arxiv-prefiltered.tsv`.

**Fast path — title input ≤ `SHORTLIST_SIZE` (default 15).** Skip the model shortlist entirely; pass the full bounded set directly to Step 9. No culling needed.

```bash
SHORTLIST_IDS=$(awk '{print $1}' /tmp/arxiv-prefiltered.tsv | xargs)
```

**Standard path — `SHORTLIST_SIZE` < title input ≤ `TITLE_MODEL_CAP` (default 60).** Single model pass: read the already-prefiltered (id, title) tuples from `/tmp/arxiv-prefiltered.tsv`, apply USER.md interests and non-interests, pick top `SHORTLIST_SIZE` (default 15) by title relevance, and assign those ids to `$SHORTLIST_IDS`. Be generous — borderline matches stay, only obvious mismatches drop.

**Keyword-prefiltered path — original candidates > `SHORTLIST_SIZE`.** The script already applied the mechanical keyword prefilter before this step. A model pass over hundreds of titles burns tokens on obvious mismatches; the cheap keyword pre-filter cuts the volume first even when the candidate count is below `TITLE_MODEL_CAP`.

1. **Keyword pre-filter (mechanical).** `scripts/arxiv-digest-prepare.sh` extracts 4+ character terms from `## Research interests`, drops common stop words, scores each title by distinct keyword hits, prefers titles with at least `KEYWORD_MIN_MATCHES` hits (default 2), tops up toward `TITLE_MODEL_TARGET_MIN` if the strict set is too small, and caps the result to `TITLE_MODEL_CAP`. Do not reimplement this in the main workflow; inspect the script only when debugging.

   If the strict result is still over `TITLE_MODEL_CAP`, take the first `TITLE_MODEL_CAP` scored lines and proceed. If the strict result is too small, top up first from one-keyword matches and then from `/tmp/arxiv-candidates.tsv` to preserve a useful title pool. If no keywords match, fall back to the first `TITLE_MODEL_CAP` deduped candidates so a bad keyword set does not produce a false empty digest.

2. **Model shortlist over the bounded subset.** Read `/tmp/arxiv-prefiltered.tsv` as-is. Do not re-filter, re-cap, or replace it during a normal run; `scripts/arxiv-digest-prepare.sh` already applied the floor, cap, and fallback logic.

**All paths output:** `$SHORTLIST_IDS`, a space-separated list of arXiv ids that pass the shortlist. Cap this list to `SHORTLIST_SIZE` before Step 9 so the abstract-ranking pass is bounded. An empty shortlist is acceptable; Step 9 will report the shortfall.

```bash
SHORTLIST_IDS=$(printf '%s\n' $SHORTLIST_IDS | head -"${SHORTLIST_SIZE:-15}" | xargs)
SHORTLIST_COUNT=$(printf '%s\n' $SHORTLIST_IDS | sed '/^$/d' | wc -l)
echo "Shortlisted ${SHORTLIST_COUNT} ids."
```

## Step 9, rank by relevance

If the shortlist from Step 8 is empty, skip Steps 9–11. Jump to Step 12 to report no relevant unbriefed papers in the latest RSS batch, then Step 13 to write a daily log entry with `**Briefed:** 0`. Do not invent or pad with weak matches.

Extract the full abstract and authors for the shortlisted ids. RSS items typically include the abstract in `<description>`; that's the primary source.

**Working template — extract from cached RSS first:**

```bash
[ -f /tmp/arxiv-run-stats.env ] && . /tmp/arxiv-run-stats.env
export API_FETCH_TIMEOUT_SEC="${API_FETCH_TIMEOUT_SEC:-45}"
export ENABLE_API_FALLBACK="${ENABLE_API_FALLBACK:-false}"
export MAX_RESULTS_PER_QUERY="${MAX_RESULTS_PER_QUERY:-500}"
export UA="${UA:-openclaw-arxiv-digest/0.1 (mailto:your-email@example.com)}"
export SHORTLIST_SIZE="${SHORTLIST_SIZE:-15}"

if [ -z "${SHORTLIST_IDS:-}" ]; then
  : > /tmp/arxiv-shortlisted.xml
  echo "Shortlist is empty; skipped RSS extraction."
  exit 0
fi

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

**Fallback if RSS entries or abstracts are missing or truncated.** RSS is the default and should be used as-is when it provides at least one usable shortlisted entry. Do not call the API just because one or more shortlisted ids are missing from RSS; that delays the whole digest for a marginal recall gain. Fetch via the API's `id_list` endpoint only when `ENABLE_API_FALLBACK=true`, or when RSS extraction produced zero usable shortlisted entries. This includes recent-list fallback runs: recent-list supplies title candidates only, so the focused `id_list` lookup is expected after shortlisting.

```bash
RSS_SHORTLISTED_COUNT=$(grep -c '<item>' /tmp/arxiv-shortlisted.xml 2>/dev/null || true)
RSS_SHORTLISTED_COUNT="${RSS_SHORTLISTED_COUNT:-0}"
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

_{Authors} · {YYYY-MM-DD} · https://arxiv.org/abs/{id}_
```

**Paper URL requirement:** every brief must include the full paper URL in the metadata line as `https://arxiv.org/abs/{id}`. Do not omit it, do not use only the bare id, and do not replace it with a title-only markdown link. The URL must appear in both the delivered digest and the Daily Log entry.

**Author formatting:** 1–3 authors → list all (e.g. "Smith, Jones, Wang"). 4+ authors → "Smith et al."

**Date formatting:** Use the `Submitted` date from arXiv, formatted in `TIMEZONE` from USER.md (e.g. `2026-05-04`).

Separate consecutive briefs with a blank line.

## Step 12, return to the active channel

Return the digest before writing the Daily Log so the user sees results as soon as ranking and briefing are complete. The log append happens afterward in Step 13.

Lead with:

*"Digest for [date], latest arXiv candidates via [FETCH_SOURCE], scanned [N] papers, [K] after dedup, [S] shortlisted, top [M] below. Log marker: [WINDOW_START → WINDOW_END]."*

Handle `SCANNED=0` before the generic `**Briefed:** = 0` case. If `SCANNED=0`, use:

*"RSS and recent-list fallback returned 0 paper items for [categories]. Scanned 0 papers; no digest entries to rank. Log marker: [WINDOW_START → WINDOW_END]."*

Keep category names as plain arXiv category codes such as `cs.CL, cs.LG`; do not turn category codes into links.

If `**Briefed:** = 0` and `SCANNED` is greater than 0, replace the lead-with sentence with:

*"No new relevant unbriefed papers in the latest arXiv candidates via [FETCH_SOURCE] — scanned [N], [K] after dedup, [S] shortlisted. Log marker: [WINDOW_START → WINDOW_END]."*

Then include the selected briefs (if any). Before sending, verify each brief contains one `https://arxiv.org/abs/` URL.

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
**Shortlisted:** 15
**Briefed:** 3

**Mechanistic Interpretability of Attention Heads in GPT-3 Class Models**

**TL;DR:** Identifies attention heads responsible for indirect object identification and demonstrates surgical ablation.
**What's new:** First fine-grained circuit-level explanation that generalizes across model scales.
**Why this matters to you:** Directly extends mechanistic interpretability of transformer attention heads.

_Smith, Jones, Wang · 2026-05-07 · https://arxiv.org/abs/2511.12345_

[two more briefs in identical format, separated by blank lines]
```

**Format invariants Step 2 depends on:**
- `**Window:**` literal, double-asterisk bold (no `*Window:*`, no `# Window`)
- One space, then `{start}Z`, one space, `→` (Unicode U+2192, not `->`), one space, `{end}Z`
- Both timestamps as ISO `YYYY-MM-DDTHH:MM` (no seconds), with `Z` suffix marking UTC

**Working template.** Reads variables computed in earlier steps and the `$BRIEFS` string composed in Step 11; appends to today's log:

```bash
[ -f /tmp/arxiv-run-stats.env ] && . /tmp/arxiv-run-stats.env
export TIMEZONE="${TIMEZONE:-UTC}"
export ARXIV_CATEGORIES="${ARXIV_CATEGORIES:-cs.LG,cs.CL}"

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

If many runs hit the `MAX_LOOKBACK_DAYS` log-marker cap after long absences, suggest enabling HEARTBEAT or setting a longer cap.

Offer suggestions, do not edit `USER.md` without asking.

## Environment variables

- `ARXIV_CATEGORIES`, default `cs.LG,cs.CL`
- `DIGEST_SIZE`, default `3`
- `SHORTLIST_SIZE`, default `15`. Caps the candidate pool sent to the rank step (Step 9). Lower = cheaper and faster but more recall risk; higher = more thorough but more tokens.
- `TITLE_MODEL_CAP`, default `60`. Maximum number of title tuples sent to the title-shortlisting model pass.
- `TITLE_MODEL_TARGET_MIN`, default `60`. Target minimum title pool after keyword scoring when enough candidates exist.
- `KEYWORD_MIN_MATCHES`, default `2`. Number of distinct interest-keyword hits required for the strict keyword prefilter.
- `MAX_FEEDS`, default `4`. Maximum number of RSS category feeds fetched per run.
- `RSS_FETCH_TIMEOUT_SEC`, default `25`. Per-feed curl timeout for RSS fetches.
- `RECENT_LIST_SHOW`, default `500`. Number of entries requested from each official arXiv recent-list fallback page when RSS returns zero items.
- `API_FETCH_TIMEOUT_SEC`, default `45`. Curl timeout for the focused `id_list` fallback.
- `ENABLE_API_FALLBACK`, default `false`. Set to `true` to enrich shortlisted ids through arXiv `id_list` when RSS entries are incomplete.
- `MAX_RESULTS_PER_QUERY`, default `500`. Upper bound for the focused arXiv API `id_list` fallback used after shortlisting, not for the RSS feed fetch.
- `MAX_LOOKBACK_DAYS`, default `4`. Caps how far back the log marker extends if the last successful run was long ago (vacation, downtime, etc.). It does not filter RSS retrieval.
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
