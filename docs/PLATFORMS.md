# Plataformas soportadas

Este repositorio mantiene dos capas de instalación sobre los mismos datos:

| Plataforma | Estado | Como se instala |
|---|---|---|
| Linux (Debian/Ubuntu, Fedora/RHEL, Arch, openSUSE, Alpine) | **Soportado** | `install.sh` / `bootstrap.sh` (bash). Detecta `apt-get`, `dnf`, `pacman`, `zypper` o `apk`. |
| WSL 1 / WSL 2 | **Soportado** | Misma capa bash; se trata como Linux. Alacritty usa el overlay `windows-wsl.toml.tpl`. |
| Windows nativo (10 22H2+ / 11, x64) | **Soportado** | `install.ps1` / `bootstrap.ps1` (PowerShell 5.1+; recomendado 7). Sin WSL y sin Git Bash. Ver [`WINDOWS.md`](WINDOWS.md). |
| Windows nativo ARM64 | Best-effort | `nui` y las herramientas tienen build ARM64; herdr corre x64 bajo emulacion. No se prueba en CI. |
| macOS | No soportado | `nui` compila (binarios best-effort), pero la capa bash necesita bash 4+, coreutils GNU y Homebrew. Ver abajo. |
| BSD / otros Unix | No soportado | Sin verificacion. |

Los **datos** son comunes a todas las capas: `config/opencode/**`,
`config/theme/dracula.env`, `config/ssh/known_hosts`, `config/alacritty/*`
(Linux/WSL), `config/oh-my-posh/*` y `config/windows-terminal/*` (Windows).
Lo que cambia por plataforma es solo el runner.

## Que se verifica en CI

Linux/WSL:

- `bash -n` y `shellcheck -S warning` de todos los scripts `.sh`.
- `gofmt`, `go vet`, `go test -race` de `ui/`.
- Compilacion cruzada `GOOS=darwin` y `GOOS=windows` (el binario de Windows se
  publica; el de Darwin es comprobacion de build).
- Validacion del tema, las plantillas TOML y `ui/theme_generated.go`.

Windows:

- Parseo de **todos** los `.ps1`/`.psm1` con el parser de PowerShell (sintaxis
  y AST), y `PSScriptAnalyzer` en severidad Error.
- Check **ASCII-only** de los `.ps1`/`.psm1`: Windows PowerShell 5.1 sin BOM
  interpreta UTF-8 como ANSI y los acentos rompen los scripts.
- Pester (`tests/windows/`): bloques gestionados, PATH, respaldos, contrato del
  plan, DSL de inputs, `show_if`, formato de resultados, manifiesto de paquetes,
  JSONC de Windows Terminal, `setup-git-identity.ps1` y `sync.ps1` reales.
- `bootstrap.ps1 -DryRun` y validacion del plan JSON (titulos, `argv`,
  `inputs`, `show_if`).
- `go vet`/`go test` del `ui/` ejecutados **dentro** de `windows-latest`, mas
  `gofmt`/checks de compatibilidad.

## Linux

Requisitos:

- `bash` >= 4 (arrays asociativos, `${var,,}`, `mapfile`).
- `coreutils` GNU (`stat -c`, `date +%s%N`, `timeout`, `base64 -w0`).
- `rsync`, `git`, `curl`, `gzip`, `tar`.
- `sudo` solo si se instalaran paquetes del sistema.

En Alpine (musl) el instalador usa `apk`; el resto del flujo es identico.

## WSL

- Detectado leyendo `/proc/sys/kernel/osrelease` (`*microsoft*`).
- Se instala como Linux dentro de la distro (Debian/Ubuntu por defecto).
- La configuracion de Alacritty se genera para Windows (`windows-wsl.toml.tpl`)
  con `wsl.exe`; si no hay Alacritty, ese paso se omite.
- El portapapeles usa OSC 52 sobre `/dev/tty`, asi que funciona en Windows
  Terminal sin instalar `xclip`/`wl-clipboard`.
- Desde WSL **no** se toca el entorno nativo de Windows: son dos instalaciones
  independientes (`bootstrap.sh` vs `bootstrap.ps1`).

## Windows nativo

Capa PowerShell nativa: `install.ps1` -> `bootstrap.ps1` -> 18 pasos ->
`nui steps run` (`shell: "pwsh"`, `argv` literal). Sin WSL y sin Git Bash.

- Gestor de paquetes: **winget** (`--scope user` por defecto) con ZIPs pinnados
  de respaldo en `config/windows/packages.json`.
- Terminal: **Windows Terminal** (sustituye a Alacritty en Windows puro).
- Shell: **PowerShell 7** recomendado; PowerShell 5.1 soportado.
- Estado del proyecto: todo bajo `~/.config/enviroment-dotfiles`.
- Permisos: ACLs (`icacls`) en lugar de `chmod`; procesos: Job Object +
  `taskkill /T` en lugar de grupos POSIX.

Requisitos, instalacion, tabla de rutas y solucion de problemas:
[`WINDOWS.md`](WINDOWS.md). El contrato de pasos entre las dos capas esta en
[`STEPS.md`](STEPS.md).

Limitaciones conocidas:

- El repo privado (`enviroment-dotfiles-secrets`) no tiene capa PowerShell
  todavia: en Windows nativo solo se instala el entorno publico.
- `nui.exe` no esta firmado: SmartScreen puede avisar la primera vez
  (`install.ps1` hace `Unblock-File` en el arbol descargado).
- Las skills cuyo `SKILL.md` documenta snippets en bash (p. ej. graphify) se
  copian igual; en Windows los ejecuta el agente via PowerShell/Python.

## macOS (no soportado)

Lo que **si** compila: `nui` (`NUI_INCLUDE_DARWIN=1 bash ui/build.sh`).
Lo que **no** funciona sin cambios:

1. **bash 3.2** por defecto: `mapfile`, `${var,,}`, arrays asociativos y
   `read -a` con separadores personalizados fallan.
2. **Herramientas GNU**: `stat -c`, `date -Iseconds`, `base64 -w0`, `sed -i` sin
   backup, `timeout`, `sort -V` y `realpath -m` son BSD o no existen.
3. **`install.sh`**: `ensure_cmd` asume un gestor de paquetes Linux.
4. **`bootstrap.sh`**: los pasos de fuente (fontconfig), Alacritty y paquetes
   necesitan ramas especificas.
5. La capa PowerShell portaria macOS facilmente (PowerShell 7 es multiplataforma
   y `nui` ya compila), pero no esta en el alcance actual.

## Como reportar

Al abrir un issue incluye:

- `uname -a` y, en WSL, `wsl.exe --version`. En Windows nativo:
  `$PSVersionTable.PSVersion` y `[Environment]::OSVersion.Version`.
- Distribucion y gestor de paquetes (`apt-get`, `dnf`, `pacman`, winget...).
- Linux/WSL: salida de `bash bootstrap.sh --dry-run`.
  Windows: salida de `pwsh -File bootstrap.ps1 -DryRun` (no modifica nada).
- Windows: resultado de `pwsh -File scripts/sync.ps1 doctor`.
- Logs: `~/.local/state/enviroment-dotfiles/logs/` (Linux/WSL) o
  `~/.config/enviroment-dotfiles/logs/` (Windows). Revisa que no haya datos
  privados antes de adjuntarlos.
