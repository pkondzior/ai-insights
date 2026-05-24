# ai-insights

Local-only HTML dashboards for your AI coding sessions. Three CLI tools share one repo:

| Command          | Source data                                  | Output                                        |
|------------------|----------------------------------------------|-----------------------------------------------|
| `codex-insights` | `~/.codex/state_5.sqlite` (+ sessions)       | `~/.codex/usage-data/report.html`             |
| `claude-insights`| `~/.claude/usage-data/session-meta/` (+ JSONL) | `~/.claude/usage-data/claude-insights.html` |
| `insights`       | both, side-by-side                           | `~/.local/share/ai-insights/report.html`      |

All three are stats-only by default. `codex-insights` has an optional `--ai` mode that pipes a small redacted sample to `codex exec` for AI-generated suggestions. `claude-insights` and `insights` are local-only.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/pkondzior/ai-insights/master/install.sh | bash
```

Installs to `~/.local/share/ai-insights/` and symlinks all three commands into `~/.local/bin/`.

## Usage

```bash
codex-insights                 # Codex dashboard, no AI
codex-insights --ai            # Codex with AI analysis (opt-in, sends redacted sample)
codex-insights --help          # Full options including snippet/cache controls

claude-insights                # Claude dashboard, local only
claude-insights --no-open      # Skip browser auto-open

insights                       # Combined Codex + Claude view
insights --no-open
```

## What each report shows

All three share the same chart vocabulary:

- Stats row (sessions, tokens, tokens/day, msgs/day, etc.)
- Weekly tokens — vertical bar chart per Monday-anchored week
- Top projects (by session count)
- Top tools (by call count)
- User messages by time of day (UTC, 6-hour bands)
- User response time distribution (`<30s` → `6h-1d` buckets)
- Top sessions, linked directly to source rollout JSONLs

Extras per tool:

- `codex-insights` — optional AI analysis (`--ai`): wins, friction points, suggested `instructions.md` additions, copyable Codex prompts.
- `claude-insights` — Languages chart, Git commit / interrupt counts (from Claude's pre-computed session-meta).
- `insights` — side-by-side Codex vs Claude comparison cards, stacked weekly tokens (Codex below, Claude above), unified top-sessions ranking with tool badges.

## Privacy

By default everything is local. Token counts and stats are computed on your machine; nothing leaves it.

`codex-insights --ai` is the only path that sends data over the network — and even then only an aggregate summary plus a small redacted message sample. Snippets from raw sessions are off by default; opt in with `--include-snippets`.

| Mode                                            | Local scan of all sessions | Sent to `codex exec`                              |
|-------------------------------------------------|----------------------------|---------------------------------------------------|
| `codex-insights` (default)                      | Yes                        | Nothing                                           |
| `codex-insights --ai`                           | Yes                        | Aggregate stats + small redacted message sample   |
| `codex-insights --ai --include-snippets`        | Yes                        | Above + redacted snippets from recent sessions    |
| `claude-insights`                               | Yes                        | Nothing                                           |
| `insights`                                      | Yes (both tools)           | Nothing                                           |

AI-sample sizes are configurable via `--ai-messages`, `--ai-snippet-sessions`, `--ai-snippets-per-session`, or the matching `CODEX_INSIGHTS_*` env vars.

## Token methodology

Both Codex's and Claude's reported "tokens" sum `input + output + cache_creation + cache_read` — i.e. all model context processed, the same number Codex's `tokens_used` records. Claude's own `session-meta` excludes cache reads (so it underreports by 100–1000× on cache-heavy sessions); `claude-insights` walks the raw rollout JSONLs to fix this.

## Requirements

- `jq` (`brew install jq`)
- `sqlite3` (preinstalled on macOS; required only for Codex)
- `codex` CLI — only required when using `codex-insights --ai`

## Credits

Forked from [atani/codex-insights](https://github.com/atani/codex-insights). Extended with Claude support (`claude-insights`, `insights`) and other changes — see `LICENSE` and git history.

## License

MIT
