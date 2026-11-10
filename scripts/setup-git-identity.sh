#!/usr/bin/env bash
# setup-git-identity.sh - configura identidad(es) git.
# Modo panel: los valores vienen de $NUI_STEP_RESULT (los pide el panel).
# Modo standalone: se piden con nui input (sin banners).
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
# shellcheck source=lib/ui.sh
source "$REPO_DIR/scripts/lib/ui.sh"
ensure_log_dir

PANEL_MODE=0
if [ -n "${NUI_STEP_RESULT:-}" ] && [ -f "$NUI_STEP_RESULT" ]; then
  # shellcheck disable=SC1090
  . "$NUI_STEP_RESULT"
  PANEL_MODE=1
fi

log_line() { printf '%s\n' "$*"; }
# En modo panel, ##log alimenta la columna de logs; en standalone es texto plano.
say() {
  if [ "$PANEL_MODE" = "1" ]; then printf '##log %s\n' "$*"; else log_line "$*"; fi
}

_ask() {
  local prompt="$1" env_name="$2" default="${3:-}" value=""
  if [ "$PANEL_MODE" = "1" ]; then
    value="${!env_name:-}"
  elif ui_have; then
    value="$(ui_input "$prompt" "$default")" || value=""
  elif [ -t 0 ]; then
    read -rp "$prompt " value
  fi
  if [ -z "$value" ]; then
    value="${!env_name:-$default}"
  fi
  printf '%s' "$value"
}

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

# --- cuenta personal (GitHub) -------------------------------------------
if [ "$PANEL_MODE" = "1" ]; then
  P_NAME="${p_name:-}"
  P_EMAIL="${p_email:-}"
else
  P_NAME="$(_ask "Nombre (GitHub):" GIT_PERSONAL_NAME "")"
  P_EMAIL="$(_ask "Email (GitHub):" GIT_PERSONAL_EMAIL "")"
fi
if [ -z "$P_NAME" ] || [ -z "$P_EMAIL" ]; then
  say "Identidad GitHub omitida (nombre/email vacíos)."
  exit 0
fi

run_cmd() {
  # run_cmd <comando>: en panel emite ##log y guarda el log; standalone directo.
  if [ "$PANEL_MODE" = "1" ]; then
    local log="$LOG_DIR/identity-$(date +%Y%m%d-%H%M%S)-$$.log"
    if bash -c "$1" >"$log" 2>&1 </dev/null; then return 0; fi
    tail -n 5 "$log" 2>/dev/null | while IFS= read -r l; do say "$l"; done
    return 1
  fi
  bash -c "$1"
}

if [ ! -f "$HOME/.ssh/id_ed25519_personal" ]; then
  say "Generando clave personal..."
  run_cmd "ssh-keygen -t ed25519 -C '$P_EMAIL' -f '$HOME/.ssh/id_ed25519_personal' -N '' >/dev/null 2>&1" || {
    say "No se pudo generar la clave personal."
    exit 1
  }
fi

# --- cuenta NUXIBA (Bitbucket, opcional) --------------------------------
NUXIBA_ENABLED=0
if [ "$PANEL_MODE" = "1" ]; then
  NUXIBA_ENABLED=0
  case "${nuxiba:-false}" in true) NUXIBA_ENABLED=1 ;; esac
  N_NAME="${n_name:-}"
  N_EMAIL="${n_email:-}"
else
  if ! ui_interactive && [ "${GIT_NUXIBA_ENABLED:-}" != "1" ]; then
    say "Cuenta Nuxiba omitida (no interactivo)."
  elif ui_ask "¿Configurar cuenta NUXIBA (Bitbucket)?"; then
    N_NAME="$(_ask "Nombre (Nuxiba):" GIT_NUXIBA_NAME "")"
    N_EMAIL="$(_ask "Email (Nuxiba):" GIT_NUXIBA_EMAIL "")"
    [ -n "$N_NAME" ] && [ -n "$N_EMAIL" ] && NUXIBA_ENABLED=1
  else
    say "Cuenta Nuxiba no configurada."
  fi
fi

if [ "$NUXIBA_ENABLED" = "1" ]; then
  if [ -z "$N_NAME" ] || [ -z "$N_EMAIL" ]; then
    N_NAME="${N_NAME:-$P_NAME}"
    N_EMAIL="${N_EMAIL:-$P_EMAIL}"
    say "Nuxiba: no se indicaron nombre/email; se usan los personales."
  fi
  if [ ! -f "$HOME/.ssh/id_ed25519_nuxiba" ]; then
    say "Generando clave Nuxiba..."
    run_cmd "ssh-keygen -t ed25519 -C '$N_EMAIL' -f '$HOME/.ssh/id_ed25519_nuxiba' -N '' >/dev/null 2>&1" || {
      say "No se pudo generar la clave Nuxiba."
      NUXIBA_ENABLED=0
    }
  fi
fi

{
  echo "Host github.com"
  echo "    HostName github.com"
  echo "    User git"
  echo "    IdentityFile ~/.ssh/id_ed25519_personal"
  echo "    IdentitiesOnly yes"
  if [ "$NUXIBA_ENABLED" = "1" ]; then
    echo ""
    echo "Host bitbucket-nuxiba"
    echo "    HostName bitbucket.org"
    echo "    User git"
    echo "    IdentityFile ~/.ssh/id_ed25519_nuxiba"
    echo "    IdentitiesOnly yes"
  fi
} > "$HOME/.ssh/config"
chmod 600 "$HOME/.ssh/config"

cat > "$HOME/.gitconfig" <<EOF
[includeIf "gitdir:$HOME/Documents/Repositorios/"]
    path = $HOME/.gitconfig-nuxiba
[includeIf "gitdir:$HOME/"]
    path = $HOME/.gitconfig-personal
EOF

cat > "$HOME/.gitconfig-personal" <<EOF
[user]
    name = $P_NAME
    email = $P_EMAIL
EOF

if [ "$NUXIBA_ENABLED" = "1" ]; then
  cat > "$HOME/.gitconfig-nuxiba" <<EOF
[user]
    name = $N_NAME
    email = $N_EMAIL
EOF
fi

gh_fp="$(ssh-keygen -lf "$HOME/.ssh/id_ed25519_personal.pub" 2>/dev/null | awk '{print $2}' || echo '?')"
say "GitHub personal: ~/.ssh/id_ed25519_personal.pub ($gh_fp)"
if [ "$NUXIBA_ENABLED" = "1" ]; then
  nx_fp="$(ssh-keygen -lf "$HOME/.ssh/id_ed25519_nuxiba.pub" 2>/dev/null | awk '{print $2}' || echo '?')"
  say "Nuxiba Bitbucket: ~/.ssh/id_ed25519_nuxiba.pub ($nx_fp)"
fi
say "Guarda las claves publicas en GitHub/Bitbucket."

# --- comprobacion SSH (sin spinner dentro del panel) --------------------
ssh_check() {
  local title="$1" target="$2"
  ui_seed_known_hosts
  local out
  if out="$(ssh -T -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10 "$target" 2>&1 || true)"; then
    if printf '%s\n' "$out" | grep -Eiq 'successfully authenticated|logged in as'; then
      say "$title OK"
      return 0
    fi
  fi
  say "$title falla (revisa que la clave este agregada)."
  return 1
}
if [ "$PANEL_MODE" = "1" ]; then
  say "Claves listas; el paso siguiente te permitira probar la conexion."
else
  if ui_interactive && ui_ask "¿Probar la conexion SSH ahora?"; then
    ssh_check "SSH GitHub" git@github.com || true
    if [ "$NUXIBA_ENABLED" = "1" ]; then
      ssh_check "SSH Bitbucket" git@bitbucket-nuxiba || true
    fi
  else
    say "Prueba SSH omitida (pruébala despues con: ssh -T git@github.com)."
  fi
fi

say "Configuracion de identidad completada."
