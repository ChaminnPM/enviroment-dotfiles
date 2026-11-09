#!/usr/bin/env bash
# build.sh - compila nui para todas las plataformas y genera bin/*.gz
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(cat VERSION 2>/dev/null || echo 0.0.0)"
OUT="../bin"
mkdir -p "$OUT"

build_one() {
  local goos="$1" goarch="$2"
  local name="nui-${goos}-${goarch}"
  echo ">> ${name} (${VERSION})"
  CGO_ENABLED=0 GOOS="$goos" GOARCH="$goarch" \
    go build -trimpath -ldflags "-s -w -X main.nuiVersion=${VERSION}" -o "$OUT/$name" .
  gzip -9 -c "$OUT/$name" > "$OUT/$name.gz"
}

build_one linux amd64
build_one linux arm64
build_one darwin amd64
build_one darwin arm64

printf '%s\n' "$VERSION" > "$OUT/VERSION"
echo ">> listo: $(ls -1 "$OUT"/nui-*.gz | wc -l) binarios comprimidos (v${VERSION})"
