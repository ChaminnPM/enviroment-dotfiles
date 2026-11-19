#!/usr/bin/env bash
# build.sh - compila nui y genera bin/*.gz
#
# Por defecto solo Linux (amd64/arm64): es la unica plataforma soportada.
# Para generar tambien macOS (no soportado, ver docs/PLATFORMS.md):
#   NUI_TARGETS="linux/amd64 linux/arm64 darwin/amd64 darwin/arm64" bash build.sh
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

TARGETS="${NUI_TARGETS:-linux/amd64 linux/arm64}"

build_one() {
  local goos="$1" goarch="$2"
  local name="nui-${goos}-${goarch}"
  echo ">> ${name} (${VERSION})"
  CGO_ENABLED=0 GOOS="$goos" GOARCH="$goarch" \
    go build -trimpath -ldflags "-s -w -X main.nuiVersion=${VERSION}" -o "$OUT/$name" .
  gzip -9 -c "$OUT/$name" > "$OUT/$name.gz"
}

for t in $TARGETS; do
  build_one "${t%%/*}" "${t##*/}"
done

printf '%s\n' "$VERSION" > "$OUT/VERSION"
# Checksums para que ui_install_ui/install.sh puedan verificar las descargas.
if command -v sha256sum >/dev/null 2>&1; then
  ( cd "$OUT" && sha256sum nui-*.gz > SHA256SUMS )
elif command -v shasum >/dev/null 2>&1; then
  ( cd "$OUT" && shasum -a 256 nui-*.gz > SHA256SUMS )
fi
echo ">> listo: $(ls -1 "$OUT"/nui-*.gz | wc -l) binarios comprimidos (v${VERSION})"
