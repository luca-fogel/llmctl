#!/bin/bash
# Installs the llmctl CLI and, optionally, the menu bar app.
#
#   ./install.sh              CLI + menu bar app
#   ./install.sh --cli-only   just the CLI
#   ./install.sh --uninstall  remove both
#
# The CLI is symlinked, not copied, so `git pull` updates it.
set -euo pipefail
cd "$(dirname "$0")"
REPO="$(pwd)"
APP_NAME="LLM Memory"
APPS="$HOME/Applications"

# Prefer a bin directory that is already on PATH; fall back to ~/.local/bin.
pick_bindir() {
  for d in "$HOME/.local/bin" "$HOME/bin" /usr/local/bin; do
    case ":$PATH:" in *":$d:"*) if [ -d "$d" ] || mkdir -p "$d" 2>/dev/null; then echo "$d"; return; fi ;; esac
  done
  mkdir -p "$HOME/.local/bin"; echo "$HOME/.local/bin"
}

if [ "${1:-}" = "--uninstall" ]; then
  for d in "$HOME/.local/bin" "$HOME/bin" /usr/local/bin; do
    if [ -L "$d/llmctl" ]; then rm -f "$d/llmctl" && echo "removed $d/llmctl"; fi
  done
  osascript -e "quit app \"${APP_NAME}\"" 2>/dev/null || true
  rm -rf "$APPS/${APP_NAME}.app" && echo "removed $APPS/${APP_NAME}.app"
  exit 0
fi

BIN="$(pick_bindir)"
ln -sf "$REPO/llmctl" "$BIN/llmctl"
chmod +x "$REPO/llmctl"
echo "==> llmctl -> $BIN/llmctl"
case ":$PATH:" in
  *":$BIN:"*) ;;
  *) echo "    NOTE: $BIN is not on your PATH; add it to your shell profile." ;;
esac

if [ "${1:-}" != "--cli-only" ]; then
  ./menubar/build.sh
  mkdir -p "$APPS"
  osascript -e "quit app \"${APP_NAME}\"" 2>/dev/null || true
  sleep 1
  rsync -a --delete "build/${APP_NAME}.app/" "$APPS/${APP_NAME}.app/"
  touch "$APPS"
  mdimport "$APPS/${APP_NAME}.app" 2>/dev/null || true
  echo "==> installed $APPS/${APP_NAME}.app"
  echo "    launch: open -a \"${APP_NAME}\"   (menu bar only; Spotlight: \"LLM Memory\")"
fi

echo
"$BIN/llmctl" status
