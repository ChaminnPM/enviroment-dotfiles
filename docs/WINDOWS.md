# Windows nativo

Capa PowerShell del repo: `install.ps1` -> `bootstrap.ps1` -> 18 pasos. Sin WSL
y sin Git Bash, con el mismo contrato que la capa bash
([`STEPS.md`](STEPS.md)). La instalacion y los modificadores comunes estan en el
[`README`](../README.md); aqui solo lo especifico de Windows.

## Requisitos

| Cosa | Minimo | Nota |
|---|---|---|
| SO | Windows 10 22H2 x64 | Windows 11 recomendado. ARM64 best-effort. |
| PowerShell | 5.1 | Se instala 7.x; 5.1 solo tiene que poder arrancar el instalador. |
| Terminal | Windows Terminal | Es el terminal objetivo; sustituye a Alacritty. |
| Utilidades | `curl.exe`, `tar.exe`, `icacls.exe` | Vienen con Windows 10 1803+. |
| OpenSSH Client | caracteristica del SO | `ssh`, `ssh-keygen`, `ssh-add`. |
| Administrador | **no** | Todo se instala por usuario. |

## Instalacion

```powershell
powershell -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/ChaminnPM/enviroment-dotfiles/main/install.ps1 | iex"
```

Alternativas: `install.cmd` (misma descarga, para consolas sin
`-ExecutionPolicy Bypass`) y `pwsh -File install.ps1 -Ref <rama|tag>`.

`install.ps1` baja el repo como ZIP a un temporal, hace `Unblock-File` sobre los
scripts descargados y ejecuta `bootstrap.ps1`. No deja clon en disco.

## Que instala

| Paso | Que hace |
|---|---|
| `Requisitos del sistema` | Comprueba SO, arquitectura, PowerShell, winget y PATH. |
| `Dependencias base` | git, python (con shim `python3`), OpenSSH y PowerShell 7. |
| `Fuente (JetBrains Mono Nerd)` | ZIP v3.4.0 a `%LOCALAPPDATA%\Microsoft\Windows\Fonts` + registro HKCU. |
| `Identidad Git (SSH)` | Claves ed25519, ACLs, perfiles por cuenta y manifiesto JSON. |
| `Registrar y probar llaves SSH` | Portapapeles, navegador y `ssh -T` con host keys pinnadas. |
| `Paquetes custom` | fzf, ripgrep, bat, eza, zoxide, fd, lazygit, Neovim y LazyVim. |
| `Node + gestor de versiones` | fnm (`fnm install --lts`) o Node por winget. |
| `Actualizar gestor de Node (opcional)` | Actualiza fnm. |
| `OpenCode` | `npm install -g @opencode/cli` (sin ZIP: así `opencode update --method npm` funciona). |
| `Restaurar configuracion` | Assets publicos a `~/.config/opencode` + `npm install`. |
| `Windows Terminal (tema)` | Esquema Dracula y fuente Nerd en `settings.json`. |
| `graphify` | Copia la skill a `~/.config/opencode/skills`. |
| `oh-my-posh` | Prompt con `dracula.omp.json` vendorizado. |
| `Tema (Dracula)` | Perfil, `theme.gitconfig`, manifiesto y OpenCode. |
| `herdr` | Instalador oficial. |
| `Wrappers` | `sync-dotfiles.ps1` y `sync-dotfiles.cmd`. |
| `Verificacion final` | Binarios, versiones, bloques de perfil, PATH y doctor. |
| `Persistencia de entorno` | `env.ps1`, PATH de usuario, `XDG_CONFIG_HOME` y politica de ejecucion (`RemoteSigned` en `CurrentUser` si estaba en `Restricted`). |

## Rutas

Todo lo gestionado vive en `~/.config/enviroment-dotfiles`:

```
~/.config/enviroment-dotfiles/
├── bin/            nui.exe, sync-dotfiles.ps1/.cmd, python3.cmd
├── env.ps1         PATH idempotente (lo carga $PROFILE)
├── theme/          copia de config/theme/dracula.env
├── themes/oh-my-posh/dracula.omp.json
├── windows-terminal/dracula.json
├── logs/           un archivo por paso y por ejecucion
├── state/          resultados de formulario y confirmaciones
├── backups/        un respaldo por archivo y ejecucion
├── git-accounts.json
└── theme.json
```

Fuera de ese arbol solo escribe donde lo impone el sistema:

| Dato | Ruta |
|---|---|
| Config de OpenCode | `~/.config/opencode` |
| Claves y `known_hosts` | `~/.ssh` |
| Config global de git | `~/.gitconfig` (bloque gestionado) |
| Perfil de PowerShell | `Documents\PowerShell\profile.ps1` y `Documents\WindowsPowerShell\profile.ps1` |
| Fuente Nerd | `%LOCALAPPDATA%\Microsoft\Windows\Fonts` + HKCU |
| Windows Terminal | `%LOCALAPPDATA%\Packages\Microsoft.WindowsTerminal_*\LocalState\settings.json` |

## Paquetes

El mapeo esta en `config/windows/packages.json`: ID de winget, alcance y ZIP de
respaldo pinnado. Sin admin se usa `winget --scope user`; si winget no esta o el
ID no resuelve, se usa el ZIP. Si tampoco hay red, el paso degrada a **aviso** y
la instalacion continua. Para traer winget donde no existe, actualiza "App
Installer" desde la Microsoft Store o `https://aka.ms/getwinget`.

Cada URL de respaldo se puede sobrescribir por variable de entorno (por ejemplo
`FZF_FALLBACK_URL`) sin editar el repo. `-MachineScope` eleva en bloque (una
sola UAC) en lugar de instalar por usuario.

## Problemas tipicos

**"No se puede ejecutar la politica de ejecucion".** Usa `install.cmd` o
`powershell -ExecutionPolicy Bypass -File install.ps1`.

**"No se puede cargar el archivo ...\profile.ps1 porque la ejecucion de scripts
esta deshabilitada".** El paso `Persistencia de entorno` escribe el perfil, pero
Windows trae la politica `Restricted` y el host rechaza el archivo: el prompt y el
PATH de `env.ps1` no cargan. Relanza `-Only "Persistencia de entorno"` (deja
`RemoteSigned` en `CurrentUser`, sin admin) o ejecuta a mano:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

La politica se lee al arrancar cada shell, asi que aplica tambien a las terminales
que abre herdr: hay que abrir una pestana nueva (las abiertas conservan el shell
donde fallo el perfil). Si `Get-ExecutionPolicy -List` muestra `MachinePolicy` o
`UserPolicy`, la fija una GPO y `CurrentUser` no manda.

**SmartScreen avisa de `nui.exe`.** El binario no esta firmado.
`Unblock-File "$HOME\.config\enviroment-dotfiles\bin\nui.exe"`. El checksum esta
en `bin/SHA256SUMS` y el instalador lo verifica antes de ejecutarlo.

## Prompt

El prompt es el puerto de `vscode`, el tema que usa oh-my-bash en Linux/WSL:
`usuario ➜ ruta (rama) $`, con los colores por slot ANSI (`0;32`, `1;34`,
`0;36`, `1;31`, `1;33`) que salen de `config/theme/dracula.env`. Se elige con
`THEME_OMP_THEME` en ese mismo archivo:

| Valor | Aspecto |
|---|---|
| `vscode` (por defecto) | identico al de oh-my-bash, sin powerline |
| `dracula` | powerline Dracula con hora/rama/node |

Tras cambiarlo, relanza `-Only "oh-my-posh"` (el fichero se copia a
`~/.config/enviroment-dotfiles/themes/oh-my-posh/<tema>.omp.json` y el bloque del
perfil se reescribe solo).

**El panel se ve como texto plano.** Consola legacy sin VT o terminal menor de
64x14. Usa Windows Terminal o fuerza el modo texto con `-Plain`.

**El instalador termina sin mostrar el panel ni los pasos.** La TUI necesita una
consola real; en consolas embebidas (por ejemplo el terminal de un IDE) puede
arrancar sin ella. Relanza con `-Plain` (o `NUI_PLAIN=1`) para ver el runner de
texto completo; si el panel falla, el instalador ya cae solo a texto.

**Decenas de lineas de `icacls ... No se efectuo ninguna asignacion`.** Version
antigua del instalador que concedia permisos por nombre de cuenta. Actualiza el
repo y relanza: las ACL se aplican por SID (no dependen del idioma ni del nombre
del equipo) y, si fallan, se avisa una sola vez.

**Dice `winget: NO disponible` aunque `winget --version` funciona.** Version
antigua del instalador: solo aceptaba versiones sin prefijo y las actuales
imprimen `v1.29.x`. Actualiza el repo y relanza; `Requisitos del sistema` y
`doctor` muestran ahora la version detectada (`winget: disponible (v1.29.380)`).

**El paso `Restaurar configuracion` avisa `npm error ENOENT ... package.json`.** Version
antigua: `npm install --prefix` sigue leyendo el `package.json` del directorio
actual, asi que falla si lanzas el instalador desde `C:\Users\<tu>` (npm 10.x).
Actualiza el repo: npm se ejecuta ahora con su directorio de trabajo en
`~/.config/opencode`.

**Instale algo con winget y no aparece hasta abrir otra terminal.** Es el PATH:
winget lo escribe en el registro y los procesos ya abiertos no lo ven. El
instalador refresca la sesion tras instalar, y ademas localiza los paquetes
portables que winget deja en `%LOCALAPPDATA%\Microsoft\WinGet\Packages` sin
crear shim en `WinGet\Links` (los anade al PATH de usuario). Si aun asi falta,
abre una terminal nueva.

**`Set-PSReadLineOption: 'Prompt' is not a valid color property` al abrir PowerShell.**
Version antigua del bloque de tema: `Prompt` no es una propiedad de color de
PSReadLine. Actualiza el repo y relanza el paso del tema.

**Windows Terminal avisa "Se encontraron errores al cargar la configuracion de
usuario" y habla de un `colorScheme` no valido.** Version antigua del esquema
Dracula: le faltaba el color ANSI `blue` y Windows Terminal invalida el esquema
entero. Actualiza el repo y relanza `-Only "Tema"` (hace respaldo de
`settings.json` antes de tocarlo).

**`ssh -T git@github.com` dice "Host key verification failed".** Falta el
`known_hosts` pinnado: relanza `bootstrap.ps1` o
`scripts/setup-git-identity.ps1`. Nunca se usa `ssh-keyscan`.

**OpenSSH rechaza la clave ("UNPROTECTED PRIVATE KEY FILE").** La ACL esta
abierta; `doctor` lo detecta y relanzar el paso de identidad la corrige con
`icacls`.

**La fuente no aparece en Windows Terminal.** Las ventanas abiertas no
reescanean fuentes: relanza `-Only "Fuente"` y abre una ventana nueva.

**El instalador se corto a mitad.** Relanzalo: los pasos son idempotentes y cada
archivo tocado tiene respaldo en `backups/`.

## Desinstalar

No hay desinstalador automatico. Para revertir:

1. Quita los bloques `# >>> dotfiles-...` de `$PROFILE`, el bloque
   `# >>> dotfiles-gitconfig` de `~/.gitconfig` y el `# >>> dotfiles-managed` de
   `~/.ssh/config`.
2. Borra `~/.config/enviroment-dotfiles` y, si no la usas para nada mas,
   `~/.config/opencode`.
3. Desinstala las herramientas con winget (`winget uninstall Neovim.Neovim`, ...).

## Atribuciones

- `dracula.omp.json`: oh-my-posh (MIT). Los colores salen de
  `config/theme/dracula.env`.
- JetBrainsMono Nerd Font v3.4.0: `ryanoasis/nerd-fonts` (MIT).
- Esquema Dracula de Windows Terminal: generado desde la misma paleta.
