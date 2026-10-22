#!/usr/bin/env bash
set -euo pipefail

OPENCODE_DIR="${OPENCODE_DIR:-$HOME/.config/opencode}"
REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"

# 0. Identidad Git (PRIMERO)
echo "==> Configurando identidad Git (personal + nuxiba)"
bash "$REPO_DIR/scripts/setup-git-identity.sh"
echo "Confirma que las pruebas SSH pasaron (y/N):"; read -r ok
[ "$ok" = "y" ] || [ "$ok" = "Y" ] || { echo "Abortado: configura SSH primero."; exit 1; }

echo "==> Instalando dependencias base"
if ! command -v git >/dev/null; then sudo apt-get update && sudo apt-get install -y git curl; fi
if ! command -v node >/dev/null; then
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
  export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
  nvm install --lts
fi
if ! command -v python3 >/dev/null; then sudo apt-get install -y python3; fi

echo "==> Instalando OpenCode"
if ! command -v opencode >/dev/null; then
  curl -fsSL https://opencode.ai/install.sh | bash
fi

echo "==> Restaurando configuracion"
mkdir -p "$OPENCODE_DIR"
cp -r "$REPO_DIR/config/opencode/." "$OPENCODE_DIR/"
cd "$OPENCODE_DIR" && npm install

echo "==> Instalando graphify skill"
mkdir -p "$OPENCODE_DIR/skills"
cp -r "$REPO_DIR/config/opencode/skills/graphify" "$OPENCODE_DIR/skills/" 2>/dev/null || true

echo "==> Instalando oh-my-bash"
if [ ! -d "$HOME/.oh-my-bash" ]; then
  git clone https://github.com/ohmybash/oh-my-bash.git "$HOME/.oh-my-bash"
fi
if ! grep -q 'oh-my-bash/oh-my-bash.sh' "$HOME/.bashrc"; then
  echo 'export OSH="$HOME/.oh-my-bash"' >> "$HOME/.bashrc"
  echo 'source "$OSH/oh-my-bash.sh"' >> "$HOME/.bashrc"
  echo 'OSH_THEME="catppuccin"' >> "$HOME/.bashrc"
fi

echo "==> Instalando herdr"
if ! command -v herdr >/dev/null; then
  echo "  (instalacion manual de herdr requerida; ver README)"
fi

echo "==> Repositorio privado (secretos/contexto)?"
read -rp "Tienes acceso al repo privado opencode-dotfiles-private? (y/N) " privans
if [ "$privans" = "y" ] || [ "$privans" = "Y" ]; then
  PRIV_DIR="$HOME/.config/opencode-private"
  if [ ! -d "$PRIV_DIR" ]; then
    git clone "git@github.com:<USER>/opencode-dotfiles-private.git" "$PRIV_DIR" 2>/dev/null || \
    git clone "https://github.com/<USER>/opencode-dotfiles-private.git" "$PRIV_DIR"
  fi
  cp -r "$PRIV_DIR/config/opencode/." "$OPENCODE_DIR/"
fi
if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
  mkdir -p "$HOME/Centerware"
  echo "  Clona manualmente los repos cw-* en $HOME/Centerware/"
fi
read -rp "Clonar repos Slingshot/Reminder? (y/N) " ans2
if [ "$ans2" = "y" ] || [ "$ans2" = "Y" ]; then
  mkdir -p "$HOME/Slingshot"
  echo "  Clona manualmente los repos slingshot-*/rm-slingshot-*/reminder-* en $HOME/Slingshot/"
fi

echo "==> Listo. Ejecuta 'opencode' para verificar."