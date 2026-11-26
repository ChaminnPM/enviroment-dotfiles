#!/usr/bin/env bash
# build.sh - compila nui y genera bin/*.gz + bin/SHA256SUMS
#
# Targets por defecto: Linux (amd64/arm64) y Windows nativo (amd64).
# Windows es plataforma soportada: requiere proc/dirs/tty/pager *_windows.go.
# Para anadir tambien macOS (no soportado, ver docs/PLATFORMS.md):
#   NUI_TARGETS="linux/amd64 linux/arm64 windows/amd64 darwin/amd64 darwin/arm64" bash ui/build.sh
#   NUI_INCLUDE_DARWIN=1 bash ui/build.sh
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v go >/dev/null 2>&1; then
  if [ -x "$HOME/.local/go/bin/go" ]; then
    export PATH="$HOME/.local/go/bin:$PATH"
  else
    echo "build.sh: go no esta instalado" >&2
    exit 1
  fi
fi

VERSION="$(cat VERSION 2>/dev/null || echo 0.0.0)"
OUT="../bin"
mkdir -p "$OUT"

# La paleta de nui se genera desde el unico archivo de tema del repo.
bash ../scripts/gen-theme-go.sh

# Verificacion minima antes de publicar binarios.
unformatted="$(gofmt -l . || true)"
if [ -n "$unformatted" ]; then
  echo "build.sh: hay archivos sin gofmt:" >&2
  printf '%s\n' "$unformatted" >&2
  exit 1
fi
go vet ./...
go test ./...

TARGETS="${NUI_TARGETS:-linux/amd64 linux/arm64 windows/amd64 windows/arm64}"
if [ "${NUI_INCLUDE_DARWIN:-0}" = "1" ] && [ -z "${NUI_TARGETS:-}" ]; then
  TARGETS="$TARGETS darwin/amd64 darwin/arm64"
fi

build_one() {
  local goos="$1" goarch="$2"
  local ext=""
  [ "$goos" = "windows" ] && ext=".exe"
  local name="nui-${goos}-${goarch}${ext}"
  echo ">> ${name} (${VERSION})"
  CGO_ENABLED=0 GOOS="$goos" GOARCH="$goarch" \
    go build -trimpath -ldflags "-s -w -X main.nuiVersion=${VERSION}" -o "$OUT/$name" .
  # -n: sin mtime ni nombre original en la cabecera gzip, para que el .gz sea
  # reproducible entre builds.
  gzip -9 -n -c "$OUT/$name" > "$OUT/$name.gz"
  # Se registra el checksum del binario descomprimido: es lo que se ejecuta y
  # no depende de la compresion. El binario sin comprimir no se versiona
  # (bin/.gitignore); se vuelve a generar en cada build.
  hash_file "$OUT/$name" "$name" >> "$OUT/SHA256SUMS.tmp"
  rm -f "$OUT/$name"
}

hash_file() {
  local f="$1" label="$2"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s  %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$label"
  else
    printf '%s  %s\n' "$(shasum -a 256 "$f" | cut -d' ' -f1)" "$label"
  fi
}

: > "$OUT/SHA256SUMS.tmp"
for t in $TARGETS; do
  build_one "${t%%/*}" "${t##*/}"
done

printf '%s\n' "$VERSION" > "$OUT/VERSION"

# bin/SHA256SUMS: checksums de los binarios que publican los instaladores
# (bash y PowerShell). Clave = nombre del binario descomprimido.
sort "$OUT/SHA256SUMS.tmp" > "$OUT/SHA256SUMS"
rm -f "$OUT/SHA256SUMS.tmp"

echo ">> listo: $(ls -1 "$OUT"/nui-*.gz | wc -l) binarios comprimidos (v${VERSION})"
