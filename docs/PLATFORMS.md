# Plataformas soportadas

Este repositorio se mantiene y prueba **solo para Linux y WSL**. macOS y
Windows nativo se documentan aquí para dejar claro qué falta, pero **no están
soportados**: `install.sh`, `bootstrap.sh` y `nui` abortan con un mensaje claro
antes de tocar nada.

| Plataforma | Estado | Notas |
|---|---|---|
| Linux (Debian/Ubuntu, Fedora/RHEL, Arch, openSUSE, Alpine) | **Soportado** | Detecta `apt-get`, `dnf`, `pacman`, `zypper` o `apk`. |
| WSL 1 / WSL 2 | **Soportado** | Se trata como Linux; Alacritty usa el overlay `windows-wsl.toml.tpl` y `wsl.exe`. |
| macOS (Intel/Apple Silicon) | No soportado | Requiere bash 4+, coreutils GNU y varios ajustes (ver abajo). |
| Windows nativo (PowerShell/cmd, Git Bash, MSYS2, Cygwin) | No soportado | No hay `/dev/tty`, grupos de procesos POSIX ni symlinks fiables. |
| BSD / otros Unix | No soportado | Sin verificación. |

## Qué se verifica en Linux/WSL

- `bash -n` y `shellcheck -S warning` de todos los scripts.
- `gofmt`, `go vet`, `go test -race` de `ui/`.
- Build cruzado `GOOS=darwin` solo como comprobación de compilación.
- Generación del tema (`ui/theme_generated.go`) reproducible.

## Linux

Requisitos:

- `bash` >= 4 (el código usa arrays asociativos, `${var,,}` y `mapfile`).
- `coreutils` GNU (`stat -c`, `date +%s%N`, `timeout`, `base64 -w0`).
- `util-linux`/`procps` estándar; `rsync`, `git`, `curl`, `gzip`, `tar`.
- `sudo` solo si se instalarán paquetes del sistema.

En Alpine (musl) el instalador usa `apk`; el resto del flujo es idéntico.

## WSL

- Detectado leyendo `/proc/sys/kernel/osrelease` (`*microsoft*`).
- Se instala como Linux dentro de la distro (Debian/Ubuntu por defecto).
- La configuración de Alacritty se genera para Windows (`windows-wsl.toml.tpl`)
  con `wsl.exe`; si no hay Alacritty, ese paso se omite.
- El portapapeles usa OSC 52 sobre `/dev/tty`, así que funciona en Windows
  Terminal sin instalar `xclip`/`wl-clipboard`.

## macOS (no soportado)

Lo que **sí** compila: `nui` (los binarios `bin/nui-darwin-*.gz` se generan de
forma best-effort con `NUI_TARGETS="darwin/amd64 darwin/arm64" bash ui/build.sh`).
Lo que **no** funciona sin cambios:

1. **bash 3.2** por defecto: `mapfile`, `${var,,}`, arrays asociativos y `read -a`
   con separadores personalizados fallan. Haría falta `brew install bash` y
   reescribir el shebang o usar `/usr/local/bin/bash`.
2. **Herramientas GNU**: el repo usa `stat -c`, `date -Iseconds`,
   `base64 -w0`, `sed -i` sin backup, `timeout`, `sort -V` y `realpath -m`.
   En macOS son BSD o no existen; habría que introducir un shim
   (`gstat`, `gdate`, `gbase64`, `gtimeout`, `gsort`, `grealpath`).
3. **`install.sh`**: `curl | bash` funciona, pero `ensure_cmd` asume un gestor
   de paquetes Linux. Haría falta Homebrew y un mapeo de paquetes.
4. **`bootstrap.sh`**: los pasos de fuente (fontconfig), Alacritty y
   `apt`/`dnf` necesitan ramas específicas.
5. **`nui`**: `syscall.Getpgid`, `syscall.Kill` y `SysProcAttr{Setpgid}` existen
   en Darwin, pero `/dev/tty` y las señales deben probarse; además la UI asume
   una terminal con `TERM=xterm-256color`.

Cambios mínimos si se quisiera soportar: shim de coreutils, `bash` >= 4,
`brew` como gestor y una matriz de CI en `macos-latest`. No está en el alcance
actual.

## Windows nativo (no soportado)

`nui` no compila en Windows tal cual:

- `ui/steps.go` usa `syscall.Getpgid`, `syscall.Kill` y
  `syscall.SysProcAttr{Setpgid: true}`, que no existen en Windows.
- `ui/tui.go` abre `/dev/tty` y usa descriptores POSIX.
- El panel depende de grupos de procesos para cancelar `apt`/`npm` sin dejar
  huérfanos.

Soportarlo requeriría build tags (`//go:build linux || darwin`), una
implementación con `CreateJobObject`/`TerminateJobObject` y ConPTY, además de
reemplazar todos los comandos POSIX de los pasos. **Usa WSL.**

## Cómo reportar

Al abrir un issue incluye:

- `uname -a` y, en WSL, `wsl.exe --version`.
- `bash --version | head -1`.
- Distribución y gestor de paquetes (`apt-get`, `dnf`, `pacman`, ...).
- Salida de `bash bootstrap.sh --dry-run` (no modifica nada).
- Logs de `~/.local/state/enviroment-dotfiles/logs/` (revisa que no haya datos
  privados antes de adjuntarlos).
