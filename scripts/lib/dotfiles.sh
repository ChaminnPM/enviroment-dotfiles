#!/usr/bin/env bash
# dotfiles.sh - helpers para modificar dotfiles sin destruir configuracion.
#
# Objetivo:
#   - respaldar cada archivo una vez por ejecucion antes de tocarlo;
#   - escribir de forma atomica (tmp en el mismo directorio + mv);
#   - conservar los permisos originales;
#   - actualizar solo bloques delimitados por marcadores.
#
# Soporte: Linux y WSL (bash 4+). En Windows nativo vive la capa PowerShell
# (bootstrap.ps1 + scripts/lib/*.psm1); macOS no esta soportado. Ver
# docs/PLATFORMS.md. El helper usa `stat -c` (GNU) con fallback a `stat -f`.

DOTFILES_STATE_DIR="${DOTFILES_STATE_DIR:-$HOME/.local/state/enviroment-dotfiles}"
DOTFILES_BACKUP_DIR="${DOTFILES_BACKUP_DIR:-$DOTFILES_STATE_DIR/backups}"
DOTFILES_RUN_ID="${DOTFILES_RUN_ID:-$(date +%Y%m%d-%H%M%S)-$$}"
NUI_ENV_FILE="${NUI_ENV_FILE:-$HOME/.config/enviroment-dotfiles/env.sh}"
export DOTFILES_STATE_DIR DOTFILES_BACKUP_DIR DOTFILES_RUN_ID NUI_ENV_FILE

# Mensajes: dentro de un paso de nui se emiten como directiva; fuera, solo si
# VERBOSE=1 (para no ensuciar stdout de quien sourcea la libreria).
_dotfiles_msg() {
  if [ "${NUI_PANEL:-0}" = "1" ]; then
    printf '##log %s\n' "$*"
  elif [ "${VERBOSE:-0}" = "1" ]; then
    printf '[dotfiles] %s\n' "$*" >&2
  fi
}

# dotfiles_platform -> linux | wsl | darwin | windows | unknown
dotfiles_platform() {
  local os
  os="$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  case "$os" in
    linux)
      if [ -r /proc/sys/kernel/osrelease ] && grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
        printf 'wsl'
      else
        printf 'linux'
      fi
      ;;
    darwin) printf 'darwin' ;;
    mingw*|msys*|cygwin*) printf 'windows' ;;
    *) printf 'unknown' ;;
  esac
}

# dotfiles_assert_supported: falla con un mensaje claro fuera de Linux/WSL.
dotfiles_assert_supported() {
  case "$(dotfiles_platform)" in
    linux|wsl) return 0 ;;
    darwin)
      printf 'Estos scripts soportan Linux y WSL; macOS no esta soportado (docs/PLATFORMS.md).\n' >&2
      return 1
      ;;
    windows)
      printf 'Windows nativo usa el instalador PowerShell: install.ps1 (docs/WINDOWS.md).\n' >&2
      return 1
      ;;
    *)
      printf 'Plataforma no reconocida (%s); solo Linux y WSL estan soportados.\n' "$(uname -s 2>/dev/null || echo '?')" >&2
      return 1
      ;;
  esac
}

dotfiles_file_mode() {
  local f="$1" m
  m="$(stat -c '%a' "$f" 2>/dev/null || true)"
  if [ -z "$m" ]; then
    m="$(stat -f '%Lp' "$f" 2>/dev/null || true)"
  fi
  printf '%s' "${m:-644}"
}

# dotfiles_realpath <ruta>: realpath -m portatil (GNU/BSD) sin exigir existencia.
dotfiles_realpath() {
  local p="$1"
  if realpath -m "$p" >/dev/null 2>&1; then
    realpath -m "$p"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$p"
  else
    printf '%s' "$p"
  fi
}

# dotfiles_backup <archivo>
# Crea $DOTFILES_BACKUP_DIR/<nombre>.<timestamp> una sola vez por archivo y
# ejecucion (marca en TMPDIR). Devuelve 0 si no habia nada que respaldar.
dotfiles_backup() {
  local f="$1" key marker stamp dest base n
  [ -e "$f" ] || return 0
  key="$(printf '%s' "$f" | tr -c '[:alnum:]._-' '_')"
  marker="${TMPDIR:-/tmp}/dotfiles-backup-${DOTFILES_RUN_ID}-${key}"
  [ -e "$marker" ] && return 0

  mkdir -p "$DOTFILES_BACKUP_DIR" 2>/dev/null || return 0
  chmod 700 "$DOTFILES_BACKUP_DIR" 2>/dev/null || true

  stamp="$(date +%Y%m%d-%H%M%S)"
  base="$DOTFILES_BACKUP_DIR/$(basename "$f").$stamp"
  dest="$base"
  n=1
  while [ -e "$dest" ]; do
    dest="$base.$n"
    n=$((n + 1))
  done

  if cp -p "$f" "$dest" 2>/dev/null; then
    : > "$marker" 2>/dev/null || true
    _dotfiles_msg "Respaldo creado: $dest"
    return 0
  fi
  _dotfiles_msg "No se pudo respaldar $f"
  return 1
}

# dotfiles_atomic_write <destino> [modo]
# Lee el contenido nuevo por stdin. Escribe en el mismo directorio y hace mv,
# preservando el modo indicado o el del archivo existente.
dotfiles_atomic_write() {
  local dest="$1" mode="${2:-}" dir tmp
  dir="$(dirname "$dest")"
  mkdir -p "$dir" || return 1
  tmp="$(mktemp "$dir/.dotfiles.XXXXXX")" || return 1
  if ! cat > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  [ -n "$mode" ] || mode="$(dotfiles_file_mode "$dest")"
  chmod "$mode" "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$dest"
}

# dotfiles_managed_block <archivo> <header> <footer> [prepend|append] [modo]
# Reemplaza el contenido entre marcadores con el bloque leido por stdin.
# - Si existe el header pero no el footer, NO toca el archivo y devuelve 1
#   (evita borrar configuracion del usuario por un bloque incompleto).
# - Conserva el contenido fuera del bloque y el modo del archivo.
dotfiles_managed_block() {
  local dest="$1" header="$2" footer="$3" position="${4:-append}" mode="${5:-}"
  local rest tmp dir
  [ -n "$mode" ] || mode="$(dotfiles_file_mode "$dest")"
  dir="$(dirname "$dest")"
  mkdir -p "$dir" || return 1

  if [ -f "$dest" ]; then
    if grep -qxF "$header" "$dest" && ! grep -qxF "$footer" "$dest"; then
      _dotfiles_msg "Bloque incompleto en $dest (falta \"$footer\"); no se modifica"
      return 1
    fi
    rest="$(mktemp "$dir/.dotfiles-rest.XXXXXX")" || return 1
    if ! awk -v b="$header" -v e="$footer" '
      $0 == b { skip = 1; next }
      $0 == e { skip = 0; next }
      skip != 1 { print }
    ' "$dest" > "$rest"; then
      rm -f "$rest"
      return 1
    fi
  else
    rest="$(mktemp "$dir/.dotfiles-rest.XXXXXX")" || return 1
    : > "$rest"
  fi

  # Garantiza salto de linea final para no pegar el header a la ultima linea.
  if [ -s "$rest" ] && [ -n "$(tail -c 1 "$rest" 2>/dev/null)" ]; then
    printf '\n' >> "$rest"
  fi

  tmp="$(mktemp "$dir/.dotfiles-block.XXXXXX")" || { rm -f "$rest"; return 1; }
  {
    if [ "$position" = "prepend" ]; then
      printf '%s\n' "$header"
      cat
      printf '%s\n' "$footer"
      cat "$rest"
    else
      cat "$rest"
      printf '%s\n' "$header"
      cat
      printf '%s\n' "$footer"
    fi
  } > "$tmp"
  rm -f "$rest"
  chmod "$mode" "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$dest"
}

dotfiles_env_file() {
  printf '%s' "$NUI_ENV_FILE"
}

# dotfiles_env_path_add <directorio>
# Persiste el directorio en el env file idempotente y lo agrega al PATH actual.
dotfiles_env_path_add() {
  local dir="$1" f q
  [ -n "$dir" ] || return 0
  f="$(dotfiles_env_file)"
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 1
  chmod 700 "$(dirname "$f")" 2>/dev/null || true
  touch "$f" 2>/dev/null || return 1
  chmod 600 "$f" 2>/dev/null || true

  q="$(printf '%q' "$dir")"
  if ! grep -qF "_dotfiles_dir=$q" "$f" 2>/dev/null; then
    {
      printf '_dotfiles_dir=%s\n' "$q"
      printf 'case ":$PATH:" in *":$_dotfiles_dir:"*) ;; *) PATH="$_dotfiles_dir:$PATH"; export PATH ;; esac\n'
    } >> "$f"
  fi

  case ":$PATH:" in
    *":$dir:"*) ;;
    *) PATH="$dir:$PATH"; export PATH ;;
  esac
}

dotfiles_env_load() {
  local f
  f="$(dotfiles_env_file)"
  [ -f "$f" ] || return 0
  # shellcheck disable=SC1090
  . "$f"
}

# dotfiles_env_install_bashrc: hace que ~/.bashrc cargue el env file con los
# PATH persistidos. Sin esto, los binarios instalados en ~/.local/bin,
# ~/.herdr/bin o ~/.opencode/bin no se encuentran en una terminal nueva.
dotfiles_env_install_bashrc() {
  local rc="$HOME/.bashrc" header='# >>> dotfiles-env (no editar)'
  local footer='# <<< dotfiles-env' f tmp
  f="$(dotfiles_env_file)"
  [ -n "$f" ] || return 1
  [ -e "$rc" ] || { : > "$rc"; chmod 644 "$rc" 2>/dev/null || true; }
  dotfiles_backup "$rc" || true
  tmp="$(mktemp)" || return 1
  printf '[ -f %q ] && . %q\n' "$f" "$f" > "$tmp"
  if dotfiles_managed_block "$rc" "$header" "$footer" append \
      "$(dotfiles_file_mode "$rc")" < "$tmp"; then
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# dotfiles_shell_startup_install: garantiza que una shell NUEVA cargue el
# entorno sin tener que ejecutar `exec $SHELL`. Cubre:
#   - ~/.profile  -> ~/.bashrc (bash) y el env file (cualquier shell)
#   - ~/.zshrc    -> env file + nvm (si zsh esta instalado)
# ~/.bash_profile ya lo hace el paso de persistencia.
dotfiles_shell_startup_install() {
  local envfile header footer tmp profile
  envfile="$(dotfiles_env_file)"
  [ -n "$envfile" ] || return 1

  profile="$HOME/.profile"
  [ -e "$profile" ] || { : > "$profile"; chmod 644 "$profile" 2>/dev/null || true; }
  dotfiles_backup "$profile" || true
  header='# >>> dotfiles-profile (no editar)'
  footer='# <<< dotfiles-profile'
  tmp="$(mktemp)" || return 1
  {
    printf '%s\n' '[ -n "$BASH_VERSION" ] && [ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"'
    printf '[ -f %q ] && . %q\n' "$envfile" "$envfile"
  } > "$tmp"
  if ! dotfiles_managed_block "$profile" "$header" "$footer" append \
      "$(dotfiles_file_mode "$profile")" < "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"

  if command -v zsh >/dev/null 2>&1 || [ -f "$HOME/.zshrc" ]; then
    profile="$HOME/.zshrc"
    [ -e "$profile" ] || { : > "$profile"; chmod 644 "$profile" 2>/dev/null || true; }
    dotfiles_backup "$profile" || true
    header='# >>> dotfiles-zsh (no editar)'
    footer='# <<< dotfiles-zsh'
    tmp="$(mktemp)" || return 1
    {
      printf '[ -f %q ] && . %q\n' "$envfile" "$envfile"
      printf '%s\n' 'export NVM_DIR="$HOME/.nvm"'
      printf '%s\n' '[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"'
    } > "$tmp"
    if ! dotfiles_managed_block "$profile" "$header" "$footer" append \
        "$(dotfiles_file_mode "$profile")" < "$tmp"; then
      rm -f "$tmp"
      return 1
    fi
    rm -f "$tmp"
  fi
  return 0
}

# dotfiles_bash_profile_install: garantiza que una shell de LOGIN cargue el
# entorno. ~/.bash_profile tiene prioridad sobre ~/.profile: si se crea con el
# bloque vacio (solo marcadores), una terminal nueva en WSL/SSH/bash -l no ve
# el PATH ni oh-my-bash y el usuario tiene que sourcear ~/.bashrc a mano.
# env.sh se carga aqui tambien (es idempotente) para que `bash -lc` no
# interactivo funcione aunque ~/.bashrc tenga el guard de `return` inicial.
dotfiles_bash_profile_install() {
  local bp="$HOME/.bash_profile" header='# >>> dotfiles-shell (no editar)'
  local footer='# <<< dotfiles-shell' envfile tmp
  envfile="$(dotfiles_env_file)"
  [ -n "$envfile" ] || return 1
  [ -e "$bp" ] || { : > "$bp"; chmod 644 "$bp" 2>/dev/null || true; }
  dotfiles_backup "$bp" || true
  tmp="$(mktemp)" || return 1
  {
    printf '[ -f %q ] && . %q\n' "$envfile" "$envfile"
    printf '%s\n' '[ -f "$HOME/.bashrc" ] && source "$HOME/.bashrc"'
  } > "$tmp"
  if dotfiles_managed_block "$bp" "$header" "$footer" append \
      "$(dotfiles_file_mode "$bp")" < "$tmp"; then
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# dotfiles_sudo_run <timeout> <cmd...>
# Reutiliza la contraseña capturada una vez por el paso interactivo de sudo.
# Los pasos del panel no tienen TTY y cada uno es un bash -c distinto, por lo
# que el timestamp de sudo (por defecto tipo tty/ppid) no se comparte: hay que
# autenticar con -S desde el archivo temporal protegido de NUI_STATE_DIR.
dotfiles_sudo_run() {
  local to="$1" passfile="${NUI_STATE_DIR:-}/sudo-pass" pass="" rc=0
  local -a pre=()
  shift
  if [ -n "$to" ] && command -v timeout >/dev/null 2>&1; then pre=(timeout "$to"); fi
  if sudo -n true 2>/dev/null; then
    "${pre[@]}" sudo -n "$@"
    return $?
  fi
  if [ -s "$passfile" ]; then
    pass="$(cat "$passfile" 2>/dev/null)" || return 1
    printf '%s\n' "$pass" | "${pre[@]}" sudo -S -p '' "$@"
    rc=${PIPESTATUS[1]}
    return "$rc"
  fi
  return 1
}

# dotfiles_user_bin <binario> <url> [ruta-interna]
# Instala un binario user-space en ~/.local/bin cuando no hay sudo disponible.
dotfiles_user_bin() {
  local bin="$1" url="$2" inner="${3:-}" tmp arc src="" dest
  [ -n "$bin" ] && [ -n "$url" ] || return 1
  dest="$HOME/.local/bin/$bin"
  command -v "$bin" >/dev/null 2>&1 && return 0
  if [ -x "$dest" ]; then
    dotfiles_env_path_add "$HOME/.local/bin"
    return 0
  fi
  case "$(uname -m)" in x86_64|amd64) ;; *) return 1 ;; esac
  tmp="$(mktemp -d)" || return 1
  arc="$tmp/pkg.tgz"
  if ! curl -fsSL --retry 3 --max-time 180 "$url" -o "$arc"; then
    rm -rf "$tmp"; return 1
  fi
  if ! tar -xzf "$arc" -C "$tmp"; then
    rm -rf "$tmp"; return 1
  fi
  [ -n "$inner" ] && [ -f "$tmp/$inner" ] && src="$tmp/$inner"
  [ -n "$src" ] || src="$(find "$tmp" -type f -name "$bin" -print -quit 2>/dev/null)"
  if [ -z "$src" ] || [ ! -f "$src" ]; then
    rm -rf "$tmp"; return 1
  fi
  mkdir -p "$HOME/.local/bin" || { rm -rf "$tmp"; return 1; }
  cp "$src" "$dest" 2>/dev/null || { rm -rf "$tmp"; return 1; }
  chmod 755 "$dest" 2>/dev/null || true
  rm -rf "$tmp"
  dotfiles_env_path_add "$HOME/.local/bin"
  return 0
}

# dotfiles_git_set <archivo> <clave> <valor>
# Escribe con `git config --file` (sin interpolar en un printf ni en bash -c).
dotfiles_git_set() {
  local file="$1" key="$2" value="$3"
  command -v git >/dev/null 2>&1 || return 1
  git config --file "$file" "$key" "$value"
}

# dotfiles_cleanup_run: elimina temporales de esta ejecucion (idempotente).
dotfiles_cleanup_run() {
  rm -f "${TMPDIR:-/tmp}/dotfiles-backup-${DOTFILES_RUN_ID}-"* 2>/dev/null || true
}
