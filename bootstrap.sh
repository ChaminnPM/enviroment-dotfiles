#!/usr/bin/env bash
set -euo pipefail

OPENCODE_DIR="${OPENCODE_DIR:-$HOME/.config/opencode}"
REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$0")" && pwd)}"

# --- UI mínima antes de gum ------------------------------------------------
say()   { printf '\033[0;34m[INFO]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }

ensure_base_tools() {
  local need=()
  command -v git   >/dev/null 2>&1 || need+=(git)
  command -v curl  >/dev/null 2>&1 || need+=(curl)
  command -v tar   >/dev/null 2>&1 || need+=(tar)
  command -v gzip  >/dev/null 2>&1 || need+=(gzip)
  if [ ${#need[@]} -gt 0 ] && command -v apt-get >/dev/null 2>&1; then
    say "Instalando herramientas mínimas: ${need[*]}"
    sudo apt-get update >/dev/null 2>&1 || true
    sudo apt-get install -y "${need[@]}" >/dev/null 2>&1 || true
  fi
}

install_gum() {
  command -v gum >/dev/null 2>&1 && return 0
  ensure_base_tools
  say "Instalando gum..."
  local os arch tag url tmp
  os="$(uname -s)"
  arch="$(uname -m)"
  case "$os" in
    Linux) os="Linux" ;;
    Darwin) os="Darwin" ;;
    *) warn "OS no soportado para gum: $os"; return 1 ;;
  esac
  case "$arch" in
    x86_64|amd64) arch="x86_64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) warn "Arquitectura no soportada para gum: $arch"; return 1 ;;
  esac
  local api
  api="$(curl -fsSL https://api.github.com/repos/charmbracelet/gum/releases/latest 2>/dev/null || true)"
  if command -v python3 >/dev/null 2>&1; then
    tag="$(printf '%s' "$api" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tag_name",""))' 2>/dev/null || true)"
  else
    tag="$(printf '%s' "$api" | grep -o '"tag_name": *"[^"]*"' | head -n1 | cut -d'"' -f4)"
  fi
  if [ -z "$tag" ]; then
    warn "No se pudo consultar la última versión de gum; instala manualmente."
    return 1
  fi
  url="https://github.com/charmbracelet/gum/releases/download/${tag}/gum_${tag#v}_${os}_${arch}.tar.gz"
  tmp="$(mktemp -d)"
  if curl -fsSL "$url" -o "$tmp/gum.tar.gz"; then
    tar -xzf "$tmp/gum.tar.gz" -C "$tmp"
    mkdir -p "$HOME/.local/bin"
    install -m 0755 "$tmp/gum" "$HOME/.local/bin/gum"
    export PATH="$HOME/.local/bin:$PATH"
    say "gum instalado: $("$HOME/.local/bin/gum" --version 2>/dev/null || echo ok)"
  else
    warn "No se pudo descargar gum ($url)."
  fi
  rm -rf "$tmp"
}

# --- Argumentos ------------------------------------------------------------
SKIP_GIT_IDENTITY="${SKIP_GIT_IDENTITY:-0}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-git) SKIP_GIT_IDENTITY=1 ;;
    *) warn "Argumento desconocido: $1" ;;
  esac
  shift
done

install_gum || true

# shellcheck source=scripts/lib/ui.sh
source "$REPO_DIR/scripts/lib/ui.sh"

ui_banner "NUXIBA ENVIRONMENT" "OpenCode Bootstrap"

# 0. Identidad Git
ui_section "Paso 0: Identidad Git (SSH)"
if [ "$SKIP_GIT_IDENTITY" != "1" ]; then
  ui_info "Configurando identidad Git (por defecto)"
  bash "$REPO_DIR/scripts/setup-git-identity.sh" < /dev/tty || ui_warn "No se pudo completar la identidad Git (ejecuta setup-git-identity.sh manualmente)"
  ui_ok "Identidad Git atendida"
else
  ui_warn "Configuracion de identidad Git omitida (SKIP_GIT_IDENTITY=1)"
fi

# 1. Dependencias
ui_section "Paso 1: Dependencias base"
APT_PKGS=()
command -v git >/dev/null || APT_PKGS+=(git)
command -v curl >/dev/null || APT_PKGS+=(curl)
command -v python3 >/dev/null || APT_PKGS+=(python3)
command -v rsync >/dev/null || APT_PKGS+=(rsync)
command -v numfmt >/dev/null || APT_PKGS+=(coreutils)
command -v xdg-open >/dev/null || APT_PKGS+=(xdg-utils)
command -v ssh >/dev/null || APT_PKGS+=(openssh-client)

EXTRA_PKGS=(lazyvim fzf ripgrep bat eza zoxide fd-find lazygit)
CHOSEN_EXTRAS=()
if [ ${#EXTRA_PKGS[@]} -gt 0 ]; then
  ui_info "Selecciona paquetes custom adicionales (espacio en gum, Enter confirma)."
  mapfile -t CHOSEN_EXTRAS < <(ui_choose "Custom:" "${EXTRA_PKGS[@]}" || true)
  for p in ${CHOSEN_EXTRAS[@]+"${CHOSEN_EXTRAS[@]}"}; do
    case "$p" in
      lazyvim) ;;
      fd-find) command -v fd >/dev/null 2>&1 || APT_PKGS+=(fd-find);;
      lazygit) command -v lazygit >/dev/null 2>&1 || APT_PKGS+=(lazygit);;
      *) command -v "$p" >/dev/null 2>&1 || APT_PKGS+=("$p");;
    esac
  done
fi

if [ ${#APT_PKGS[@]} -gt 0 ]; then
  if command -v apt-get >/dev/null 2>&1; then
    ui_spin "apt-get update" sudo apt-get update
    ui_spin "apt-get install" sudo apt-get install -y "${APT_PKGS[@]}"
  else
    ui_warn "Gestor apt-get no disponible. Instala manualmente: ${APT_PKGS[*]}"
  fi
fi

if ! command -v node >/dev/null; then
  ui_info "Instalando nvm + node LTS..."
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
fi
export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
if ! command -v node >/dev/null; then
  nvm install --lts || { ui_error "Fallo instalando node"; exit 1; }
fi
ui_ok "Dependencias listas (node $(node --version 2>/dev/null || echo '?'))"

# 2. OpenCode
ui_section "Paso 2: OpenCode"
if ! command -v opencode >/dev/null; then
  ui_info "Usando metodo: curl v2"
  curl -fsSL https://opencode.ai/v2/install | bash || { ui_error "The OpenCode installer failed"; exit 1; }
fi
for p in "$HOME/.opencode/bin" "$HOME/.local/bin" "$HOME/bin"; do
  [ -d "$p" ] && export PATH="$p:$PATH"
done
if command -v opencode >/dev/null; then
  ui_ok "OpenCode: $(opencode --version 2>/dev/null || echo ok)"
else
  ui_warn "opencode no esta en PATH de esta sesion. Ejecuta: exec \$SHELL"
fi

# 3. Config
ui_section "Paso 3: Restaurar configuracion"
mkdir -p "$OPENCODE_DIR"
if command -v rsync >/dev/null 2>&1; then
  rsync -a "$REPO_DIR/config/opencode/" "$OPENCODE_DIR/"
else
  cp -r "$REPO_DIR/config/opencode/." "$OPENCODE_DIR/"
fi
ui_spin "npm install" bash -c "cd '$OPENCODE_DIR' && npm install" || ui_warn "npm install fallo; revisa node_modules manualmente"
ui_ok "Config restaurada"

# 4. graphify (skill externa vendorizada)
ui_section "Paso 4: graphify"
mkdir -p "$OPENCODE_DIR/skills"
if [ -d "$REPO_DIR/config/opencode/skills/graphify" ]; then
  rsync -a "$REPO_DIR/config/opencode/skills/graphify/" "$OPENCODE_DIR/skills/graphify/" 2>/dev/null || \
    cp -r "$REPO_DIR/config/opencode/skills/graphify/." "$OPENCODE_DIR/skills/graphify/"
  ui_ok "graphify instalado (ver VERSION.json para actualizaciones)"
else
  ui_warn "graphify no encontrado en el repo"
fi

# 5. oh-my-bash
ui_section "Paso 5: oh-my-bash"
if [ ! -d "$HOME/.oh-my-bash" ]; then
  ui_spin "Clonando oh-my-bash" git clone https://github.com/ohmybash/oh-my-bash.git "$HOME/.oh-my-bash" || { ui_error "Fallo clonando oh-my-bash"; exit 1; }
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
[ -f "$OSH/oh-my-bash.sh" ] && . "$OSH/oh-my-bash.sh" 2>/dev/null || true
ui_ok "oh-my-bash listo (tema vscode)"

# 6. herdr
ui_section "Paso 6: herdr"
if ! command -v herdr >/dev/null 2>&1; then
  ui_info "Usando metodo: curl"
  curl -fsSL https://herdr.dev/install.sh | sh || ui_warn "herdr no se instalo automaticamente"
fi
for p in "$HOME/.herdr/bin" "$HOME/.local/bin" "$HOME/.opencode/bin"; do
  [ -d "$p" ] && export PATH="$p:$PATH"
done
if ! grep -q 'export PATH=.*\.local/bin' "$HOME/.bashrc" 2>/dev/null; then
  echo 'export PATH="$HOME/.local/bin:$HOME/.herdr/bin:$HOME/.opencode/bin:$PATH"' >> "$HOME/.bashrc"
fi
command -v herdr >/dev/null 2>&1 && ui_ok "herdr: $(herdr --version 2>/dev/null || echo ok)" || ui_warn "herdr no disponible"

# 7. Neovim / LazyVim (si fue seleccionado custom)
if printf '%s\n' ${CHOSEN_EXTRAS[@]+"${CHOSEN_EXTRAS[@]}"} | grep -q '^lazyvim$'; then
  ui_section "Paso 7: Neovim / LazyVim"
  command -v nvim >/dev/null 2>&1 || ui_spin "instalando neovim" sudo apt-get install -y neovim
  if [ ! -d "$HOME/.config/nvim" ]; then
    git clone https://github.com/LazyVim/starter "$HOME/.config/nvim"
    rm -rf "$HOME/.config/nvim/.git"
  fi
  ui_ok "LazyVim starter instalado"
fi

# 8. Wrapper de sincronización
ui_section "Paso 8: Wrappers"
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/sync-dotfiles" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec bash <(curl -fsSL https://raw.githubusercontent.com/ChaminnPM/enviroment-dotfiles/main/scripts/sync.sh) "$@"
EOF
chmod +x "$HOME/.local/bin/sync-dotfiles"
ui_ok "sync-dotfiles instalado"

# 9. Persistir entorno
ui_section "Paso 9: Persistencia de entorno"
if [ -f "$HOME/.bash_profile" ]; then
  grep -q 'source ~/.bashrc' "$HOME/.bash_profile" 2>/dev/null || echo 'source ~/.bashrc' >> "$HOME/.bash_profile"
else
  echo 'source ~/.bashrc' > "$HOME/.bash_profile"
fi

[ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc" 2>/dev/null || true

ui_banner "Instalacion publica completada" "Ejecuta: exec \$SHELL si algo no esta en PATH"
