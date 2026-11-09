#!/usr/bin/env bash
set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"
LOG_DIR="${LOG_DIR:-$HOME/.local/state/enviroment-dotfiles/logs}"
export VERBOSE="${VERBOSE:-0}"
mkdir -p "$LOG_DIR" 2>/dev/null || true

TMP_REPO="$(mktemp -d)"
trap 'rm -rf "$TMP_REPO"' EXIT

APTPFX=""
if [ "${EUID:-$(id -u)}" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
  APTPFX="sudo "
fi

quiet_run() {
  local title="$1" cmd="$2" log
  log="$LOG_DIR/$(date +%Y%m%d-%H%M%S)-$$.log"
  if [ "${VERBOSE:-0}" = "1" ]; then
    eval "$cmd"
    return $?
  fi
  if command -v gum >/dev/null 2>&1 && [ -t 1 ]; then
    if gum spin --spinner line --title "$title" -- bash -c 'eval "$1" >"$2" 2>&1' _ "$cmd" "$log"; then
      return 0
    else
      printf '\033[0;31m[ERROR]\033[0m %s\n' "$title" >&2
      printf '\033[0;34m[INFO]\033[0m Log: %s\n' "$log" >&2
      [ -f "$log" ] && tail -n 10 "$log" >&2 || true
      return 1
    fi
  else
    if bash -c 'eval "$1" >"$2" 2>&1' _ "$cmd" "$log"; then
      return 0
    else
      printf '\033[0;31m[ERROR]\033[0m %s\n' "$title" >&2
      printf '\033[0;34m[INFO]\033[0m Log: %s\n' "$log" >&2
      [ -f "$log" ] && tail -n 10 "$log" >&2 || true
      return 1
    fi
  fi
}

ensure_cmd() {
  local cmd="$1" pkg="${2:-$1}"
  command -v "$cmd" >/dev/null 2>&1 && return 0
  quiet_run "Instalando $pkg..." "${APTPFX}apt-get update >/dev/null 2>&1 || true; ${APTPFX}apt-get install -y $pkg >/dev/null 2>&1"
}

install_gum() {
  command -v gum >/dev/null 2>&1 && return 0
  ensure_cmd curl curl || return 1
  ensure_cmd tar tar || return 1
  ensure_cmd gzip gzip || return 1

  local os arch tag url tmp
  os="$(uname -s)"; arch="$(uname -m)"
  case "$os" in Linux) os="Linux" ;; Darwin) os="Darwin" ;; *) return 1 ;; esac
  case "$arch" in x86_64|amd64) arch="x86_64" ;; aarch64|arm64) arch="arm64" ;; *) return 1 ;; esac

  tag="$(curl -fsSL https://api.github.com/repos/charmbracelet/gum/releases/latest 2>/dev/null \
    | grep -o '"tag_name": *"[^"]*"' | head -n1 | cut -d'"' -f4 || true)"
  [ -n "$tag" ] || return 1

  url="https://github.com/charmbracelet/gum/releases/download/${tag}/gum_${tag#v}_${os}_${arch}.tar.gz"
  tmp="$(mktemp -d)"
  quiet_run "Instalando gum..." "mkdir -p '$HOME/.local/bin'; curl -fsSL '$url' -o '$tmp/gum.tar.gz' && tar -xzf '$tmp/gum.tar.gz' -C '$tmp' && install -m 0755 '$tmp/gum' '$HOME/.local/bin/gum'"
  rm -rf "$tmp"
  command -v gum >/dev/null 2>&1 || return 1
}

install_gum || true

clear_if_tty() {
  if [ -t 1 ] && [ "${VERBOSE:-0}" != "1" ]; then
    clear >/dev/null 2>&1 || true
  fi
}

banner() {
  if command -v gum >/dev/null 2>&1; then
    gum style --foreground 212 --border-foreground 212 --border double --align center --width 62 --margin "1 0" --padding "0 1" "$*"
  else
    printf '\n\033[1;36m============================================================\033[0m\n\033[1;36m%s\033[0m\n\033[1;36m============================================================\033[0m\n' "$*"
  fi
}

clear_if_tty
banner "NUXIBA ENVIRONMENT" "OpenCode Bootstrap"

ensure_cmd curl curl
ensure_cmd tar tar
ensure_cmd gzip gzip

download_cmd="curl -fsSL https://github.com/ChaminnPM/enviroment-dotfiles/archive/refs/heads/main.tar.gz | tar -xz --strip-components=1 -C '$TMP_REPO'"
quiet_run "Descargando repositorio (tarball)..." "$download_cmd"

cd "$TMP_REPO"
bash bootstrap.sh "$@"
