# enviroment-dotfiles

Entorno portable de desarrollo: OpenCode, Neovim/LazyVim, herramientas CLI y un
unico tema (Dracula + JetBrainsMono Nerd Font), instalado con un comando en
Linux, WSL y Windows nativo. macOS no esta soportado.

## Instalacion

**Linux / WSL** (Debian/Ubuntu, Fedora/RHEL, Arch, openSUSE, Alpine):

```bash
curl -fsSL https://raw.githubusercontent.com/ChaminnPM/enviroment-dotfiles/main/install.sh | bash
```

**Windows nativo** (10 22H2+ / 11, x64; sin WSL y sin Git Bash):

```powershell
powershell -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/ChaminnPM/enviroment-dotfiles/main/install.ps1 | iex"
```

Si el one-liner falla (politica de ejecucion, proxy que rompe
`Invoke-RestMethod`), usa `install.cmd` desde una copia del repo.

El instalador baja el repo a un temporal (tarball o ZIP), ejecuta el bootstrap y
lo borra: no deja clon en disco. En Linux/WSL necesita `curl` y `tar` (los
instala si faltan y hay sudo); en Windows `curl.exe` y `tar.exe` ya vienen con
el SO.

| | Linux / WSL | Windows nativo |
|---|---|---|
| Paquetes | `apt-get` / `dnf` / `pacman` / `zypper` / `apk` | winget (`--scope user`) + ZIPs pinnados |
| Administrador | `sudo` solo para paquetes del sistema | **no** por defecto |
| Shell y prompt | bash + oh-my-bash | PowerShell + oh-my-posh |
| Terminal | Alacritty (si ya esta instalado) | Windows Terminal |

## Que instala

- **Dependencias base**: git, curl, python3, tar, gzip, rsync, openssh-client y
  compilador C en Linux/WSL; git, python, OpenSSH y PowerShell 7 opcional en
  Windows.
- **CLI**: fzf, ripgrep, bat, eza, zoxide, fd y lazygit.
- **Neovim** (> 0.11.2) con LazyVim.
- **Node** con nvm (Linux/WSL) o fnm (Windows), y **OpenCode**
  (`@opencode/cli`).
- **Prompt**: oh-my-bash (Linux/WSL) u oh-my-posh (Windows).
- **Tema Dracula** en terminal, prompt, bat, eza, fzf, git, nvim y OpenCode,
  con la fuente JetBrainsMono Nerd Font v3.4.0 instalada.
- **Configuracion publica** en `~/.config/opencode`: agentes, skills (incluidas
  las externas `graphify` y `security-audit`), plugins y `AGENTS.md`.
- **Identidad Git/SSH**: una cuenta personal obligatoria y hasta 3 espacios con
  clave y `includeIf` propios (paso opcional).
- **herdr** y el wrapper `sync-dotfiles`.

Todo lo que gestiona el instalador queda en `~/.config/enviroment-dotfiles`
(bin, env y tema aplicado), con los logs, el estado de los formularios y los
respaldos en `~/.local/state/enviroment-dotfiles` (Linux/WSL) o en el mismo arbol
(Windows). Fuera de ahi solo escribe donde lo obligan las herramientas:
`~/.config/opencode`, `~/.ssh`, `~/.gitconfig`, `$PROFILE` y, en Windows, el
registro de fuentes y `settings.json` de Windows Terminal.

## Modificadores

Los mismos modificadores en las dos capas, con la sintaxis de cada shell:

| Que hace | Linux / WSL | Windows |
|---|---|---|
| Muestra toda la salida (sin panel) | `--verbose` | `-Verbose` |
| Imprime el plan de pasos y no ejecuta | `--dry-run` | `-DryRun` |
| Sin preguntas: defaults y modo texto | `--non-interactive` | `-NonInteractive` |
| Desactiva el color | `--no-color` | `-NoColor` |
| Solo los pasos cuyo titulo coincida | `--only "<texto>"` | `-Only "<texto>"` |
| Omite la identidad Git/SSH | `--skip-git` | `-SkipGit` |
| Instala los paquetes en ambito de maquina (una sola UAC) | — | `-MachineScope` |
| Usa Node de winget en lugar de fnm | — | `-NodeManager node` |
| Instala PowerShell 7 | — | `-WithPowerShell7` |
| Rama o tag del repo | `REPO_REF=<ref>` | `-Ref <ref>` |

Con `irm | iex` no se pueden pasar banderas: usa las variables de entorno
`NUI_DRY_RUN=1`, `NUI_NONINTERACTIVE=1`, `NUI_NO_COLOR=1`, `NUI_ONLY`, `VERBOSE=1`,
`SKIP_GIT_IDENTITY=1`, `REPO_REF`, `DOTFILES_NODE_MANAGER` y
`DOTFILES_MACHINE_SCOPE=1`, que hacen lo mismo.

Ejemplos:

```bash
# Linux/WSL (desde una copia del repo; sin copia: curl ... | bash -s -- --only "OpenCode")
bash install.sh --dry-run
bash install.sh --only "OpenCode"

# Windows (desde una copia del repo)
pwsh -File install.ps1 -DryRun
pwsh -File install.ps1 -Only "Tema"
```

`--only` / `-Only` filtra **solo por titulo** y no resuelve dependencias: si
relanzas un paso suelto, asume que los anteriores ya se ejecutaron.

Pasos (titulos para `--only`): `Requisitos del sistema`, `Dependencias base`,
`Fuente (JetBrains Mono Nerd)`, `Identidad Git (SSH)`, `Registrar y probar
llaves SSH`, `Paquetes custom`, `Node + nvm` / `Node + gestor de versiones`,
`Actualizar nvm (opcional)` / `Actualizar gestor de Node (opcional)`,
`OpenCode`, `Restaurar configuracion`, `Alacritty (opcional)` / `Windows Terminal (tema)`,
`graphify`, `oh-my-bash` / `oh-my-posh`, `Tema (Dracula)`, `herdr`, `Wrappers`,
`Verificacion final`, `Persistencia de entorno`.

## Despues de instalar

- Abre una terminal nueva: el entorno se carga solo (`env.sh` / `env.ps1`).
  No uses `exec $SHELL`.
- `sync-dotfiles doctor` comprueba versiones, permisos, bloques y tema;
  `sync-dotfiles pull` / `push` sincroniza la configuracion con el repo.
- Los logs estan en `~/.local/state/enviroment-dotfiles/logs` (Linux/WSL) y
  `~/.config/enviroment-dotfiles/logs` (Windows); los respaldos de cada archivo
  tocado, en `backups/` del mismo arbol.
- Cada paso es idempotente: si algo falla, relanzalo con `--only`.

## Documentacion

- [`docs/WINDOWS.md`](docs/WINDOWS.md): requisitos, rutas, paquetes y problemas
  tipicos de Windows nativo.
- [`docs/PLATFORMS.md`](docs/PLATFORMS.md): soporte y verificacion por
  plataforma.
- [`docs/STEPS.md`](docs/STEPS.md): contrato interno entre las dos capas
  (mantenimiento del repo).
