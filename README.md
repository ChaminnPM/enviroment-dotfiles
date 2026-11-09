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
   - Instala `nui` (binario propio con [bubbletea](https://github.com/charmbracelet/bubbletea)) si falta o si la version instalada difiere de `bin/VERSION`, y lo usa para banners, spinners y prompts.
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
- `nui`: binario estatico propio (bubbletea + lipgloss) que se instala automaticamente desde `bin/nui-<os>-<arch>.gz` (o `NUI_BASE_URL`).
- `herdr` y `oh-my-bash`: se instalan automaticamente.

## Comportamiento visual
- La UI usa `nui steps run` (binario propio en Go con bubbletea/lipgloss; fuente en `ui/`, binarios en `bin/`): un panel de dos columnas con el listado de pasos (`[✓]`/`[!]`/`[✗]`) y el detalle del paso activo (progreso, contador `paso N de M` y logs). Si `nui` no esta disponible, hay fallback textual/ANSI.
- Los pasos se definen en `scripts/lib/ui.sh` (`ui_panel_step`) como un plan JSON que `nui` ejecuta; los prompts y selecciones se resuelven antes del panel, salvo los pasos interactivos (`--interactive`), que ceden la terminal (por ejemplo `setup-git-identity.sh`).
- Cada paso emite `##progress N`, `##log T` y `##warn T` para el panel; la salida de `apt-get`, `npm`, `git clone`, OpenCode, herdr y SSH se guarda en logs.
- Al terminar se muestra un **reporte final**: secciones `INSTALADO`, `AVISOS` y `ERRORES` (exit 1 si hay errores). `q`/`esc`/`ctrl+c` cancelan la ejecucion (exit 1).
- Las cajas se ajustan al ancho de la terminal y el panel se adapta al tamano de la ventana.
- Las claves publicas se muestran por fingerprint y archivo; la clave completa puede verse con `nui pager`.
- Los prompts (input/confirm/choose) resuelven TTY via `/dev/tty`, por lo que funcionan con `curl | bash`.

## Modo verbose
Por defecto el instalador oculta el ruido de `apt-get`, `npm`, `git clone`, OpenCode y herdr, guardando logs en:
```bash
~/.local/state/enviroment-dotfiles/logs
```

Para ver toda la salida:
```bash
VERBOSE=1 bash bootstrap.sh
bash bootstrap.sh --verbose
sync-dotfiles pull --verbose
sync-dotfiles push --verbose
```

El one-liner inicial usa un fallback silencioso antes de tener `nui`; cuando `nui` ya esta disponible muestra banners, spinners, prompts y reporte final.

- Los scripts usan `nui` para mejorar legibilidad y tienen fallback textual/ANSI.
- `analyze-webrtc-dumps` es un **agente**, no una skill.
- El repo publico no debe contener assets Nuxiba privados.
