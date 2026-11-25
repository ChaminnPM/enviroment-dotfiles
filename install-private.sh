#!/usr/bin/env bash
# install-private.sh - launcher publico para instalar el repo privado.
#
# raw.githubusercontent.com no sirve archivos de repos privados sin token,
# asi que este launcher (que SI es publico) verifica git/SSH, clona el repo
# privado por SSH en un temporal y ejecuta su install.sh. No deja el clon.
#
# Solo Linux y WSL (ver docs/PLATFORMS.md).
set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"
LOG_DIR="${LOG_DIR:-$HOME/.local/state/enviroment-dotfiles/logs}"
mkdir -p "$LOG_DIR" 2>/dev/null || true
chmod 700 "$LOG_DIR" 2>/dev/null || true

REPO_URL="${REPO_URL:-git@github.com:ChaminnPM/enviroment-dotfiles-secrets.git}"
REPO_REF="${REPO_REF:-main}"
ARGS=()

usage() {
  cat <<'HELP'
Uso: install-private.sh [opciones]

  --verbose            muestra toda la salida
  --dry-run            no ejecuta nada (solo verifica/clona)
  --non-interactive    sin preguntas (defaults, modo texto)
  --no-color           desactiva color
  --only <texto>       ejecuta solo los pasos cuyo titulo contenga <texto>
  --skip-dotnet        no instala .NET SDK (lo reenvia al repo privado)
  -h, --help           esta ayuda

Variables: REPO_URL, REPO_REF (default main), LOG_DIR.

Requiere acceso SSH a REPO_URL (llave de GitHub configurada).
HELP
}

while [ $# -gt 0 ]; do
  case "$1" in
    --verbose|verbose|v) ARGS+=(--verbose) ;;
    --dry-run|--non-interactive|--no-color|--skip-dotnet) ARGS+=("$1") ;;
    --only)
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        printf '[ERROR] --only requiere un valor\n' >&2
        exit 2
      fi
      ARGS+=(--only "$2")
      shift
      ;;
    --only=*) ARGS+=("$1") ;;
    -h|--help) usage; exit 0 ;;
    *) printf '[WARN] Argumento desconocido: %s\n' "$1" >&2 ;;
  esac
  shift
done

if [[ ! "$REPO_REF" =~ ^[A-Za-z0-9._-]+$ ]]; then
  printf '[ERROR] REPO_REF invalido: %q\n' "$REPO_REF" >&2
  exit 2
fi

case "$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')" in
  linux) ;;
  *)
    printf '[ERROR] Solo Linux/WSL; plataforma: %s\n' \
      "$(uname -s 2>/dev/null || echo '?')" >&2
    exit 1
    ;;
esac

TMP_REPO="$(mktemp -d)"
_cleanup() { rm -rf "$TMP_REPO" 2>/dev/null || true; }
trap _cleanup EXIT
trap 'exit 130' INT TERM HUP

APTPFX=""
if [ "${EUID:-$(id -u)}" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
  APTPFX="sudo"
fi

quiet_run() {
  local title="$1" log rc=0
  shift
  log="$LOG_DIR/$(date +%Y%m%d-%H%M%S)-$$-private-launcher.log"
  "$@" >"$log" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '[OK] %s\n' "$title"
    return 0
  fi
  printf '[ERROR] %s (log %s)\n' "$title" "$log" >&2
  tail -n 10 "$log" >&2 2>/dev/null || true
  return "$rc"
}

ensure_cmd() {
  local cmd="$1" pkg="${2:-$1}" mgr="" m
  local -a root=()
  command -v "$cmd" >/dev/null 2>&1 && return 0
  for m in apt-get dnf pacman zypper apk; do
    if command -v "$m" >/dev/null 2>&1; then mgr="$m"; break; fi
  done
  [ -n "$mgr" ] || { printf '[ERROR] No hay gestor de paquetes para %s\n' "$pkg" >&2; return 1; }
  [ -n "$APTPFX" ] && root=("$APTPFX")
  if [ -n "$APTPFX" ] && [ -e /dev/tty ] && ! "$APTPFX" -n true 2>/dev/null; then
    "$APTPFX" -v < /dev/tty >/dev/null 2>&1 || true
  fi
  case "$mgr" in
    apt-get) quiet_run "Instalando $pkg..." "${root[@]}" apt-get install -y --no-install-recommends "$pkg" ;;
    dnf) quiet_run "Instalando $pkg..." "${root[@]}" dnf install -y "$pkg" ;;
    pacman) quiet_run "Instalando $pkg..." "${root[@]}" pacman -S --noconfirm "$pkg" ;;
    zypper) quiet_run "Instalando $pkg..." "${root[@]}" zypper --non-interactive install "$pkg" ;;
    apk) quiet_run "Instalando $pkg..." "${root[@]}" apk add --no-cache "$pkg" ;;
  esac
}

ensure_cmd git git
ensure_cmd curl curl
ensure_cmd tar tar
ensure_cmd gzip gzip
ensure_cmd ssh openssh-client

# Fallar temprano y con mensaje claro si la llave SSH no esta configurada.
if command -v timeout >/dev/null 2>&1; then
  ssh_ok=0
  timeout 25 git ls-remote --heads "$REPO_URL" >/dev/null 2>&1 && ssh_ok=1
else
  git ls-remote --heads "$REPO_URL" >/dev/null 2>&1 && ssh_ok=1
fi
if [ "${ssh_ok:-0}" != "1" ]; then
  printf '[ERROR] No hay acceso SSH a %s.\n' "$REPO_URL" >&2
  printf '        Configura tu llave de GitHub (paso de identidad del repo publico).\n' >&2
  exit 1
fi

clone_args=(--depth 1)
[ "$REPO_REF" != "main" ] && clone_args+=(--branch "$REPO_REF")
if ! quiet_run "Clonando repositorio privado..." \
     git clone "${clone_args[@]}" "$REPO_URL" "$TMP_REPO/repo"; then
  printf '[ERROR] No se pudo clonar el repo privado.\n' >&2
  exit 1
fi

cd "$TMP_REPO/repo"
# Sin exec: asi se ejecuta el trap EXIT y se limpia el clon temporal.
bash install.sh ${ARGS[@]+"${ARGS[@]}"}
