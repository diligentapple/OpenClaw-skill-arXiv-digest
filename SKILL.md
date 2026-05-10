---
name: arxiv-morning-digest
description: Produces a personalized digest of recent arXiv papers ranked by relevance to the researcher's stated interests in USER.md. Use when the user wants a morning paper digest, a personalized arXiv feed, or asks "what's new on arxiv", "arxiv digest", "arxiv morning digest", "today's papers", "morning digest", or "/digest". Supports daily heartbeat-style runs and on-demand chat runs. For first-time setup, see SETUP.md.
---

# ArXiv Morning Digest

> **First-time setup required.** If the workspace does not yet have a populated `USER.md` with a non-empty `## Research interests` section, stop and run `SETUP.md`.

This skill fetches the latest official arXiv category candidates, shortlists them against the user's profile, writes an auditable Daily Log entry, and returns a concise digest.

## Core rules

- Use the checked-in bash script for mechanical preparation. Do not recreate its RSS, recent-list, date, dedup, or keyword-prefilter logic in chat.
- Use RSS first: `https://rss.arxiv.org/rss/<category>`. The prepare script falls back to official recent-list pages only when RSS returns HTTP 200 but zero `<item>` entries.
- Do not use the arXiv search API for bulk title discovery. The `export.arxiv.org/api/query?id_list=...` endpoint is allowed only after shortlisting, to fetch details for already-selected ids.
- Do not pivot to web search, individual `/abs/<id>` scraping, or alternate data sources when official fetches fail.
- Keep the run bounded: default `MAX_FEEDS=4`, `TITLE_MODEL_CAP=60`, `SHORTLIST_SIZE=15`, `DIGEST_SIZE=3`.
- Metadata lines must be plain text, with the arXiv URL as the final token. Do not wrap the URL line in `_`, `*`, brackets, angle brackets, punctuation, or Markdown links.

## Configuration

The prepare script reads configuration in this order:

1. Environment variables, when set.
2. `USER.md` section `## Skill-specific settings` / `### arxiv-morning-digest`.
3. Built-in defaults.

Supported variables:

- `ARXIV_CATEGORIES`, default `cs.LG,cs.CL`
- `DIGEST_SIZE`, default `3` (used by the ranking/briefing step)
- `SHORTLIST_SIZE`, default `15`
- `TITLE_MODEL_CAP`, default `60`
- `TITLE_MODEL_TARGET_MIN`, default `60`
- `KEYWORD_MIN_MATCHES`, default `2`
- `MAX_FEEDS`, default `4`
- `RSS_FETCH_TIMEOUT_SEC`, default `25`
- `RECENT_LIST_SHOW`, default `500`
- `API_FETCH_TIMEOUT_SEC`, default `45`
- `ENABLE_API_FALLBACK`, default `false`
- `MAX_RESULTS_PER_QUERY`, default `500`
- `MAX_LOOKBACK_DAYS`, default `4`
- `TIMEZONE`, default from `USER.md` `## Identity` / `Timezone`, then `UTC`

## Workflow

### Step 1, Resolve Profile

Read the workspace `USER.md`, not `USER.md.template` or `USER.md.example`.

If `ARXIV_DIGEST_WORKSPACE` is set, use that directory. Otherwise, when this skill is installed at `skills/arxiv-morning-digest`, the workspace is two directories above the skill root. The prepare script uses the same resolver and writes `WORKSPACE_DIR` to `/tmp/arxiv-run-stats.env`.

If `USER.md` is missing or `## Research interests` is empty, respond:

```text
No research interests configured yet. Type "set up arxiv digest" to configure, then I'll start delivering each morning.
```

Then append a skip note to `${WORKSPACE_DIR}/memory/YYYY-MM-DD.md` and stop. Do not fetch papers without a real profile.

```bash
WORKSPACE_DIR="${ARXIV_DIGEST_WORKSPACE:-$(pwd -P)}"
mkdir -p "${WORKSPACE_DIR}/memory"
TODAY=$(TZ="${TIMEZONE:-UTC}" date '+%Y-%m-%d')
{
  echo ""
  echo "## ArXiv Digest"
  echo "**Status:** Skipped - no research interests configured."
} >> "${WORKSPACE_DIR}/memory/${TODAY}.md"
```

If the user asked to set up or reconfigure the digest, read `SETUP.md` and follow it.

### Step 2, Prepare Candidates

Run the checked-in prepare script once:

```bash
SCRIPT="skills/arxiv-morning-digest/scripts/arxiv-digest-prepare.sh"
[ -f "$SCRIPT" ] || SCRIPT="scripts/arxiv-digest-prepare.sh"
bash "$SCRIPT"
```

The script handles:

- workspace/profile resolution
- user settings and timezone defaults
- config validation
- run watermark calculation
- RSS fetch and recent-list fallback
- id/title extraction
- dedup against recent Daily Logs
- keyword prefiltering and title-pool capping

It writes:

- `/tmp/arxiv-prefiltered.tsv` - bounded `id<TAB>title` rows for the model shortlist pass
- `/tmp/arxiv-candidates.tsv` - deduped candidates before title-pool capping
- `/tmp/arxiv-run-stats.env` - shell variables including `WORKSPACE_DIR`, `TIMEZONE`, `WIN_START_ISO`, `WIN_END_ISO`, `FETCH_SOURCE`, `SCANNED`, `AFTER_DEDUP`, and `TITLE_MODEL_INPUT`

If the script exits with a missing-profile or invalid-config message, report that directly and do not continue. If it exits because all official fetches failed, report the failure in active chat; for scheduled delivery, append an error note to the Daily Log and stay silent. Do not write a `**Window:**` line on failure.

### Step 3, Shortlist Titles

Read `/tmp/arxiv-prefiltered.tsv`.

If it has at most `SHORTLIST_SIZE` rows, use all ids:

```bash
[ -f /tmp/arxiv-run-stats.env ] && . /tmp/arxiv-run-stats.env
SHORTLIST_IDS=$(awk '{print $1}' /tmp/arxiv-prefiltered.tsv | head -"${SHORTLIST_SIZE:-15}" | xargs)
SHORTLIST_COUNT=$(printf '%s\n' $SHORTLIST_IDS | sed '/^$/d' | wc -l)
echo "Shortlisted ${SHORTLIST_COUNT} ids."
```

If it has more than `SHORTLIST_SIZE` rows, do one model pass over the provided title rows. Apply `USER.md` interests and explicit non-interests; pick up to `SHORTLIST_SIZE` ids by likely relevance. Be generous with plausible matches, but drop obvious mismatches. Do not replace or re-cap `/tmp/arxiv-prefiltered.tsv`; the prepare script already did the mechanical filtering.

If no titles remain after dedup, set `SHORTLIST_IDS=""`, `SHORTLISTED=0`, and `BRIEFED=0`; skip Steps 4-6 and continue to Step 7.

### Step 4, Fetch Shortlisted Details

Run one focused extraction command after setting `SHORTLIST_IDS`:

```bash
[ -f /tmp/arxiv-run-stats.env ] && . /tmp/arxiv-run-stats.env
export API_FETCH_TIMEOUT_SEC="${API_FETCH_TIMEOUT_SEC:-45}"
export ENABLE_API_FALLBACK="${ENABLE_API_FALLBACK:-false}"
export MAX_RESULTS_PER_QUERY="${MAX_RESULTS_PER_QUERY:-500}"
export UA="${UA:-openclaw-arxiv-digest/0.1 (mailto:your-email@example.com)}"

: > /tmp/arxiv-shortlisted.xml

if [ -z "${SHORTLIST_IDS:-}" ]; then
  echo "Shortlist is empty; skipped detail extraction."
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

RSS_FILES=(/tmp/arxiv-rss-*.xml)
if [ -e "${RSS_FILES[0]}" ]; then
  awk -v pat="$SHORTLIST_PATTERN" -f /tmp/arxiv-extract-shortlisted.awk "${RSS_FILES[@]}" > /tmp/arxiv-shortlisted.xml
fi

RSS_SHORTLISTED_COUNT=$(grep -c '<item>' /tmp/arxiv-shortlisted.xml 2>/dev/null || true)
RSS_SHORTLISTED_COUNT="${RSS_SHORTLISTED_COUNT:-0}"

if [ "${ENABLE_API_FALLBACK:-false}" = "true" ] || [ "${FETCH_SOURCE:-rss}" = "recent-list" ] || [ "$RSS_SHORTLISTED_COUNT" -eq 0 ]; then
  IDS_CSV=$(echo "$SHORTLIST_IDS" | tr ' ' ',')
  URL="https://export.arxiv.org/api/query?id_list=${IDS_CSV}&max_results=${MAX_RESULTS_PER_QUERY}"
  CODE=$(curl --globoff --connect-timeout 8 --max-time "$API_FETCH_TIMEOUT_SEC" \
    -A "$UA" -L -sS -o /tmp/arxiv-shortlisted-api.xml -w "%{http_code}" "$URL" || echo "000")
  CODE="${CODE:0:3}"
  if [ "$CODE" = "200" ]; then
    mv /tmp/arxiv-shortlisted-api.xml /tmp/arxiv-shortlisted.xml
  else
    rm -f /tmp/arxiv-shortlisted-api.xml
    if [ "$RSS_SHORTLISTED_COUNT" -eq 0 ]; then
      echo "Focused id_list fallback returned HTTP ${CODE}; no shortlisted details are available." >&2
      exit 1
    fi
    echo "Focused id_list fallback returned HTTP ${CODE}; ranking available RSS entries only."
  fi
fi

echo "Detail file ready: /tmp/arxiv-shortlisted.xml"
```

Read `/tmp/arxiv-shortlisted.xml` directly for ranking. It may contain RSS `<item>` entries or arXiv API Atom `<entry>` records; both are acceptable. Do not run brittle one-off parsers that discard metadata the model can use.

### Step 5, Rank And Select

Rank the shortlisted papers by semantic relevance to the configured interests, not just keyword overlap. Use explicit non-interests to drop or down-rank mismatches. Prefer newer submissions when relevance is otherwise tied.

Keep up to `DIGEST_SIZE` meaningfully relevant papers. If fewer qualify, deliver fewer and mention the shortfall. If none qualify, set `BRIEFED=0` and do not pad with weak matches.

### Step 6, Generate Briefs

Use exactly this brief shape:

```text
**{Title}**

**TL;DR:** {one plain-language sentence - what the paper actually does}
**What's new:** {one sentence - the specific contribution beyond prior work}
**Why this matters to you:** {one sentence - connect to a specific USER.md interest}

{Authors} · {YYYY-MM-DD} · https://arxiv.org/abs/{id}
```

Author format:

- 1-3 authors: list all surnames, e.g. `Smith, Jones, Wang`
- 4+ authors: `{FirstAuthor} et al.`

Date format: use arXiv's submitted/published date rendered in `TIMEZONE`.

Before returning or logging, verify every selected brief has exactly one `https://arxiv.org/abs/` URL and that the URL is the final token on its metadata line.

### Step 7, Return Digest

Return the digest before writing the Daily Log.

Normal lead:

```text
Digest for {YYYY-MM-DD}, latest arXiv candidates via {FETCH_SOURCE}, scanned {SCANNED} papers, {AFTER_DEDUP} after dedup, {SHORTLISTED} shortlisted, top {BRIEFED} below. Log marker: {WIN_START_ISO}Z -> {WIN_END_ISO}Z.
```

If `SCANNED=0`:

```text
RSS and recent-list fallback returned 0 paper items for {ARXIV_CATEGORIES}. Scanned 0 papers; no digest entries to rank. Log marker: {WIN_START_ISO}Z -> {WIN_END_ISO}Z.
```

If `BRIEFED=0` and `SCANNED>0`:

```text
No new relevant unbriefed papers in the latest arXiv candidates via {FETCH_SOURCE} - scanned {SCANNED}, {AFTER_DEDUP} after dedup, {SHORTLISTED} shortlisted. Log marker: {WIN_START_ISO}Z -> {WIN_END_ISO}Z.
```

Keep category names as plain codes such as `cs.CL, cs.LG`; do not turn category codes into links. For asynchronous scheduled delivery, post a separate message rather than interrupting an active exchange.

### Step 8, Write Daily Log

Append a new section to `${WORKSPACE_DIR}/memory/YYYY-MM-DD.md`. Never overwrite the file. A successful run, including a run with `BRIEFED=0`, writes a `**Window:**` line. A failed fetch does not.

The `**Window:**` line is a parser contract. Keep its markup and timestamp shape exactly:

```text
**Window:** {WIN_START_ISO}Z → {WIN_END_ISO}Z
```

Use this append command after composing `BRIEFS`, `SHORTLISTED`, and `BRIEFED`:

```bash
[ -f /tmp/arxiv-run-stats.env ] && . /tmp/arxiv-run-stats.env
export TIMEZONE="${TIMEZONE:-UTC}"
export ARXIV_CATEGORIES="${ARXIV_CATEGORIES:-cs.LG,cs.CL}"

WORKSPACE_DIR="${WORKSPACE_DIR:-$(pwd -P)}"
TZ_VAL="${TIMEZONE:-UTC}"
TODAY=$(TZ="$TZ_VAL" date '+%Y-%m-%d')
RUN_AT=$(TZ="$TZ_VAL" date '+%Y-%m-%d %H:%M %z')
LOG="${WORKSPACE_DIR}/memory/${TODAY}.md"
mkdir -p "${WORKSPACE_DIR}/memory"

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

printf '%s\n' "$BRIEFS" >> "$LOG"
echo "Wrote digest to $LOG"
```

## Proactive Tuning

- If fewer than `DIGEST_SIZE` relevant papers surface for 2 or more days in a row, suggest broadening `ARXIV_CATEGORIES` or loosening the phrasing in `USER.md`.
- If the user rejects multiple papers as irrelevant, suggest tightening interests or adding `## Explicit non-interests`.
- If the user consistently reads every brief carefully, suggest increasing `DIGEST_SIZE`.
- If many runs hit the `MAX_LOOKBACK_DAYS` log-marker cap after long absences, suggest enabling HEARTBEAT or setting a longer cap.

Offer suggestions; do not edit `USER.md` without asking.

## Expected USER.md Sections

```markdown
## Research interests
- [specific topic 1]
- [specific topic 2]
- [specific topic 3]

## Explicit non-interests
- [topic to exclude]

## Skill-specific settings

### arxiv-morning-digest
- ARXIV_CATEGORIES: cs.LG, cs.CL
- DIGEST_SIZE: 3
```

Prefer 3 to 5 specific interests.

## Tools Required

- Read
- Write
- Bash with `curl`, `awk`, `sed`, and `grep`

## Scope Boundaries

This skill is for daily discovery and triage. Use a dedicated paper-reading workflow for deep reads, a search-collector workflow for broader literature collection, and separate review workflows for peer-review preparation.
