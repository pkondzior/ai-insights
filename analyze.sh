#!/usr/bin/env bash
# Codex Insights - Analyze Codex CLI session history and generate HTML report
# Usage: bash ~/.skills/codex-insights/analyze.sh
# Output: ~/.codex/usage-data/report.html (mirrors Claude Code's path)
# Compatible with macOS bash 3.x (no associative arrays)
set -euo pipefail
if locale -a 2>/dev/null | grep -q 'C.UTF-8'; then
  export LC_ALL=C.UTF-8
elif locale -a 2>/dev/null | grep -q 'en_US.UTF-8'; then
  export LC_ALL=en_US.UTF-8
fi

# HTML escape helper to prevent XSS.
# Note: an unescaped `&` in a bash `${s//pat/repl}` replacement refers to the
# matched pattern (sed-style), so the literal ampersand entities must be
# written as `\&amp;`, etc.
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

CODEX_DIR="${HOME}/.codex"
HISTORY="${CODEX_DIR}/history.jsonl"
SESSIONS_DIR="${CODEX_DIR}/sessions"
OUTPUT_DIR="${CODEX_DIR}/usage-data"
OUTPUT_HTML="${OUTPUT_DIR}/report.html"
INSIGHTS_JSON="${OUTPUT_DIR}/insights.json"
mkdir -p "$OUTPUT_DIR"
TMPDIR_WORK=$(mktemp -d)
trap 'rm -rf "$TMPDIR_WORK"' EXIT

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required. Install it: brew install jq" >&2
  exit 1
fi

# ── Resolve $HISTORY: legacy file → SQLite synth fallback (3a) ──
# Newer Codex CLI no longer writes ~/.codex/history.jsonl; thread metadata lives
# in state_5.sqlite. Synthesize a per-thread JSONL with shape {session_id, ts, text}
# using each thread's first_user_message. One row per thread (not per message).
resolve_history() {
  if [[ -f "$HISTORY" ]]; then
    return 0
  fi
  local state_db="${CODEX_DIR}/state_5.sqlite"
  if [[ ! -f "$state_db" ]]; then
    echo "Error: neither ${HISTORY} nor ${state_db} found." >&2
    echo "Codex CLI session data not found. Run Codex first, then try again." >&2
    exit 1
  fi
  if ! command -v sqlite3 &>/dev/null; then
    echo "Error: sqlite3 is required to read ${state_db}." >&2
    exit 1
  fi
  HISTORY="${TMPDIR_WORK}/history-synth.jsonl"
  sqlite3 "$state_db" <<SQL > "$HISTORY"
SELECT json_object(
  'session_id', id,
  'ts', created_at,
  'text', first_user_message,
  'tokens', tokens_used,
  'rollout_path', rollout_path
)
FROM threads
ORDER BY created_at;
SQL
}
resolve_history

# ═══════════════════════════════════════
# Data Collection
# ═══════════════════════════════════════

total_messages=$(wc -l < "$HISTORY" | tr -d ' ')
unique_sessions=$(jq -r '.session_id' "$HISTORY" | sort -u | wc -l | tr -d ' ')

first_ts=$(jq -r '.ts | floor' "$HISTORY" | head -1)
last_ts=$(jq -r '.ts | floor' "$HISTORY" | tail -1)
first_date=$(date -r "$first_ts" '+%Y-%m-%d' 2>/dev/null || date -d "@$first_ts" '+%Y-%m-%d' 2>/dev/null || echo "unknown")
last_date=$(date -r "$last_ts" '+%Y-%m-%d' 2>/dev/null || date -d "@$last_ts" '+%Y-%m-%d' 2>/dev/null || echo "unknown")

days_active=$(( (last_ts - first_ts) / 86400 + 1 ))
[[ $days_active -lt 1 ]] && days_active=1
msgs_per_day=$(awk "BEGIN {printf \"%.1f\", $total_messages / $days_active}")
avg_msgs=$(jq -r '.session_id' "$HISTORY" | sort | uniq -c | awk '{sum+=$1; n++} END {printf "%.1f", sum/n}')

# Session file analysis
projects_tmp="${TMPDIR_WORK}/projects.txt"
tools_tmp="${TMPDIR_WORK}/tools.txt"
session_msgs_tmp="${TMPDIR_WORK}/session_msgs.tsv"
hours_tmp="${TMPDIR_WORK}/hours.txt"
deltas_tmp="${TMPDIR_WORK}/deltas_buckets.txt"
: > "$projects_tmp"
: > "$tools_tmp"
: > "$session_msgs_tmp"
: > "$hours_tmp"
: > "$deltas_tmp"

find "$SESSIONS_DIR" -name '*.jsonl' -print0 2>/dev/null | while IFS= read -r -d '' sf; do
  jq -r 'select(.type == "session_meta") | .payload.cwd // empty' "$sf" 2>/dev/null | head -1 | while read -r cwd; do
    [[ -n "$cwd" ]] && basename "$cwd" >> "$projects_tmp"
  done
  jq -r 'select(.type == "response_item") | .payload | select(.type == "function_call") | .name // empty' "$sf" 2>/dev/null >> "$tools_tmp"
  # Real user message timestamps (excludes <environment_context> + AGENTS.md auto-injections)
  sid=$(jq -r 'select(.type == "session_meta") | .payload.id // empty' "$sf" 2>/dev/null | head -1)
  if [[ -n "$sid" ]]; then
    # jq pre-computes (epoch_seconds, hour_of_day_utc) for each real user message
    user_ts=$(jq -r '
      select(.type == "response_item" and .payload.type == "message" and .payload.role == "user")
      | (.payload.content[0].text // "") as $t
      | if ($t | test("^(<environment_context>|# AGENTS\\.md)")) then empty
        else
          (.timestamp // "") as $ts
          | ($ts | sub("\\.[0-9]+Z$"; "Z")) as $isoz
          | (try ($isoz | fromdateiso8601) catch 0) as $epoch
          | (try ($ts[11:13] | tonumber) catch 0) as $hour
          | "\($epoch)\t\($hour)"
        end
    ' "$sf" 2>/dev/null)

    msg_count=$(printf '%s' "$user_ts" | grep -c '^.' || true)
    printf '%s\t%s\n' "$sid" "$msg_count" >> "$session_msgs_tmp"

    # awk: per-session hour histogram + consecutive-turn deltas
    printf '%s\n' "$user_ts" | awk -F'\t' -v hours="$hours_tmp" -v deltas="$deltas_tmp" '
      $0 != "" {
        e = $1 + 0
        h = $2 + 0
        print h >> hours
        if (prev > 0 && e > prev) {
          d = e - prev
          if      (d < 30)    print "1|<30s"   >> deltas
          else if (d < 120)   print "2|30s-2m" >> deltas
          else if (d < 600)   print "3|2m-10m" >> deltas
          else if (d < 1800)  print "4|10m-30m" >> deltas
          else if (d < 3600)  print "5|30m-1h" >> deltas
          else if (d < 21600) print "6|1h-6h" >> deltas
          else if (d < 86400) print "7|6h-1d" >> deltas
        }
        prev = e
      }
    '
  fi
done

# If the JSONL walk produced real user-message counts, prefer those over the
# synth-derived line count (which is one-per-thread on new Codex layouts).
total_messages_walk=$(awk -F'\t' '{sum += $2} END {print sum+0}' "$session_msgs_tmp")
if [[ "$total_messages_walk" -gt 0 ]]; then
  total_messages="$total_messages_walk"
  msgs_per_day=$(awk "BEGIN {printf \"%.1f\", $total_messages / $days_active}")
  avg_msgs=$(awk "BEGIN {printf \"%.1f\", $total_messages / $unique_sessions}")
fi

project_sorted=$(sort "$projects_tmp" | uniq -c | sort -rn | head -10)
tool_sorted=$(sort "$tools_tmp" | uniq -c | sort -rn | head -8)
total_tool_calls=$(wc -l < "$tools_tmp" | tr -d ' ')

# Token totals (0 on legacy history.jsonl with no .tokens field)
total_tokens=$(jq -r '.tokens // 0' "$HISTORY" 2>/dev/null | awk '{sum+=$1} END {print sum+0}')
total_tokens_fmt=$(fmt_num "$total_tokens")
tokens_per_day=$(awk -v t="$total_tokens" -v d="$days_active" 'BEGIN { printf "%d", t/d + 0.5 }')
tokens_per_day_fmt=$(fmt_num "$tokens_per_day")

max_project_count=$(echo "$project_sorted" | head -1 | awk '{print $1}')
max_tool_count=$(echo "$tool_sorted" | head -1 | awk '{print $1}')
: "${max_project_count:=1}"
: "${max_tool_count:=1}"

keywords=$(jq -r '.text' "$HISTORY" | \
  grep -oiE '(CLI|GAS|Slack|API|PR|commit|push|test|deploy|release|refactor|docs?|CI|CD|Homebrew|chezmoi|dotfiles|Playwright|review|bug|fix|image|screenshot|blog|article|MCP|Serena)' 2>/dev/null | \
  tr '[:upper:]' '[:lower:]' | sort | uniq -c | sort -rn | head -10) || true

top_sessions=$(jq -c '{id: .session_id, tokens: (.tokens // 0), first_msg: .text, rollout_path: (.rollout_path // "")}' "$HISTORY" | \
  jq -rs 'sort_by(-.tokens) | .[0:5]')

# Check for AI-generated insights
has_insights=false
if [[ -f "$INSIGHTS_JSON" ]]; then
  has_insights=true
fi

generated_at=$(date '+%Y-%m-%d %H:%M')

# ═══════════════════════════════════════
# HTML Generation
# ═══════════════════════════════════════

cat > "$OUTPUT_HTML" <<'CSS'
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>Codex Insights</title>
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
    .at-a-glance { background: linear-gradient(135deg, #dbeafe 0%, #bfdbfe 100%); border: 1px solid #3b82f6; border-radius: 12px; padding: 20px 24px; margin-bottom: 32px; }
    .glance-title { font-size: 16px; font-weight: 700; color: #1e3a5f; margin-bottom: 16px; }
    .glance-sections { display: flex; flex-direction: column; gap: 12px; }
    .glance-section { font-size: 14px; color: #1e3a5f; line-height: 1.6; }
    .glance-section strong { color: #1e40af; }
    .see-more { color: #2563eb; text-decoration: none; font-size: 13px; white-space: nowrap; }
    .see-more:hover { text-decoration: underline; }
    .charts-row { display: grid; grid-template-columns: 1fr 1fr; gap: 24px; margin: 24px 0; }
    .chart-card { background: white; border: 1px solid #e2e8f0; border-radius: 8px; padding: 16px; }
    .chart-title { font-size: 12px; font-weight: 600; color: #64748b; text-transform: uppercase; margin-bottom: 12px; }
    .bar-row { display: flex; align-items: center; margin-bottom: 6px; }
    .bar-label { width: 130px; font-size: 11px; color: #475569; flex-shrink: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .bar-track { flex: 1; height: 6px; background: #f1f5f9; border-radius: 3px; margin: 0 8px; }
    .bar-fill { height: 100%; border-radius: 3px; }
    .bar-value { width: 40px; font-size: 11px; font-weight: 500; color: #64748b; text-align: right; }
    .vbar-chart { display: flex; align-items: flex-end; gap: 3px; height: 220px; padding: 28px 4px 40px 4px; border-bottom: 1px solid #e2e8f0; position: relative; overflow-x: auto; }
    .vbar { flex: 1; min-width: 14px; background: #16a34a; border-radius: 2px 2px 0 0; position: relative; transition: background 0.15s; }
    .vbar:hover { background: #15803d; }
    .vbar-value { font-size: 9px; color: #64748b; position: absolute; top: -18px; left: 50%; transform: translateX(-50%); white-space: nowrap; }
    .vbar-label { font-size: 9px; color: #94a3b8; position: absolute; bottom: -32px; left: 0; white-space: nowrap; transform: rotate(-45deg); transform-origin: top left; }
    .session-card { background: white; border: 1px solid #e2e8f0; border-radius: 8px; padding: 12px 16px; margin-bottom: 8px; transition: border-color 0.15s, background 0.15s; }
    .session-card-link { display: block; text-decoration: none; color: inherit; }
    .session-card-link:hover .session-card { border-color: #94a3b8; background: #f8fafc; }
    .area-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 4px; }
    .area-name { font-weight: 600; font-size: 13px; color: #0f172a; font-family: monospace; }
    .area-count { font-size: 12px; color: #64748b; background: #f1f5f9; padding: 2px 8px; border-radius: 4px; }
    .session-msg { font-size: 13px; color: #475569; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; max-width: 600px; }
    .keyword-grid { display: flex; flex-wrap: wrap; gap: 8px; margin: 16px 0; }
    .keyword-chip { background: white; border: 1px solid #e2e8f0; border-radius: 6px; padding: 6px 12px; font-size: 13px; }
    .keyword-count { font-weight: 600; color: #2563eb; margin-right: 4px; }
    .big-win { background: #f0fdf4; border: 1px solid #bbf7d0; border-radius: 8px; padding: 16px; margin-bottom: 12px; }
    .big-win-title { font-weight: 600; font-size: 15px; color: #166534; margin-bottom: 8px; }
    .big-win-desc { font-size: 14px; color: #15803d; line-height: 1.5; }
    .friction-card { background: #fef2f2; border: 1px solid #fca5a5; border-radius: 8px; padding: 16px; margin-bottom: 12px; }
    .friction-title { font-weight: 600; font-size: 15px; color: #991b1b; margin-bottom: 6px; }
    .friction-desc { font-size: 13px; color: #7f1d1d; line-height: 1.5; }
    .friction-example { font-size: 12px; color: #334155; margin-top: 8px; padding: 8px 12px; background: rgba(255,255,255,0.6); border-radius: 4px; font-family: monospace; }
    .suggestion-card { background: #eff6ff; border: 1px solid #bfdbfe; border-radius: 8px; padding: 16px; margin-bottom: 12px; }
    .suggestion-title { font-weight: 600; font-size: 15px; color: #1e40af; margin-bottom: 6px; }
    .suggestion-desc { font-size: 14px; color: #1e3a5f; line-height: 1.5; }
    .copy-btn { background: #e2e8f0; border: none; border-radius: 4px; padding: 4px 10px; font-size: 11px; cursor: pointer; color: #475569; float: right; transition: all 0.2s; }
    .copy-btn:hover { background: #cbd5e1; }
    .copy-btn.copied { background: #16a34a; color: white; }
    .copyable-prompt { background: #f8fafc; padding: 12px; border-radius: 6px; margin-top: 10px; border: 1px solid #e2e8f0; position: relative; }
    .copyable-prompt code { font-family: monospace; font-size: 12px; color: #334155; display: block; white-space: pre-wrap; line-height: 1.6; }
    .prompt-label { font-size: 11px; font-weight: 600; text-transform: uppercase; color: #64748b; margin-bottom: 6px; }
    .instructions-section { background: #eff6ff; border: 1px solid #bfdbfe; border-radius: 8px; padding: 16px; margin-bottom: 20px; }
    .instructions-section h3 { font-size: 14px; font-weight: 600; color: #1e40af; margin: 0 0 8px 0; }
    .instructions-item { display: flex; flex-wrap: wrap; align-items: flex-start; gap: 8px; padding: 10px 0; border-bottom: 1px solid #dbeafe; }
    .instructions-item:last-child { border-bottom: none; }
    .instructions-code { background: white; padding: 8px 12px; border-radius: 4px; font-size: 12px; color: #1e40af; border: 1px solid #bfdbfe; font-family: monospace; display: block; white-space: pre-wrap; word-break: break-word; flex: 1; }
    .instructions-why { font-size: 12px; color: #64748b; width: 100%; padding-left: 4px; margin-top: 4px; }
    .compare-row { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; margin: 16px 0; }
    .compare-card { background: white; border: 1px solid #e2e8f0; border-radius: 8px; padding: 16px; }
    .compare-card h3 { font-size: 14px; font-weight: 600; margin-bottom: 8px; }
    .compare-card ul { font-size: 13px; color: #475569; padding-left: 16px; line-height: 1.7; }
    .note { background: #f0f9ff; border: 1px solid #bae6fd; border-radius: 8px; padding: 16px; margin: 24px 0; font-size: 14px; color: #0c4a6e; line-height: 1.6; }
    @media (max-width: 640px) { .charts-row { grid-template-columns: 1fr; } .compare-row { grid-template-columns: 1fr; } }
  </style>
</head>
<body>
<div class="container">
CSS

# --- Header + At a Glance ---
cat >> "$OUTPUT_HTML" <<HEADER
  <h1>Codex Insights</h1>
  <p class="subtitle">${total_messages} messages across ${unique_sessions} sessions | ${first_date} to ${last_date}</p>
HEADER

# At a Glance (read from insights.json if exists, otherwise use data-driven defaults)
if [[ "$has_insights" == true ]] && jq -e '.at_a_glance' "$INSIGHTS_JSON" >/dev/null 2>&1; then
  working=$(html_escape "$(jq -r '.at_a_glance.working' "$INSIGHTS_JSON")")
  hindering=$(html_escape "$(jq -r '.at_a_glance.hindering' "$INSIGHTS_JSON")")
  quick_wins=$(html_escape "$(jq -r '.at_a_glance.quick_wins' "$INSIGHTS_JSON")")
else
  working="Activity across ${total_tool_calls} tool calls suggests automation around git, CI/CD, and multi-repo workflows is running steadily."
  hindering="Run codex-insights --ai --force to get a detailed friction analysis from your session data."
  quick_wins="Start by running codex-insights --ai --force to generate concrete improvement suggestions."
fi

cat >> "$OUTPUT_HTML" <<GLANCE
  <div class="at-a-glance">
    <div class="glance-title">At a Glance</div>
    <div class="glance-sections">
      <div class="glance-section"><strong>What's working:</strong> ${working} <a href="#section-wins" class="see-more">Impressive Things →</a></div>
      <div class="glance-section"><strong>What's hindering:</strong> ${hindering} <a href="#section-friction" class="see-more">Friction Points →</a></div>
      <div class="glance-section"><strong>Quick wins:</strong> ${quick_wins} <a href="#section-suggestions" class="see-more">Suggestions →</a></div>
    </div>
  </div>
GLANCE

# --- Nav ---
cat >> "$OUTPUT_HTML" <<'NAV'
  <nav class="nav-toc">
    <a href="#section-stats">Stats</a>
    <a href="#section-weekly-tokens">Weekly Tokens</a>
    <a href="#section-projects">Projects</a>
    <a href="#section-tools">Tools</a>
    <a href="#section-keywords">Keywords</a>
    <a href="#section-hours">Time of Day</a>
    <a href="#section-response-time">Response Time</a>
    <a href="#section-wins">Impressive Things</a>
    <a href="#section-friction">Friction Points</a>
    <a href="#section-suggestions">Suggestions</a>
    <a href="#section-compare">Codex vs Claude Code</a>
  </nav>
NAV

# --- Stats ---
cat >> "$OUTPUT_HTML" <<STATS
  <div class="stats-row" id="section-stats">
    <div class="stat"><div class="stat-value">${total_messages}</div><div class="stat-label">Messages</div></div>
    <div class="stat"><div class="stat-value">${unique_sessions}</div><div class="stat-label">Sessions</div></div>
    <div class="stat"><div class="stat-value">${total_tool_calls}</div><div class="stat-label">Tool Calls</div></div>
    <div class="stat"><div class="stat-value">${total_tokens_fmt}</div><div class="stat-label">Tokens</div></div>
    <div class="stat"><div class="stat-value">${days_active}</div><div class="stat-label">Days</div></div>
    <div class="stat"><div class="stat-value">${msgs_per_day}</div><div class="stat-label">Msgs/Day</div></div>
    <div class="stat"><div class="stat-value">${avg_msgs}</div><div class="stat-label">Msgs/Session</div></div>
    <div class="stat"><div class="stat-value">${tokens_per_day_fmt}</div><div class="stat-label">Tokens/Day</div></div>
  </div>
STATS

# --- Weekly tokens (vertical bars, millions) ---
# Bucket threads by Monday-anchored week, sum tokens.
weekly_data=$(jq -r '
  (.ts // 0) as $t
  | (.tokens // 0) as $tok
  | (
      (($t | strftime("%w")) | tonumber) as $dow_sun
      | (if $dow_sun == 0 then 6 else $dow_sun - 1 end) as $dow_mon
      | ($t - ($dow_mon * 86400)) | floor
    ) as $monday_epoch
  | "\($monday_epoch | strftime("%Y-%m-%d"))\t\($tok)"
' "$HISTORY" 2>/dev/null | awk -F'\t' '$1 != "" {sum[$1]+=$2} END {for (k in sum) print k, sum[k]}' | sort)
max_weekly_tokens=$(printf '%s\n' "$weekly_data" | awk '{if ($2+0 > m) m = $2+0} END {print (m > 0 ? m : 1)}')

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

cat >> "$OUTPUT_HTML" <<STATS
  <div class="charts-row">
    <div class="chart-card">
      <div class="chart-title" id="section-projects">Projects</div>
STATS

echo "$project_sorted" | while read -r count name; do
  [[ -z "$count" ]] && continue
  pct=$(awk "BEGIN {printf \"%.1f\", $count * 100 / $max_project_count}")
  escaped_name=$(html_escape "$name")
  printf '      <div class="bar-row"><div class="bar-label">%s</div><div class="bar-track"><div class="bar-fill" style="width:%s%%;background:#2563eb"></div></div><div class="bar-value">%s</div></div>\n' "$escaped_name" "$pct" "$count" >> "$OUTPUT_HTML"
done

cat >> "$OUTPUT_HTML" <<'MID'
    </div>
    <div class="chart-card">
      <div class="chart-title" id="section-tools">Tool Usage</div>
MID

echo "$tool_sorted" | while read -r count name; do
  [[ -z "$count" ]] && continue
  pct=$(awk "BEGIN {printf \"%.1f\", $count * 100 / $max_tool_count}")
  escaped_name=$(html_escape "$name")
  printf '      <div class="bar-row"><div class="bar-label">%s</div><div class="bar-track"><div class="bar-fill" style="width:%s%%;background:#0891b2"></div></div><div class="bar-value">%s</div></div>\n' "$escaped_name" "$pct" "$count" >> "$OUTPUT_HTML"
done

printf '    </div>\n  </div>\n' >> "$OUTPUT_HTML"

# --- Keywords ---
printf '\n  <h2 id="section-keywords">Top Keywords</h2>\n  <div class="keyword-grid">\n' >> "$OUTPUT_HTML"
echo "$keywords" | while read -r count word; do
  [[ -z "$count" ]] && continue
  escaped_word=$(html_escape "$word")
  printf '    <div class="keyword-chip"><span class="keyword-count">%s</span>%s</div>\n' "$count" "$escaped_word" >> "$OUTPUT_HTML"
done
printf '  </div>\n' >> "$OUTPUT_HTML"

# --- User Messages by Time of Day (UTC, 6-hour bands) ---
hour_counts="${TMPDIR_WORK}/hour_counts.txt"
awk '{c[int($0/6)]++} END {for (i=0;i<4;i++) printf "%d %d\n", (c[i]+0), i}' "$hours_tmp" > "$hour_counts"
max_hour_count=$(awk 'BEGIN{m=1} {if ($1+0 > m) m=$1+0} END{print m}' "$hour_counts")
printf '\n  <h2 id="section-hours">User Messages by Time of Day <span style="font-size:12px;color:#94a3b8;font-weight:400;">(UTC, 6-hour bands)</span></h2>\n  <div class="chart-card">\n' >> "$OUTPUT_HTML"
while read -r count bucket; do
  start_h=$((bucket * 6))
  end_h=$((start_h + 5))
  pct=$(awk "BEGIN {printf \"%.1f\", $count * 100 / $max_hour_count}")
  printf '    <div class="bar-row"><div class="bar-label">%02d:00-%02d:59</div><div class="bar-track"><div class="bar-fill" style="width:%s%%;background:#7c3aed"></div></div><div class="bar-value">%s</div></div>\n' "$start_h" "$end_h" "$pct" "$count" >> "$OUTPUT_HTML"
done < "$hour_counts"
printf '  </div>\n' >> "$OUTPUT_HTML"

# --- User Response Time Distribution (time between consecutive user turns) ---
delta_counts="${TMPDIR_WORK}/delta_counts.txt"
sort "$deltas_tmp" | uniq -c | awk '{print $1, $2}' > "$delta_counts"
max_delta_count=$(awk 'BEGIN{m=1} {if ($1+0 > m) m=$1+0} END{print m}' "$delta_counts")
printf '\n  <h2 id="section-response-time">User Response Time Distribution <span style="font-size:12px;color:#94a3b8;font-weight:400;">(between consecutive user turns)</span></h2>\n  <div class="chart-card">\n' >> "$OUTPUT_HTML"
for ordered_bucket in '1|<30s' '2|30s-2m' '3|2m-10m' '4|10m-30m' '5|30m-1h' '6|1h-6h' '7|6h-1d'; do
  count=$(awk -v b="$ordered_bucket" '$2 == b {print $1}' "$delta_counts")
  count="${count:-0}"
  label="${ordered_bucket#*|}"
  pct=$(awk "BEGIN {printf \"%.1f\", $count * 100 / $max_delta_count}")
  escaped_label=$(html_escape "$label")
  printf '    <div class="bar-row"><div class="bar-label">%s</div><div class="bar-track"><div class="bar-fill" style="width:%s%%;background:#ea580c"></div></div><div class="bar-value">%s</div></div>\n' "$escaped_label" "$pct" "$count" >> "$OUTPUT_HTML"
done
printf '  </div>\n' >> "$OUTPUT_HTML"

# ═══════════════════════════════════════
# AI Analysis Sections (from insights.json)
# ═══════════════════════════════════════

if [[ "$has_insights" == true ]]; then
  # --- Wins ---
  printf '\n  <h2 id="section-wins">Impressive Things</h2>\n' >> "$OUTPUT_HTML"
  while read -r win; do
    title=$(html_escape "$(echo "$win" | jq -r '.title')")
    desc=$(html_escape "$(echo "$win" | jq -r '.desc')")
    printf '  <div class="big-win"><div class="big-win-title">%s</div><div class="big-win-desc">%s</div></div>\n' "$title" "$desc" >> "$OUTPUT_HTML"
  done < <(jq -c '.wins[]' "$INSIGHTS_JSON" 2>/dev/null)

  # --- Friction ---
  printf '\n  <h2 id="section-friction">Friction Points</h2>\n' >> "$OUTPUT_HTML"
  while read -r fr; do
    title=$(html_escape "$(echo "$fr" | jq -r '.title')")
    desc=$(html_escape "$(echo "$fr" | jq -r '.desc')")
    example=$(html_escape "$(echo "$fr" | jq -r '.example // empty')")
    printf '  <div class="friction-card"><div class="friction-title">%s</div><div class="friction-desc">%s</div>' "$title" "$desc" >> "$OUTPUT_HTML"
    [[ -n "$example" ]] && printf '<div class="friction-example">%s</div>' "$example" >> "$OUTPUT_HTML"
    printf '</div>\n' >> "$OUTPUT_HTML"
  done < <(jq -c '.friction[]' "$INSIGHTS_JSON" 2>/dev/null)

  # --- Suggestions with instructions.md additions ---
  printf '\n  <h2 id="section-suggestions">Suggestions</h2>\n' >> "$OUTPUT_HTML"

  # instructions.md additions
  inst_count=$(jq '.instructions_additions | length' "$INSIGHTS_JSON" 2>/dev/null || echo 0)
  if [[ "$inst_count" -gt 0 ]]; then
    printf '  <div class="instructions-section"><h3>Add to instructions.md (copy &amp; paste)</h3>\n' >> "$OUTPUT_HTML"
    local_idx=0
    while read -r item; do
      text=$(html_escape "$(echo "$item" | jq -r '.text')")
      why=$(html_escape "$(echo "$item" | jq -r '.why // empty')")
      printf '    <div class="instructions-item"><div class="instructions-code" id="inst-%s">%s</div><button class="copy-btn" onclick="copyText('"'"'inst-%s'"'"', this)">Copy</button>' "$local_idx" "$text" "$local_idx" >> "$OUTPUT_HTML"
      [[ -n "$why" ]] && printf '<div class="instructions-why">%s</div>' "$why" >> "$OUTPUT_HTML"
      printf '</div>\n' >> "$OUTPUT_HTML"
      local_idx=$((local_idx + 1))
    done < <(jq -c '.instructions_additions[]' "$INSIGHTS_JSON" 2>/dev/null)
    printf '  </div>\n' >> "$OUTPUT_HTML"
  fi

  # Suggestion cards with copyable prompts
  local_idx=0
  while read -r sug; do
    title=$(html_escape "$(echo "$sug" | jq -r '.title')")
    desc=$(html_escape "$(echo "$sug" | jq -r '.desc')")
    prompt=$(html_escape "$(echo "$sug" | jq -r '.prompt // empty')")
    printf '  <div class="suggestion-card"><div class="suggestion-title">%s</div><div class="suggestion-desc">%s</div>' "$title" "$desc" >> "$OUTPUT_HTML"
    if [[ -n "$prompt" ]]; then
      printf '<div class="copyable-prompt"><div class="prompt-label">Prompt to paste into Codex</div><code id="prompt-%s">%s</code><button class="copy-btn" onclick="copyText('"'"'prompt-%s'"'"', this)">Copy</button></div>' "$local_idx" "$prompt" "$local_idx" >> "$OUTPUT_HTML"
    fi
    printf '</div>\n' >> "$OUTPUT_HTML"
    local_idx=$((local_idx + 1))
  done < <(jq -c '.suggestions[]' "$INSIGHTS_JSON" 2>/dev/null)

  # --- Comparison ---
  if jq -e '.comparison' "$INSIGHTS_JSON" >/dev/null 2>&1; then
    printf '\n  <h2 id="section-compare">Codex vs Claude Code</h2>\n' >> "$OUTPUT_HTML"
    printf '  <div class="compare-row">\n    <div class="compare-card"><h3 style="color:#2563eb;">Codex</h3><ul>\n' >> "$OUTPUT_HTML"
    while read -r item; do
      escaped_item=$(html_escape "$item")
      printf '      <li>%s</li>\n' "$escaped_item" >> "$OUTPUT_HTML"
    done < <(jq -r '.comparison.codex[]' "$INSIGHTS_JSON" 2>/dev/null)
    printf '    </ul></div>\n    <div class="compare-card"><h3 style="color:#d946ef;">Claude Code</h3><ul>\n' >> "$OUTPUT_HTML"
    while read -r item; do
      escaped_item=$(html_escape "$item")
      printf '      <li>%s</li>\n' "$escaped_item" >> "$OUTPUT_HTML"
    done < <(jq -r '.comparison.claude[]' "$INSIGHTS_JSON" 2>/dev/null)
    printf '    </ul></div>\n  </div>\n' >> "$OUTPUT_HTML"
  fi

else
  # No insights.json - show placeholder sections
  cat >> "$OUTPUT_HTML" <<'PLACEHOLDER'

  <h2 id="section-wins">Impressive Things</h2>
  <div class="note">Running AI analysis surfaces success patterns from your session data.<br>Run <code>codex-insights --ai --force</code>.</div>

  <h2 id="section-friction">Friction Points</h2>
  <div class="note">Running AI analysis generates friction points and improvement suggestions.<br>Run <code>codex-insights --ai --force</code>.</div>

  <h2 id="section-suggestions">Suggestions</h2>
  <div class="note">Running AI analysis generates copyable improvement prompts.<br>Run <code>codex-insights --ai --force</code>.</div>

  <h2 id="section-compare">Codex vs Claude Code</h2>
  <div class="note">Running AI analysis generates a comparison between the two tools.<br>Run <code>codex-insights --ai --force</code>.</div>
PLACEHOLDER
fi

# --- Top Sessions ---
printf '\n  <h2 id="section-sessions">Top Sessions</h2>\n' >> "$OUTPUT_HTML"
echo "$top_sessions" | jq -c '.[]' | while read -r session; do
  sid=$(echo "$session" | jq -r '.id')
  tokens=$(echo "$session" | jq -r '.tokens')
  tokens_fmt=$(fmt_num "$tokens")
  first_msg=$(html_escape "$(echo "$session" | jq -r '.first_msg' | head -c 120)")
  rollout_path=$(echo "$session" | jq -r '.rollout_path')
  short_id="${sid:0:12}"
  if [[ -n "$rollout_path" && "$rollout_path" != "null" ]]; then
    escaped_href=$(html_escape "file://${rollout_path}")
    printf '  <a class="session-card-link" href="%s"><div class="session-card"><div class="area-header"><span class="area-name">%s...</span><span class="area-count">%s tokens</span></div><div class="session-msg">%s</div></div></a>\n' "$escaped_href" "$short_id" "$tokens_fmt" "$first_msg" >> "$OUTPUT_HTML"
  else
    printf '  <div class="session-card"><div class="area-header"><span class="area-name">%s...</span><span class="area-count">%s tokens</span></div><div class="session-msg">%s</div></div>\n' "$short_id" "$tokens_fmt" "$first_msg" >> "$OUTPUT_HTML"
  fi
done

# --- Footer ---
cat >> "$OUTPUT_HTML" <<FOOTER
  <p style="margin-top:48px;font-size:12px;color:#94a3b8;text-align:center;">Generated: ${generated_at}</p>
</div>
<script>
function copyText(id, btn) {
  var el = document.getElementById(id);
  var text = el.textContent || el.innerText;
  navigator.clipboard.writeText(text).then(function() {
    btn.textContent = 'Copied!';
    btn.classList.add('copied');
    setTimeout(function() { btn.textContent = 'Copy'; btn.classList.remove('copied'); }, 2000);
  });
}
</script>
</body>
</html>
FOOTER

echo "$OUTPUT_HTML"
