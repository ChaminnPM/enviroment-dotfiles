# enviroment-dotfiles (publico)

Configuracion portable de OpenCode para **Linux y WSL**. Funciona con
`apt-get` (Debian/Ubuntu), `dnf` (Fedora/RHEL), `pacman` (Arch), `zypper`
(openSUSE) y `apk` (Alpine). macOS y Windows nativo **no estan soportados**:
ver [`docs/PLATFORMS.md`](docs/PLATFORMS.md).

Incluye un tema canonico (**Dracula + JetBrainsMono Nerd Font**) que se aplica
a todas las herramientas durante la instalacion, incluida la instalacion de
la fuente.

## Instalacion (verificada, recomendada)

El instalador es **fail-closed**: exige `REPO_SHA256` para el tarball y
`NVM_SHA256`, `NEOVIM_SHA256`, `OPENCODE_SHA256` y `HERDR_SHA256` para los
instaladores remotos. El one-liner clásico solo funciona con
`NUI_ALLOW_UNVERIFIED=1` (opt-out **inseguro**), así que la forma recomendada es
descargar, verificar y ejecutar:

```bash
# Todo va dentro de ( ... ): un fallo solo termina este bloque, NO tu terminal.
# No pegues un `exit 1` suelto en una shell interactiva: cerraria la sesion.
(
  set -euo pipefail
  base="https://raw.githubusercontent.com/ChaminnPM/enviroment-dotfiles/main"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  curl -fsSL --retry 3 "$base/SHA256SUMS" -o "$tmp/SHA256SUMS"
  curl -fsSL --retry 3 "$base/install.sh"  -o "$tmp/install.sh"

  # El archivo debe llamarse exactamente install.sh: es la clave del
  # SHA256SUMS. Con otro nombre, --ignore-missing no verificaria nada.
  want="$(awk '$2 == "install.sh" { print $1; exit }' "$tmp/SHA256SUMS")"
  [ -n "$want" ] || { echo "[ERROR] SHA256SUMS no contiene install.sh" >&2; exit 1; }
  printf '%s  %s\n' "$want" "$tmp/install.sh" | sha256sum -c -

  # Comodidad: calculamos el hash del tarball de la misma rama. install.sh lo
  # vuelve a verificar con REPO_SHA256 antes de extraer absolutamente nada.
  repo_url="https://github.com/ChaminnPM/enviroment-dotfiles/archive/refs/heads/main.tar.gz"
  repo_sha="$(curl -fsSL --retry 3 --max-time 600 "$repo_url" | sha256sum | awk '{print $1}')"

  REPO_SHA256="$repo_sha" \
  NVM_SHA256="${NVM_SHA256:?define NVM_SHA256}" \
  NEOVIM_SHA256="${NEOVIM_SHA256:?define NEOVIM_SHA256}" \
  OPENCODE_SHA256="${OPENCODE_SHA256:?define OPENCODE_SHA256}" \
  HERDR_SHA256="${HERDR_SHA256:?define HERDR_SHA256}" \
    bash "$tmp/install.sh"
)
```

La forma correcta de cargar el PATH y NVM al terminar es abrir una terminal
nueva, o sourcear el archivo de entorno en la actual:

```bash
. "$HOME/.config/enviroment-dotfiles/env.sh"
```

**No uses `exec "$SHELL"`**: reemplaza el proceso de la shell actual y, si la
configuración de inicio falla o la terminal cierra al salir de esa shell, te
deja fuera de la sesión.

`SHA256SUMS` (raíz, generado con `bash scripts/gen-checksums.sh`) cubre los
scripts de instalación; `bin/SHA256SUMS` cubre los binarios de `nui`, que están
vendorizados y se verifican antes de instalarse.

El instalador descarga el repo como **tarball** y no requiere `git` para empezar. Luego `bootstrap.sh` instala dependencias base (`git`, `curl`, `python3`, `tar`, `gzip`, `rsync`, `openssh-client`, etc.) antes de los pasos que las necesitan.

### Como obtener los pins (una sola vez)

Los cuatro hashes se calculan desde las URLs oficiales fijadas en
`bootstrap.sh`. Es un modelo *trust-on-first-use*: calcúlalos una vez, guárdalos
en tu gestor de contraseñas y reutilízalos. Solo vuelve a calcularlos cuando
actualices la versión fijada (`NVM_VERSION`, `NEOVIM_VERSION`, etc.).

```bash
# nvm (NVM_VERSION por defecto: v0.40.8)
curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.8/install.sh | sha256sum

# neovim (NEOVIM_VERSION por defecto: v0.11.4)
curl -fsSL https://github.com/neovim/neovim/releases/download/v0.11.4/nvim-linux-x86_64.tar.gz | sha256sum
# En arm64 usa nvim-linux-arm64.tar.gz. Si ese asset no existe, bootstrap
# prueba nvim-linux64.tar.gz: calcula el hash de ese archivo en su lugar.

# OpenCode
curl -fsSL https://opencode.ai/v2/install | sha256sum

# herdr
curl -fsSL https://herdr.dev/install.sh | sha256sum
```

Luego exportalos antes del bloque de instalación:

```bash
export NVM_SHA256='...' NEOVIM_SHA256='...' OPENCODE_SHA256='...' HERDR_SHA256='...'
```

Si alguno falta o no coincide, el instalador se detiene **antes** de ejecutar
ese instalador remoto. No lo eludas salvo en un entorno de prueba.

### One-liner heredado (sin verificacion, desaconsejado)

```bash
export NUI_ALLOW_UNVERIFIED=1
curl -fsSL https://raw.githubusercontent.com/ChaminnPM/enviroment-dotfiles/main/install.sh | bash
```

Solo para entornos de prueba; en producción usa la instalación verificada de
arriba. Con este modo verás avisos `SIN verificar (NUI_ALLOW_UNVERIFIED=1:
INSEGURO)` para neovim, nvm, OpenCode y herdr.

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
   - Aplica Alacritty y, al final, el **tema** a todas las herramientas presentes.
   - Instala el wrapper publico `sync-dotfiles`.
5. Elimina el directorio temporal del repo: no queda `~/enviroment-dotfiles` instalado localmente.

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

Todos los comandos `bash install.sh --only ...` de esta sección vuelven a
descargar el repo, por lo que necesitan las mismas variables (`REPO_SHA256` y
los pins) que el bloque seguro. Si `main` cambió entre la instalación y la
reparación, recalcula `REPO_SHA256` como se muestra arriba.

**La terminal se cierra al ejecutar el comando de instalación.** Causa habitual:
un `exit 1` pegado en una shell interactiva, o un `exec "$SHELL"`. Usa el bloque
`( ... )` de arriba: sus `exit` solo afectan a ese subproceso. Para recuperar el
PATH sin reemplazar la shell:

```bash
. "$HOME/.config/enviroment-dotfiles/env.sh"   # o abre una terminal nueva
```

**Aviso `Contraseña sudo no activa; el gestor de paquetes no instalara nada`.**
Activa las credenciales y vuelve a ejecutar el paso:

```bash
sudo -v && sudo -n true
bash install.sh --only "Dependencias base"
```

**Aviso `La fuente esta en disco pero fontconfig sigue sin verla`.** El script ya
ejecutó `fc-cache -f`; comprueba antes de volver a descargar:

```bash
find "$HOME/.local/share/fonts" -maxdepth 1 -type f \( -iname '*JetBrains*' -o -iname '*.ttf' -o -iname '*.otf' \) -printf '%f\n'
fc-cache -f "$HOME/.local/share/fonts" && fc-cache -f
fc-match "JetBrainsMono Nerd Font"
fc-list | grep -i JetBrains | head
```

Si no hay archivos, repite solo ese paso con `bash install.sh --only "Fuente"`.

**Avisos `SIN verificar (NUI_ALLOW_UNVERIFIED=1: INSEGURO)`.** Significa que
faltan pins. No son un fallo de npm ni de red: el instalador omitió la
verificación de neovim, nvm, OpenCode o herdr. Desactiva la variable y vuelve
a ejecutar con los hashes de la sección "Como obtener los pins":

```bash
unset NUI_ALLOW_UNVERIFIED
# exporta NVM_SHA256, NEOVIM_SHA256, OPENCODE_SHA256, HERDR_SHA256
bash install.sh --only "Node + nvm"
bash install.sh --only "OpenCode"
bash install.sh --only "herdr"
```

**Aviso `npm install falló; revisa node_modules manualmente`.** El paso oculta la
salida de npm, así que diagnostícalo a mano en el directorio de
configuración de OpenCode:

```bash
command -v node && node --version
command -v npm && npm --version
cd "$HOME/.config/opencode" && npm install
```

Casi siempre se debe a que Node/nvm no quedó en el PATH de la sesión actual
(sourcea el env file o abre una terminal nueva) o a que los instaladores se
ejecutaron sin verificar. Después repite:

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
- `PATH` de herramientas instaladas (nvm, opencode, herdr) se persiste en
  `~/.config/enviroment-dotfiles/env.sh`, que cada paso carga antes de ejecutar.

## Contenido publico
- `config/opencode/`: config global de OpenCode, sin contenido Nuxiba.
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
- **Migracion (opt-in)**: si existia el esquema viejo (repos Nuxiba en
  `~/Documents/Repositorios`) y hay exactamente una cuenta opcional, se puede
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
- Linux o WSL (ver [`docs/PLATFORMS.md`](docs/PLATFORMS.md)).
- Base: `git`, `curl`, `bash`, `python3`, `node` (nvm), `npm`, `rsync`, `openssh-client`, `tar`, `gzip` (instalados por `bootstrap.sh` si faltan, con `apt-get`/`dnf`/`pacman`/`zypper`/`apk`). `xdg-utils`, `wl-clipboard` y `xclip` solo con sesion grafica.
- Tema: `fontconfig` (`fc-match`/`fc-cache`) para verificar e instalar JetBrainsMono Nerd Font; si no esta, los TTFs se copian igual y el paso avisa.
- `nui`: binario estatico propio (bubbletea + lipgloss) que se instala automaticamente desde `bin/nui-<os>-<arch>.gz` (o `NUI_BASE_URL`).
- `herdr` y `oh-my-bash`: se instalan automaticamente.

## Comportamiento visual
- La UI usa `nui steps run` (binario propio en Go con bubbletea/lipgloss; fuente en `ui/`, binarios en `bin/`): un panel de dos columnas con el listado de pasos (`[✓]`/`[!]`/`[✗]`) y el detalle del paso activo (progreso, contador `paso N de M` y logs). Si `nui` no esta disponible, hay fallback textual/ANSI.
- Los pasos se definen en `scripts/lib/ui.sh` (`ui_panel_step`); los prompts (texto, password, confirmacion y seleccion multiple) se resuelven **dentro del panel** con `ui_panel_inputs`, por lo que ninguna pantalla anterior aparece durante la instalacion.
- Los campos pueden ser condicionales mediante `showif <campo> <field> <op> [value]` (ops: `eq`, `ne`, `gt`, `gte`, `lt`, `lte`, `nonempty`, `empty`; varias lineas = AND). En la identidad Git, elegir 0-3 cuentas adicionales muestra solo los campos de esas cuentas, y dejar vacio el "espacio" de una cuenta oculta su plataforma/nombre/email. Funciona igual en el panel y en el modo texto.
- En los formularios, `shift+tab` (o `↑`, y `←` en selecciones) vuelve al campo anterior conservando lo escrito; cambiar un campo anterior recalcula los campos condicionales.
- La lista de pasos se puede recorrer con `↑/↓` en cualquier momento, incluso mientras uno se ejecuta o despues de terminar: el detalle sigue al cursor y `enter` fija/selta un paso (`◆`). Con un formulario abierto, `tab` lleva el foco a la lista de pasos (el panel derecho muestra el detalle del paso señalado) y `tab`/`esc` vuelve al formulario sin perder lo escrito; `ctrl+↑/↓` navega los pasos directamente. Al terminar, `tab` alterna entre el reporte final y la lista de pasos.
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
