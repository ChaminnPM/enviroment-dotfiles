#!/usr/bin/env bash
# setup-git-identity.sh - configura identidad(es) git con UI nui (bubbletea).
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
# shellcheck source=lib/ui.sh
source "$REPO_DIR/scripts/lib/ui.sh"
ensure_log_dir

# Prompt con nui si hay TTY; env/default como fallback no interactivo.
_ask() {
  local prompt="$1" env_name="$2" default="${3:-}" value=""
  if ui_have; then
    value="$(ui_input "$prompt" "$default")" || value=""
  elif [ -t 0 ]; then
    read -rp "$prompt " value
  fi
  if [ -z "$value" ]; then
    value="${!env_name:-$default}"
  fi
  printf '%s' "$value"
}

ui_clear
ui_banner "Identidad Git" "GitHub / Bitbucket"

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

ui_section "Cuenta PERSONAL (GitHub)"
P_NAME="$(_ask "Nombre:" GIT_PERSONAL_NAME "")"
P_EMAIL="$(_ask "Email:" GIT_PERSONAL_EMAIL "")"
if [ -z "$P_NAME" ] || [ -z "$P_EMAIL" ]; then
  ui_error "Nombre y email GitHub son obligatorios"
  exit 1
fi
if [ ! -f "$HOME/.ssh/id_ed25519_personal" ]; then
  ui_logged "Generando clave personal..." "ssh-keygen -t ed25519 -C '$P_EMAIL' -f '$HOME/.ssh/id_ed25519_personal' -N '' >/dev/null 2>&1" || { ui_error "Fallo generando llave personal"; exit 1; }
fi

ui_section "Cuenta NUXIBA (Bitbucket) (opcional)"
NUXIBA_ENABLED=0
if ! ui_interactive && [ "${GIT_NUXIBA_ENABLED:-}" != "1" ]; then
  ui_warn "Cuenta Nuxiba omitida (no interactivo)."
elif ui_ask "¿Configurar cuenta NUXIBA (Bitbucket)?"; then
  N_NAME="$(_ask "Nombre:" GIT_NUXIBA_NAME "")"
  N_EMAIL="$(_ask "Email:" GIT_NUXIBA_EMAIL "")"
  if [ -n "$N_NAME" ] && [ -n "$N_EMAIL" ]; then
    if [ ! -f "$HOME/.ssh/id_ed25519_nuxiba" ]; then
      ui_logged "Generando clave Nuxiba..." "ssh-keygen -t ed25519 -C '$N_EMAIL' -f '$HOME/.ssh/id_ed25519_nuxiba' -N '' >/dev/null 2>&1" || { ui_error "Fallo generando llave nuxiba"; exit 1; }
    fi
    NUXIBA_ENABLED=1
  fi
else
  ui_dim "Cuenta Nuxiba no configurada."
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
ui_summary "GitHub personal" "Archivo: ~/.ssh/id_ed25519_personal.pub" "Fingerprint: $gh_fp"
if [ "$NUXIBA_ENABLED" = "1" ]; then
  nx_fp="$(ssh-keygen -lf "$HOME/.ssh/id_ed25519_nuxiba.pub" 2>/dev/null | awk '{print $2}' || echo '?')"
  ui_summary "Nuxiba Bitbucket" "Archivo: ~/.ssh/id_ed25519_nuxiba.pub" "Fingerprint: $nx_fp"
fi

if ui_interactive && ui_ask "¿Ver claves publicas completas ahora?"; then
  ui_seed_known_hosts
  ui_pager "$HOME/.ssh/id_ed25519_personal.pub"
  if [ "$NUXIBA_ENABLED" = "1" ]; then
    ui_pager "$HOME/.ssh/id_ed25519_nuxiba.pub"
  fi
else
  ui_dim "Guarda las claves de los archivos listados y agrégalas a GitHub/Bitbucket."
fi

ui_ssh_test "Comprobando SSH GitHub..." git@github.com && ui_ok "GitHub SSH OK" || ui_warn "GitHub SSH falla"
if [ "$NUXIBA_ENABLED" = "1" ]; then
  ui_ssh_test "Comprobando SSH Bitbucket..." git@bitbucket-nuxiba && ui_ok "Bitbucket SSH OK" || ui_warn "Bitbucket SSH falla"
fi

ui_ok "Configuracion de identidad completada."
