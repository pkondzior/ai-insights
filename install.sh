#!/usr/bin/env bash
# Install codex-insights
# Usage: bash install.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="${HOME}/.local/bin"
SKILLS_DIR="${HOME}/.skills"

echo "Installing codex-insights..."

# Ensure bin directory exists and is in PATH
mkdir -p "$BIN_DIR"

# Create skills symlink (~/.skills/codex-insights -> repo)
mkdir -p "$SKILLS_DIR"
ln -sfn "$REPO_DIR" "${SKILLS_DIR}/codex-insights"

# Create bin symlink (~/.local/bin/codex-insights -> repo/codex-insights)
ln -sfn "${REPO_DIR}/codex-insights" "${BIN_DIR}/codex-insights"

# Make scripts executable
chmod +x "${REPO_DIR}/codex-insights" "${REPO_DIR}/analyze.sh"

# Claude Code integration
CLAUDE_SKILLS="${HOME}/.claude/skills"
if [[ -d "${HOME}/.claude" ]]; then
  mkdir -p "$CLAUDE_SKILLS"
  ln -sfn "${SKILLS_DIR}/codex-insights" "${CLAUDE_SKILLS}/codex-insights"
  echo "  Claude Code skill linked"
fi

# Codex CLI integration
CODEX_SKILLS="${HOME}/.codex/skills"
if [[ -d "${HOME}/.codex" ]]; then
  mkdir -p "$CODEX_SKILLS"
  ln -sfn "${SKILLS_DIR}/codex-insights" "${CODEX_SKILLS}/codex-insights"
  echo "  Codex skill linked"
fi

echo ""
echo "Installed! Run: codex-insights"

# Check PATH
if ! echo "$PATH" | tr ':' '\n' | grep -q "^${BIN_DIR}$"; then
  echo ""
  echo "NOTE: Add ${BIN_DIR} to your PATH:"
  echo "  export PATH=\"\${HOME}/.local/bin:\${PATH}\""
fi
