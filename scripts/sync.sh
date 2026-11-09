#!/usr/bin/env bash
# sync.sh - sincroniza solo los assets PUBLICOS entre repo y ~/.config/opencode.
# Los assets privados (Nuxiba) se gestionan con sync-private.sh del repo privado.
set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"
OPENCODE_DIR="${OPENCODE_DIR:-$HOME/.config/opencode}"
LOG_DIR="${LOG_DIR:-$HOME/.local/state/enviroment-dotfiles/logs}"
MODE="pull"
VERBOSE="${VERBOSE:-0}"
for arg in "$@"; do
  case "$arg" in
    pull|push) MODE="$arg" ;;
    --verbose|verbose|v) VERBOSE=1 ;;
  esac
done
export VERBOSE

# Verificar git antes de clonar/sincronizar
if ! command -v git >/dev/null 2>&1; then
  printf '\033[0;31m[ERROR]\033[0m git no está instalado. Ejecuta bootstrap.sh o instala git.\n' >&2
  exit 1
fi

# Si no hay repo local valido, clonar en temporal y limpiar al salir.
if [ -z "${REPO_DIR:-}" ] || [ ! -d "${REPO_DIR}/.git" ]; then
  _EPHEMERAL_REPO="$(mktemp -d)"
  trap 'rm -rf "$_EPHEMERAL_REPO"' EXIT
  git clone --depth 50 https://github.com/ChaminnPM/enviroment-dotfiles.git "$_EPHEMERAL_REPO" >/dev/null 2>&1
  REPO_DIR="$_EPHEMERAL_REPO"
fi

# shellcheck source=lib/ui.sh
source "$REPO_DIR/scripts/lib/ui.sh"
ensure_log_dir

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
    rsync -a --delete "$src" "$dst" >/dev/null 2>&1
  else
    rsync -a "$src" "$dst" >/dev/null 2>&1
  fi
}

ui_clear
ui_banner "Sync publico"

if ! { ssh -T git@github.com 2>&1 || true; } | grep -qi "successfully authenticated"; then
  ui_error "SSH GitHub falla. Ejecuta setup-git-identity.sh"
  exit 1
fi

case "$MODE" in
  pull)
    ui_logged "Actualizando repo publico..." "cd '$REPO_DIR' && git pull --rebase --autostash >/dev/null 2>&1" || { ui_warn "git pull fallo; revisa estado local o conflictos"; }
    for rel in "${PUBLIC_PATHS[@]}"; do
      sync_path "$rel" "$REPO_DIR/config/opencode/$rel" "$OPENCODE_DIR/$rel" || ui_warn "No se pudo sincronizar: $rel"
    done
    ui_logged "npm install" "cd '$OPENCODE_DIR' && npm install >/dev/null 2>&1" || ui_warn "npm install fallo; revisa node_modules manualmente"
    ui_summary "Sincronizado (pull publico)" "Assets publicos aplicados"
    ;;
  push)
    for rel in "${PUBLIC_PATHS[@]}"; do
      [ -e "$OPENCODE_DIR/$rel" ] || continue
      sync_path "$rel" "$OPENCODE_DIR/$rel" "$REPO_DIR/config/opencode/$rel" || ui_warn "No se pudo preparar: $rel"
    done
    rm -f "$REPO_DIR/config/opencode/service.json"
    rm -rf "$REPO_DIR/config/opencode/node_modules"
    ui_logged "Commit publico..." "cd '$REPO_DIR' && git add -A && git commit -m 'sync: $(date -Iseconds)' >/dev/null 2>&1" || ui_dim "Nada que commitear"
    ui_logged "Push publico..." "cd '$REPO_DIR' && git push >/dev/null 2>&1" || { ui_error "No se pudo subir al repo publico"; exit 1; }
    ui_summary "Sincronizado (push publico)" "Repo publico actualizado"
    ;;
  *)
    ui_error "Uso: $0 {push|pull}"
    exit 1
    ;;
esac
