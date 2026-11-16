# enviroment-dotfiles (publico)

Configuracion portable de OpenCode para **Linux** (Debian/Ubuntu, apt-get).

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
   - Configura las cuentas Git: personal obligatoria y hasta 3 espacios opcionales con carpeta propia (ver "Cuentas Git" mas abajo). Para omitirlo:
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
- `config/alacritty/`: config base de Alacritty (TOML, requiere alacritty >= 0.13); solo se instala si `alacritty` esta en el PATH y no existe configuracion previa. `windows/` guarda la copia exacta de la config de Windows (arranque de WSL Debian); la raiz es la version portable adaptada a Linux.
- `agents/`: `net-qa`, `react-qa`, `lua-qa`. (`analyze-webrtc-dumps` vive en el repo privado.)
- `skills/`: `generate-test-cases`, `generate-tests`, `graphify` (externa), `security-audit` (externa).
- `plugins/`: `herdr-agent-state.js`, `usage-limits`.
- `memory/skills-best-practices.md`: guia de escritura de skills/agents.
- `AGENTS.md`: instrucciones generales con graphify.
- `scripts/`: instalacion, sincronizacion, identidad Git y actualizacion de skills externas.
- `.github/workflows/ci.yml`: CI con bash -n, shellcheck y validacion de TOML/JSON en cada push.

## service.json.example
`service.json.example` es la plantilla de configuracion privada local. Se copia a
`~/.config/opencode/service.json` (fuera del repo; el push lo excluye siempre) y se
rellena con credenciales o ajustes que no deben versionarse. No existe en la
instalacion hasta que la crees manualmente a partir del ejemplo.

## Cuentas Git (SSH + includeIf)
`setup-git-identity.sh` configura **una cuenta personal obligatoria** y **hasta 3
cuentas opcionales** ("espacios"):

- **Personal**: clave `~/.ssh/id_ed25519_personal`, perfil `~/.gitconfig-personal`;
  actua en **todo el sistema** (`includeIf "gitdir:$HOME/"`) salvo en las carpetas
  de los espacios. Su plataforma (github/bitbucket) se pregunta en la instalacion.
- **Espacios**: cada cuenta vive en una carpeta de `$HOME` cuyo nombre pide el
  instalador (ej. `~/Nuxiba`). Tiene clave `id_ed25519_<slug>`, perfil
  `~/.gitconfig-<slug>` y alias SSH `git-<slug>`. Dentro de la carpeta,
  `includeIf` cambia `user.name/email` y un bloque `url.insteadOf` reescribe los
  remotes de la plataforma al alias, de modo que los remotes se autentican con la
  clave de esa cuenta aunque la plataforma coincida con la de la personal.
- **Estado**: el resultado queda en `~/.config/git-accounts.sh` (manifiesto
  generado). El paso "Probar llaves SSH" del bootstrap y `sync-dotfiles doctor`
  lo leen; para agregar/renombrar cuentas, relanza `bootstrap.sh`.
- **`~/.ssh/config`**: solo se regenera la seccion entre los marcadores
  `# >>> dotfiles-managed` / `# <<< dotfiles-managed`; cualquier bloque propio
  del usuario fuera de los marcadores se conserva.
- **Validaciones**: el nombre del espacio se normaliza a slug (sin espacios ni
  acentos), se rechazan duplicados, nombres que empiezan por `.` y rutas con `/`
  (no se permiten carpetas anidadas entre espacios).
- **Migracion**: si existia el esquema viejo (repos Nuxiba en
  `~/Documents/Repositorios`) y hay exactamente una cuenta opcional, su contenido
  se mueve a la carpeta del espacio y el include legado desaparece.
- **Limitacion**: un repo personal clonado *dentro* de la carpeta de un espacio
  usara la clave de ese espacio para la plataforma del espacio (limitacion de
  `insteadOf`, aplicado por carpeta).

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
sync-dotfiles doctor

sync-dotfiles-private pull
sync-dotfiles-private push
```

`doctor` verifica el estado del entorno (versiones vs pins, skills externas, claves SSH) y sale 1 si hay avisos.

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
- Base: `git`, `curl`, `bash`, `python3`, `node` (nvm), `npm`, `rsync`, `openssh-client`, `xdg-utils`, `tar`, `gzip` (instalados por `bootstrap.sh` si faltan).
- `nui`: binario estatico propio (bubbletea + lipgloss) que se instala automaticamente desde `bin/nui-<os>-<arch>.gz` (o `NUI_BASE_URL`).
- `herdr` y `oh-my-bash`: se instalan automaticamente.

## Comportamiento visual
- La UI usa `nui steps run` (binario propio en Go con bubbletea/lipgloss; fuente en `ui/`, binarios en `bin/`): un panel de dos columnas con el listado de pasos (`[✓]`/`[!]`/`[✗]`) y el detalle del paso activo (progreso, contador `paso N de M` y logs). Si `nui` no esta disponible, hay fallback textual/ANSI.
- Los pasos se definen en `scripts/lib/ui.sh` (`ui_panel_step`); los prompts (texto, password, confirmacion y seleccion multiple) se resuelven **dentro del panel** con `ui_panel_inputs`, por lo que ninguna pantalla anterior aparece durante la instalacion.
- Los pasos opcionales (credenciales sudo, identidad Git, .NET) se pueden **omitir** con `esc` sin detener la instalacion; los prompts y selecciones se resuelven antes del panel solo cuando no hay TTY.
- La prueba de llaves SSH es un paso opcional **despues** de generar las claves, para que puedas agregarlas a GitHub/Bitbucket antes de probar (tambien puede mostrarlas en el panel; si la prueba falla, la clave se muestra automaticamente).
- Si el sistema necesita `apt`, el paso **Credenciales sudo** pide la contraseña en un TTY real para cachearla; si se omite, los pasos con apt se muestran como avisos con la salida de apt.
- Cada paso emite `##progress N`, `##log T` y `##warn T` para el panel; la salida de `apt-get`, `npm`, `git clone`, OpenCode, herdr y SSH se guarda en logs.
- Al terminar, el **reporte final** (`INSTALADO` / `AVISOS` / `ERRORES`) se muestra como estado final dentro del panel; `q` sale (exit 1 si hay errores). `q`/`esc`/`ctrl+c` durante la ejecucion cancelan (exit 1).
- Las cajas se ajustan al ancho de la terminal y el panel se adapta al tamano de la ventana.
- SSH no debe pedir host key durante la instalación: se usan `ssh-keyscan` y `StrictHostKeyChecking=accept-new`.

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
- `analyze-webrtc-dumps` es un **agente**, no una skill; se gestiona desde el repo privado.
- El repo publico no debe contener assets Nuxiba privados.
