#!/usr/bin/env bash
# ui.sh - helpers de UI con nui (bubbletea + lipgloss) y fallback ANSI.
# nui resuelve TTY (/dev/tty) internamente, por lo que funciona aunque el
# script este corriendo con stdin conectado a un pipe (curl | bash).

LOG_DIR="${LOG_DIR:-$HOME/.local/state/enviroment-dotfiles/logs}"
export VERBOSE="${VERBOSE:-0}"
export UI_APP_TITLE="${UI_APP_TITLE:-AGENTS ENVIRONMENT}"
export NUI_BASE_URL="${NUI_BASE_URL:-https://raw.githubusercontent.com/ChaminnPM/enviroment-dotfiles/main}"

UI_OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
UI_ARCH="$(uname -m)"
case "$UI_ARCH" in
  x86_64|amd64) UI_ARCH=amd64 ;;
  aarch64|arm64) UI_ARCH=arm64 ;;
  *) UI_ARCH=amd64 ;;
esac

# --- reporte final (pasos instalados / avisos / errores) -----------------
REPORT_OK=()
REPORT_WARN=()
REPORT_ERR=()
REPORT_INFO=()
report_ok()   { REPORT_OK+=("$*"); }
report_warn() { REPORT_WARN+=("$*"); }
report_err()  { REPORT_ERR+=("$*"); }
report_info() { REPORT_INFO+=("$*"); }

ensure_log_dir() {
  mkdir -p "$LOG_DIR" 2>/dev/null || true
}

# --- binario nui ---------------------------------------------------------
ui_bin() {
  if [ -n "${UI_BIN:-}" ]; then printf '%s' "$UI_BIN"; return 0; fi
  if command -v nui >/dev/null 2>&1; then command -v nui; return 0; fi
  if [ -x "$HOME/.local/bin/nui" ]; then printf '%s' "$HOME/.local/bin/nui"; return 0; fi
  if [ -n "${REPO_DIR:-}" ] && [ -x "$REPO_DIR/bin/nui-$UI_OS-$UI_ARCH" ]; then
    printf '%s' "$REPO_DIR/bin/nui-$UI_OS-$UI_ARCH"
    return 0
  fi
  return 1
}

ui_have() { ui_bin >/dev/null 2>&1; }
ui_gum_available() { ui_have; } # compat con scripts antiguos

# Hay TTY utilizable (stdin directo o /dev/tty)?
ui_interactive() {
  [ -t 0 ] && return 0
  [ -e /dev/tty ] && [ -r /dev/tty ] && [ -w /dev/tty ]
}

ui_install_ui() {
  local dest="$HOME/.local/bin/nui"
  local localgz="${REPO_DIR:-}/bin/nui-$UI_OS-$UI_ARCH.gz"
  local want="${NUI_VERSION:-}" have=""

  if [ -z "$want" ] && [ -n "${REPO_DIR:-}" ] && [ -f "$REPO_DIR/bin/VERSION" ]; then
    want="$(cat "$REPO_DIR/bin/VERSION" 2>/dev/null || true)"
  fi
  if ui_have; then
    have="$("$(ui_bin)" version 2>/dev/null | awk 'NR==1{print $2}')"
    if [ -n "$want" ] && [ "$have" = "$want" ]; then
      return 0
    fi
  fi
  if [ -z "$want" ] && command -v curl >/dev/null 2>&1; then
    want="$(curl -fsSL --max-time 10 "$NUI_BASE_URL/bin/VERSION" 2>/dev/null || true)"
    if ui_have && [ -n "$want" ] && [ "$have" = "$want" ]; then
      return 0
    fi
  fi

  if [ -f "$localgz" ]; then
    # repo local: instalar sin red
    if ! ui_logged "Instalando nui..." "mkdir -p '$HOME/.local/bin' && gzip -dc '$localgz' > '$dest' && chmod 755 '$dest'"; then
      return 1
    fi
  else
    ui_ensure_cmd curl curl || return 1
    ui_ensure_cmd gzip gzip || return 1
    local url="$NUI_BASE_URL/bin/nui-$UI_OS-$UI_ARCH.gz"
    if ! ui_logged "Instalando nui..." "mkdir -p '$HOME/.local/bin' && curl -fsSL '$url' -o '$dest.gz' && gzip -dc '$dest.gz' > '$dest' && chmod 755 '$dest' && rm -f '$dest.gz'"; then
      return 1
    fi
  fi
  export PATH="$HOME/.local/bin:$PATH"
  export UI_BIN="$dest"
  ui_have
}
ui_install_gum() { ui_install_ui; } # compat

# --- utilidades ----------------------------------------------------------
ui_width() {
  local cols
  cols="$(tput cols 2>/dev/null || true)"
  [ -z "$cols" ] && cols="$(stty size 2>/dev/null | awk '{print $2}' || true)"
  cols="${cols:-80}"
  cols=$((cols - 2))
  [ "$cols" -lt 44 ] && cols=44
  printf '%s' "$cols"
}

ui_wrap() {
  local width="$1"
  shift
  local inner=$((width - 6))
  [ "$inner" -lt 24 ] && inner=24
  printf '%s\n' "$*" | fold -s -w "$inner" || true
}

# Limpia pantalla + scrollback (sin redirigir a /dev/null: ese era el bug).
ui_clear() {
  [ "${VERBOSE:-0}" = "1" ] && return 0
  if ui_have; then
    "$(ui_bin)" clear
  elif [ -t 1 ]; then
    printf '\033[3J\033[2J\033[H'
  fi
}

# --- pantallas -----------------------------------------------------------
ui_banner() {
  ensure_log_dir
  if ui_have; then
    "$(ui_bin)" banner "$@"
    return 0
  fi
  local w
  w="$(ui_width)"
  printf '\n'
  printf '%s\n' "$(printf '%*s' "$w" '' | tr ' ' '-')"
  printf '%s\n' "$*"
  printf '%s\n' "$(printf '%*s' "$w" '' | tr ' ' '-')"
}

# Cada paso: limpia TODO lo anterior y pinta solo el paso actual (<=6 lineas).
ui_step_start() {
  local step="$1" title="$2"
  if [ "${VERBOSE:-0}" = "1" ]; then
    printf '\n== %s: %s ==\n' "$step" "$title"
    return 0
  fi
  if ui_have; then
    "$(ui_bin)" step "$UI_APP_TITLE" "$step: $title"
  else
    ui_clear
    ui_banner "$UI_APP_TITLE" "$step: $title"
  fi
}

ui_step_done() {
  ui_ok "$*"
  report_ok "$*"
  if [ "${VERBOSE:-0}" != "1" ] && [ -t 1 ]; then
    sleep 0.35
  fi
}

ui_title() {
  if ui_have; then
    "$(ui_bin)" box --color accent --align center "$@"
    return 0
  fi
  printf '\n== %s ==\n' "$*"
}

ui_section() {
  if ui_have; then
    "$(ui_bin)" style --foreground 63 --bold -- "$*"
  else
    printf '\033[1;34m%s\033[0m\n' "$*"
  fi
}

# --- mensajes ------------------------------------------------------------
ui_info() {
  if ui_have; then
    "$(ui_bin)" log --level info "$*"
  else
    printf '[INFO] %s\n' "$*"
  fi
}

ui_ok() {
  if ui_have; then
    "$(ui_bin)" log --level ok "$*"
  else
    printf '[OK] %s\n' "$*"
  fi
}

ui_warn() {
  report_warn "$*"
  if ui_have; then
    "$(ui_bin)" log --level warn "$*"
  else
    printf '[WARN] %s\n' "$*" >&2
  fi
}

ui_error() {
  report_err "$*"
  if ui_have; then
    "$(ui_bin)" log --level error "$*"
  else
    printf '[ERROR] %s\n' "$*" >&2
  fi
}

# Error fatal: registra, muestra el reporte final y sale con 1.
ui_fatal() {
  ui_error "$*"
  ui_report || true
  exit 1
}

ui_dim() {
  if ui_have; then
    "$(ui_bin)" style --foreground 240 -- "$*"
  else
    printf '%s\n' "$*"
  fi
}

# --- interaccion ---------------------------------------------------------
ui_ask() {
  if ui_have; then
    "$(ui_bin)" confirm "$*"
    return $?
  fi
  if [ -t 0 ]; then
    local a
    read -rp "$* [y/N]: " a
    [[ "${a,,}" == y* ]]
    return
  fi
  return 1
}

ui_input() {
  if ui_have; then
    "$(ui_bin)" input --prompt "$1 " --placeholder "${2:-}"
    return $?
  fi
  if [ -t 0 ]; then
    local v
    read -rp "$1 " v
    printf '%s' "$v"
    return 0
  fi
  printf '%s' "${UI_INPUT_DEFAULT:-}"
}

ui_choose() {
  local prompt="$1"
  shift
  if ui_have; then
    "$(ui_bin)" choose --no-limit --height 12 --header "$prompt" -- "$@" || true
    return 0
  fi
  if [ -t 0 ]; then
    printf '%s\n' "$@"
    local sel
    read -rp "Escribe separados por espacio (o Enter para omitir): " sel
    printf '%s\n' $sel
  fi
}

ui_pager() {
  if ui_have; then
    "$(ui_bin)" pager "$@"
    return 0
  fi
  if command -v less >/dev/null 2>&1; then
    less -R "$@"
  else
    cat "$@"
  fi
}

# --- errores con log -----------------------------------------------------
ui_tail_error() {
  local title="$1" log="$2"
  local body
  ensure_log_dir
  if [ -f "$log" ]; then
    body="$title
Log: $log
$(tail -n 15 "$log" 2>/dev/null || true)"
  else
    body="$title
Log no disponible: $log"
  fi
  if ui_have; then
    "$(ui_bin)" box --color err -- "$body"
  else
    printf '\n[ERROR] %s\n' "$body" >&2
  fi
}

ui_summary() {
  if ui_have; then
    "$(ui_bin)" box --color ok --align center "$@"
    return 0
  fi
  printf '\n%s\n' "$*"
}

# --- comandos con log ----------------------------------------------------
ui_logged() {
  local title="$1" cmd="$2"
  local log
  ensure_log_dir
  log="$LOG_DIR/$(date +%Y%m%d-%H%M%S)-$$.log"

  if [ "${VERBOSE:-0}" = "1" ]; then
    eval "$cmd"
    return $?
  fi

  if ui_have; then
    if "$(ui_bin)" spin --title "$title" -- bash -c 'eval "$1" >"$2" 2>&1' _ "$cmd" "$log"; then
      return 0
    fi
    ui_tail_error "$title" "$log"
    return 1
  fi

  if bash -c 'eval "$1" >"$2" 2>&1' _ "$cmd" "$log"; then
    return 0
  fi
  ui_tail_error "$title" "$log"
  return 1
}

# --- dependencias --------------------------------------------------------
ui_apt_prefix() {
  if [ "${EUID:-$(id -u)}" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
    printf 'sudo '
  fi
}

ui_ensure_cmd() {
  local cmd="$1" pkg="${2:-$1}"
  command -v "$cmd" >/dev/null 2>&1 && return 0
  local apt_prefix
  apt_prefix="$(ui_apt_prefix)"
  ui_logged "Instalando $pkg..." "${apt_prefix}apt-get update >/dev/null 2>&1 || true; ${apt_prefix}apt-get install -y $pkg >/dev/null 2>&1"
}

# --- SSH sin prompts -----------------------------------------------------
ui_seed_known_hosts() {
  local host tmp_known
  mkdir -p "$HOME/.ssh" 2>/dev/null || true
  chmod 700 "$HOME/.ssh" 2>/dev/null || true
  touch "$HOME/.ssh/known_hosts" 2>/dev/null || true
  tmp_known="$(mktemp)"
  for host in github.com bitbucket.org; do
    ssh-keyscan -t ed25519,rsa "$host" >> "$tmp_known" 2>/dev/null || true
  done
  if [ -s "$tmp_known" ]; then
    sort -u "$HOME/.ssh/known_hosts" "$tmp_known" > "${tmp_known}.sorted" 2>/dev/null || true
    if [ -s "${tmp_known}.sorted" ]; then
      cat "${tmp_known}.sorted" > "$HOME/.ssh/known_hosts" 2>/dev/null || true
    fi
  fi
  rm -f "$tmp_known" "${tmp_known}.sorted" 2>/dev/null || true
}

ui_ssh_test() {
  local title="$1" target="$2"
  ui_seed_known_hosts
  # GitHub/Bitbucket devuelven exit 1 incluso autenticando bien: evaluar por mensaje.
  ui_logged "$title" "out=\$(ssh -T -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10 '$target' 2>&1 || true); printf '%s\n' \"\$out\"; printf '%s\n' \"\$out\" | grep -Eiq 'successfully authenticated|logged in as'"
}

# --- reporte final -------------------------------------------------------
ui_report() {
  ensure_log_dir
  local args=() x
  for x in ${REPORT_OK[@]+"${REPORT_OK[@]}"}; do args+=(--ok "$x"); done
  for x in ${REPORT_WARN[@]+"${REPORT_WARN[@]}"}; do args+=(--warn "$x"); done
  for x in ${REPORT_ERR[@]+"${REPORT_ERR[@]}"}; do args+=(--err "$x"); done
  for x in ${REPORT_INFO[@]+"${REPORT_INFO[@]}"}; do args+=(--info "$x"); done
  args+=(--info "Logs: $LOG_DIR")

  if ui_have; then
    if [ "${VERBOSE:-0}" = "1" ]; then
      NUI_NO_CLEAR=1 "$(ui_bin)" report "${args[@]}"
    else
      "$(ui_bin)" report "${args[@]}"
    fi
    return $?
  fi

  # fallback textual
  if [ "${VERBOSE:-0}" != "1" ] && [ -t 1 ]; then
    printf '\033[3J\033[2J\033[H'
  fi
  printf '\n== REPORTE FINAL ==\n'
  for x in ${REPORT_OK[@]+"${REPORT_OK[@]}"}; do printf '  [OK]   %s\n' "$x"; done
  for x in ${REPORT_WARN[@]+"${REPORT_WARN[@]}"}; do printf '  [WARN] %s\n' "$x"; done
  for x in ${REPORT_ERR[@]+"${REPORT_ERR[@]}"}; do printf '  [ERR]  %s\n' "$x"; done
  for x in ${REPORT_INFO[@]+"${REPORT_INFO[@]}"}; do printf '  %s\n' "$x"; done
  printf '  Logs: %s\n' "$LOG_DIR"
  [ ${#REPORT_ERR[@]} -gt 0 ] && return 1
  return 0
}

# --- plan de pasos + panel (nui steps run) -------------------------------
# Uso:
#   ui_panel_begin
#   ui_panel_note "Comandos: sync-dotfiles pull/push"
#   ui_panel_step "Dependencias base" --estimate 60 <<'EOF'
#   ...comandos...
#   EOF
#   ui_panel_step "Identidad Git" --interactive <<'EOF'
#   bash "$REPO_DIR/scripts/setup-git-identity.sh"
#   EOF
#   ui_panel_run
#
# Cada cuerpo se ejecuta con bash (set -euo pipefail) y puede emitir:
#   ##progress N   porcentaje del paso
#   ##log T        linea limpia en el panel
#   ##title T      renombra el paso en vivo
#   ##warn T       marca aviso y continua
# ui_panel_run devuelve 1 si hubo errores (y ya imprime el reporte final).
PANEL_DIR=""
PANEL_STEPS=()
PANEL_NOTES=()

ui_panel_begin() {
  ensure_log_dir
  PANEL_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nui-steps.XXXXXX")" || return 1
  PANEL_STEPS=()
  PANEL_NOTES=()
}

ui_panel_note() { PANEL_NOTES+=("$*"); }

ui_panel_step() {
  local title="$1"
  shift
  local optional=0 interactive=0 estimate=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --optional) optional=1 ;;
      --interactive) interactive=1 ;;
      --estimate) shift; estimate="${1:-0}" ;;
      *) ui_warn "ui_panel_step: opcion desconocida: $1" ;;
    esac
    shift
  done
  [ -n "$PANEL_DIR" ] || ui_panel_begin

  local n=$(( ${#PANEL_STEPS[@]} + 1 ))
  local file="$PANEL_DIR/step-$n.sh"
  {
    printf 'set -euo pipefail\n'
    cat
  } > "$file"

  local b64
  b64="$(printf '%s' "$title" | base64 | tr -d '\n')"
  PANEL_STEPS+=("$b64|$optional|$interactive|$estimate|$file")
}

# Filtra directivas y guarda el log del paso (fallback sin panel).
_ui_panel_filter() {
  local log="$1" line
  while IFS= read -r line; do
    printf '%s\n' "$line" >> "$log"
    case "$line" in
      '##progress '*) ;;
      '##log '*) printf '%s\n' "${line#'##log '}" ;;
      '##title '*) ;;
      '##warn '*)
        printf '[WARN] %s\n' "${line#'##warn '}"
        : > "$log.warn"
        ;;
      *) printf '%s\n' "$line" ;;
    esac
  done
}

# Ejecuta el plan sin panel (nui ausente, VERBOSE o terminal no interactiva).
_ui_panel_run_plain() {
  local manifest="$1" title="$2"
  local total=${#PANEL_STEPS[@]} i=0
  local b64t opt intr est path t log rc

  REPORT_OK=(); REPORT_WARN=(); REPORT_ERR=()
  ui_clear
  ui_banner "$title"
  printf '\nLogs: %s\n' "$LOG_DIR"

  while IFS='|' read -r b64t opt intr est path; do
    [ -n "$path" ] || continue
    i=$((i + 1))
    t="$(printf '%s' "$b64t" | base64 -d)"
    log="$LOG_DIR/steps-$(date +%Y%m%d-%H%M%S)-$(printf '%02d' "$i")-$(printf '%s' "$t" | tr -cs '[:alnum:]' '-' | cut -c1-40).log"
    rm -f "$log.warn"

    printf '\n\033[1m== [%d/%d] %s ==\033[0m\n' "$i" "$total" "$t"

    if [ "$intr" = "1" ]; then
      if [ -e /dev/tty ] && [ -r /dev/tty ]; then
        bash "$path" < /dev/tty
      else
        bash "$path"
      fi
      rc=$?
    else
      bash "$path" 2>&1 | _ui_panel_filter "$log"
      rc=${PIPESTATUS[0]}
    fi

    if [ "$rc" -eq 0 ]; then
      if [ -f "$log.warn" ]; then
        report_warn "$t"
      else
        report_ok "$t"
      fi
      continue
    fi
    if [ "$opt" = "1" ]; then
      report_warn "$t: falló (opcional)"
      continue
    fi
    report_err "$t: exit $rc"
    break
  done < "$manifest"

  for x in ${PANEL_NOTES[@]+"${PANEL_NOTES[@]}"}; do report_info "$x"; done
  ui_report
}

# ui_panel_run [--title T] [--plain]: ejecuta el plan y muestra el reporte.
ui_panel_run() {
  local title="${UI_APP_TITLE:-INSTALACIÓN}" plain=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --title) shift; title="${1:-$title}" ;;
      --plain) plain=1 ;;
      *) ui_warn "ui_panel_run: opcion desconocida: $1" ;;
    esac
    shift
  done

  if [ ${#PANEL_STEPS[@]} -eq 0 ]; then
    ui_error "No hay pasos para ejecutar"
    return 1
  fi

  local manifest="$PANEL_DIR/manifest" notes="$PANEL_DIR/notes" plan="$PANEL_DIR/plan.json"
  local entry
  for entry in "${PANEL_STEPS[@]}"; do printf '%s\n' "$entry"; done > "$manifest"
  for entry in ${PANEL_NOTES[@]+"${PANEL_NOTES[@]}"}; do printf '%s\n' "$entry"; done > "$notes"

  if ! PANEL_TITLE="$title" python3 - "$manifest" "$notes" "$plan" <<'PY'
import base64, json, os, shlex, sys

manifest, notes_path, out = sys.argv[1:4]
steps = []
with open(manifest, encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        b64title, optional, interactive, estimate, path = line.split("|")
        steps.append({
            "title": base64.b64decode(b64title).decode("utf-8"),
            "cmd": "bash " + shlex.quote(path),
            "optional": optional == "1",
            "interactive": interactive == "1",
            "estimate": int(estimate or 0),
        })

notes = []
try:
    with open(notes_path, encoding="utf-8") as fh:
        notes = [l.rstrip("\n") for l in fh if l.strip()]
except FileNotFoundError:
    pass

with open(out, "w", encoding="utf-8") as fh:
    json.dump({
        "title": os.environ.get("PANEL_TITLE", "INSTALACIÓN"),
        "notes": notes,
        "steps": steps,
    }, fh, ensure_ascii=False)
PY
  then
    ui_error "No se pudo generar el plan de pasos"
    return 1
  fi

  if [ "${PLAN_ONLY:-0}" = "1" ]; then
    cat "$plan"
    if [ "${PLAN_KEEP:-0}" != "1" ]; then
      rm -rf "$PANEL_DIR"
      PANEL_DIR=""
      PANEL_STEPS=()
      PANEL_NOTES=()
    fi
    return 0
  fi

  local rc=0 verbose_plain="$plain"
  [ "${VERBOSE:-0}" = "1" ] && verbose_plain=1

  if ui_have && ui_interactive; then
    local extra=()
    [ "$verbose_plain" = "1" ] && extra+=(--plain)
    if "$(ui_bin)" steps run --plan "$plan" --log-dir "$LOG_DIR" --title "$title" \
        ${extra[@]+"${extra[@]}"}; then
      rc=0
    else
      rc=$?
    fi
  else
    if _ui_panel_run_plain "$manifest" "$title"; then
      rc=0
    else
      rc=$?
    fi
  fi

  rm -rf "$PANEL_DIR"
  PANEL_DIR=""
  PANEL_STEPS=()
  PANEL_NOTES=()
  return "$rc"
}
