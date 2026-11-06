#!/usr/bin/env bash
# setup-git-identity.sh - configura identidad(es) git (sin validar SSH)
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
# shellcheck source=lib/ui.sh
source "$REPO_DIR/scripts/lib/ui.sh"

ui_title "Identidad Git"

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

ui_section "Cuenta PERSONAL (GitHub)"
P_NAME="$(ui_input "Nombre:" "Tu nombre")"
P_EMAIL="$(ui_input "Email:" "tu@email.com")"
if [ ! -f "$HOME/.ssh/id_ed25519_personal" ]; then
  ssh-keygen -t ed25519 -C "$P_EMAIL" -f "$HOME/.ssh/id_ed25519_personal" -N "" || { ui_error "Fallo generando llave personal"; exit 1; }
fi

echo ""
NUXIBA_ENABLED=0
if ui_ask "Configurar cuenta NUXIBA (Bitbucket)?"; then
  ui_section "Cuenta NUXIBA (Bitbucket)"
  N_NAME="$(ui_input "Nombre:" "Tu nombre Nuxiba")"
  N_EMAIL="$(ui_input "Email:" "tu@nuxiba.com")"
  if [ ! -f "$HOME/.ssh/id_ed25519_nuxiba" ]; then
    ssh-keygen -t ed25519 -C "$N_EMAIL" -f "$HOME/.ssh/id_ed25519_nuxiba" -N "" || { ui_error "Fallo generando llave nuxiba"; exit 1; }
  fi
  NUXIBA_ENABLED=1
else
  ui_warn "Saltando cuenta Nuxiba (opcional)."
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

echo ""
ui_info "Claves publicas (agregalas a GitHub/Bitbucket):"
echo "--- PERSONAL (GitHub) ---"
cat "$HOME/.ssh/id_ed25519_personal.pub"
if [ "$NUXIBA_ENABLED" = "1" ]; then
  echo "--- NUXIBA (Bitbucket) ---"
  cat "$HOME/.ssh/id_ed25519_nuxiba.pub"
fi
echo ""

ui_info "Agrega las claves publicas arriba a GitHub (y Bitbucket si aplica)."
if command -v gum >/dev/null 2>&1; then
  gum input --placeholder "Presiona Enter para continuar..." >/dev/null || true
else
  read -rp "Presiona Enter para continuar..." _ < /dev/tty
fi

echo ""
ui_info "Ejecutando comprobacion de conexiones SSH (solo informativo)..."
ssh -T git@github.com 2>&1 || true
if [ "$NUXIBA_ENABLED" = "1" ]; then
  ssh -T git@bitbucket-nuxiba 2>&1 || true
fi

echo ""
ui_ok "Configuracion de identidad completada."
