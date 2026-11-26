# Winget.Tests.ps1 - deteccion de winget por version.
#
# Regresion real: winget v1.29.380 imprime "v1.29.380" (con 'v') y el instalador
# exigia un digito inicial. En Windows 11 en espanol se reportaba "winget: NO
# disponible" teniendo winget perfectamente funcional: se perdia el gestor y
# python/node se quedaban en aviso.

BeforeAll {
    $RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
    $script:Sandbox = Join-Path ([IO.Path]::GetTempPath()) ('winget-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $script:Sandbox | Out-Null
    $env:DOTFILES_HOME = $script:Sandbox
    Import-Module (Join-Path $RepoRoot 'scripts/lib/dotfiles.psm1') -Force
    Import-Module (Join-Path $RepoRoot 'scripts/lib/ui.psm1') -Force
    Import-Module (Join-Path $RepoRoot 'scripts/lib/packages.psm1') -Force

    function New-WingetShim {
        param([string]$Output)
        if ($IsWindows) {
            $p = Join-Path $script:Sandbox ('winget-' + [guid]::NewGuid().ToString('N') + '.cmd')
            $lines = @('@echo off')
            if ($Output) { $lines += "echo $Output" }
            $lines += 'exit /b 0'
            Set-Content -LiteralPath $p -Value ($lines -join "`r`n") -Encoding ascii
            return $p
        }
        $p = Join-Path $script:Sandbox ('winget-' + [guid]::NewGuid().ToString('N') + '.sh')
        $body = if ($Output) { "#!/bin/sh`necho '$Output'`nexit 0`n" } else { "#!/bin/sh`nexit 0`n" }
        Set-Content -LiteralPath $p -Value $body -Encoding ascii
        chmod +x $p
        return $p
    }
}

AfterAll {
    Remove-Item env:WINGET_BIN -ErrorAction SilentlyContinue
    # Dejar el cache del modulo en el estado real, por si otro contenedor lo usa.
    $null = Test-DotfilesWinget -Force
    Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Test-DotfilesWingetVersion' {
    It 'acepta el prefijo v de las versiones nuevas' {
        Test-DotfilesWingetVersion -Version 'v1.29.380' | Should -BeTrue
        Test-DotfilesWingetVersion -Version 'v1.0' | Should -BeTrue
        Test-DotfilesWingetVersion -Version 'v10.2.3' | Should -BeTrue
    }

    It 'acepta versiones sin prefijo y con sufijo' {
        Test-DotfilesWingetVersion -Version '1.6.3482' | Should -BeTrue
        Test-DotfilesWingetVersion -Version '1.29.380-preview' | Should -BeTrue
        Test-DotfilesWingetVersion -Version '  v1.29.380  ' | Should -BeTrue
    }

    It 'rechaza versiones anteriores a 1.0, vacias o basura' {
        Test-DotfilesWingetVersion -Version 'v0.9.1' | Should -BeFalse
        Test-DotfilesWingetVersion -Version '0.3' | Should -BeFalse
        Test-DotfilesWingetVersion -Version '' | Should -BeFalse
        Test-DotfilesWingetVersion -Version $null | Should -BeFalse
        Test-DotfilesWingetVersion -Version 'basura' | Should -BeFalse
    }
}

Describe 'Test-DotfilesWinget' {
    BeforeEach { $script:PrevBin = $env:WINGET_BIN }
    AfterEach {
        $env:WINGET_BIN = $script:PrevBin
        $null = Test-DotfilesWinget -Force
    }

    It 'detecta winget con la salida real v1.29.380' {
        $env:WINGET_BIN = New-WingetShim -Output 'v1.29.380'
        (Test-DotfilesWinget -Force) | Should -BeTrue
        (Get-DotfilesWingetVersion) | Should -Be 'v1.29.380'
    }

    It 'detecta winget con una version sin prefijo' {
        $env:WINGET_BIN = New-WingetShim -Output '1.6.3482'
        (Test-DotfilesWinget -Force) | Should -BeTrue
        (Get-DotfilesWingetVersion) | Should -Be '1.6.3482'
    }

    It 'descarta un winget anterior a 1.0 (sin flags de user-scope)' {
        $env:WINGET_BIN = New-WingetShim -Output 'v0.9.1'
        (Test-DotfilesWinget -Force) | Should -BeFalse
        (Get-DotfilesWingetVersion) | Should -Be 'v0.9.1'
    }

    It 'si existe pero no imprime version, se intenta igualmente' {
        # Antes esto se trataba como "no disponible" y mandaba python/node al
        # fallback (que no tienen). Mejor intentarlo: si es viejo, fallara al
        # instalar y se usara el ZIP.
        $env:WINGET_BIN = New-WingetShim -Output ''
        (Test-DotfilesWinget -Force) | Should -BeTrue
        (Get-DotfilesWingetVersion) | Should -Be ''
    }
}
