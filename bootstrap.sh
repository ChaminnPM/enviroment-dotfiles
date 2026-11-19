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
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verbose) VERBOSE=1; export VERBOSE ;;
    --skip-git) SKIP_GIT_IDENTITY=1 ;;
    *) ui_warn "Argumento desconocido: $1" ;;
  esac
  shift
done

ui_install_ui || true
export PATH="$HOME/.local/bin:$PATH"

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
command -v xdg-open >/dev/null 2>&1 || APT_PKGS+=(xdg-utils)
# Portapapeles para el copiado de claves SSH (ui_copy_clip)
command -v wl-copy >/dev/null 2>&1 || APT_PKGS+=(wl-clipboard)
command -v xclip >/dev/null 2>&1 || APT_PKGS+=(xclip)
command -v ssh-keygen >/dev/null 2>&1 || APT_PKGS+=(openssh-client)
# bash no puede exportar arrays: convertir a escalar antes de exportar.
APT_PKGS_STR="${APT_PKGS[*]}"
unset APT_PKGS
APT_PKGS="$APT_PKGS_STR"
export APT_PKGS

# --- plan de pasos -------------------------------------------------------
ui_panel_begin
ui_panel_note "Comandos: sync-dotfiles pull/push"
ui_panel_note "Ejecuta: exec \$SHELL"

ui_panel_step "Credenciales sudo" --optional --interactive --estimate 15 <<'EOF'
if [ -z "${APT_PREFIX:-}" ]; then
  echo "##log Sin sudo; apt se ejecutara como usuario actual"
  exit 0
fi
if [ -z "${APT_PKGS:-}" ]; then
  echo "##log No hay paquetes pendientes"
  exit 0
fi
if sudo -n true 2>/dev/null; then
  echo "##log Credenciales sudo OK"
  exit 0
fi
echo "##log Se solicitara la contrasena de sudo (solo para apt)"
if sudo -v; then
  echo "##log Credenciales sudo guardadas"
else
  echo "##warn No se pudieron guardar las credenciales sudo"
  exit 1
fi
EOF

ui_panel_step "Dependencias base" --estimate 45 <<'EOF'
sudo_ok=1
if [ -n "${APT_PREFIX:-}" ]; then
  if sudo -n true 2>/dev/null; then
    sudo_ok=1
  else
    sudo_ok=0
    echo "##warn Contraseña sudo no activa; apt no instalara nada"
    echo "##log Completa el paso 'Credenciales sudo' (relanzando la instalación) para apt"
  fi
fi

apt_run() {
  local log rc to
  log="$(mktemp)"
  to="${APT_TIMEOUT:-600}"
  rc=0
  export DEBIAN_FRONTEND=noninteractive
  if [ -n "${APT_PREFIX:-}" ]; then
    timeout "$to" sudo -n apt-get "$@" >"$log" 2>&1 || rc=$?
  else
    timeout "$to" apt-get "$@" >"$log" 2>&1 || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    echo "##log apt termino con codigo $rc (ultimas lineas):"
    tail -n 5 "$log" 2>/dev/null | while IFS= read -r l; do echo "##log $l"; done
  fi
  rm -f "$log"
  return "$rc"
}

if [ -n "${APT_PKGS:-}" ]; then
  if command -v apt-get >/dev/null 2>&1; then
    if [ "$sudo_ok" = "0" ]; then
      echo "##log Omito instalacion de: ${APT_PKGS} (sudo no activo)"
    else
      echo "##log Actualizando indices"
      apt_run update || true
      echo "##log Instalando: ${APT_PKGS}"
      if ! apt_run install -y --no-install-recommends ${APT_PKGS}; then
        echo "##warn No se pudieron instalar: ${APT_PKGS}"
      fi
    fi
  else
    echo "##warn apt-get no disponible; instala: ${APT_PKGS}"
  fi
else
  echo "##log Todas las dependencias base ya estaban instaladas"
fi
if ! command -v git >/dev/null 2>&1; then
  echo "##log git no esta disponible; instala: ${APT_PREFIX}apt-get install -y git"
  exit 1
fi
echo "Dependencias base listas"
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

  ui_panel_inputs <<'INPUTS'
confirm probar Probar conexion SSH ahora? y
INPUTS
  ui_panel_step "Probar llaves SSH" --optional --estimate 40 <<'EOF'
if [ -z "${NUI_STEP_RESULT:-}" ] || [ ! -f "$NUI_STEP_RESULT" ]; then
  echo "##log Sin respuestas (modo no interactivo); prueba omitida"
  exit 0
fi
. "$NUI_STEP_RESULT"

if [ "${probar:-true}" != "true" ]; then
  echo "##log Prueba SSH omitida por el usuario"
  exit 0
fi

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
  local file="$1" url="$2"
  echo "##log Clave publica ($file):"
  while IFS= read -r l; do echo "##log $l"; done < "$file" 2>/dev/null || true
  if ui_copy_clip < "$file" 2>/dev/null; then
    echo "##log Copiada al portapapeles; pegala en $url"
    if ui_open_url "$url" 2>/dev/null; then
      echo "##log Abriendo la pagina para pegarla"
    fi
  else
    echo "##log Sin portapapeles; copia la linea de arriba a mano"
    { printf '=== %s (pegar en %s)\n' "$(basename "$file")" "$url"; cat "$file" 2>/dev/null; } \
      >> "$HOME/claves-ssh.txt" 2>/dev/null || true
    echo "##log Respaldo: ~/claves-ssh.txt"
  fi
}

ssh_test() {
  local title="$1" target="$2" out
  # StrictHostKeyChecking=accept-new cubre known_hosts sin depender de ui.sh.
  if out="$(ssh -T -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10 "$target" 2>&1 || true)"; then
    if printf '%s\n' "$out" | grep -Eiq 'successfully authenticated|authenticated via ssh key|logged in as'; then
      echo "##log $title OK"
      return 0
    fi
  fi
  echo "##log $title falla (revisa que la clave este agregada)"
  return 1
}

test_account() {
  local title="$1" target="$2" keyfile="$3" platform="$4"
  if [ ! -f "$keyfile" ]; then
    echo "##log $title sin clave ($keyfile); omitido"
    return 0
  fi
  if ! ssh_test "$title" "$target"; then
    show_key "$keyfile" "$(platform_url "$platform")"
  fi
}

case "$PERSONAL_PLATFORM" in
  bitbucket)
    test_account "SSH personal (Bitbucket)" git@bitbucket.org "$HOME/.ssh/id_ed25519_personal.pub" bitbucket
    ;;
  *)
    test_account "SSH personal (GitHub)" git@github.com "$HOME/.ssh/id_ed25519_personal.pub" github
    ;;
esac

for slug in ${GIT_ACCOUNT_SLUGS:-}; do
  u="$(printf '%s' "$slug" | tr 'a-z-' 'A-Z_')"
  eval "esp=\"\${ACC_${u}_ESPACIO:-}\""
  eval "pf=\"\${ACC_${u}_PLATFORM:-github}\""
  test_account "SSH $esp" "git@git-$slug" "$HOME/.ssh/id_ed25519_$slug.pub" "$pf"
done
echo "##log Prueba SSH finalizada"
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
INPUTS
ui_panel_step "Paquetes custom" --estimate 90 <<'EOF'
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
  if [ -n "${APT_PREFIX:-}" ]; then
    timeout "$to" sudo -n apt-get install -y --no-install-recommends "$pkg" >"$log" 2>&1 || rc=$?
  else
    timeout "$to" apt-get install -y --no-install-recommends "$pkg" >"$log" 2>&1 || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    echo "##log apt termino con codigo $rc para $pkg (ultimas lineas):"
    tail -n 3 "$log" 2>/dev/null | while IFS= read -r l; do echo "##log $l"; done
  fi
  rm -f "$log"
  return "$rc"
}

CUSTOM_APT=()
for p in ${SELECTED}; do
  case "$p" in
    lazyvim) ;;
    fd-find) command -v fd >/dev/null 2>&1 || CUSTOM_APT+=(fd-find) ;;
    lazygit) command -v lazygit >/dev/null 2>&1 || CUSTOM_APT+=(lazygit) ;;
    neovim) ;; # se maneja con ensure_nvim (requiere > 0.11.2)
    *) command -v "$p" >/dev/null 2>&1 || CUSTOM_APT+=("$p") ;;
  esac
done

if [ ${#CUSTOM_APT[@]} -gt 0 ]; then
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "##warn Instala manualmente: ${CUSTOM_APT[*]}"
  elif [ -n "${APT_PREFIX:-}" ] && ! sudo -n true 2>/dev/null; then
    echo "##warn Contraseña sudo no activa; no puedo instalar: ${CUSTOM_APT[*]}"
    echo "##log Relanza la instalación y completa el paso 'Credenciales sudo'"
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
  for asset in "nvim-linux-${arch}" "nvim-linux64"; do
    echo "##log Descargando neovim (latest, ${asset})..."
    if curl -fsSL "https://github.com/neovim/neovim/releases/latest/download/${asset}.tar.gz" -o "$tmp/nvim.tgz"; then
      dir="$asset"
      break
    fi
  done
  if [ -z "$dir" ]; then
    echo "##warn No se pudo descargar neovim desde GitHub"
    rm -rf "$tmp"
    return 1
  fi
  if ! tar -xzf "$tmp/nvim.tgz" -C "$tmp"; then
    echo "##warn El tarball de neovim esta corrupto"
    rm -rf "$tmp"
    return 1
  fi
  mkdir -p "$HOME/.local"
  rm -rf "$HOME/.local/nvim"
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
export NVM_DIR="$HOME/.nvm"
if ! command -v node >/dev/null 2>&1; then
  if [ ! -s "$NVM_DIR/nvm.sh" ]; then
    echo "##log Instalando nvm"
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.8/install.sh | bash >/dev/null 2>&1 \
      || echo "##warn No se pudo instalar nvm automáticamente"
  fi
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" >/dev/null 2>&1 || true
  if ! command -v node >/dev/null 2>&1; then
    echo "##log Instalando Node LTS"
    nvm install --lts >/dev/null 2>&1 || { echo "##log Falló la instalación de Node"; exit 1; }
  fi
fi
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" >/dev/null 2>&1 || true
echo "Node $(node --version 2>/dev/null || echo '?')"
EOF

ui_panel_step "Actualizar nvm (opcional)" --optional --estimate 30 <<'EOF'
NVM_DIR="$HOME/.nvm"
if [ ! -s "$NVM_DIR/nvm.sh" ]; then
  echo "##log nvm no instalado; nada que actualizar"
  exit 0
fi
. "$NVM_DIR/nvm.sh" >/dev/null 2>&1 || true
cur="$(nvm --version 2>/dev/null || true)"
want="0.40.8"
if [ "$cur" = "$want" ]; then
  echo "##log nvm $cur ya esta en la version fijada"
  exit 0
fi
echo "##log Actualizando nvm $cur -> $want"
if curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/v${want}/install.sh" | bash >/dev/null 2>&1 \
  && . "$NVM_DIR/nvm.sh" >/dev/null 2>&1; then
  echo "##log nvm ahora: $(nvm --version 2>/dev/null || echo '?')"
else
  echo "##warn No se pudo actualizar nvm a $want"
  exit 1
fi
EOF

ui_panel_step "OpenCode" --estimate 90 <<'EOF'
if ! command -v opencode >/dev/null 2>&1; then
  tmp_oc="$(mktemp)"
  trap 'rm -f "$tmp_oc"' EXIT
  echo "##log Descargando instalador"
  curl -fsSL https://opencode.ai/v2/install -o "$tmp_oc"
  bash "$tmp_oc" --no-modify-path </dev/null >/dev/null 2>&1 \
    || { echo "##log El instalador de OpenCode falló"; exit 1; }
fi
for p in "$HOME/.opencode/bin" "$HOME/.local/bin" "$HOME/bin"; do
  [ -d "$p" ] && PATH="$p:$PATH"
done
export PATH
echo "OpenCode $(opencode --version 2>/dev/null || echo '?')"
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
  if ! (cd "$OPENCODE_DIR" && npm install >/dev/null 2>&1); then
    echo "##warn npm install falló; revisa node_modules manualmente"
  fi
fi
echo "Configuración restaurada"
EOF

ui_panel_step "Alacritty (opcional)" --optional --estimate 5 <<'EOF'
if ! command -v alacritty >/dev/null 2>&1; then
  echo "##log Alacritty no detectado; paso omitido"
  exit 0
fi

AL_VER="$(alacritty --version 2>/dev/null | sed -n 's/^Alacritty \([0-9][0-9.]*\).*/\1/p')"
AL_MAJOR="${AL_VER%%.*}"
AL_MINOR="${AL_VER#*.}"
AL_MINOR="${AL_MINOR%%.*}"
if [ "${AL_MAJOR:-0}" -lt 0 ] || { [ "${AL_MAJOR:-0}" -eq 0 ] && [ "${AL_MINOR:-0}" -lt 13 ]; }; then
  echo "##warn Alacritty ${AL_VER:-desconocida} detectado; la config TOML requiere >= 0.13"
  echo "##log Paso omitido para no sobrescribir configuracion incompatible"
  exit 0
fi

AL_DIR="$HOME/.config/alacritty"
if [ -f "$AL_DIR/alacritty.toml" ] || [ -f "$AL_DIR/alacritty.yml" ]; then
  echo "##log Ya existe configuracion de alacritty en $AL_DIR; no se sobrescribe"
  exit 0
fi

mkdir -p "$AL_DIR"
if cp "$REPO_DIR/config/alacritty/alacritty.toml" "$AL_DIR/alacritty.toml" 2>/dev/null; then
  echo "##log Config de alacritty instalada en $AL_DIR/alacritty.toml"
else
  echo "##warn No se pudo copiar la configuracion de alacritty"
  exit 1
fi
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
# Respaldo unico de .bashrc antes de la primera modificacion
if [ -f "$HOME/.bashrc" ] && ! ls "$HOME"/.bashrc.bak-dotfiles-* >/dev/null 2>&1; then
  if cp -p "$HOME/.bashrc" "$HOME/.bashrc.bak-dotfiles-$(date +%Y%m%d-%H%M%S)" 2>/dev/null; then
    echo "##log Respaldo de .bashrc creado"
  else
    echo "##warn No se pudo crear el respaldo de .bashrc"
  fi
fi
if [ ! -d "$HOME/.oh-my-bash" ]; then
  echo "##log Clonando oh-my-bash"
  git clone https://github.com/ohmybash/oh-my-bash.git "$HOME/.oh-my-bash" >/dev/null 2>&1 \
    || { echo "##log Falló el clonado de oh-my-bash"; exit 1; }
fi
if ! grep -q 'oh-my-bash/oh-my-bash.sh' "$HOME/.bashrc" 2>/dev/null; then
  {
    echo 'export OSH="$HOME/.oh-my-bash"'
    echo 'OSH_THEME="vscode"'
    echo 'source "$OSH/oh-my-bash.sh"'
  } >> "$HOME/.bashrc"
fi
if ! grep -q 'OSH_THEME="vscode"' "$HOME/.bashrc" 2>/dev/null; then
  sed -i 's/^OSH_THEME=.*/OSH_THEME="vscode"/' "$HOME/.bashrc" 2>/dev/null || true
fi
echo "oh-my-bash listo"
EOF

ui_panel_step "herdr" --estimate 45 <<'EOF'
if ! command -v herdr >/dev/null 2>&1; then
  echo "##log Instalando herdr"
  curl -fsSL https://herdr.dev/install.sh | sh >/dev/null 2>&1 \
    || echo "##warn herdr no se instaló automáticamente"
fi
for p in "$HOME/.herdr/bin" "$HOME/.local/bin" "$HOME/.opencode/bin"; do
  [ -d "$p" ] && PATH="$p:$PATH"
done
export PATH
if ! grep -q 'export PATH=.*\.local/bin' "$HOME/.bashrc" 2>/dev/null; then
  echo 'export PATH="$HOME/.local/bin:$HOME/.herdr/bin:$HOME/.opencode/bin:$PATH"' >> "$HOME/.bashrc"
fi
echo "herdr atendido"
EOF

ui_panel_step "Wrappers" --estimate 10 <<'EOF'
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/sync-dotfiles" <<'WRAP'
#!/usr/bin/env bash
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
if ! command -v git >/dev/null 2>&1; then
  echo "git no está instalado. Ejecuta bootstrap.sh o instala git." >&2
  exit 1
fi
exec bash <(curl -fsSL https://raw.githubusercontent.com/ChaminnPM/enviroment-dotfiles/main/scripts/sync.sh) "$@"
WRAP
chmod +x "$HOME/.local/bin/sync-dotfiles"
echo "sync-dotfiles instalado"
EOF

ui_panel_step "Persistencia de entorno" --estimate 10 <<'EOF'
if [ -f "$HOME/.bash_profile" ]; then
  grep -q 'source ~/.bashrc' "$HOME/.bash_profile" 2>/dev/null \
    || echo 'source ~/.bashrc' >> "$HOME/.bash_profile"
else
  echo 'source ~/.bashrc' > "$HOME/.bash_profile"
fi
echo "Entorno persistente"
EOF

rc=0
ui_panel_run || rc=$?
exit "$rc"
