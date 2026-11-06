#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${HOME}/enviroment-dotfiles"

if command -v gum >/dev/null 2>&1; then
  gum style --border double --border-foreground 212 --align center --padding "0 2" --margin "1 0" "enviroment-dotfiles" "Instalador publico"
else
  echo "== enviroment-dotfiles (instalador publico) =="
fi

if [ -d "$REPO_DIR/.git" ]; then
  if command -v gum >/dev/null 2>&1; then
    gum spin --spinner dot --title "Actualizando repositorio..." -- bash -c "cd '$REPO_DIR' && git pull --rebase --autostash"
  else
    ( cd "$REPO_DIR" && git pull --rebase --autostash )
  fi
else
  if command -v gum >/dev/null 2>&1; then
    gum spin --spinner dot --title "Clonando repositorio..." -- git clone https://github.com/ChaminnPM/enviroment-dotfiles.git "$REPO_DIR"
  else
    git clone https://github.com/ChaminnPM/enviroment-dotfiles.git "$REPO_DIR"
  fi
fi

cd "$REPO_DIR"
bash bootstrap.sh
