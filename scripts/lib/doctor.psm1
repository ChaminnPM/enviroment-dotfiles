# doctor.psm1 - verificacion de salud del entorno publico en Windows nativo.
#
# Es el equivalente del bloque `doctor` de scripts/sync.sh, con las
# comprobaciones propias de Windows (ACLs, registro de fuentes, bloques de
# perfil, PATH de usuario). NO modifica nada: solo informa.
#
# Salidas:
#   [OK]   algo correcto
#   [WARN] accion requerida del usuario (relanzar bootstrap, iniciar servicio)
# Devuelve el numero de avisos; sync.ps1 sale con 1 si hay alguno.

Set-StrictMode -Version 2.0

if (-not (Get-Command Get-DotfilesPaths -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot 'dotfiles.psm1') -Force -ErrorAction Stop
}
if (-not (Get-Command Get-DotfilesUiVersion -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot 'ui.psm1') -Force -ErrorAction Stop
}
if (-not (Get-Command Get-DotfilesPackageList -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot 'packages.psm1') -Force -ErrorAction Stop
}
if (-not (Get-Command Read-DotfilesTheme -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot 'theme.psm1') -Force -ErrorAction Stop
}

$script:Ok = 0
$script:Warn = 0

function Reset-DotfilesDoctorCounters {
    $script:Ok = 0
    $script:Warn = 0
}

function Get-DotfilesDoctorResult {
    return [pscustomobject]@{ ok = $script:Ok; warn = $script:Warn }
}

function Write-DoctorOk {
    param([Parameter(Mandatory)][string]$Text)
    $script:Ok++
    Write-Host "[OK]   $Text" -ForegroundColor Green
}

function Write-DoctorWarn {
    param([Parameter(Mandatory)][string]$Text)
    $script:Warn++
    Write-Host "[WARN] $Text" -ForegroundColor Yellow
}

function Test-DoctorCommand {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Hint
    )
    if (Get-Command $Name -CommandType Application, ExternalScript -ErrorAction SilentlyContinue) {
        Write-DoctorOk "$Name instalado"
        return $true
    }
    $suffix = if ($Hint) { " ($Hint)" } else { '' }
    Write-DoctorWarn "$Name NO instalado$suffix"
    return $false
}

function Invoke-DotfilesDoctor {
    param(
        [hashtable]$Paths,
        [string]$RepoDir,
        [string]$OpenCodeDir,
        [hashtable]$Theme
    )

    Reset-DotfilesDoctorCounters
    if (-not $Paths) { $Paths = Get-DotfilesPaths }
    if (-not $RepoDir) { $RepoDir = $Paths.RepoDir }
    if (-not $OpenCodeDir) { $OpenCodeDir = $Paths.OpenCodeDir }
    if (-not $Theme) { $Theme = Read-DotfilesTheme }

    $pinNui = ''
    $vf = Join-DotfilesPath -Base $RepoDir -Child 'bin/VERSION'
    if (Test-Path -LiteralPath $vf) { $pinNui = (Get-Content -LiteralPath $vf -Raw).Trim() }

    Write-Host ("Doctor publico (Windows, nui {0}, tema {1}):" -f $(if ($pinNui) { $pinNui } else { '?' }), $Theme.THEME_NAME)

    # --- utilidades base ----------------------------------------------------
    foreach ($c in @(
            @{ n = 'git'; h = 'bootstrap.ps1 -Only "Dependencias base"' },
            @{ n = 'curl.exe'; h = 'viene con Windows 10 1803+' },
            @{ n = 'tar.exe'; h = 'viene con Windows 10 1803+' },
            @{ n = 'python'; h = 'graphify lo necesita' },
            @{ n = 'ssh'; h = 'caracteristica OpenSSH Client' },
            @{ n = 'icacls.exe'; h = 'viene con Windows' }
        )) {
        $null = Test-DoctorCommand -Name $c.n -Hint $c.h
    }

    if (Test-DotfilesWinget) {
        $wv = Get-DotfilesWingetVersion
        if ($wv) { Write-DoctorOk "winget disponible ($wv)" }
        else { Write-DoctorOk 'winget disponible (version desconocida)' }
    } else {
        Write-DoctorWarn 'winget no disponible; los fallbacks pinnados son la unica via'
        Write-DoctorWarn 'si "winget --version" funciona, actualiza el repo (acepta el prefijo "v" de las versiones nuevas)'
    }

    # --- node / npm ---------------------------------------------------------
    $manager = $env:DOTFILES_NODE_MANAGER
    if (-not $manager) { $manager = 'fnm' }
    if (Test-DoctorCommand -Name 'node' -Hint 'relanza bootstrap.ps1') {
        Write-DoctorOk "node $(& node --version 2>$null | Select-Object -First 1)"
    }
    $null = Test-DoctorCommand -Name 'npm' -Hint 'necesario para OpenCode y los plugins'

    if ($manager -eq 'fnm') {
        if (Get-Command 'fnm' -CommandType Application -ErrorAction SilentlyContinue) {
            $cur = & fnm --version 2>$null | Select-Object -First 1
            $want = if ($env:FNM_VERSION) { ($env:FNM_VERSION -replace '^v', '') } else { '1.38.1' }
            if ("$cur" -eq $want) { Write-DoctorOk "fnm $cur (pin)" }
            else { Write-DoctorWarn "fnm $cur; relanza 'Actualizar gestor de Node'" }
            $nodeDir = Get-DotfilesFnmNodeDir
            if ($nodeDir) { Write-DoctorOk "fnm node dir: $nodeDir" }
            else { Write-DoctorWarn 'fnm no tiene todavia un node activo (fnm install --lts)' }
        } else {
            Write-DoctorWarn 'fnm no instalado (Node manager elegido: fnm)'
        }
    }

    # --- herramientas instaladas por el bootstrap ---------------------------
    foreach ($c in @(
            @{ n = 'opencode'; h = 'paso OpenCode' },
            @{ n = 'herdr'; h = 'paso herdr' },
            @{ n = 'oh-my-posh'; h = 'paso oh-my-posh' }
        )) {
        $null = Test-DoctorCommand -Name $c.n -Hint $c.h
    }

    $nvimVer = Get-DotfilesNvimVersion
    if ($nvimVer) {
        if (Test-DotfilesSemverGt -Version $nvimVer -Minimum '0.11.2') {
            Write-DoctorOk "nvim $nvimVer (> 0.11.2)"
        } else {
            Write-DoctorWarn "nvim $nvimVer no supera 0.11.2 (LazyVim/treesitter fallaran)"
        }
    } else {
        Write-DoctorWarn 'nvim no instalado o sin LazyVim'
    }

    if (Get-DotfilesCC) { Write-DoctorOk 'compilador C disponible' }
    else { Write-DoctorWarn 'sin compilador C: los plugins nativos de LazyVim no compilaran' }

    # --- nui ----------------------------------------------------------------
    $uiBin = Get-DotfilesUiBin
    if ($uiBin) {
        $have = Get-DotfilesUiVersion -Bin $uiBin
        if ($have -eq $pinNui) { Write-DoctorOk "nui $have (pin)" }
        else { Write-DoctorWarn "nui ${have} (pin $pinNui); se actualiza al proximo bootstrap.ps1" }
    } else {
        Write-DoctorWarn 'nui no instalado (la UI usara el runner textual)'
    }

    # --- persistencia de entorno --------------------------------------------
    if (Test-Path -LiteralPath $Paths.EnvFile) {
        Write-DoctorOk "env.ps1 presente ($($Paths.EnvFile))"
    } else {
        Write-DoctorWarn "sin $($Paths.EnvFile) (relanza bootstrap.ps1)"
    }

    $profiles = Get-DotfilesProfilePaths
    foreach ($pf in $profiles) {
        if (-not (Test-Path -LiteralPath $pf -PathType Leaf)) { continue }
        if (Test-DotfilesProfileEnv -Profiles @($pf)) {
            Write-DoctorOk "$pf carga env.ps1"
        } else {
            Write-DoctorWarn "$pf sin bloque dotfiles-env efectivo (relanza 'Persistencia de entorno')"
        }
        $themeHdr = Get-DotfilesBlockHeader -Kind 'theme'
        $themeFtr = Get-DotfilesBlockFooter -Kind 'theme'
        if (Test-DotfilesManagedBlock -Path $pf -Header $themeHdr -Footer $themeFtr -MustContain 'BAT_THEME') {
            Write-DoctorOk "$pf con paleta de tema"
        } else {
            Write-DoctorWarn "$pf sin bloque de tema (relanza scripts/apply-theme.ps1)"
        }
    }

    # PATH de usuario: el env.ps1 sirve para la shell, pero el registro es lo
    # que hace que una terminal NUEVA vea los binarios.
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ("$userPath" -like "*enviroment-dotfiles*bin*") {
        Write-DoctorOk 'PATH de usuario incluye el bin del proyecto'
    } else {
        Write-DoctorWarn 'El PATH de usuario no incluye el bin del proyecto (abre otra terminal o relanza Persistencia de entorno)'
    }

    # --- assets publicos ----------------------------------------------------
    foreach ($rel in Get-DotfilesPublicPathList) {
        $p = Join-Path $OpenCodeDir $rel
        if (Test-Path -LiteralPath $p) { Write-DoctorOk "asset $rel" }
        else { Write-DoctorWarn "falta asset $rel (sync-dotfiles pull)" }
    }

    # --- skills externas ----------------------------------------------------
    foreach ($s in @('graphify', 'security-audit')) {
        $repoV = Join-Path $RepoDir "config/opencode/skills/$s/VERSION.json"
        $instV = Join-Path $OpenCodeDir "skills/$s/VERSION.json"
        if (-not (Test-Path -LiteralPath $repoV)) {
            Write-DoctorWarn "skill $s sin VERSION.json en el repo"
            continue
        }
        $want = (Read-DotfilesJson -Path $repoV).upstream_ref
        $have = ''
        if (Test-Path -LiteralPath $instV) { $have = (Read-DotfilesJson -Path $instV).upstream_ref }
        if ($want -eq $have) { Write-DoctorOk "skill $s ($want)" }
        else { Write-DoctorWarn "skill $s instalada $have, repo $want; sync-dotfiles pull la actualiza" }
    }

    # --- tema y fuente ------------------------------------------------------
    if (Test-DotfilesNerdFontInstalled -Theme $Theme) {
        Write-DoctorOk "fuente $($Theme.THEME_FONT_FAMILY) registrada"
    } elseif (Test-DotfilesNerdFontFilesPresent -Theme $Theme) {
        Write-DoctorWarn "la fuente esta en disco pero no en el registro; relanza el paso de fuente"
    } else {
        Write-DoctorWarn "fuente $($Theme.THEME_FONT_FAMILY) NO instalada (relanza bootstrap.ps1)"
    }

    if (Test-Path -LiteralPath $Paths.ThemeManifest) {
        $m = Read-DotfilesJson -Path $Paths.ThemeManifest
        if ($m.nerd_version -eq $Theme.THEME_NERD_VERSION) {
            Write-DoctorOk "tema $($m.theme) / Nerd Font $($m.nerd_version) (pin)"
        } else {
            Write-DoctorWarn "tema instalado $($m.nerd_version) (pin $($Theme.THEME_NERD_VERSION)); relanza bootstrap.ps1"
        }
    } else {
        Write-DoctorWarn "sin $($Paths.ThemeManifest) (relanza bootstrap.ps1)"
    }

    $cliJson = Join-Path $OpenCodeDir 'cli.json'
    if (Test-Path -LiteralPath $cliJson) {
        $name = (Read-DotfilesJson -Path $cliJson).theme.name
        if ($name -eq $Theme.THEME_NAME) { Write-DoctorOk "OpenCode theme=$name" }
        else { Write-DoctorWarn "OpenCode theme=$name, esperado $($Theme.THEME_NAME)" }
    }

    # --- Windows Terminal ---------------------------------------------------
    $wt = $Paths.TerminalSettings
    if ($wt -and (Test-Path -LiteralPath $wt -PathType Leaf)) {
        $txt = Get-DotfilesFileText -Path $wt
        if ($txt -match '"Dracula"') { Write-DoctorOk "Windows Terminal con esquema Dracula" }
        else { Write-DoctorWarn "$wt sin esquema Dracula (relanza 'Windows Terminal (tema)')" }
    } else {
        Write-DoctorWarn 'Windows Terminal no instalado o sin settings.json'
    }

    # --- SSH y cuentas git --------------------------------------------------
    $personalKey = Join-Path $Paths.SshDir 'id_ed25519_personal'
    if (Test-Path -LiteralPath $personalKey -PathType Leaf) {
        Write-DoctorOk 'clave SSH personal presente'
        if (Test-DotfilesPrivateAcl -Path $personalKey) {
            Write-DoctorOk 'clave personal con ACL privada'
        } else {
            Write-DoctorWarn 'clave personal con ACL abierta (OpenSSH la rechazara)'
        }
    } else {
        Write-DoctorWarn "sin $personalKey (relanza el paso de identidad Git)"
    }

    $sshConfig = Join-Path $Paths.SshDir 'config'
    if (Test-Path -LiteralPath $sshConfig -PathType Leaf) {
        $h = '# >>> dotfiles-managed (setup-git-identity.ps1) - no editar entre los marcadores'
        $f = '# <<< dotfiles-managed'
        if (Test-DotfilesManagedBlock -Path $sshConfig -Header $h -Footer $f) {
            Write-DoctorOk 'seccion SSH gestionada presente'
        } else {
            Write-DoctorWarn "$sshConfig sin seccion gestionada (o bloque incompleto)"
        }
        if (Test-DotfilesPrivateAcl -Path $sshConfig) { Write-DoctorOk "$sshConfig ACL correcta" }
        else { Write-DoctorWarn "$sshConfig con ACL abierta" }
    } else {
        Write-DoctorWarn 'sin ~/.ssh/config'
    }

    $knownHosts = Join-Path $Paths.SshDir 'known_hosts'
    if (Test-Path -LiteralPath $knownHosts -PathType Leaf) {
        $kh = Get-DotfilesFileText -Path $knownHosts
        if ($kh -match 'github.com' -and $kh -match 'bitbucket') {
            Write-DoctorOk 'known_hosts con GitHub y Bitbucket pinnados'
        } else {
            Write-DoctorWarn 'known_hosts sin las host keys pinnadas del repo'
        }
    } else {
        Write-DoctorWarn 'sin ~/.ssh/known_hosts (relanza bootstrap.ps1)'
    }

    if (Test-Path -LiteralPath $Paths.AccountsFile -PathType Leaf) {
        $acc = Read-DotfilesJson -Path $Paths.AccountsFile -AsHashtable
        Write-DoctorOk "manifiesto de cuentas git (personal: $($acc['personal']['platform']))"
        foreach ($s in @($acc['spaces'])) {
            if (-not $s) { continue }
            $esp = $s['espacio']
            if (Test-Path -LiteralPath $s['key'] -PathType Leaf) {
                Write-DoctorOk "clave $esp presente"
                if (Test-DotfilesPrivateAcl -Path $s['key']) { Write-DoctorOk "clave $esp ACL privada" }
                else { Write-DoctorWarn "clave $esp con ACL abierta" }
            } else {
                Write-DoctorWarn "sin clave para el espacio $esp"
            }
            if (Test-Path -LiteralPath $s['folder'] -PathType Container) {
                Write-DoctorOk "carpeta $($s['folder']) presente"
            } else {
                Write-DoctorWarn "carpeta $($s['folder']) no existe"
            }
            if (Test-Path -LiteralPath $Paths.GitConfig -PathType Leaf) {
                $gc = Get-DotfilesFileText -Path $Paths.GitConfig
                if ($gc -match [regex]::Escape($s['gitdir'])) {
                    Write-DoctorOk "includeIf de $esp activo"
                } else {
                    Write-DoctorWarn "sin includeIf para $esp en ~/.gitconfig"
                }
            }
        }
    } else {
        Write-DoctorWarn "sin $($Paths.AccountsFile) (relanza bootstrap.ps1 para configurar cuentas)"
    }

    if (Test-Path -LiteralPath $Paths.GitConfig -PathType Leaf) {
        $gc = Get-DotfilesFileText -Path $Paths.GitConfig
        if ($gc -match '>>> dotfiles-gitconfig') {
            Write-DoctorOk '~/.gitconfig usa bloque gestionado'
        } else {
            Write-DoctorWarn '~/.gitconfig sin bloque gestionado (config del usuario intacta)'
        }
    }

    # --- wrapper -------------------------------------------------------------
    $wrap = Join-Path $Paths.BinDir 'sync-dotfiles.cmd'
    if (Test-Path -LiteralPath $wrap -PathType Leaf) {
        Write-DoctorOk 'sync-dotfiles instalado'
    } else {
        Write-DoctorWarn 'sync-dotfiles no instalado (relanza el paso "Wrappers")'
    }

    Write-Host "Resumen: $($script:Ok) OK, $($script:Warn) avisos"
    return $script:Warn
}

Export-ModuleMember -Function *
