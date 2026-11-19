#!/usr/bin/env bash
# setup-git-identity.sh - configura identidad(es) git multi-cuenta.
#
# Modelo de cuentas:
#   - Cuenta personal (obligatoria): clave ~/.ssh/id_ed25519_personal y perfil
#     ~/.gitconfig-personal; actua en todo el sistema (includeIf "gitdir:$HOME/").
#   - Hasta 3 cuentas opcionales ("espacios"): cada una vive en $HOME/<Espacio>
#     con clave id_ed25519_<slug>, perfil ~/.gitconfig-<slug> y alias SSH
#     git-<slug>. Un includeIf por carpeta cambia user.name/email y un bloque
#     url.insteadOf reescribe los remotes de su plataforma al alias, de modo
#     que dentro de la carpeta se usa la clave de esa cuenta aunque la
#     plataforma coincida con la de la personal.
#     Limitacion documentada: un repo personal clonado DENTRO de la carpeta de
#     un espacio usara la clave de ese espacio para la plataforma de este.
#   - Estado: ~/.config/git-accounts.sh (manifiesto generado; lo leen el paso
#     'Probar llaves SSH' del bootstrap y 'sync-dotfiles doctor').
#   - ~/.ssh/config: solo se regenera la seccion entre los marcadores
#     "# >>> dotfiles-managed" / "# <<< dotfiles-managed"; el resto se
#     conserva (el bloque gestionado va primero y tiene prioridad en ssh).
#   - Migracion: si detecta el esquema viejo (Nuxiba en
#     ~/Documents/Repositorios + ~/.gitconfig-nuxiba) y hay exactamente una
#     cuenta opcional, mueve el contenido a la carpeta del espacio.
#
# Modo panel: los valores vienen de $NUI_STEP_RESULT (los pide el panel).
# Modo standalone: se piden con ui_input/read; tambien acepta variables
# GIT_PERSONAL_* y GIT_ACC<i>_* para ejecucion no interactiva.
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
# shellcheck source=lib/ui.sh
source "$REPO_DIR/scripts/lib/ui.sh"
# shellcheck source=lib/dotfiles.sh
source "$REPO_DIR/scripts/lib/dotfiles.sh"
ensure_log_dir

PANEL_MODE=0
if [ -n "${NUI_STEP_RESULT:-}" ] && [ -f "$NUI_STEP_RESULT" ]; then
  # shellcheck disable=SC1090
  . "$NUI_STEP_RESULT"
  PANEL_MODE=1
fi

say() {
  if [ "$PANEL_MODE" = "1" ]; then printf '##log %s\n' "$*"; else printf '%s\n' "$*"; fi
}

# Las identidades se escriben en ~/.gitconfig y se pasan a ssh-keygen como
# argumentos (nunca dentro de `bash -c`). Aun asi se rechazan caracteres de
# control y corchetes para que no puedan inyectar secciones de git config.
valid_identity() {
  local label="$1" value="$2"
  if printf '%s' "$value" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    say "$label contiene caracteres de control; valor rechazado"
    return 1
  fi
  case "$value" in
    *'['*|*']'*)
      say "$label contiene '[' o ']'; valor rechazado"
      return 1
      ;;
  esac
  return 0
}

_ask() {
  local prompt="$1" env_name="$2" default="${3:-}" value=""
  if [ "$PANEL_MODE" = "1" ]; then
    value="${!env_name:-}"
  elif [ -n "${!env_name:-}" ]; then
    value="${!env_name}"
  elif [ "${NUI_NONINTERACTIVE:-0}" = "1" ]; then
    value=""
  elif ui_interactive; then
    if ui_have; then
      value="$(ui_input "$prompt" "$default")" || value=""
    else
      read -rp "$prompt " value || value=""
    fi
  fi
  if [ -z "$value" ]; then value="$default"; fi
  printf '%s' "$value"
}

norm_platform() {
  case "${1:-}" in bitbucket) printf 'bitbucket' ;; *) printf 'github' ;; esac
}

slugify() {
  local s="$1"
  s="$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]')"
  s="$(printf '%s' "$s" | iconv -f utf-8 -t ascii//TRANSLIT 2>/dev/null || printf '%s' "$s")"
  printf '%s' "$s" | sed -e 's/[^a-z0-9_-]/-/g' -e 's/--*/-/g' -e 's/^-//' -e 's/-$//'
}

platform_url() {
  case "$1" in
    bitbucket) printf 'https://bitbucket.org/account/settings/ssh-keys/' ;;
    *) printf 'https://github.com/settings/ssh/new' ;;
  esac
}

platform_host() {
  case "$1" in
    bitbucket) printf 'bitbucket.org' ;;
    *) printf 'github.com' ;;
  esac
}

run_cmd() {
  # run_cmd <comando> [args...]: en panel emite el log; standalone directo.
  # No usa `bash -c`: los valores del usuario viajan como argumentos.
  if [ "$PANEL_MODE" = "1" ]; then
    local log="$LOG_DIR/identity-$(date +%Y%m%d-%H%M%S)-$$.log"
    if "$@" >"$log" 2>&1 </dev/null; then return 0; fi
    tail -n 5 "$log" 2>/dev/null | while IFS= read -r l; do say "$l"; done
    return 1
  fi
  "$@"
}

mkdir -p "$HOME/.ssh" "$HOME/.config"
chmod 700 "$HOME/.ssh"

# --- cuenta personal (obligatoria) -----------------------------------------
if [ "$PANEL_MODE" = "1" ]; then
  P_PLATFORM="$(norm_platform "$(_ask '' p_platform github)")"
  P_NAME="$(_ask '' p_name '')"
  P_EMAIL="$(_ask '' p_email '')"
else
  P_PLATFORM="$(norm_platform "$(_ask 'Plataforma personal (github|bitbucket):' GIT_PERSONAL_PLATFORM github)")"
  P_NAME="$(_ask 'Nombre personal:' GIT_PERSONAL_NAME '')"
  P_EMAIL="$(_ask 'Email personal:' GIT_PERSONAL_EMAIL '')"
fi
if [ -z "$P_NAME" ] || [ -z "$P_EMAIL" ]; then
  say "Identidad personal omitida (nombre/email vacíos)."
  exit 0
fi
valid_identity "Nombre personal" "$P_NAME" || exit 1
valid_identity "Email personal" "$P_EMAIL" || exit 1

# --- cuentas opcionales (0-3) -----------------------------------------------
ACC_SLUG=(); ACC_ESPACIO=(); ACC_PLATFORM=(); ACC_NAME=(); ACC_EMAIL=(); ACC_FOLDER=()
ACC_FAIL=()

add_account() { # <espacio> <plataforma> <nombre> <email>
  local esp="$1" plt nam="$3" eml="$4" slug folder rfolder rf
  local n idx bad
  case "$esp" in ''|.*|*/*) say "Espacio invalido ('$esp'); cuenta omitida"; return 1 ;; esac
  valid_identity "Nombre de la cuenta '$esp'" "$nam" || return 1
  valid_identity "Email de la cuenta '$esp'" "$eml" || return 1
  plt="$(norm_platform "$2")"
  slug="$(slugify "$esp")"
  if [ -z "$slug" ]; then
    say "No se pudo normalizar el espacio '$esp'; cuenta omitida"
    return 1
  fi
  n=${#ACC_SLUG[@]}
  for ((idx = 0; idx < n; idx++)); do
    if [ "${ACC_SLUG[$idx]}" = "$slug" ]; then
      say "Espacio duplicado ($slug); cuenta omitida"
      return 1
    fi
  done
  folder="$HOME/$esp"
  rfolder="$(dotfiles_realpath "$folder")"
  for ((idx = 0; idx < n; idx++)); do
    rf="$(dotfiles_realpath "${ACC_FOLDER[$idx]}")"
    case "$rfolder/" in "$rf"/*)
      say "La carpeta '$esp' esta dentro de otra cuenta; cuenta omitida"; return 1 ;;
    esac
    case "$rf/" in "$rfolder"/*)
      say "La carpeta '$esp' contiene otra cuenta; cuenta omitida"; return 1 ;;
    esac
  done
  if [ -d "$folder" ] && [ -n "$(ls -A "$folder" 2>/dev/null)" ]; then
    say "Aviso: $folder ya existe con contenido; no se toca nada"
  fi
  mkdir -p "$folder" 2>/dev/null || true
  ACC_SLUG+=("$slug"); ACC_ESPACIO+=("$esp"); ACC_PLATFORM+=("$plt")
  ACC_NAME+=("$nam"); ACC_EMAIL+=("$eml"); ACC_FOLDER+=("$folder")
  return 0
}

# Indices de cuentas cuya clave se genero bien.
ok_indices() {
  local idx slug f bad
  for ((idx = 0; idx < ${#ACC_SLUG[@]}; idx++)); do
    slug="${ACC_SLUG[$idx]}"
    bad=0
    for f in ${ACC_FAIL[@]+"${ACC_FAIL[@]}"}; do
      [ "$f" = "$slug" ] && bad=1
    done
    [ "$bad" = "0" ] && printf '%d\n' "$idx"
  done
  return 0
}

if [ "$PANEL_MODE" = "1" ]; then
  count="$(_ask '' acc_count 0)"
else
  count="$(_ask '¿Cuantas cuentas adicionales (0-3)?:' GIT_ACC_COUNT 0)"
fi
case "$count" in 0|1|2|3) ;; *) count=0 ;; esac

i=1
while [ "$i" -le "$count" ]; do
  if [ "$PANEL_MODE" = "1" ]; then
    esp="$(_ask '' "acc${i}_espacio" '')"
    plt="$(_ask '' "acc${i}_platform" 'github')"
    nam="$(_ask '' "acc${i}_name" '')"
    eml="$(_ask '' "acc${i}_email" '')"
  else
    esp="$(_ask "Espacio $i (carpeta en tu home, ej. Nuxiba):" "GIT_ACC${i}_ESPACIO" '')"
    plt="$(_ask "Plataforma cuenta $i (github|bitbucket):" "GIT_ACC${i}_PLATFORM" 'github')"
    nam="$(_ask "Nombre cuenta $i:" "GIT_ACC${i}_NAME" '')"
    eml="$(_ask "Email cuenta $i:" "GIT_ACC${i}_EMAIL" '')"
  fi
  if [ -z "$esp" ]; then
    say "Cuenta $i sin espacio; omitida"
  else
    if [ -z "$nam" ] && [ -z "$eml" ]; then
      nam="$P_NAME"
      eml="$P_EMAIL"
      say "Cuenta $i: sin nombre/email; se usan los personales"
    fi
    if [ -n "$nam" ] && [ -n "$eml" ]; then
      add_account "$esp" "$plt" "$nam" "$eml" || true
    else
      say "Cuenta $i incompleta; omitida"
    fi
  fi
  i=$((i + 1))
done

# --- claves SSH -------------------------------------------------------------
add_to_agent() {
  local key="$1"
  [ -n "${SSH_AUTH_SOCK:-}" ] || return 0
  command -v ssh-add >/dev/null 2>&1 || return 0
  ssh-add "$key" >/dev/null 2>&1 || say "No se pudo agregar $key al ssh-agent"
}

if [ ! -f "$HOME/.ssh/id_ed25519_personal" ]; then
  say "Generando clave personal..."
  if ! run_cmd ssh-keygen -t ed25519 -C "$P_EMAIL" -f "$HOME/.ssh/id_ed25519_personal" -N ''; then
    say "No se pudo generar la clave personal."
    exit 1
  fi
fi
chmod 600 "$HOME/.ssh/id_ed25519_personal" 2>/dev/null || true
chmod 644 "$HOME/.ssh/id_ed25519_personal.pub" 2>/dev/null || true
add_to_agent "$HOME/.ssh/id_ed25519_personal"

for idx in $(ok_indices); do
  key="$HOME/.ssh/id_ed25519_${ACC_SLUG[$idx]}"
  if [ ! -f "$key" ]; then
    say "Generando clave ${ACC_ESPACIO[$idx]}..."
    if ! run_cmd ssh-keygen -t ed25519 -C "${ACC_EMAIL[$idx]}" -f "$key" -N ''; then
      say "No se pudo generar la clave ${ACC_ESPACIO[$idx]}; cuenta desactivada"
      ACC_FAIL+=("${ACC_SLUG[$idx]}")
      continue
    fi
  fi
  chmod 600 "$key" 2>/dev/null || true
  chmod 644 "$key.pub" 2>/dev/null || true
  add_to_agent "$key"
done

# --- migracion del esquema viejo --------------------------------------------
LEGACY_DIR="$HOME/Documents/Repositorios"
KEEP_LEGACY_INCLUDE=0
legacy_include=0
if [ -f "$HOME/.gitconfig" ] && grep -q 'Documents/Repositorios' "$HOME/.gitconfig" 2>/dev/null; then
  legacy_include=1
fi
legacy_content=0
if [ -d "$LEGACY_DIR" ] && [ -n "$(ls -A "$LEGACY_DIR" 2>/dev/null)" ]; then
  legacy_content=1
fi

MIGRATE_LEGACY="${GIT_MIGRATE_LEGACY:-0}"
if [ "${#ACC_SLUG[@]}" -eq 1 ] && [ "$legacy_content" = "1" ] && [ "$MIGRATE_LEGACY" != "1" ]; then
  if [ "$PANEL_MODE" != "1" ] && [ "${NUI_NONINTERACTIVE:-0}" != "1" ] && ui_interactive; then
    if ui_ask "Mover el contenido de $LEGACY_DIR a ${ACC_FOLDER[0]}?"; then
      MIGRATE_LEGACY=1
    fi
  fi
  if [ "$MIGRATE_LEGACY" != "1" ]; then
    say "Migracion omitida: $LEGACY_DIR conserva su contenido (usa GIT_MIGRATE_LEGACY=1 para moverlo)"
  fi
fi

if [ "${#ACC_SLUG[@]}" -eq 1 ] && [ "$legacy_content" = "1" ] && [ "$MIGRATE_LEGACY" = "1" ]; then
  target="${ACC_FOLDER[0]}"
  if [ "$(dotfiles_realpath "$target")" = "$(dotfiles_realpath "$LEGACY_DIR")" ]; then
    say "Migracion: la carpeta del espacio ya es $LEGACY_DIR; no se mueve nada"
  else
    mkdir -p "$target"
    shopt -s dotglob nullglob
    moved=0
    for item in "$LEGACY_DIR"/*; do
      if mv -- "$item" "$target"/; then moved=$((moved + 1)); fi
    done
    shopt -u dotglob nullglob
    say "Migracion: $moved elementos de $LEGACY_DIR -> $target"
    rmdir "$LEGACY_DIR" 2>/dev/null || true
  fi
elif [ "$legacy_include" = "1" ] && [ -f "$HOME/.gitconfig-nuxiba" ]; then
  KEEP_LEGACY_INCLUDE=1
  say "Esquema viejo: se conserva el include de ~/Documents/Repositorios; mueve esos repos a la carpeta de un espacio y relanza"
elif [ "$legacy_include" = "1" ]; then
  say "Esquema viejo: los repos de ~/Documents/Repositorios quedaran con identidad personal; muevelos a la carpeta del espacio que corresponda"
fi

# --- ~/.ssh/config (seccion gestionada) --------------------------------------
ssh_header='# >>> dotfiles-managed (setup-git-identity.sh) - no editar entre los marcadores'
ssh_footer='# <<< dotfiles-managed'
ssh_tmp="$(mktemp)"
{
  # Solo el cuerpo: dotfiles_managed_block agrega los marcadores.
  if [ "$P_PLATFORM" = "bitbucket" ]; then
    printf 'Host bitbucket.org ssh.bitbucket.org\n    HostName ssh.bitbucket.org\n    User git\n    IdentityFile ~/.ssh/id_ed25519_personal\n    IdentitiesOnly yes\n'
  else
    printf 'Host github.com\n    HostName github.com\n    User git\n    IdentityFile ~/.ssh/id_ed25519_personal\n    IdentitiesOnly yes\n'
  fi
  # Alias de compatibilidad: clone-repos.sh (repo privado) usa git@bitbucket-nuxiba:
  compat=0
  for idx in $(ok_indices); do
    if [ "$compat" = "0" ] && [ "${ACC_PLATFORM[$idx]}" = "bitbucket" ]; then
      printf 'Host bitbucket-nuxiba\n    HostName ssh.bitbucket.org\n    User git\n    IdentityFile ~/.ssh/id_ed25519_%s\n    IdentitiesOnly yes\n' "${ACC_SLUG[$idx]}"
      compat=1
    fi
  done
  for idx in $(ok_indices); do
    if [ "${ACC_PLATFORM[$idx]}" = "bitbucket" ]; then
      printf 'Host git-%s\n    HostName ssh.bitbucket.org\n' "${ACC_SLUG[$idx]}"
    else
      printf 'Host git-%s\n    HostName github.com\n' "${ACC_SLUG[$idx]}"
    fi
    printf '    User git\n    IdentityFile ~/.ssh/id_ed25519_%s\n    IdentitiesOnly yes\n' "${ACC_SLUG[$idx]}"
  done
} > "$ssh_tmp"

cfg="$HOME/.ssh/config"
if [ -f "$cfg" ]; then
  # Aviso (sin tocar nada): hosts propios que quedan fuera del bloque.
  rest_check="$(mktemp)"
  awk -v b="$ssh_header" -v e="$ssh_footer" '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    skip != 1 { print }
  ' "$cfg" > "$rest_check" 2>/dev/null || true
  if grep -qE '^Host (github\.com|bitbucket\.org|ssh\.bitbucket\.org)' "$rest_check" 2>/dev/null; then
    say "~/.ssh/config: bloques previos conservados fuera de la seccion gestionada (el bloque gestionado tiene prioridad)"
  fi
  rm -f "$rest_check"
fi
dotfiles_backup "$cfg" || true
if ! dotfiles_managed_block "$cfg" "$ssh_header" "$ssh_footer" prepend 600 < "$ssh_tmp"; then
  say "No se modifico ~/.ssh/config (bloque gestionado incompleto)"
fi
chmod 600 "$cfg" 2>/dev/null || true
rm -f "$ssh_tmp"

# --- ~/.gitconfig (includes por carpeta) -------------------------------------
# Solo se reemplaza el bloque gestionado: alias, core.editor, credential.helper
# y cualquier otra configuracion del usuario fuera de los marcadores se conserva.
gc_header='# >>> dotfiles-gitconfig (setup-git-identity.sh) - no editar'
gc_footer='# <<< dotfiles-gitconfig'
gc_tmp="$(mktemp)"
{
  # El tema vive en un include aparte para no perderse cuando este script
  # regenera ~/.gitconfig en cada instalacion.
  printf '[include]\n    path = %s/.config/git/theme.gitconfig\n' "$HOME"
  printf '[includeIf "gitdir:%s/"]\n    path = %s/.gitconfig-personal\n' "$HOME" "$HOME"
  if [ "$KEEP_LEGACY_INCLUDE" = "1" ]; then
    printf '[includeIf "gitdir:%s/Documents/Repositorios/"]\n    path = %s/.gitconfig-nuxiba\n' "$HOME" "$HOME"
  fi
  for idx in $(ok_indices); do
    printf '[includeIf "gitdir:%s/"]\n    path = %s/.gitconfig-%s\n' "${ACC_FOLDER[$idx]}" "$HOME" "${ACC_SLUG[$idx]}"
  done
} > "$gc_tmp"
dotfiles_backup "$HOME/.gitconfig" || true
if ! dotfiles_managed_block "$HOME/.gitconfig" "$gc_header" "$gc_footer" prepend 644 < "$gc_tmp"; then
  say "No se modifico ~/.gitconfig (bloque gestionado incompleto)"
fi
rm -f "$gc_tmp"

instead_block() { # <slug> <plataforma> -> bloque url.insteadOf del perfil
  case "$2" in
    bitbucket)
      printf '[url "git@git-%s:"]\n    insteadOf = git@bitbucket.org:\n    insteadOf = ssh://git@ssh.bitbucket.org/\n    insteadOf = ssh://git@bitbucket.org/\n' "$1"
      ;;
    *)
      printf '[url "git@git-%s:"]\n    insteadOf = git@github.com:\n' "$1"
      ;;
  esac
}

# Escribe user.name/user.email con `git config --file` (sin printf ni eval).
write_user_profile() {
  local file="$1" name="$2" email="$3" tmp
  dotfiles_backup "$file" || return 1
  tmp="$(mktemp)"
  chmod 600 "$tmp"
  if [ -f "$file" ]; then cp -p "$file" "$tmp" 2>/dev/null || true; fi
  if command -v git >/dev/null 2>&1; then
    dotfiles_git_set "$tmp" user.name "$name" || return 1
    dotfiles_git_set "$tmp" user.email "$email" || return 1
  else
    printf '[user]\n    name = %s\n    email = %s\n' "$name" "$email" > "$tmp"
  fi
  dotfiles_atomic_write "$file" 600 < "$tmp"
  rm -f "$tmp"
}

# Los perfiles no se pisan si ya existen: el email que el usuario ajusto a mano
# no debe revertirse al relanzar la instalacion. A los existentes solo se les
# agrega el bloque de enrutamiento SSH si no lo tienen.
if [ ! -f "$HOME/.gitconfig-personal" ]; then
  write_user_profile "$HOME/.gitconfig-personal" "$P_NAME" "$P_EMAIL" \
    || say "No se pudo escribir ~/.gitconfig-personal"
else
  chmod 600 "$HOME/.gitconfig-personal" 2>/dev/null || true
  say "~/.gitconfig-personal ya existe; se conserva"
fi

for idx in $(ok_indices); do
  slug="${ACC_SLUG[$idx]}"
  pf="$HOME/.gitconfig-$slug"
  block="$(instead_block "$slug" "${ACC_PLATFORM[$idx]}")"
  if [ ! -f "$pf" ]; then
    write_user_profile "$pf" "${ACC_NAME[$idx]}" "${ACC_EMAIL[$idx]}" \
      || { say "No se pudo escribir $pf"; continue; }
    printf '\n%s' "$block" >> "$pf"
  elif ! grep -qF "git-$slug:" "$pf"; then
    dotfiles_backup "$pf" || true
    printf '\n%s' "$block" >> "$pf"
    say "Se agrego el enrutamiento SSH a $pf"
  else
    say "$pf ya existe; se conserva"
  fi
  chmod 600 "$pf" 2>/dev/null || true
done

# --- manifiesto de cuentas ----------------------------------------------------
slugs=""
for idx in $(ok_indices); do
  slugs="$slugs ${ACC_SLUG[$idx]}"
done
slugs="${slugs# }"

man="$HOME/.config/git-accounts.sh"
man_tmp="$(mktemp)"
{
  printf '# generado por setup-git-identity.sh - no editar a mano\n'
  printf 'PERSONAL_PLATFORM=%q\n' "$P_PLATFORM"
  printf 'PERSONAL_NAME=%q\n' "$P_NAME"
  printf 'PERSONAL_EMAIL=%q\n' "$P_EMAIL"
  printf 'GIT_ACCOUNT_SLUGS=%q\n' "$slugs"
  for idx in $(ok_indices); do
    slug="${ACC_SLUG[$idx]}"
    u="$(printf '%s' "$slug" | tr 'a-z-' 'A-Z_')"
    printf 'ACC_%s_ESPACIO=%q\n' "$u" "${ACC_ESPACIO[$idx]}"
    printf 'ACC_%s_PLATFORM=%q\n' "$u" "${ACC_PLATFORM[$idx]}"
    printf 'ACC_%s_NAME=%q\n' "$u" "${ACC_NAME[$idx]}"
    printf 'ACC_%s_EMAIL=%q\n' "$u" "${ACC_EMAIL[$idx]}"
    printf 'ACC_%s_FOLDER=%q\n' "$u" "${ACC_FOLDER[$idx]}"
  done
} > "$man_tmp"
dotfiles_backup "$man" || true
dotfiles_atomic_write "$man" 600 < "$man_tmp"
rm -f "$man_tmp"

# --- resumen + portapapeles ---------------------------------------------------
gh_fp="$(ssh-keygen -lf "$HOME/.ssh/id_ed25519_personal.pub" 2>/dev/null | awk '{print $2}' || echo '?')"
say "Personal ($P_PLATFORM): ~/.ssh/id_ed25519_personal.pub ($gh_fp)"
for idx in $(ok_indices); do
  slug="${ACC_SLUG[$idx]}"
  fp="$(ssh-keygen -lf "$HOME/.ssh/id_ed25519_$slug.pub" 2>/dev/null | awk '{print $2}' || echo '?')"
  say "${ACC_ESPACIO[$idx]} (${ACC_PLATFORM[$idx]}): ~/.ssh/id_ed25519_$slug.pub ($fp)"
done
say "Guarda las claves publicas en tus plataformas."

copied=0
if ui_copy_clip < "$HOME/.ssh/id_ed25519_personal.pub" 2>/dev/null; then
  say "Clave personal copiada al portapapeles; pegala en $(platform_url "$P_PLATFORM")"
  if ui_open_url "$(platform_url "$P_PLATFORM")" 2>/dev/null; then
    say "Abriendo la pagina para pegarla"
  fi
  copied=1
else
  claves_tmp="$(mktemp)"
  {
    printf '=== Personal/%s (pegar en %s)\n' "$P_PLATFORM" "$(platform_url "$P_PLATFORM")"
    cat "$HOME/.ssh/id_ed25519_personal.pub" 2>/dev/null
    for idx in $(ok_indices); do
      slug="${ACC_SLUG[$idx]}"
      printf '=== %s/%s (pegar en %s)\n' "${ACC_ESPACIO[$idx]}" "${ACC_PLATFORM[$idx]}" "$(platform_url "${ACC_PLATFORM[$idx]}")"
      cat "$HOME/.ssh/id_ed25519_$slug.pub" 2>/dev/null
    done
  } > "$claves_tmp"
  dotfiles_backup "$HOME/claves-ssh.txt" || true
  dotfiles_atomic_write "$HOME/claves-ssh.txt" 600 < "$claves_tmp"
  rm -f "$claves_tmp"
  if [ -f "$HOME/claves-ssh.txt" ]; then
    say "Sin portapapeles: todas las claves guardadas en ~/claves-ssh.txt"
  fi
fi
if [ "$copied" = "1" ] && [ "${#ACC_SLUG[@]}" -gt 0 ]; then
  say "Las claves de los espacios se copian solas si su prueba SSH falla (paso 'Probar llaves SSH')."
fi

# --- comprobacion SSH (solo standalone) ---------------------------------------
ssh_check() {
  local title="$1" target="$2"
  ui_seed_known_hosts
  local out
  if out="$(ssh -T -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10 "$target" 2>&1 || true)"; then
    if printf '%s\n' "$out" | grep -Eiq 'successfully authenticated|authenticated via ssh key|logged in as'; then
      say "$title OK"
      return 0
    fi
  fi
  say "$title falla (revisa que la clave este agregada)."
  return 1
}

if [ "$PANEL_MODE" != "1" ] && [ "${NUI_NONINTERACTIVE:-0}" != "1" ] && ui_interactive && ui_ask "¿Probar la conexion SSH ahora?"; then
  ssh_check "SSH personal ($P_PLATFORM)" "git@$(platform_host "$P_PLATFORM")" || true
  for idx in $(ok_indices); do
    ssh_check "SSH ${ACC_ESPACIO[$idx]}" "git@git-${ACC_SLUG[$idx]}" || true
  done
else
  say "Prueba SSH omitida (pruébala despues con: ssh -T git@$(platform_host "$P_PLATFORM"))."
fi

say "Configuracion de identidad completada."
