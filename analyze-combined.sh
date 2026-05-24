#!/usr/bin/env bash
# analyze-combined.sh - Render a combined Codex + Claude dashboard.
# Triggered by the `insights` entry script; expects CODEX_OK / CLAUDE_OK env vars.
set -euo pipefail
if locale -a 2>/dev/null | grep -q 'C.UTF-8'; then
  export LC_ALL=C.UTF-8
elif locale -a 2>/dev/null | grep -q 'en_US.UTF-8'; then
  export LC_ALL=en_US.UTF-8
fi

html_escape() {
  local s="$1"
  s="${s//&/\&amp;}"
  s="${s//</\&lt;}"
  s="${s//>/\&gt;}"
  s="${s//\"/\&quot;}"
  echo "$s"
}

fmt_num() {
  awk -v n="$1" 'BEGIN {
    if (n+0 >= 1e9)      printf "%.2fB", n/1e9;
    else if (n+0 >= 1e6) printf "%.1fM", n/1e6;
    else if (n+0 >= 1e3) printf "%.1fK", n/1e3;
    else                 printf "%d", n
  }'
}

CODEX_OK="${CODEX_OK:-false}"
CLAUDE_OK="${CLAUDE_OK:-false}"

OUTPUT_DIR="${HOME}/.local/share/ai-insights"
OUTPUT_HTML="${OUTPUT_DIR}/report.html"
mkdir -p "$OUTPUT_DIR"
TMPDIR_WORK=$(mktemp -d)
trap 'rm -rf "$TMPDIR_WORK"' EXIT

# ───────── Codex extraction ─────────
codex_total_tokens=0
codex_sessions=0
codex_first_ts=0
codex_last_ts=0
codex_weekly="${TMPDIR_WORK}/codex_weekly.tsv"
codex_projects="${TMPDIR_WORK}/codex_projects.txt"
codex_top_sessions="${TMPDIR_WORK}/codex_top.tsv"
: > "$codex_weekly"
: > "$codex_projects"
: > "$codex_top_sessions"

if [[ "$CODEX_OK" == true ]]; then
  CODEX_DB="${HOME}/.codex/state_5.sqlite"
  codex_sessions=$(sqlite3 "$CODEX_DB" "SELECT COUNT(*) FROM threads")
  codex_total_tokens=$(sqlite3 "$CODEX_DB" "SELECT IFNULL(SUM(tokens_used),0) FROM threads")
  codex_first_ts=$(sqlite3 "$CODEX_DB" "SELECT MIN(created_at) FROM threads")
  codex_last_ts=$(sqlite3 "$CODEX_DB"  "SELECT MAX(created_at) FROM threads")

  # Weekly aggregation (Monday-anchored, UTC). 'weekday 0' = next Sunday; '-6 days' = previous Monday.
  sqlite3 -separator $'\t' "$CODEX_DB" "
    SELECT date(created_at, 'unixepoch', 'weekday 0', '-6 days') AS monday,
           SUM(tokens_used)
    FROM threads
    GROUP BY monday
    ORDER BY monday
  " > "$codex_weekly"

  # Per-project counts
  sqlite3 "$CODEX_DB" "
    SELECT REPLACE(cwd, '/Users/', '') FROM threads WHERE cwd != ''
  " | awk -F/ '{print $NF}' | sort | uniq -c | sort -rn | head -10 > "$codex_projects"

  # Top sessions by tokens (sid, tokens, first_msg, rollout_path)
  sqlite3 -separator $'\t' "$CODEX_DB" "
    SELECT id,
           tokens_used,
           REPLACE(SUBSTR(IFNULL(first_user_message, ''), 1, 120), char(10), ' '),
           rollout_path
    FROM threads
    ORDER BY tokens_used DESC
    LIMIT 5
  " > "$codex_top_sessions"
fi

# ───────── Claude extraction ─────────
claude_total_tokens=0
claude_sessions=0
claude_first_ts=0
claude_last_ts=0
claude_total_user_msgs=0
claude_total_tool_calls=0
claude_weekly="${TMPDIR_WORK}/claude_weekly.tsv"
claude_projects="${TMPDIR_WORK}/claude_projects.txt"
claude_top_sessions="${TMPDIR_WORK}/claude_top.tsv"
: > "$claude_weekly"
: > "$claude_projects"
: > "$claude_top_sessions"

if [[ "$CLAUDE_OK" == true ]]; then
  CLAUDE_META_DIR="${HOME}/.claude/usage-data/session-meta"
  CLAUDE_PROJECTS_DIR="${HOME}/.claude/projects"
  combined_meta="${TMPDIR_WORK}/claude_combined.json"
  jq -s '.' "${CLAUDE_META_DIR}"/*.json > "$combined_meta"

  claude_sessions=$(jq 'length' "$combined_meta")
  claude_total_user_msgs=$(jq '[.[] | .user_message_count // 0] | add // 0' "$combined_meta")
  claude_total_tool_calls=$(jq '[.[] | .tool_counts // {} | to_entries | map(.value) | add // 0] | add // 0' "$combined_meta")

  # Honest token totals: walk rollout JSONLs and sum input + output + cache_creation + cache_read.
  echo "Walking Claude session JSONLs for honest tokens..." >&2
  claude_token_map="${TMPDIR_WORK}/claude_token_map.tsv"
  : > "$claude_token_map"
  jq -r '.[].session_id' "$combined_meta" | while read -r sid; do
    jsonl=$(find "$CLAUDE_PROJECTS_DIR" -maxdepth 3 -type f -name "${sid}.jsonl" 2>/dev/null | head -1)
    if [[ -n "$jsonl" ]]; then
      t=$(jq -s '
        [.[] | select(.type == "assistant") | .message.usage // {}]
        | map((.input_tokens // 0) + (.output_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0))
        | add // 0
      ' "$jsonl" 2>/dev/null)
      printf '%s\t%s\t%s\n' "$sid" "${t:-0}" "$jsonl" >> "$claude_token_map"
    fi
  done
  claude_total_tokens=$(awk -F'\t' '{sum+=$2} END {print sum+0}' "$claude_token_map")

  # Date range from session-meta start_times
  claude_first_iso=$(jq -r '[.[].start_time] | sort | .[0] // ""' "$combined_meta")
  claude_last_iso=$(jq -r  '[.[].start_time] | sort | .[-1] // ""' "$combined_meta")
  claude_first_ts=$(printf '%s' "$claude_first_iso" | jq -Rr 'sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601')
  claude_last_ts=$(printf '%s' "$claude_last_iso"  | jq -Rr 'sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601')

  # Weekly buckets: join session start_time → honest_tokens
  # Build a sid → epoch map from meta, then bucket
  jq -r '.[] | "\(.session_id)\t\(.start_time)"' "$combined_meta" \
    | awk -F'\t' -v map="$claude_token_map" '
      BEGIN {
        while ((getline line < map) > 0) {
          split(line, a, "\t")
          tok[a[1]] = a[2]
        }
        close(map)
      }
      {
        sid = $1; iso = $2
        if (sid in tok) print iso "\t" tok[sid]
      }
    ' | jq -Rr 'split("\t") as $r |
        ($r[0] | sub("\\.[0-9]+Z$"; "Z") | (try fromdateiso8601 catch 0)) as $t |
        ($r[1] | tonumber) as $tok |
        if $t == 0 then empty
        else
          (
            (($t | strftime("%w")) | tonumber) as $dow_sun
            | (if $dow_sun == 0 then 6 else $dow_sun - 1 end) as $dow_mon
            | ($t - ($dow_mon * 86400)) | floor
          ) as $monday_epoch
          | "\($monday_epoch | strftime("%Y-%m-%d"))\t\($tok)"
        end' 2>/dev/null \
    | awk -F'\t' '{sum[$1]+=$2} END {for (k in sum) print k"\t"sum[k]}' | sort > "$claude_weekly"

  # Per-project counts (sessions per project name)
  jq -r '.[] | (.project_path // "") | split("/") | .[-1] // ""' "$combined_meta" \
    | awk 'NF > 0' | sort | uniq -c | sort -rn | head -10 > "$claude_projects"

  # Top sessions by honest tokens
  awk -F'\t' '{print $2"\t"$1"\t"$3}' "$claude_token_map" | sort -rn | head -5 \
    | while IFS=$'\t' read -r tokens sid jsonl; do
      first_msg=$(jq -r --arg sid "$sid" '.[] | select(.session_id == $sid) | .first_prompt // ""' "$combined_meta" | head -c 120 | tr '\n' ' ')
      project=$(jq -r --arg sid "$sid" '.[] | select(.session_id == $sid) | (.project_path // "") | split("/") | .[-1] // ""' "$combined_meta")
      printf '%s\t%s\t%s\t%s\t%s\n' "$sid" "$tokens" "$first_msg" "$jsonl" "$project" >> "$claude_top_sessions"
    done
fi

# ───────── Combined aggregates ─────────
combined_total_tokens=$((codex_total_tokens + claude_total_tokens))
combined_sessions=$((codex_sessions + claude_sessions))

# Date span = union of both ranges
combined_first_ts="$codex_first_ts"
combined_last_ts="$codex_last_ts"
if [[ "$CLAUDE_OK" == true ]]; then
  if [[ "$CODEX_OK" != true ]]; then
    combined_first_ts="$claude_first_ts"
    combined_last_ts="$claude_last_ts"
  else
    [[ "$claude_first_ts" -lt "$combined_first_ts" ]] && combined_first_ts="$claude_first_ts"
    [[ "$claude_last_ts"  -gt "$combined_last_ts"  ]] && combined_last_ts="$claude_last_ts"
  fi
fi
combined_days=$(( (combined_last_ts - combined_first_ts) / 86400 + 1 ))
[[ $combined_days -lt 1 ]] && combined_days=1
combined_first_date=$(date -r "$combined_first_ts" '+%Y-%m-%d' 2>/dev/null || date -d "@$combined_first_ts" '+%Y-%m-%d')
combined_last_date=$(date -r "$combined_last_ts"  '+%Y-%m-%d' 2>/dev/null || date -d "@$combined_last_ts"  '+%Y-%m-%d')

combined_tokens_per_day=$(awk -v t="$combined_total_tokens" -v d="$combined_days" 'BEGIN {printf "%d", t/d + 0.5}')
combined_total_tokens_fmt=$(fmt_num "$combined_total_tokens")
combined_tokens_per_day_fmt=$(fmt_num "$combined_tokens_per_day")
codex_total_tokens_fmt=$(fmt_num "$codex_total_tokens")
claude_total_tokens_fmt=$(fmt_num "$claude_total_tokens")

# Weekly merge: union of weeks from both sources
combined_weekly="${TMPDIR_WORK}/combined_weekly.tsv"
awk -F'\t' -v src="codex"  '{print $1"\t"src"\t"$2}' "$codex_weekly"  >  "$combined_weekly"
awk -F'\t' -v src="claude" '{print $1"\t"src"\t"$2}' "$claude_weekly" >> "$combined_weekly"

# Build per-week (monday, codex_tokens, claude_tokens) sorted by date
weekly_pivot=$(awk -F'\t' '
  { tok[$1"\t"$2] = $3 + 0; weeks[$1] = 1 }
  END {
    n = 0
    for (w in weeks) { ws[n++] = w }
    # bubble sort (small N)
    for (i = 0; i < n; i++) for (j = i+1; j < n; j++) if (ws[j] < ws[i]) { t = ws[i]; ws[i] = ws[j]; ws[j] = t }
    for (i = 0; i < n; i++) {
      w = ws[i]
      c = tok[w"\tcodex"]   + 0
      a = tok[w"\tclaude"]  + 0
      printf "%s\t%d\t%d\n", w, c, a
    }
  }
' "$combined_weekly")
max_weekly_combined=$(printf '%s\n' "$weekly_pivot" | awk -F'\t' 'BEGIN{m=1} {s = $2+$3; if (s > m) m = s} END {print m}')

# Unified top sessions list (combine codex + claude top-5, then rerank top 10)
all_top="${TMPDIR_WORK}/all_top.tsv"
{
  awk -F'\t' '{printf "codex\t%s\t%s\t%s\t%s\t-\n", $1, $2, $3, $4}' "$codex_top_sessions"
  cat "$claude_top_sessions" | awk -F'\t' '{printf "claude\t%s\t%s\t%s\t%s\t%s\n", $1, $2, $3, $4, $5}'
} > "$all_top"
top_combined=$(sort -t$'\t' -k3,3 -nr "$all_top" | head -10)

# Date ranges per tool (for cards)
codex_first_date="-"
codex_last_date="-"
if [[ "$CODEX_OK" == true ]]; then
  codex_first_date=$(date -r "$codex_first_ts" '+%Y-%m-%d' 2>/dev/null || date -d "@$codex_first_ts" '+%Y-%m-%d')
  codex_last_date=$(date -r "$codex_last_ts" '+%Y-%m-%d' 2>/dev/null  || date -d "@$codex_last_ts" '+%Y-%m-%d')
fi
claude_first_date="-"
claude_last_date="-"
if [[ "$CLAUDE_OK" == true ]]; then
  claude_first_date=$(date -r "$claude_first_ts" '+%Y-%m-%d' 2>/dev/null || date -d "@$claude_first_ts" '+%Y-%m-%d')
  claude_last_date=$(date -r "$claude_last_ts" '+%Y-%m-%d' 2>/dev/null   || date -d "@$claude_last_ts" '+%Y-%m-%d')
fi
codex_days=1
[[ "$CODEX_OK" == true ]] && codex_days=$(( (codex_last_ts - codex_first_ts) / 86400 + 1 ))
[[ $codex_days -lt 1 ]] && codex_days=1
claude_days=1
[[ "$CLAUDE_OK" == true ]] && claude_days=$(( (claude_last_ts - claude_first_ts) / 86400 + 1 ))
[[ $claude_days -lt 1 ]] && claude_days=1
codex_tpd=$(awk -v t="$codex_total_tokens" -v d="$codex_days" 'BEGIN {printf "%d", t/d + 0.5}')
claude_tpd=$(awk -v t="$claude_total_tokens" -v d="$claude_days" 'BEGIN {printf "%d", t/d + 0.5}')
codex_tpd_fmt=$(fmt_num "$codex_tpd")
claude_tpd_fmt=$(fmt_num "$claude_tpd")

generated_at=$(date '+%Y-%m-%d %H:%M')

# ───────── HTML ─────────
cat > "$OUTPUT_HTML" <<'CSS'
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>AI Coding Insights</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #f8fafc; color: #334155; line-height: 1.65; padding: 48px 24px; }
    .container { max-width: 880px; margin: 0 auto; }
    h1 { font-size: 32px; font-weight: 700; color: #0f172a; margin-bottom: 8px; }
    h2 { font-size: 20px; font-weight: 600; color: #0f172a; margin-top: 48px; margin-bottom: 16px; }
    .subtitle { color: #64748b; font-size: 15px; margin-bottom: 32px; }
    .stats-row { display: flex; gap: 24px; margin-bottom: 24px; padding: 20px 0; border-top: 1px solid #e2e8f0; border-bottom: 1px solid #e2e8f0; flex-wrap: wrap; justify-content: center; }
    .stat { text-align: center; min-width: 100px; }
    .stat-value { font-size: 26px; font-weight: 700; color: #0f172a; }
    .stat-label { font-size: 11px; color: #64748b; text-transform: uppercase; }
    .compare-row { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; margin: 16px 0 40px 0; }
    .compare-card { background: white; border: 1px solid #e2e8f0; border-radius: 8px; padding: 18px 20px; }
    .compare-card.codex { border-left: 4px solid #2563eb; }
    .compare-card.claude { border-left: 4px solid #d946ef; }
    .compare-title { font-size: 14px; font-weight: 700; margin-bottom: 12px; }
    .compare-card.codex .compare-title { color: #2563eb; }
    .compare-card.claude .compare-title { color: #d946ef; }
    .compare-row-stat { display: flex; justify-content: space-between; font-size: 13px; padding: 4px 0; }
    .compare-row-stat .label { color: #64748b; }
    .compare-row-stat .value { font-weight: 600; color: #0f172a; }
    .vbar-chart { display: flex; align-items: flex-end; gap: 3px; height: 240px; padding: 28px 4px 40px 4px; border-bottom: 1px solid #e2e8f0; position: relative; overflow-x: auto; }
    .vbar { flex: 1; min-width: 14px; display: flex; flex-direction: column; position: relative; }
    .vbar-claude { width: 100%; background: #d946ef; border-radius: 2px 2px 0 0; transition: background 0.15s; }
    .vbar-codex { width: 100%; background: #2563eb; border-radius: 0; transition: background 0.15s; }
    .vbar-codex:only-child { border-radius: 2px 2px 0 0; }
    .vbar:hover .vbar-claude { background: #a21caf; }
    .vbar:hover .vbar-codex { background: #1d4ed8; }
    .vbar-value { font-size: 9px; color: #64748b; position: absolute; top: -18px; left: 50%; transform: translateX(-50%); white-space: nowrap; }
    .vbar-label { font-size: 9px; color: #94a3b8; position: absolute; bottom: -32px; left: 0; white-space: nowrap; transform: rotate(-45deg); transform-origin: top left; }
    .legend { display: flex; justify-content: center; gap: 24px; margin-top: 12px; font-size: 12px; color: #64748b; }
    .legend-dot { display: inline-block; width: 10px; height: 10px; border-radius: 2px; margin-right: 6px; vertical-align: middle; }
    .legend-codex .legend-dot { background: #2563eb; }
    .legend-claude .legend-dot { background: #d946ef; }
    .charts-row { display: grid; grid-template-columns: 1fr 1fr; gap: 24px; margin: 24px 0; }
    .chart-card { background: white; border: 1px solid #e2e8f0; border-radius: 8px; padding: 16px; }
    .chart-title { font-size: 12px; font-weight: 600; color: #64748b; text-transform: uppercase; margin-bottom: 12px; }
    .bar-row { display: flex; align-items: center; margin-bottom: 6px; }
    .bar-label { width: 130px; font-size: 11px; color: #475569; flex-shrink: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .bar-track { flex: 1; height: 6px; background: #f1f5f9; border-radius: 3px; margin: 0 8px; }
    .bar-fill { height: 100%; border-radius: 3px; }
    .bar-value { width: 50px; font-size: 11px; font-weight: 500; color: #64748b; text-align: right; }
    .session-card { background: white; border: 1px solid #e2e8f0; border-radius: 8px; padding: 12px 16px; margin-bottom: 8px; transition: border-color 0.15s, background 0.15s; position: relative; }
    .session-card-link { display: block; text-decoration: none; color: inherit; }
    .session-card-link:hover .session-card { border-color: #94a3b8; background: #f8fafc; }
    .area-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 4px; }
    .area-name { font-weight: 600; font-size: 13px; color: #0f172a; font-family: monospace; }
    .area-count { font-size: 12px; color: #64748b; background: #f1f5f9; padding: 2px 8px; border-radius: 4px; }
    .session-msg { font-size: 13px; color: #475569; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; max-width: 700px; }
    .session-meta-line { font-size: 11px; color: #94a3b8; margin-top: 4px; font-family: monospace; }
    .tool-badge { display: inline-block; font-size: 9px; font-weight: 700; padding: 2px 6px; border-radius: 3px; margin-right: 6px; text-transform: uppercase; vertical-align: middle; }
    .badge-codex { background: #dbeafe; color: #1e40af; }
    .badge-claude { background: #fae8ff; color: #86198f; }
    @media (max-width: 720px) { .compare-row, .charts-row { grid-template-columns: 1fr; } }
  </style>
</head>
<body>
<div class="container">
CSS

# Header
cat >> "$OUTPUT_HTML" <<HEADER
  <h1>AI Coding Insights</h1>
  <p class="subtitle">${combined_sessions} sessions, ${combined_total_tokens_fmt} tokens across both tools | ${combined_first_date} to ${combined_last_date} (${combined_days} days)</p>
HEADER

# Combined stats row
cat >> "$OUTPUT_HTML" <<STATS
  <div class="stats-row">
    <div class="stat"><div class="stat-value">${combined_sessions}</div><div class="stat-label">Sessions</div></div>
    <div class="stat"><div class="stat-value">${combined_total_tokens_fmt}</div><div class="stat-label">Tokens</div></div>
    <div class="stat"><div class="stat-value">${combined_tokens_per_day_fmt}</div><div class="stat-label">Tokens/Day</div></div>
    <div class="stat"><div class="stat-value">${combined_days}</div><div class="stat-label">Days Active</div></div>
  </div>
STATS

# Side-by-side comparison
codex_share=0
claude_share=0
if [[ "$combined_total_tokens" -gt 0 ]]; then
  codex_share=$(awk -v c="$codex_total_tokens" -v t="$combined_total_tokens" 'BEGIN {printf "%.1f", c*100/t}')
  claude_share=$(awk -v c="$claude_total_tokens" -v t="$combined_total_tokens" 'BEGIN {printf "%.1f", c*100/t}')
fi
cat >> "$OUTPUT_HTML" <<COMPARE
  <div class="compare-row">
    <div class="compare-card codex">
      <div class="compare-title">Codex</div>
      <div class="compare-row-stat"><span class="label">Sessions</span><span class="value">${codex_sessions}</span></div>
      <div class="compare-row-stat"><span class="label">Tokens</span><span class="value">${codex_total_tokens_fmt}</span></div>
      <div class="compare-row-stat"><span class="label">Tokens/day</span><span class="value">${codex_tpd_fmt}</span></div>
      <div class="compare-row-stat"><span class="label">Span</span><span class="value">${codex_first_date} → ${codex_last_date}</span></div>
      <div class="compare-row-stat"><span class="label">Share of total</span><span class="value">${codex_share}%</span></div>
    </div>
    <div class="compare-card claude">
      <div class="compare-title">Claude Code</div>
      <div class="compare-row-stat"><span class="label">Sessions</span><span class="value">${claude_sessions}</span></div>
      <div class="compare-row-stat"><span class="label">Tokens</span><span class="value">${claude_total_tokens_fmt}</span></div>
      <div class="compare-row-stat"><span class="label">Tokens/day</span><span class="value">${claude_tpd_fmt}</span></div>
      <div class="compare-row-stat"><span class="label">Span</span><span class="value">${claude_first_date} → ${claude_last_date}</span></div>
      <div class="compare-row-stat"><span class="label">Share of total</span><span class="value">${claude_share}%</span></div>
    </div>
  </div>
COMPARE

# Weekly stacked tokens
cat >> "$OUTPUT_HTML" <<'WEEKLY_HEADER'
  <h2>Weekly Tokens <span style="font-size:12px;color:#94a3b8;font-weight:400;">(millions, stacked: Codex below, Claude above)</span></h2>
  <div class="chart-card">
    <div class="vbar-chart">
WEEKLY_HEADER

printf '%s\n' "$weekly_pivot" | while IFS=$'\t' read -r monday codex_t claude_t; do
  [[ -z "$monday" ]] && continue
  total=$((codex_t + claude_t))
  bar_pct=$(awk -v s="$total" -v m="$max_weekly_combined" 'BEGIN {printf "%.1f", s*100/m}')
  total_m=$(awk -v t="$total" 'BEGIN {printf "%.1f", t/1000000}')
  short_label=$(date -j -f "%Y-%m-%d" "$monday" "+%b %d" 2>/dev/null || date -d "$monday" "+%b %d" 2>/dev/null || echo "$monday")
  printf '      <div class="vbar" style="height:%s%%;" title="%s — Codex %sM, Claude %sM"><div class="vbar-value">%sM</div>\n' \
    "$bar_pct" "$monday" \
    "$(awk -v t="$codex_t" 'BEGIN {printf "%.1f", t/1000000}')" \
    "$(awk -v t="$claude_t" 'BEGIN {printf "%.1f", t/1000000}')" \
    "$total_m" >> "$OUTPUT_HTML"
  if [[ "$claude_t" -gt 0 ]]; then
    cl_flex=$(awk -v c="$claude_t" -v t="$total" 'BEGIN {printf "%.4f", c/t}')
    printf '        <div class="vbar-claude" style="flex:%s;"></div>\n' "$cl_flex" >> "$OUTPUT_HTML"
  fi
  if [[ "$codex_t" -gt 0 ]]; then
    cx_flex=$(awk -v c="$codex_t" -v t="$total" 'BEGIN {printf "%.4f", c/t}')
    printf '        <div class="vbar-codex" style="flex:%s;"></div>\n' "$cx_flex" >> "$OUTPUT_HTML"
  fi
  printf '        <div class="vbar-label">%s</div>\n      </div>\n' "$short_label" >> "$OUTPUT_HTML"
done

cat >> "$OUTPUT_HTML" <<'WEEKLY_FOOTER'
    </div>
  </div>
  <div class="legend">
    <span class="legend-codex"><span class="legend-dot"></span>Codex</span>
    <span class="legend-claude"><span class="legend-dot"></span>Claude</span>
  </div>
WEEKLY_FOOTER

# Projects side-by-side
cat >> "$OUTPUT_HTML" <<'PROJ_HEADER'
  <h2>Top Projects (by session count)</h2>
  <div class="charts-row">
    <div class="chart-card">
      <div class="chart-title">Codex</div>
PROJ_HEADER

if [[ -s "$codex_projects" ]]; then
  max_codex_proj=$(head -1 "$codex_projects" | awk '{print $1}')
  : "${max_codex_proj:=1}"
  while read -r count name; do
    [[ -z "$count" ]] && continue
    pct=$(awk "BEGIN {printf \"%.1f\", $count * 100 / $max_codex_proj}")
    escaped_name=$(html_escape "$name")
    printf '      <div class="bar-row"><div class="bar-label">%s</div><div class="bar-track"><div class="bar-fill" style="width:%s%%;background:#2563eb"></div></div><div class="bar-value">%s</div></div>\n' "$escaped_name" "$pct" "$count" >> "$OUTPUT_HTML"
  done < "$codex_projects"
else
  printf '      <div style="color:#94a3b8;font-size:13px;">no data</div>\n' >> "$OUTPUT_HTML"
fi

cat >> "$OUTPUT_HTML" <<'PROJ_MID'
    </div>
    <div class="chart-card">
      <div class="chart-title">Claude</div>
PROJ_MID

if [[ -s "$claude_projects" ]]; then
  max_claude_proj=$(head -1 "$claude_projects" | awk '{print $1}')
  : "${max_claude_proj:=1}"
  while read -r count name; do
    [[ -z "$count" ]] && continue
    pct=$(awk "BEGIN {printf \"%.1f\", $count * 100 / $max_claude_proj}")
    escaped_name=$(html_escape "$name")
    printf '      <div class="bar-row"><div class="bar-label">%s</div><div class="bar-track"><div class="bar-fill" style="width:%s%%;background:#d946ef"></div></div><div class="bar-value">%s</div></div>\n' "$escaped_name" "$pct" "$count" >> "$OUTPUT_HTML"
  done < "$claude_projects"
else
  printf '      <div style="color:#94a3b8;font-size:13px;">no data</div>\n' >> "$OUTPUT_HTML"
fi

cat >> "$OUTPUT_HTML" <<'PROJ_END'
    </div>
  </div>
PROJ_END

# Combined Top Sessions
printf '\n  <h2>Top Sessions Across Both Tools <span style="font-size:12px;color:#94a3b8;font-weight:400;">(by tokens)</span></h2>\n' >> "$OUTPUT_HTML"

printf '%s\n' "$top_combined" | while IFS=$'\t' read -r tool sid tokens first_msg jsonl project; do
  [[ -z "$tool" ]] && continue
  short_id="${sid:0:12}"
  tokens_fmt=$(fmt_num "$tokens")
  first_msg_clean=$(html_escape "${first_msg:0:120}")
  badge_class="badge-${tool}"
  meta_line="${tool} session"
  if [[ -n "$project" && "$project" != "-" ]]; then
    meta_line="${project} · ${tool}"
  fi
  if [[ -n "$jsonl" && -f "$jsonl" ]]; then
    escaped_href=$(html_escape "file://${jsonl}")
    printf '  <a class="session-card-link" href="%s"><div class="session-card"><div class="area-header"><span class="area-name"><span class="tool-badge %s">%s</span>%s...</span><span class="area-count">%s tokens</span></div><div class="session-msg">%s</div><div class="session-meta-line">%s</div></div></a>\n' \
      "$escaped_href" "$badge_class" "$tool" "$short_id" "$tokens_fmt" "$first_msg_clean" "$meta_line" >> "$OUTPUT_HTML"
  else
    printf '  <div class="session-card"><div class="area-header"><span class="area-name"><span class="tool-badge %s">%s</span>%s...</span><span class="area-count">%s tokens</span></div><div class="session-msg">%s</div><div class="session-meta-line">%s</div></div>\n' \
      "$badge_class" "$tool" "$short_id" "$tokens_fmt" "$first_msg_clean" "$meta_line" >> "$OUTPUT_HTML"
  fi
done

# Footer
cat >> "$OUTPUT_HTML" <<FOOTER
  <p style="margin-top:48px;font-size:12px;color:#94a3b8;text-align:center;">
    Generated: ${generated_at}<br>
    Token counts include input + output + cache_creation + cache_read (model context processed).
  </p>
</div>
</body>
</html>
FOOTER

echo "$OUTPUT_HTML"
