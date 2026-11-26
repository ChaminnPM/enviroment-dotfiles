# Results.Tests.ps1 - forma de los resultados de los pasos y cwd del launcher.
#
# Regresion real en Windows 11: los pasos de Fuente (3), Windows Terminal (11) y
# Tema (14) morian con "No se encuentra la propiedad 'skipped'" porque
# Set-StrictMode 2.0 convierte en error fatal leer una propiedad inexistente, y
# varios returns no la traian. El paso de tema ademas abortaba el resto.

BeforeAll {
    $RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
    $script:Sandbox = Join-Path ([IO.Path]::GetTempPath()) ('res-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $script:Sandbox | Out-Null
    $env:DOTFILES_HOME = $script:Sandbox
    $env:DOTFILES_PLATFORM_OVERRIDE = 'windows'
    $env:DOTFILES_LOCALAPPDATA = Join-Path $script:Sandbox 'AppData/Local'
    $env:DOTFILES_APPDATA = Join-Path $script:Sandbox 'AppData/Roaming'
    New-Item -ItemType Directory -Force -Path $env:DOTFILES_LOCALAPPDATA | Out-Null
    New-Item -ItemType Directory -Force -Path $env:DOTFILES_APPDATA | Out-Null
    Import-Module (Join-Path $RepoRoot 'scripts/lib/dotfiles.psm1') -Force
    Import-Module (Join-Path $RepoRoot 'scripts/lib/ui.psm1') -Force
    Import-Module (Join-Path $RepoRoot 'scripts/lib/theme.psm1') -Force
    $script:Theme = Read-DotfilesTheme
    $script:P = Get-DotfilesPaths
}

AfterAll {
    Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item env:DOTFILES_HOME, env:DOTFILES_PLATFORM_OVERRIDE -ErrorAction SilentlyContinue
    Remove-Item env:DOTFILES_LOCALAPPDATA, env:DOTFILES_APPDATA -ErrorAction SilentlyContinue
}

Describe 'Test-DotfilesResultSkipped' {
    It 'acepta un objeto sin la propiedad (no omitido)' {
        (Test-DotfilesResultSkipped -Result ([pscustomobject]@{ ok = $false; detail = 'x' })) | Should -BeFalse
    }
    It 'respeta skipped = true/false' {
        (Test-DotfilesResultSkipped -Result ([pscustomobject]@{ skipped = $true })) | Should -BeTrue
        (Test-DotfilesResultSkipped -Result ([pscustomobject]@{ skipped = $false })) | Should -BeFalse
    }
    It '$null se considera omitido' {
        (Test-DotfilesResultSkipped -Result $null) | Should -BeTrue
    }
}

Describe 'Los resultados de pasos traen siempre skipped' {
    It 'Set-DotfilesWindowsTerminalTheme sin settings.json' {
        $r = Set-DotfilesWindowsTerminalTheme -Theme $script:Theme
        $r.PSObject.Properties.Name | Should -Contain 'skipped'
        (Test-DotfilesResultSkipped -Result $r) | Should -BeTrue
    }

    It 'Set-DotfilesWindowsTerminalTheme con JSON invalido' {
        # Es la rama que reventaba: devolvia ok/detail y el paso leia .skipped.
        $settings = $script:P.TerminalSettings
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $settings) | Out-Null
        Set-Content -LiteralPath $settings -Value '{ esto no es json'
        try {
            $r = Set-DotfilesWindowsTerminalTheme -Theme $script:Theme
            $r.PSObject.Properties.Name | Should -Contain 'skipped'
            $r.ok | Should -BeFalse
            (Test-DotfilesResultSkipped -Result $r) | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $settings -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Update-DotfilesNerdFont trae skipped (rama no-Windows)' {
        if ($IsWindows) { Set-ItResult -Skipped -Because 'en Windows descargaria la fuente'; return }
        $r = Update-DotfilesNerdFont -Theme $script:Theme
        $r.PSObject.Properties.Name | Should -Contain 'skipped'
        (Test-DotfilesResultSkipped -Result $r) | Should -BeTrue
    }
}

Describe 'Invoke-DotfilesNativeLogged -WorkingDirectory' {
    It 'el hijo arranca con el cwd indicado' {
        # Es lo que necesita npm: `npm install --prefix` sigue leyendo el
        # package.json del cwd y falla ENOENT si no hay ninguno.
        $dir = Join-Path $script:Sandbox 'proj'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $log = Join-Path $script:Sandbox 'cwd.log'
        $code = Invoke-DotfilesNativeLogged -LogFile $log `
            -Argv @((Get-DotfilesSelfPwsh), '-NoProfile', '-Command', '(Get-Location).Path') `
            -WorkingDirectory $dir
        $code | Should -Be 0
        (Get-DotfilesFileText -Path $log) | Should -BeLike "*$([IO.Path]::GetFileName($dir))*"
    }

    It 'sin WorkingDirectory no se toca el cwd' {
        $log = Join-Path $script:Sandbox 'cwd2.log'
        $code = Invoke-DotfilesNativeLogged -LogFile $log `
            -Argv @((Get-DotfilesSelfPwsh), '-NoProfile', '-Command', '(Get-Location).Path')
        $code | Should -Be 0
        (Get-DotfilesFileText -Path $log) | Should -Not -BeNullOrEmpty
    }
}
