# enviroment-dotfiles (publico)

Configuracion portable de OpenCode con instalador automatico para **Linux, WSL
y Windows nativo**. En Linux/WSL funciona con `apt-get` (Debian/Ubuntu), `dnf`
(Fedora/RHEL), `pacman` (Arch), `zypper` (openSUSE) y `apk` (Alpine); en
Windows nativo usa **winget** con ZIPs pinnados de respaldo, sin WSL y sin Git
Bash. macOS **no esta soportado**: ver [`docs/PLATFORMS.md`](docs/PLATFORMS.md).

Hay **dos capas de runner sobre los mismos datos**: `bootstrap.sh` +
`scripts/lib/*.sh` para Linux/WSL y `bootstrap.ps1` + `scripts/lib/*.psm1` para
Windows. `nui` (Go) es comun a las dos. El contrato que las mantiene
sincronizadas esta en [`docs/STEPS.md`](docs/STEPS.md).

Incluye un tema canonico (**Dracula + JetBrainsMono Nerd Font**) que se aplica
a todas las herramientas durante la instalacion, incluida la instalacion de
la fuente.

## Instalacion

### Linux o WSL

```bash
curl -fsSL https://raw.githubusercontent.com/ChaminnPM/enviroment-dotfiles/main/install.sh | bash
```

### Windows nativo (10 22H2+ / 11, x64)

```powershell
powershell -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/ChaminnPM/enviroment-dotfiles/main/install.ps1 | iex"
```

Sin WSL y sin Git Bash. Por defecto **no pide admin**: winget en `--scope user`
y ZIPs portatiles pinnados. Guia completa (requisitos, rutas, paquetes,
troubleshooting): [`docs/WINDOWS.md`](docs/WINDOWS.md). Si el one-liner falla
por politica de ejecucion o proxy, usa `install.cmd`.

El instalador descarga el repo como **tarball** y no requiere `git` para empezar. Luego `bootstrap.sh` instala dependencias base (`git`, `curl`, `python3`, `tar`, `gzip`, `rsync`, `openssh-client`, etc.) antes de los pasos que las necesitan.

Para el repo privado (`enviroment-dotfiles-secrets`) usa el launcher público, que clona por SSH (raw no sirve repos privados):

```bash
curl -fsSL https://raw.githubusercontent.com/ChaminnPM/enviroment-dotfiles/main/install-private.sh | bash
```

En Windows el instalador baja el repo como **ZIP** y `bootstrap.ps1` equivale
paso a paso a `bootstrap.sh` (18 pasos, mismos titulos; el de terminal pasa de
`Alacritty` a `Windows Terminal (tema)`).

El instalador fija las host keys de GitHub/Bitbucket en
`~/.ssh/known_hosts` desde `config/ssh/known_hosts` (sin `ssh-keyscan`). El
launcher privado además descarga ese pin y lo usa vía `GIT_SSH_COMMAND`, para
que `git`/`ssh` funcionen aunque el `known_hosts` del usuario esté vacío.

El PATH de las herramientas instaladas (nvm, opencode, herdr, nvim,
`~/.local/bin`) se persiste automáticamente: el instalador agrega bloques
gestionados que cargan `~/.config/enviroment-dotfiles/env.sh` desde `~/.bashrc`,
`~/.profile`, `~/.bash_profile` (para shells de login, que tienen prioridad sobre
`~/.profile` en WSL/SSH/`bash -l`) y `~/.zshrc` si zsh está instalado. Por eso
**una terminal nueva ya trae todo cargado, sin ejecutar `exec $SHELL`**. También
puedes cargarlo en la sesión actual:

```bash
. "$HOME/.config/enviroment-dotfiles/env.sh"
```

**No uses `exec "$SHELL"`**: reemplaza el proceso de la shell actual y, si la
configuración de inicio falla o la terminal cierra al salir de esa shell, te
deja fuera de la sesión.

## Seguridad

- Host keys de GitHub/Bitbucket **pinadas** en `config/ssh/known_hosts` (chmod
  `0600`), installadas con backup y sin `ssh-keyscan` ni
  `StrictHostKeyChecking=accept-new`.
- Sin `eval` ni `bash -c` con variables interpoladas: el runner usa
  `ui_logged_argv <titulo> <cmd> [args...]` y los comandos se pasan como argv.
- Logs y archivos `result-NN.env` se crean con `0600` dentro de directorios
  `0700`.
- El wrapper `sync-dotfiles` ya no ejecuta código remoto con `bash <(curl …)`;
  clona el repo en un temporal (`SYNC_REF`/`SYNC_SHA`) y ejecuta el script local.

## Orden actual de instalacion
1. Verificar herramientas minimas para descargar/instalar: `curl`, `tar`, `gzip`.
2. Descargar el repo publico como tarball a un directorio temporal.
3. Ejecutar `bootstrap.sh`.
4. `bootstrap.sh`:
   - Instala `git` y dependencias base si faltan (paquetes de escritorio solo si hay `DISPLAY`/`WAYLAND_DISPLAY`).
   - **Fuente**: instala JetBrainsMono Nerd Font (`v3.4.0`) en `~/.local/share/fonts` si `fc-match` no la encuentra; es idempotente. Es un paso opcional: si falla la descarga o la extracción se registra un aviso y la instalación continúa. Si `fontconfig` aún no ve la fuente, el propio script ejecuta `fc-cache -f` y vuelve a comprobarlo antes de avisar.
   - Instala `nui` (binario propio con [bubbletea](https://github.com/charmbracelet/bubbletea)) si falta o si la version instalada difiere de `bin/VERSION`, y lo usa para banners, spinners y prompts.
   - Configura las cuentas Git: personal obligatoria y hasta 3 espacios opcionales con carpeta propia (ver la sección «Cuentas Git (SSH + includeIf)»). Para omitirlo:
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
   - `neovim` viene seleccionado por defecto (descarga pinnada a `~/.local/nvim` si no hay version > 0.11.2).
   - Aplica Alacritty y, al final, el **tema** a todas las herramientas presentes.
   - Instala el wrapper publico `sync-dotfiles` y ejecuta una **verificación final** (`opencode`, `herdr`, `node`, `npm`, `nvim` y `sync-dotfiles doctor`).
5. Elimina el directorio temporal del repo: no queda `~/enviroment-dotfiles` instalado localmente.

### Equivalente en Windows nativo

`install.ps1` -> ZIP al temporal -> `bootstrap.ps1` -> 18 pasos con el mismo
contrato (`shell: "pwsh"`, `argv` literal, mismas directivas `##log`/`##warn`/
`##progress`/`##confirm`). Los paralelismos y las diferencias:

| Linux/WSL | Windows nativo |
|---|---|
| `sudo` + apt/dnf/pacman/zypper/apk | winget `--scope user` + ZIPs pinnados (sin admin; `-MachineScope` eleva en bloque) |
| `~/.bashrc`, `~/.profile`, `~/.bash_profile` | `$PROFILE` de PowerShell 7 y de 5.1 + `~/.config/enviroment-dotfiles/env.ps1` |
| nvm | fnm (`-NodeManager node` para Node directo) |
| oh-my-bash | oh-my-posh con `dracula.omp.json` vendorizado |
| `~/.config/alacritty` | Windows Terminal (`settings.json`, esquema Dracula + fuente Nerd) |
| fontconfig (`fc-match`) | carpeta de fuentes de usuario + registro HKCU |
| `chmod`/`rsync`/`less` | `icacls`/`Copy-Item`+`robocopy`/`bat` o `more.com` |
| `~/.local/state/enviroment-dotfiles` | `~/.config/enviroment-dotfiles/{logs,state,backups}` |

Ver [`docs/WINDOWS.md`](docs/WINDOWS.md) para requisitos, paquetes y
troubleshooting, y [`docs/STEPS.md`](docs/STEPS.md) para el contrato compartido.

### Opciones del instalador
```bash
bash install.sh --help          # o: bash bootstrap.sh --help

  --verbose            muestra toda la salida (sin panel)
  --dry-run            imprime el plan de pasos y no ejecuta nada
  --non-interactive    no hace preguntas; usa defaults y modo texto
  --no-color           desactiva color (equivale a NO_COLOR=1)
  --only <texto>       ejecuta solo los pasos cuyo titulo contenga <texto>
  --skip-git           omite la configuracion de identidad Git/SSH
```

`install.sh` acepta las mismas opciones y las reenvia a `bootstrap.sh`.
Tambien puedes usar `NUI_DRY_RUN=1`, `NUI_NONINTERACTIVE=1`, `NUI_NO_COLOR=1`
y `VERBOSE=1` como variables de entorno.

`--only <texto>` filtra **solo por título** y no resuelve dependencias entre
pasos: si vuelves a ejecutar `Node + nvm` sin `Dependencias base`, asumes que
`curl`, `tar` y los permisos sudo ya están disponibles. Para una reparación
dirigida, ejecuta los pasos en orden.

### Solución de problemas

Los comandos `bash install.sh --only ...` vuelven a descargar el repositorio,
así que requieren conexión y permisos sudo para los pasos que instalan paquetes.

**La sesión interactiva termina al ejecutar el instalador.** Un `exit 1` suelto
o un `exec "$SHELL"` cierran o reemplazan la shell que invocó el comando. El PATH
puede cargarse sin reemplazar la shell:

```bash
. "$HOME/.config/enviroment-dotfiles/env.sh"   # o abre una terminal nueva
```

**Una terminal nueva no carga la configuración (WSL / login shell).** Si
`shopt -q login_shell` imprime `SÍ`, bash lee `~/.bash_profile`, que opaca a
`~/.profile`. El bloque `dotfiles-shell` debe contener la línea de
`source ~/.bashrc`; si solo tiene los marcadores (`# >>>` / `# <<<`), la shell
nueva no ve el PATH ni oh-my-bash y parece que "nada se cargó". Comprueba y
repara:

```bash
sed -n '/^# >>> dotfiles-shell/,/^# <<< dotfiles-shell/p' "$HOME/.bash_profile"
bash install.sh --only "Persistencia de entorno"
env -i HOME="$HOME" USER="$USER" PATH=/usr/bin:/bin bash -lc 'command -v opencode'
```

`sync-dotfiles doctor` también verifica el contenido de los bloques de arranque,
no solo que existan los marcadores.

**Aviso `Contraseña sudo no activa; el gestor de paquetes no instalara nada`.**
El paso interactivo "Credenciales sudo" pide la contraseña una sola vez y la
reutiliza en los pasos apt con `sudo -S` (el timestamp de sudo es por
TTY/PPID y no se comparte entre los `bash -c` del panel). La contraseña se
guarda solo en el directorio de estado temporal (`0700/0600`) y se borra al
terminar. Si se omite el paso, los paquetes custom se instalan en
`~/.local/bin` desde binarios pinnados de GitHub; si aun asi falta algo:

```bash
sudo -v && sudo -n true
bash install.sh --only "Dependencias base"
```

**Aviso `La fuente esta en disco pero fontconfig sigue sin verla`.** El paso
refresca la caché automáticamente; estos comandos permiten diagnosticarlo:

```bash
find "$HOME/.local/share/fonts" -maxdepth 1 -type f \( -iname '*JetBrains*' -o -iname '*.ttf' -o -iname '*.otf' \) -printf '%f\n'
fc-cache -f "$HOME/.local/share/fonts" && fc-cache -f
fc-match "JetBrainsMono Nerd Font"
fc-list | grep -i JetBrains | head
```

Si no hay archivos, ejecuta ese paso con `bash install.sh --only "Fuente"`.

**Falta compilador C para nvim/LazyVim.** El instalador agrega `build-essential`
(a o `gcc gcc-c++ make` / `base-devel` / `build-base` segun la distro) cuando no
hay `cc`/`gcc`, porque `nvim-treesitter` y otros plugins nativos se compilan. Si
no hay sudo, instálalo manualmente y relanza "Paquetes custom":

```bash
sudo apt install -y build-essential    # Debian/Ubuntu/WSL
```

**Fallo al instalar neovim, nvm, OpenCode o herdr.** Vuelve a ejecutar el paso
correspondiente; si el fallo persiste, revisa los logs en
`~/.local/state/enviroment-dotfiles/logs/`:

```bash
bash install.sh --only "Node + nvm"
bash install.sh --only "OpenCode"
bash install.sh --only "herdr"
```

**Aviso `npm install falló; revisa <log>`.** El paso reintenta con
`--prefer-online` y guarda la salida en `logs/npm-install-*.log`; para
reproducirla de forma visible:

```bash
command -v node && node --version
command -v npm && npm --version
cd "$HOME/.config/opencode" && npm install
```

Casi siempre se debe a que Node/nvm no quedó en el PATH de la sesión actual
(sourcea el env file o abre una terminal nueva). Después repite:

```bash
bash install.sh --only "Restaurar configuración"
```

### Respaldos y bloques gestionados
- Antes de modificar un archivo se crea una copia en
  `~/.local/state/enviroment-dotfiles/backups/` (una por archivo y ejecucion).
- Los archivos se escriben de forma atomica (temporal en el mismo directorio +
  `mv`) conservando permisos; `~/.bashrc` ya no cambia de `0644` a `0600`.
- `~/.bashrc`, `~/.bash_profile`, `~/.gitconfig` y `~/.ssh/config` solo se
  editan entre marcadores (`# >>> dotfiles-...` / `# <<< dotfiles-...`). Si el
  bloque esta incompleto, el script **no** toca el archivo y avisa.
- Los permisos sensibles se fijan: claves SSH y perfiles git `0600`,
  `~/.ssh/config` `0600`, logs en `0700`/`0600`.
- `PATH` de herramientas instaladas (nvm, opencode, herdr, nvim, `~/.local/bin`)
  se persiste en `~/.config/enviroment-dotfiles/env.sh`, que cada paso carga
  antes de ejecutar y que `~/.bashrc` sourcea automáticamente mediante un bloque
  gestionado.

## Contenido publico
- `config/opencode/`: configuración global de OpenCode, sin credenciales ni contenido privado.
- `config/theme/dracula.env`: fuente unica de verdad del tema (paleta, tipografia, pin de Nerd Font y colores de fzf/eza).
- `config/alacritty/`: plantillas TOML (requiere alacritty >= 0.13) generadas desde `config/theme/dracula.env`. `common.toml.tpl` lleva fuente y paleta; `linux.toml.tpl` y `windows-wsl.toml.tpl` son overlays segun el entorno (`DOTFILES_ENV`). Solo se instala si `alacritty` esta en el PATH y no hay configuracion previa no gestionada.
- `agents/`: `net-qa`, `react-qa`, `lua-qa`. (`analyze-webrtc-dumps` vive en el repo privado.)
- `skills/`: `generate-test-cases`, `generate-tests`, `graphify` (externa), `security-audit` (externa).
- `plugins/`: `herdr-agent-state.js` y `google-quota/` (widget de cuota, atajo
  `<leader>o`). Los plugins de paquete se declaran en `opencode.jsonc`.
- `memory/skills-best-practices.md`: guia de escritura de skills/agents.
- `AGENTS.md`: instrucciones generales con graphify.
- `scripts/`: instalacion, sincronizacion, identidad Git y actualizacion de skills externas.
- `.github/workflows/ci.yml`: CI con bash -n, shellcheck, `gofmt`/`go vet`/`go test -race`, validacion de TOML/JSON y build cruzado de `nui`.

## Tema y tipografia
`config/theme/dracula.env` es la **unica** definicion del tema y se aplica en cada instalacion:

- **Paleta Dracula**: fondo `#282a36`, texto `#f8f8f2`, seleccion `#44475a`, y los colores normales/bright que ya usaba `alacritty.toml`.
- **Fuente**: `JetBrainsMono Nerd Font`, tamano `10.0`, Nerd Fonts `v3.4.0`. Se descarga el zip oficial `JetBrainsMono.zip`, se extrae con `python3` en `~/.local/share/fonts` y se refresca `fc-cache`. Si `fc-match` ya la resuelve, no se toca nada.
- **Alacritty**: `common.toml.tpl` + overlay de entorno. En WSL se usa `windows-wsl.toml.tpl` con `wsl.exe`; en Linux puro, `linux.toml.tpl`. Los valores `THEME_WSL_WORKDIR`, `THEME_WSL_DISTRO` y `THEME_WSL_HOME` se pueden override por entorno.
- **OpenCode**: `cli.json` ya trae `theme: dracula` / `mode: dark`; el paso de tema solo avisa si hay desvio.
- **oh-my-bash**: el tema se toma de `THEME_OMB_THEME` (por defecto `vscode`, el mas cercano disponible).
- **Shell**: snippet gestionado en `~/.bashrc` entre `# >>> dotfiles-theme` / `# <<< dotfiles-theme` con `BAT_THEME`, `EXA_COLORS`/`EZA_COLORS`, `FZF_DEFAULT_OPTS` y `LS_COLORS` (`dircolors`). Fuera de los marcadores no se sobrescribe nada.
- **git**: `~/.config/git/theme.gitconfig` con `[color]`; `setup-git-identity.sh` lo incluye via `[include]` para que no se pierda al regenerar `~/.gitconfig`.
- **`nui`**: sus colores se generan en `ui/theme_generated.go` desde el mismo `.env` (`bash scripts/gen-theme-go.sh`) y CI verifica que este al dia.

Overrides utiles: `THEME_ENV_FILE`, `THEME_NERD_VERSION`, `THEME_NERD_REPO_URL`, `DOTFILES_ENV=linux|windows-wsl`. El resultado queda en `~/.config/enviroment-dotfiles/theme.json` y `sync-dotfiles doctor` verifica la fuente y el pin.

## service.json.example
`service.json.example` es la plantilla de configuracion privada local. Se copia a
`~/.config/opencode/service.json` (fuera del repo; el push lo excluye siempre) y se
rellena con credenciales o ajustes que no deben versionarse. No se crea durante
la instalación: debe generarse manualmente a partir del ejemplo.

## Cuentas Git (SSH + includeIf)
`setup-git-identity.sh` configura **una cuenta personal obligatoria** y **hasta 3
cuentas opcionales** ("espacios"):

- **Personal**: clave `~/.ssh/id_ed25519_personal`, perfil `~/.gitconfig-personal`;
  actua en **todo el sistema** (`includeIf "gitdir:$HOME/"`) salvo en las carpetas
  de los espacios. Su plataforma (github/bitbucket) se pregunta en la instalacion.
- **Espacios**: cada cuenta vive en una carpeta de `$HOME` cuyo nombre pide el
  instalador (ej. `~/Trabajo`). Tiene clave `id_ed25519_<slug>`, perfil
  `~/.gitconfig-<slug>` y alias SSH `git-<slug>`. Dentro de la carpeta,
  `includeIf` cambia `user.name/email` y un bloque `url.insteadOf` reescribe los
  remotes de la plataforma al alias, de modo que los remotes se autentican con la
  clave de esa cuenta aunque la plataforma coincida con la de la personal.
- **Estado**: el resultado queda en `~/.config/git-accounts.sh` (manifiesto
  generado). El paso "Registrar y probar llaves SSH" del bootstrap y
  `sync-dotfiles doctor` lo leen; para agregar/renombrar cuentas, relanza
  `bootstrap.sh`.
- **`~/.ssh/config`**: solo se regenera la seccion entre los marcadores
  `# >>> dotfiles-managed` / `# <<< dotfiles-managed`; cualquier bloque propio
  del usuario fuera de los marcadores se conserva.
- **Validaciones**: el nombre del espacio se normaliza a slug (sin espacios ni
  acentos), se rechazan duplicados, nombres que empiezan por `.` y rutas con `/`
  (no se permiten carpetas anidadas entre espacios).
- **Migracion (opt-in)**: si existía un esquema anterior (repositorios en una
  carpeta legada como `~/Documents/Repositorios`) y hay una sola cuenta opcional, se puede
  mover su contenido a la carpeta del espacio. Ya **no** se hace de forma
  automatica: se pregunta en modo interactivo o se activa con
  `GIT_MIGRATE_LEGACY=1`; por defecto la carpeta legada se conserva intacta.
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
sync-dotfiles pull --dry-run     # muestra que haria, sin tocar nada

sync-dotfiles-private pull
sync-dotfiles-private push
```

- `pull` descarga por **HTTPS** (no requiere llaves SSH) y aplica los assets
  publicos. `rsync` **no** borra archivos extra por defecto; usa
  `sync-dotfiles pull --delete` si quieres que el destino quede identico al repo.
- `push` si requiere SSH de GitHub y solo commitea las rutas publicas
  (`PUBLIC_PATHS`), nunca cambios a medias de otras carpetas.
- `doctor` verifica versiones vs pins, skills externas, claves SSH, permisos
  (`0600`) y bloques gestionados; sale 1 si hay avisos.

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

### Linux o WSL
- Linux o WSL (ver [`docs/PLATFORMS.md`](docs/PLATFORMS.md)).
- Base: `git`, `curl`, `bash`, `python3`, `node` (nvm), `npm`, `rsync`, `openssh-client`, `tar`, `gzip` (instalados por `bootstrap.sh` si faltan, con `apt-get`/`dnf`/`pacman`/`zypper`/`apk`). `xdg-utils`, `wl-clipboard` y `xclip` solo con sesion grafica.
- Tema: `fontconfig` (`fc-match`/`fc-cache`) para verificar e instalar JetBrainsMono Nerd Font; si no esta, los TTFs se copian igual y el paso avisa.
- `nui`: binario estatico propio (bubbletea + lipgloss) que se instala automaticamente desde `bin/nui-<os>-<arch>.gz` (o `NUI_BASE_URL`).
- `herdr` y `oh-my-bash`: se instalan automaticamente.

### Windows nativo
- Windows 10 22H2 o Windows 11, x64 (ARM64 best-effort). PowerShell 5.1 minimo,
  PowerShell 7 recomendado; Windows Terminal como terminal objetivo.
- Base: `git`, `python`, OpenSSH Client (`ssh`/`ssh-keygen`), `curl.exe` y
  `tar.exe` (estos dos vienen con el SO). `bootstrap.ps1` instala lo que falte
  con winget o con los ZIPs de `config/windows/packages.json`.
- No hace falta administrador ni WSL ni Git Bash.
- `nui`: mismo binario Go, publicado como `bin/nui-windows-<arch>.exe.gz` y
  verificado contra `bin/SHA256SUMS`.
- `herdr`, `oh-my-posh`, OpenCode y Neovim: se instalan automaticamente.

## Comportamiento visual
- La UI usa `nui steps run` (binario propio en Go con bubbletea/lipgloss; fuente en `ui/`, binarios en `bin/`): un panel de dos columnas con el listado de pasos (`[✓]`/`[!]`/`[✗]`) y el detalle del paso activo (progreso, contador `paso N de M` y logs). Si `nui` no esta disponible, hay fallback textual/ANSI.
- Los pasos se definen en `scripts/lib/ui.sh` (`ui_panel_step`); los prompts (texto, password, confirmacion y seleccion multiple) se resuelven **dentro del panel** con `ui_panel_inputs`, por lo que ninguna pantalla anterior aparece durante la instalacion.
- Los campos pueden ser condicionales mediante `showif <campo> <field> <op> [value]` (ops: `eq`, `ne`, `gt`, `gte`, `lt`, `lte`, `nonempty`, `empty`; varias lineas = AND). En la identidad Git, elegir 0-3 cuentas adicionales muestra solo los campos de esas cuentas, y dejar vacio el "espacio" de una cuenta oculta su plataforma/nombre/email. Funciona igual en el panel y en el modo texto.
- En los formularios, `shift+tab` (o `↑`, y `←` en selecciones) vuelve al campo anterior conservando lo escrito; cambiar un campo anterior recalcula los campos condicionales.
- La lista de pasos se puede recorrer con `↑/↓` en cualquier momento, incluso mientras uno se ejecuta o despues de terminar: el detalle sigue al cursor y `enter` fija/selta un paso (`◆`). Con un formulario abierto, `tab` lleva el foco a la lista de pasos (el panel derecho muestra el detalle del paso señalado) y `tab`/`esc` vuelve al formulario sin perder lo escrito; `ctrl+↑/↓` navega los pasos directamente. Al terminar, `tab` alterna entre el reporte final y la lista de pasos.
- Los pasos opcionales (credenciales sudo, identidad Git, .NET) se pueden **omitir** con `esc` sin detener la instalacion; los prompts y selecciones se resuelven antes del panel solo cuando no hay TTY.
- El paso **Registrar y probar llaves SSH** recorre las cuentas en orden **dentro del panel** (sin ceder la terminal ni lanzar un segundo TUI):
  1. muestra la clave pública de la cuenta y la copia al portapapeles; si no hay portapapeles, la respalda en `~/claves-ssh.txt` y la muestra para copiarla manualmente;
  2. abre la página de claves SSH de GitHub o Bitbucket;
  3. el panel pregunta `Sí/No` con `##confirm` (`←/→` para elegir, `enter` para confirmar, `esc` = no);
  4. si se confirma, ejecuta `ssh -T` para esa cuenta;
  5. continúa con la siguiente llave solo después de procesar la actual.
  La lista, la llave activa, la pregunta y el resultado permanecen visibles en el panel.
- Si el sistema necesita `apt`, el paso **Credenciales sudo** pide la contraseña en un TTY real (es el único paso que cede la terminal) y la reutiliza en los pasos apt con `sudo -S`; se guarda solo en el estado efímero del TUI y se borra al terminar. Si se omite, los paquetes custom se instalan en `~/.local/bin` desde binarios pinnados y los que falten se informan con el comando exacto para instalarlos.
- Cada paso emite `##progress N`, `##log T` y `##warn T` para el panel, y puede pedir confirmación en vivo con `##confirm <id> <pregunta>` (la respuesta se escribe en `$NUI_STATE_DIR`). La salida de `apt-get`, `npm`, `git clone`, OpenCode, herdr y SSH se guarda en logs.
- Al terminar, el **reporte final** (`INSTALADO` / `AVISOS` / `ERRORES`) se muestra como estado final dentro del panel; `q` sale (exit 1 si hay errores). `q`/`esc`/`ctrl+c` durante la ejecucion cancelan (exit 1).
- Las cajas se ajustan al ancho de la terminal y el panel se adapta al tamano de la ventana.
- SSH usa host keys pinadas en `config/ssh/known_hosts` con `StrictHostKeyChecking=yes` y `BatchMode=yes`; nunca `ssh-keyscan` ni `accept-new`.

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

En Windows los logs van a `~/.config/enviroment-dotfiles/logs` y el equivalente
es:
```powershell
pwsh -File bootstrap.ps1 -Verbose
pwsh -File bootstrap.ps1 -DryRun          # solo el plan, sin ejecutar nada
sync-dotfiles pull -Verbose
pwsh -File scripts/sync.ps1 -Mode doctor
```

El one-liner inicial usa un fallback silencioso antes de tener `nui`; cuando `nui` ya esta disponible muestra banners, spinners, prompts y reporte final.

- Los scripts usan `nui` para mejorar legibilidad y tienen fallback textual/ANSI.
- `analyze-webrtc-dumps` es un **agente**, no una skill; se gestiona desde el repo privado.
- El repositorio público no debe contener credenciales ni configuración privada.
