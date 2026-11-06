#!/usr/bin/env bash
# ui.sh - helpers de UI con gum y fallback portable.
# Uso: source "$(dirname "$0")/lib/ui.sh"

if command -v gum >/dev/null 2>&1; then
  ui_title()   { gum style --border double --border-foreground 212 --align center --padding "0 2" --margin "1 0" "$*"; }
  ui_section() { gum style --foreground 212 --bold "$*"; }
  ui_info()    { gum log --level info "$*"; }
  ui_ok()      { gum log --level info "$*"; }
  ui_warn()    { gum log --level warn "$*"; }
  ui_error()   { gum log --level error "$*"; }
  ui_ask()     { gum confirm "$*"; }
  ui_input()   { gum input --placeholder "$2" --prompt "$1 "; }
  ui_spin()    { local title="$1"; shift; gum spin --spinner dot --title "$title" -- "$@"; }
else
  ui_title()   { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
  ui_section() { printf '\033[1;36m%s\033[0m\n' "$*"; }
  ui_info()    { printf '\033[0;34m[INFO]\033[0m %s\n' "$*"; }
  ui_ok()      { printf '\033[0;32m[OK]\033[0m %s\n' "$*"; }
  ui_warn()    { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
  ui_error()   { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*"; }
  ui_ask()     { local a; read -rp "$* [y/N]: " a; [[ "${a,,}" == y* ]]; }
  ui_input()   { local v; read -rp "$1 " v; printf '%s' "$v"; }
  ui_spin()    { local title="$1"; shift; printf '%s...\n' "$title"; "$@"; }
fi
