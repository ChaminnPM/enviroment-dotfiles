#!/usr/bin/env bash
# sync.sh - sincroniza enviroment-dotfiles entre repo y ~/.config/opencode
set -euo pipefail
REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
OPENCODE_DIR="${OPENCODE_DIR:-$HOME/.config/opencode}"
MODE="${1:-pull}"
PRIV_DIR="$HOME/.config/opencode-private"

# Verificar SSH (ssh -T retorna 1 incluso en exito, por eso usamos grep)
echo "==> Verificando llaves SSH..."
if ! ssh -T git@github.com 2>&1 | grep -qi "successfully authenticated"; then
  echo "SSH GitHub falla. Ejecuta setup-git-identity.sh"; exit 1
fi

case "$MODE" in
  pull)
    cd "$REPO_DIR" && git pull --rebase
    mkdir -p "$OPENCODE_DIR"
    cp -r "$REPO_DIR/config/opencode/." "$OPENCODE_DIR/"
    if [ -d "$PRIV_DIR" ] && [ -d "$PRIV_DIR/config/opencode" ]; then
      cd "$PRIV_DIR" && git pull --rebase
      cp -r "$PRIV_DIR/config/opencode/." "$OPENCODE_DIR/"
    fi
    cd "$OPENCODE_DIR" && npm install
    echo "==> sincronizado (pull)"
    ;;
  push)
    mkdir -p "$REPO_DIR/config/opencode"
    cp -r "$OPENCODE_DIR/." "$REPO_DIR/config/opencode/"
    rm -f "$REPO_DIR/config/opencode/service.json"
    rm -rf "$REPO_DIR/config/opencode/node_modules"
    cd "$REPO_DIR"
    git add -A
    git commit -m "sync: $(date -Iseconds)" || echo "nada que commitear"
    git push
    if [ -d "$PRIV_DIR" ] && [ -d "$PRIV_DIR/config/opencode" ]; then
      cp -r "$OPENCODE_DIR/." "$PRIV_DIR/config/opencode/"
      cd "$PRIV_DIR" && git add -A && git commit -m "sync: $(date -Iseconds)" && git push
    fi
    echo "==> sincronizado (push)"
    ;;
  *)
    echo "Uso: $0 {push|pull}"; exit 1 ;;
esac