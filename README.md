# codex-insights

Codex CLI のセッション履歴を分析し、HTML レポートを生成するツール。

Claude Code の `/insights` に相当する機能を Codex CLI 向けに提供します。

## Features

- セッション統計（メッセージ数、セッション数、ツール呼び出し数）
- プロジェクト別・ツール別の利用状況チャート
- キーワード頻度分析
- AI 分析による改善提案（insights.json 連携）
  - 成功パターンの抽出
  - 摩擦点の特定
  - コピー可能な改善プロンプト
  - Codex vs Claude Code 比較

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/atani/codex-insights/master/install.sh | bash
```

## Usage

### 基本（統計レポート生成）

```bash
codex-insights
```

`~/.codex/usage-data/report.html` にレポートが生成され、ブラウザで開きます。

### AI 分析付き（推奨）

Codex CLI で深い分析を実行：

```bash
codex exec "$(cat /path/to/codex-insights/SKILL.md)"
```

分析結果が `~/.codex/usage-data/insights.json` に保存され、次回 `codex-insights` 実行時にレポートに反映されます。

## Requirements

- bash 3.x+（macOS 標準で動作）
- jq
- [Codex CLI](https://github.com/openai/codex) のセッションデータ（`~/.codex/`）

## File Structure

```
~/.codex/
  history.jsonl          # Codex が自動生成するメッセージ履歴
  sessions/              # セッション詳細データ
  usage-data/
    report.html          # 生成されるレポート
    insights.json        # AI 分析データ（オプション）
```

## License

MIT
