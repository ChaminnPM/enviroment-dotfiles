#!/usr/bin/env bash
set -euo pipefail

TMP_REPO="$(mktemp -d)"
trap 'rm -rf "$TMP_REPO"' EXIT

if command -v gum >/dev/null 2>&1; then
  gum style --border double --border-foreground 212 --align center --padding "0 2" --margin "1 0" "enviroment-dotfiles" "Instalador publico"
  gum spin --spinner dot --title "Clonando repositorio..." -- git clone https://github.com/ChaminnPM/enviroment-dotfiles.git "$TMP_REPO"
else
  echo "== enviroment-dotfiles (instalador publico) =="
  git clone https://github.com/ChaminnPM/enviroment-dotfiles.git "$TMP_REPO"
fi

cd "$TMP_REPO"
bash bootstrap.sh
