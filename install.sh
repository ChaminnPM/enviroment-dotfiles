#!/usr/bin/env bash
set -euo pipefail
REPO_DIR="${HOME}/enviroment-dotfiles"
if [ ! -d "$REPO_DIR" ]; then
  git clone https://github.com/ChaminnPM/enviroment-dotfiles.git "$REPO_DIR"
fi
cd "$REPO_DIR"
bash bootstrap.sh