#!/usr/bin/env bash
# ui.sh - helpers de UI con gum, spinners, logs y fallback portable.
# Uso: source "$(dirname "$0")/lib/ui.sh"

LOG_DIR="${LOG_DIR:-$HOME/.local/state/enviroment-dotfiles/logs}"
export VERBOSE="${VERBOSE:-0}"

ensure_log_dir() {
  mkdir -p "$LOG_DIR" 2>/dev/null || true
}

ui_clear() {
  if [ -t 1 ] && [ "${VERBOSE:-0}" != "1" ]; then
    clear >/dev/null 2>&1 || true
  fi
}

if command -v gum >/dev/null 2>&1; then
  ui_banner()  { ensure_log_dir; gum style --foreground 212 --border-foreground 212 --border double --align center --width 72 --margin "1 0" --padding "0 1" "$*"; }
  ui_title()   { gum style --border double --border-foreground 212 --align center --padding "0 2" --margin "1 0" "$*"; }
  ui_section() { gum style --foreground 212 --bold --padding "0 1" "$*"; }
  ui_info()    { [ "${VERBOSE:-0}" = "1" ] && gum log --level info "$*" || true; }
  ui_ok()      { gum log --level info "$*"; }
  ui_warn()    { gum log --level warn "$*"; }
  ui_error()   { gum log --level error "$*"; }
  ui_ask()     { gum confirm "$*"; }
  ui_input()   { gum input --placeholder "$2" --prompt "$1 "; }
  ui_choose()  { local prompt="$1"; shift; if [ -t 0 ]; then printf '%s\n' "$@" | gum choose --no-limit --height 12 --header "$prompt" || true; fi; }
  ui_spin()    { local title="$1"; shift; gum spin --spinner moon --title "$title" -- "$@"; }
  ui_tail_error() {
    local title="$1" log="$2"
    ensure_log_dir
    if [ -f "$log" ]; then
      gum style --border rounded --foreground 196 --border-foreground 196 --padding "1 2" \
        "Fallo: $title" \
        "Log: $log" \
        "$(tail -n 15 "$log" 2>/dev/null)"
    else
      gum style --border rounded --foreground 196 --border-foreground 196 --padding "1 2" \
        "Fallo: $title" \
        "Log no disponible: $log"
    fi
  }
  ui_summary() {
    gum style --border rounded --border-foreground 48 --foreground 48 --align center --padding "1 3" --margin "1 0" "✨ $*"
  }
  ui_dim() { gum style --foreground 240 "$*"; }
else
  ui_banner()  { printf '\n\033[1;36m============================================================\033[0m\n\033[1;36m%s\033[0m\n\033[1;36m============================================================\033[0m\n' "$*"; }
  ui_title()   { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
  ui_section() { printf '\033[1;36m%s\033[0m\n' "$*"; }
  ui_info()    { [ "${VERBOSE:-0}" = "1" ] && printf '\033[0;34m[INFO]\033[0m %s\n' "$*" || true; }
  ui_ok()      { printf '\033[0;32m[OK]\033[0m %s\n' "$*"; }
  ui_warn()    { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
  ui_error()   { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*"; }
  ui_ask()     { local a; if [ -t 0 ]; then read -rp "$* [y/N]: " a; [[ "${a,,}" == y* ]]; else return 1; fi; }
  ui_input()   { local v; if [ -t 0 ]; then read -rp "$1 " v; else v="${GIT_PROMPT_DEFAULT:-}"; fi; printf '%s' "$v"; }
  ui_choose()  { local prompt="$1"; shift; if [ -t 0 ]; then echo "$prompt:"; printf '  %s\n' "$@"; read -rp "Escribe separados por espacio (o Enter para omitir): " sel; printf '%s\n' $sel; fi; }
  ui_spin()    { local title="$1"; shift; printf '%s...\n' "$title"; "$@"; }
  ui_tail_error() {
    local title="$1" log="$2"
    ensure_log_dir
    printf '\033[0;31m[ERROR]\033[0m %s\n' "$title"
    printf '\033[0;34m[INFO]\033[0m Log: %s\n' "$log"
    [ -f "$log" ] && tail -n 15 "$log" || true
  }
  ui_summary() { printf '\033[0;32m%s\033[0m\n' "$*"; }
  ui_dim() { printf '\033[0;37m%s\033[0m\n' "$*"; }
fi

ui_logged() {
  local title="$1" cmd="$2"
  local log
  ensure_log_dir
  log="$LOG_DIR/$(date +%Y%m%d-%H%M%S)-$$.log"

  if [ "${VERBOSE:-0}" = "1" ]; then
    eval "$cmd"
    return $?
  fi

  if command -v gum >/dev/null 2>&1 && [ -t 1 ]; then
    if gum spin --spinner moon --title "$title" -- bash -c 'eval "$1" >"$2" 2>&1' _ "$cmd" "$log"; then
      return 0
    else
      ui_tail_error "$title" "$log"
      return 1
    fi
  else
    if bash -c 'eval "$1" >"$2" 2>&1' _ "$cmd" "$log"; then
      return 0
    else
      ui_tail_error "$title" "$log"
      return 1
    fi
  fi
}

ui_ensure_cmd() {
  local cmd="$1" pkg="${2:-$1}"
  command -v "$cmd" >/dev/null 2>&1 && return 0
  local apt_prefix=""
  if [ "${EUID:-$(id -u)}" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
    apt_prefix="sudo "
  fi
  ui_logged "Instalando $pkg..." "${apt_prefix}apt-get update >/dev/null 2>&1 || true; ${apt_prefix}apt-get install -y $pkg >/dev/null 2>&1"
}

ui_install_gum() {
  command -v gum >/dev/null 2>&1 && return 0
  ui_ensure_cmd curl curl || return 1
  ui_ensure_cmd tar tar || return 1
  ui_ensure_cmd gzip gzip || return 1

  local os arch api tag url tmp gum_bin
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

  api="$(curl -fsSL https://api.github.com/repos/charmbracelet/gum/releases/latest 2>/dev/null || true)"
  if command -v python3 >/dev/null 2>&1; then
    tag="$(printf '%s' "$api" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tag_name",""))' 2>/dev/null || true)"
  else
    tag="$(printf '%s' "$api" | grep -o '"tag_name": *"[^"]*"' | head -n1 | cut -d'"' -f4)"
  fi
  [ -n "$tag" ] || tag="v2.0.2"

  url="https://github.com/charmbracelet/gum/releases/download/${tag}/gum_${tag#v}_${os}_${arch}.tar.gz"
  tmp="$(mktemp -d)"
  if ! ui_logged "Instalando gum..." "curl -fsSL '$url' -o '$tmp/gum.tar.gz' && tar -xzf '$tmp/gum.tar.gz' -C '$tmp'"; then
    rm -rf "$tmp"
    return 1
  fi

  gum_bin="$(find "$tmp" -type f -name gum -print -quit 2>/dev/null || true)"
  if [ -n "$gum_bin" ]; then
    ui_logged "Instalando gum..." "mkdir -p '$HOME/.local/bin' && install -m 0755 '$gum_bin' '$HOME/.local/bin/gum'" || { rm -rf "$tmp"; return 1; }
    export PATH="$HOME/.local/bin:$PATH"
    command -v gum >/dev/null 2>&1
  else
    rm -rf "$tmp"
    return 1
  fi
}
