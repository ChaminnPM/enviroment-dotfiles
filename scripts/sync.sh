#!/usr/bin/env bash
# sync.sh - sincroniza solo los assets PUBLICOS entre repo y ~/.config/opencode.
# Los assets privados (Nuxiba) se gestionan con sync-private.sh del repo privado.
set -euo pipefail

OPENCODE_DIR="${OPENCODE_DIR:-$HOME/.config/opencode}"
MODE="${1:-pull}"

# Si no hay repo local valido, clonar en temporal y limpiar al salir.
if [ -z "${REPO_DIR:-}" ] || [ ! -d "${REPO_DIR}/.git" ]; then
  _EPHEMERAL_REPO="$(mktemp -d)"
  trap 'rm -rf "$_EPHEMERAL_REPO"' EXIT
  git clone --depth 50 https://github.com/ChaminnPM/enviroment-dotfiles.git "$_EPHEMERAL_REPO" >/dev/null 2>&1
  REPO_DIR="$_EPHEMERAL_REPO"
fi

# shellcheck source=lib/ui.sh
source "$REPO_DIR/scripts/lib/ui.sh"

# Rutas públicas relativas a config/opencode
PUBLIC_PATHS=(
  "AGENTS.md"
  "cli.json"
  "opencode.jsonc"
  "tui.jsonc"
  "package.json"
  "package-lock.json"
  "service.json.example"
  "agents/lua-qa.md"
  "agents/net-qa.md"
  "agents/react-qa.md"
  "agents/analyze-webrtc-dumps.md"
  "plugins/"
  "skills/generate-test-cases/"
  "skills/generate-tests/"
  "skills/graphify/"
  "skills/security-audit/"
  "memory/skills-best-practices.md"
)

sync_path() {
  local rel="$1" src="$2" dst="$3"
  [ -e "$src" ] || return 0
  mkdir -p "$(dirname "$dst")"
  if [ -d "$src" ]; then
    rsync -a --delete "$src" "$dst"
  else
    rsync -a "$src" "$dst"
  fi
}

ui_title "Sync público"

if ! { ssh -T git@github.com 2>&1 || true; } | grep -qi "successfully authenticated"; then
  ui_error "SSH GitHub falla. Ejecuta setup-git-identity.sh"
  exit 1
fi

case "$MODE" in
  pull)
    ( cd "$REPO_DIR" && git pull --rebase --autostash )
    for rel in "${PUBLIC_PATHS[@]}"; do
      sync_path "$rel" "$REPO_DIR/config/opencode/$rel" "$OPENCODE_DIR/$rel"
    done
    ( cd "$OPENCODE_DIR" && npm install ) || ui_warn "npm install fallo; revisa node_modules manualmente"
    ui_ok "sincronizado (pull público)"
    ;;
  push)
    for rel in "${PUBLIC_PATHS[@]}"; do
      [ -e "$OPENCODE_DIR/$rel" ] || continue
      sync_path "$rel" "$OPENCODE_DIR/$rel" "$REPO_DIR/config/opencode/$rel"
    done
    rm -f "$REPO_DIR/config/opencode/service.json"
    rm -rf "$REPO_DIR/config/opencode/node_modules"
    ( cd "$REPO_DIR" && git add -A && git commit -m "sync: $(date -Iseconds)" || ui_warn "nada que commitear" )
    ( cd "$REPO_DIR" && git push )
    ui_ok "sincronizado (push público)"
    ;;
  *)
    ui_error "Uso: $0 {push|pull}"
    exit 1
    ;;
esac
