#!/usr/bin/env bash
set -u

[ -n "${ARXIV_CATEGORIES:-}" ] && ENV_ARXIV_CATEGORIES_SET=1 || ENV_ARXIV_CATEGORIES_SET=
[ -n "${DIGEST_SIZE:-}" ] && ENV_DIGEST_SIZE_SET=1 || ENV_DIGEST_SIZE_SET=
[ -n "${MAX_LOOKBACK_DAYS:-}" ] && ENV_MAX_LOOKBACK_DAYS_SET=1 || ENV_MAX_LOOKBACK_DAYS_SET=
[ -n "${SHORTLIST_SIZE:-}" ] && ENV_SHORTLIST_SIZE_SET=1 || ENV_SHORTLIST_SIZE_SET=
[ -n "${TITLE_MODEL_CAP:-}" ] && ENV_TITLE_MODEL_CAP_SET=1 || ENV_TITLE_MODEL_CAP_SET=
[ -n "${TITLE_MODEL_TARGET_MIN:-}" ] && ENV_TITLE_MODEL_TARGET_MIN_SET=1 || ENV_TITLE_MODEL_TARGET_MIN_SET=
[ -n "${KEYWORD_MIN_MATCHES:-}" ] && ENV_KEYWORD_MIN_MATCHES_SET=1 || ENV_KEYWORD_MIN_MATCHES_SET=
[ -n "${MAX_FEEDS:-}" ] && ENV_MAX_FEEDS_SET=1 || ENV_MAX_FEEDS_SET=
[ -n "${RSS_FETCH_TIMEOUT_SEC:-}" ] && ENV_RSS_FETCH_TIMEOUT_SEC_SET=1 || ENV_RSS_FETCH_TIMEOUT_SEC_SET=
[ -n "${RECENT_LIST_SHOW:-}" ] && ENV_RECENT_LIST_SHOW_SET=1 || ENV_RECENT_LIST_SHOW_SET=
[ -n "${API_FETCH_TIMEOUT_SEC:-}" ] && ENV_API_FETCH_TIMEOUT_SEC_SET=1 || ENV_API_FETCH_TIMEOUT_SEC_SET=
[ -n "${ENABLE_API_FALLBACK:-}" ] && ENV_ENABLE_API_FALLBACK_SET=1 || ENV_ENABLE_API_FALLBACK_SET=
[ -n "${MAX_RESULTS_PER_QUERY:-}" ] && ENV_MAX_RESULTS_PER_QUERY_SET=1 || ENV_MAX_RESULTS_PER_QUERY_SET=
[ -n "${TIMEZONE:-}" ] && ENV_TIMEZONE_SET=1 || ENV_TIMEZONE_SET=

export ARXIV_CATEGORIES="${ARXIV_CATEGORIES:-cs.LG,cs.CL}"
export DIGEST_SIZE="${DIGEST_SIZE:-3}"
export MAX_LOOKBACK_DAYS="${MAX_LOOKBACK_DAYS:-4}"
export SHORTLIST_SIZE="${SHORTLIST_SIZE:-15}"
export TITLE_MODEL_CAP="${TITLE_MODEL_CAP:-60}"
export TITLE_MODEL_TARGET_MIN="${TITLE_MODEL_TARGET_MIN:-60}"
export KEYWORD_MIN_MATCHES="${KEYWORD_MIN_MATCHES:-2}"
export MAX_FEEDS="${MAX_FEEDS:-4}"
export RSS_FETCH_TIMEOUT_SEC="${RSS_FETCH_TIMEOUT_SEC:-25}"
export RECENT_LIST_SHOW="${RECENT_LIST_SHOW:-500}"
export API_FETCH_TIMEOUT_SEC="${API_FETCH_TIMEOUT_SEC:-45}"
export ENABLE_API_FALLBACK="${ENABLE_API_FALLBACK:-false}"
export MAX_RESULTS_PER_QUERY="${MAX_RESULTS_PER_QUERY:-500}"
export TIMEZONE="${TIMEZONE:-UTC}"
export UA="${UA:-openclaw-arxiv-digest/0.1 (mailto:your-email@example.com)}"

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
SKILL_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)

resolve_workspace_dir() {
  if [ -n "${ARXIV_DIGEST_WORKSPACE:-}" ]; then
    if CDPATH= cd -- "$ARXIV_DIGEST_WORKSPACE" 2>/dev/null; then
      pwd -P
      return
    fi
    echo "ARXIV_DIGEST_WORKSPACE does not point to a readable directory; falling back to auto-detection." >&2
  fi

  workspace_candidate="$SKILL_DIR/../.."

  if [ -f USER.md ]; then
    pwd -P
    return
  fi

  if [ -f "$SKILL_DIR/USER.md" ]; then
    printf '%s\n' "$SKILL_DIR"
    return
  fi

  # Installed skill layout: <workspace>/skills/arxiv-morning-digest/scripts.
  if [ -f "$workspace_candidate/USER.md" ]; then
    CDPATH= cd -- "$workspace_candidate" && pwd -P
    return
  fi

  if [ -d memory ]; then
    pwd -P
    return
  fi

  if [ -d "$SKILL_DIR/memory" ]; then
    printf '%s\n' "$SKILL_DIR"
    return
  fi

  if [ -d "$workspace_candidate/memory" ]; then
    CDPATH= cd -- "$workspace_candidate" && pwd -P
    return
  fi

  if [ "$(basename "$SKILL_DIR")" = "arxiv-morning-digest" ] && [ "$(basename "$(dirname "$SKILL_DIR")")" = "skills" ]; then
    CDPATH= cd -- "$workspace_candidate" && pwd -P
    return
  fi

  pwd -P
}

WORKSPACE_DIR=$(resolve_workspace_dir)
USER_FILE="$WORKSPACE_DIR/USER.md"
MEMORY_DIR="$WORKSPACE_DIR/memory"

trim() {
  sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

get_skill_setting() {
  local key="$1"
  [ -f "$USER_FILE" ] || return 0
  awk -v key="$key" '
    /^## Skill-specific settings[[:space:]]*$/ { in_settings=1; next }
    /^## / && in_settings { exit }
    in_settings {
      if ($0 ~ /<!--/) in_comment=1
      if (!in_comment && /^### arxiv-morning-digest[[:space:]]*$/) { in_skill=1; next }
      if (!in_comment && /^### / && in_skill) { exit }
    }
    in_skill && !in_comment {
      line=$0
      sub(/^[[:space:]]*-[[:space:]]*/, "", line)
      name=line
      sub(/[[:space:]]*:.*/, "", name)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
      if (name == key) {
        sub(/^[^:]*:[[:space:]]*/, "", line)
        sub(/[[:space:]]+$/, "", line)
        print line
        exit
      }
    }
    in_settings && /-->/ { in_comment=0 }
  ' "$USER_FILE"
}

get_identity_timezone() {
  [ -f "$USER_FILE" ] || return 0
  awk '
    /^## Identity[[:space:]]*$/ { in_identity=1; next }
    /^## / && in_identity { exit }
    in_identity && /\*\*Timezone:\*\*/ {
      line=$0
      sub(/.*\*\*Timezone:\*\*[[:space:]]*/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line !~ /<!--/ && line != "") print line
      exit
    }
  ' "$USER_FILE"
}

apply_user_setting_default() {
  local name="$1"
  local env_flag="ENV_${name}_SET"
  local value=""

  if [ -z "${!env_flag:-}" ]; then
    value=$(get_skill_setting "$name" | trim)
    if [ -n "$value" ]; then
      printf -v "$name" '%s' "$value"
      export "$name"
      return
    fi

    if [ "$name" = "TIMEZONE" ]; then
      value=$(get_identity_timezone | trim)
      if [ -n "$value" ]; then
        printf -v "$name" '%s' "$value"
        export "$name"
      fi
    fi
  fi
}

has_research_interests() {
  [ -f "$USER_FILE" ] || return 1
  awk '
    /^## Research interests[[:space:]]*$/ { in_section=1; next }
    /^## / && in_section { exit }
    in_section {
      line=$0
      if (line ~ /<!--/) in_comment=1
      if (!in_comment) {
        sub(/^[[:space:]]*-[[:space:]]*/, "", line)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
        if (line != "" && line !~ /^specific topic[[:space:]]*[0-9]*$/ && line !~ /^\[/) found=1
      }
      if ($0 ~ /-->/) in_comment=0
    }
    END { exit found ? 0 : 1 }
  ' "$USER_FILE"
}

require_positive_int() {
  local name="$1"
  local value="${!name:-}"
  case "$value" in
    ''|*[!0-9]*|0)
      echo "${name} must be a positive integer; got '${value}'." >&2
      exit 2
      ;;
  esac
}

require_nonnegative_int() {
  local name="$1"
  local value="${!name:-}"
  case "$value" in
    ''|*[!0-9]*)
      echo "${name} must be a non-negative integer; got '${value}'." >&2
      exit 2
      ;;
  esac
}

require_bool() {
  local name="$1"
  local value="${!name:-}"
  case "$value" in
    true|false) ;;
    TRUE|True) printf -v "$name" '%s' "true"; export "$name" ;;
    FALSE|False) printf -v "$name" '%s' "false"; export "$name" ;;
    *)
      echo "${name} must be true or false; got '${value}'." >&2
      exit 2
      ;;
  esac
}

write_env_kv() {
  local name="$1"
  printf '%s=%q\n' "$name" "${!name}"
}

apply_user_setting_default ARXIV_CATEGORIES
apply_user_setting_default DIGEST_SIZE
apply_user_setting_default MAX_LOOKBACK_DAYS
apply_user_setting_default SHORTLIST_SIZE
apply_user_setting_default TITLE_MODEL_CAP
apply_user_setting_default TITLE_MODEL_TARGET_MIN
apply_user_setting_default KEYWORD_MIN_MATCHES
apply_user_setting_default MAX_FEEDS
apply_user_setting_default RSS_FETCH_TIMEOUT_SEC
apply_user_setting_default RECENT_LIST_SHOW
apply_user_setting_default API_FETCH_TIMEOUT_SEC
apply_user_setting_default ENABLE_API_FALLBACK
apply_user_setting_default MAX_RESULTS_PER_QUERY
apply_user_setting_default TIMEZONE

require_positive_int DIGEST_SIZE
require_positive_int MAX_LOOKBACK_DAYS
require_positive_int SHORTLIST_SIZE
require_positive_int TITLE_MODEL_CAP
require_positive_int TITLE_MODEL_TARGET_MIN
require_nonnegative_int KEYWORD_MIN_MATCHES
require_positive_int MAX_FEEDS
require_positive_int RSS_FETCH_TIMEOUT_SEC
require_positive_int RECENT_LIST_SHOW
require_positive_int API_FETCH_TIMEOUT_SEC
require_positive_int MAX_RESULTS_PER_QUERY
require_bool ENABLE_API_FALLBACK

if ! has_research_interests; then
  echo "No configured research interests found in ${USER_FILE}. Run setup before running the digest." >&2
  exit 2
fi

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
# not for paper retrieval, because RSS/recent-list do not use date windows.
WATERMARK_ISO=""
WATERMARK_LINE=$(grep -hE '^\*\*Window:\*\*' "$MEMORY_DIR"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].md 2>/dev/null | tail -1)
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
  cat_trimmed=$(printf '%s' "$cat" | trim)
  [ -z "$cat_trimmed" ] && continue
  case "$cat_trimmed" in
    *[!A-Za-z0-9.-]*)
      echo "Ignoring invalid arXiv category '${cat_trimmed}'. Category codes may contain only letters, digits, dots, and hyphens." >&2
      continue
      ;;
  esac
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

ls -1 "$MEMORY_DIR"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].md 2>/dev/null \
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
  awk '/^## Research interests[[:space:]]*$/ {in_section=1; next} /^## / && in_section {exit} in_section {print}' "$USER_FILE" 2>/dev/null \
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
FEEDS_FETCHED=$SUCCESS_COUNT
FEEDS_REQUESTED=${#FEED_URLS[@]}

{
  write_env_kv WORKSPACE_DIR
  write_env_kv WIN_START_ISO
  write_env_kv WIN_END_ISO
  write_env_kv ARXIV_CATEGORIES
  write_env_kv DIGEST_SIZE
  write_env_kv TIMEZONE
  write_env_kv FEEDS_FETCHED
  write_env_kv FEEDS_REQUESTED
  write_env_kv FETCH_SOURCE
  write_env_kv RECENT_LIST_SHOW
  write_env_kv SCANNED
  write_env_kv AFTER_DEDUP
  write_env_kv TITLE_MODEL_INPUT
  write_env_kv SHORTLIST_SIZE
  write_env_kv TITLE_MODEL_CAP
  write_env_kv TITLE_MODEL_TARGET_MIN
  write_env_kv KEYWORD_MIN_MATCHES
  write_env_kv MAX_FEEDS
  write_env_kv MAX_LOOKBACK_DAYS
  write_env_kv RSS_FETCH_TIMEOUT_SEC
  write_env_kv API_FETCH_TIMEOUT_SEC
  write_env_kv ENABLE_API_FALLBACK
  write_env_kv MAX_RESULTS_PER_QUERY
  write_env_kv KEYWORD_PREFILTER_APPLIED
  write_env_kv KEYWORD_PREFILTER_STRICT_MATCHES
  write_env_kv KEYWORD_PREFILTER_LOOSE_MATCHES
} > /tmp/arxiv-run-stats.env

echo "Log marker: ${WIN_START_ISO}Z -> ${WIN_END_ISO}Z"
echo "Feeds: ${SUCCESS_COUNT}/${#FEED_URLS[@]}"
echo "Scanned: ${SCANNED}; after dedup: ${AFTER_DEDUP}; strict keyword matches: ${KEYWORD_PREFILTER_STRICT_MATCHES}; loose keyword matches: ${KEYWORD_PREFILTER_LOOSE_MATCHES}; title model input: ${TITLE_MODEL_INPUT}"
