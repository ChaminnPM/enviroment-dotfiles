#!/usr/bin/env bash
# update-external-skills.sh - consulta y actualiza skills externas (graphify, security-audit)
# Uso: bash scripts/update-external-skills.sh [check|update]
set -euo pipefail

MODE="${1:-check}"
REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
SKILLS_DIR="$REPO_DIR/config/opencode/skills"

# UI: nui (bubbletea) via ui.sh, con fallback textual.
# shellcheck source=lib/ui.sh
source "$REPO_DIR/scripts/lib/ui.sh"

# Lee un campo de VERSION.json sin requerir jq
read_version_field() {
  local file="$1" field="$2"
  python3 - "$file" "$field" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
print(data.get(sys.argv[2], ""))
PY
}

check_graphify() {
  local version_file="$SKILLS_DIR/graphify/VERSION.json"
  local current vendored latest_tag latest_main
  current="$(read_version_field "$version_file" "upstream_ref")"
  vendored="$(read_version_field "$version_file" "vendored_ref")"
  latest_tag="$(git ls-remote --tags https://github.com/Graphify-Labs/graphify.git 2>/dev/null | awk '{print $2}' | sed 's#refs/tags/##' | grep -v '\^{}' | sort -V | tail -n1)"
  latest_main="$(git ls-remote https://github.com/Graphify-Labs/graphify.git refs/heads/main 2>/dev/null | awk '{print $1}')"
  ui_title "graphify"
  ui_info "Upstream ref : ${current:-?}"
  ui_info "Vendored ref : ${vendored:-?}"
  ui_info "Ultimo tag   : ${latest_tag:-?}"
  ui_info "main HEAD    : ${latest_main:-?}"
  if [[ "$vendored" == custom* ]]; then
    ui_warn "La copia local es personalizada (references/). Revisar diff y estabilidad antes de actualizar."
  fi
  if [[ -n "$latest_tag" && "$current" != "$latest_tag" ]]; then
    ui_warn "Hay una version nueva (tag $latest_tag). Revisar estabilidad antes de actualizar."
    if [[ "$MODE" == "update" ]] && ui_ask "Actualizar graphify a $latest_tag?"; then
      local tmp
      tmp="$(mktemp -d)"
      git clone --depth 1 --branch "$latest_tag" https://github.com/Graphify-Labs/graphify.git "$tmp/graphify" >/dev/null 2>&1
      cp "$tmp/graphify/skills/graphify/skill.md" "$SKILLS_DIR/graphify/SKILL.md"
      python3 - "$version_file" "$latest_tag" <<'PY'
import json, sys
path, ref = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)
data["upstream_ref"] = ref
data["updated_at"] = __import__("datetime").datetime.now().isoformat(timespec="seconds")
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
      rm -rf "$tmp"
      ui_ok "graphify actualizado a $latest_tag"
    fi
  else
    ui_ok "graphify al dia (segun tag estable)."
  fi
}

check_security_audit() {
  local version_file="$SKILLS_DIR/security-audit/VERSION.json"
  local current latest_main
  current="$(read_version_field "$version_file" "upstream_ref")"
  latest_main="$(git ls-remote https://github.com/cloudflare/security-audit-skill.git refs/heads/main 2>/dev/null | awk '{print $1}')"
  ui_title "security-audit"
  ui_info "Vendored ref : ${current:-?}"
  ui_info "main HEAD    : ${latest_main:-?}"
  if [[ -n "$latest_main" && "$current" != "$latest_main" ]]; then
    ui_warn "Hay cambios en upstream (main $latest_main). Revisar estabilidad antes de actualizar."
    if [[ "$MODE" == "update" ]] && ui_ask "Actualizar security-audit desde main?"; then
      local tmp
      tmp="$(mktemp -d)"
      git clone --depth 1 https://github.com/cloudflare/security-audit-skill.git "$tmp/repo" >/dev/null 2>&1
      rsync -a --delete "$tmp/repo/skills/security-audit/" "$SKILLS_DIR/security-audit/"
      python3 - "$version_file" "$latest_main" <<'PY'
import json, sys
path, ref = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)
data["upstream_ref"] = ref
data["updated_at"] = __import__("datetime").datetime.now().isoformat(timespec="seconds")
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
      rm -rf "$tmp"
      ui_ok "security-audit actualizado desde main"
    fi
  else
    ui_ok "security-audit al dia."
  fi
}

ui_title "Skills externas"
check_graphify
check_security_audit
ui_title "Fin"
