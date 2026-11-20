#!/usr/bin/env bash
# gen-checksums.sh - genera SHA256SUMS en la raiz con los scripts que se
# ejecutan directamente (one-liner, bootstrap y utilidades).
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$REPO_DIR"

files=(
  install.sh
  bootstrap.sh
  scripts/sync.sh
  scripts/setup-git-identity.sh
  scripts/update-external-skills.sh
  scripts/apply-theme.sh
  scripts/gen-theme-go.sh
  scripts/lib/ui.sh
  scripts/lib/dotfiles.sh
  scripts/lib/theme.sh
)

missing=()
for f in "${files[@]}"; do
  [ -f "$f" ] || missing+=("$f")
done
if [ ${#missing[@]} -gt 0 ]; then
  printf 'gen-checksums.sh: faltan archivos: %s\n' "${missing[*]}" >&2
  exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "${files[@]}" > SHA256SUMS
elif command -v shasum >/dev/null 2>&1; then
  shasum -a 256 "${files[@]}" > SHA256SUMS
else
  printf 'gen-checksums.sh: se necesita sha256sum o shasum\n' >&2
  exit 1
fi

printf 'Generado %s/SHA256SUMS (%d archivos)\n' "$REPO_DIR" "${#files[@]}"
