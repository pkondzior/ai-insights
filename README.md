# codex-insights

Codex CLI のセッション履歴を分析し、AI による改善提案付き HTML レポートを生成。

Claude Code の `/insights` に相当する機能を Codex CLI 向けに提供します。

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/atani/codex-insights/master/install.sh | bash
```

## Usage

```bash
codex-insights
```

これだけ。AI 分析 → HTML レポート生成 → ブラウザで表示まで全自動。

```bash
codex-insights --force   # キャッシュを無視して再分析
```

## Requirements

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code)（AI 分析に使用）
- jq (`brew install jq`)
- [Codex CLI](https://github.com/openai/codex) のセッションデータ（`~/.codex/`）

## What It Generates

- セッション統計（メッセージ数、セッション数、ツール呼び出し数）
- プロジェクト別・ツール別の利用状況チャート
- キーワード頻度分析
- AI 分析
  - 成功パターン（Wins）
  - 摩擦点（Friction Points）
  - instructions.md への追加ルール（コピー可能）
  - 改善プロンプト（Codex にそのまま貼り付け可能）

## License

MIT
