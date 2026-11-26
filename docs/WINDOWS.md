# Windows nativo

Guia de la capa PowerShell: instalacion, requisitos, rutas, paquetes y
solucion de problemas. El contrato tecnico entre `bootstrap.ps1`, el plan JSON
y `nui` esta en [`STEPS.md`](STEPS.md); el estado de soporte por plataforma en
[`PLATFORMS.md`](PLATFORMS.md).

## Requisitos

| Cosa | Minimo | Nota |
|---|---|---|
| SO | Windows 10 22H2 x64 | Windows 11 recomendado. ARM64 best-effort. |
| PowerShell | 5.1 | 7.x recomendado (`bootstrap.ps1 -WithPowerShell7`). |
| Terminal | Windows Terminal | Es el terminal objetivo; sustituye a Alacritty. |
| Utilidades SO | `curl.exe`, `tar.exe`, `icacls.exe` | Vienen con Windows 10 1803+. |
| OpenSSH Client | caracteristica del SO | `ssh`, `ssh-keygen`, `ssh-add`. |
| Admin | **no** | Todo se instala por usuario (`winget --scope user` + ZIPs pinnados). |

## Instalacion

One-liner (recomendado):

```powershell
powershell -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/ChaminnPM/enviroment-dotfiles/main/install.ps1 | iex"
```

Opciones por bandera o por variable de entorno (necesario con `irm | iex`):

```powershell
pwsh -File bootstrap.ps1 -DryRun              # imprime el plan, no ejecuta nada
pwsh -File bootstrap.ps1 -Only "OpenCode"     # solo pasos cuyo titulo coincide
pwsh -File bootstrap.ps1 -NonInteractive      # defaults, modo texto
pwsh -File bootstrap.ps1 -SkipGit             # sin identidad Git/SSH
pwsh -File bootstrap.ps1 -MachineScope        # winget machine (puede pedir UAC)
pwsh -File bootstrap.ps1 -NodeManager node    # en lugar de fnm
pwsh -File bootstrap.ps1 -Verbose             # salida completa, sin panel
```

Si el one-liner no funciona (politica de ejecucion, proxy que rompe
`Invoke-RestMethod`), usa el launcher:

```cmd
install.cmd
```

`install.ps1` descarga el repo como **ZIP** a un temporal, desbloquea los
scripts y ejecuta `bootstrap.ps1`. No deja clon en el disco.

## Que instala

18 pasos, con los mismos titulos y el mismo contrato que `bootstrap.sh`:

1. `Requisitos del sistema` - SO, arch, PowerShell, winget, admin, PATH.
2. `Dependencias base` - git, python (+ shim `python3`), OpenSSH, pwsh opcional.
3. `Fuente (JetBrains Mono Nerd)` - ZIP pinnado -> `%LOCALAPPDATA%\Microsoft\Windows\Fonts` + registro HKCU.
4. `Identidad Git (SSH)` - claves ed25519, ACLs, perfiles por cuenta, manifiesto JSON.
5. `Registrar y probar llaves SSH` - portapapeles, navegador, `ssh -T` con host keys pinnadas.
6. `Paquetes custom` - fzf, ripgrep, bat, eza, zoxide, fd, lazygit, neovim, LazyVim.
7. `Node + gestor de versiones` - fnm (`fnm install --lts`) o Node por winget.
8. `Actualizar gestor de Node (opcional)`.
9. `OpenCode` - `npm install -g @opencode/cli`, fallback ZIP oficial.
10. `Restaurar configuracion` - assets publicos a `~/.config/opencode` + `npm install`.
11. `Windows Terminal (tema)` - esquema Dracula + fuente Nerd en `settings.json`.
12. `graphify`.
13. `oh-my-posh` - reemplazo de oh-my-bash, con `dracula.omp.json` vendorizado.
14. `Tema (Dracula)` - perfil, `theme.gitconfig`, manifiesto, OpenCode.
15. `herdr` - instalador oficial `herdr.dev/install.ps1`.
16. `Wrappers` - `sync-dotfiles.ps1` + `sync-dotfiles.cmd`.
17. `Verificacion final` - binarios, versiones, bloques de perfil, PATH, doctor.
18. `Persistencia de entorno` - `env.ps1`, PATH de usuario, `XDG_CONFIG_HOME`.

## Rutas

Todo lo que gestiona el instalador vive en **un arbol**:
`~/.config/enviroment-dotfiles` (`%USERPROFILE%\.config\...`), igual que la
config global de OpenCode:

```
~/.config/enviroment-dotfiles/
├── bin/            nui.exe, sync-dotfiles.ps1/.cmd, python3.cmd
├── env.ps1         PATH idempotente (lo carga $PROFILE)
├── theme/          copia de config/theme/dracula.env
├── themes/oh-my-posh/dracula.omp.json
├── windows-terminal/dracula.json
├── logs/           un archivo por paso y por ejecucion
├── state/          resultados de formulario y confirmaciones
├── backups/        los respaldos, uno por archivo y ejecucion
├── git-accounts.json
└── theme.json
```

Rutas que **impone** el SO o la herramienta y por eso estan fuera:

| Dato | Ruta | Quien la fija |
|---|---|---|
| Config OpenCode | `~/.config/opencode` | OpenCode (igual que Linux) |
| Claves y `known_hosts` | `~/.ssh` | OpenSSH |
| Config git global | `~/.gitconfig` (bloque gestionado) | Git |
| Perfil de shell | `Documents\PowerShell\profile.ps1` y `Documents\WindowsPowerShell\profile.ps1` | PowerShell |
| Fuente Nerd | `%LOCALAPPDATA%\Microsoft\Windows\Fonts` + HKCU\...\Fonts | Windows |
| Windows Terminal | `%LOCALAPPDATA%\Packages\Microsoft.WindowsTerminal_*\LocalState\settings.json` | Windows Terminal |
| Herramientas | donde las ponga winget | winget |

Equivalencias con Linux/WSL:

| Linux/WSL | Windows |
|---|---|
| `sudo` + `apt`/`dnf`/`pacman` | winget por usuario (sin UAC); `-MachineScope` para lo contrario |
| `~/.bashrc`, `~/.profile`, `~/.bash_profile` | `$PROFILE` (PS7 y 5.1) + `env.ps1` |
| `~/.local/state/enviroment-dotfiles` | `~/.config/enviroment-dotfiles/{logs,state,backups}` |
| `~/.local/share/fonts` + `fc-cache` | `%LOCALAPPDATA%\Microsoft\Windows\Fonts` + HKCU |
| `~/.config/alacritty` | Windows Terminal (`settings.json`) |
| `~/.config/nvim` | `~/.config/nvim` via `XDG_CONFIG_HOME` |
| oh-my-bash | oh-my-posh |
| `nvm` | fnm |
| `chmod 600` | `icacls /inheritance:r /grant:r` |
| `rsync` | `Copy-Item` / `robocopy` |
| `/dev/tty` | `CONIN$` |
| grupos de procesos POSIX | Job Object + `taskkill /T /F` |
| `pbcopy`/`xclip` | `Set-Clipboard`, fallback OSC 52 |
| `less` | `bat` o `more.com` |
| `curl \| bash` | `irm \| iex` |

## Paquetes

El mapeo vive en `config/windows/packages.json`: ID de winget, alcance y ZIP
de respaldo pinnado por entrada. Cada `fallback.env` permite repinnear la URL
por variable de entorno sin editar el repo:

```powershell
$env:FZF_FALLBACK_URL = 'https://github.com/<mirror>/fzf-windows.zip'
pwsh -File bootstrap.ps1 -Only 'Paquetes custom'
```

Si winget no esta (Windows 10 sin App Installer) o el ID no resuelve, se usa el
ZIP; si tampoco hay red, el paso degrada a **aviso** y la instalacion continua.
Sin admin: `--scope user` primero y, si el paquete no lo admite, ZIP portatil.
El modo `-MachineScope` eleva en bloque (una sola UAC) en lugar de una por
paquete. Para traer winget donde no existe, instala "App Installer" desde la
Microsoft Store o desde `https://aka.ms/getwinget`.

IDs declarados en el manifiesto: `Git.Git`, `Python.Python.3.13`,
`OpenJS.NodeJS.LTS`, `Schniz.fnm`, `Neovim.Neovim`, `junegunn.fzf`,
`BurntSushi.ripgrep.MSVC`, `sharkdp.bat`, `ajeetdsouza.zoxide`, `sharkdp.fd`,
`JesseDuffield.lazygit`, `JanDeDobbeleer.OhMyPosh`, `Microsoft.PowerShell`,
`eza-community.eza`.

Un ID que no exista o que ya no acepte `--scope user` **no rompe nada**: winget
falla y se usa el ZIP pinnado. Las URLs de respaldo si estan verificadas (los
assets existen tal cual en los releases de cada upstream).

## Verificacion y reparacion

```powershell
sync-dotfiles doctor            # estado del entorno (solo lectura)
sync-dotfiles pull              # volver a aplicar los assets publicos
sync-dotfiles push              # subir mis cambios (valida SSH antes)
pwsh -File bootstrap.ps1 -Only 'Persistencia de entorno'   # repara PATH/perfiles
pwsh -File bootstrap.ps1 -Only 'Windows Terminal'          # repara el esquema
```

`doctor` sale con codigo != 0 si hay avisos; cada linea `[WARN]` dice que paso
relanzar.

Una terminal nueva debe ver todo sin `exec $SHELL`. Comprobacion dura:

```powershell
pwsh -NoProfile -Command '$env:Path'   # debe incluir ~/.config/enviroment-dotfiles/bin
```

## Solucion de problemas

**"No se puede ejecutar la politica de ejecucion" / script bloqueado.**
Ejecuta con `-ExecutionPolicy Bypass` (solo ese proceso) o `install.cmd`.
`install.ps1` ademas hace `Unblock-File` sobre el arbol descargado.

**SmartScreen avisa de `nui.exe`.** El binario no esta firmado.
`Unblock-File "$HOME\.config\enviroment-dotfiles\bin\nui.exe"`. Si quieres
verificarlo antes: el checksum esta en `bin/SHA256SUMS` y el instalador lo
compara; puedes repetir `Get-FileHash` a mano.

**El panel se ve como texto plano o con escapes.** Estas en una consola legacy
sin VT o con una terminal menor de 64x14. Usa Windows Terminal, o fuerza el
modo texto con `-Verbose`. `nui` habilita `ENABLE_VIRTUAL_TERMINAL_PROCESSING`
cuando puede.

**`winget` no esta o falla.** Normal en Windows 10 sin App Installer: el
instalador usa los ZIPs pinnados de `config/windows/packages.json`. Para traer winget, actualiza "App Installer"
desde la Microsoft Store o desde `https://aka.ms/getwinget`.

**`ssh -T git@github.com` dice "Host key verification failed".** Falta el
known_hosts pinnado. `bootstrap.ps1` lo siembra antes del panel y
`scripts/setup-git-identity.ps1` tambien lo instala; relanza cualquiera de los
dos. Nunca se hace `ssh-keyscan` en caliente: eso aceptaria un MITM.

**OpenSSH rechaza la clave ("UNPROTECTED PRIVATE KEY FILE").** La ACL esta
abierta. `icacls "$HOME\.ssh\id_ed25519_personal" /inheritance:r /grant:r "$($env:USERNAME):(R)"`
y relanza el paso de identidad. `doctor` lo comprueba.

**ssh-agent no guarda las claves.** En Windows es un servicio:

```powershell
Set-Service ssh-agent -StartupType Automatic
Start-Service ssh-agent
ssh-add "$HOME\.ssh\id_ed25519_personal"
```

El instalador no toca servicios sin elevacion: genera claves **sin passphrase**,
asi que el agente es opcional.

**La fuente no aparece en Windows Terminal.** `oh-my-posh`/WT leen el registro
de fuentes; relanza `bootstrap.ps1 -Only "Fuente"` y abre una ventana nueva (las
ventanas abiertas no reescanean fuentes).

**`eza` no se instala.** eza no publica binarios Windows oficiales y su ID de
winget puede no existir: el paso avisa y continua. Alternativa nativa: `ls`
alias o `Get-ChildItem` con `Terminal-Icons`.

**Los colores de `bat`/`fzf` no coinciden.** Vienen del bloque
`dotfiles-theme` del perfil. Abre una terminal nueva o `. $PROFILE`.

**Rutas muy largas (`node_modules`).** `git config --global core.longpaths true`
y, si hace falta, `LongPathsEnabled` en el registro (requiere admin).

**Una terminal nueva no carga nada.** Los bloques se escriben en los dos
perfiles (`Documents\PowerShell\profile.ps1` y
`Documents\WindowsPowerShell\profile.ps1`). Si OneDrive redirige `Documents`,
`$PROFILE` ya apunta al sitio correcto: no hardcodeamos la ruta.

**El instalador se corto a mitad.** Relanzalo: los pasos son idempotentes y los
archivos tocados tienen respaldo en
`~/.config/enviroment-dotfiles/backups/`.

## Desinstalar / revertir

No hay desinstalador automatico (el instalador no escribe un manifest de todo
lo que bajo winget). Para volver atras:

1. Quitar los bloques gestionados de `$PROFILE`
   (marcadores `# >>> dotfiles-env`, `# >>> dotfiles-theme`,
   `# >>> dotfiles-oh-my-posh`).
2. Quitar el bloque `# >>> dotfiles-gitconfig` de `~/.gitconfig` y el
   `# >>> dotfiles-managed` de `~/.ssh/config` si quieres perder las cuentas.
3. Borrar `~/.config/enviroment-dotfiles` (bin, logs, estado y respaldos).
4. Quitar `~/.config/opencode` (config de OpenCode) y, si no lo usas para nada
   mas, `~/.config/nvim`.
5. Desinstalar las herramientas con winget (`winget uninstall Neovim.Neovim`...).

Cada archivo tocado quedo respaldado en `backups/` con marca de tiempo; lo que
esta fuera de los marcadores nunca se modifica.

## Atribuciones

- Tema `dracula.omp.json` vendorizado en `config/oh-my-posh/`: oh-my-posh
  (Jan De Dobbeleer, MIT). Fuente de verdad de los colores:
  `config/theme/dracula.env`.
- JetBrainsMono Nerd Font v3.4.0: `ryanoasis/nerd-fonts` (MIT).
- Windows Terminal: esquema Dracula generado desde la misma paleta.

## Roadmap Windows

- Capa PowerShell del repo privado (`install-private.ps1`).
- Firma de codigo de `nui.exe` (elimina el aviso de SmartScreen).
- Verificacion SHA-256 en la capa bash de las mismas descargas que hoy hace
  `bootstrap.sh` (la capa PowerShell ya la hace para `nui`).
