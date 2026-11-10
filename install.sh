#!/usr/bin/env bash
set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"
LOG_DIR="${LOG_DIR:-$HOME/.local/state/enviroment-dotfiles/logs}"
export VERBOSE="${VERBOSE:-0}"
for arg in "$@"; do
  case "$arg" in
    --verbose|verbose|v) VERBOSE=1; export VERBOSE ;;
  esac
done
mkdir -p "$LOG_DIR" 2>/dev/null || true

TMP_REPO="$(mktemp -d)"
trap 'rm -rf "$TMP_REPO"' EXIT

APTPFX=""
if [ "${EUID:-$(id -u)}" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
  APTPFX="sudo "
fi

# Si faltan herramientas y hay sudo, cachear credenciales en el TTY real
# (los comandos de quiet_run no tienen TTY propio).
if [ -n "$APTPFX" ] && [ -e /dev/tty ]; then
  _need=0
  for _c in curl tar gzip; do
    command -v "$_c" >/dev/null 2>&1 || _need=1
  done
  if [ "$_need" = "1" ]; then
    sudo -v < /dev/tty || true
  fi
fi

quiet_run() {
  local title="$1" cmd="$2" log
  log="$LOG_DIR/$(date +%Y%m%d-%H%M%S)-$$.log"
  if [ "${VERBOSE:-0}" = "1" ]; then
    eval "$cmd"
    return $?
  fi
  # si nui ya esta disponible de una corrida anterior, usar su spinner
  if command -v nui >/dev/null 2>&1 && [ -t 1 ]; then
    if nui spin --title "$title" -- bash -c 'eval "$1" >"$2" 2>&1' _ "$cmd" "$log"; then
      return 0
    fi
    printf '\033[0;31m[ERROR]\033[0m %s\n' "$title" >&2
    printf 'Log: %s\n' "$log" >&2
    [ -f "$log" ] && tail -n 15 "$log" >&2 || true
    return 1
  fi
  if bash -c 'eval "$1" >"$2" 2>&1' _ "$cmd" "$log"; then
    printf '\033[0;32m[OK]\033[0m %s\n' "$title"
    return 0
  fi
  printf '\033[0;31m[ERROR]\033[0m %s\n' "$title" >&2
  printf 'Log: %s\n' "$log" >&2
  [ -f "$log" ] && tail -n 15 "$log" >&2 || true
  return 1
}

ensure_cmd() {
  local cmd="$1" pkg="${2:-$1}"
  command -v "$cmd" >/dev/null 2>&1 && return 0
  quiet_run "Instalando $pkg..." "${APTPFX}apt-get update >/dev/null 2>&1 || true; ${APTPFX}apt-get install -y $pkg >/dev/null 2>&1"
}

ensure_cmd curl curl
ensure_cmd tar tar
ensure_cmd gzip gzip

quiet_run "Descargando repositorio (tarball)..." "curl -fsSL https://github.com/ChaminnPM/enviroment-dotfiles/archive/refs/heads/main.tar.gz | tar -xz --strip-components=1 -C '$TMP_REPO'"

cd "$TMP_REPO"
bash bootstrap.sh "$@"
