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
    pull|push|doctor) MODE="$arg" ;;
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

# --- doctor: verificacion de salud del entorno publico --------------------
if [ "$MODE" = "doctor" ]; then
  OK=0; WARN=0
  d_ok()   { printf '\033[0;32m[OK]\033[0m   %s\n' "$1"; OK=$((OK+1)); }
  d_warn() { printf '\033[0;33m[WARN]\033[0m %s\n' "$1"; WARN=$((WARN+1)); }

  printf '%s\n' "Doctor publico (pin nvm 0.40.8, nui $(cat "$REPO_DIR/bin/VERSION" 2>/dev/null || echo '?')):"

  for c in git curl python3 rsync tar gzip; do
    if command -v "$c" >/dev/null 2>&1; then
      d_ok "$c instalado"
    else
      d_warn "$c NO instalado (relanza bootstrap.sh para instalarlo)"
    fi
  done

  # nvm / node / npm
  if [ -s "$HOME/.nvm/nvm.sh" ]; then
    . "$HOME/.nvm/nvm.sh" >/dev/null 2>&1 || true
    nv="$(nvm --version 2>/dev/null || true)"
    if [ "$nv" = "0.40.8" ]; then
      d_ok "nvm $nv (pin)"
    else
      d_warn "nvm ${nv:-incompleto} (pin 0.40.8); relanza bootstrap.sh para actualizarlo"
    fi
    if command -v node >/dev/null 2>&1; then d_ok "node $(node --version)"; else d_warn "node no disponible (nvm install --lts)"; fi
    if command -v npm >/dev/null 2>&1; then d_ok "npm $(npm --version)"; else d_warn "npm no disponible"; fi
  else
    d_warn "nvm no instalado (~/.nvm/nvm.sh no existe)"
  fi

  # herramientas instaladas por bootstrap
  command -v opencode >/dev/null 2>&1 && d_ok "opencode $(opencode --version 2>/dev/null || echo '?')" || d_warn "opencode no instalado"
  command -v herdr >/dev/null 2>&1 && d_ok "herdr instalado" || d_warn "herdr no instalado"
  grep -q 'oh-my-bash/oh-my-bash.sh' "$HOME/.bashrc" 2>/dev/null && d_ok "oh-my-bash activo en .bashrc" || d_warn "oh-my-bash no esta en .bashrc"

  # nui vs pin del repo
  pin="$(cat "$REPO_DIR/bin/VERSION" 2>/dev/null || true)"
  if command -v nui >/dev/null 2>&1 || [ -x "$HOME/.local/bin/nui" ]; then
    have="$(nui version 2>/dev/null | awk 'NR==1{print $2}')"
    if [ "$have" = "$pin" ]; then
      d_ok "nui $have (pin $pin)"
    else
      d_warn "nui ${have:-?} (pin $pin); se actualiza al proximo bootstrap.sh"
    fi
  else
    d_warn "nui no instalado (la UI usara fallback textual)"
  fi

  # skills externas: repo vs instalado
  for s in graphify security-audit; do
    read_ref() { python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('upstream_ref',''))" "$1" 2>/dev/null || true; }
    want="$(read_ref "$REPO_DIR/config/opencode/skills/$s/VERSION.json")"
    have="$(read_ref "$OPENCODE_DIR/skills/$s/VERSION.json")"
    if [ -z "$want" ]; then
      d_warn "skill $s sin VERSION.json en el repo"
    elif [ "$want" = "$have" ]; then
      d_ok "skill $s ($want)"
    else
      d_warn "skill $s instalada ${have:-?}, repo $want; sync-dotfiles pull la actualiza"
    fi
  done

  # claves SSH y cuentas git (manifiesto generado por setup-git-identity.sh)
  [ -f "$HOME/.ssh/id_ed25519_personal" ] && d_ok "clave SSH personal presente" || d_warn "sin ~/.ssh/id_ed25519_personal"
  if [ -f "$HOME/.config/git-accounts.sh" ]; then
    # shellcheck disable=SC1090
    . "$HOME/.config/git-accounts.sh"
    d_ok "manifiesto de cuentas git (personal: $PERSONAL_PLATFORM)"
    grep -q '# >>> dotfiles-managed' "$HOME/.ssh/config" 2>/dev/null \
      && d_ok "seccion SSH gestionada presente" || d_warn "~/.ssh/config sin seccion gestionada"
    for slug in ${GIT_ACCOUNT_SLUGS:-}; do
      u="$(printf '%s' "$slug" | tr 'a-z-' 'A-Z_')"
      eval "esp=\"\${ACC_${u}_ESPACIO:-}\""
      eval "folder=\"\${ACC_${u}_FOLDER:-}\""
      if [ -f "$HOME/.ssh/id_ed25519_$slug" ]; then
        d_ok "clave $esp presente"
      else
        d_warn "sin clave para el espacio $esp"
      fi
      if [ -d "$folder" ]; then
        d_ok "carpeta $folder presente"
      else
        d_warn "carpeta $folder no existe"
      fi
      if grep -q "gitdir:$folder/" "$HOME/.gitconfig" 2>/dev/null; then
        d_ok "includeIf de $esp activo"
      else
        d_warn "sin includeIf para $esp en ~/.gitconfig"
      fi
    done
  else
    d_warn "sin ~/.config/git-accounts.sh (relanza bootstrap.sh para configurar cuentas)"
  fi

  printf '%s\n' "Resumen: $OK OK, $WARN avisos"
  [ "$WARN" -eq 0 ] && exit 0 || exit 1
fi

ui_clear
ui_banner "Sync publico"

if ! ui_ssh_test "Validando GitHub SSH..." git@github.com; then
  ui_fatal "SSH GitHub falla. Ejecuta setup-git-identity.sh"
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
    ui_logged "Push publico..." "cd '$REPO_DIR' && git push >/dev/null 2>&1" || ui_fatal "No se pudo subir al repo publico"
    ui_summary "Sincronizado (push publico)" "Repo publico actualizado"
    ;;
  *)
    ui_error "Uso: $0 {push|pull|doctor}"
    exit 1
    ;;
esac
