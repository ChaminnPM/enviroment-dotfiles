#!/usr/bin/env bash
# install.sh - instalador one-liner para Linux y WSL.
# macOS y Windows nativo no estan soportados (ver docs/PLATFORMS.md).
set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"
LOG_DIR="${LOG_DIR:-$HOME/.local/state/enviroment-dotfiles/logs}"
export VERBOSE="${VERBOSE:-0}"
REPO_REF="${REPO_REF:-main}"
REPO_SHA256="${REPO_SHA256:-}"
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
    printf '[ERROR] Windows nativo no esta soportado. Usa WSL. Ver docs/PLATFORMS.md.\n' >&2
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

Variables: REPO_REF (rama/tag, default main), REPO_SHA256 (checksum opcional
del tarball), NUI_BASE_URL, NUI_VERSION.

Solo Linux y WSL. macOS/Windows: ver docs/PLATFORMS.md.
HELP
      exit 0
      ;;
    *) printf '[WARN] Argumento desconocido: %s\n' "$1" >&2 ;;
  esac
  shift
done
mkdir -p "$LOG_DIR" 2>/dev/null || true
chmod 700 "$LOG_DIR" 2>/dev/null || true

if [ "${WSL_INFO:-0}" = "1" ]; then
  printf '[INFO] WSL detectado; se instalara como Linux.\n'
fi

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
  local cmd="$1" pkg="${2:-$1}" mgr prefix
  command -v "$cmd" >/dev/null 2>&1 && return 0
  mgr=""
  for m in apt-get dnf pacman zypper apk; do
    if command -v "$m" >/dev/null 2>&1; then mgr="$m"; break; fi
  done
  prefix="$( [ "${EUID:-$(id -u)}" -ne 0 ] && command -v sudo >/dev/null 2>&1 && printf 'sudo ' )"
  case "$mgr" in
    apt-get) quiet_run "Instalando $pkg..." "${prefix}apt-get update >/dev/null 2>&1 || true; ${prefix}apt-get install -y $pkg >/dev/null 2>&1" ;;
    dnf) quiet_run "Instalando $pkg..." "${prefix}dnf install -y $pkg >/dev/null 2>&1" ;;
    pacman) quiet_run "Instalando $pkg..." "${prefix}pacman -S --noconfirm $pkg >/dev/null 2>&1" ;;
    zypper) quiet_run "Instalando $pkg..." "${prefix}zypper --non-interactive install $pkg >/dev/null 2>&1" ;;
    apk) quiet_run "Instalando $pkg..." "${prefix}apk add --no-cache $pkg >/dev/null 2>&1" ;;
    *) printf '[ERROR] No hay gestor de paquetes para %s\n' "$pkg" >&2; return 1 ;;
  esac
}

ensure_cmd curl curl
ensure_cmd tar tar
ensure_cmd gzip gzip

TARBALL="$TMP_REPO/repo.tar.gz"
quiet_run "Descargando repositorio (tarball)..." \
  "curl -fsSL --retry 3 --max-time 600 'https://github.com/ChaminnPM/enviroment-dotfiles/archive/refs/heads/${REPO_REF}.tar.gz' -o '$TARBALL'"

if [ -n "$REPO_SHA256" ]; then
  if command -v sha256sum >/dev/null 2>&1; then
    have="$(sha256sum "$TARBALL" | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    have="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
  else
    have=""
  fi
  if [ -z "$have" ] || [ "$have" != "$REPO_SHA256" ]; then
    printf '[ERROR] Checksum del tarball invalido (esperado %s, obtenido %s)\n' "$REPO_SHA256" "${have:-?}" >&2
    exit 1
  fi
  printf '[OK] Checksum del tarball verificado\n'
fi

quiet_run "Extrayendo repositorio..." "tar -xzf '$TARBALL' --strip-components=1 -C '$TMP_REPO'"

cd "$TMP_REPO"
bash bootstrap.sh ${BOOTSTRAP_ARGS[@]+"${BOOTSTRAP_ARGS[@]}"}
