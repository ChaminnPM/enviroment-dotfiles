#!/usr/bin/env bash
# setup-git-identity.sh - configura identidad(es) git y prueba SSH
set -euo pipefail

# Colores
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

# --- Personal (GitHub) — obligatorio ---
info "Configurando cuenta PERSONAL (GitHub)"
read -rp "Nombre: " P_NAME
read -rp "Email: " P_EMAIL
if [ ! -f "$HOME/.ssh/id_ed25519_personal" ]; then
  ssh-keygen -t ed25519 -C "$P_EMAIL" -f "$HOME/.ssh/id_ed25519_personal" -N "" || { err "Fallo generando llave personal"; exit 1; }
fi

# --- Nuxiba (Bitbucket) — opcional ---
echo ""
read -rp "Configurar cuenta NUXIBA (Bitbucket)? (y/N): " nux
if [ "$nux" = "y" ] || [ "$nux" = "Y" ]; then
  info "Configurando cuenta NUXIBA (Bitbucket)"
  read -rp "Nombre: " N_NAME
  read -rp "Email: " N_EMAIL
  if [ ! -f "$HOME/.ssh/id_ed25519_nuxiba" ]; then
    ssh-keygen -t ed25519 -C "$N_EMAIL" -f "$HOME/.ssh/id_ed25519_nuxiba" -N "" || { err "Fallo generando llave nuxiba"; exit 1; }
  fi
  NUXIBA_ENABLED=1
else
  warn "Saltando cuenta Nuxiba (opcional)."
  NUXIBA_ENABLED=0
fi

# SSH config
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

# gitconfig
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
info "Claves publicas (agregalas a GitHub/Bitbucket):"
echo -e "${YELLOW}--- PERSONAL (GitHub) ---${NC}"
cat "$HOME/.ssh/id_ed25519_personal.pub"
if [ "$NUXIBA_ENABLED" = "1" ]; then
  echo -e "${YELLOW}--- NUXIBA (Bitbucket) ---${NC}"
  cat "$HOME/.ssh/id_ed25519_nuxiba.pub"
fi
echo ""

info "Agrega las claves publicas arriba a GitHub (y Bitbucket si aplica)."
read -rp "Presiona Enter cuando hayas agregado las claves para probar las conexiones..." _

echo ""
info "Probando conexiones SSH..."
if ssh -T git@github.com 2>&1 | grep -q "successfully authenticated"; then
  ok "GitHub OK"
else
  err "GitHub fallo. Verifica la clave."
fi
if [ "$NUXIBA_ENABLED" = "1" ]; then
  if ssh -T git@bitbucket-nuxiba 2>&1 | grep -q "logged in"; then
    ok "Bitbucket OK"
  else
    warn "Bitbucket fallo (opcional)."
  fi
fi

echo ""
ok "Configuracion de identidad completada."