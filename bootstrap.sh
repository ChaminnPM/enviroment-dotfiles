#!/usr/bin/env bash
set -euo pipefail

OPENCODE_DIR="${OPENCODE_DIR:-$HOME/.config/opencode}"
REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$0")" && pwd)}"
LOG_DIR="${LOG_DIR:-$HOME/.local/state/enviroment-dotfiles/logs}"

# shellcheck source=scripts/lib/ui.sh
source "$REPO_DIR/scripts/lib/ui.sh"
export UI_APP_TITLE="AGENTS ENVIRONMENT"
export REPO_DIR OPENCODE_DIR LOG_DIR
ensure_log_dir

VERBOSE="${VERBOSE:-0}"
SKIP_GIT_IDENTITY="${SKIP_GIT_IDENTITY:-0}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verbose) VERBOSE=1; export VERBOSE ;;
    --skip-git) SKIP_GIT_IDENTITY=1 ;;
    *) ui_warn "Argumento desconocido: $1" ;;
  esac
  shift
done

ui_install_ui || true
export PATH="$HOME/.local/bin:$PATH"

APT_PREFIX="$(ui_apt_prefix)"
export APT_PREFIX

# --- dependencias base: calcular paquetes faltantes ----------------------
APT_PKGS=()
command -v git >/dev/null 2>&1 || APT_PKGS+=(git)
command -v curl >/dev/null 2>&1 || APT_PKGS+=(curl)
command -v python3 >/dev/null 2>&1 || APT_PKGS+=(python3)
command -v tar >/dev/null 2>&1 || APT_PKGS+=(tar)
command -v gzip >/dev/null 2>&1 || APT_PKGS+=(gzip)
command -v rsync >/dev/null 2>&1 || APT_PKGS+=(rsync)
command -v numfmt >/dev/null 2>&1 || APT_PKGS+=(coreutils)
command -v xdg-open >/dev/null 2>&1 || APT_PKGS+=(xdg-utils)
command -v ssh-keygen >/dev/null 2>&1 || APT_PKGS+=(openssh-client)
# bash no puede exportar arrays: convertir a escalar antes de exportar.
APT_PKGS_STR="${APT_PKGS[*]}"
unset APT_PKGS
APT_PKGS="$APT_PKGS_STR"
export APT_PKGS

# --- plan de pasos -------------------------------------------------------
ui_panel_begin
ui_panel_note "Comandos: sync-dotfiles pull/push"
ui_panel_note "Ejecuta: exec \$SHELL"

ui_panel_step "Credenciales sudo" --optional --interactive --estimate 15 <<'EOF'
if [ -z "${APT_PREFIX:-}" ]; then
  echo "##log Sin sudo; apt se ejecutara como usuario actual"
  exit 0
fi
if [ -z "${APT_PKGS:-}" ]; then
  echo "##log No hay paquetes pendientes"
  exit 0
fi
if sudo -n true 2>/dev/null; then
  echo "##log Credenciales sudo OK"
  exit 0
fi
echo "##log Se solicitara la contrasena de sudo (solo para apt)"
if sudo -v; then
  echo "##log Credenciales sudo guardadas"
else
  echo "##warn No se pudieron guardar las credenciales sudo"
  exit 1
fi
EOF

ui_panel_step "Dependencias base" --estimate 45 <<'EOF'
apt_run() {
  local log rc
  log="$(mktemp)"
  if [ -n "${APT_PREFIX:-}" ]; then
    ${APT_PREFIX}apt-get "$@" >"$log" 2>&1
  else
    apt-get "$@" >"$log" 2>&1
  fi
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "##log Salida de apt (ultimas lineas):"
    tail -n 5 "$log" 2>/dev/null | while IFS= read -r l; do echo "##log $l"; done
  fi
  rm -f "$log"
  return "$rc"
}

if [ -n "${APT_PKGS:-}" ]; then
  if command -v apt-get >/dev/null 2>&1; then
    echo "##log Actualizando indices"
    apt_run update || true
    echo "##log Instalando: ${APT_PKGS}"
    if ! apt_run install -y ${APT_PKGS}; then
      echo "##warn No se pudieron instalar: ${APT_PKGS}"
    fi
  else
    echo "##warn apt-get no disponible; instala: ${APT_PKGS}"
  fi
else
  echo "##log Todas las dependencias base ya estaban instaladas"
fi
if ! command -v git >/dev/null 2>&1; then
  echo "##log git no esta disponible; instala: ${APT_PREFIX}apt-get install -y git"
  exit 1
fi
echo "Dependencias base listas"
EOF

if [ "$SKIP_GIT_IDENTITY" != "1" ]; then
  ui_panel_inputs <<'INPUTS'
input p_name Nombre personal (GitHub):
input p_email Email personal (GitHub):
confirm nuxiba Configurar cuenta NUXIBA (Bitbucket)? n
input n_name Nombre Nuxiba (Bitbucket):
input n_email Email Nuxiba (Bitbucket):
INPUTS
  ui_panel_step "Identidad Git (SSH)" --optional --estimate 30 <<'EOF'
bash "$REPO_DIR/scripts/setup-git-identity.sh"
EOF
else
  ui_panel_note "Identidad Git omitida (--skip-git)"
fi

ui_panel_inputs <<'INPUTS'
select extras Paquetes custom (espacio para marcar, enter confirma) many
option extras lazyvim
option extras fzf
option extras ripgrep
option extras bat
option extras eza
option extras zoxide
option extras fd-find
option extras lazygit
INPUTS
ui_panel_step "Paquetes custom" --estimate 90 <<'EOF'
if [ -z "${NUI_STEP_RESULT:-}" ] || [ ! -f "$NUI_STEP_RESULT" ]; then
  echo "##log Sin selección (modo no interactivo); nada que instalar"
  exit 0
fi
. "$NUI_STEP_RESULT"

SELECTED="${extras:-}"
if [ -z "$SELECTED" ]; then
  echo "##log No se seleccionaron paquetes custom"
  exit 0
fi

CUSTOM_APT=()
for p in ${SELECTED}; do
  case "$p" in
    lazyvim) ;;
    fd-find) command -v fd >/dev/null 2>&1 || CUSTOM_APT+=(fd-find) ;;
    lazygit) command -v lazygit >/dev/null 2>&1 || CUSTOM_APT+=(lazygit) ;;
    *) command -v "$p" >/dev/null 2>&1 || CUSTOM_APT+=("$p") ;;
  esac
done

if [ ${#CUSTOM_APT[@]} -gt 0 ]; then
  if command -v apt-get >/dev/null 2>&1; then
    echo "##log Instalando: ${CUSTOM_APT[*]}"
    ${APT_PREFIX}apt-get install -y ${CUSTOM_APT[*]} >/dev/null 2>&1 \
      || echo "##warn No se instalaron todos los paquetes custom"
  else
    echo "##warn Instala manualmente: ${CUSTOM_APT[*]}"
  fi
fi

if printf '%s\n' ${SELECTED} | grep -qx 'lazyvim'; then
  if ! command -v nvim >/dev/null 2>&1; then
    echo "##log Instalando neovim"
    ${APT_PREFIX}apt-get install -y neovim >/dev/null 2>&1 \
      || echo "##warn No se pudo instalar neovim"
  fi
  if [ ! -d "$HOME/.config/nvim" ]; then
    echo "##log Clonando LazyVim starter"
    if git clone https://github.com/LazyVim/starter "$HOME/.config/nvim" >/dev/null 2>&1; then
      rm -rf "$HOME/.config/nvim/.git"
    else
      echo "##warn No se pudo instalar LazyVim automáticamente"
    fi
  fi
fi

echo "Paquetes custom atendidos"
EOF

ui_panel_step "Node + nvm" --estimate 120 <<'EOF'
export NVM_DIR="$HOME/.nvm"
if ! command -v node >/dev/null 2>&1; then
  if [ ! -s "$NVM_DIR/nvm.sh" ]; then
    echo "##log Instalando nvm"
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash >/dev/null 2>&1 \
      || echo "##warn No se pudo instalar nvm automáticamente"
  fi
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" >/dev/null 2>&1 || true
  if ! command -v node >/dev/null 2>&1; then
    echo "##log Instalando Node LTS"
    nvm install --lts >/dev/null 2>&1 || { echo "##log Falló la instalación de Node"; exit 1; }
  fi
fi
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" >/dev/null 2>&1 || true
echo "Node $(node --version 2>/dev/null || echo '?')"
EOF

ui_panel_step "OpenCode" --estimate 90 <<'EOF'
if ! command -v opencode >/dev/null 2>&1; then
  tmp_oc="$(mktemp)"
  trap 'rm -f "$tmp_oc"' EXIT
  echo "##log Descargando instalador"
  curl -fsSL https://opencode.ai/v2/install -o "$tmp_oc"
  bash "$tmp_oc" --no-modify-path </dev/null >/dev/null 2>&1 \
    || { echo "##log El instalador de OpenCode falló"; exit 1; }
fi
for p in "$HOME/.opencode/bin" "$HOME/.local/bin" "$HOME/bin"; do
  [ -d "$p" ] && PATH="$p:$PATH"
done
export PATH
echo "OpenCode $(opencode --version 2>/dev/null || echo '?')"
EOF

ui_panel_step "Restaurar configuración" --estimate 60 <<'EOF'
mkdir -p "$OPENCODE_DIR"
if command -v rsync >/dev/null 2>&1; then
  rsync -a "$REPO_DIR/config/opencode/" "$OPENCODE_DIR/" \
    || echo "##warn No se pudieron copiar todos los assets públicos"
else
  cp -r "$REPO_DIR/config/opencode/." "$OPENCODE_DIR/" \
    || echo "##warn No se pudieron copiar todos los assets públicos"
fi
if [ -f "$OPENCODE_DIR/package.json" ] && command -v npm >/dev/null 2>&1; then
  echo "##log Instalando dependencias npm"
  if ! (cd "$OPENCODE_DIR" && npm install >/dev/null 2>&1); then
    echo "##warn npm install falló; revisa node_modules manualmente"
  fi
fi
echo "Configuración restaurada"
EOF

ui_panel_step "graphify" --estimate 15 <<'EOF'
mkdir -p "$OPENCODE_DIR/skills"
if [ -d "$REPO_DIR/config/opencode/skills/graphify" ]; then
  if command -v rsync >/dev/null 2>&1; then
    rsync -a "$REPO_DIR/config/opencode/skills/graphify/" "$OPENCODE_DIR/skills/graphify/" || true
  else
    cp -r "$REPO_DIR/config/opencode/skills/graphify/." "$OPENCODE_DIR/skills/graphify/" || true
  fi
  echo "graphify instalado"
else
  echo "##log graphify no encontrado en el repo"
fi
EOF

ui_panel_step "oh-my-bash" --estimate 45 <<'EOF'
if [ ! -d "$HOME/.oh-my-bash" ]; then
  echo "##log Clonando oh-my-bash"
  git clone https://github.com/ohmybash/oh-my-bash.git "$HOME/.oh-my-bash" >/dev/null 2>&1 \
    || { echo "##log Falló el clonado de oh-my-bash"; exit 1; }
fi
if ! grep -q 'oh-my-bash/oh-my-bash.sh' "$HOME/.bashrc" 2>/dev/null; then
  {
    echo 'export OSH="$HOME/.oh-my-bash"'
    echo 'OSH_THEME="vscode"'
    echo 'source "$OSH/oh-my-bash.sh"'
  } >> "$HOME/.bashrc"
fi
if ! grep -q 'OSH_THEME="vscode"' "$HOME/.bashrc" 2>/dev/null; then
  sed -i 's/^OSH_THEME=.*/OSH_THEME="vscode"/' "$HOME/.bashrc" 2>/dev/null || true
fi
echo "oh-my-bash listo"
EOF

ui_panel_step "herdr" --estimate 45 <<'EOF'
if ! command -v herdr >/dev/null 2>&1; then
  echo "##log Instalando herdr"
  curl -fsSL https://herdr.dev/install.sh | sh >/dev/null 2>&1 \
    || echo "##warn herdr no se instaló automáticamente"
fi
for p in "$HOME/.herdr/bin" "$HOME/.local/bin" "$HOME/.opencode/bin"; do
  [ -d "$p" ] && PATH="$p:$PATH"
done
export PATH
if ! grep -q 'export PATH=.*\.local/bin' "$HOME/.bashrc" 2>/dev/null; then
  echo 'export PATH="$HOME/.local/bin:$HOME/.herdr/bin:$HOME/.opencode/bin:$PATH"' >> "$HOME/.bashrc"
fi
echo "herdr atendido"
EOF

ui_panel_step "Wrappers" --estimate 10 <<'EOF'
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/sync-dotfiles" <<'WRAP'
#!/usr/bin/env bash
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
if ! command -v git >/dev/null 2>&1; then
  echo "git no está instalado. Ejecuta bootstrap.sh o instala git." >&2
  exit 1
fi
exec bash <(curl -fsSL https://raw.githubusercontent.com/ChaminnPM/enviroment-dotfiles/main/scripts/sync.sh) "$@"
WRAP
chmod +x "$HOME/.local/bin/sync-dotfiles"
echo "sync-dotfiles instalado"
EOF

ui_panel_step "Persistencia de entorno" --estimate 10 <<'EOF'
if [ -f "$HOME/.bash_profile" ]; then
  grep -q 'source ~/.bashrc' "$HOME/.bash_profile" 2>/dev/null \
    || echo 'source ~/.bashrc' >> "$HOME/.bash_profile"
else
  echo 'source ~/.bashrc' > "$HOME/.bash_profile"
fi
echo "Entorno persistente"
EOF

rc=0
ui_panel_run || rc=$?
exit "$rc"
