#!/usr/bin/env bash
set -euo pipefail

TMP_REPO="$(mktemp -d)"
trap 'rm -rf "$TMP_REPO"' EXIT

run_priv() {
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    return 1
  fi
}

ensure_cmd() {
  local cmd="$1" pkg="${2:-$1}"
  command -v "$cmd" >/dev/null 2>&1 && return 0
  echo "Instalando $pkg (necesario para instalar el entorno)..."
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "No se encontró apt-get; no puedo instalar $pkg automáticamente." >&2
    return 1
  fi
  run_priv apt-get update >/dev/null 2>&1 || true
  run_priv apt-get install -y "$pkg" >/dev/null 2>&1 || {
    echo "No se pudo instalar $pkg." >&2
    return 1
  }
}

ensure_cmd curl curl
ensure_cmd tar tar
ensure_cmd gzip gzip

echo "== enviroment-dotfiles (instalador publico) =="
echo "Descargando repositorio como tarball (no requiere git)..."
curl -fsSL https://github.com/ChaminnPM/enviroment-dotfiles/archive/refs/heads/main.tar.gz | tar -xz --strip-components=1 -C "$TMP_REPO"

cd "$TMP_REPO"
bash bootstrap.sh
