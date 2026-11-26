# Plataformas soportadas

| Plataforma | Estado | Instalador |
|---|---|---|
| Linux (Debian/Ubuntu, Fedora/RHEL, Arch, openSUSE, Alpine) | Soportado | `install.sh` (bash; detecta `apt-get`, `dnf`, `pacman`, `zypper` o `apk`) |
| WSL 1 / WSL 2 | Soportado | El mismo `install.sh`; se trata como Linux |
| Windows nativo (10 22H2+ / 11, x64) | Soportado | `install.ps1` (PowerShell 5.1+); ver [`WINDOWS.md`](WINDOWS.md) |
| Windows nativo ARM64 | Best-effort | Mismo instalador; no se prueba en CI |
| macOS | No soportado | — |
| BSD / otros Unix | No soportado | — |

Los **datos** son comunes a las dos capas (`config/opencode/**`,
`config/theme/dracula.env`, `config/ssh/known_hosts`, `config/alacritty/*` en
Linux/WSL, `config/oh-my-posh/*` y `config/windows-terminal/*` en Windows); lo
que cambia es solo el runner. El contrato entre ambas esta en
[`STEPS.md`](STEPS.md).

## Verificacion en CI

- **Linux/WSL**: `bash -n` y `shellcheck -S warning`, `gofmt`/`go vet`/
  `go test -race` de `ui/`, build cruzado (`windows`, `darwin`), validacion del
  tema y de las plantillas TOML.
- **Windows** (`windows-latest`): parseo y `PSScriptAnalyzer` de todos los
  `.ps1`/`.psm1`, check ASCII-only (PowerShell 5.1 sin BOM rompe UTF-8), Pester
  de `tests/windows/`, `bootstrap.ps1 -DryRun` con validacion del plan JSON y
  ejecucion real de `nui`, `setup-git-identity.ps1` y `sync.ps1`.

## macOS (no soportado)

`nui` compila (`NUI_INCLUDE_DARWIN=1 bash ui/build.sh`), pero la capa bash
necesita bash 4+, coreutils GNU y un gestor de paquetes Linux. Portarlo a macOS
o a otro Unix queda fuera del alcance.

## Reportar un problema

Incluye plataforma y version (`uname -a`; en Windows
`$PSVersionTable.PSVersion` y `[Environment]::OSVersion.Version`), el gestor de
paquetes, la salida de `install.sh --dry-run` / `bootstrap.ps1 -DryRun` y los
logs (`~/.local/state/enviroment-dotfiles/logs` o
`~/.config/enviroment-dotfiles/logs`). Revisa que no haya datos privados antes
de adjuntarlos.
