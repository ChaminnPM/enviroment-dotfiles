# enviroment-dotfiles (publico)

Configuracion portable de OpenCode para Linux/macOS.

## One-liner
```bash
curl -fsSL https://raw.githubusercontent.com/ChaminnPM/enviroment-dotfiles/main/install.sh | bash
```

El one-liner descarga el repo como **tarball** y no requiere `git` para empezar. Luego `bootstrap.sh` instala dependencias base (`git`, `curl`, `python3`, `tar`, `gzip`, `rsync`, `openssh-client`, etc.) antes de los pasos que las necesitan.

## Orden actual de instalacion
1. Verificar herramientas minimas para descargar/instalar: `curl`, `tar`, `gzip`.
2. Descargar el repo publico como tarball a un directorio temporal.
3. Ejecutar `bootstrap.sh`.
4. `bootstrap.sh`:
   - Instala `git` y dependencias base si faltan.
   - Instala `gum` si falta y muestra banners/spinners con gum.
   - Configura identidad Git por defecto. Para omitirla:
     ```bash
     SKIP_GIT_IDENTITY=1 bash bootstrap.sh
     # o
     bash bootstrap.sh --skip-git
     ```
   - Permite seleccionar paquetes custom adicionales:
     - `lazyvim`
     - `lazygit`
     - `fzf`
     - `ripgrep`
     - `bat`
     - `eza`
     - `zoxide`
     - `fd-find`
   - Instala Node/nvm, OpenCode, configuracion publica, `graphify`, `oh-my-bash` y `herdr`.
   - Instala el wrapper publico `sync-dotfiles`.
5. Elimina el directorio temporal del repo: no queda `~/enviroment-dotfiles` instalado localmente.

## Contenido publico
- `config/opencode/`: config global de OpenCode, sin contenido Nuxiba.
- `agents/`: `net-qa`, `react-qa`, `lua-qa`, `analyze-webrtc-dumps`.
- `skills/`: `generate-test-cases`, `generate-tests`, `graphify` (externa), `security-audit` (externa).
- `plugins/`: `herdr-agent-state.js`, `usage-limits`.
- `memory/skills-best-practices.md`: guia de escritura de skills/agents.
- `AGENTS.md`: instrucciones generales con graphify.
- `scripts/`: instalacion, sincronizacion, identidad Git y actualizacion de skills externas.

## Skills externas
- `graphify`: https://github.com/Graphify-Labs/graphify
- `security-audit`: https://github.com/cloudflare/security-audit-skill

Cada skill externa incluye `VERSION.json`. Para consultar/actualizar:
```bash
bash scripts/update-external-skills.sh check
bash scripts/update-external-skills.sh update
```

## Sincronizacion
La instalacion no deja repos locales. Usa los wrappers instalados en `~/.local/bin`:
```bash
sync-dotfiles pull
sync-dotfiles push

sync-dotfiles-private pull
sync-dotfiles-private push
```

Los wrappers verifican que exista `git` antes de sincronizar.

Alternativa sin wrapper para el repo publico:
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ChaminnPM/enviroment-dotfiles/main/scripts/sync.sh) pull
bash <(curl -fsSL https://raw.githubusercontent.com/ChaminnPM/enviroment-dotfiles/main/scripts/sync.sh) push
```

Para desarrollo local del repo:
```bash
git clone https://github.com/ChaminnPM/enviroment-dotfiles.git
cd enviroment-dotfiles
bash scripts/sync.sh pull
bash scripts/sync.sh push
```

## Requiere
- Base: `git`, `curl`, `bash`, `python3`, `node` (nvm), `npm`, `rsync`, `openssh-client`, `xdg-utils`, `tar`, `gzip`.
- `gum`: se instala automaticamente si falta.
- `herdr` y `oh-my-bash`: se instalan automaticamente.

## Notas
- Los scripts usan `gum` para mejorar legibilidad y tienen fallback textual/ANSI.
- `analyze-webrtc-dumps` es un **agente**, no una skill.
- El repo publico no debe contener assets Nuxiba privados.
