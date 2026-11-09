#!/usr/bin/env bash
# ui.sh - helpers de UI con gum dinámico, spinners, logs, anchos y fallback portable.

LOG_DIR="${LOG_DIR:-$HOME/.local/state/enviroment-dotfiles/logs}"
export VERBOSE="${VERBOSE:-0}"
export UI_APP_TITLE="${UI_APP_TITLE:-AGENTS ENVIRONMENT}"

ensure_log_dir() {
  mkdir -p "$LOG_DIR" 2>/dev/null || true
}

ui_gum_available() {
  command -v gum >/dev/null 2>&1
}

ui_width() {
  local cols
  cols="$(tput cols 2>/dev/null || true)"
  if [ -z "$cols" ]; then
    cols="$(stty size 2>/dev/null | awk '{print $2}' || true)"
  fi
  cols="${cols:-80}"
  cols=$((cols - 2))
  if [ "$cols" -lt 44 ]; then
    cols=44
  fi
  printf '%s' "$cols"
}

ui_wrap() {
  local width="$1"
  shift
  local inner=$((width - 6))
  [ "$inner" -lt 24 ] && inner=24
  printf '%s\n' "$*" | fold -s -w "$inner" || true
}

ui_clear() {
  if [ -t 1 ] && [ "${VERBOSE:-0}" != "1" ]; then
    clear >/dev/null 2>&1 || true
  fi
}

ui_banner() {
  ensure_log_dir
  local w text
  w="$(ui_width)"
  if [ "$#" -gt 1 ]; then
    local head rest
    head="$(ui_wrap "$w" "$1")"
    shift
    rest="$(ui_wrap "$w" "$*")"
    if ui_gum_available; then
      gum style --border rounded --border-foreground 63 --foreground 15 --bold --align center --width "$w" --margin "1 0" --padding "1 2" "$head" "$rest"
    else
      printf '\n\033[1;34m%s\033[0m\n' "$head"
      printf '%s\n' "$rest"
    fi
    return 0
  fi
  text="$(ui_wrap "$w" "$*")"
  if ui_gum_available; then
    gum style --border rounded --border-foreground 63 --foreground 15 --bold --align center --width "$w" --margin "1 0" --padding "1 2" "$text"
  else
    printf '\n\033[1;34m%s\033[0m\n' "$*"
    printf '%s\n' "$text"
  fi
}

ui_step_start() {
  local step="$1"
  local title="$2"
  ui_clear
  ui_banner "$UI_APP_TITLE" "$step: $title"
}

ui_step_done() {
  ui_ok "$*"
  if [ "${VERBOSE:-0}" != "1" ] && [ -t 1 ]; then
    sleep 0.35
  fi
}

ui_title() {
  local w text
  w="$(ui_width)"
  text="$(ui_wrap "$w" "$*")"
  if ui_gum_available; then
    gum style --border rounded --border-foreground 63 --align center --width "$w" --padding "0 2" --margin "1 0" "$text"
  else
    printf '\n== %s ==\n' "$text"
  fi
}

ui_section() {
  local w text
  w="$(ui_width)"
  text="$(ui_wrap "$w" "$*")"
  if ui_gum_available; then
    gum style --foreground 39 --bold --width "$w" --padding "0 1" "$text"
  else
    printf '%s\n' "$text"
  fi
}

ui_info() {
  if [ "${VERBOSE:-0}" = "1" ]; then
    if ui_gum_available; then gum log --level info "$*"; else printf '[INFO] %s\n' "$*"; fi
  fi
}

ui_ok() {
  if ui_gum_available; then gum log --level info "$*"; else printf '[OK] %s\n' "$*"; fi
}

ui_warn() {
  if ui_gum_available; then gum log --level warn "$*"; else printf '[WARN] %s\n' "$*"; fi
}

ui_error() {
  if ui_gum_available; then gum log --level error "$*"; else printf '[ERROR] %s\n' "$*"; fi
}

ui_dim() {
  if ui_gum_available; then gum style --foreground 240 "$*"; else printf '%s\n' "$*"; fi
}

ui_ask() {
  if ui_gum_available && [ -t 0 ]; then
    gum confirm "$*"
  elif [ -t 0 ]; then
    local a
    read -rp "$* [y/N]: " a
    [[ "${a,,}" == y* ]]
  else
    return 1
  fi
}

ui_input() {
  if ui_gum_available && [ -t 0 ]; then
    gum input --placeholder "${2:-}" --prompt "$1 "
  elif [ -t 0 ]; then
    local v
    read -rp "$1 " v
    printf '%s' "$v"
  else
    printf '%s' "${GIT_PROMPT_DEFAULT:-}"
  fi
}

ui_choose() {
  local prompt="$1"
  shift
  if ui_gum_available && [ -t 0 ]; then
    printf '%s\n' "$@" | gum choose --no-limit --height 12 --header "$prompt" || true
  elif [ -t 0 ]; then
    printf '%s\n' "$@"
    read -rp "Escribe separados por espacio (o Enter para omitir): " sel
    printf '%s\n' $sel
  fi
}

ui_tail_error() {
  local title="$1" log="$2"
  local w
  ensure_log_dir
  w="$(ui_width)"
  local tail=""
  if [ -f "$log" ]; then
    tail="$(tail -n 15 "$log" 2>/dev/null || true)"
    tail="$(ui_wrap "$w" "$title
Log: $log
$tail")"
  else
    tail="$(ui_wrap "$w" "$title
Log no disponible: $log")"
  fi

  if ui_gum_available; then
    gum style --border rounded --foreground 196 --border-foreground 196 --width "$w" --padding "1 2" "$tail"
  else
    printf '\n[ERROR] %s\n' "$title"
    printf 'Log: %s\n' "$log"
    if [ -f "$log" ]; then
      tail -n 15 "$log" || true
    fi
  fi
}

ui_summary() {
  local w text
  w="$(ui_width)"
  text="$(ui_wrap "$w" "$*")"
  if ui_gum_available; then
    gum style --border rounded --border-foreground 48 --foreground 48 --align center --width "$w" --padding "1 3" --margin "1 0" "$text"
  else
    printf '\n%s\n' "$text"
  fi
}

ui_logged() {
  local title="$1" cmd="$2"
  local log
  ensure_log_dir
  log="$LOG_DIR/$(date +%Y%m%d-%H%M%S)-$$.log"

  if [ "${VERBOSE:-0}" = "1" ]; then
    eval "$cmd"
    return $?
  fi

  if ui_gum_available && [ -t 1 ]; then
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

ui_apt_prefix() {
  if [ "${EUID:-$(id -u)}" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
    printf 'sudo '
  fi
}

ui_ensure_cmd() {
  local cmd="$1" pkg="${2:-$1}"
  command -v "$cmd" >/dev/null 2>&1 && return 0
  local apt_prefix
  apt_prefix="$(ui_apt_prefix)"
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
    rm -rf "$tmp"
    command -v gum >/dev/null 2>&1
  else
    rm -rf "$tmp"
    return 1
  fi
}

ui_seed_known_hosts() {
  local host tmp_known
  mkdir -p "$HOME/.ssh" 2>/dev/null || true
  chmod 700 "$HOME/.ssh" 2>/dev/null || true
  touch "$HOME/.ssh/known_hosts" 2>/dev/null || true
  tmp_known="$(mktemp)"
  for host in github.com bitbucket.org; do
    ssh-keyscan -t ed25519,rsa "$host" >> "$tmp_known" 2>/dev/null || true
  done
  if [ -s "$tmp_known" ]; then
    sort -u "$HOME/.ssh/known_hosts" "$tmp_known" > "${tmp_known}.sorted" 2>/dev/null || true
    if [ -s "${tmp_known}.sorted" ]; then
      cat "${tmp_known}.sorted" > "$HOME/.ssh/known_hosts" 2>/dev/null || true
    fi
  fi
  rm -f "$tmp_known" "${tmp_known}.sorted" 2>/dev/null || true
}

ui_ssh_test() {
  local title="$1" target="$2"
  ui_seed_known_hosts
  # GitHub/Bitbucket devuelven exit 1 incluso autenticando bien: evaluar por mensaje.
  ui_logged "$title" "out=\$(ssh -T -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10 '$target' 2>&1 || true); printf '%s\n' \"\$out\"; printf '%s\n' \"\$out\" | grep -Eiq 'successfully authenticated|logged in as'"
}
