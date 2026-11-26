#!/usr/bin/env pwsh
# bootstrap.ps1 - instalador NATIVO de Windows (sin WSL y sin Git Bash).
#
# Uso:
#   pwsh -File bootstrap.ps1                     # instalacion completa
#   pwsh -File bootstrap.ps1 -DryRun             # imprime el plan y no toca nada
#   pwsh -File bootstrap.ps1 -NonInteractive     # defaults, modo texto
#   pwsh -File bootstrap.ps1 -Only "OpenCode"    # solo pasos que coinciden
#   pwsh -File bootstrap.ps1 -SkipGit            # omite identidad Git/SSH
#   pwsh -File bootstrap.ps1 -MachineScope       # winget machine (una UAC)
#   pwsh -File bootstrap.ps1 -Plain              # sin panel (texto, con todo)
#
# Equivalente de bootstrap.sh para Windows. Comparte con el flujo bash el
# contrato de docs/STEPS.md: mismos pasos, mismas directivas, mismo plan JSON
# (con shell=pwsh) y mismos marcadores de bloque gestionado.
#
# Politicas:
#   - CERO admin por defecto: winget --scope user y ZIPs pinnados. -MachineScope
#     es explicito y provoca una unica elevacion en bloque;
#   - todo el estado del proyecto vive en ~/.config/enviroment-dotfiles;
#   - ningun dato del usuario se interpola en una cadena de shell.

[CmdletBinding()]
param(
    [string]$RepoDir,
    [string]$DotfilesHome,
    [string]$Only,
    [switch]$DryRun,
    [switch]$NonInteractive,
    [switch]$NoColor,
    [switch]$SkipGit,
    [switch]$MachineScope,
    [switch]$WithPowerShell7,
    # -Plain fuerza el runner de texto (sin panel). Es la salida de emergencia
    # cuando la consola no soporta la TUI: imprime todo y no pierde errores.
    [switch]$Plain,
    [ValidateSet('fnm', 'node')][string]$NodeManager = 'fnm',
    [string]$Title
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Ningun fallo puede terminar en silencio: sin esto, un error no controlado en
# `irm | iex` (o durante el import de los modulos) deja la consola limpia y
# parece que el instalador "no hizo nada". Es lo primero del script y no usa
# Write-Ui*: puede dispararse antes de que los modulos esten cargados.
trap {
    $msg = if ($_.Exception) { $_.Exception.Message } else { "$_" }
    Write-Host ''
    Write-Host "[ERROR] instalacion interrumpida: $msg" -ForegroundColor Red
    if (Test-Path variable:Paths) {
        Write-Host "        Log: $($Paths.LogDir)" -ForegroundColor DarkGray
    }
    Write-Host '        Reintenta con -Plain (o -Verbose) para ver la salida completa.' -ForegroundColor DarkGray
    exit 1
}

# --- arranque --------------------------------------------------------------

if (-not $RepoDir) { $RepoDir = $PSScriptRoot }
$RepoDir = (Resolve-Path -LiteralPath $RepoDir).Path
if ($DotfilesHome) { $env:DOTFILES_HOME = $DotfilesHome }

$LibDir = [IO.Path]::Combine($RepoDir, 'scripts', 'lib')
Import-Module (Join-Path $LibDir 'dotfiles.psm1') -Force
Import-Module (Join-Path $LibDir 'ui.psm1') -Force
Import-Module (Join-Path $LibDir 'theme.psm1') -Force
Import-Module (Join-Path $LibDir 'packages.psm1') -Force

$VerboseOn = [bool]$PSBoundParameters['Verbose'] -or $env:VERBOSE -eq '1'

$Paths = Get-DotfilesPaths
$Platform = Get-DotfilesPlatform

if ($VerboseOn) { $env:VERBOSE = '1' }
if ($NoColor -or $env:NUI_NO_COLOR -eq '1') {
    $env:NUI_NO_COLOR = '1'
    $env:NO_COLOR = '1'
}
if ($NonInteractive) { $env:NUI_NONINTERACTIVE = '1' }
if ($DryRun) { $env:NUI_DRY_RUN = '1' }
if ($Plain) { $env:NUI_PLAIN = '1' }
if ($Only) { $env:NUI_ONLY = $Only }
$env:REPO_DIR = $RepoDir
$env:OPENCODE_DIR = $Paths.OpenCodeDir
$env:LOG_DIR = $Paths.LogDir
$env:NUI_ENV_FILE = $Paths.EnvFile
$env:DOTFILES_LIB = $LibDir
$env:DOTFILES_STATE_DIR = $Paths.StateDir
$env:DOTFILES_PLATFORM = $Platform
$env:DOTFILES_MACHINE_SCOPE = if ($MachineScope) { '1' } else { '0' }
$env:DOTFILES_NODE_MANAGER = $NodeManager
$env:DOTFILES_SKIP_GIT = if ($SkipGit) { '1' } else { '0' }
$env:DOTFILES_WITH_PS7 = if ($WithPowerShell7) { '1' } else { '0' }
$env:NUI_STEP_RESULT = $null

Initialize-DotfilesUi -Paths $Paths

# --- gate de plataforma ----------------------------------------------------

if ($Platform -notin @('windows')) {
    Write-UiError "bootstrap.ps1 es el instalador NATIVO de Windows; plataforma detectada: $Platform"
    if ($Platform -in @('linux', 'wsl')) {
        Write-UiDim 'En Linux/WSL usa bootstrap.sh (o install.sh).'
    } else {
        Write-UiDim 'Ver docs/PLATFORMS.md.'
    }
    exit 1
}

if (-not [Environment]::Is64BitOperatingSystem) {
    Write-UiError 'Windows de 32 bits no esta soportado (x64 minimo).'
    exit 1
}

$psMajor = $PSVersionTable.PSVersion.Major
if ($psMajor -lt 5) {
    Write-UiError "PowerShell $psMajor no soportado; se requiere 5.1 o PowerShell 7."
    exit 1
}

# --- preinstalacion: nui, respaldo de perfiles, known_hosts ----------------

if ($env:NUI_DRY_RUN -ne '1') {
    try {
        $null = Add-DotfilesUi
    } catch {
        Write-UiWarn "no se pudo instalar nui: $($_.Exception.Message)"
    }
    # Dejar el PATH persistido ANTES de los pasos: una terminal nueva debe ver
    # los binarios aunque la instalacion se cancele a mitad.
    $null = Install-DotfilesProfileEnv
    foreach ($d in @($Paths.BinDir)) { $null = Add-DotfilesEnvPath -Dir $d }
    $null = Update-DotfilesKnownHosts
}

# --- calculo de dependencias faltantes ------------------------------------

$baseMissing = @()
foreach ($pkg in Get-DotfilesPackageList -Section 'base') {
    if (-not $pkg) { continue }
    if ($pkg['scope'] -eq 'system') { continue }
    if (Test-DotfilesPackageInstalled -Package $pkg) { continue }
    if ($pkg['optional'] -and -not $WithPowerShell7) { continue }
    $baseMissing += $pkg
}
$env:DOTFILES_BASE_MISSING = ($baseMissing | ForEach-Object { $_['key'] }) -join ';'

$panel = New-DotfilesPanel -Title $(if ($Title) { $Title } else { 'AGENTS ENVIRONMENT' })

$null = Add-DotfilesPanelNote -Panel $panel -Text 'Comandos: sync-dotfiles pull/push'
$null = Add-DotfilesPanelNote -Panel $panel -Text 'Config: ~/.config/enviroment-dotfiles y ~/.config/opencode'
$null = Add-DotfilesPanelNote -Panel $panel -Text 'Abre una terminal nueva para cargar el PATH (no relances pwsh dentro del instalador)'
if ($MachineScope) {
    $null = Add-DotfilesPanelNote -Panel $panel -Text 'Modo machine-scope: winget puede pedir UAC una sola vez'
}
if ($SkipGit) {
    $null = Add-DotfilesPanelNote -Panel $panel -Text 'Identidad Git omitida (-SkipGit)'
}

# --- 1. requisitos ---------------------------------------------------------
$panel = Add-DotfilesPanelStep -Panel $panel -Title 'Requisitos del sistema' -Estimate 10 -Body {
    $wingetOk = Test-DotfilesWinget
    $wingetVer = Get-DotfilesWingetVersion
    $wingetState = if (-not $wingetOk) { 'NO disponible' }
    elseif ($wingetVer) { "disponible ($wingetVer)" }
    else { 'disponible (version desconocida)' }
    $info = @{
        OS      = [System.Environment]::OSVersion.VersionString
        Arch    = (Get-DotfilesUiArch)
        PS      = "$($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
        Home    = (Get-DotfilesPaths).Home
        Winget  = $wingetState
        Admin   = if (Test-DotfilesAdmin) { 'si' } else { 'no (por usuario)' }
        Scope   = if ($env:DOTFILES_MACHINE_SCOPE -eq '1') { 'machine' } else { 'user' }
        NodeMgr = $env:DOTFILES_NODE_MANAGER
    }
    Write-UiStepLog "SO: $($info.OS) [$($info.Arch)]"
    Write-UiStepLog "PowerShell: $($info.PS)"
    Write-UiStepLog "Home: $($info.Home)"
    Write-UiStepLog "winget: $($info.Winget) | alcance: $($info.Scope) | admin: $($info.Admin)"
    Write-UiStepLog "Node manager: $($info.NodeMgr)"

    if ($info.Winget -eq 'NO disponible') {
        Write-UiWarn 'winget no esta disponible: se usaran los ZIPs pinnados de config/windows/packages.json'
        Write-UiDim 'Si winget --version funciona, actualiza el repo: versiones nuevas imprimen "v1.29.x" y el instalador debe aceptarlo.'
    }
    if ($env:DOTFILES_MACHINE_SCOPE -eq '1' -and -not $info.Admin -and (Test-DotfilesWinget)) {
        Write-UiWarn 'machine-scope sin sesion elevada: los paquetes que requieran admin se intentaran por usuario'
    }
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        Write-UiDim 'PowerShell 5.1 detectado: funciona, pero se recomienda PowerShell 7 (-WithPowerShell7)'
    }
    $missing = @()
    foreach ($c in 'curl.exe', 'tar.exe') {
        if (-not (Get-Command $c -CommandType Application -ErrorAction SilentlyContinue)) { $missing += $c }
    }
    if ($missing.Count -gt 0) {
        Write-UiWarn ("faltan utilidades del SO: " + ($missing -join ', ') + ' (Windows 10 1803+ las incluye)')
    }
    Write-Output '##progress 100'
    'Requisitos verificados'
}

# --- 2. dependencias base --------------------------------------------------
$panel = Add-DotfilesPanelStep -Panel $panel -Title 'Dependencias base' -Estimate 90 -Body {
    $machine = $env:DOTFILES_MACHINE_SCOPE -eq '1'
    # Releer el PATH del registro ANTES de decidir que falta: winget instala en
    # %LOCALAPPDATA%\...\WinGet\Links y este proceso no lo ve hasta refrescar.
    $null = Update-DotfilesSessionPath
    $missing = @()
    foreach ($pkg in Get-DotfilesPackageList -Section 'base') {
        if (-not $pkg) { continue }
        if ($pkg['scope'] -eq 'system') { continue }
        if ($pkg['optional'] -and $env:DOTFILES_WITH_PS7 -ne '1') { continue }
        if (Test-DotfilesPackageInstalled -Package $pkg) {
            # Aunque ya este, hay que dejarla visible: winget pudo instalarla sin
            # crear el shim (ver Find-DotfilesWingetTool).
            Publish-DotfilesWingetTool -Command $pkg['command']
            Write-UiStepLog "$($pkg['key']) OK"
            continue
        }
        $missing += $pkg
    }
    if ($missing.Count -eq 0) {
        Write-UiStepLog 'Todas las dependencias base ya estaban instaladas'
        # Aun asi se comprueba git: sin git no hay sync ni skills.
        if (-not (Test-DotfilesCommand 'git')) {
            Write-UiWarn 'git no esta en el PATH; instala Git for Windows'
            exit 1
        }
        Write-Output '##progress 100'
        'Dependencias base listas'
        exit 0
    }

    $i = 0
    foreach ($pkg in $missing) {
        $i++
        Write-UiStepLog ("instalando ({0}/{1}): {2}" -f $i, $missing.Count, $pkg['key'])
        $r = Add-DotfilesPackage -Package $pkg -MachineScope:$machine
        if ($r.ok) {
            Write-UiStepLog "$($pkg['key']): $($r.detail)"
        } else {
            Write-UiWarn ("{0} no se pudo instalar: {1}" -f $pkg['key'], $r.detail)
        }
        Write-Output "##progress $([int](100 * $i / $missing.Count))"
    }

    # winget actualiza el PATH en el registro, no en este proceso: sin refrescar,
    # `python`/`git` recien instalados siguen "sin estar" y el paso aborta.
    $null = Update-DotfilesSessionPath

    # python3 shim: graphify y los validadores de skills lo invocan por ese
    # nombre y en Windows el ejecutable es python.exe.
    $py = Get-Command 'python.exe', 'python' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($py) {
        if (-not (Get-Command 'python3' -CommandType Application -ErrorAction SilentlyContinue)) {
            $null = Install-DotfilesCommandShim -Alias 'python3' -Target $py.Source
            Write-UiStepLog "shim python3 -> $($py.Source)"
        }
    } else {
        Write-UiWarn 'python no disponible: graphify no funcionara hasta instalarlo'
    }

    if (-not (Test-DotfilesCommand 'git')) {
        Write-UiWarn 'git sigue sin estar disponible; los pasos de config/sync no podran ejecutar'
        exit 1
    }
    if (-not (Test-DotfilesCommand 'ssh')) {
        Write-UiWarn 'OpenSSH Client no esta disponible; la identidad Git puede fallar'
    }
    'Dependencias base atendidas'
}

# --- 3. fuente -------------------------------------------------------------
$panel = Add-DotfilesPanelStep -Panel $panel -Title 'Fuente (JetBrains Mono Nerd)' -Optional -Estimate 60 -Body {
    $theme = Read-DotfilesTheme
    $r = Update-DotfilesNerdFont -Theme $theme
    if (Test-DotfilesResultSkipped -Result $r) {
        Write-UiWarn $r.detail
        exit 0
    }
    if ($r.ok -and $r.installed) {
        Write-UiOk $r.detail
    } elseif ($r.detail) {
        Write-UiWarn $r.detail
    } else {
        Write-UiWarn 'la fuente no se pudo instalar'
    }
}

# --- 4/5. identidad git -----------------------------------------------------
if (-not $SkipGit) {
    $null = Add-DotfilesPanelNote -Panel $panel -Text 'Identidad: personal obligatoria; elige 0-3 cuentas adicionales'

    $gitInputs = @'
input p_platform Plataforma personal (github|bitbucket):
default p_platform github
input p_name Nombre personal:
input p_email Email personal:
select acc_count Cuantas cuentas adicionales? (0-3):
default acc_count 0
option acc_count 0
option acc_count 1
option acc_count 2
option acc_count 3
'@
    # El here-string cierra SIN salto de linea final: hay que anadirlo, si no
    # la primera linea generada en el bucle se pega a "option acc_count 3".
    $gitInputs += "`n"
    for ($n = 1; $n -le 3; $n++) {
        $note = if ($n -eq 1) { '(carpeta en tu home, ej. Nuxiba; vacio ignora)' } else { '(vacio ignora)' }
        $gitInputs += "input acc$($n)_espacio Espacio cuenta ${n} $note`n"
        $gitInputs += "showif acc$($n)_espacio acc_count gte $n`n"
        $gitInputs += "input acc$($n)_platform Plataforma cuenta ${n} (github|bitbucket):`n"
        $gitInputs += "default acc$($n)_platform github`n"
        $gitInputs += "showif acc$($n)_platform acc_count gte $n`n"
        $gitInputs += "showif acc$($n)_platform acc$($n)_espacio nonempty`n"
        $gitInputs += "input acc$($n)_name Nombre cuenta ${n}:`n"
        $gitInputs += "showif acc$($n)_name acc_count gte $n`n"
        $gitInputs += "showif acc$($n)_name acc$($n)_espacio nonempty`n"
        $gitInputs += "input acc$($n)_email Email cuenta ${n}:`n"
        $gitInputs += "showif acc$($n)_email acc_count gte $n`n"
        $gitInputs += "showif acc$($n)_email acc$($n)_espacio nonempty`n"
    }
    $panel = Add-DotfilesPanelInputDsl -Panel $panel -Text $gitInputs
    $panel = Add-DotfilesPanelStep -Panel $panel -Title 'Identidad Git (SSH)' -Optional -Estimate 45 -Body {
        $script = Join-DotfilesPath -Base $env:REPO_DIR -Child 'scripts/setup-git-identity.ps1'
        $code = Invoke-DotfilesNativeQuoted -Argv @((Get-DotfilesSelfPwsh), '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script)
        if ($code -ne 0) {
            Write-UiWarn "setup-git-identity.ps1 termino con codigo $code"
            exit $code
        }
    }

    $panel = Add-DotfilesPanelStep -Panel $panel -Title 'Registrar y probar llaves SSH' -Optional -Estimate 40 -Body {
        $paths = Get-DotfilesPaths
        $accountsFile = $paths.AccountsFile
        if (-not (Test-Path -LiteralPath $accountsFile)) {
            Write-UiStepLog 'Sin manifiesto de cuentas git; prueba omitida (relanza el paso de identidad)'
            exit 0
        }
        $accounts = Read-DotfilesJson -Path $accountsFile -AsHashtable
        $personal = $accounts['personal']
        $spaces = @($accounts['spaces'])
        $total = 1 + $spaces.Count

        function Get-AccountUrl([string]$Platform) {
            if ($Platform -eq 'bitbucket') { return 'https://bitbucket.org/account/settings/ssh-keys/' }
            return 'https://github.com/settings/ssh/new'
        }

        function Show-Key([hashtable]$Acc, [int]$Order) {
            $title = $Acc['title']
            $pub = $Acc['pub']
            $url = Get-AccountUrl $Acc['platform']
            Write-Output "##title Llave $Order/$total"
            if (-not (Test-Path -LiteralPath $pub)) {
                Write-UiStepLog "$title sin clave publica ($pub); omitida"
                return $false
            }
            $text = (Get-DotfilesFileText -Path $pub).Trim()
            Write-UiStepLog "Llave publica de $title :"
            foreach ($l in ($text -split "`n")) { Write-UiStepLog $l }
            if (Copy-DotfilesClipboard -Text $text) {
                Write-UiStepLog "Llave $title copiada al portapapeles"
            } else {
                Write-UiWarn 'No hay portapapeles disponible; copia la linea mostrada arriba'
            }
            if (Show-DotfilesUrl -Url $url) {
                Write-UiStepLog "Plataforma abierta: $url"
            } else {
                Write-UiStepLog "Abre manualmente: $url"
            }
            Write-UiStepLog 'Pega la llave como una NUEVA llave SSH en la plataforma'
            return $true
        }

        $order = 1
        $all = @()
        $all += @{
            title    = "Cuenta personal ($($personal['platform']))"
            pub      = $personal['pub']
            platform = $personal['platform']
            target   = if ($personal['platform'] -eq 'bitbucket') { 'git@bitbucket.org' } else { 'git@github.com' }
        }
        foreach ($s in $spaces) {
            $all += @{
                title    = "Espacio $($s['espacio'])"
                pub      = $s['pub']
                platform = $s['platform']
                target   = "git@git-$($s['slug'])"
            }
        }

        foreach ($acc in $all) {
            Write-Output "##progress $([int](100 * $order / $total))"
            if (-not (Show-Key -Acc $acc -Order $order)) { $order++; continue }
            if (Wait-DotfilesPanelConfirm -Id "key$order" -Question "Llave $order/$total registrada y guardada en $($acc['title']). Comprobar ahora?") {
                $null = Test-DotfilesSsh -Title $acc['title'] -Target $acc['target']
            } else {
                Write-UiStepLog "Comprobacion de $($acc['title']) omitida; puedes volver a ejecutar este paso"
            }
            $order++
        }
        Write-Output '##progress 100'
        Write-UiStepLog 'Registro y comprobacion SSH finalizados'
    }
}

# --- 6. paquetes custom -----------------------------------------------------
$panel = Add-DotfilesPanelInput -Panel $panel -Type 'select' -Name 'extras' `
    -Prompt 'Paquetes custom (espacio para marcar, enter confirma)' -Multi `
    -Options @('lazyvim', 'fzf', 'ripgrep', 'bat', 'eza', 'zoxide', 'fd-find', 'lazygit', 'neovim') `
    -Default @('neovim')
$panel = Add-DotfilesPanelStep -Panel $panel -Title 'Paquetes custom' -Estimate 120 -Body {
    $machine = $env:DOTFILES_MACHINE_SCOPE -eq '1'
    $selected = @()
    if ($extras) { $selected = @($extras -split "`n" | Where-Object { $_ }) }
    if ($selected.Count -eq 0) {
        Write-UiStepLog 'No se seleccionaron paquetes custom'
        exit 0
    }
    Write-UiStepLog ("seleccion: " + ($selected -join ', '))
    # Igual que en 'Dependencias base': sin refrescar el PATH, lo ya instalado
    # por winget parece ausente y se reinstala (o se cae al ZIP) en cada pasada.
    $null = Update-DotfilesSessionPath

    $i = 0
    foreach ($key in $selected) {
        $i++
        $pkg = Get-DotfilesPackage -Key $key -Section 'custom'
        if (-not $pkg) {
            Write-UiWarn "$key no esta en config/windows/packages.json"
            continue
        }
        Write-Output "##progress $([int](60 * $i / $selected.Count))"
        if ($pkg['scope'] -eq 'config') {
            Write-UiStepLog "${key}: se aplica tras instalar neovim"
            continue
        }
        if (Test-DotfilesPackageInstalled -Package $pkg) {
            Publish-DotfilesWingetTool -Command $pkg['command']
            Write-UiStepLog "$key OK ($($pkg['command']))"
            continue
        }
        $r = Add-DotfilesPackage -Package $pkg -MachineScope:$machine
        if ($r.ok) { Write-UiStepLog "${key}: $($r.detail)" }
        else { Write-UiWarn "$key no se pudo instalar: $($r.detail)" }
    }

    # neovim: LazyVim/treesitter requieren version > 0.11.2 y un compilador.
    $needNvim = ($selected -contains 'neovim') -or ($selected -contains 'lazyvim')
    if ($needNvim) {
        # El proceso actual conserva el PATH con el que arranco; winget escribe
        # el suyo en el registro. Sin refrescar, nvim recien instalado "no esta".
        $null = Update-DotfilesSessionPath
        $ver = Get-DotfilesNvimVersion
        if (-not $ver) {
            # Cinturon y tirantes: instalaciones machine-scope dejan nvim fuera
            # del PATH de usuario.
            $cands = @()
            if ($env:ProgramFiles) { $cands += (Join-Path $env:ProgramFiles 'Neovim\bin') }
            if ($env:LOCALAPPDATA) {
                $cands += (Join-Path $env:LOCALAPPDATA 'Programs\Neovim\bin')
                $cands += (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links')
            }
            foreach ($cand in $cands) {
                if ($cand -and (Test-Path -LiteralPath (Join-Path $cand 'nvim.exe'))) {
                    $env:Path = "$cand;$env:Path"
                    $ver = Get-DotfilesNvimVersion
                    break
                }
            }
        }
        if (-not $ver) {
            Write-UiWarn 'neovim no quedo disponible; LazyVim no funcionara'
        } elseif (-not (Test-DotfilesSemverGt -Version $ver -Minimum '0.11.2')) {
            Write-UiWarn "neovim $ver no supera la version requerida 0.11.2"
        } else {
            Write-UiStepLog "neovim OK ($ver)"
        }
        if (-not (Get-DotfilesCC)) {
            Write-UiWarn 'No hay compilador C; los plugins nativos de LazyVim no compilaran'
            Write-UiDim 'Instala Visual Studio Build Tools o MinGW (winget install --id MLSquared.MSVC ...)'
        }
    }

    if ($selected -contains 'lazyvim') {
        $paths = Get-DotfilesPaths
        $nvimCfg = $paths.NvimDir
        if (-not (Test-Path -LiteralPath $nvimCfg)) {
            Write-UiStepLog 'Clonando LazyVim starter'
            $code = Invoke-DotfilesNative -Argv @('git', 'clone', '--depth', '1', 'https://github.com/LazyVim/starter', $nvimCfg)
            if ($code -eq 0) {
                $gitDir = Join-Path $nvimCfg '.git'
                if (Test-Path -LiteralPath $gitDir) { Remove-Item -LiteralPath $gitDir -Recurse -Force }
            } else {
                Write-UiWarn 'No se pudo instalar LazyVim automaticamente'
            }
        } else {
            Write-UiStepLog "~/.config/nvim ya existe; no se toca"
        }
    }
    Write-Output '##progress 100'
    'Paquetes custom atendidos'
}

# --- 7. node ---------------------------------------------------------------
$panel = Add-DotfilesPanelStep -Panel $panel -Title 'Node + gestor de versiones' -Estimate 150 -Body {
    $paths = Get-DotfilesPaths
    $manager = $env:DOTFILES_NODE_MANAGER
    $fnmPin = if ($env:FNM_VERSION) { $env:FNM_VERSION } else { 'v1.38.1' }

    if (Test-DotfilesCommand 'node') {
        Write-UiStepLog "Node $($(& node --version)) ya disponible"
    } else {
        $appNode = Get-DotfilesPackage -Key 'node' -Section 'apps'
        $appFnm = Get-DotfilesPackage -Key 'fnm' -Section 'apps'
        if ($manager -eq 'fnm' -and $appFnm) {
            $r = Add-DotfilesApp -App $appFnm
            if ($r.ok) {
                Write-UiStepLog "fnm: $($r.detail)"
                $null = Invoke-DotfilesLoggedArgv -Title 'Instalando Node LTS con fnm...' -Argv @('fnm', 'install', '--lts')
                $null = Invoke-DotfilesNative -Argv @('fnm', 'default', 'lts/*')
            } else {
                Write-UiWarn "fnm no se pudo instalar: $($r.detail)"
            }
        }
        if (-not (Test-DotfilesCommand 'node') -and $appNode) {
            $r = Add-DotfilesApp -App $appNode
            if ($r.ok) { Write-UiStepLog "Node: $($r.detail)" }
            else { Write-UiWarn "Node no se pudo instalar: $($r.detail)" }
        }
    }

    # fnm guarda los node installados bajo una ruta propia: hay que anadirla al
    # PATH y activar el hook del perfil para que `node` este en una shell nueva.
    if (Test-DotfilesCommand 'fnm') {
        $fnmData = if ($env:FNM_DIR) { $env:FNM_DIR } else { (Join-Path $env:LOCALAPPDATA 'fnm') }
        $null = Add-DotfilesEnvPath -Dir $fnmData
        $nodeDir = Get-DotfilesFnmNodeDir -FnmDir $fnmData
        if ($nodeDir) { $null = Add-DotfilesEnvPath -Dir $nodeDir }
        Write-UiStepLog "fnm data: $fnmData (pin $fnmPin)"
    }
    $npmGlobal = Join-Path $env:APPDATA 'npm'
    if (Test-Path -LiteralPath $npmGlobal) { $null = Add-DotfilesEnvPath -Dir $npmGlobal }

    if (Test-DotfilesCommand 'node') {
        Write-UiStepLog "Node $(& node --version)"
    } else {
        Write-UiWarn 'Node no quedo disponible en este paso'
    }
    if (-not (Test-DotfilesCommand 'npm')) {
        Write-UiWarn 'npm no esta disponible; el paso "Restaurar configuracion" no podra instalar dependencias'
    }
}

# --- 8. actualizar gestor de node ------------------------------------------
$panel = Add-DotfilesPanelStep -Panel $panel -Title 'Actualizar gestor de Node (opcional)' -Optional -Estimate 30 -Body {
    $manager = $env:DOTFILES_NODE_MANAGER
    if ($manager -ne 'fnm') {
        Write-UiStepLog 'Gestor de Node: winget/OpenJS.NodeJS.LTS (nada que actualizar aqui)'
        exit 0
    }
    if (-not (Test-DotfilesCommand 'fnm')) {
        Write-UiStepLog 'fnm no instalado; nada que actualizar'
        exit 0
    }
    $cur = (& fnm --version 2>$null | Select-Object -First 1)
    $want = if ($env:FNM_VERSION) { ($env:FNM_VERSION -replace '^v', '') } else { '1.38.1' }
    if ("$cur" -eq $want) {
        Write-UiStepLog "fnm $cur ya esta en la version fijada"
        exit 0
    }
    Write-UiStepLog "Actualizando fnm $cur -> $want"
    $app = Get-DotfilesPackage -Key 'fnm' -Section 'apps'
    $r = Add-DotfilesPackage -Package $app
    if ($r.ok) { Write-UiStepLog "fnm ahora: $(& fnm --version 2>$null | Select-Object -First 1)" }
    else { Write-UiWarn "no se pudo actualizar fnm: $($r.detail)" }
}

# --- 9. opencode ------------------------------------------------------------
$panel = Add-DotfilesPanelStep -Panel $panel -Title 'OpenCode' -Estimate 120 -Body {
    if (-not (Test-DotfilesCommand 'opencode')) {
        $app = Get-DotfilesPackage -Key 'opencode' -Section 'apps'
        if ($app) {
            $r = Add-DotfilesApp -App $app
            if ($r.ok) { Write-UiStepLog "OpenCode: $($r.detail)" }
            else {
                Write-UiWarn "OpenCode no se pudo instalar: $($r.detail)"
                exit 1
            }
        }
    }
    foreach ($d in @((Get-DotfilesPaths).BinDir, (Join-Path $env:APPDATA 'npm'), (Join-Path $env:LOCALAPPDATA 'Programs\opencode\bin'))) {
        if (Test-Path -LiteralPath $d) { $null = Add-DotfilesEnvPath -Dir $d }
    }
    # Igual que en 'Paquetes custom': npm -g escribe opencode en %APPDATA%\npm
    # y el proceso actual no lo ve sin releer el PATH del registro.
    $null = Update-DotfilesSessionPath
    if (Test-DotfilesCommand 'opencode') {
        $v = & opencode --version 2>$null | Select-Object -First 1
        Write-UiOk "OpenCode $v"
    } else {
        Write-UiWarn 'OpenCode no encontrado en PATH; revisa ~/.config/enviroment-dotfiles/bin y %APPDATA%\npm'
        exit 1
    }
}

# --- 10. restaurar config ---------------------------------------------------
$panel = Add-DotfilesPanelStep -Panel $panel -Title 'Restaurar configuracion' -Estimate 90 -Body {
    $paths = Get-DotfilesPaths
    $src = Join-DotfilesPath -Base $paths.RepoDir -Child 'config/opencode'
    $dst = $paths.OpenCodeDir
    if (-not (Test-Path -LiteralPath $src)) {
        Write-UiWarn "no existe $src; nada que restaurar"
        exit 0
    }
    if (-not (Test-Path -LiteralPath $dst)) { New-Item -ItemType Directory -Force -Path $dst | Out-Null }

    foreach ($rel in Get-DotfilesPublicPathList) {
        $s = (Join-Path $src $rel) -replace '/', [IO.Path]::DirectorySeparatorChar
        $d = (Join-Path $dst $rel) -replace '/', [IO.Path]::DirectorySeparatorChar
        if (-not (Test-Path -LiteralPath $s)) { continue }
        if (-not (Copy-DotfilesTree -Source $s -Destination $d)) {
            Write-UiWarn "no se pudo copiar $rel"
        }
    }
    Write-UiStepLog "Assets publicos aplicados en $dst"

    $pkg = Join-Path $dst 'package.json'
    if (Test-Path -LiteralPath $pkg) {
        if (Test-DotfilesCommand 'npm') {
            $log = Join-Path $paths.LogDir ("npm-install-{0}-{1}.log" -f (Get-DotfilesStamp), $PID)
            Write-UiStepLog 'Instalando dependencias npm'
            # Sin --prefix: npm lee el package.json del CWD antes del prefix y
            # desde C:\Users\X falla con ENOENT (npm 10.9.8). El cwd del hijo
            # es el proyecto.
            $code = Invoke-DotfilesNativeLogged -Argv @('npm', 'install', '--no-audit', '--no-fund') -LogFile $log -TimeoutSec 900 -WorkingDirectory $dst
            if ($code -ne 0) {
                Write-UiStepLog 'Reintentando npm install (prefer-online)'
                $code = Invoke-DotfilesNativeLogged -Argv @('npm', 'install', '--no-audit', '--no-fund', '--prefer-online') -LogFile $log -TimeoutSec 900 -WorkingDirectory $dst
                if ($code -eq 0) { Write-UiStepLog 'npm install exitoso tras el reintento' }
                else {
                    Write-UiWarn "npm install fallo; revisa $log"
                    Show-DotfilesLogTail -Path $log -Lines 8
                }
            }
        } else {
            Write-UiWarn 'npm no disponible; no se instalaron las dependencias'
        }
    }
    'Configuracion restaurada'
}

# --- 11. windows terminal ---------------------------------------------------
$panel = Add-DotfilesPanelStep -Panel $panel -Title 'Windows Terminal (tema)' -Optional -Estimate 15 -Body {
    $theme = Read-DotfilesTheme
    $paths = Get-DotfilesPaths
    if (-not $paths.TerminalSettings) {
        Write-UiStepLog 'Windows Terminal no detectado; paso omitido'
        exit 0
    }
    $r = Set-DotfilesWindowsTerminalTheme -Theme $theme
    if (Test-DotfilesResultSkipped -Result $r) { Write-UiStepLog $r.detail; exit 0 }
    if ($r.ok) { Write-UiOk $r.detail }
    else { Write-UiWarn $r.detail }
}

# --- 12. graphify -----------------------------------------------------------
$panel = Add-DotfilesPanelStep -Panel $panel -Title 'graphify' -Estimate 20 -Body {
    $paths = Get-DotfilesPaths
    $src = Join-DotfilesPath -Base $paths.RepoDir -Child 'config/opencode/skills/graphify'
    $dst = Join-DotfilesPath -Base $paths.OpenCodeDir -Child 'skills/graphify'
    if (-not (Test-Path -LiteralPath $src)) {
        Write-UiStepLog 'graphify no encontrado en el repo'
        exit 0
    }
    if (-not (Test-Path -LiteralPath (Split-Path -Parent $dst))) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
    }
    if (Copy-DotfilesTree -Source $src -Destination $dst) { 'graphify instalado' }
    else {
        Write-UiWarn 'No se pudo copiar graphify'
        exit 1
    }
}

# --- 13. oh-my-posh ---------------------------------------------------------
$panel = Add-DotfilesPanelStep -Panel $panel -Title 'oh-my-posh' -Estimate 90 -Body {
    $theme = Read-DotfilesTheme
    $paths = Get-DotfilesPaths

    $app = Get-DotfilesPackage -Key 'oh-my-posh' -Section 'apps'
    if (-not $app) {
        Write-UiWarn 'oh-my-posh no esta en el manifiesto de paquetes'
        exit 1
    }
    if (Test-DotfilesCommand 'oh-my-posh') {
        Write-UiStepLog 'oh-my-posh ya instalado'
    } else {
        $r = Add-DotfilesApp -App $app
        if ($r.ok) { Write-UiStepLog "oh-my-posh: $($r.detail)" }
        else {
            Write-UiWarn "oh-my-posh no se pudo instalar: $($r.detail)"
            exit 1
        }
    }

    # El prompt de Windows replica el tema de oh-my-bash (misma forma en las dos
    # capas). config/theme/dracula.env elige el fichero con THEME_OMP_THEME.
    # Se fija en ~/.config/enviroment-dotfiles/themes: mismo arbol que todo lo
    # demas y sin depender de POSH_THEMES_PATH.
    $ompName = if ($theme.THEME_OMP_THEME) { $theme.THEME_OMP_THEME } else { 'dracula' }
    if ($ompName -notmatch '^[A-Za-z0-9._-]+$') {
        Write-UiWarn "THEME_OMP_THEME invalido ('$ompName'); se usa dracula"
        $ompName = 'dracula'
    }
    $themeDir = Join-DotfilesPath -Base $paths.Project -Child 'themes/oh-my-posh'
    if (-not (Test-Path -LiteralPath $themeDir)) { New-Item -ItemType Directory -Force -Path $themeDir | Out-Null }
    $omp = Join-Path $themeDir ("{0}.omp.json" -f $ompName)
    $localTheme = Join-DotfilesPath -Base $paths.RepoDir -Child ("config/oh-my-posh/{0}.omp.json" -f $ompName)
    if (-not (Test-Path -LiteralPath $localTheme) -and $ompName -ne 'dracula') {
        Write-UiWarn "tema de prompt '$ompName' no esta en el repo; se usa dracula"
        $ompName = 'dracula'
        $omp = Join-Path $themeDir 'dracula.omp.json'
        $localTheme = Join-DotfilesPath -Base $paths.RepoDir -Child 'config/oh-my-posh/dracula.omp.json'
    }
    # Se re-copia siempre desde el repo: es un asset gestionado y asi llegan las
    # correcciones del tema sin borrar nada a mano.
    if (Test-Path -LiteralPath $localTheme) {
        Copy-DotfilesTree -Source $localTheme -Destination $omp | Out-Null
    } elseif (-not (Test-Path -LiteralPath $omp)) {
        $poshThemes = $env:POSH_THEMES_PATH
        $url = $null
        if (@($app.Keys) -contains 'theme') { $url = $app['theme']['url'] }
        if ($poshThemes -and (Test-Path -LiteralPath (Join-Path $poshThemes ("{0}.omp.json" -f $ompName)))) {
            Copy-DotfilesTree -Source (Join-Path $poshThemes ("{0}.omp.json" -f $ompName)) -Destination $omp | Out-Null
        } elseif ($url -and $ompName -eq 'dracula') {
            $null = Invoke-DotfilesDownload -Uri $url -OutFile $omp -TimeoutSec 60
        }
    }
    if (-not (Test-Path -LiteralPath $omp)) {
        Write-UiWarn "No se pudo fijar el tema de oh-my-posh ($ompName)"
        exit 1
    }
    Write-UiStepLog "prompt: $ompName ($omp)"

    $body = @(
        "`$poshConfig = '$($omp.Replace("'", "''"))'",
        'if (Get-Command oh-my-posh -ErrorAction SilentlyContinue) {',
        '    oh-my-posh init pwsh --config $poshConfig | Invoke-Expression',
        '    # PSReadLine con la paleta del tema (los colores del prompt no',
        '    # dependen del esquema del terminal).',
        # Sin "Prompt": no es una propiedad de color de PSReadLine y hacia que
        # el perfil fallara al arrancar ('Prompt' is not a valid color property).
        # try/catch para que una clave no soportada por otra version no rompa la shell.
        "    if (`$env:THEME_GREEN) { try { Set-PSReadLineOption -Colors @{ Command = `$env:THEME_GREEN; Parameter = `$env:THEME_ORANGE; String = `$env:THEME_YELLOW; Comment = `$env:THEME_COMMENT } } catch { } }",
        '}'
    ) -join "`n"
    $r = Set-DotfilesProfileBlock -Kind 'posh' -Body $body
    if ($r.failed.Count -gt 0) {
        Write-UiWarn ("perfiles sin bloque de oh-my-posh: " + ($r.failed -join ', '))
    }
    "oh-my-posh listo (prompt $ompName)"
}

# --- 14. tema ---------------------------------------------------------------
$panel = Add-DotfilesPanelStep -Panel $panel -Title 'Tema (Dracula)' -Estimate 20 -Body {
    $script = Join-DotfilesPath -Base $env:REPO_DIR -Child 'scripts/apply-theme.ps1'
    $code = Invoke-DotfilesNativeQuoted -Argv @((Get-DotfilesSelfPwsh), '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script)
    if ($code -ne 0) {
        Write-UiWarn "apply-theme.ps1 termino con codigo $code"
        exit $code
    }
}

# --- 15. herdr --------------------------------------------------------------
$panel = Add-DotfilesPanelStep -Panel $panel -Title 'herdr' -Estimate 60 -Body {
    $paths = Get-DotfilesPaths
    if (-not (Test-DotfilesCommand 'herdr')) {
        $app = Get-DotfilesPackage -Key 'herdr' -Section 'apps'
        if (-not $app) {
            Write-UiWarn 'herdr no esta en el manifiesto de paquetes'
            exit 1
        }
        $r = Add-DotfilesApp -App $app
        if ($r.ok) { Write-UiStepLog "herdr: $($r.detail)" }
        else {
            Write-UiWarn "herdr no se instalo: $($r.detail)"
            exit 1
        }
    }
    foreach ($d in @((Join-Path $env:LOCALAPPDATA 'Programs\Herdr\bin'), $paths.BinDir, (Join-Path $env:APPDATA 'npm'))) {
        if (Test-Path -LiteralPath $d) { $null = Add-DotfilesEnvPath -Dir $d }
    }
    # herdr actualiza el PATH del registro por su cuenta: refrescar el propio
    # para poder verificarlo en este mismo proceso.
    Update-DotfilesSessionPath
    if (Test-DotfilesCommand 'herdr') {
        $v = & herdr --version 2>$null | Select-Object -First 1
        Write-UiOk "herdr $v"
    } else {
        Write-UiWarn 'herdr no encontrado en PATH; revisa %LOCALAPPDATA%\Programs\Herdr\bin'
    }
}

# --- 16. wrappers -----------------------------------------------------------
$panel = Add-DotfilesPanelStep -Panel $panel -Title 'Wrappers' -Estimate 15 -Body {
    $paths = Get-DotfilesPaths
    # El objeto de retorno se captura: si se deja en el pipeline, el panel pinta
    # una tabla de formato de PowerShell en mitad del paso.
    $w = Install-DotfilesSyncWrapper -Paths $paths
    if (-not (Test-Path -LiteralPath $w.ps1) -or -not (Test-Path -LiteralPath $w.cmd)) {
        Write-UiWarn 'faltan los wrappers sync-dotfiles.ps1 o sync-dotfiles.cmd'
        exit 1
    }
    "sync-dotfiles instalado en $($paths.BinDir)"
}

# --- 17. verificacion final --------------------------------------------------
$panel = Add-DotfilesPanelStep -Panel $panel -Title 'Verificacion final' -Optional -Estimate 30 -Body {
    $paths = Get-DotfilesPaths
    $failed = 0
    Update-DotfilesSessionPath

    function Test-BinPresent([string]$Label, [string]$Bin) {
        $cmd = Get-Command $Bin -CommandType Application, ExternalScript -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($cmd) {
            Write-UiStepLog "$Label OK ($($cmd.Source))"
        } else {
            Write-UiWarn "$Label no encontrado en PATH"
            $script:failedLocal++
        }
    }
    $script:failedLocal = 0
    Test-BinPresent 'OpenCode' 'opencode'
    Test-BinPresent 'herdr' 'herdr'
    Test-BinPresent 'Node' 'node'
    Test-BinPresent 'npm' 'npm'
    Test-BinPresent 'Neovim' 'nvim'
    Test-BinPresent 'git' 'git'
    Test-BinPresent 'nui' 'nui'

    $ver = Get-DotfilesNvimVersion
    if ($ver -and -not (Test-DotfilesSemverGt -Version $ver -Minimum '0.11.2')) {
        Write-UiWarn "Neovim $ver no supera la version requerida 0.11.2"
        $script:failedLocal++
    }

    Write-Output '##progress 60'

    # Bloques de perfil CON CONTENIDO: un bloque vacio (solo los marcadores)
    # pasaba el chequeo historico y daba falso positivo en maquina limpia.
    if (Test-DotfilesProfileEnv) {
        Write-UiStepLog 'Perfiles cargan env.ps1 (bloque con contenido)'
    } else {
        Write-UiWarn 'Bloques de arranque vacios/incompletos; relanza "Persistencia de entorno"'
        $script:failedLocal++
    }

    # Prueba funcional: un pwsh NUEVO, sin perfilar, debe ver los binarios solo
    # por el PATH de usuario del registro.
    $probe = @(
        (Get-DotfilesSelfPwsh), '-NoProfile', '-NonInteractive', '-Command',
        'if ($env:Path -split ";" | Where-Object { $_ -like "*enviroment-dotfiles*bin*" }) { exit 0 } exit 1'
    )
    $code = Invoke-DotfilesNative -Argv $probe -TimeoutSec 30
    if ($code -eq 0) {
        Write-UiStepLog 'El PATH de usuario persiste en una sesion nueva'
    } else {
        Write-UiWarn 'Una sesion nueva no ve el PATH persistido (abre otra terminal o revisa HKCU\Environment)'
        $script:failedLocal++
    }

    $doctor = Join-DotfilesPath -Base $paths.RepoDir -Child 'scripts/sync.ps1'
    if (Test-Path -LiteralPath $doctor) {
        Write-UiStepLog 'Ejecutando sync-dotfiles doctor'
        $log = New-DotfilesStepLog -Label 'doctor'
        $code = Invoke-DotfilesNativeLogged -Argv @((Get-DotfilesSelfPwsh), '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $doctor, 'doctor') -LogFile $log -TimeoutSec 90
        $text = ''
        if (Test-Path -LiteralPath $log) { $text = Get-DotfilesFileText -Path $log }
        foreach ($l in (($text -split "`n") | Select-Object -Last 20)) { if ($l) { Write-UiStepLog $l } }
        if ($code -eq 124) { Write-UiWarn "Doctor no termino a tiempo; revisa $log" }
        elseif ($code -ne 0) { Write-UiWarn "Doctor reporto avisos (exit $code); revisa $log" }
    } else {
        Write-UiWarn 'No se encontro scripts/sync.ps1 para el doctor'
    }

    Write-Output '##progress 100'
    if ($script:failedLocal -gt 0) {
        Write-UiWarn 'Hay herramientas pendientes; revisa los avisos del reporte'
        exit 1
    }
    'Verificacion final OK'
}

# --- 18. persistencia -------------------------------------------------------
$panel = Add-DotfilesPanelStep -Panel $panel -Title 'Persistencia de entorno' -Estimate 15 -Body {
    $paths = Get-DotfilesPaths
    $r = Install-DotfilesProfileEnv
    if ($r.failed.Count -gt 0) {
        Write-UiWarn ("no se pudo persistir en: " + ($r.failed -join ', '))
    } else {
        Write-UiStepLog "PATH persistido via env.ps1 en $($r.done.Count) perfil(es)"
    }
    # XDG_CONFIG_HOME hace que neovim (y otras herramientas) usen
    # ~/.config/nvim en lugar de %LOCALAPPDATA%\nvim: un unico arbol.
    [Environment]::SetEnvironmentVariable('XDG_CONFIG_HOME', $paths.ConfigRoot, 'User')
    $env:XDG_CONFIG_HOME = $paths.ConfigRoot
    Write-UiStepLog "XDG_CONFIG_HOME=$($paths.ConfigRoot)"
    foreach ($d in @($paths.BinDir)) { $null = Add-DotfilesEnvPath -Dir $d }
    'Entorno persistido'
}

# --- ejecucion --------------------------------------------------------------

$rc = 0
try {
    $rc = Invoke-DotfilesPanelRun -Panel $panel -Plain:$Plain -DryRun:$DryRun -NonInteractive:$NonInteractive -LogDir $Paths.LogDir
} catch {
    Write-UiError "la ejecucion fallo: $($_.Exception.Message)"
    Write-UiDim "Log: $($Paths.LogDir)"
    $rc = 1
} finally {
    $env:NUI_STATE_DIR = $null
}
exit $rc
