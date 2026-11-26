#!/usr/bin/env bash
# install.sh - instalador one-liner para Linux y WSL.
# Windows nativo tiene su propio instalador (install.ps1); macOS no esta
# soportado. Ver docs/PLATFORMS.md.
set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"
LOG_DIR="${LOG_DIR:-$HOME/.local/state/enviroment-dotfiles/logs}"
export VERBOSE="${VERBOSE:-0}"
REPO_REF="${REPO_REF:-main}"
BOOTSTRAP_ARGS=()

case "$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')" in
  linux)
    if [ -r /proc/sys/kernel/osrelease ] && grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
      WSL_INFO=1
    fi
    ;;
  darwin)
    printf '[ERROR] macOS no esta soportado. Ver docs/PLATFORMS.md.\n' >&2
    exit 1
    ;;
  mingw*|msys*|cygwin*)
    printf '[ERROR] Estos scripts son de Linux/WSL. En Windows nativo usa install.ps1.\n' >&2
    printf '        powershell -ExecutionPolicy Bypass -File install.ps1   (ver docs/WINDOWS.md)\n' >&2
    exit 1
    ;;
  *)
    printf '[ERROR] Plataforma no soportada (%s). Solo Linux y WSL. Ver docs/PLATFORMS.md.\n' "$(uname -s 2>/dev/null || echo '?')" >&2
    exit 1
    ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --verbose|verbose|v) VERBOSE=1; export VERBOSE ;;
    --dry-run|--non-interactive|--no-color|--skip-git) BOOTSTRAP_ARGS+=("$1") ;;
    --only)
      if [ $# -lt 2 ]; then
        printf '[ERROR] --only requiere un valor\n' >&2
        exit 2
      fi
      BOOTSTRAP_ARGS+=("--only" "$2")
      shift
      ;;
    --only=*) BOOTSTRAP_ARGS+=("$1") ;;
    --help|-h)
      cat <<'HELP'
Uso: install.sh [opciones]

  --verbose            muestra toda la salida
  --dry-run            imprime el plan de pasos y no ejecuta nada
  --non-interactive    no hace preguntas (defaults, modo texto)
  --no-color           desactiva color
  --skip-git           omite la configuracion de identidad Git/SSH
  --only <texto>       ejecuta solo los pasos que coincidan
  -h, --help           esta ayuda

Variables: REPO_REF (rama/tag, default main; solo [A-Za-z0-9._-]),
NUI_BASE_URL, NUI_VERSION.

Solo Linux y WSL. En Windows nativo: install.ps1 (docs/WINDOWS.md).
macOS: no soportado (docs/PLATFORMS.md).
HELP
      exit 0
      ;;
    *) printf '[WARN] Argumento desconocido: %s\n' "$1" >&2 ;;
  esac
  shift
done

# REPO_REF se interpola en una URL y en un nombre de archivo: solo se
# aceptan caracteres seguros. Nunca se pasa a eval ni a bash -c.
if [[ ! "$REPO_REF" =~ ^[A-Za-z0-9._-]+$ ]]; then
  printf '[ERROR] REPO_REF invalido: %q (solo se permiten [A-Za-z0-9._-])\n' "$REPO_REF" >&2
  exit 2
fi

mkdir -p "$LOG_DIR" 2>/dev/null || true
chmod 700 "$LOG_DIR" 2>/dev/null || true

if [ "${WSL_INFO:-0}" = "1" ]; then
  printf '[INFO] WSL detectado; se instalara como Linux.\n'
fi

# --- cancelacion limpia ---------------------------------------------------
# Senalizacion copiada de install.sh del repo privado: al recibir INT/TERM/HUP
# se mata el arbol de procesos (curl/tar/apt) y se limpia el temporal.
TMP_REPO="$(mktemp -d)"

_install_cleanup() {
  [ -n "$TMP_REPO" ] && rm -rf "$TMP_REPO" 2>/dev/null || true
}

_install_kill_tree() {
  local pid="$1" sig="$2" kids child
  kids="$(ps -o pid= --ppid "$pid" 2>/dev/null || true)"
  for child in $kids; do
    _install_kill_tree "$child" "$sig"
  done
  if [ "$pid" != "$$" ]; then
    kill -"$sig" "$pid" 2>/dev/null || true
  fi
}

_install_signal() {
  # Handler inofensivo mientras se cancela: los hijos exec'ados heredarian
  # "ignored" si se usara trap '', y no responderian al TERM del grupo.
  trap ':' INT TERM HUP
  if command -v pkill >/dev/null 2>&1; then
    pkill -TERM -P "$$" 2>/dev/null || true
  fi
  _install_kill_tree "$$" TERM
  local pgid=""
  pgid="$(ps -o pgid= -p $$ 2>/dev/null | tr -d '[:space:]' || true)"
  if [ "$pgid" = "$$" ]; then
    kill -TERM -- "-$$" 2>/dev/null || true
  fi
  sleep 0.2 2>/dev/null || sleep 1 2>/dev/null || true
  _install_kill_tree "$$" KILL
  _install_cleanup
  exit 130
}
trap '_install_signal INT' INT
trap '_install_signal TERM' TERM
trap '_install_signal HUP' HUP
trap '_install_cleanup' EXIT

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

# quiet_run <titulo> <cmd> [args...]
# Ejecuta argv como array (sin eval): ningun dato del usuario se interpola en
# una cadena de shell. Toda la salida se captura en un log y se devuelve el
# codigo de salida real del comando.
quiet_run() {
  local title="$1" log rc=0
  shift
  log="$LOG_DIR/$(date +%Y%m%d-%H%M%S)-$$.log"
  if [ "${VERBOSE:-0}" = "1" ]; then
    "$@" || rc=$?
    return "$rc"
  fi
  # si nui ya esta disponible de una corrida anterior, usar su spinner
  if command -v nui >/dev/null 2>&1 && [ -t 1 ]; then
    nui spin --title "$title" -- "$@" >"$log" 2>&1 || rc=$?
  else
    "$@" >"$log" 2>&1 || rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
    printf '\033[0;32m[OK]\033[0m %s\n' "$title"
    return 0
  fi
  printf '\033[0;31m[ERROR]\033[0m %s\n' "$title" >&2
  printf 'Log: %s\n' "$log" >&2
  [ -f "$log" ] && tail -n 15 "$log" >&2 || true
  return "$rc"
}

ensure_cmd() {
  local cmd="$1" pkg="${2:-$1}" mgr="" m
  local -a root=()
  command -v "$cmd" >/dev/null 2>&1 && return 0
  for m in apt-get dnf pacman zypper apk; do
    if command -v "$m" >/dev/null 2>&1; then mgr="$m"; break; fi
  done
  if [ "${EUID:-$(id -u)}" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
    root=(sudo)
  fi
  case "$mgr" in
    apt-get)
      # La actualizacion de indices es best-effort; la instalacion no.
      quiet_run "Actualizando indice de paquetes..." "${root[@]+"${root[@]}"}" apt-get update || true
      quiet_run "Instalando $pkg..." "${root[@]+"${root[@]}"}" apt-get install -y "$pkg"
      ;;
    dnf) quiet_run "Instalando $pkg..." "${root[@]+"${root[@]}"}" dnf install -y "$pkg" ;;
    pacman) quiet_run "Instalando $pkg..." "${root[@]+"${root[@]}"}" pacman -S --noconfirm "$pkg" ;;
    zypper) quiet_run "Instalando $pkg..." "${root[@]+"${root[@]}"}" zypper --non-interactive install "$pkg" ;;
    apk) quiet_run "Instalando $pkg..." "${root[@]+"${root[@]}"}" apk add --no-cache "$pkg" ;;
    *) printf '[ERROR] No hay gestor de paquetes para %s\n' "$pkg" >&2; return 1 ;;
  esac
}

ensure_cmd curl curl
ensure_cmd tar tar
ensure_cmd gzip gzip

TARBALL="$TMP_REPO/repo.tar.gz"
TARBALL_URL="https://github.com/ChaminnPM/enviroment-dotfiles/archive/refs/heads/${REPO_REF}.tar.gz"
quiet_run "Descargando repositorio (tarball)..." \
  curl -fsSL --retry 3 --max-time 600 "$TARBALL_URL" -o "$TARBALL"

quiet_run "Extrayendo repositorio..." tar -xzf "$TARBALL" --strip-components=1 -C "$TMP_REPO"

cd "$TMP_REPO"
bash bootstrap.sh ${BOOTSTRAP_ARGS[@]+"${BOOTSTRAP_ARGS[@]}"}
