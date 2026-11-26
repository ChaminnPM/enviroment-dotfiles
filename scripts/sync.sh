#!/usr/bin/env bash
# sync.sh - sincroniza solo los assets PUBLICOS entre repo y ~/.config/opencode.
# Los assets privados (Nuxiba) se gestionan con sync-private.sh del repo privado.
#
# Uso: sync.sh [pull|push|doctor] [--dry-run] [--delete] [--verbose] [--help]
#
#   pull     baja el repo (HTTPS, sin SSH) y aplica los assets publicos
#   push     sube los assets publicos al repo (requiere SSH de GitHub)
#   doctor   verifica el entorno sin modificar nada
#
# --delete  permite que rsync borre archivos extra en el destino (opt-in).
# Solo Linux y WSL. Ver docs/PLATFORMS.md.
set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"
OPENCODE_DIR="${OPENCODE_DIR:-$HOME/.config/opencode}"
LOG_DIR="${LOG_DIR:-$HOME/.local/state/enviroment-dotfiles/logs}"
MODE="pull"
VERBOSE="${VERBOSE:-0}"
SYNC_DELETE="${SYNC_DELETE:-0}"
NUI_DRY_RUN="${NUI_DRY_RUN:-0}"
REPO_URL="${REPO_URL:-https://github.com/ChaminnPM/enviroment-dotfiles.git}"

for arg in "$@"; do
  case "$arg" in
    pull|push|doctor) MODE="$arg" ;;
    --dry-run) NUI_DRY_RUN=1 ;;
    --delete) SYNC_DELETE=1 ;;
    --verbose|verbose|v) VERBOSE=1 ;;
    -h|--help)
      sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) printf '[WARN] Argumento desconocido: %s\n' "$arg" >&2 ;;
  esac
done
export VERBOSE NUI_DRY_RUN

# Verificar git antes de clonar/sincronizar
if ! command -v git >/dev/null 2>&1; then
  printf '\033[0;31m[ERROR]\033[0m git no está instalado. Ejecuta bootstrap.sh o instala git.\n' >&2
  exit 1
fi

# Si no hay repo local valido, clonar en temporal y limpiar al salir.
_EPHEMERAL=0
if [ -z "${REPO_DIR:-}" ] || [ ! -d "${REPO_DIR}/.git" ]; then
  _EPHEMERAL_REPO="$(mktemp -d)"
  trap 'rm -rf "$_EPHEMERAL_REPO"' EXIT
  if ! git clone --depth 50 "$REPO_URL" "$_EPHEMERAL_REPO" >/dev/null 2>&1; then
    printf '\033[0;31m[ERROR]\033[0m No se pudo clonar %s\n' "$REPO_URL" >&2
    exit 1
  fi
  REPO_DIR="$_EPHEMERAL_REPO"
  _EPHEMERAL=1
fi

# shellcheck source=lib/ui.sh
source "$REPO_DIR/scripts/lib/ui.sh"
# El repo remoto puede ser una version anterior sin la capa de tema.
if [ -f "$REPO_DIR/scripts/lib/theme.sh" ]; then
  # shellcheck source=lib/theme.sh
  source "$REPO_DIR/scripts/lib/theme.sh"
  theme_load_env || true
fi
ensure_log_dir

THEME_SRC="$REPO_DIR/config/theme"
THEME_DST="$HOME/.config/enviroment-dotfiles/theme"

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

_rsync_flags() {
  if [ "$SYNC_DELETE" = "1" ]; then printf '%s' '-a --delete'; else printf '%s' '-a'; fi
}

sync_path() {
  local rel="$1" src="$2" dst="$3" flags
  [ -e "$src" ] || return 0
  flags="$(_rsync_flags)"
  if [ "$NUI_DRY_RUN" = "1" ]; then
    printf '[dry-run] rsync %s %s -> %s\n' "$flags" "$src" "$dst"
    return 0
  fi
  mkdir -p "$(dirname "$dst")"
  # Con `rsync -a src dst`, si dst ya EXISTE el resultado es dst/src_basename
  # (doble theme/theme tras el segundo pull). Para directorios se fuerza la
  # barra final: "copia el contenido de src en dst".
  if [ -d "$src" ]; then
    src="${src%/}/"
    dst="${dst%/}/"
  fi
  # shellcheck disable=SC2086  # flags se expande a proposito
  rsync $flags "$src" "$dst" >/dev/null 2>&1
}

_file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || printf '?'
}

# --- doctor: verificacion de salud del entorno publico --------------------
if [ "$MODE" = "doctor" ]; then
  OK=0; WARN=0
  d_ok()   { printf '\033[0;32m[OK]\033[0m   %s\n' "$1"; OK=$((OK+1)); }
  d_warn() { printf '\033[0;33m[WARN]\033[0m %s\n' "$1"; WARN=$((WARN+1)); }

  nvm_pin="${NVM_VERSION:-v0.40.8}"; nvm_pin="${nvm_pin#v}"
  printf '%s\n' "Doctor publico (pin nvm $nvm_pin, nui $(cat "$REPO_DIR/bin/VERSION" 2>/dev/null || echo '?')):"

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
    if [ "$nv" = "$nvm_pin" ]; then
      d_ok "nvm $nv (pin)"
    else
      d_warn "nvm ${nv:-incompleto} (pin $nvm_pin); relanza bootstrap.sh para actualizarlo"
    fi
    if command -v node >/dev/null 2>&1; then d_ok "node $(node --version)"; else d_warn "node no disponible (nvm install --lts)"; fi
    if command -v npm >/dev/null 2>&1; then d_ok "npm $(npm --version)"; else d_warn "npm no disponible"; fi
  else
    d_warn "nvm no instalado (~/.nvm/nvm.sh no existe)"
  fi

  # herramientas instaladas por bootstrap
  command -v opencode >/dev/null 2>&1 && d_ok "opencode $(opencode --version 2>/dev/null || echo '?')" || d_warn "opencode no instalado"
  command -v herdr >/dev/null 2>&1 && d_ok "herdr instalado" || d_warn "herdr no instalado"
  if [ -f "$HOME/.config/enviroment-dotfiles/env.sh" ]; then
    d_ok "PATH persistente presente (env.sh)"
  else
    d_warn "sin ~/.config/enviroment-dotfiles/env.sh (relanza bootstrap.sh)"
  fi
  grep -q 'oh-my-bash/oh-my-bash.sh' "$HOME/.bashrc" 2>/dev/null && d_ok "oh-my-bash activo en .bashrc" || d_warn "oh-my-bash no esta en .bashrc"
  if grep -q '# >>> dotfiles-oh-my-bash' "$HOME/.bashrc" 2>/dev/null; then
    d_ok ".bashrc usa bloque gestionado (idempotente)"
  else
    d_warn ".bashrc sin bloque gestionado de oh-my-bash"
  fi

  # Bloques de arranque con CONTENIDO: un bloque vacio (solo # >>> / # <<<)
  # pasaba el grep de marcador y daba falso positivo en maquina limpia.
  startup_block_has() { # <archivo> <header> <footer> <texto-requerido>
    local file="$1" h="$2" f="$3" need="$4" body
    [ -f "$file" ] || return 1
    body="$(awk -v b="$h" -v e="$f" \
      '$0==b{on=1;next} $0==e{on=0;next} on{print}' "$file" 2>/dev/null)"
    [ -n "$body" ] || return 1
    printf '%s\n' "$body" | grep -qF -- "$need"
  }
  if startup_block_has "$HOME/.bashrc" '# >>> dotfiles-env (no editar)' \
      '# <<< dotfiles-env' 'env.sh'; then
    d_ok ".bashrc carga env.sh"
  else
    d_warn ".bashrc sin bloque dotfiles-env efectivo (relanza 'Persistencia de entorno')"
  fi
  if startup_block_has "$HOME/.bash_profile" '# >>> dotfiles-shell (no editar)' \
      '# <<< dotfiles-shell' '.bashrc'; then
    d_ok ".bash_profile carga .bashrc (login shell)"
  else
    d_warn ".bash_profile no carga .bashrc (relanza 'Persistencia de entorno')"
  fi
  if startup_block_has "$HOME/.profile" '# >>> dotfiles-profile (no editar)' \
      '# <<< dotfiles-profile' 'env.sh'; then
    d_ok ".profile carga el entorno"
  else
    d_warn ".profile sin bloque dotfiles-profile efectivo"
  fi

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

  # tema canónico y fuente Nerd
  if command -v fc-match >/dev/null 2>&1; then
    if fc-match "${THEME_FONT_FAMILY:-JetBrainsMono Nerd Font}" 2>/dev/null \
        | grep -Fqi "${THEME_FONT_FAMILY:-JetBrainsMono Nerd Font}"; then
      d_ok "fuente ${THEME_FONT_FAMILY:-?} instalada"
    else
      d_warn "fuente ${THEME_FONT_FAMILY:-?} NO instalada (relanza bootstrap.sh)"
    fi
  else
    d_warn "fontconfig no disponible; no se puede verificar la fuente"
  fi
  manifest="$HOME/.config/enviroment-dotfiles/theme.json"
  if [ -f "$manifest" ]; then
    installed="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("nerd_version",""))' "$manifest" 2>/dev/null || true)"
    if [ "$installed" = "${THEME_NERD_VERSION:-}" ]; then
      d_ok "tema ${THEME_NAME:-?} / Nerd Font $installed (pin)"
    else
      d_warn "tema ${installed:-?} (pin ${THEME_NERD_VERSION:-?}); relanza bootstrap.sh"
    fi
  else
    d_warn "sin ~/.config/enviroment-dotfiles/theme.json (relanza bootstrap.sh)"
  fi

  # claves SSH y cuentas git (manifiesto generado por setup-git-identity.sh)
  [ -f "$HOME/.ssh/id_ed25519_personal" ] && d_ok "clave SSH personal presente" || d_warn "sin ~/.ssh/id_ed25519_personal"
  if [ -f "$HOME/.ssh/id_ed25519_personal" ]; then
    m="$(_file_mode "$HOME/.ssh/id_ed25519_personal")"
    [ "$m" = "600" ] && d_ok "clave personal 0600" || d_warn "clave personal con permisos $m (deberia ser 600)"
  fi
  if [ -f "$HOME/.ssh/config" ]; then
    m="$(_file_mode "$HOME/.ssh/config")"
    [ "$m" = "600" ] && d_ok "$HOME/.ssh/config 0600" || d_warn "$HOME/.ssh/config con permisos $m (deberia ser 600)"
    grep -q '# >>> dotfiles-managed' "$HOME/.ssh/config" 2>/dev/null \
      && d_ok "seccion SSH gestionada presente" || d_warn "$HOME/.ssh/config sin seccion gestionada"
  fi
  if [ -f "$HOME/claves-ssh.txt" ]; then
    m="$(_file_mode "$HOME/claves-ssh.txt")"
    [ "$m" = "600" ] && d_ok "claves-ssh.txt 0600" || d_warn "claves-ssh.txt con permisos $m (contiene solo claves publicas, pero deberia ser 600)"
  fi
  if [ -f "$HOME/.gitconfig" ]; then
    grep -q '# >>> dotfiles-gitconfig' "$HOME/.gitconfig" 2>/dev/null \
      && d_ok "$HOME/.gitconfig usa bloque gestionado" || d_warn "$HOME/.gitconfig sin bloque gestionado (config del usuario intacta)"
  fi
  if [ -f "$HOME/.config/git-accounts.sh" ]; then
    # shellcheck disable=SC1090
    . "$HOME/.config/git-accounts.sh"
    d_ok "manifiesto de cuentas git (personal: $PERSONAL_PLATFORM)"
    for slug in ${GIT_ACCOUNT_SLUGS:-}; do
      u="$(printf '%s' "$slug" | tr 'a-z-' 'A-Z_')"
      # Expansion indirecta de bash (sin eval): el nombre se construye, nunca
      # se ejecuta como codigo. printf -v evita interpolaciones en strings.
      esp_var="ACC_${u}_ESPACIO"
      folder_var="ACC_${u}_FOLDER"
      printf -v esp '%s' "${!esp_var:-}"
      printf -v folder '%s' "${!folder_var:-}"
      if [ -f "$HOME/.ssh/id_ed25519_$slug" ]; then
        d_ok "clave $esp presente"
        m="$(_file_mode "$HOME/.ssh/id_ed25519_$slug")"
        [ "$m" = "600" ] && d_ok "clave $esp 0600" || d_warn "clave $esp con permisos $m (deberia ser 600)"
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
if [ "$NUI_DRY_RUN" = "1" ]; then
  ui_warn "Modo dry-run: no se modifica nada"
fi

case "$MODE" in
  pull)
    # pull usa HTTPS: no requiere llaves SSH configuradas.
    if [ "$_EPHEMERAL" = "0" ]; then
      if [ "$NUI_DRY_RUN" = "1" ]; then
        ui_dim "[dry-run] git pull --rebase --autostash en $REPO_DIR"
      else
        # argv como array: sin eval, sin interpolar rutas en un string de shell.
        ui_logged_argv "Actualizando repo publico..." \
          git -C "$REPO_DIR" pull --rebase --autostash \
          || ui_warn "git pull fallo; revisa estado local o conflictos"
      fi
    fi
    for rel in "${PUBLIC_PATHS[@]}"; do
      sync_path "$rel" "$REPO_DIR/config/opencode/$rel" "$OPENCODE_DIR/$rel" || ui_warn "No se pudo sincronizar: $rel"
    done
    sync_path "config/theme" "$THEME_SRC" "$THEME_DST" || ui_warn "No se pudo sincronizar: config/theme"
    if command -v npm >/dev/null 2>&1; then
      if [ "$NUI_DRY_RUN" = "1" ]; then
        ui_dim "[dry-run] npm install en $OPENCODE_DIR"
      else
        ui_logged_argv "npm install" \
          npm --prefix "$OPENCODE_DIR" install \
          || ui_warn "npm install fallo; revisa node_modules manualmente"
      fi
    else
      ui_warn "npm no disponible; se omite la instalacion de dependencias"
    fi
    ui_summary "Sincronizado (pull publico)" "Assets publicos aplicados"
    ;;
  push)
    if ! ui_ssh_test "Validando GitHub SSH..." git@github.com; then
      ui_fatal "SSH GitHub falla. Ejecuta setup-git-identity.sh"
    fi
    for rel in "${PUBLIC_PATHS[@]}"; do
      [ -e "$OPENCODE_DIR/$rel" ] || continue
      sync_path "$rel" "$OPENCODE_DIR/$rel" "$REPO_DIR/config/opencode/$rel" || ui_warn "No se pudo preparar: $rel"
    done
    sync_path "config/theme" "$THEME_DST" "$THEME_SRC" || ui_warn "No se pudo preparar: config/theme"
    rm -f "$REPO_DIR/config/opencode/service.json"
    rm -rf "$REPO_DIR/config/opencode/node_modules"
    if [ "$NUI_DRY_RUN" = "1" ]; then
      ui_dim "[dry-run] git add (solo rutas publicas) + commit + push"
      ui_summary "Dry-run (push publico)" "Nada se subio"
      exit 0
    fi
    # git add acotado: nunca se commitea lo que el usuario tenga a medias fuera
    # de las rutas publicas.
    add_paths=()
    for rel in "${PUBLIC_PATHS[@]}"; do
      add_paths+=("config/opencode/${rel%/}")
    done
    add_paths+=("config/theme")
    stamp="$(date +%Y-%m-%dT%H:%M:%S%z)"
    # argv como array: las rutas y la fecha viajan como datos, nunca como
    # fragmentos de un string que el shell tenga que evaluar.
    git -C "$REPO_DIR" add -- "${add_paths[@]}" 2>/dev/null || true
    if git -C "$REPO_DIR" diff --cached --quiet; then
      ui_dim "Nada que commitear"
    else
      ui_logged_argv "Commit publico..." \
        git -C "$REPO_DIR" commit -m "sync: $stamp" \
        || ui_dim "Nada que commitear"
    fi
    ui_logged_argv "Push publico..." \
      git -C "$REPO_DIR" push \
      || ui_fatal "No se pudo subir al repo publico"
    ui_summary "Sincronizado (push publico)" "Repo publico actualizado"
    ;;
  *)
    ui_error "Uso: $0 {push|pull|doctor} [--dry-run] [--delete]"
    exit 1
    ;;
esac
