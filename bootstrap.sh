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

APT_PREFIX=""
if [ "${EUID:-$(id -u)}" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
  APT_PREFIX="sudo "
fi

ensure_cmd() {
  local cmd="$1" pkg="${2:-$1}"
  command -v "$cmd" >/dev/null 2>&1 && return 0
  ui_logged "Instalando $pkg..." "${APT_PREFIX}apt-get update >/dev/null 2>&1 || true; ${APT_PREFIX}apt-get install -y $pkg >/dev/null 2>&1"
}

install_gum() {
  command -v gum >/dev/null 2>&1 && return 0
  ensure_cmd curl curl || return 1
  ensure_cmd tar tar || return 1
  ensure_cmd gzip gzip || return 1
  ensure_cmd python3 python3 || true

  local os arch tag url tmp
  os="$(uname -s)"
  arch="$(uname -m)"
  case "$os" in
    Linux) os="Linux" ;;
    Darwin) os="Darwin" ;;
    *) return 1 ;;
  esac
  case "$arch" in
    x86_64|amd64) arch="x86_64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) return 1 ;;
  esac

  local api
  api="$(curl -fsSL https://api.github.com/repos/charmbracelet/gum/releases/latest 2>/dev/null || true)"
  if command -v python3 >/dev/null 2>&1; then
    tag="$(printf '%s' "$api" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tag_name",""))' 2>/dev/null || true)"
  else
    tag="$(printf '%s' "$api" | grep -o '"tag_name": *"[^"]*"' | head -n1 | cut -d'"' -f4)"
  fi
  [ -n "$tag" ] || return 1

  url="https://github.com/charmbracelet/gum/releases/download/${tag}/gum_${tag#v}_${os}_${arch}.tar.gz"
  tmp="$(mktemp -d)"
  ui_logged "Instalando gum..." "curl -fsSL '$url' -o '$tmp/gum.tar.gz' && tar -xzf '$tmp/gum.tar.gz' -C '$tmp' && mkdir -p '$HOME/.local/bin' && install -m 0755 '$tmp/gum' '$HOME/.local/bin/gum'"
  rm -rf "$tmp"
  command -v gum >/dev/null 2>&1 || return 1
}

install_gum || true
export PATH="$HOME/.local/bin:$PATH"

ui_clear
ui_banner "NUXIBA ENVIRONMENT" "OpenCode Bootstrap"

# 1. Dependencias base (git antes de los pasos que lo requieren)
ui_section "Paso 1: Dependencias base"
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

# 2. Identidad Git
ui_section "Paso 2: Identidad Git (SSH)"
if [ "$SKIP_GIT_IDENTITY" != "1" ]; then
  ui_dim "Configurando identidad Git..."
  if [ -e /dev/tty ]; then
    bash "$REPO_DIR/scripts/setup-git-identity.sh" < /dev/tty || ui_warn "No se pudo completar la identidad Git automáticamente"
  else
    bash "$REPO_DIR/scripts/setup-git-identity.sh" < /dev/null || ui_warn "Sin TTY: usa GIT_PERSONAL_NAME/GIT_PERSONAL_EMAIL para configurar Git"
  fi
  ui_ok "Identidad Git atendida"
else
  ui_warn "Configuracion de identidad Git omitida (SKIP_GIT_IDENTITY=1)"
fi

# 3. Paquetes custom
ui_section "Paso 3: Paquetes custom (opcional)"
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

# 4. Node / nvm
ui_section "Paso 4: Node + nvm"
if ! command -v node >/dev/null 2>&1; then
  ui_logged "Instalando nvm..." "curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash >/dev/null 2>&1" || ui_warn "No se pudo instalar nvm automáticamente"
fi
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" >/dev/null 2>&1 || true
if ! command -v node >/dev/null 2>&1; then
  ui_logged "Instalando Node LTS..." "export NVM_DIR='$HOME/.nvm'; . '$NVM_DIR/nvm.sh' >/dev/null 2>&1; nvm install --lts >/dev/null 2>&1" || { ui_error "Fallo instalando node"; exit 1; }
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" >/dev/null 2>&1 || true
fi
ui_ok "Node listo ($(node --version 2>/dev/null || echo '?'))"

# 5. OpenCode
ui_section "Paso 5: OpenCode"
if ! command -v opencode >/dev/null 2>&1; then
  ui_logged "Instalando OpenCode..." "curl -fsSL https://opencode.ai/v2/install | bash >/dev/null 2>&1" || { ui_error "The OpenCode installer failed"; exit 1; }
fi
for p in "$HOME/.opencode/bin" "$HOME/.local/bin" "$HOME/bin"; do
  [ -d "$p" ] && export PATH="$p:$PATH"
done
if command -v opencode >/dev/null 2>&1; then
  ui_ok "OpenCode: $(opencode --version 2>/dev/null || echo ok)"
else
  ui_warn "opencode no esta en PATH de esta sesion. Ejecuta: exec \$SHELL"
fi

# 6. Config
ui_section "Paso 6: Restaurar configuracion"
mkdir -p "$OPENCODE_DIR"
if command -v rsync >/dev/null 2>&1; then
  rsync -a "$REPO_DIR/config/opencode/" "$OPENCODE_DIR/" >/dev/null 2>&1 || ui_warn "No se pudieron copiar todos los assets publicos"
else
  cp -r "$REPO_DIR/config/opencode/." "$OPENCODE_DIR/" >/dev/null 2>&1 || ui_warn "No se pudieron copiar todos los assets publicos"
fi
ui_logged "npm install" "cd '$OPENCODE_DIR' && npm install >/dev/null 2>&1" || ui_warn "npm install fallo; revisa node_modules manualmente"
ui_ok "Config restaurada"

# 7. graphify
ui_section "Paso 7: graphify"
mkdir -p "$OPENCODE_DIR/skills"
if [ -d "$REPO_DIR/config/opencode/skills/graphify" ]; then
  if command -v rsync >/dev/null 2>&1; then
    rsync -a "$REPO_DIR/config/opencode/skills/graphify/" "$OPENCODE_DIR/skills/graphify/" >/dev/null 2>&1 || true
  else
    cp -r "$REPO_DIR/config/opencode/skills/graphify/." "$OPENCODE_DIR/skills/graphify/" >/dev/null 2>&1 || true
  fi
  ui_ok "graphify instalado (ver VERSION.json para actualizaciones)"
else
  ui_warn "graphify no encontrado en el repo"
fi

# 8. oh-my-bash
ui_section "Paso 8: oh-my-bash"
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
ui_ok "oh-my-bash listo (tema vscode)"

# 9. herdr
ui_section "Paso 9: herdr"
if ! command -v herdr >/dev/null 2>&1; then
  ui_logged "Instalando herdr..." "curl -fsSL https://herdr.dev/install.sh | sh >/dev/null 2>&1" || ui_warn "herdr no se instalo automaticamente"
fi
for p in "$HOME/.herdr/bin" "$HOME/.local/bin" "$HOME/.opencode/bin"; do
  [ -d "$p" ] && export PATH="$p:$PATH"
done
if ! grep -q 'export PATH=.*\.local/bin' "$HOME/.bashrc" 2>/dev/null; then
  echo 'export PATH="$HOME/.local/bin:$HOME/.herdr/bin:$HOME/.opencode/bin:$PATH"' >> "$HOME/.bashrc"
fi
command -v herdr >/dev/null 2>&1 && ui_ok "herdr listo" || ui_warn "herdr no disponible"

# 10. LazyVim
if printf '%s\n' ${CHOSEN_EXTRAS[@]+"${CHOSEN_EXTRAS[@]}"} | grep -q '^lazyvim$'; then
  ui_section "Paso 10: Neovim / LazyVim"
  command -v nvim >/dev/null 2>&1 || ui_logged "Instalando neovim..." "${APT_PREFIX}apt-get install -y neovim >/dev/null 2>&1"
  if [ ! -d "$HOME/.config/nvim" ]; then
    ui_logged "Clonando LazyVim starter..." "git clone https://github.com/LazyVim/starter '$HOME/.config/nvim' >/dev/null 2>&1 && rm -rf '$HOME/.config/nvim/.git'" || ui_warn "No se pudo instalar LazyVim automáticamente"
  fi
  ui_ok "LazyVim listo"
fi

# 11. Wrapper
ui_section "Paso 11: Wrappers"
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
ui_ok "sync-dotfiles instalado"

# 12. Persistencia
ui_section "Paso 12: Persistencia de entorno"
if [ -f "$HOME/.bash_profile" ]; then
  grep -q 'source ~/.bashrc' "$HOME/.bash_profile" 2>/dev/null || echo 'source ~/.bashrc' >> "$HOME/.bash_profile"
else
  echo 'source ~/.bashrc' > "$HOME/.bash_profile"
fi

[ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc" >/dev/null 2>&1 || true

ui_summary "Instalacion publica completada" "Comandos: sync-dotfiles pull/push" "Logs: $LOG_DIR" "Si algo no esta en PATH: exec \$SHELL"
