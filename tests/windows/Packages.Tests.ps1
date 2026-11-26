# Packages.Tests.ps1 - instalacion de paquetes: winget "ya instalado" y fallback.
#
# Regresion real (Windows 11): cada relanzamiento intentaba reinstalar lo que
# winget ya tenia y winget responde "No available upgrade found" con codigo != 0;
# el codigo se tomaba como fallo, se caia al ZIP y Add-DotfilesUserBin reventaba
# con "No se puede recuperar la variable $found", abortando 'Paquetes custom'.

BeforeAll {
    $RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
    $script:RepoRoot = $RepoRoot
    $script:Sandbox = Join-Path ([IO.Path]::GetTempPath()) ('pkg-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $script:Sandbox | Out-Null
    $env:DOTFILES_HOME = $script:Sandbox
    $env:DOTFILES_PLATFORM_OVERRIDE = 'windows'
    $env:DOTFILES_LOCALAPPDATA = Join-Path $script:Sandbox 'AppData/Local'
    $env:DOTFILES_APPDATA = Join-Path $script:Sandbox 'AppData/Roaming'
    New-Item -ItemType Directory -Force -Path $env:DOTFILES_LOCALAPPDATA | Out-Null
    New-Item -ItemType Directory -Force -Path $env:DOTFILES_APPDATA | Out-Null
    Import-Module (Join-Path $RepoRoot 'scripts/lib/dotfiles.psm1') -Force
    Import-Module (Join-Path $RepoRoot 'scripts/lib/ui.psm1') -Force
    Import-Module (Join-Path $RepoRoot 'scripts/lib/packages.psm1') -Force

    function New-WingetFailShim {
        # --version responde una version valida; cualquier instalacion sale con
        # != 0, como cuando no hay actualizacion que aplicar.
        if ($IsWindows) {
            $p = Join-Path $script:Sandbox ('wingetfail-' + [guid]::NewGuid().ToString('N') + '.cmd')
            $body = @(
                '@echo off',
                'if "%1"=="--version" (echo v1.29.380 & exit /b 0)',
                'echo No available upgrade found.',
                'exit /b 9'
            ) -join "`r`n"
            Set-Content -LiteralPath $p -Value $body -Encoding ascii
            return $p
        }
        $p = Join-Path $script:Sandbox ('wingetfail-' + [guid]::NewGuid().ToString('N') + '.sh')
        $body = "#!/bin/sh`nif [ `"`$1`" = '--version' ]; then echo v1.29.380; exit 0; fi`necho 'No available upgrade found.'`nexit 9`n"
        Set-Content -LiteralPath $p -Value $body -Encoding ascii
        chmod +x $p
        return $p
    }
}

AfterAll {
    Remove-Item env:WINGET_BIN -ErrorAction SilentlyContinue
    Remove-Item env:DOTFILES_HOME, env:DOTFILES_PLATFORM_OVERRIDE -ErrorAction SilentlyContinue
    Remove-Item env:DOTFILES_LOCALAPPDATA, env:DOTFILES_APPDATA -ErrorAction SilentlyContinue
    $null = Test-DotfilesWinget -Force
    Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Add-DotfilesPackage con winget en "sin actualizacion"' {
    BeforeEach { $script:PrevBin = $env:WINGET_BIN }
    AfterEach {
        $env:WINGET_BIN = $script:PrevBin
        $null = Test-DotfilesWinget -Force
    }

    It 'no reinstala ni cae al ZIP si el comando ya existe' {
        $env:WINGET_BIN = New-WingetFailShim
        $null = Test-DotfilesWinget -Force
        # 'pwsh' existe seguro: es el proceso que corre el test.
        $pkg = @{ key = 'pwsh'; id = 'Microsoft.PowerShell'; command = 'pwsh' }
        $r = Add-DotfilesPackage -Package $pkg
        $r.ok | Should -BeTrue
        $r.detail | Should -BeLike '*ya estaba instalado*'
    }

    It 'un fallback roto devuelve ok=false en vez de lanzar' {
        $env:WINGET_BIN = New-WingetFailShim
        $null = Test-DotfilesWinget -Force
        # zip local valido pero sin el binario esperado.
        $zip = Join-Path $script:Sandbox 'vacio.zip'
        $tmp = Join-Path $script:Sandbox 'zipin'
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        Set-Content -LiteralPath (Join-Path $tmp 'otro.txt') -Value 'x'
        if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
        Compress-Archive -Path (Join-Path $tmp '*') -DestinationPath $zip -Force
        $pkg = @{
            key      = 'dfnope'
            id       = 'Example.NoExiste'
            command  = 'dfnope'
            fallback = @{ name = 'dfnope'; url = ([Uri]$zip).AbsoluteUri; inner = '' }
        }
        $r = Add-DotfilesPackage -Package $pkg
        $r.ok | Should -BeFalse
        $r.detail | Should -BeLike '*fallback*'
    }
}

Describe 'Test-DotfilesPackageInstalled' {
    It 've los shims de winget aunque el PATH de la sesion no los tenga' {
        $paths = Get-DotfilesPaths
        New-Item -ItemType Directory -Force -Path $paths.WingetLinks | Out-Null
        $name = if ($IsWindows) { 'dfwgt.exe' } else { 'dfwgt' }
        Set-Content -LiteralPath (Join-Path $paths.WingetLinks $name) -Value 'x'
        # El PATH real no contiene ese directorio: solo se encuentra por el atajo.
        (Test-DotfilesPackageInstalled -Package @{ command = 'dfwgt' }) | Should -BeTrue
    }
}

Describe 'Find-DotfilesWingetTool' {
    It 'encuentra un portable dentro de WinGet\Packages aunque no haya shim' {
        # Caso real: WinGet\Links vacio y fzf.exe en Packages\<id>\.
        $paths = Get-DotfilesPaths
        $pkgDir = Join-Path $paths.LocalAppData 'Microsoft/WinGet/Packages/proveedor.dfpack_8wekyb'
        New-Item -ItemType Directory -Force -Path $pkgDir | Out-Null
        $tool = Join-Path $pkgDir 'dfpack.exe'
        Set-Content -LiteralPath $tool -Value 'x'
        (Find-DotfilesWingetTool -Name 'dfpack') | Should -Be $tool
        (Test-DotfilesPackageInstalled -Package @{ command = 'dfpack' }) | Should -BeTrue
    }

    It 'encuentra el shim de WinGet\Links' {
        $paths = Get-DotfilesPaths
        New-Item -ItemType Directory -Force -Path $paths.WingetLinks | Out-Null
        $shim = Join-Path $paths.WingetLinks 'dfshim.exe'
        Set-Content -LiteralPath $shim -Value 'x'
        (Find-DotfilesWingetTool -Name 'dfshim') | Should -Be $shim
    }

    It 'devuelve null si no esta en ningun sitio' {
        (Find-DotfilesWingetTool -Name 'dfnoexiste123') | Should -BeNullOrEmpty
        (Test-DotfilesPackageInstalled -Package @{ command = 'dfnoexiste123' }) | Should -BeFalse
    }
}

Describe 'Update-DotfilesSessionPath' {
    It 'en Windows anade los shims de winget si faltan' -Skip:(-not $IsWindows) {
        $paths = Get-DotfilesPaths
        New-Item -ItemType Directory -Force -Path $paths.WingetLinks | Out-Null
        $prev = $env:Path
        try {
            $env:Path = 'C:\Windows'
            $out = Update-DotfilesSessionPath
            $out | Should -BeLike "*$($paths.WingetLinks)*"
        } finally {
            $env:Path = $prev
        }
    }
}
