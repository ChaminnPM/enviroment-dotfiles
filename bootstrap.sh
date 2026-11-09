#!/usr/bin/env bash
set -euo pipefail

OPENCODE_DIR="${OPENCODE_DIR:-$HOME/.config/opencode}"
REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$0")" && pwd)}"
LOG_DIR="${LOG_DIR:-$HOME/.local/state/enviroment-dotfiles/logs}"

# shellcheck source=scripts/lib/ui.sh
source "$REPO_DIR/scripts/lib/ui.sh"
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

APT_PREFIX="$(ui_apt_prefix)"

ui_install_gum || true
export PATH="$HOME/.local/bin:$PATH"

# Paso 0: preflight / gum
ui_step_start "Paso 0" "Preparando instalador"
if ui_gum_available; then
  ui_ok "gum disponible"
else
  ui_warn "gum no disponible; usando modo texto"
fi
ui_step_done "Instalador listo"

# 1. Dependencias base (git antes de los pasos que lo requieren)
ui_step_start "Paso 1" "Dependencias base"
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

if [ ${#APT_PKGS[@]} -gt 0 ]; then
  if command -v apt-get >/dev/null 2>&1; then
    ui_logged "apt-get update" "${APT_PREFIX}apt-get update >/dev/null 2>&1 || true"
    ui_logged "Instalando ${APT_PKGS[*]}" "${APT_PREFIX}apt-get install -y ${APT_PKGS[*]} >/dev/null 2>&1" || ui_warn "No se pudieron instalar todos los paquetes"
  else
    ui_warn "Gestor apt-get no disponible. Instala manualmente: ${APT_PKGS[*]}"
  fi
fi

if ! command -v git >/dev/null 2>&1; then
  ui_error "Se requiere git para continuar."
  exit 1
fi
ui_step_done "Dependencias base listas"

# 2. Identidad Git
ui_step_start "Paso 2" "Identidad Git (SSH)"
if [ "$SKIP_GIT_IDENTITY" != "1" ]; then
  if [ -e /dev/tty ]; then
    bash "$REPO_DIR/scripts/setup-git-identity.sh" < /dev/tty || ui_warn "No se pudo completar la identidad Git automáticamente"
  else
    bash "$REPO_DIR/scripts/setup-git-identity.sh" < /dev/null || ui_warn "Sin TTY: usa GIT_PERSONAL_NAME/GIT_PERSONAL_EMAIL para configurar Git"
  fi
else
  ui_warn "Configuracion de identidad Git omitida (SKIP_GIT_IDENTITY=1)"
fi
ui_step_done "Identidad Git atendida"

# 3. Paquetes custom
ui_step_start "Paso 3" "Paquetes custom (opcional)"
EXTRA_PKGS=(lazyvim fzf ripgrep bat eza zoxide fd-find lazygit)
CHOSEN_EXTRAS=()
mapfile -t CHOSEN_EXTRAS < <(ui_choose "Selecciona paquetes custom (tab/space, Enter confirma)" "${EXTRA_PKGS[@]}" || true)

CUSTOM_APT=()
for p in ${CHOSEN_EXTRAS[@]+"${CHOSEN_EXTRAS[@]}"}; do
  case "$p" in
    lazyvim) ;;
    fd-find) command -v fd >/dev/null 2>&1 || CUSTOM_APT+=(fd-find);;
    lazygit) command -v lazygit >/dev/null 2>&1 || CUSTOM_APT+=(lazygit);;
    *) command -v "$p" >/dev/null 2>&1 || CUSTOM_APT+=("$p");;
  esac
done

if [ ${#CUSTOM_APT[@]} -gt 0 ]; then
  if command -v apt-get >/dev/null 2>&1; then
    ui_logged "Instalando custom: ${CUSTOM_APT[*]}" "${APT_PREFIX}apt-get install -y ${CUSTOM_APT[*]} >/dev/null 2>&1" || ui_warn "No se instalaron todos los custom"
  else
    ui_warn "Instala manualmente: ${CUSTOM_APT[*]}"
  fi
fi
ui_step_done "Custom seleccionado/atendido"

# 4. Node / nvm
ui_step_start "Paso 4" "Node + nvm"
if ! command -v node >/dev/null 2>&1; then
  ui_logged "Instalando nvm..." "curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash >/dev/null 2>&1" || ui_warn "No se pudo instalar nvm automáticamente"
fi
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" >/dev/null 2>&1 || true
if ! command -v node >/dev/null 2>&1; then
  ui_logged "Instalando Node LTS..." "export NVM_DIR='$HOME/.nvm'; . '$NVM_DIR/nvm.sh' >/dev/null 2>&1; nvm install --lts >/dev/null 2>&1" || { ui_error "Fallo instalando node"; exit 1; }
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" >/dev/null 2>&1 || true
fi
ui_step_done "Node listo ($(node --version 2>/dev/null || echo '?'))"

# 5. OpenCode
ui_step_start "Paso 5" "OpenCode"
if ! command -v opencode >/dev/null 2>&1; then
  tmp_oc="$(mktemp)"
  ui_logged "Instalando OpenCode..." "curl -fsSL https://opencode.ai/v2/install -o '$tmp_oc' && bash '$tmp_oc' --no-modify-path </dev/null >/dev/null 2>&1; rm -f '$tmp_oc'" || { ui_error "The OpenCode installer failed"; exit 1; }
else
  ui_dim "OpenCode ya estaba instalado"
fi
for p in "$HOME/.opencode/bin" "$HOME/.local/bin" "$HOME/bin"; do
  [ -d "$p" ] && export PATH="$p:$PATH"
done
ui_step_done "OpenCode: $(opencode --version 2>/dev/null || echo '?')"

# 6. Config
ui_step_start "Paso 6" "Restaurar configuración"
mkdir -p "$OPENCODE_DIR"
if command -v rsync >/dev/null 2>&1; then
  rsync -a "$REPO_DIR/config/opencode/" "$OPENCODE_DIR/" >/dev/null 2>&1 || ui_warn "No se pudieron copiar todos los assets publicos"
else
  cp -r "$REPO_DIR/config/opencode/." "$OPENCODE_DIR/" >/dev/null 2>&1 || ui_warn "No se pudieron copiar todos los assets publicos"
fi
ui_logged "npm install" "cd '$OPENCODE_DIR' && npm install >/dev/null 2>&1" || ui_warn "npm install fallo; revisa node_modules manualmente"
ui_step_done "Config restaurada"

# 7. graphify
ui_step_start "Paso 7" "graphify"
mkdir -p "$OPENCODE_DIR/skills"
if [ -d "$REPO_DIR/config/opencode/skills/graphify" ]; then
  if command -v rsync >/dev/null 2>&1; then
    rsync -a "$REPO_DIR/config/opencode/skills/graphify/" "$OPENCODE_DIR/skills/graphify/" >/dev/null 2>&1 || true
  else
    cp -r "$REPO_DIR/config/opencode/skills/graphify/." "$OPENCODE_DIR/skills/graphify/" >/dev/null 2>&1 || true
  fi
  ui_step_done "graphify instalado"
else
  ui_step_done "graphify no encontrado en el repo"
fi

# 8. oh-my-bash
ui_step_start "Paso 8" "oh-my-bash"
if [ ! -d "$HOME/.oh-my-bash" ]; then
  ui_logged "Clonando oh-my-bash..." "git clone https://github.com/ohmybash/oh-my-bash.git '$HOME/.oh-my-bash' >/dev/null 2>&1" || { ui_error "Fallo clonando oh-my-bash"; exit 1; }
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
export OSH="$HOME/.oh-my-bash"
OSH_THEME="vscode"
[ -f "$OSH/oh-my-bash.sh" ] && . "$OSH/oh-my-bash.sh" >/dev/null 2>&1 || true
ui_step_done "oh-my-bash listo"

# 9. herdr
ui_step_start "Paso 9" "herdr"
if ! command -v herdr >/dev/null 2>&1; then
  ui_logged "Instalando herdr..." "curl -fsSL https://herdr.dev/install.sh | sh >/dev/null 2>&1" || ui_warn "herdr no se instalo automaticamente"
fi
for p in "$HOME/.herdr/bin" "$HOME/.local/bin" "$HOME/.opencode/bin"; do
  [ -d "$p" ] && export PATH="$p:$PATH"
done
if ! grep -q 'export PATH=.*\.local/bin' "$HOME/.bashrc" 2>/dev/null; then
  echo 'export PATH="$HOME/.local/bin:$HOME/.herdr/bin:$HOME/.opencode/bin:$PATH"' >> "$HOME/.bashrc"
fi
ui_step_done "herdr atendido"

# 10. LazyVim
if printf '%s\n' ${CHOSEN_EXTRAS[@]+"${CHOSEN_EXTRAS[@]}"} | grep -q '^lazyvim$'; then
  ui_step_start "Paso 10" "Neovim / LazyVim"
  command -v nvim >/dev/null 2>&1 || ui_logged "Instalando neovim..." "${APT_PREFIX}apt-get install -y neovim >/dev/null 2>&1"
  if [ ! -d "$HOME/.config/nvim" ]; then
    ui_logged "Clonando LazyVim starter..." "git clone https://github.com/LazyVim/starter '$HOME/.config/nvim' >/dev/null 2>&1 && rm -rf '$HOME/.config/nvim/.git'" || ui_warn "No se pudo instalar LazyVim automáticamente"
  fi
  ui_step_done "LazyVim atendido"
fi

# 11. Wrapper
ui_step_start "Paso 11" "Wrappers"
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/sync-dotfiles" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
if ! command -v git >/dev/null 2>&1; then
  echo "git no está instalado. Ejecuta bootstrap.sh o instala git." >&2
  exit 1
fi
exec bash <(curl -fsSL https://raw.githubusercontent.com/ChaminnPM/enviroment-dotfiles/main/scripts/sync.sh) "$@"
EOF
chmod +x "$HOME/.local/bin/sync-dotfiles"

# 12. Persistencia
ui_step_start "Paso 12" "Persistencia de entorno"
if [ -f "$HOME/.bash_profile" ]; then
  grep -q 'source ~/.bashrc' "$HOME/.bash_profile" 2>/dev/null || echo 'source ~/.bashrc' >> "$HOME/.bash_profile"
else
  echo 'source ~/.bashrc' > "$HOME/.bash_profile"
fi
[ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc" >/dev/null 2>&1 || true

ui_clear
ui_summary "Instalacion publica completada" "Comandos: sync-dotfiles pull/push" "Logs: $LOG_DIR" "Ejecuta: exec \$SHELL"
