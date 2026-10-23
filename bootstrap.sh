#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; C='\033[0;36m'; N='\033[0m'
info() { echo -e "${BLUE}[INFO]${N} $*"; }
ok()   { echo -e "${GREEN}[OK]${N} $*"; }
warn() { echo -e "${YELLOW}[WARN]${N} $*"; }
err()  { echo -e "${RED}[ERROR]${N} $*"; }
box()  { echo -e "${C}┌${N}  $*"; echo -e "${C}│${N}"; }
end()  { echo -e "${C}└${N}  $*"; echo; }

OPENCODE_DIR="${OPENCODE_DIR:-$HOME/.config/opencode}"
REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$0")" && pwd)}"

box "OpenCode Bootstrap"

# 0. Identidad Git
box "Paso 0: Identidad Git (SSH)"
read -rp "  Configurar identidad Git ahora? (y/N/skip): " gitans < /dev/tty
if [ "$gitans" = "y" ] || [ "$gitans" = "Y" ]; then
  info "Usando metodo: setup-git-identity.sh"
  bash "$REPO_DIR/scripts/setup-git-identity.sh" < /dev/tty || { err "Fallo en setup-git-identity"; end "Failed"; exit 1; }
  ok "Identidad Git configurada"
else
  warn "Saltando configuracion de identidad Git"
  info "Recuerda ejecutarla antes de sync.sh push/pull"
fi
end "Paso 0 completado"

# 1. Dependencias
box "Paso 1: Dependencias base"
if ! command -v git >/dev/null; then sudo apt-get update && sudo apt-get install -y git curl; fi
if ! command -v node >/dev/null; then
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
  export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
  nvm install --lts || { err "Fallo instalando node"; end "Failed"; exit 1; }
fi
if ! command -v python3 >/dev/null; then sudo apt-get install -y python3; fi
export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
ok "Dependencias listas"
end "Paso 1 completado"

# 2. OpenCode
box "Paso 2: OpenCode"
if ! command -v opencode >/dev/null; then
  info "Usando metodo: curl v2"
  curl -fsSL https://opencode.ai/v2/install | bash || { err "The OpenCode installer failed"; end "Failed"; exit 1; }
  for p in "$HOME/.opencode/bin" "$HOME/.local/bin" "$HOME/bin"; do
    [ -d "$p" ] && export PATH="$p:$PATH"
  done
fi
if command -v opencode >/dev/null; then
  ok "OpenCode: $(opencode --version 2>/dev/null || echo ok)"
else
  warn "opencode no esta en PATH de esta sesion. Ejecuta: exec \$SHELL"
fi
end "Paso 2 completado"

# 3. Config
box "Paso 3: Restaurar configuracion"
mkdir -p "$OPENCODE_DIR"
cp -r "$REPO_DIR/config/opencode/." "$OPENCODE_DIR/" || { err "Fallo copiando config"; end "Failed"; exit 1; }
cd "$OPENCODE_DIR" && npm install || { err "Fallo npm install"; end "Failed"; exit 1; }
ok "Config restaurada"
end "Paso 3 completado"

# 4. graphify
box "Paso 4: graphify"
mkdir -p "$OPENCODE_DIR/skills"
cp -r "$REPO_DIR/config/opencode/skills/graphify" "$OPENCODE_DIR/skills/" 2>/dev/null || true
ok "graphify listo"
end "Paso 4 completado"

# 5. oh-my-bash
box "Paso 5: oh-my-bash"
if [ ! -d "$HOME/.oh-my-bash" ]; then
  git clone https://github.com/ohmybash/oh-my-bash.git "$HOME/.oh-my-bash" || { err "Fallo clonando oh-my-bash"; end "Failed"; exit 1; }
fi
# Asegurar que oh-my-bash se cargue en .bashrc (OSH_THEME antes del source)
if ! grep -q 'oh-my-bash/oh-my-bash.sh' "$HOME/.bashrc" 2>/dev/null; then
  {
    echo 'export OSH="$HOME/.oh-my-bash"'
    echo 'OSH_THEME="vscode"'
    echo 'source "$OSH/oh-my-bash.sh"'
  } >> "$HOME/.bashrc"
fi
# Asegurar OSH_THEME en .bashrc si no esta
if ! grep -q 'OSH_THEME="vscode"' "$HOME/.bashrc" 2>/dev/null; then
  sed -i 's/^OSH_THEME=.*/OSH_THEME="vscode"/' "$HOME/.bashrc" 2>/dev/null || true
fi
export OSH="$HOME/.oh-my-bash"
OSH_THEME="vscode"
[ -f "$OSH/oh-my-bash.sh" ] && source "$OSH/oh-my-bash.sh" 2>/dev/null || true
ok "oh-my-bash listo (tema vscode)"
end "Paso 5 completado"

# 6. herdr
box "Paso 6: herdr"
if ! command -v herdr >/dev/null 2>&1; then
  info "Usando metodo: curl"
  curl -fsSL https://herdr.dev/install.sh | sh || warn "herdr no se instalo automaticamente"
fi
for p in "$HOME/.herdr/bin" "$HOME/.local/bin" "$HOME/.opencode/bin"; do
  [ -d "$p" ] && export PATH="$p:$PATH"
done
# Persistir PATH en .bashrc
if ! grep -q 'export PATH=.*\.local/bin' "$HOME/.bashrc" 2>/dev/null; then
  echo 'export PATH="$HOME/.local/bin:$HOME/.herdr/bin:$HOME/.opencode/bin:$PATH"' >> "$HOME/.bashrc"
fi
command -v herdr >/dev/null 2>&1 && ok "herdr: $(herdr --version 2>/dev/null || echo ok)" || warn "herdr no disponible"
end "Paso 6 completado"

# Persistir .bashrc en .bash_profile
if [ -f "$HOME/.bash_profile" ]; then
  grep -q 'source ~/.bashrc' "$HOME/.bash_profile" 2>/dev/null || echo 'source ~/.bashrc' >> "$HOME/.bash_profile"
else
  echo 'source ~/.bashrc' > "$HOME/.bash_profile"
fi

# Source en sesion actual
[ -f "$HOME/.bashrc" ] && source "$HOME/.bashrc" 2>/dev/null || true

echo ""
ok "Instalacion publica completada."
info "Si los comandos no funcionan, ejecuta: exec \$SHELL"
end "Success"