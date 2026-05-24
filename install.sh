#!/usr/bin/env bash
# Install ai-insights (codex-insights, claude-insights, insights)
# Usage: curl -fsSL https://raw.githubusercontent.com/pkondzior/ai-insights/master/install.sh | bash
set -euo pipefail

REPO="https://github.com/pkondzior/ai-insights"
INSTALL_DIR="${HOME}/.local/share/ai-insights"
BIN_DIR="${HOME}/.local/bin"

echo "Installing ai-insights..."

# Hard dependencies
for cmd in git jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: $cmd is required." >&2
    [[ "$cmd" == "jq" ]]  && echo "  brew install jq" >&2
    [[ "$cmd" == "git" ]] && echo "  brew install git" >&2
    exit 1
  fi
done

# Soft dependencies — warn but don't fail
for cmd in codex claude sqlite3; do
  if ! command -v "$cmd" &>/dev/null; then
    case "$cmd" in
      codex)    echo "Note: 'codex' not found — 'codex-insights --ai' will be unavailable." >&2 ;;
      claude)   echo "Note: 'claude' CLI not found — 'claude-insights' still works on stored data, but Claude must have run at least once." >&2 ;;
      sqlite3)  echo "Note: 'sqlite3' not found — 'codex-insights' needs it to read state_5.sqlite." >&2 ;;
    esac
  fi
done

mkdir -p "$BIN_DIR"

# Clone or update
if [[ -d "$INSTALL_DIR/.git" ]]; then
  git -C "$INSTALL_DIR" pull --quiet
else
  if [[ -d "$INSTALL_DIR" ]]; then
    echo "Removing existing non-git directory: $INSTALL_DIR"
    rm -rf "$INSTALL_DIR"
  fi
  git clone --quiet "$REPO" "$INSTALL_DIR"
fi

# Mark all executables
for f in codex-insights claude-insights insights analyze.sh analyze-claude.sh analyze-combined.sh; do
  [[ -f "${INSTALL_DIR}/${f}" ]] && chmod +x "${INSTALL_DIR}/${f}"
done

# Symlink CLIs into BIN_DIR
for cli in codex-insights claude-insights insights; do
  [[ -f "${INSTALL_DIR}/${cli}" ]] && ln -sfn "${INSTALL_DIR}/${cli}" "${BIN_DIR}/${cli}"
done

# Register the codex-insights skill (only one with SKILL.md currently)
for dir in "${HOME}/.skills" "${HOME}/.claude/skills" "${HOME}/.codex/skills"; do
  [[ -d "$(dirname "$dir")" ]] || continue
  mkdir -p "$dir"
  ln -sfn "$INSTALL_DIR" "${dir}/codex-insights"
done

echo "Done! Try:"
echo "  codex-insights      # Codex dashboard"
echo "  claude-insights     # Claude dashboard"
echo "  insights            # Combined view"

if ! echo "$PATH" | tr ':' '\n' | grep -q "^${BIN_DIR}$"; then
  echo ""
  echo "Add to PATH: export PATH=\"\${HOME}/.local/bin:\${PATH}\""
fi
