#!/usr/bin/env bash
# analyze-claude.sh - Build HTML insights report from Claude Code data
# Reads pre-computed session metadata at ~/.claude/usage-data/session-meta/*.json
# Output: ~/.claude/usage-data/claude-insights.html
set -euo pipefail
if locale -a 2>/dev/null | grep -q 'C.UTF-8'; then
  export LC_ALL=C.UTF-8
elif locale -a 2>/dev/null | grep -q 'en_US.UTF-8'; then
  export LC_ALL=en_US.UTF-8
fi

# HTML escape helper to prevent XSS.
# Bash's `${s//pat/repl}` treats unescaped `&` in replacement as the matched
# pattern (sed-style), so entities must be written `\&amp;` etc.
html_escape() {
  local s="$1"
  s="${s//&/\&amp;}"
  s="${s//</\&lt;}"
  s="${s//>/\&gt;}"
  s="${s//\"/\&quot;}"
  echo "$s"
}

# Human-readable integer (K/M/B suffix)
fmt_num() {
  awk -v n="$1" 'BEGIN {
    if (n+0 >= 1e9)      printf "%.2fB", n/1e9;
    else if (n+0 >= 1e6) printf "%.1fM", n/1e6;
    else if (n+0 >= 1e3) printf "%.1fK", n/1e3;
    else                 printf "%d", n
  }'
}

CLAUDE_DIR="${HOME}/.claude"
SESSION_META_DIR="${CLAUDE_DIR}/usage-data/session-meta"
PROJECTS_DIR="${CLAUDE_DIR}/projects"
OUTPUT_DIR="${CLAUDE_DIR}/usage-data"
OUTPUT_HTML="${OUTPUT_DIR}/claude-insights.html"
mkdir -p "$OUTPUT_DIR"
TMPDIR_WORK=$(mktemp -d)
trap 'rm -rf "$TMPDIR_WORK"' EXIT

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required (brew install jq)" >&2
  exit 1
fi

if [[ ! -d "$SESSION_META_DIR" ]]; then
  echo "Error: ${SESSION_META_DIR} not found." >&2
  echo "Run Claude Code's /insights command first." >&2
  exit 1
fi

# ═══════════════════════════════════════
# Data Collection — combine all session-meta into one stream
# ═══════════════════════════════════════

# Slurp all session-meta JSON files into one array
combined="${TMPDIR_WORK}/combined.json"
jq -s '.' "${SESSION_META_DIR}"/*.json > "$combined"

total_sessions=$(jq 'length' "$combined")
total_user_msgs=$(jq '[.[] | .user_message_count // 0] | add // 0' "$combined")
total_asst_msgs=$(jq '[.[] | .assistant_message_count // 0] | add // 0' "$combined")

# session-meta's input_tokens/output_tokens EXCLUDE cache reads and cache creation,
# so they understate real model work by 100-1000x for sessions with prefix caching.
# Walk each session's rollout JSONL to sum honest token usage (input + output +
# cache_creation + cache_read), matching what Codex's tokens_used represents.
echo "Walking session JSONLs for honest token totals..." >&2
token_map_json="${TMPDIR_WORK}/token_map.json"
echo '{}' > "$token_map_json"
session_ids=$(jq -r '.[].session_id' "$combined")
for sid in $session_ids; do
  jsonl=$(find "$PROJECTS_DIR" -maxdepth 3 -type f -name "${sid}.jsonl" 2>/dev/null | head -1)
  if [[ -n "$jsonl" ]]; then
    t=$(jq -s '
      [.[] | select(.type == "assistant") | .message.usage // {}]
      | map((.input_tokens // 0) + (.output_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0))
      | add // 0
    ' "$jsonl" 2>/dev/null)
    jq --arg sid "$sid" --argjson t "${t:-0}" '. + {($sid): $t}' "$token_map_json" > "${token_map_json}.tmp" && mv "${token_map_json}.tmp" "$token_map_json"
  fi
done

# Merge honest_tokens into combined for downstream use
jq --slurpfile tmap "$token_map_json" '
  map(. + {honest_tokens: ($tmap[0][.session_id] // 0)})
' "$combined" > "${combined}.enhanced" && mv "${combined}.enhanced" "$combined"

total_tokens=$(jq '[.[].honest_tokens // 0] | add // 0' "$combined")
total_tool_calls=$(jq '[.[] | .tool_counts // {} | to_entries | map(.value) | add // 0] | add // 0' "$combined")
total_interruptions=$(jq '[.[] | .user_interruptions // 0] | add // 0' "$combined")
total_commits=$(jq '[.[] | .git_commits // 0] | add // 0' "$combined")
total_lines_added=$(jq '[.[] | .lines_added // 0] | add // 0' "$combined")
total_lines_removed=$(jq '[.[] | .lines_removed // 0] | add // 0' "$combined")

# Date range
first_iso=$(jq -r '[.[].start_time] | sort | .[0] // ""' "$combined")
last_iso=$(jq -r '[.[].start_time] | sort | .[-1] // ""' "$combined")
first_ts=$(printf '%s' "$first_iso" | jq -Rr 'sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601')
last_ts=$(printf '%s' "$last_iso" | jq -Rr 'sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601')
first_date="${first_iso:0:10}"
last_date="${last_iso:0:10}"

days_active=$(( (last_ts - first_ts) / 86400 + 1 ))
[[ $days_active -lt 1 ]] && days_active=1

msgs_per_day=$(awk "BEGIN {printf \"%.1f\", $total_user_msgs / $days_active}")
avg_msgs=$(awk "BEGIN {printf \"%.1f\", $total_user_msgs / $total_sessions}")
tokens_per_day=$(awk "BEGIN {printf \"%d\", $total_tokens / $days_active + 0.5}")
total_tokens_fmt=$(fmt_num "$total_tokens")
tokens_per_day_fmt=$(fmt_num "$tokens_per_day")
total_commits_fmt=$(fmt_num "$total_commits")
net_lines=$((total_lines_added - total_lines_removed))

# Projects (basename of project_path)
project_sorted=$(jq -r '.[] | (.project_path // "") | split("/") | .[-1] // ""' "$combined" \
  | awk 'NF > 0' | sort | uniq -c | sort -rn | head -10)
max_project_count=$(echo "$project_sorted" | head -1 | awk '{print $1}')
: "${max_project_count:=1}"

# Tools — sum across sessions
tool_sorted=$(jq -r '.[] | .tool_counts // {} | to_entries[] | "\(.value) \(.key)"' "$combined" \
  | awk '{c[$2]+=$1} END {for (k in c) print c[k], k}' | sort -rn | head -10)
max_tool_count=$(echo "$tool_sorted" | head -1 | awk '{print $1}')
: "${max_tool_count:=1}"

# Languages — sum across sessions (Claude-specific dimension)
lang_sorted=$(jq -r '.[] | .languages // {} | to_entries[] | "\(.value) \(.key)"' "$combined" \
  | awk '{c[$2]+=$1} END {for (k in c) print c[k], k}' | sort -rn | head -8)
has_languages=false
if [[ -n "$lang_sorted" ]]; then
  has_languages=true
  max_lang_count=$(echo "$lang_sorted" | head -1 | awk '{print $1}')
  : "${max_lang_count:=1}"
fi

# Keywords from first_prompt text
keywords=$(jq -r '.[] | .first_prompt // empty' "$combined" \
  | grep -oiE '(CLI|GAS|Slack|API|PR|commit|push|test|deploy|release|refactor|docs?|CI|CD|Homebrew|chezmoi|dotfiles|Playwright|review|bug|fix|image|screenshot|blog|article|MCP|Serena)' 2>/dev/null \
  | tr '[:upper:]' '[:lower:]' | sort | uniq -c | sort -rn | head -10) || true

# Top sessions by total tokens — also fish out the rollout JSONL path
top_sessions=$(jq -c 'map({
  id: .session_id,
  tokens: (.honest_tokens // 0),
  first_msg: (.first_prompt // ""),
  project: (.project_path // ""),
  user_msgs: (.user_message_count // 0),
  duration: (.duration_minutes // 0)
}) | sort_by(-.tokens) | .[0:5]' "$combined")

# Weekly tokens — bucket by Monday-anchored week
weekly_data=$(jq -r '
  .[] |
  (.honest_tokens // 0) as $tok |
  ((.start_time // "") | sub("\\.[0-9]+Z$"; "Z") | (try fromdateiso8601 catch 0)) as $t |
  if $t == 0 then empty
  else
    (
      (($t | strftime("%w")) | tonumber) as $dow_sun
      | (if $dow_sun == 0 then 6 else $dow_sun - 1 end) as $dow_mon
      | ($t - ($dow_mon * 86400)) | floor
    ) as $monday_epoch
    | "\($monday_epoch | strftime("%Y-%m-%d"))\t\($tok)"
  end
' "$combined" 2>/dev/null | awk -F'\t' '$1 != "" {sum[$1]+=$2} END {for (k in sum) print k, sum[k]}' | sort)
max_weekly_tokens=$(printf '%s\n' "$weekly_data" | awk '{if ($2+0 > m) m = $2+0} END {print (m > 0 ? m : 1)}')

# Time of day — Claude pre-computes `message_hours` array per session
hour_counts="${TMPDIR_WORK}/hour_counts.txt"
jq -r '.[] | .message_hours[]? // empty' "$combined" \
  | awk '{c[int($0/6)]++} END {for (i=0;i<4;i++) printf "%d %d\n", (c[i]+0), i}' > "$hour_counts"
max_hour_count=$(awk 'BEGIN{m=1} {if ($1+0 > m) m=$1+0} END{print m}' "$hour_counts")

# Response time buckets — Claude pre-computes `user_response_times` (seconds, float)
delta_counts="${TMPDIR_WORK}/delta_counts.txt"
jq -r '.[] | .user_response_times[]? // empty' "$combined" \
  | awk '{
      d = $0 + 0
      if      (d < 30)    print "1|<30s"
      else if (d < 120)   print "2|30s-2m"
      else if (d < 600)   print "3|2m-10m"
      else if (d < 1800)  print "4|10m-30m"
      else if (d < 3600)  print "5|30m-1h"
      else if (d < 21600) print "6|1h-6h"
      else if (d < 86400) print "7|6h-1d"
    }' \
  | sort | uniq -c | awk '{print $1, $2}' > "$delta_counts"
max_delta_count=$(awk 'BEGIN{m=1} {if ($1+0 > m) m=$1+0} END{print m}' "$delta_counts")

generated_at=$(date '+%Y-%m-%d %H:%M')

# ═══════════════════════════════════════
# HTML Generation
# ═══════════════════════════════════════

cat > "$OUTPUT_HTML" <<'CSS'
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>Claude Insights</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #f8fafc; color: #334155; line-height: 1.65; padding: 48px 24px; }
    .container { max-width: 800px; margin: 0 auto; }
    h1 { font-size: 32px; font-weight: 700; color: #0f172a; margin-bottom: 8px; }
    h2 { font-size: 20px; font-weight: 600; color: #0f172a; margin-top: 48px; margin-bottom: 16px; }
    .subtitle { color: #64748b; font-size: 15px; margin-bottom: 32px; }
    .nav-toc { display: flex; flex-wrap: wrap; gap: 8px; margin: 24px 0 32px 0; padding: 16px; background: white; border-radius: 8px; border: 1px solid #e2e8f0; }
    .nav-toc a { font-size: 12px; color: #64748b; text-decoration: none; padding: 6px 12px; border-radius: 6px; background: #f1f5f9; transition: all 0.15s; }
    .nav-toc a:hover { background: #e2e8f0; color: #334155; }
    .stats-row { display: flex; gap: 24px; margin-bottom: 40px; padding: 20px 0; border-top: 1px solid #e2e8f0; border-bottom: 1px solid #e2e8f0; flex-wrap: wrap; justify-content: center; }
    .stat { text-align: center; min-width: 80px; }
    .stat-value { font-size: 24px; font-weight: 700; color: #0f172a; }
    .stat-label { font-size: 11px; color: #64748b; text-transform: uppercase; }
    .charts-row { display: grid; grid-template-columns: 1fr 1fr; gap: 24px; margin: 24px 0; }
    .chart-card { background: white; border: 1px solid #e2e8f0; border-radius: 8px; padding: 16px; }
    .chart-title { font-size: 12px; font-weight: 600; color: #64748b; text-transform: uppercase; margin-bottom: 12px; }
    .bar-row { display: flex; align-items: center; margin-bottom: 6px; }
    .bar-label { width: 130px; font-size: 11px; color: #475569; flex-shrink: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .bar-track { flex: 1; height: 6px; background: #f1f5f9; border-radius: 3px; margin: 0 8px; }
    .bar-fill { height: 100%; border-radius: 3px; }
    .bar-value { width: 60px; font-size: 11px; font-weight: 500; color: #64748b; text-align: right; }
    .vbar-chart { display: flex; align-items: flex-end; gap: 3px; height: 220px; padding: 28px 4px 40px 4px; border-bottom: 1px solid #e2e8f0; position: relative; overflow-x: auto; }
    .vbar { flex: 1; min-width: 14px; background: #d946ef; border-radius: 2px 2px 0 0; position: relative; transition: background 0.15s; }
    .vbar:hover { background: #a21caf; }
    .vbar-value { font-size: 9px; color: #64748b; position: absolute; top: -18px; left: 50%; transform: translateX(-50%); white-space: nowrap; }
    .vbar-label { font-size: 9px; color: #94a3b8; position: absolute; bottom: -32px; left: 0; white-space: nowrap; transform: rotate(-45deg); transform-origin: top left; }
    .session-card { background: white; border: 1px solid #e2e8f0; border-radius: 8px; padding: 12px 16px; margin-bottom: 8px; transition: border-color 0.15s, background 0.15s; }
    .session-card-link { display: block; text-decoration: none; color: inherit; }
    .session-card-link:hover .session-card { border-color: #94a3b8; background: #f8fafc; }
    .area-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 4px; }
    .area-name { font-weight: 600; font-size: 13px; color: #0f172a; font-family: monospace; }
    .area-count { font-size: 12px; color: #64748b; background: #f1f5f9; padding: 2px 8px; border-radius: 4px; }
    .session-msg { font-size: 13px; color: #475569; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; max-width: 600px; }
    .session-meta-line { font-size: 11px; color: #94a3b8; margin-top: 4px; font-family: monospace; }
    .keyword-grid { display: flex; flex-wrap: wrap; gap: 8px; margin: 16px 0; }
    .keyword-chip { background: white; border: 1px solid #e2e8f0; border-radius: 6px; padding: 6px 12px; font-size: 13px; }
    .keyword-count { font-weight: 600; color: #d946ef; margin-right: 4px; }
    .note { background: #fdf4ff; border: 1px solid #f0abfc; border-radius: 8px; padding: 16px; margin: 24px 0; font-size: 14px; color: #701a75; line-height: 1.6; }
    @media (max-width: 640px) { .charts-row { grid-template-columns: 1fr; } }
  </style>
</head>
<body>
<div class="container">
CSS

# --- Header ---
cat >> "$OUTPUT_HTML" <<HEADER
  <h1>Claude Insights</h1>
  <p class="subtitle">${total_sessions} sessions, ${total_user_msgs} user messages | ${first_date} to ${last_date}</p>

  <div class="note">
    Sessions / messages / tool counts come from <code>~/.claude/usage-data/session-meta/*.json</code> (pre-computed by Claude's <code>/insights</code>).
    Token totals are summed directly from raw rollout JSONLs and include <strong>input + output + cache_creation + cache_read</strong> — matching what Codex reports, not the cache-excluded number stored in session-meta.
  </div>
HEADER

# --- Nav ---
cat >> "$OUTPUT_HTML" <<'NAV'
  <nav class="nav-toc">
    <a href="#section-stats">Stats</a>
    <a href="#section-weekly-tokens">Weekly Tokens</a>
    <a href="#section-projects">Projects</a>
    <a href="#section-tools">Tools</a>
    <a href="#section-languages">Languages</a>
    <a href="#section-keywords">Keywords</a>
    <a href="#section-hours">Time of Day</a>
    <a href="#section-response-time">Response Time</a>
    <a href="#section-sessions">Top Sessions</a>
  </nav>
NAV

# --- Stats ---
cat >> "$OUTPUT_HTML" <<STATS
  <div class="stats-row" id="section-stats">
    <div class="stat"><div class="stat-value">${total_user_msgs}</div><div class="stat-label">User Msgs</div></div>
    <div class="stat"><div class="stat-value">${total_sessions}</div><div class="stat-label">Sessions</div></div>
    <div class="stat"><div class="stat-value">${total_tool_calls}</div><div class="stat-label">Tool Calls</div></div>
    <div class="stat"><div class="stat-value">${total_tokens_fmt}</div><div class="stat-label">Tokens</div></div>
    <div class="stat"><div class="stat-value">${days_active}</div><div class="stat-label">Days</div></div>
    <div class="stat"><div class="stat-value">${msgs_per_day}</div><div class="stat-label">Msgs/Day</div></div>
    <div class="stat"><div class="stat-value">${avg_msgs}</div><div class="stat-label">Msgs/Session</div></div>
    <div class="stat"><div class="stat-value">${tokens_per_day_fmt}</div><div class="stat-label">Tokens/Day</div></div>
    <div class="stat"><div class="stat-value">${total_commits_fmt}</div><div class="stat-label">Git Commits</div></div>
    <div class="stat"><div class="stat-value">${total_interruptions}</div><div class="stat-label">Interrupts</div></div>
  </div>
STATS

# --- Weekly tokens (vertical bars, millions) ---
cat >> "$OUTPUT_HTML" <<'WEEKLY_HEADER'
  <h2 id="section-weekly-tokens">Weekly Tokens <span style="font-size:12px;color:#94a3b8;font-weight:400;">(millions)</span></h2>
  <div class="chart-card">
    <div class="vbar-chart">
WEEKLY_HEADER

printf '%s\n' "$weekly_data" | while read -r monday tokens; do
  [[ -z "$monday" ]] && continue
  pct=$(awk "BEGIN {printf \"%.1f\", $tokens * 100 / $max_weekly_tokens}")
  mtokens=$(awk "BEGIN {printf \"%.1f\", $tokens / 1000000}")
  short_label=$(date -j -f "%Y-%m-%d" "$monday" "+%b %d" 2>/dev/null \
              || date -d "$monday" "+%b %d" 2>/dev/null \
              || echo "$monday")
  printf '      <div class="vbar" style="height:%s%%;" title="%s — %sM tokens"><div class="vbar-value">%sM</div><div class="vbar-label">%s</div></div>\n' "$pct" "$monday" "$mtokens" "$mtokens" "$short_label" >> "$OUTPUT_HTML"
done

cat >> "$OUTPUT_HTML" <<'WEEKLY_FOOTER'
    </div>
  </div>
WEEKLY_FOOTER

# --- Projects + Tools side-by-side ---
cat >> "$OUTPUT_HTML" <<'PT_HEADER'
  <div class="charts-row">
    <div class="chart-card">
      <div class="chart-title" id="section-projects">Projects</div>
PT_HEADER

echo "$project_sorted" | while read -r count name; do
  [[ -z "$count" ]] && continue
  pct=$(awk "BEGIN {printf \"%.1f\", $count * 100 / $max_project_count}")
  escaped_name=$(html_escape "$name")
  printf '      <div class="bar-row"><div class="bar-label">%s</div><div class="bar-track"><div class="bar-fill" style="width:%s%%;background:#d946ef"></div></div><div class="bar-value">%s</div></div>\n' "$escaped_name" "$pct" "$count" >> "$OUTPUT_HTML"
done

cat >> "$OUTPUT_HTML" <<'PT_MID'
    </div>
    <div class="chart-card">
      <div class="chart-title" id="section-tools">Tool Usage</div>
PT_MID

echo "$tool_sorted" | while read -r count name; do
  [[ -z "$count" ]] && continue
  pct=$(awk "BEGIN {printf \"%.1f\", $count * 100 / $max_tool_count}")
  escaped_name=$(html_escape "$name")
  printf '      <div class="bar-row"><div class="bar-label">%s</div><div class="bar-track"><div class="bar-fill" style="width:%s%%;background:#0891b2"></div></div><div class="bar-value">%s</div></div>\n' "$escaped_name" "$pct" "$count" >> "$OUTPUT_HTML"
done

printf '    </div>\n  </div>\n' >> "$OUTPUT_HTML"

# --- Languages (Claude-specific) ---
if [[ "$has_languages" == true ]]; then
  printf '\n  <h2 id="section-languages">Languages Touched <span style="font-size:12px;color:#94a3b8;font-weight:400;">(by occurrence in sessions)</span></h2>\n  <div class="chart-card">\n' >> "$OUTPUT_HTML"
  echo "$lang_sorted" | while read -r count name; do
    [[ -z "$count" ]] && continue
    pct=$(awk "BEGIN {printf \"%.1f\", $count * 100 / $max_lang_count}")
    escaped_name=$(html_escape "$name")
    printf '    <div class="bar-row"><div class="bar-label">%s</div><div class="bar-track"><div class="bar-fill" style="width:%s%%;background:#16a34a"></div></div><div class="bar-value">%s</div></div>\n' "$escaped_name" "$pct" "$count" >> "$OUTPUT_HTML"
  done
  printf '  </div>\n' >> "$OUTPUT_HTML"
fi

# --- Keywords ---
printf '\n  <h2 id="section-keywords">Top Keywords <span style="font-size:12px;color:#94a3b8;font-weight:400;">(from first prompts)</span></h2>\n  <div class="keyword-grid">\n' >> "$OUTPUT_HTML"
echo "$keywords" | while read -r count word; do
  [[ -z "$count" ]] && continue
  escaped_word=$(html_escape "$word")
  printf '    <div class="keyword-chip"><span class="keyword-count">%s</span>%s</div>\n' "$count" "$escaped_word" >> "$OUTPUT_HTML"
done
printf '  </div>\n' >> "$OUTPUT_HTML"

# --- Time of Day (6-hour bands, UTC) ---
printf '\n  <h2 id="section-hours">User Messages by Time of Day <span style="font-size:12px;color:#94a3b8;font-weight:400;">(UTC, 6-hour bands)</span></h2>\n  <div class="chart-card">\n' >> "$OUTPUT_HTML"
while read -r count bucket; do
  start_h=$((bucket * 6))
  end_h=$((start_h + 5))
  pct=$(awk "BEGIN {printf \"%.1f\", $count * 100 / $max_hour_count}")
  printf '    <div class="bar-row"><div class="bar-label">%02d:00-%02d:59</div><div class="bar-track"><div class="bar-fill" style="width:%s%%;background:#7c3aed"></div></div><div class="bar-value">%s</div></div>\n' "$start_h" "$end_h" "$pct" "$count" >> "$OUTPUT_HTML"
done < "$hour_counts"
printf '  </div>\n' >> "$OUTPUT_HTML"

# --- Response Time Distribution ---
printf '\n  <h2 id="section-response-time">User Response Time Distribution <span style="font-size:12px;color:#94a3b8;font-weight:400;">(pre-computed per session)</span></h2>\n  <div class="chart-card">\n' >> "$OUTPUT_HTML"
for ordered_bucket in '1|<30s' '2|30s-2m' '3|2m-10m' '4|10m-30m' '5|30m-1h' '6|1h-6h' '7|6h-1d'; do
  count=$(awk -v b="$ordered_bucket" '$2 == b {print $1}' "$delta_counts")
  count="${count:-0}"
  label="${ordered_bucket#*|}"
  pct=$(awk "BEGIN {printf \"%.1f\", $count * 100 / $max_delta_count}")
  escaped_label=$(html_escape "$label")
  printf '    <div class="bar-row"><div class="bar-label">%s</div><div class="bar-track"><div class="bar-fill" style="width:%s%%;background:#ea580c"></div></div><div class="bar-value">%s</div></div>\n' "$escaped_label" "$pct" "$count" >> "$OUTPUT_HTML"
done
printf '  </div>\n' >> "$OUTPUT_HTML"

# --- Top Sessions (linked to JSONL rollouts) ---
printf '\n  <h2 id="section-sessions">Top Sessions <span style="font-size:12px;color:#94a3b8;font-weight:400;">(by total tokens)</span></h2>\n' >> "$OUTPUT_HTML"
echo "$top_sessions" | jq -c '.[]' | while read -r session; do
  sid=$(echo "$session" | jq -r '.id')
  tokens=$(echo "$session" | jq -r '.tokens')
  tokens_fmt=$(fmt_num "$tokens")
  user_msgs=$(echo "$session" | jq -r '.user_msgs')
  duration_min=$(echo "$session" | jq -r '.duration')
  project=$(echo "$session" | jq -r '.project' | awk -F/ '{print $NF}')
  first_msg_raw=$(echo "$session" | jq -r '.first_msg' | head -c 120)
  first_msg=$(html_escape "$first_msg_raw")
  project_escaped=$(html_escape "$project")
  short_id="${sid:0:12}"
  jsonl_path=$(find "$PROJECTS_DIR" -maxdepth 3 -type f -name "${sid}.jsonl" 2>/dev/null | head -1)
  meta_line="${project_escaped} · ${user_msgs} user msgs · ${duration_min} min"
  if [[ -n "$jsonl_path" ]]; then
    escaped_href=$(html_escape "file://${jsonl_path}")
    printf '  <a class="session-card-link" href="%s"><div class="session-card"><div class="area-header"><span class="area-name">%s...</span><span class="area-count">%s tokens</span></div><div class="session-msg">%s</div><div class="session-meta-line">%s</div></div></a>\n' "$escaped_href" "$short_id" "$tokens_fmt" "$first_msg" "$meta_line" >> "$OUTPUT_HTML"
  else
    printf '  <div class="session-card"><div class="area-header"><span class="area-name">%s...</span><span class="area-count">%s tokens</span></div><div class="session-msg">%s</div><div class="session-meta-line">%s</div></div>\n' "$short_id" "$tokens_fmt" "$first_msg" "$meta_line" >> "$OUTPUT_HTML"
  fi
done

# --- Footer ---
cat >> "$OUTPUT_HTML" <<FOOTER
  <p style="margin-top:48px;font-size:12px;color:#94a3b8;text-align:center;">
    Generated: ${generated_at} · ${total_lines_added} lines added / ${total_lines_removed} removed (net ${net_lines})
  </p>
</div>
</body>
</html>
FOOTER

echo "$OUTPUT_HTML"
