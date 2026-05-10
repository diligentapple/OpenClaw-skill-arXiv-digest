#!/usr/bin/env bash
set -u

export ARXIV_CATEGORIES="${ARXIV_CATEGORIES:-cs.LG,cs.CL}"
export MAX_LOOKBACK_DAYS="${MAX_LOOKBACK_DAYS:-4}"
export SHORTLIST_SIZE="${SHORTLIST_SIZE:-15}"
export TITLE_MODEL_CAP="${TITLE_MODEL_CAP:-60}"
export TITLE_MODEL_TARGET_MIN="${TITLE_MODEL_TARGET_MIN:-60}"
export KEYWORD_MIN_MATCHES="${KEYWORD_MIN_MATCHES:-2}"
export MAX_FEEDS="${MAX_FEEDS:-4}"
export RSS_FETCH_TIMEOUT_SEC="${RSS_FETCH_TIMEOUT_SEC:-25}"
export RECENT_LIST_SHOW="${RECENT_LIST_SHOW:-500}"
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
      /tmp/arxiv-list-*.html /tmp/arxiv-list-code-*.txt /tmp/arxiv-list-err-*.txt \
      /tmp/arxiv-id-title.tsv /tmp/arxiv-seen-ids.txt /tmp/arxiv-candidates.tsv \
      /tmp/arxiv-prefiltered.tsv /tmp/arxiv-prefiltered-capped.tsv /tmp/arxiv-run-stats.env \
      /tmp/arxiv-keywords.txt /tmp/arxiv-prefiltered-strict.tsv /tmp/arxiv-prefiltered-loose.tsv \
      /tmp/arxiv-prefiltered-loose-sorted.tsv

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
RSS_FILES=()
for url in "${FEED_URLS[@]}"; do
  cat=$(basename "$url")
  out="/tmp/arxiv-rss-${cat}.xml"
  code_file="/tmp/arxiv-code-${cat}.txt"
  CODE=$(cat "$code_file" 2>/dev/null || printf '000')
  if [ "$CODE" = "200" ]; then
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    RSS_FILES+=("$out")
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

awk -f /tmp/arxiv-extract-id-title.awk "${RSS_FILES[@]}" | awk -F '\t' '!seen[$1]++' > /tmp/arxiv-id-title.tsv
SCANNED=$(wc -l < /tmp/arxiv-id-title.tsv)
FETCH_SOURCE="rss"

if [ "$SCANNED" -eq 0 ]; then
  echo "RSS returned 0 item entries; falling back to arXiv recent listings."
  pids=()
  for url in "${FEED_URLS[@]}"; do
    cat=$(basename "$url")
    list_url="https://arxiv.org/list/${cat}/recent?skip=0&show=${RECENT_LIST_SHOW}"
    out="/tmp/arxiv-list-${cat}.html"
    code_file="/tmp/arxiv-list-code-${cat}.txt"
    err_file="/tmp/arxiv-list-err-${cat}.txt"
    echo "Fetching recent listing ${cat}..."
    (
      CODE=$(curl --globoff --connect-timeout 8 --max-time "$RSS_FETCH_TIMEOUT_SEC" \
        -A "$UA" -L -sS -o "$out" -w "%{http_code}" "$list_url" 2>"$err_file" || echo "000")
      CODE="${CODE:0:3}"
      printf '%s\n' "$CODE" > "$code_file"
    ) &
    pids+=($!)
  done

  for pid in "${pids[@]}"; do
    wait "$pid" || true
  done

  LIST_FILES=()
  for url in "${FEED_URLS[@]}"; do
    cat=$(basename "$url")
    out="/tmp/arxiv-list-${cat}.html"
    code_file="/tmp/arxiv-list-code-${cat}.txt"
    CODE=$(cat "$code_file" 2>/dev/null || printf '000')
    if [ "$CODE" != "200" ]; then
      echo "Recent listing for ${cat} returned HTTP ${CODE}; skipping."
      rm -f "$out"
    else
      LIST_FILES+=("$out")
    fi
  done

  cat > /tmp/arxiv-extract-list-id-title.awk <<'AWK'
    /<dt>/ { in_dt=1; id="" }
    in_dt && /\/abs\/[0-9]{4}\.[0-9]+/ {
      match($0, /\/abs\/[0-9]{4}\.[0-9]+/)
      if (RSTART > 0) id = substr($0, RSTART + 5, RLENGTH - 5)
    }
    /<\/dt>/ { in_dt=0 }
    id != "" && /<div class=.list-title/ {
      in_title=1
      line=$0
      sub(/.*<span class=.descriptor.>Title:<\/span>/, "", line)
      title=line
      if (line ~ /<\/div>/) {
        in_title=0
        sub(/<\/div>.*/, "", title)
        gsub(/<[^>]*>/, "", title)
        gsub(/&amp;/, "\\&", title)
        gsub(/[[:space:]]+/, " ", title)
        sub(/^[[:space:]]+/, "", title)
        sub(/[[:space:]]+$/, "", title)
        if (title != "") print id "\t" title
        id=""
      }
      next
    }
    in_title {
      line=$0
      if (line ~ /<\/div>/) {
        sub(/<\/div>.*/, "", line)
        in_title=0
      }
      title = title " " line
      if (!in_title) {
        gsub(/<[^>]*>/, "", title)
        gsub(/&amp;/, "\\&", title)
        gsub(/[[:space:]]+/, " ", title)
        sub(/^[[:space:]]+/, "", title)
        sub(/[[:space:]]+$/, "", title)
        if (title != "") print id "\t" title
        id=""
      }
    }
AWK

  if [ "${#LIST_FILES[@]}" -gt 0 ]; then
    awk -f /tmp/arxiv-extract-list-id-title.awk "${LIST_FILES[@]}" 2>/dev/null | awk -F '\t' '!seen[$1]++' > /tmp/arxiv-id-title.tsv
  else
    : > /tmp/arxiv-id-title.tsv
  fi
  SCANNED=$(wc -l < /tmp/arxiv-id-title.tsv)
  if [ "$SCANNED" -gt 0 ]; then
    FETCH_SOURCE="recent-list"
  fi
fi

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
KEYWORD_PREFILTER_APPLIED=false
KEYWORD_PREFILTER_STRICT_MATCHES=0
KEYWORD_PREFILTER_LOOSE_MATCHES=0

if [ "$AFTER_DEDUP" -le "$SHORTLIST_SIZE" ]; then
  cp /tmp/arxiv-candidates.tsv /tmp/arxiv-prefiltered.tsv
else
  KEYWORD_PREFILTER_APPLIED=true
  awk '/^## Research interests[[:space:]]*$/ {in_section=1; next} /^## / && in_section {exit} in_section {print}' USER.md 2>/dev/null \
    | grep -oE '\b[a-zA-Z][a-zA-Z.-]{3,}\b' \
    | grep -viE '^(that|this|with|from|their|which|these|those|about|across|under|between|through|beyond|rather|should|could|would|using|based|into|onto|over|after|before|where|when|what|have|has|been|being|such|including|without|within|toward|towards|paper|papers|research|method|methods|model|models|learning|system|systems)$' \
    | sort -fu > /tmp/arxiv-keywords.txt

  if [ -s /tmp/arxiv-keywords.txt ]; then
    awk -F '\t' -v kw_file="/tmp/arxiv-keywords.txt" -v min_matches="$KEYWORD_MIN_MATCHES" \
      -v strict_out="/tmp/arxiv-prefiltered-strict.tsv" -v loose_out="/tmp/arxiv-prefiltered-loose.tsv" '
      BEGIN {
        while ((getline term < kw_file) > 0) {
          if (term != "") kw[++n] = tolower(term)
        }
      }
      {
        title = tolower($0)
        score = 0
        for (i = 1; i <= n; i++) {
          if (index(title, kw[i]) > 0) score++
        }
        if (score >= min_matches) print score "\t" $0 >> strict_out
        else if (score > 0) print score "\t" $0 >> loose_out
      }
    ' /tmp/arxiv-candidates.tsv
    sort -k1,1nr -s /tmp/arxiv-prefiltered-strict.tsv 2>/dev/null | cut -f2- > /tmp/arxiv-prefiltered.tsv
    sort -k1,1nr -s /tmp/arxiv-prefiltered-loose.tsv 2>/dev/null | cut -f2- > /tmp/arxiv-prefiltered-loose-sorted.tsv
  else
    : > /tmp/arxiv-prefiltered.tsv
    : > /tmp/arxiv-prefiltered-loose-sorted.tsv
  fi

  PREFILTER_COUNT=$(wc -l < /tmp/arxiv-prefiltered.tsv)
  KEYWORD_PREFILTER_STRICT_MATCHES=$PREFILTER_COUNT
  KEYWORD_PREFILTER_LOOSE_MATCHES=$(wc -l < /tmp/arxiv-prefiltered-loose-sorted.tsv 2>/dev/null || echo 0)
  TARGET_MIN=$TITLE_MODEL_TARGET_MIN
  [ "$TARGET_MIN" -gt "$TITLE_MODEL_CAP" ] && TARGET_MIN=$TITLE_MODEL_CAP
  [ "$TARGET_MIN" -gt "$AFTER_DEDUP" ] && TARGET_MIN=$AFTER_DEDUP

  if [ "$PREFILTER_COUNT" -eq 0 ] && [ "$KEYWORD_PREFILTER_LOOSE_MATCHES" -gt 0 ]; then
    head -"$TITLE_MODEL_CAP" /tmp/arxiv-prefiltered-loose-sorted.tsv > /tmp/arxiv-prefiltered.tsv
  elif [ "$PREFILTER_COUNT" -eq 0 ]; then
    head -"$TITLE_MODEL_CAP" /tmp/arxiv-candidates.tsv > /tmp/arxiv-prefiltered.tsv
  elif [ "$PREFILTER_COUNT" -lt "$TARGET_MIN" ]; then
    awk 'NR==FNR { seen[$1]=1; print; next } !($1 in seen) { seen[$1]=1; print }' \
      /tmp/arxiv-prefiltered.tsv /tmp/arxiv-prefiltered-loose-sorted.tsv /tmp/arxiv-candidates.tsv \
      | head -"$TARGET_MIN" > /tmp/arxiv-prefiltered-capped.tsv
    mv /tmp/arxiv-prefiltered-capped.tsv /tmp/arxiv-prefiltered.tsv
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
FETCH_SOURCE='$FETCH_SOURCE'
RECENT_LIST_SHOW='$RECENT_LIST_SHOW'
SCANNED='$SCANNED'
AFTER_DEDUP='$AFTER_DEDUP'
TITLE_MODEL_INPUT='$TITLE_MODEL_INPUT'
SHORTLIST_SIZE='$SHORTLIST_SIZE'
TITLE_MODEL_CAP='$TITLE_MODEL_CAP'
TITLE_MODEL_TARGET_MIN='$TITLE_MODEL_TARGET_MIN'
KEYWORD_MIN_MATCHES='$KEYWORD_MIN_MATCHES'
KEYWORD_PREFILTER_APPLIED='$KEYWORD_PREFILTER_APPLIED'
KEYWORD_PREFILTER_STRICT_MATCHES='$KEYWORD_PREFILTER_STRICT_MATCHES'
KEYWORD_PREFILTER_LOOSE_MATCHES='$KEYWORD_PREFILTER_LOOSE_MATCHES'
EOF

echo "Log marker: ${WIN_START_ISO}Z -> ${WIN_END_ISO}Z"
echo "Feeds: ${SUCCESS_COUNT}/${#FEED_URLS[@]}"
echo "Scanned: ${SCANNED}; after dedup: ${AFTER_DEDUP}; strict keyword matches: ${KEYWORD_PREFILTER_STRICT_MATCHES}; loose keyword matches: ${KEYWORD_PREFILTER_LOOSE_MATCHES}; title model input: ${TITLE_MODEL_INPUT}"
