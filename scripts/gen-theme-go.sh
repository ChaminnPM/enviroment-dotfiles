#!/usr/bin/env bash
# gen-theme-go.sh - genera ui/theme_generated.go desde config/theme/dracula.env.
# Uso: bash scripts/gen-theme-go.sh [archivo_de_salida]
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
ENV_FILE="${THEME_ENV_FILE:-$REPO_DIR/config/theme/dracula.env}"
OUT="${1:-$REPO_DIR/ui/theme_generated.go}"

python3 - "$ENV_FILE" "$OUT" <<'PY'
import sys

env = {}
for raw in open(sys.argv[1], encoding="utf-8"):
    line = raw.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    key, value = line.split("=", 1)
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
        value = value[1:-1]
    env[key.strip()] = value

keys = [
    "THEME_BG", "THEME_CURRENT", "THEME_FG", "THEME_COMMENT",
    "THEME_RED", "THEME_GREEN", "THEME_ORANGE", "THEME_YELLOW",
    "THEME_PURPLE", "THEME_PINK", "THEME_CYAN",
]
missing = [k for k in keys if not env.get(k)]
if missing:
    sys.exit("faltan tokens en el tema: " + ", ".join(missing))

def goname(key):
    return "theme" + "".join(p.capitalize() for p in key[6:].split("_"))

lines = [
    "// Code generated from config/theme/dracula.env by scripts/gen-theme-go.sh. DO NOT EDIT.",
    "",
    "package main",
    "",
    "const (",
]
lines.extend('\t%s = "%s"' % (goname(k), env[k]) for k in keys)
lines.append(")")
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(lines) + "\n")
PY

# gofmt alinea las constantes; sin esto `gofmt -l` fallaria en CI.
if command -v gofmt >/dev/null 2>&1; then
  gofmt -w "$OUT"
elif [ -x "$HOME/.local/go/bin/gofmt" ]; then
  "$HOME/.local/go/bin/gofmt" -w "$OUT"
fi

printf 'Generado %s desde %s\n' "$OUT" "$ENV_FILE"
