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

box "Paso 1: Dependencias base"
if ! command -v git >/dev/null; then sudo apt-get update && sudo apt-get install -y git curl; fi
if ! command -v node >/dev/null; then
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
  export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
  nvm install --lts || { err "Fallo instalando node"; end "Failed"; exit 1; }
fi
if ! command -v python3 >/dev/null; then sudo apt-get install -y python3; fi
ok "Dependencias listas"
end "Paso 1 completado"

box "Paso 2: OpenCode"
if ! command -v opencode >/dev/null; then
  info "Usando metodo: curl"
  curl -fsSL https://opencode.ai/install.sh | bash || { err "The OpenCode installer failed"; end "Failed"; exit 1; }
fi
ok "OpenCode listo"
end "Paso 2 completado"

box "Paso 3: Restaurar configuracion"
mkdir -p "$OPENCODE_DIR"
cp -r "$REPO_DIR/config/opencode/." "$OPENCODE_DIR/" || { err "Fallo copiando config"; end "Failed"; exit 1; }
cd "$OPENCODE_DIR" && npm install || { err "Fallo npm install"; end "Failed"; exit 1; }
ok "Config restaurada"
end "Paso 3 completado"

box "Paso 4: graphify"
mkdir -p "$OPENCODE_DIR/skills"
cp -r "$REPO_DIR/config/opencode/skills/graphify" "$OPENCODE_DIR/skills/" 2>/dev/null || true
ok "graphify listo"
end "Paso 4 completado"

box "Paso 5: oh-my-bash"
if [ ! -d "$HOME/.oh-my-bash" ]; then
  git clone https://github.com/ohmybash/oh-my-bash.git "$HOME/.oh-my-bash" || { err "Fallo clonando oh-my-bash"; end "Failed"; exit 1; }
fi
if ! grep -q 'oh-my-bash/oh-my-bash.sh' "$HOME/.bashrc" 2>/dev/null; then
  echo 'export OSH="$HOME/.oh-my-bash"' >> "$HOME/.bashrc"
  echo 'source "$OSH/oh-my-bash.sh"' >> "$HOME/.bashrc"
  echo 'OSH_THEME="catppuccin"' >> "$HOME/.bashrc"
fi
ok "oh-my-bash listo"
end "Paso 5 completado"

box "Paso 6: herdr"
if ! command -v herdr >/dev/null 2>&1; then
  info "Usando metodo: curl"
  curl -fsSL https://herdr.dev/install.sh | sh || warn "herdr no se instalo automaticamente"
fi
command -v herdr >/dev/null 2>&1 && ok "herdr: $(herdr --version 2>/dev/null || echo ok)" || warn "herdr no disponible"
end "Paso 6 completado"

box "Paso 7: Repositorio privado (opcional)"
read -rp "  Tienes acceso a enviroment-dotfiles-secrets? (y/N): " privans < /dev/tty
if [ "$privans" = "y" ] || [ "$privans" = "Y" ]; then
  PRIV_DIR="$HOME/.config/opencode-private"
  if [ ! -d "$PRIV_DIR" ]; then
    info "Clonando repo privado..."
    git clone "git@github.com:ChaminnPM/enviroment-dotfiles-secrets.git" "$PRIV_DIR" 2>/dev/null || \
    git clone "https://github.com/ChaminnPM/enviroment-dotfiles-secrets.git" "$PRIV_DIR" || { err "Fallo clonando privado"; end "Failed"; exit 1; }
  fi
  cp -r "$PRIV_DIR/config/opencode/." "$OPENCODE_DIR/" || { err "Fallo copiando privado"; end "Failed"; exit 1; }
  ok "Privado sincronizado"
else
  warn "Saltando repo privado"
fi
end "Paso 7 completado"

box "Paso 8: Repos de trabajo (opcional)"
read -rp "  Clonar repos CenterWare? (y/N): " ans < /dev/tty
if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
  mkdir -p "$HOME/Centerware"
  info "Clona manualmente los repos cw-* en $HOME/Centerware/"
fi
read -rp "  Clonar repos Slingshot/Reminder? (y/N): " ans2 < /dev/tty
if [ "$ans2" = "y" ] || [ "$ans2" = "Y" ]; then
  mkdir -p "$HOME/Slingshot"
  info "Clona manualmente los repos slingshot-*/rm-slingshot-*/reminder-* en $HOME/Slingshot/"
fi
end "Paso 8 completado"

echo ""
ok "Instalacion completada. Ejecuta 'opencode' para verificar."
end "Success"