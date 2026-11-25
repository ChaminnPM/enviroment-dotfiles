#!/usr/bin/env bash
# ui.sh - helpers de UI con nui (bubbletea + lipgloss) y fallback ANSI.
# nui resuelve TTY (/dev/tty) internamente, por lo que funciona aunque el
# script este corriendo con stdin conectado a un pipe (curl | bash).

LOG_DIR="${LOG_DIR:-$HOME/.local/state/enviroment-dotfiles/logs}"
export VERBOSE="${VERBOSE:-0}"
export UI_APP_TITLE="${UI_APP_TITLE:-AGENTS ENVIRONMENT}"
export NUI_BASE_URL="${NUI_BASE_URL:-https://raw.githubusercontent.com/ChaminnPM/enviroment-dotfiles/main}"
# scripts/lib/ui.sh -> raiz del repo, para que ui_seed_known_hosts y
# ui_install_ui encuentren config/ssh y bin/ aunque el llamador no exporte
# REPO_DIR (por ejemplo, setup-git-identity.sh en modo standalone).
if [ -z "${REPO_DIR:-}" ]; then
  REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"
fi
export REPO_DIR

# Helpers de dotfiles (respaldos, escritura atomica, PATH persistente).
if [ -n "${REPO_DIR:-}" ] && [ -f "$REPO_DIR/scripts/lib/dotfiles.sh" ]; then
  # shellcheck source=lib/dotfiles.sh
  . "$REPO_DIR/scripts/lib/dotfiles.sh"
fi

# Solo Linux y WSL estan soportados. En macOS/Windows se avisa y se aborta
# antes de tocar nada (ver docs/PLATFORMS.md).
if command -v dotfiles_platform >/dev/null 2>&1; then
  UI_PLATFORM="$(dotfiles_platform)"
else
  case "$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')" in
    linux) UI_PLATFORM=linux ;;
    darwin) UI_PLATFORM=darwin ;;
    mingw*|msys*|cygwin*) UI_PLATFORM=windows ;;
    *) UI_PLATFORM=unknown ;;
  esac
fi

case "$UI_PLATFORM" in
  linux) UI_OS=linux ;;
  wsl) UI_OS=linux ;;
  darwin) UI_OS=darwin ;;
  *) UI_OS=unsupported ;;
esac
UI_ARCH="$(uname -m)"
case "$UI_ARCH" in
  x86_64|amd64) UI_ARCH=amd64 ;;
  aarch64|arm64) UI_ARCH=arm64 ;;
  *) UI_ARCH=amd64 ;;
esac
export UI_PLATFORM UI_OS UI_ARCH

# Modos globales: NUI_NONINTERACTIVE=1 evita cualquier prompt; NUI_NO_COLOR=1
# desactiva color; NUI_DRY_RUN=1 imprime el plan sin ejecutarlo.
export NUI_NONINTERACTIVE="${NUI_NONINTERACTIVE:-0}"
export NUI_NO_COLOR="${NUI_NO_COLOR:-0}"
export NUI_DRY_RUN="${NUI_DRY_RUN:-0}"
export NO_COLOR="${NO_COLOR:-}"
if [ "$NUI_NO_COLOR" = "1" ]; then export NO_COLOR=1; fi
export CLICOLOR="${CLICOLOR:-}"

# Los logs se limitan al cerrar (N lineas) para que crezcan sin limite;
# LOG_KEEP_ALL=1 conserva el log completo.
LOG_KEEP_LINES="${LOG_KEEP_LINES:-500}"
export LOG_KEEP_LINES

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
  # Los logs pueden contener salida de comandos con datos sensibles: se crean
  # con permisos restrictivos desde el inicio (umask) y se refuerza con chmod.
  umask 077
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  chmod 700 "$LOG_DIR" 2>/dev/null || true
}

# Trunca un log ya cerrado a las ultimas LOG_KEEP_LINES lineas. Se llama al
# final de cada captura; mientras el comando corre el log esta intacto.
_ui_cap_log() {
  local log="$1" lines tmp
  [ "${LOG_KEEP_ALL:-0}" = "1" ] && return 0
  [ -f "$log" ] || return 0
  case "$LOG_KEEP_LINES" in ''|*[!0-9]*|0) return 0 ;; esac
  lines="$(wc -l < "$log" 2>/dev/null || echo 0)"
  [ "$lines" -le "$LOG_KEEP_LINES" ] && return 0
  tmp="$(mktemp "${log}.cap.XXXXXX")" || return 0
  if tail -n "$LOG_KEEP_LINES" "$log" > "$tmp"; then
    mv -f "$tmp" "$log" || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
}

# --- binario nui ---------------------------------------------------------
ui_bin() {
  if [ -n "${UI_BIN:-}" ] && [ -x "$UI_BIN" ]; then printf '%s' "$UI_BIN"; return 0; fi
  if command -v nui >/dev/null 2>&1; then command -v nui; return 0; fi
  if [ -x "$HOME/.local/bin/nui" ]; then printf '%s' "$HOME/.local/bin/nui"; return 0; fi
  if [ -n "${REPO_DIR:-}" ] && [ "$UI_OS" != "unsupported" ] && [ -x "$REPO_DIR/bin/nui-$UI_OS-$UI_ARCH" ]; then
    printf '%s' "$REPO_DIR/bin/nui-$UI_OS-$UI_ARCH"
    return 0
  fi
  return 1
}

ui_have() { ui_bin >/dev/null 2>&1; }

# Hay TTY utilizable (stdin directo o /dev/tty)?
ui_interactive() {
  [ -t 0 ] && return 0
  [ -e /dev/tty ] && [ -r /dev/tty ] && [ -w /dev/tty ]
}

ui_install_ui() {
  local dest="$HOME/.local/bin/nui"
  local localgz="${REPO_DIR:-}/bin/nui-$UI_OS-$UI_ARCH.gz"
  local want="${NUI_VERSION:-}" have=""

  if [ "$UI_OS" = "unsupported" ]; then
    ui_error "Plataforma $UI_PLATFORM no soportada por nui (solo Linux/WSL; ver docs/PLATFORMS.md)"
    return 1
  fi

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
    want="$(curl -fsSL --retry 3 --max-time 10 "$NUI_BASE_URL/bin/VERSION" 2>/dev/null || true)"
    if ui_have && [ -n "$want" ] && [ "$have" = "$want" ]; then
      return 0
    fi
  fi

  # Importante: no usar ui_logged (spinner de nui) ni escribir directamente
  # sobre $dest, porque ese binario puede estar en ejecucion (ETXTBSY).
  # Se arma en un temporal y se reemplaza con mv.
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/nui.XXXXXX")" || return 1
  ui_info "Instalando nui${want:+ $want}..."

  if [ -f "$localgz" ]; then
    # repo local: instalar sin red
    if ! gzip -dc "$localgz" > "$tmp" 2>/dev/null; then
      rm -f "$tmp"
      ui_error "No se pudo descomprimir nui desde el repo local"
      return 1
    fi
  else
    ui_ensure_cmd curl curl || { rm -f "$tmp"; return 1; }
    ui_ensure_cmd gzip gzip || { rm -f "$tmp"; return 1; }
    local url="$NUI_BASE_URL/bin/nui-$UI_OS-$UI_ARCH.gz"
    if ! curl -fsSL --retry 3 --max-time 120 "$url" -o "$tmp.gz" 2>/dev/null; then
      rm -f "$tmp" "$tmp.gz"
      ui_error "No se pudo descargar nui desde $url"
      return 1
    fi
    if ! gzip -dc "$tmp.gz" > "$tmp" 2>/dev/null; then
      rm -f "$tmp" "$tmp.gz"
      ui_error "No se pudo descomprimir nui"
      return 1
    fi
    rm -f "$tmp.gz"
  fi

  if ! chmod 755 "$tmp" || ! mkdir -p "$HOME/.local/bin" || ! mv -f "$tmp" "$dest"; then
    rm -f "$tmp"
    ui_error "No se pudo instalar nui en $dest"
    return 1
  fi
  export PATH="$HOME/.local/bin:$PATH"
  export UI_BIN="$dest"
  ui_ok "nui $("$(ui_bin)" version 2>/dev/null | awk 'NR==1{print $2}') instalado"
  return 0
}

# ui_supports_steps: nui >= 0.2.0 (subcomando 'steps run').
ui_supports_steps() {
  local v
  v="$("$(ui_bin)" version 2>/dev/null | awk 'NR==1{print $2}')"
  case "$v" in
    0.2.*|0.[3-9].*|[1-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

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
# Lee de /dev/tty cuando stdin viene de un pipe (curl | bash) y no estamos en
# modo no interactivo.
_ui_read() {
  [ "${NUI_NONINTERACTIVE:-0}" = "1" ] && return 1
  if [ -t 0 ] || [ ! -r /dev/tty ]; then
    read "$@"
  else
    read "$@" < /dev/tty
  fi
}

ui_ask() {
  if [ "${NUI_NONINTERACTIVE:-0}" = "1" ]; then return 1; fi
  if ui_have; then
    "$(ui_bin)" confirm "$*"
    return $?
  fi
  if [ -t 0 ] || [ -r /dev/tty ]; then
    local a
    _ui_read -rp "$* [y/N]: " a || return 1
    [[ "${a,,}" == y* ]]
    return
  fi
  return 1
}

# ui_panel_confirm <id> <pregunta>: confirmacion dentro del panel de nui.
# El paso emite "##confirm <id> <pregunta>" y espera a que el TUI escriba la
# respuesta en $NUI_STATE_DIR/confirm-<id>.env. Asi no se cede la terminal ni
# se lanza un segundo programa bubbletea sobre el mismo /dev/tty.
# En modo texto (NUI_PLAIN=1 o sin estado compartido) pregunta por /dev/tty.
ui_panel_confirm() {
  local id="$1"; shift
  local question="$*" safe answer i a=""

  [ "${NUI_NONINTERACTIVE:-0}" = "1" ] && return 1
  safe="$(printf '%s' "${id:-key}" | tr -cd '[:alnum:]_.-' 2>/dev/null || true)"
  [ -n "$safe" ] || safe=key

  if [ "${NUI_PLAIN:-0}" = "1" ] || [ -z "${NUI_STATE_DIR:-}" ] || [ ! -d "$NUI_STATE_DIR" ]; then
    if [ -t 0 ] || [ -r /dev/tty ]; then
      _ui_read -rp "$question [s/N]: " a || true
    fi
    case "${a,,}" in s*|y*) return 0 ;; *) return 1 ;; esac
  fi

  answer="$NUI_STATE_DIR/confirm-$safe.env"
  rm -f "$answer" 2>/dev/null || true
  printf '##confirm %s %s\n' "$safe" "$question"
  # Espera como maximo 5 minutos: si el panel se cancela, el paso es matado
  # por el runner; este limite evita quedar colgado ante un TUI perdido.
  for ((i = 0; i < 600; i++)); do
    [ -f "$answer" ] && break
    sleep 0.5
  done
  [ -f "$answer" ] || return 1
  # shellcheck disable=SC1090
  . "$answer"
  [ "${NUI_CONFIRM_ANSWER:-false}" = "true" ]
}

ui_input() {
  if [ "${NUI_NONINTERACTIVE:-0}" = "1" ]; then
    printf '%s' "${UI_INPUT_DEFAULT:-}"
    return 0
  fi
  if ui_have; then
    "$(ui_bin)" input --prompt "$1 " --placeholder "${2:-}"
    return $?
  fi
  if [ -t 0 ] || [ -r /dev/tty ]; then
    local v
    _ui_read -rp "$1 " v || return 1
    printf '%s' "$v"
    return 0
  fi
  printf '%s' "${UI_INPUT_DEFAULT:-}"
}

ui_choose() {
  local prompt="$1"
  shift
  if [ "${NUI_NONINTERACTIVE:-0}" = "1" ]; then return 0; fi
  if ui_have; then
    "$(ui_bin)" choose --no-limit --height 12 --header "$prompt" -- "$@" || true
    return 0
  fi
  if [ -t 0 ] || [ -r /dev/tty ]; then
    printf '%s\n' "$@"
    local sel
    _ui_read -rp "Escribe separados por espacio (o Enter para omitir): " sel || return 0
    printf '%s\n' $sel
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
# Prefijo de timeout portable (GNU coreutils en Linux/WSL).
_ui_timeout_prefix() {
  local t="${NUI_CMD_TIMEOUT:-600}"
  case "$t" in ''|*[!0-9]*|0) return 0 ;; esac
  command -v timeout >/dev/null 2>&1 && printf 'timeout %s ' "$t"
  return 0
}

# ui_logged_argv <titulo> <cmd> [args...]
# Ejecuta "$@" como ARRAY: nunca eval, nunca bash -c con strings interpolados.
# Funciona con argumentos que contienen espacios. Captura stdout+stderr en un
# log bajo $LOG_DIR (ruta expuesta en UI_LAST_LOG) y devuelve el codigo real.
UI_LAST_LOG=""
ui_logged_argv() {
  local title="$1" rc=0
  shift
  if [ $# -eq 0 ]; then
    ui_error "ui_logged_argv: falta el comando"
    return 2
  fi

  ensure_log_dir
  local log
  log="$LOG_DIR/$(date +%Y%m%d-%H%M%S)-$$-argv.log"
  UI_LAST_LOG="$log"
  # Crear el log explicitamente con 0600: las redirecciones posteriores
  # reutilizan el archivo y conservan sus permisos (umask no reliably = 077).
  : > "$log" 2>/dev/null || true
  chmod 600 "$log" 2>/dev/null || true

  # _ui_timeout_prefix devuelve un prefijo controlado ("timeout N "); se
  # convierte a array sin eval para conservar argumentos con espacios.
  local prefix=""
  local -a prefix_arr=() cmd=()
  prefix="$(_ui_timeout_prefix 2>/dev/null || true)"
  if [ -n "$prefix" ]; then
    read -r -a prefix_arr <<< "$prefix"
  fi
  cmd=("${prefix_arr[@]}" "$@")

  if [ "${VERBOSE:-0}" = "1" ]; then
    if command -v tee >/dev/null 2>&1; then
      "${cmd[@]}" 2>&1 | tee "$log"
      rc=${PIPESTATUS[0]}
    else
      "${cmd[@]}"
      rc=$?
    fi
    _ui_cap_log "$log"
    return "$rc"
  fi

  if ui_have; then
    "$(ui_bin)" spin --title "$title" -- "${cmd[@]}" >"$log" 2>&1
    rc=$?
  else
    "${cmd[@]}" >"$log" 2>&1
    rc=$?
  fi
  _ui_cap_log "$log"
  if [ "$rc" -ne 0 ]; then
    ui_tail_error "$title" "$log"
  fi
  return "$rc"
}

# Compatibilidad: ui_logged aceptaba un string y ejecutaba eval. Se mantiene
# el nombre pero NO ejecuta el string; avisa con un error claro para migrar.
ui_logged() {
  ui_error "ui_logged esta obsoleto (ejecutaba eval inseguro); usa ui_logged_argv <titulo> <cmd> [args...]"
  return 2
}

# --- dependencias --------------------------------------------------------
ui_root_prefix() {
  if [ "${EUID:-$(id -u)}" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
    printf 'sudo '
  fi
}
# Compatibilidad con scripts existentes.
ui_apt_prefix() { ui_root_prefix; }

ui_pkg_manager() {
  local m
  for m in apt-get dnf pacman zypper apk; do
    if command -v "$m" >/dev/null 2>&1; then printf '%s' "$m"; return 0; fi
  done
  return 1
}

# ui_pkg_install_cmd <paquete...>: imprime el comando de instalacion.
ui_pkg_install_cmd() {
  local mgr prefix
  mgr="$(ui_pkg_manager)" || return 1
  prefix="$(ui_root_prefix)"
  case "$mgr" in
    apt-get)
      printf '%sapt-get update >/dev/null 2>&1 || true; %sapt-get install -y --no-install-recommends %s' \
        "$prefix" "$prefix" "$*"
      ;;
    dnf) printf '%sdnf install -y %s' "$prefix" "$*" ;;
    pacman) printf '%spacman -S --noconfirm %s' "$prefix" "$*" ;;
    zypper) printf '%szypper --non-interactive install %s' "$prefix" "$*" ;;
    apk) printf '%sapk add --no-cache %s' "$prefix" "$*" ;;
    *) return 1 ;;
  esac
}

# ui_pkg_install_argv <paquete...>: prepara los argv del gestor. Se conserva
# ui_pkg_install_cmd (devuelve un string) para scripts que aún lo usan.
UI_PKG_ARGV=()
UI_PKG_PRE_ARGV=()
ui_pkg_install_argv() {
  local mgr
  local -a root=()
  mgr="$(ui_pkg_manager)" || return 1
  [ -n "$(ui_root_prefix)" ] && root=(sudo)
  UI_PKG_ARGV=()
  UI_PKG_PRE_ARGV=()
  case "$mgr" in
    apt-get)
      UI_PKG_PRE_ARGV=("${root[@]}" apt-get update)
      UI_PKG_ARGV=("${root[@]}" apt-get install -y --no-install-recommends "$@")
      ;;
    dnf) UI_PKG_ARGV=("${root[@]}" dnf install -y "$@") ;;
    pacman) UI_PKG_ARGV=("${root[@]}" pacman -S --noconfirm "$@") ;;
    zypper) UI_PKG_ARGV=("${root[@]}" zypper --non-interactive install "$@") ;;
    apk) UI_PKG_ARGV=("${root[@]}" apk add --no-cache "$@") ;;
    *) return 1 ;;
  esac
}

ui_ensure_cmd() {
  local need_cmd="$1" pkg="${2:-$1}"
  command -v "$need_cmd" >/dev/null 2>&1 && return 0
  if ! ui_pkg_install_argv "$pkg"; then
    ui_warn "No hay gestor de paquetes conocido para instalar $pkg"
    return 1
  fi
  if [ ${#UI_PKG_PRE_ARGV[@]} -gt 0 ]; then
    ui_logged_argv "Actualizando indices de paquetes..." "${UI_PKG_PRE_ARGV[@]}" || true
  fi
  ui_logged_argv "Instalando $pkg..." "${UI_PKG_ARGV[@]}"
}

# --- SSH sin prompts -----------------------------------------------------
# Las host keys se fijan desde el repo. Nunca se hace ssh-keyscan en caliente:
# eso aceptaria un MITM silenciosamente.
ui_seed_known_hosts() {
  local src="${REPO_DIR:-}/config/ssh/known_hosts"
  if [ ! -f "$src" ]; then
    ui_error "Falta el pin de host keys en $src; no se hara ssh-keyscan"
    return 1
  fi
  mkdir -p "$HOME/.ssh" 2>/dev/null || return 1
  chmod 700 "$HOME/.ssh" 2>/dev/null || true
  if [ -f "$HOME/.ssh/known_hosts" ] && command -v dotfiles_backup >/dev/null 2>&1; then
    dotfiles_backup "$HOME/.ssh/known_hosts" \
      || ui_warn "No se pudo respaldar ~/.ssh/known_hosts"
  fi
  # Fusionar (no sobrescribir): conservar hosts propios del usuario; las claves
  # pinadas van primero para que tengan prioridad en StrictHostKeyChecking=yes.
  local tmp
  tmp="$(mktemp "$HOME/.ssh/.known_hosts.XXXXXX" 2>/dev/null)" || {
    ui_error "No se pudo crear el temporal para known_hosts"
    return 1
  }
  if ! {
    cat "$src"
    # Con pipefail, un `[ -f ... ] && cat` que falla (archivo nuevo) hace que
    # todo el pipeline falle; usar if evita el falso error en maquina limpia.
    if [ -f "$HOME/.ssh/known_hosts" ]; then
      cat "$HOME/.ssh/known_hosts"
    fi
  } | sort -u > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    ui_error "No se pudo fusionar $HOME/.ssh/known_hosts"
    return 1
  fi
  chmod 600 "$tmp" 2>/dev/null || true
  if ! mv -f "$tmp" "$HOME/.ssh/known_hosts"; then
    rm -f "$tmp"
    ui_error "No se pudo instalar $HOME/.ssh/known_hosts desde $src"
    return 1
  fi
  return 0
}

ui_ssh_test() {
  local title="$1" target="$2" log
  ui_seed_known_hosts || return 1
  # GitHub/Bitbucket devuelven exit 1 incluso autenticando bien: evaluar por
  # mensaje leyendo el log. argv como array: $target nunca se interpola en un
  # string de shell.
  ui_logged_argv "$title" ssh -T \
    -o StrictHostKeyChecking=yes -o BatchMode=yes -o ConnectTimeout=10 \
    "$target" || true
  log="${UI_LAST_LOG:-}"
  if [ -n "$log" ] && [ -f "$log" ] && \
     grep -Eiq 'successfully authenticated|authenticated via ssh key|logged in as' "$log"; then
    return 0
  fi
  return 1
}

# --- portapapeles y URLs sin dependencias de Windows ----------------------
ui_copy_clip() { # stdin -> portapapeles; 0 si se copio
  local data
  data="$(cat 2>/dev/null)" || return 1
  [ -n "$data" ] || return 1
  if command -v wl-copy >/dev/null 2>&1 && printf '%s\n' "$data" | wl-copy >/dev/null 2>&1; then
    return 0
  fi
  if command -v xclip >/dev/null 2>&1 && printf '%s\n' "$data" | xclip -selection clipboard -in >/dev/null 2>&1; then
    return 0
  fi
  if command -v xsel >/dev/null 2>&1 && printf '%s\n' "$data" | xsel --clipboard --input >/dev/null 2>&1; then
    return 0
  fi
  if command -v pbcopy >/dev/null 2>&1 && printf '%s\n' "$data" | pbcopy >/dev/null 2>&1; then
    return 0
  fi
  # OSC 52: el propio terminal copia (Windows Terminal, kitty, alacritty...).
  # Se escribe a /dev/tty porque el stdout del paso lo consume el panel.
  if [ -c /dev/tty ] && : 2>/dev/null < /dev/tty; then
    local b64
    b64="$(printf '%s\n' "$data" | base64 2>/dev/null | tr -d '\n')"
    if [ -n "$b64" ] && printf '\033]52;c;%s\a' "$b64" 2>/dev/null > /dev/tty; then
      return 0
    fi
  fi
  return 1
}

ui_open_url() { # abre una URL con herramientas Linux; 0 si hay herramienta
  local url="$1"
  if command -v xdg-open >/dev/null 2>&1; then
    ( xdg-open "$url" >/dev/null 2>&1 & ) 2>/dev/null
    return 0
  fi
  if command -v gio >/dev/null 2>&1 && gio open "$url" >/dev/null 2>&1; then
    return 0
  fi
  # Fallback exclusivo de WSL (wslu): en Linux puro nunca existe; se conserva
  # documentado para no romper el entorno actual montado sobre WSL.
  if command -v wslview >/dev/null 2>&1 && wslview "$url" >/dev/null 2>&1; then
    return 0
  fi
  return 1
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
#   ui_panel_step "Identidad Git" --optional --estimate 20 <<'EOF'
#   bash "$REPO_DIR/scripts/setup-git-identity.sh"
#   EOF
#   ui_panel_run
#
# Formularios (se resuelven dentro del panel):
#   ui_panel_inputs <<'INPUTS'
#   input nombre Prompt:
#   password token Prompt:
#   confirm clonar ¿Clonar? n
#   select extras Paquetes many
#   option extras lazyvim
#   default extras lazyvim
#   INPUTS
#   ui_panel_step "Paso con formulario" --optional <<'EOF'
#   . "$NUI_STEP_RESULT"
#   ...
#   EOF
#
# Cada cuerpo se ejecuta con bash (set -euo pipefail) y puede emitir:
#   ##progress N   porcentaje del paso
#   ##log T        linea limpia en el panel
#   ##title T      renombra el paso en vivo
#   ##warn T       marca aviso y continua
# ui_panel_run devuelve 1 si hubo errores (y el panel muestra el reporte).
# Todo el armado del plan es bash puro (no requiere python3).
PANEL_DIR=""
PANEL_STEPS=()
PANEL_NOTES=()
PANEL_INPUTS=""
PANEL_STATE_DIR=""

json_escape() {
  local s="$1"
  # Elimina controles no imprimibles (JSON invalido si se cuelan).
  s="$(printf '%s' "$s" | LC_ALL=C tr -d '\000-\010\013\014\016-\037')"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

ui_panel_begin() {
  ensure_log_dir
  PANEL_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nui-steps.XXXXXX")" || return 1
  PANEL_STEPS=()
  PANEL_NOTES=()
  PANEL_INPUTS=""
  PANEL_STATE_DIR=""
}

ui_panel_note() { PANEL_NOTES+=("$*"); }

ui_panel_inputs() { PANEL_INPUTS="$(cat)"; }

# Convierte el DSL de inputs a lineas de campos (tab separado, opciones con
# \x1f): type, nombre, prompt, default, multi, opciones.
_ui_panel_inputs_fields() {
  local line kind rest name prompt value last
  local found cfield after cop cval
  local -a names=() types=() prompts=() defaults=() multis=() options=() conds=()
  local i
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -z "$line" ] && continue
    case "$line" in \#*) continue ;; esac
    kind="${line%% *}"
    rest="${line#"$kind"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"
    case "$kind" in
      input|password|confirm|select)
        name="${rest%% *}"
        prompt="${rest#"$name"}"
        prompt="${prompt#"${prompt%%[![:space:]]*}"}"
        names+=("$name")
        types+=("$kind")
        prompts+=("$prompt")
        defaults+=("")
        multis+=("0")
        options+=("")
        conds+=("")
        ;;
      key)
        # key <nombre> <ruta> <prompt...>: muestra el archivo en el panel.
        name="${rest%% *}"
        after="${rest#"$name"}"
        after="${after#"${after%%[![:space:]]*}"}"
        path="${after%% *}"
        prompt="${after#"$path"}"
        prompt="${prompt#"${prompt%%[![:space:]]*}"}"
        names+=("$name")
        types+=("key")
        prompts+=("$prompt")
        defaults+=("")
        multis+=("0")
        options+=("$path")
        conds+=("")
        ;;
      option)
        name="${rest%% *}"
        value="${rest#"$name"}"
        value="${value#"${value%%[![:space:]]*}"}"
        for i in "${!names[@]}"; do
          if [ "${names[$i]}" = "$name" ]; then
            if [ -n "${options[$i]}" ]; then
              options[$i]="${options[$i]}"$'\x1e'"$value"
            else
              options[$i]="$value"
            fi
          fi
        done
        ;;
      default)
        name="${rest%% *}"
        value="${rest#"$name"}"
        value="${value#"${value%%[![:space:]]*}"}"
        for i in "${!names[@]}"; do
          if [ "${names[$i]}" = "$name" ]; then
            defaults[$i]="$value"
          fi
        done
        ;;
      showif)
        # showif <campo> <field> <op> [value]: condicion de visibilidad.
        # Varias lineas sobre el mismo campo se combinan con AND.
        name="${rest%% *}"
        after="${rest#"$name"}"
        after="${after#"${after%%[![:space:]]*}"}"
        cfield="${after%% *}"
        after="${after#"$cfield"}"
        after="${after#"${after%%[![:space:]]*}"}"
        cop="${after%% *}"
        cval="${after#"$cop"}"
        cval="${cval#"${cval%%[![:space:]]*}"}"
        case "$cop" in
          eq|ne|gt|gte|lt|lte|nonempty|empty) ;;
          *) return 1 ;;
        esac
        found=0
        for i in "${!names[@]}"; do
          if [ "${names[$i]}" = "$name" ]; then
            found=1
            if [ -n "${conds[$i]}" ]; then
              conds[$i]="${conds[$i]}"$'\x1d'
            fi
            conds[$i]="${conds[$i]}${cfield}"$'\x1c'"${cop}"$'\x1c'"${cval}"
          fi
        done
        [ "$found" = "1" ] || return 1
        ;;
    esac
  done

  for i in "${!names[@]}"; do
    case "${types[$i]}" in
      confirm)
        last="${prompts[$i]##* }"
        case "$last" in
          s|S|si|no|n|y|true|false)
            case "$last" in
              s|S|si|y|true) defaults[$i]="true" ;;
              *) defaults[$i]="false" ;;
            esac
            prompts[$i]="${prompts[$i]% *}"
            ;;
        esac
        ;;
      select)
        last="${prompts[$i]##* }"
        if [ "$last" = "many" ]; then
          multis[$i]="1"
          prompts[$i]="${prompts[$i]% *}"
        fi
        ;;
    esac
    printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
      "${types[$i]}" "${names[$i]}" "${prompts[$i]}" "${defaults[$i]}" "${multis[$i]}" "${options[$i]}" "${conds[$i]}"
  done
}

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
  case "$estimate" in ''|*[!0-9]*) estimate=0 ;; esac
  # --only: filtra por titulo. No resuelve dependencias entre pasos.
  if [ -n "${NUI_ONLY:-}" ]; then
    case "$title" in
      *"$NUI_ONLY"*) ;;
      *) return 0 ;;
    esac
  fi
  [ -n "$PANEL_DIR" ] || ui_panel_begin

  local n=$(( ${#PANEL_STEPS[@]} + 1 ))
  local file="$PANEL_DIR/step-$n.sh"
  {
    printf 'set -euo pipefail\n'
    # PATH persistido por pasos anteriores (nvm, opencode, herdr...).
    if [ -n "${NUI_ENV_FILE:-}" ]; then
      printf '[ -f %q ] && . %q || true\n' "$NUI_ENV_FILE" "$NUI_ENV_FILE"
    fi
    cat
  } > "$file"

  local b64 b64inputs=""
  b64="$(printf '%s' "$title" | base64 | tr -d '\n')"
  if [ -n "$PANEL_INPUTS" ]; then
    b64inputs="$(printf '%s\n' "$PANEL_INPUTS" | _ui_panel_inputs_fields | base64 | tr -d '\n')"
    if [ -z "$b64inputs" ]; then
      ui_error "ui_panel_inputs: DSL invalido"
      PANEL_INPUTS=""
      return 1
    fi
  fi
  PANEL_INPUTS=""
  PANEL_STEPS+=("$b64|$optional|$interactive|$estimate|$file|$b64inputs")
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

# Pide los inputs de un paso por stdin (fallback sin panel).
_ui_panel_prompt_inputs() {
  local state="$1" idx="$2" b64="$3"
  [ -n "$b64" ] || return 0
  local out
  out="$state/result-$(printf '%02d' "$idx").env"
  : > "$out"
  local fields
  fields="$(mktemp "${TMPDIR:-/tmp}/nui-inputs.XXXXXX")"
  printf '%s' "$b64" | base64 -d > "$fields"
  local -a field_lines=()
  mapfile -t field_lines < "$fields"
  local line type name prompt default multi options sf val sel n i idxopt yesno
  local shown cond cf cop cv cur want iopt
  local -a opts=() condlist=()
  declare -A answers=()
  for line in "${field_lines[@]}"; do
    IFS=$'\x1f' read -r type name prompt default multi options sf <<< "$line"
    [ -n "$type" ] || continue

    # Visibilidad condicional (show_if): todas las condiciones deben cumplirse.
    shown=1
    if [ -n "$sf" ]; then
      IFS=$'\x1d' read -ra condlist <<< "$sf"
      for cond in "${condlist[@]}"; do
        [ -n "$cond" ] || continue
        IFS=$'\x1c' read -r cf cop cv <<< "$cond"
        cur="${answers[$cf]:-}"
        case "$cop" in
          eq)       [ "$cur" = "$cv" ]  || shown=0 ;;
          ne)       [ "$cur" != "$cv" ] || shown=0 ;;
          nonempty) [ -n "$cur" ]       || shown=0 ;;
          empty)    [ -z "$cur" ]       || shown=0 ;;
          gt|gte|lt|lte)
            case "$cur" in ''|*[!0-9]*) shown=0 ;; esac
            case "$cv"  in ''|*[!0-9]*) shown=0 ;; esac
            if [ "$shown" = "1" ]; then
              case "$cop" in
                gt)  [ "$cur" -gt "$cv" ] || shown=0 ;;
                gte) [ "$cur" -ge "$cv" ] || shown=0 ;;
                lt)  [ "$cur" -lt "$cv" ] || shown=0 ;;
                lte) [ "$cur" -le "$cv" ] || shown=0 ;;
              esac
            fi
            ;;
        esac
        [ "$shown" = "1" ] || break
      done
    fi
    if [ "$shown" = "0" ]; then
      answers["$name"]=""
      printf '%s=%q\n' "$name" "" >> "$out"
      continue
    fi

    val="$default"
    case "$type" in
      input)
        _ui_read -rp "$(printf '%s [%s]: ' "$prompt" "$default")" val || true
        ;;
      password)
        _ui_read -rsp "$(printf '%s: ' "$prompt")" val || true
        printf '\n'
        ;;
      confirm)
        yesno=n
        [ "$default" = "true" ] && yesno=s
        _ui_read -rp "$(printf '%s [s/n] (%s): ' "$prompt" "$yesno")" val || true
        if [ -z "$val" ]; then val="$default"; else
          case "${val,,}" in
            s|si|sí|y|yes|true) val=true ;;
            *) val=false ;;
          esac
        fi
        ;;
      key)
        printf '\n%s\n' "$prompt"
        cat "$options" 2>/dev/null || printf '(no se pudo leer %s)\n' "$options"
        _ui_read -rp "Pulsa enter para continuar... " || true
        ;;
      select)
        printf '\n%s\n' "$prompt"
        opts=()
        IFS=$'\x1e' read -ra opts <<< "$options"
        for i in "${!opts[@]}"; do printf '  %2d) %s\n' "$((i + 1))" "${opts[$i]}"; done
        _ui_read -rp "Seleccion (numeros separados por espacio): " sel || true
        val=""
        for n in $sel; do
          idxopt=$((n - 1))
          if [ "$idxopt" -ge 0 ] && [ "$idxopt" -lt "${#opts[@]}" ]; then
            if [ -n "$val" ]; then val="$val
${opts[$idxopt]}"; else val="${opts[$idxopt]}"; fi
          fi
          [ "$multi" = "1" ] || break
        done
        if [ -z "$val" ] && [ -n "$default" ]; then
          for want in $default; do
            for iopt in "${!opts[@]}"; do
              if [ "${opts[$iopt]}" = "$want" ]; then
                if [ -n "$val" ]; then val="$val
${opts[$iopt]}"; else val="${opts[$iopt]}"; fi
                break
              fi
            done
          done
        fi
        ;;
    esac
    answers["$name"]="$val"
    printf '%s=%q\n' "$name" "$val" >> "$out"
  done
  rm -f "$fields"
}

# Ejecuta el plan sin panel (nui ausente, VERBOSE o terminal no interactiva).
_ui_panel_run_plain() {
  local manifest="$1" title="$2"
  local total=${#PANEL_STEPS[@]} i=0
  local b64t opt intr est path b64inputs t log rc
  local result entry

  REPORT_OK=(); REPORT_WARN=(); REPORT_ERR=()
  ui_clear
  ui_banner "$title"
  printf '\nLogs: %s\n' "$LOG_DIR"

  local -a manifest_lines=()
  mapfile -t manifest_lines < "$manifest"
  for entry in "${manifest_lines[@]}"; do
    IFS='|' read -r b64t opt intr est path b64inputs <<< "$entry"
    [ -n "$path" ] || continue
    i=$((i + 1))
    t="$(printf '%s' "$b64t" | base64 -d)"
    log="$LOG_DIR/steps-$(date +%Y%m%d-%H%M%S)-$(printf '%02d' "$i")-$(printf '%s' "$t" | tr -cs '[:alnum:]' '-' | cut -c1-40).log"
    rm -f "$log.warn"

    printf '\n\033[1m== [%d/%d] %s ==\033[0m\n' "$i" "$total" "$t"
    result="${NUI_STATE_DIR:-$PANEL_DIR}/result-$(printf '%02d' "$i").env"
    _ui_panel_prompt_inputs "${NUI_STATE_DIR:-$PANEL_DIR}" "$i" "$b64inputs"
    export NUI_STEP_RESULT="$result"

    if [ "$intr" = "1" ]; then
      if [ "${NUI_NONINTERACTIVE:-0}" = "1" ]; then
        printf '[WARN] paso interactivo omitido en modo no interactivo\n'
        report_warn "$t: interactivo omitido (modo no interactivo)"
        continue
      fi
      if [ -e /dev/tty ] && [ -r /dev/tty ]; then
        NUI_PLAIN=1 bash "$path" < /dev/tty
      else
        NUI_PLAIN=1 bash "$path" </dev/null
      fi
      rc=$?
    else
      NUI_PLAIN=1 bash "$path" </dev/null 2>&1 | _ui_panel_filter "$log"
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
  done

  for x in ${PANEL_NOTES[@]+"${PANEL_NOTES[@]}"}; do report_info "$x"; done
  ui_report
}

# Arma el plan JSON en bash puro (sin python3).
_ui_panel_plan_json() {
  local manifest="$1" out="$2" title="$3"
  local first_step=1
  local entry b64t opt intr est path b64in t
  local nfirst=1 n
  local fields line ty na pr de mu op sf optval
  local ifirst ofirst cfirst cf cop cv cond
  local -a opts=() condlist=()

  {
    printf '{"title":"%s","notes":[' "$(json_escape "$title")"
    for n in ${PANEL_NOTES[@]+"${PANEL_NOTES[@]}"}; do
      [ "$nfirst" = "0" ] && printf ','
      nfirst=0
      printf '"%s"' "$(json_escape "$n")"
    done
    printf '],"steps":['

    while IFS='|' read -r b64t opt intr est path b64in; do
      [ -n "$path" ] || continue
      case "$est" in ''|*[!0-9]*) est=0 ;; esac
      t="$(printf '%s' "$b64t" | base64 -d)"
      [ "$first_step" = "0" ] && printf ','
      first_step=0
      printf '{"title":"%s","cmd":"bash %s","optional":%s,"interactive":%s,"estimate":%s' \
        "$(json_escape "$t")" \
        "$(json_escape "$(printf '%q' "$path")")" \
        "$([ "$opt" = "1" ] && echo true || echo false)" \
        "$([ "$intr" = "1" ] && echo true || echo false)" \
        "$est"

      if [ -n "$b64in" ]; then
        printf ',"inputs":['
        fields="$(mktemp "${TMPDIR:-/tmp}/nui-fields.XXXXXX")"
        printf '%s' "$b64in" | base64 -d > "$fields"
        ifirst=1
        while IFS=$'\x1f' read -r ty na pr de mu op sf; do
          [ -n "$ty" ] || continue
          [ "$ifirst" = "0" ] && printf ','
          ifirst=0
          printf '{"type":"%s","name":"%s","prompt":"%s","default":"%s"' \
            "$ty" "$(json_escape "$na")" "$(json_escape "$pr")" "$(json_escape "$de")"
          if [ "$ty" = "key" ]; then
            printf ',"path":"%s"' "$(json_escape "$op")"
          fi
          if [ "$ty" = "select" ]; then
            printf ',"multi":%s,"options":[' "$([ "$mu" = "1" ] && echo true || echo false)"
            opts=()
            IFS=$'\x1e' read -ra opts <<< "$op"
            ofirst=1
            for optval in "${opts[@]}"; do
              [ -z "$optval" ] && continue
              [ "$ofirst" = "0" ] && printf ','
              ofirst=0
              printf '"%s"' "$(json_escape "$optval")"
            done
            printf ']'
          fi
          if [ -n "$sf" ]; then
            printf ',"show_if":['
            cfirst=1
            IFS=$'\x1d' read -ra condlist <<< "$sf"
            for cond in "${condlist[@]}"; do
              [ -n "$cond" ] || continue
              [ "$cfirst" = "0" ] && printf ','
              cfirst=0
              IFS=$'\x1c' read -r cf cop cv <<< "$cond"
              printf '{"field":"%s","op":"%s"' "$(json_escape "$cf")" "$(json_escape "$cop")"
              [ -z "$cv" ] || printf ',"value":"%s"' "$(json_escape "$cv")"
              printf '}'
            done
            printf ']'
          fi
          printf '}'
        done < "$fields"
        rm -f "$fields"
        printf ']'
      fi
      printf '}'
    done < "$manifest"

    printf ']}\n'
  } > "$out"
}

# ui_panel_run [--title T] [--plain]: ejecuta el plan y muestra el reporte.
_ui_panel_cleanup() {
  [ -n "${PANEL_DIR:-}" ] && rm -rf "$PANEL_DIR" 2>/dev/null || true
  [ -n "${PANEL_STATE_DIR:-}" ] && rm -rf "$PANEL_STATE_DIR" 2>/dev/null || true
  dotfiles_cleanup_run 2>/dev/null || true
}

ui_panel_run() {
  local title="${UI_APP_TITLE:-INSTALACIÓN}" plain=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --title) shift; title="${1:-$title}" ;;
      --plain) plain=1 ;;
      --dry-run) NUI_DRY_RUN=1; export NUI_DRY_RUN ;;
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

  PANEL_STATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nui-steps-state.XXXXXX")"
  export NUI_STATE_DIR="$PANEL_STATE_DIR"

  _ui_panel_plan_json "$manifest" "$plan" "$title"
  if [ ! -s "$plan" ]; then
    ui_error "No se pudo generar el plan de pasos"
    return 1
  fi

  if [ "${PLAN_ONLY:-0}" = "1" ] || [ "${NUI_DRY_RUN:-0}" = "1" ]; then
    if [ "${NUI_DRY_RUN:-0}" = "1" ]; then
      printf '== DRY RUN: no se ejecutara nada ==\n'
    fi
    cat "$plan"
    if [ "${PLAN_KEEP:-0}" != "1" ]; then
      rm -rf "$PANEL_DIR" "$PANEL_STATE_DIR"
      PANEL_DIR=""
      PANEL_STATE_DIR=""
      PANEL_STEPS=()
      PANEL_NOTES=()
    fi
    return 0
  fi

  # Limpieza garantizada ante Ctrl+C/SIGTERM: no dejar temporales ni procesos
  # hijos con el lock de apt.
  trap '_ui_panel_cleanup; exit 130' INT TERM HUP
  trap '_ui_panel_cleanup' EXIT

  local rc=0 verbose_plain="$plain"
  [ "${VERBOSE:-0}" = "1" ] && verbose_plain=1
  [ "${NUI_NONINTERACTIVE:-0}" = "1" ] && verbose_plain=1

  if ui_have && ui_interactive && ui_supports_steps; then
    local extra=()
    [ "$verbose_plain" = "1" ] && extra+=(--plain)
    [ "${NUI_NONINTERACTIVE:-0}" = "1" ] && extra+=(--non-interactive)
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

  trap - INT TERM HUP EXIT
  rm -rf "$PANEL_DIR" "$PANEL_STATE_DIR"
  PANEL_DIR=""
  PANEL_STATE_DIR=""
  PANEL_STEPS=()
  PANEL_NOTES=()
  return "$rc"
}
