#!/usr/bin/env bash
# apply-theme.sh - aplica el tema canonico (Dracula + JetBrainsMono Nerd) a
# todas las herramientas instaladas. Nunca sobrescribe configuracion de usuario
# que no este marcada como generada/gestionada por estos scripts.
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
OPENCODE_DIR="${OPENCODE_DIR:-$HOME/.config/opencode}"
export REPO_DIR OPENCODE_DIR

# shellcheck source=lib/theme.sh
source "$REPO_DIR/scripts/lib/theme.sh"
# shellcheck source=lib/dotfiles.sh
source "$REPO_DIR/scripts/lib/dotfiles.sh"

theme_load_env || exit 1
DOTFILES_ENV="$(theme_detect_env)"
export DOTFILES_ENV

MODE="all"
case "${1:-}" in
  --alacritty) MODE="alacritty" ;;
  --all|"") MODE="all" ;;
  *) printf 'Uso: %s [--alacritty|--all]\n' "$0" >&2; exit 1 ;;
esac

header='# >>> dotfiles-theme (apply-theme.sh) - no editar'
footer='# <<< dotfiles-theme'

# --- Alacritty -------------------------------------------------------------
apply_alacritty() {
  if ! command -v alacritty >/dev/null 2>&1; then
    printf '##log Alacritty no detectado; paso omitido\n'
    return 0
  fi

  local ver major minor
  ver="$(alacritty --version 2>/dev/null | sed -n 's/^Alacritty \([0-9][0-9.]*\).*/\1/p')"
  major="${ver%%.*}"
  minor="${ver#*.}"
  minor="${minor%%.*}"
  if [ "${major:-0}" -lt 0 ] || { [ "${major:-0}" -eq 0 ] && [ "${minor:-0}" -lt 13 ]; }; then
    printf '##warn Alacritty %s detectado; la config TOML requiere >= 0.13\n' "${ver:-?}"
    return 0
  fi

  local out="$HOME/.config/alacritty/alacritty.toml"
  if [ -f "$out" ] && ! grep -qF 'Generado por scripts/apply-theme.sh' "$out" 2>/dev/null; then
    printf '##log Existe config de Alacritty no gestionada en %s; no se sobrescribe\n' "$out"
    return 0
  fi

  if [ "$DOTFILES_ENV" = "windows-wsl" ]; then
    export THEME_WSL_WORKDIR="${THEME_WSL_WORKDIR:-C:\\Users\\$USER}"
    export THEME_WSL_DISTRO="${THEME_WSL_DISTRO:-Debian}"
    export THEME_WSL_HOME="${THEME_WSL_HOME:-$HOME}"
  fi

  local tmp overlay mode
  tmp="$(mktemp)"
  overlay="$REPO_DIR/config/alacritty/linux.toml.tpl"
  [ "$DOTFILES_ENV" = "windows-wsl" ] && overlay="$REPO_DIR/config/alacritty/windows-wsl.toml.tpl"

  theme_render_toml "$REPO_DIR/config/alacritty/common.toml.tpl" "$tmp"
  theme_render_toml "$overlay" - >> "$tmp"
  dotfiles_backup "$out" || return 1
  mode="$(dotfiles_file_mode "$out")"
  mkdir -p "$(dirname "$out")"
  dotfiles_atomic_write "$out" "$mode" < "$tmp"
  rm -f "$tmp"
  printf '##log Config de Alacritty aplicada (%s, tema %s)\n' "$DOTFILES_ENV" "$THEME_NAME"
}

# --- shell (~/.bashrc) -----------------------------------------------------
apply_shell() {
  local rc="$HOME/.bashrc" tmp mode
  if [ ! -f "$rc" ]; then
    mkdir -p "$(dirname "$rc")"
    : > "$rc"
    chmod 644 "$rc" 2>/dev/null || true
  fi
  dotfiles_backup "$rc" || return 1
  mode="$(dotfiles_file_mode "$rc")"
  tmp="$(mktemp)"

  {
    # Solo el cuerpo: dotfiles_managed_block agrega los marcadores.
    # Los tokens no contienen comillas simples; se escriben entrecomillados
    # para que el snippet sea legible (printf %q generaba escapes innecesarios).
    printf "export THEME_NAME='%s'\n" "$THEME_NAME"
    printf "export THEME_BG='%s'\n" "$THEME_BG"
    printf "export THEME_FG='%s'\n" "$THEME_FG"
    printf "export BAT_THEME='%s'\n" 'Dracula'
    printf "export EXA_COLORS='%s'\n" "$THEME_EZA_COLORS"
    printf "export EZA_COLORS='%s'\n" "$THEME_EZA_COLORS"
    printf "export FZF_DEFAULT_OPTS='%s'\n" "$THEME_FZF_OPTS"
    # shellcheck disable=SC2016  # el $() se escribe literal en el snippet
    printf '%s\n' 'if command -v dircolors >/dev/null 2>&1; then eval "$(dircolors -b)"; fi'
  } > "$tmp"

  if ! dotfiles_managed_block "$rc" "$header" "$footer" append "$mode" < "$tmp"; then
    rm -f "$tmp"
    printf '##warn ~/.bashrc tiene un bloque de tema incompleto; no se modifico\n'
    return 1
  fi
  rm -f "$tmp"
  printf '##log Paleta aplicada a ~/.bashrc (bat/eza/fzf/ls)\n'
}

# --- git (include que sobrevive a setup-git-identity.sh) -------------------
apply_git() {
  local dir="$HOME/.config/git" out tmp
  mkdir -p "$dir"
  out="$dir/theme.gitconfig"
  dotfiles_backup "$out" || return 1
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
# Generado por scripts/apply-theme.sh - tema $THEME_NAME. No editar a mano.
[color]
    ui = true
[color "branch"]
    current = $THEME_GREEN bold
    local = $THEME_PURPLE
    remote = $THEME_PINK
[color "diff"]
    meta = $THEME_PURPLE bold
    frag = $THEME_CYAN
    old = $THEME_RED
    new = $THEME_GREEN
    commit = $THEME_YELLOW
[color "status"]
    added = $THEME_GREEN
    changed = $THEME_YELLOW
    untracked = $THEME_PINK
EOF
  dotfiles_atomic_write "$out" 644 < "$tmp"
  rm -f "$tmp"
  printf '##log Colores de git en %s\n' "$out"
}

# --- OpenCode: solo verificar (cli.json se sincroniza desde el repo) ------
check_opencode() {
  [ -f "$OPENCODE_DIR/cli.json" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  local have
  have="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("theme",{}).get("name",""))' \
    "$OPENCODE_DIR/cli.json" 2>/dev/null || true)"
  if [ "$have" != "$THEME_NAME" ]; then
    printf '##warn OpenCode usa theme=%s, esperado %s (sync-dotfiles pull)\n' "${have:-?}" "$THEME_NAME"
  fi
}

apply_alacritty
if [ "$MODE" = "all" ]; then
  apply_shell
  apply_git
  check_opencode
  theme_write_manifest
  printf '##log Tema %s aplicado (fuente %s)\n' "$THEME_NAME" "$THEME_FONT_FAMILY"
fi
