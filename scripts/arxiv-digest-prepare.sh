#!/usr/bin/env bash
set -u

export ARXIV_CATEGORIES="${ARXIV_CATEGORIES:-cs.LG,cs.CL}"
export MAX_LOOKBACK_DAYS="${MAX_LOOKBACK_DAYS:-4}"
export SHORTLIST_SIZE="${SHORTLIST_SIZE:-15}"
export TITLE_MODEL_CAP="${TITLE_MODEL_CAP:-250}"
export MAX_FEEDS="${MAX_FEEDS:-4}"
export RSS_FETCH_TIMEOUT_SEC="${RSS_FETCH_TIMEOUT_SEC:-25}"
export TIMEZONE="${TIMEZONE:-UTC}"
export UA="${UA:-openclaw-arxiv-digest/0.1 (mailto:your-email@example.com)}"

LOCK_DIR="/tmp/arxiv-digest.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "Another arxiv digest preparation is already running; try again after it finishes." >&2
  exit 1
fi
trap 'rm -rf "$LOCK_DIR"' EXIT

mkdir -p /tmp
rm -f /tmp/arxiv-rss-*.xml /tmp/arxiv-code-*.txt /tmp/arxiv-err-*.txt \
      /tmp/arxiv-id-title.tsv /tmp/arxiv-seen-ids.txt /tmp/arxiv-candidates.tsv \
      /tmp/arxiv-prefiltered.tsv /tmp/arxiv-prefiltered-capped.tsv /tmp/arxiv-run-stats.env

# Find the last successful run marker. This is for logging and dedup context,
# not for RSS retrieval, because RSS always returns the latest announcement batch.
WATERMARK_ISO=""
WATERMARK_LINE=$(grep -hE '^\*\*Window:\*\*' memory/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].md 2>/dev/null | tail -1)
if [ -n "$WATERMARK_LINE" ]; then
  WATERMARK_ISO=$(printf '%s\n' "$WATERMARK_LINE" | sed -nE 's/.*->[[:space:]]*([0-9-]+T[0-9:]+)Z.*/\1/p')
  if [ -z "$WATERMARK_ISO" ]; then
    WATERMARK_ISO=$(printf '%s\n' "$WATERMARK_LINE" | sed -nE 's/.*→[[:space:]]*([0-9-]+T[0-9:]+)Z.*/\1/p')
  fi
fi

NOW_EPOCH=$(date -u +%s)
WATERMARK_EPOCH=""
if [ -n "$WATERMARK_ISO" ]; then
  WATERMARK_EPOCH=$(date -u -d "${WATERMARK_ISO}Z" +%s 2>/dev/null || true)
fi

HAS_PRIOR_WATERMARK=1
case "$WATERMARK_EPOCH" in
  ''|*[!0-9]*)
    HAS_PRIOR_WATERMARK=0
    WATERMARK_EPOCH=$NOW_EPOCH
    ;;
esac

if [ "$HAS_PRIOR_WATERMARK" -eq 1 ]; then
  WIN_START_EPOCH=$((WATERMARK_EPOCH - 43200))
  MIN_START_EPOCH=$((NOW_EPOCH - MAX_LOOKBACK_DAYS * 86400))
  [ "$WIN_START_EPOCH" -lt "$MIN_START_EPOCH" ] && WIN_START_EPOCH=$MIN_START_EPOCH
else
  WIN_START_EPOCH=$NOW_EPOCH
fi

WIN_START_ISO=$(date -u -d "@$WIN_START_EPOCH" '+%Y-%m-%dT%H:%M')
WIN_END_ISO=$(date -u -d "@$NOW_EPOCH" '+%Y-%m-%dT%H:%M')

FEED_URLS=()
IFS=',' read -ra CATS <<< "$ARXIV_CATEGORIES"
for cat in "${CATS[@]}"; do
  [ "${#FEED_URLS[@]}" -ge "$MAX_FEEDS" ] && break
  cat_trimmed=$(printf '%s' "$cat" | xargs)
  [ -z "$cat_trimmed" ] && continue
  FEED_URLS+=("https://rss.arxiv.org/rss/${cat_trimmed}")
done

if [ "${#FEED_URLS[@]}" -eq 0 ]; then
  echo "No arXiv categories configured after parsing ARXIV_CATEGORIES." >&2
  exit 1
fi

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
  code_file="/tmp/arxiv-code-${cat}.txt"
  CODE=$(cat "$code_file" 2>/dev/null || printf '000')
  if [ "$CODE" = "200" ]; then
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
  else
    echo "Feed for ${cat} returned HTTP ${CODE}; skipping."
    rm -f "$out"
  fi
done

if [ "$SUCCESS_COUNT" -eq 0 ]; then
  echo "All RSS feeds failed. Try again in a few minutes." >&2
  exit 1
fi

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
SCANNED=$(wc -l < /tmp/arxiv-id-title.tsv)

ls -1 memory/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].md 2>/dev/null \
  | sort -r | head -"$MAX_LOOKBACK_DAYS" \
  | xargs -r grep -hoE 'arxiv\.org/abs/[0-9]{4}\.[0-9]+(v[0-9]+)?' 2>/dev/null \
  | sed 's|.*/||; s|v[0-9]*$||' | sort -u > /tmp/arxiv-seen-ids.txt

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
AFTER_DEDUP=$(wc -l < /tmp/arxiv-candidates.tsv)

if [ "$AFTER_DEDUP" -le "$TITLE_MODEL_CAP" ]; then
  cp /tmp/arxiv-candidates.tsv /tmp/arxiv-prefiltered.tsv
else
  KEYWORDS=$(awk '/^## Research interests[[:space:]]*$/ {in_section=1; next} /^## / && in_section {exit} in_section {print}' USER.md 2>/dev/null \
    | grep -oE '\b[a-zA-Z][a-zA-Z.-]{3,}\b' \
    | grep -viE '^(that|this|with|from|their|which|these|those|about|across|under|between|through|beyond|rather|should|could|would|using|based|into|onto|over|after|before|where|when|what|have|has|been|being|such|including|without|within|toward|towards|paper|papers|research|method|methods|model|models|learning|system|systems)$' \
    | sed 's/[.]/[.]/g' \
    | sort -u | paste -sd '|')
  if [ -n "$KEYWORDS" ]; then
    grep -iE "$KEYWORDS" /tmp/arxiv-candidates.tsv > /tmp/arxiv-prefiltered.tsv || true
  else
    : > /tmp/arxiv-prefiltered.tsv
  fi
  PREFILTER_COUNT=$(wc -l < /tmp/arxiv-prefiltered.tsv)
  if [ "$PREFILTER_COUNT" -eq 0 ]; then
    head -"$TITLE_MODEL_CAP" /tmp/arxiv-candidates.tsv > /tmp/arxiv-prefiltered.tsv
  elif [ "$PREFILTER_COUNT" -gt "$TITLE_MODEL_CAP" ]; then
    head -"$TITLE_MODEL_CAP" /tmp/arxiv-prefiltered.tsv > /tmp/arxiv-prefiltered-capped.tsv
    mv /tmp/arxiv-prefiltered-capped.tsv /tmp/arxiv-prefiltered.tsv
  fi
fi

TITLE_MODEL_INPUT=$(wc -l < /tmp/arxiv-prefiltered.tsv)

cat > /tmp/arxiv-run-stats.env <<EOF
WIN_START_ISO='$WIN_START_ISO'
WIN_END_ISO='$WIN_END_ISO'
ARXIV_CATEGORIES='$ARXIV_CATEGORIES'
FEEDS_FETCHED='$SUCCESS_COUNT'
FEEDS_REQUESTED='${#FEED_URLS[@]}'
SCANNED='$SCANNED'
AFTER_DEDUP='$AFTER_DEDUP'
TITLE_MODEL_INPUT='$TITLE_MODEL_INPUT'
SHORTLIST_SIZE='$SHORTLIST_SIZE'
TITLE_MODEL_CAP='$TITLE_MODEL_CAP'
EOF

echo "Log marker: ${WIN_START_ISO}Z -> ${WIN_END_ISO}Z"
echo "Feeds: ${SUCCESS_COUNT}/${#FEED_URLS[@]}"
echo "Scanned: ${SCANNED}; after dedup: ${AFTER_DEDUP}; title model input: ${TITLE_MODEL_INPUT}"
