#!/usr/bin/env bash
set -euo pipefail

OPENCODE_DIR="${OPENCODE_DIR:-$HOME/.config/opencode}"
REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$0")" && pwd)}"
LOG_DIR="${LOG_DIR:-$HOME/.local/state/enviroment-dotfiles/logs}"

# shellcheck source=scripts/lib/ui.sh
source "$REPO_DIR/scripts/lib/ui.sh"
export UI_APP_TITLE="AGENTS ENVIRONMENT"
export REPO_DIR OPENCODE_DIR LOG_DIR
ensure_log_dir

VERBOSE="${VERBOSE:-0}"
SKIP_GIT_IDENTITY="${SKIP_GIT_IDENTITY:-0}"
ONLY_STEP="${ONLY_STEP:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verbose) VERBOSE=1; export VERBOSE ;;
    --skip-git) SKIP_GIT_IDENTITY=1 ;;
    --dry-run) NUI_DRY_RUN=1; export NUI_DRY_RUN ;;
    --non-interactive) NUI_NONINTERACTIVE=1; export NUI_NONINTERACTIVE ;;
    --no-color) NUI_NO_COLOR=1; export NUI_NO_COLOR; export NO_COLOR=1 ;;
    --only) shift; ONLY_STEP="${1:-}"; export NUI_ONLY="$ONLY_STEP" ;;
    --only=*) ONLY_STEP="${1#*=}"; export NUI_ONLY="$ONLY_STEP" ;;
    -h|--help)
      cat <<'HELP'
Uso: bootstrap.sh [opciones]

  --verbose            muestra toda la salida (sin panel)
  --skip-git           omite la configuracion de identidad Git/SSH
  --dry-run            imprime el plan de pasos y no ejecuta nada
  --non-interactive    no hace preguntas; usa defaults y modo texto
  --no-color           desactiva color (equivale a NO_COLOR=1)
  --only <texto>       ejecuta solo los pasos cuyo titulo contenga <texto>
  -h, --help           esta ayuda

Solo Linux y WSL. En Windows nativo existe bootstrap.ps1 (docs/WINDOWS.md).
HELP
      exit 0
      ;;
    *) ui_warn "Argumento desconocido: $1" ;;
  esac
  shift
done

if command -v dotfiles_assert_supported >/dev/null 2>&1; then
  dotfiles_assert_supported || exit 1
fi

# Dry-run: no se instala nui, no se tocan dotfiles; solo se arma el plan.
if [ "${NUI_DRY_RUN:-0}" != "1" ]; then
  ui_install_ui || true
  export PATH="$HOME/.local/bin:$PATH"
  dotfiles_env_load 2>/dev/null || true
  dotfiles_backup "$HOME/.bashrc" || true
  dotfiles_backup "$HOME/.bash_profile" || true
  # El env file se genera en ~/.config/enviroment-dotfiles/env.sh; sin esta
  # linea ~/.bashrc nunca lo carga y una terminal nueva no ve los binarios.
  dotfiles_env_install_bashrc 2>/dev/null || true
  dotfiles_shell_startup_install 2>/dev/null || true
  # Login shells (WSL/SSH/bash -l) leen ~/.bash_profile, que opaca a ~/.profile.
  dotfiles_bash_profile_install 2>/dev/null || true
  # Fijar las host keys de GitHub/Bitbucket en ~/.ssh/known_hosts para que
  # git/ssh functionen fuera del panel (p. ej. el launcher del repo privado).
  if ! ui_seed_known_hosts 2>/dev/null; then
    printf '[WARN] No se pudieron fijar las host keys en ~/.ssh/known_hosts\n' >&2
  fi
fi

APT_PREFIX="$(ui_apt_prefix)"
export APT_PREFIX

# --- dependencias base: calcular paquetes faltantes ----------------------
APT_PKGS=()
command -v git >/dev/null 2>&1 || APT_PKGS+=(git)
command -v curl >/dev/null 2>&1 || APT_PKGS+=(curl)
command -v python3 >/dev/null 2>&1 || APT_PKGS+=(python3)
command -v tar >/dev/null 2>&1 || APT_PKGS+=(tar)
command -v gzip >/dev/null 2>&1 || APT_PKGS+=(gzip)
command -v rsync >/dev/null 2>&1 || APT_PKGS+=(rsync)
command -v numfmt >/dev/null 2>&1 || APT_PKGS+=(coreutils)
# El portapapeles y el navegador solo tienen sentido con sesion grafica.
# En servidores headless se omiten para no arrastrar paquetes inutiles.
if [ -n "${WAYLAND_DISPLAY:-}" ] || [ -n "${DISPLAY:-}" ]; then
  command -v xdg-open >/dev/null 2>&1 || APT_PKGS+=(xdg-utils)
  # Portapapeles para el copiado de claves SSH (ui_copy_clip)
  command -v wl-copy >/dev/null 2>&1 || APT_PKGS+=(wl-clipboard)
  command -v xclip >/dev/null 2>&1 || APT_PKGS+=(xclip)
fi
command -v ssh-keygen >/dev/null 2>&1 || APT_PKGS+=(openssh-client)
# LazyVim/nvim-treesitter compila plugins nativos: sin compilador fallan.
if ! command -v cc >/dev/null 2>&1 && ! command -v gcc >/dev/null 2>&1; then
  APT_PKGS+=(build-essential)
fi
# Gestor de paquetes: se detecta una vez y se usa en todos los pasos.
PKG_MGR="$(ui_pkg_manager || true)"
export PKG_MGR

# Traduce nombres genericos a los de cada distro (solo los que difieren).
if [ -n "$PKG_MGR" ] && [ "$PKG_MGR" != "apt-get" ]; then
  _mapped=()
  for _p in "${APT_PKGS[@]}"; do
    case "$PKG_MGR:$_p" in
      dnf:openssh-client) _mapped+=(openssh-clients) ;;
      pacman:openssh-client) _mapped+=(openssh) ;;
      dnf:build-essential) _mapped+=(gcc gcc-c++ make) ;;
      pacman:build-essential) _mapped+=(base-devel) ;;
      zypper:build-essential) _mapped+=(gcc gcc-c++ make) ;;
      apk:build-essential) _mapped+=(build-base) ;;
      *) _mapped+=("$_p") ;;
    esac
  done
  APT_PKGS=("${_mapped[@]}")
  unset _mapped _p
fi

# bash no puede exportar arrays: publicar una copia escalar con otro nombre
# (reasignar APT_PKGS a string despues de usarlo como array es un error).
APT_PKGS_STR="${APT_PKGS[*]}"
export APT_PKGS_STR

# --- plan de pasos -------------------------------------------------------
ui_panel_begin
ui_panel_note "Comandos: sync-dotfiles pull/push"
ui_panel_note "PATH persistido automaticamente en ~/.bashrc; abre una terminal nueva para cargarlo (no uses exec \$SHELL: reemplaza la shell y puede cerrar la terminal)"

ui_panel_step "Credenciales sudo" --optional --interactive --estimate 15 <<'EOF'
passfile="${NUI_STATE_DIR:-}/sudo-pass"
rm -f "$passfile" 2>/dev/null || true
if [ -z "${APT_PREFIX:-}" ]; then
  echo "Sin sudo; apt se ejecutara como usuario actual"
  exit 0
fi
if [ -z "${APT_PKGS_STR:-}" ]; then
  echo "No hay paquetes pendientes"
  exit 0
fi
if sudo -n true 2>/dev/null; then
  echo "Credenciales sudo OK"
  exit 0
fi
echo "Se solicitara la contrasena de sudo (solo para apt)"
pass=""
if [ -r /dev/tty ]; then
  IFS= read -rs -p "Contrasena sudo: " pass < /dev/tty || true
  printf '\n' > /dev/tty 2>/dev/null || true
fi
if [ -z "$pass" ]; then
  echo "[WARN] No se capturo la contrasena; los pasos apt usaran fallback user-space"
  exit 1
fi
# El timestamp de sudo es por TTY/PPID; los pasos del panel son bash -c hijos
# sin TTY, asi que guardamos la contrasena en el estado efimero (0700/0600)
# para reautenticar con sudo -S en cada paso que lo necesite.
if printf '%s\n' "$pass" | sudo -S -p '' -v >/dev/null 2>&1; then
  if [ -n "${NUI_STATE_DIR:-}" ] && [ -d "$NUI_STATE_DIR" ]; then
    umask 077
    printf '%s\n' "$pass" > "$passfile"
    chmod 600 "$passfile" 2>/dev/null || true
    echo "Credenciales sudo guardadas temporalmente"
  else
    echo "[WARN] No hay directorio de estado seguro para la contrasena"
    exit 1
  fi
else
  echo "[WARN] Contrasena de sudo incorrecta o sudo no disponible"
  exit 1
fi
unset pass
EOF

ui_panel_step "Dependencias base" --estimate 45 <<'EOF'
# shellcheck source=lib/dotfiles.sh
source "$REPO_DIR/scripts/lib/dotfiles.sh"
passfile="${NUI_STATE_DIR:-}/sudo-pass"
sudo_ok=1
if [ -n "${APT_PREFIX:-}" ]; then
  if sudo -n true 2>/dev/null || [ -s "$passfile" ]; then
    sudo_ok=1
  else
    sudo_ok=0
    echo "##warn Contraseña sudo no activa; el gestor de paquetes no instalara nada"
    echo "##log Ejecuta 'sudo -v' en tu terminal y relanza el instalador"
  fi
fi

PKG_MGR="${PKG_MGR:-}"
if [ -z "$PKG_MGR" ]; then
  for _m in apt-get dnf pacman zypper apk; do
    if command -v "$_m" >/dev/null 2>&1; then PKG_MGR="$_m"; break; fi
  done
fi
export PKG_MGR

pkg_run() {
  local log rc to
  log="$(mktemp)"
  to="${APT_TIMEOUT:-600}"
  rc=0
  export DEBIAN_FRONTEND=noninteractive
  if [ -n "${APT_PREFIX:-}" ]; then
    dotfiles_sudo_run "$to" "$@" >"$log" 2>&1 || rc=$?
  else
    timeout "$to" "$@" >"$log" 2>&1 || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    echo "##log el gestor de paquetes termino con codigo $rc (ultimas lineas):"
    tail -n 5 "$log" 2>/dev/null | while IFS= read -r l; do echo "##log $l"; done
  fi
  rm -f "$log"
  return "$rc"
}

if [ -n "${APT_PKGS_STR:-}" ]; then
  if [ -z "$PKG_MGR" ]; then
    echo "##warn No hay gestor de paquetes conocido; instala: ${APT_PKGS_STR}"
  elif [ "$sudo_ok" = "0" ]; then
    echo "##log Omito instalacion de: ${APT_PKGS_STR} (sudo no activo)"
  else
    case "$PKG_MGR" in
      apt-get)
        echo "##log Actualizando indices (apt)"
        pkg_run apt-get update || true
        echo "##log Instalando: ${APT_PKGS_STR}"
        if ! pkg_run apt-get install -y --no-install-recommends ${APT_PKGS_STR}; then
          echo "##warn No se pudieron instalar: ${APT_PKGS_STR}"
        fi
        ;;
      dnf)
        echo "##log Actualizando indices (dnf)"
        pkg_run dnf makecache || true
        echo "##log Instalando: ${APT_PKGS_STR}"
        pkg_run dnf install -y ${APT_PKGS_STR} || echo "##warn No se pudieron instalar: ${APT_PKGS_STR}"
        ;;
      pacman)
        echo "##log Actualizando indices (pacman)"
        pkg_run pacman -Sy --noconfirm || true
        echo "##log Instalando: ${APT_PKGS_STR}"
        pkg_run pacman -S --noconfirm ${APT_PKGS_STR} || echo "##warn No se pudieron instalar: ${APT_PKGS_STR}"
        ;;
      zypper)
        echo "##log Instalando: ${APT_PKGS_STR}"
        pkg_run zypper --non-interactive install ${APT_PKGS_STR} || echo "##warn No se pudieron instalar: ${APT_PKGS_STR}"
        ;;
      apk)
        echo "##log Instalando: ${APT_PKGS_STR}"
        pkg_run apk add --no-cache ${APT_PKGS_STR} || echo "##warn No se pudieron instalar: ${APT_PKGS_STR}"
        ;;
    esac
  fi
else
  echo "##log Todas las dependencias base ya estaban instaladas"
fi
if ! command -v git >/dev/null 2>&1; then
  echo "##log git no esta disponible; instala git con tu gestor de paquetes"
  exit 1
fi
echo "Dependencias base listas"
EOF

# La fuente se instala antes de configurar Alacritty para que el terminal
# ya pueda renderizar los glifos Nerd desde el primer arranque.
# La fuente es cosmética: un fallo de descarga/extracción no debe abortar la
# instalación. --optional convierte el error en aviso y continúa con los pasos
# posteriores (nui markStepWarn y _ui_panel_run_plain report_warn).
ui_panel_step "Fuente (JetBrains Mono Nerd)" --optional --estimate 60 <<'EOF'
# shellcheck source=lib/theme.sh
source "$REPO_DIR/scripts/lib/theme.sh"
theme_load_env || exit 1
theme_ensure_font
EOF

if [ "$SKIP_GIT_IDENTITY" != "1" ]; then
  ui_panel_note "Identidad: personal obligatoria; elige 0-3 cuentas adicionales y solo se pediran sus campos (vacio en 'espacio' omite esa cuenta)"

  # Los campos de cuenta se generan con un bucle para no repetir 12 bloques
  # casi identicos. showif <campo> <field> <op> [value] controla la visibilidad.
  _git_account_inputs() {
    local n note
    for n in 1 2 3; do
      case "$n" in
        1) note="(carpeta en tu home, ej. Nuxiba; vacio ignora)" ;;
        *) note="(vacio ignora)" ;;
      esac
      printf 'input acc%s_espacio Espacio cuenta %s %s:\n' "$n" "$n" "$note"
      printf 'showif acc%s_espacio acc_count gte %s\n' "$n" "$n"
      printf 'input acc%s_platform Plataforma cuenta %s (github|bitbucket):\n' "$n" "$n"
      printf 'default acc%s_platform github\n' "$n"
      printf 'showif acc%s_platform acc_count gte %s\n' "$n" "$n"
      printf 'showif acc%s_platform acc%s_espacio nonempty\n' "$n" "$n"
      printf 'input acc%s_name Nombre cuenta %s:\n' "$n" "$n"
      printf 'showif acc%s_name acc_count gte %s\n' "$n" "$n"
      printf 'showif acc%s_name acc%s_espacio nonempty\n' "$n" "$n"
      printf 'input acc%s_email Email cuenta %s:\n' "$n" "$n"
      printf 'showif acc%s_email acc_count gte %s\n' "$n" "$n"
      printf 'showif acc%s_email acc%s_espacio nonempty\n' "$n" "$n"
    done
  }

  ui_panel_inputs < <({
    cat <<'INPUTS'
input p_platform Plataforma personal (github|bitbucket):
default p_platform github
input p_name Nombre personal:
input p_email Email personal:
select acc_count ¿Cuentas adicionales? (0-3):
default acc_count 0
option acc_count 0
option acc_count 1
option acc_count 2
option acc_count 3
INPUTS
    _git_account_inputs
  })
  ui_panel_step "Identidad Git (SSH)" --optional --estimate 45 <<'EOF'
bash "$REPO_DIR/scripts/setup-git-identity.sh"
EOF

  ui_panel_step "Registrar y probar llaves SSH" --optional --estimate 40 <<'EOF'

# ui_copy_clip / ui_open_url son funciones de ui.sh y no se heredan entre
# procesos: cargarlas aqui (antes este paso las llamaba sin tenerlas).
# shellcheck source=lib/ui.sh
source "$REPO_DIR/scripts/lib/ui.sh"

MANIFEST="$HOME/.config/git-accounts.sh"
if [ ! -f "$MANIFEST" ]; then
  echo "##log Sin manifiesto de cuentas git; prueba omitida (relanza el paso de identidad)"
  exit 0
fi
# shellcheck disable=SC1090
. "$MANIFEST"

platform_url() {
  case "$1" in
    bitbucket) printf 'https://bitbucket.org/account/settings/ssh-keys/' ;;
    *) printf 'https://github.com/settings/ssh/new' ;;
  esac
}

show_key() {
  local title="$1" file="$2" url="$3"
  echo "##title $title"
  echo "##log Llave publica de $title:"
  while IFS= read -r l; do echo "##log $l"; done < "$file" 2>/dev/null || true
  if ui_copy_clip < "$file" 2>/dev/null; then
    echo "##log Llave $title copiada al portapapeles"
  else
    echo "##warn No hay portapapeles disponible; copia la linea publica mostrada arriba"
    printf '=== %s (pegar en %s)\n' "$title" "$url" >> "$HOME/claves-ssh.txt" 2>/dev/null || true
    cat "$file" >> "$HOME/claves-ssh.txt" 2>/dev/null || true
    chmod 600 "$HOME/claves-ssh.txt" 2>/dev/null || true
    echo "##log Respaldo: ~/claves-ssh.txt"
  fi
  if ui_open_url "$url" 2>/dev/null; then
    echo "##log Plataforma abierta: $url"
  else
    echo "##log Abre manualmente: $url"
  fi
  echo "##log Pega la llave como una NUEVA llave SSH en la plataforma"
}

ssh_test() {
  local title="$1" target="$2" out
  # Hosts pinnados en el repo: UserKnownHostsFile + StrictHostKeyChecking=yes.
  # Sin el archivo pinnado, ssh falla cerrado (no acepta claves nuevas).
  local known_hosts="$REPO_DIR/config/ssh/known_hosts"
  if [ ! -f "$known_hosts" ]; then
    echo "##warn Falta config/ssh/known_hosts pinnado; no se aceptaran hosts nuevos"
  fi
  if out="$(ssh -T -o UserKnownHostsFile="$known_hosts" -o StrictHostKeyChecking=yes -o BatchMode=yes -o ConnectTimeout=10 "$target" 2>&1 || true)"; then
    if printf '%s\n' "$out" | grep -Eiq 'successfully authenticated|authenticated via ssh key|logged in as'; then
      echo "##log $title OK"
      return 0
    fi
  fi
  echo "##log $title falla (revisa que la clave este agregada)"
  return 1
}

test_account() {
  local title="$1" target="$2" keyfile="$3" platform="$4" order="$5"
  if [ ! -f "$keyfile" ]; then
    echo "##log $title sin clave ($keyfile); omitido"
    return 0
  fi

  echo "##progress $((order * 100 / ACCOUNT_COUNT))"
  show_key "$title" "$keyfile" "$(platform_url "$platform")"

  if ui_panel_confirm "key-$order" "Llave $order/$ACCOUNT_COUNT registrada y guardada en $title. Comprobar ahora?"; then
    ssh_test "$title" "$target" || true
  else
    echo "##log Comprobacion de $title omitida; puedes volver a ejecutar este paso"
  fi
  echo
}

ACCOUNT_COUNT=1
for _slug_count in ${GIT_ACCOUNT_SLUGS:-}; do
  ACCOUNT_COUNT=$((ACCOUNT_COUNT + 1))
done
export ACCOUNT_COUNT

ACCOUNT_ORDER=1
case "$PERSONAL_PLATFORM" in
  bitbucket)
    test_account "Cuenta personal (Bitbucket)" git@bitbucket.org "$HOME/.ssh/id_ed25519_personal.pub" bitbucket "$ACCOUNT_ORDER"
    ;;
  *)
    test_account "Cuenta personal (GitHub)" git@github.com "$HOME/.ssh/id_ed25519_personal.pub" github "$ACCOUNT_ORDER"
    ;;
esac

for slug in ${GIT_ACCOUNT_SLUGS:-}; do
  ACCOUNT_ORDER=$((ACCOUNT_ORDER + 1))
  u="$(printf '%s' "$slug" | tr 'a-z-' 'A-Z_')"
  var_esp="ACC_${u}_ESPACIO" var_pf="ACC_${u}_PLATFORM"
  esp="${!var_esp:-}"
  pf="${!var_pf:-github}"
  test_account "Espacio $esp" "git@git-$slug" "$HOME/.ssh/id_ed25519_$slug.pub" "$pf" "$ACCOUNT_ORDER"
done
echo "##progress 100"
echo "##log Registro y comprobacion SSH finalizados"
EOF
else
  ui_panel_note "Identidad Git omitida (--skip-git)"
fi

ui_panel_inputs <<'INPUTS'
select extras Paquetes custom (espacio para marcar, enter confirma) many
option extras lazyvim
option extras fzf
option extras ripgrep
option extras bat
option extras eza
option extras zoxide
option extras fd-find
option extras lazygit
option extras neovim
default extras neovim
INPUTS
ui_panel_step "Paquetes custom" --estimate 90 <<'EOF'
# shellcheck source=lib/dotfiles.sh
source "$REPO_DIR/scripts/lib/dotfiles.sh"
if [ -z "${NUI_STEP_RESULT:-}" ] || [ ! -f "$NUI_STEP_RESULT" ]; then
  echo "##log Sin selección (modo no interactivo); nada que instalar"
  exit 0
fi
. "$NUI_STEP_RESULT"

SELECTED="${extras:-}"
if [ -z "$SELECTED" ]; then
  echo "##log No se seleccionaron paquetes custom"
  exit 0
fi

apt_one() {
  local pkg="$1" log rc to
  log="$(mktemp)"
  to="${APT_TIMEOUT:-600}"
  rc=0
  export DEBIAN_FRONTEND=noninteractive
  local mgr="${PKG_MGR:-}"
  if [ -z "$mgr" ]; then
    for _m in apt-get dnf pacman zypper apk; do
      if command -v "$_m" >/dev/null 2>&1; then mgr="$_m"; break; fi
    done
  fi
  local -a cmd
  case "$mgr" in
    apt-get) cmd=(apt-get install -y --no-install-recommends "$pkg") ;;
    dnf) cmd=(dnf install -y "$pkg") ;;
    pacman) cmd=(pacman -S --noconfirm "$pkg") ;;
    zypper) cmd=(zypper --non-interactive install "$pkg") ;;
    apk) cmd=(apk add --no-cache "$pkg") ;;
    *) return 1 ;;
  esac
  if [ -n "${APT_PREFIX:-}" ]; then
    dotfiles_sudo_run "$to" "${cmd[@]}" >"$log" 2>&1 || rc=$?
  else
    timeout "$to" "${cmd[@]}" >"$log" 2>&1 || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    echo "##log el gestor de paquetes termino con codigo $rc para $pkg (ultimas lineas):"
    tail -n 3 "$log" 2>/dev/null | while IFS= read -r l; do echo "##log $l"; done
  fi
  rm -f "$log"
  return "$rc"
}

CUSTOM_APT=()
for p in ${SELECTED}; do
  case "$p" in
    lazyvim) ;;
    fd-find) command -v fd >/dev/null 2>&1 || command -v fdfind >/dev/null 2>&1 || CUSTOM_APT+=(fd-find) ;;
    lazygit) command -v lazygit >/dev/null 2>&1 || CUSTOM_APT+=(lazygit) ;;
    neovim) ;; # se maneja con ensure_nvim (requiere > 0.11.2)
    *) command -v "$p" >/dev/null 2>&1 || CUSTOM_APT+=("$p") ;;
  esac
done

# URLs pinnadas para el fallback sin sudo (se pueden sobreescribir por env).
FZF_URL="${FZF_URL:-https://github.com/junegunn/fzf/releases/download/v0.65.0/fzf-0.65.0-linux_amd64.tar.gz}"
RIPGREP_URL="${RIPGREP_URL:-https://github.com/BurntSushi/ripgrep/releases/download/14.1.1/ripgrep-14.1.1-x86_64-unknown-linux-musl.tar.gz}"
RIPGREP_INNER="${RIPGREP_INNER:-ripgrep-14.1.1-x86_64-unknown-linux-musl/rg}"
BAT_URL="${BAT_URL:-https://github.com/sharkdp/bat/releases/download/v0.25.0/bat-v0.25.0-x86_64-unknown-linux-musl.tar.gz}"
BAT_INNER="${BAT_INNER:-bat-v0.25.0-x86_64-unknown-linux-musl/bat}"
EZA_URL="${EZA_URL:-https://github.com/eza-community/eza/releases/download/v0.23.0/eza_x86_64-unknown-linux-gnu.tar.gz}"
ZOXIDE_URL="${ZOXIDE_URL:-https://github.com/ajeetdsouza/zoxide/releases/download/v0.9.8/zoxide-0.9.8-x86_64-unknown-linux-musl.tar.gz}"
FD_URL="${FD_URL:-https://github.com/sharkdp/fd/releases/download/v10.2.0/fd-v10.2.0-x86_64-unknown-linux-musl.tar.gz}"
FD_INNER="${FD_INNER:-fd-v10.2.0-x86_64-unknown-linux-musl/fd}"
LAZYGIT_URL="${LAZYGIT_URL:-https://github.com/jesseduffield/lazygit/releases/download/v0.55.0/lazygit_0.55.0_Linux_x86_64.tar.gz}"

user_fallback() {
  case "$1" in
    fzf) dotfiles_user_bin fzf "$FZF_URL" ;;
    ripgrep) dotfiles_user_bin rg "$RIPGREP_URL" "$RIPGREP_INNER" ;;
    bat) dotfiles_user_bin bat "$BAT_URL" "$BAT_INNER" ;;
    eza) dotfiles_user_bin eza "$EZA_URL" ;;
    zoxide) dotfiles_user_bin zoxide "$ZOXIDE_URL" ;;
    fd-find) dotfiles_user_bin fd "$FD_URL" "$FD_INNER" ;;
    lazygit) dotfiles_user_bin lazygit "$LAZYGIT_URL" ;;
    *) return 1 ;;
  esac
}

if [ ${#CUSTOM_APT[@]} -gt 0 ]; then
  if [ -z "${PKG_MGR:-}" ]; then
    for _m in apt-get dnf pacman zypper apk; do
      if command -v "$_m" >/dev/null 2>&1; then PKG_MGR="$_m"; break; fi
    done
  fi
  if [ -z "${PKG_MGR:-}" ]; then
    echo "##warn Instala manualmente: ${CUSTOM_APT[*]}"
  elif [ -n "${APT_PREFIX:-}" ] && ! sudo -n true 2>/dev/null && [ ! -s "${NUI_STATE_DIR:-}/sudo-pass" ]; then
    echo "##warn Contraseña sudo no activa; intentando instalacion user-space"
    missed=()
    for pkg in "${CUSTOM_APT[@]}"; do
      if user_fallback "$pkg"; then
        echo "##log $pkg instalado en ~/.local/bin"
      else
        missed+=("$pkg")
      fi
    done
    if [ ${#missed[@]} -gt 0 ]; then
      echo "##warn No se pudieron instalar en user-space: ${missed[*]}"
      echo "##log Instalalos con: sudo apt install ${missed[*]}"
    fi
  else
    total=${#CUSTOM_APT[@]}
    i=0
    for pkg in "${CUSTOM_APT[@]}"; do
      i=$((i + 1))
      echo "##log Instalando ($i/$total): $pkg"
      if ! apt_one "$pkg"; then
        echo "##warn No se pudo instalar $pkg"
      fi
      echo "##progress $((i * 100 / total))"
    done
  fi
fi

# --- neovim: requiere version > 0.11.2 -----------------------------------
# apt de Debian trae versiones menores (0.10.x en trixie), asi que se
# instala desde los releases de GitHub en ~/.local/nvim (sin sudo).
nvim_ver() {
  "$1" --version 2>/dev/null | sed -n 's/^NVIM v\([0-9][0-9.]*\).*/\1/p' | head -1
}

ver_gt() { # ver_gt A B -> 0 si A > B (semver de 3 componentes)
  local -a A B
  local i x y
  IFS='.' read -r -a A <<< "${1:-0}"
  IFS='.' read -r -a B <<< "${2:-0}"
  for i in 0 1 2; do
    x="${A[i]:-0}"; y="${B[i]:-0}"
    x="${x%%[^0-9]*}"; y="${y%%[^0-9]*}"
    x=$((10#${x:-0})); y=$((10#${y:-0}))
    if [ "$x" -gt "$y" ]; then return 0; fi
    if [ "$x" -lt "$y" ]; then return 1; fi
  done
  return 1
}

ensure_nvim() {
  local bin cur arch asset tmp dir
  bin="$(command -v nvim 2>/dev/null || true)"
  if [ -n "$bin" ]; then
    cur="$(nvim_ver "$bin")"
    if ver_gt "$cur" 0.11.2; then
      echo "##log neovim OK ($cur > 0.11.2, $bin)"
      return 0
    fi
    echo "##log neovim actual: ${cur:-desconocida} ($bin); requiere > 0.11.2"
  else
    echo "##log neovim no esta instalado; se instalara desde GitHub"
  fi

  case "$(uname -m)" in
    x86_64) arch="x86_64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) echo "##warn Arquitectura no soportada para neovim: $(uname -m)"; return 1 ;;
  esac
  tmp="$(mktemp -d)"
  dir=""
  local ver="${NEOVIM_VERSION:-v0.11.4}" base
  for asset in "nvim-linux-${arch}" "nvim-linux64"; do
    base="https://github.com/neovim/neovim/releases/download/${ver}/${asset}.tar.gz"
    echo "##log Descargando neovim (${ver}, ${asset})..."
    if curl -fsSL --retry 3 --max-time 300 "$base" -o "$tmp/nvim.tgz"; then
      dir="$asset"
      break
    fi
  done
  if [ -z "$dir" ]; then
    echo "##warn No se pudo descargar neovim ${ver} desde GitHub (no se intenta 'latest')"
    rm -rf "$tmp"
    return 1
  fi
  if ! tar -xzf "$tmp/nvim.tgz" -C "$tmp"; then
    echo "##warn El tarball de neovim esta corrupto"
    rm -rf "$tmp"
    return 1
  fi
  mkdir -p "$HOME/.local"
  if [ -d "$HOME/.local/nvim" ]; then
    local bak="$HOME/.local/nvim.bak-$(date +%Y%m%d-%H%M%S)"
    if mv "$HOME/.local/nvim" "$bak" 2>/dev/null; then
      echo "##log Respaldo de neovim anterior: $bak"
    else
      echo "##warn No se pudo respaldar ~/.local/nvim; se conserva y no se reemplaza"
      rm -rf "$tmp"
      return 1
    fi
  fi
  if ! mv "$tmp/$dir" "$HOME/.local/nvim"; then
    echo "##warn No se pudo instalar neovim en ~/.local/nvim"
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$tmp"
  mkdir -p "$HOME/.local/bin"
  ln -sf "$HOME/.local/nvim/bin/nvim" "$HOME/.local/bin/nvim"
  hash -r

  bin="$HOME/.local/bin/nvim"
  cur="$(nvim_ver "$bin")"
  if ver_gt "$cur" 0.11.2; then
    echo "##log neovim instalado: $cur ($bin)"
    return 0
  fi
  echo "##warn neovim instalado pero no reporta version > 0.11.2 (${cur:-desconocida})"
  return 1
}

need_nvim=0
printf '%s\n' ${SELECTED} | grep -qx 'neovim' && need_nvim=1
if printf '%s\n' ${SELECTED} | grep -qx 'lazyvim'; then
  need_nvim=1
fi
if [ "$need_nvim" = "1" ]; then
  if ! command -v cc >/dev/null 2>&1 && ! command -v gcc >/dev/null 2>&1; then
    echo "##warn No hay compilador C; los plugins nativos de LazyVim no compilaran"
    echo "##log Instala build-essential (apt/dnf) o base-devel (pacman)"
  fi
  if ! ensure_nvim; then
    echo "##warn neovim quedo sin la version requerida (> 0.11.2)"
  fi
fi

if printf '%s\n' ${SELECTED} | grep -qx 'lazyvim'; then
  if [ ! -d "$HOME/.config/nvim" ]; then
    echo "##log Clonando LazyVim starter"
    if git clone https://github.com/LazyVim/starter "$HOME/.config/nvim" >/dev/null 2>&1; then
      rm -rf "$HOME/.config/nvim/.git"
    else
      echo "##warn No se pudo instalar LazyVim automáticamente"
    fi
  fi
fi

echo "Paquetes custom atendidos"
EOF

ui_panel_step "Node + nvm" --estimate 120 <<'EOF'
# shellcheck source=lib/dotfiles.sh
source "$REPO_DIR/scripts/lib/dotfiles.sh"
export NVM_DIR="$HOME/.nvm"
NVM_PIN="${NVM_VERSION:-v0.40.8}"
if ! command -v node >/dev/null 2>&1; then
  if [ ! -s "$NVM_DIR/nvm.sh" ]; then
    echo "##log Instalando nvm $NVM_PIN"
    nvm_tmp="$(mktemp)"
    trap 'rm -f "$nvm_tmp"' EXIT
    if ! curl -fsSL --retry 3 --max-time 60 \
         "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_PIN}/install.sh" -o "$nvm_tmp"; then
      echo "##warn No se pudo descargar el instalador de nvm $NVM_PIN"
      exit 1
    fi
    bash "$nvm_tmp" >/dev/null 2>&1 \
      || echo "##warn No se pudo instalar nvm automáticamente"
    rm -f "$nvm_tmp"
  fi
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" >/dev/null 2>&1 || true
  if ! command -v node >/dev/null 2>&1; then
    echo "##log Instalando Node LTS"
    nvm install --lts >/dev/null 2>&1 || { echo "##log Falló la instalación de Node"; exit 1; }
  fi
fi
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" >/dev/null 2>&1 || true
if command -v node >/dev/null 2>&1; then
  dotfiles_env_path_add "$(dirname "$(command -v node)")"
  echo "Node $(node --version 2>/dev/null || echo '?')"
else
  echo "##warn Node no quedo disponible en este paso"
fi
if ! command -v npm >/dev/null 2>&1; then
  echo "##warn npm no esta disponible; el paso 'Restaurar configuración' no podra instalar dependencias"
fi
EOF

ui_panel_step "Actualizar nvm (opcional)" --optional --estimate 30 <<'EOF'
# shellcheck source=lib/dotfiles.sh
source "$REPO_DIR/scripts/lib/dotfiles.sh"
NVM_DIR="$HOME/.nvm"
if [ ! -s "$NVM_DIR/nvm.sh" ]; then
  echo "##log nvm no instalado; nada que actualizar"
  exit 0
fi
. "$NVM_DIR/nvm.sh" >/dev/null 2>&1 || true
cur="$(nvm --version 2>/dev/null || true)"
want="${NVM_VERSION:-v0.40.8}"
want="${want#v}"
if [ "$cur" = "$want" ]; then
  echo "##log nvm $cur ya esta en la version fijada"
  exit 0
fi
echo "##log Actualizando nvm $cur -> $want"
nvm_up_tmp="$(mktemp)"
trap 'rm -f "$nvm_up_tmp"' EXIT
if ! curl -fsSL --retry 3 --max-time 60 \
     "https://raw.githubusercontent.com/nvm-sh/nvm/v${want}/install.sh" -o "$nvm_up_tmp"; then
  echo "##warn No se pudo descargar el instalador de nvm v${want}"
  exit 1
fi
if bash "$nvm_up_tmp" >/dev/null 2>&1 && . "$NVM_DIR/nvm.sh" >/dev/null 2>&1; then
  echo "##log nvm ahora: $(nvm --version 2>/dev/null || echo '?')"
else
  echo "##warn No se pudo actualizar nvm a $want"
  exit 1
fi
rm -f "$nvm_up_tmp"
EOF

ui_panel_step "OpenCode" --estimate 90 <<'EOF'
# shellcheck source=lib/dotfiles.sh
source "$REPO_DIR/scripts/lib/dotfiles.sh"
if ! command -v opencode >/dev/null 2>&1; then
  tmp_oc="$(mktemp)"
  trap 'rm -f "$tmp_oc"' EXIT
  url="${OPENCODE_INSTALL_URL:-https://opencode.ai/v2/install}"
  echo "##log Descargando instalador"
  if ! curl -fsSL --retry 3 --max-time 120 "$url" -o "$tmp_oc"; then
    echo "##warn No se pudo descargar el instalador de OpenCode"
    exit 1
  fi
  bash "$tmp_oc" --no-modify-path </dev/null >/dev/null 2>&1 \
    || { echo "##log El instalador de OpenCode falló"; exit 1; }
fi
for p in "$HOME/.opencode/bin" "$HOME/.local/bin" "$HOME/bin"; do
  if [ -d "$p" ]; then
    PATH="$p:$PATH"
    dotfiles_env_path_add "$p"
  fi
done
export PATH
if command -v opencode >/dev/null 2>&1; then
  echo "OpenCode $(opencode --version 2>/dev/null || echo '?')"
else
  echo "##warn OpenCode no encontrado; revisa ~/.opencode/bin y el PATH persistido"
fi
EOF

ui_panel_step "Restaurar configuración" --estimate 60 <<'EOF'
mkdir -p "$OPENCODE_DIR"
if command -v rsync >/dev/null 2>&1; then
  rsync -a "$REPO_DIR/config/opencode/" "$OPENCODE_DIR/" \
    || echo "##warn No se pudieron copiar todos los assets públicos"
else
  cp -r "$REPO_DIR/config/opencode/." "$OPENCODE_DIR/" \
    || echo "##warn No se pudieron copiar todos los assets públicos"
fi
if [ -f "$OPENCODE_DIR/package.json" ] && command -v npm >/dev/null 2>&1; then
  echo "##log Instalando dependencias npm"
  npm_log="$LOG_DIR/npm-install-$(date +%Y%m%d-%H%M%S)-$$.log"
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  if ! (cd "$OPENCODE_DIR" && npm install --no-audit --no-fund >"$npm_log" 2>&1); then
    echo "##log Reintentando npm install (prefer-online)"
    if (cd "$OPENCODE_DIR" && npm install --no-audit --no-fund --prefer-online >>"$npm_log" 2>&1); then
      echo "##log npm install exitoso tras el reintento"
    else
      echo "##warn npm install falló; revisa $npm_log"
      tail -n 8 "$npm_log" 2>/dev/null | while IFS= read -r l; do echo "##log $l"; done
    fi
  fi
elif [ -f "$OPENCODE_DIR/package.json" ]; then
  echo "##warn npm no disponible; no se instalaron las dependencias de $OPENCODE_DIR"
fi
echo "Configuración restaurada"
EOF

ui_panel_step "Alacritty (opcional)" --optional --estimate 5 <<'EOF'
# Plantillas + paleta centralizadas en apply-theme.sh (config/theme/dracula.env).
bash "$REPO_DIR/scripts/apply-theme.sh" --alacritty
EOF

ui_panel_step "graphify" --estimate 15 <<'EOF'
mkdir -p "$OPENCODE_DIR/skills"
if [ -d "$REPO_DIR/config/opencode/skills/graphify" ]; then
  if command -v rsync >/dev/null 2>&1; then
    rsync -a "$REPO_DIR/config/opencode/skills/graphify/" "$OPENCODE_DIR/skills/graphify/" || true
  else
    cp -r "$REPO_DIR/config/opencode/skills/graphify/." "$OPENCODE_DIR/skills/graphify/" || true
  fi
  echo "graphify instalado"
else
  echo "##log graphify no encontrado en el repo"
fi
EOF

ui_panel_step "oh-my-bash" --estimate 45 <<'EOF'
# shellcheck source=lib/theme.sh
source "$REPO_DIR/scripts/lib/theme.sh"
# shellcheck source=lib/dotfiles.sh
source "$REPO_DIR/scripts/lib/dotfiles.sh"
theme_load_env || exit 1
OMB_THEME="${THEME_OMB_THEME:-vscode}"

# Respaldo por ejecucion (el bootstrap ya respalda .bashrc al inicio; esto es
# idempotente y cubre ejecuciones standalone del paso).
dotfiles_backup "$HOME/.bashrc" || true

if [ ! -d "$HOME/.oh-my-bash" ]; then
  echo "##log Clonando oh-my-bash"
  git clone --depth 1 https://github.com/ohmybash/oh-my-bash.git "$HOME/.oh-my-bash" >/dev/null 2>&1 \
    || { echo "##log Falló el clonado de oh-my-bash"; exit 1; }
fi

osh_header='# >>> dotfiles-oh-my-bash (no editar)'
osh_footer='# <<< dotfiles-oh-my-bash'
osh_tmp="$(mktemp)"
{
  printf 'export OSH="$HOME/.oh-my-bash"\n'
  printf 'OSH_THEME="%s"\n' "$OMB_THEME"
  printf '%s\n' 'source "$OSH/oh-my-bash.sh"'
} > "$osh_tmp"
if ! dotfiles_managed_block "$HOME/.bashrc" "$osh_header" "$osh_footer" append \
    "$(dotfiles_file_mode "$HOME/.bashrc")" < "$osh_tmp"; then
  echo "##warn ~/.bashrc tiene un bloque de oh-my-bash incompleto; no se modifico"
  rm -f "$osh_tmp"
  exit 1
fi
rm -f "$osh_tmp"
echo "oh-my-bash listo (tema $OMB_THEME)"
EOF

# Se ejecuta al final para que el tema alcance tambien los paquetes custom
# instalados arriba (bat, eza, fzf) y los snippets de shell ya generados.
ui_panel_step "Tema (Dracula)" --estimate 15 <<'EOF'
bash "$REPO_DIR/scripts/apply-theme.sh"
EOF

ui_panel_step "herdr" --estimate 45 <<'EOF'
# shellcheck source=lib/dotfiles.sh
source "$REPO_DIR/scripts/lib/dotfiles.sh"
if ! command -v herdr >/dev/null 2>&1; then
  echo "##log Instalando herdr"
  herdr_tmp="$(mktemp)"
  trap 'rm -f "$herdr_tmp"' EXIT
  url="${HERDR_INSTALL_URL:-https://herdr.dev/install.sh}"
  if curl -fsSL --retry 3 --max-time 120 "$url" -o "$herdr_tmp"; then
    sh "$herdr_tmp" </dev/null >/dev/null 2>&1 \
      || echo "##warn herdr no se instaló automáticamente"
  else
    echo "##warn No se pudo descargar el instalador de herdr"
    exit 1
  fi
fi
for p in "$HOME/.herdr/bin" "$HOME/.local/bin" "$HOME/.opencode/bin"; do
  if [ -d "$p" ]; then
    PATH="$p:$PATH"
    dotfiles_env_path_add "$p"
  fi
done
export PATH
if command -v herdr >/dev/null 2>&1; then
  echo "herdr $(herdr --version 2>/dev/null || echo '?')"
else
  echo "##warn herdr no encontrado; revisa ~/.local/bin y el PATH persistido"
fi
EOF

ui_panel_step "Wrappers" --estimate 10 <<'EOF'
# shellcheck source=lib/dotfiles.sh
source "$REPO_DIR/scripts/lib/dotfiles.sh"
mkdir -p "$HOME/.local/bin"
dotfiles_env_path_add "$HOME/.local/bin"
# El wrapper ya no usa curl|bash: clona el repo en un temporal, ejecuta el
# script desde ese clon y limpia siempre con trap.
sync_ref="${SYNC_REF:-}"
sync_sha="${SYNC_SHA:-}"
if [ -n "$sync_ref" ] && ! printf '%s\n' "$sync_ref" | grep -Eq '^[A-Za-z0-9._/-]+$'; then
  echo "##warn SYNC_REF invalido; se ignora"
  sync_ref=""
fi
if [ -n "$sync_sha" ] && ! printf '%s\n' "$sync_sha" | grep -Eq '^[0-9a-fA-F]{7,40}$'; then
  echo "##warn SYNC_SHA invalido; se ignora"
  sync_sha=""
fi
cat > "$HOME/.local/bin/sync-dotfiles" <<WRAP
#!/usr/bin/env bash
set -euo pipefail
export PATH="\$HOME/.local/bin:\$PATH"
if ! command -v git >/dev/null 2>&1; then
  echo "git no está instalado. Ejecuta bootstrap.sh o instala git." >&2
  exit 1
fi
SYNC_REPO_URL="\${SYNC_REPO_URL:-https://github.com/ChaminnPM/enviroment-dotfiles.git}"
SYNC_REF_VAL='$sync_ref'
SYNC_SHA_VAL='$sync_sha'
_sync_tmp="\$(mktemp -d)"
_sync_cleanup() { rm -rf "\$_sync_tmp" 2>/dev/null || true; }
trap _sync_cleanup EXIT
trap 'exit 130' INT TERM HUP
clone_args=(--depth 1)
if [ -n "\$SYNC_REF_VAL" ] && [ "\$SYNC_REF_VAL" != "main" ]; then
  clone_args+=(--branch "\$SYNC_REF_VAL")
fi
if ! git clone "\${clone_args[@]}" "\$SYNC_REPO_URL" "\$_sync_tmp/repo" >/dev/null 2>&1; then
  echo "No se pudo clonar el repo para sync-dotfiles" >&2
  exit 1
fi
if [ -n "\$SYNC_SHA_VAL" ]; then
  _head="\$(git -C "\$_sync_tmp/repo" rev-parse HEAD 2>/dev/null || true)"
  if [ "\$_head" != "\$SYNC_SHA_VAL" ]; then
    echo "HEAD del repo no coincide con SYNC_SHA (\$_head != \$SYNC_SHA_VAL)" >&2
    exit 1
  fi
fi
bash "\$_sync_tmp/repo/scripts/sync.sh" "\$@"
WRAP
chmod 755 "$HOME/.local/bin/sync-dotfiles"
echo "sync-dotfiles instalado"
EOF

ui_panel_step "Verificación final" --optional --estimate 20 <<'EOF'
# shellcheck source=lib/dotfiles.sh
source "$REPO_DIR/scripts/lib/dotfiles.sh"
dotfiles_env_load 2>/dev/null || true
export PATH="$HOME/.local/bin:$HOME/.opencode/bin:$HOME/.herdr/bin:$PATH"
failed=0
# Todo lo que pueda esperar va con timeout -k: con solo TERM, un hijo que lo
# ignora deja colgado el panel indefinidamente.
run_limited() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout -k 5 "$secs" "$@"
  else
    "$@"
  fi
}
check_bin() {
  local label="$1" bin="$2" p
  p="$(command -v "$bin" 2>/dev/null || true)"
  if [ -n "$p" ] && [ -x "$p" ]; then
    echo "##log $label OK ($p)"
  else
    echo "##warn $label no encontrado en PATH"
    failed=1
  fi
}
check_bin OpenCode opencode
check_bin herdr herdr
check_bin Node node
check_bin npm npm
check_bin Neovim nvim
if command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1; then
  echo "##log Compilador C OK"
else
  echo "##warn Compilador C no encontrado (nvim-treesitter/LazyVim)"
  failed=1
fi
echo "##progress 95"
if command -v nvim >/dev/null 2>&1; then
  nv_log="$LOG_DIR/nvim-version-$$.log"
  cur=""
  if run_limited 15 nvim --version >"$nv_log" 2>/dev/null; then
    cur="$(sed -n 's/^NVIM v\([0-9][0-9.]*\).*/\1/p' "$nv_log" 2>/dev/null | head -1)"
  fi
  got="$(printf '%s' "${cur:-0}" | awk -F. '{print $1*10000+$2*100+$3}')"
  if [ "${got:-0}" -le 1102 ]; then
    echo "##warn Neovim ${cur:-?} no supera la version requerida 0.11.2"
    failed=1
  fi
  rm -f "$nv_log" 2>/dev/null || true
fi
# Comprobacion por CONTENIDO, no solo por marcador: un bloque vacio (solo los
# # >>> / # <<<) pasaba el grep y daba falso positivo en maquina limpia.
# Nada de `bash -ic`: puede esperar en /dev/tty y colgar el panel.
envfile="${NUI_ENV_FILE:-$HOME/.config/enviroment-dotfiles/env.sh}"
startup_block_has() { # <archivo> <header> <footer> <texto-requerido>
  local file="$1" h="$2" f="$3" need="$4" body
  [ -f "$file" ] || return 1
  body="$(awk -v b="$h" -v e="$f" \
    '$0==b{on=1;next} $0==e{on=0;next} on{print}' "$file" 2>/dev/null)"
  [ -n "$body" ] || return 1
  printf '%s\n' "$body" | grep -qF -- "$need"
}
shell_ok=1
[ -s "$envfile" ] || shell_ok=0
startup_block_has "$HOME/.bashrc" '# >>> dotfiles-env (no editar)' \
  '# <<< dotfiles-env' "$envfile" || shell_ok=0
startup_block_has "$HOME/.profile" '# >>> dotfiles-profile (no editar)' \
  '# <<< dotfiles-profile' "$envfile" || shell_ok=0
startup_block_has "$HOME/.bash_profile" '# >>> dotfiles-shell (no editar)' \
  '# <<< dotfiles-shell' '.bashrc' || shell_ok=0
if [ "$shell_ok" = "1" ]; then
  echo "##log Bloques de arranque de shell con contenido (sin exec \$SHELL)"
else
  echo "##warn Bloques de arranque vacios/incompletos; relanza 'Persistencia de entorno'"
  failed=1
fi
# Prueba funcional: bash -lc es login NO interactivo (sin prompts ni /dev/tty),
# lee ~/.bash_profile y debe ver el PATH persistido. env -i evita heredar el
# PATH del instalador; timeout -k evita cuelgues.
if run_limited 15 env -i HOME="$HOME" USER="${USER:-$(id -un)}" PATH=/usr/bin:/bin \
    bash -lc 'case ":$PATH:" in *":$HOME/.local/bin:"*) exit 0;; *) exit 1;; esac' \
    </dev/null >/dev/null 2>&1; then
  echo "##log bash -lc carga el PATH persistido"
else
  echo "##warn bash -lc no cargo el PATH persistido"
  failed=1
fi
if [ -x "$HOME/.local/bin/sync-dotfiles" ]; then
  echo "##log Ejecutando sync-dotfiles doctor"
  doc_log="$LOG_DIR/doctor-$$.log"
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  # Sin pipe directo: un nieto (git clone del wrapper) podria mantener el pipe
  # abierto y dejar `tail` esperando EOF para siempre.
  if run_limited 25 "$HOME/.local/bin/sync-dotfiles" doctor >"$doc_log" 2>&1; then
    tail -n 20 "$doc_log" 2>/dev/null | sed 's/^/##log /'
  else
    echo "##warn Doctor no termino a tiempo o fallo; revisa $doc_log"
    tail -n 8 "$doc_log" 2>/dev/null | sed 's/^/##log /'
  fi
else
  echo "##warn sync-dotfiles no instalado"
fi
echo "##progress 100"
if [ "$failed" -ne 0 ]; then
  echo "##warn Hay herramientas pendientes; revisa los avisos del reporte"
  exit 1
fi
echo "Verificación final OK"
EOF

ui_panel_step "Persistencia de entorno" --estimate 10 <<'EOF'
# shellcheck source=lib/dotfiles.sh
source "$REPO_DIR/scripts/lib/dotfiles.sh"
if dotfiles_env_install_bashrc; then
  echo "PATH persistido en ~/.bashrc"
else
  echo "##warn No se pudo persistir el PATH en ~/.bashrc"
fi
if dotfiles_shell_startup_install; then
  echo "Entorno cargado automaticamente en shells nuevas"
else
  echo "##warn No se pudo configurar el arranque de shell"
fi
if dotfiles_bash_profile_install; then
  echo "Login shell (~/.bash_profile) carga ~/.bashrc"
else
  echo "##warn No se pudo configurar ~/.bash_profile"
fi
# La contrasena de sudo solo vive en el estado efimero del TUI; se borra al
# terminar (defensa en profundidad, ademas del RemoveAll de nui).
rm -f "${NUI_STATE_DIR:-}/sudo-pass" 2>/dev/null || true
EOF

rc=0
ui_panel_run || rc=$?
exit "$rc"
