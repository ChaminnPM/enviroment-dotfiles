#!/usr/bin/env bash
# setup-git-identity.sh - configura dos identidades git (personal + nuxiba) y prueba SSH
set -euo pipefail

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

# --- Personal (GitHub) ---
read -rp "Nombre para cuenta PERSONAL (GitHub): " P_NAME
read -rp "Email para cuenta PERSONAL (GitHub): " P_EMAIL
if [ ! -f "$HOME/.ssh/id_ed25519_personal" ]; then
  ssh-keygen -t ed25519 -C "$P_EMAIL" -f "$HOME/.ssh/id_ed25519_personal" -N ""
fi

# --- Nuxiba (Bitbucket) ---
read -rp "Nombre para cuenta NUXIBA (Bitbucket): " N_NAME
read -rp "Email para cuenta NUXIBA (Bitbucket): " N_EMAIL
if [ ! -f "$HOME/.ssh/id_ed25519_nuxiba" ]; then
  ssh-keygen -t ed25519 -C "$N_EMAIL" -f "$HOME/.ssh/id_ed25519_nuxiba" -N ""
fi

# SSH config
cat > "$HOME/.ssh/config" <<EOF
Host github.com
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_ed25519_personal
    IdentitiesOnly yes

Host bitbucket-nuxiba
    HostName bitbucket.org
    User git
    IdentityFile ~/.ssh/id_ed25519_nuxiba
    IdentitiesOnly yes
EOF
chmod 600 "$HOME/.ssh/config"

# gitconfig con includeIf
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
cat > "$HOME/.gitconfig-nuxiba" <<EOF
[user]
    name = $N_NAME
    email = $N_EMAIL
EOF

echo ""
echo "==> Claves publicas (agregalas a GitHub/Bitbucket):"
echo "--- PERSONAL (GitHub) ---"
cat "$HOME/.ssh/id_ed25519_personal.pub"
echo "--- NUXIBA (Bitbucket) ---"
cat "$HOME/.ssh/id_ed25519_nuxiba.pub"
echo ""

echo "==> Agrega las claves publicas arriba a GitHub y Bitbucket AHORA."
read -rp "Presiona Enter cuando hayas agregado las claves para probar las conexiones..." _

echo ""
echo "==> Probando conexiones SSH..."
ssh -T git@github.com 2>&1 || true
ssh -T git@bitbucket-nuxiba 2>&1 || true

echo ""
echo "Si ambas conexiones respondieron OK, puedes continuar con bootstrap.sh"