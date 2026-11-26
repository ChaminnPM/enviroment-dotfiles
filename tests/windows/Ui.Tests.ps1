# Ui.Tests.ps1 - instalacion de nui y ejecucion con log/spinner.
#
# Usa el repo local como origen del binario: no depende de la red.

BeforeAll {
    $RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
    $script:RepoRoot = $RepoRoot
    $script:Sandbox = Join-Path ([IO.Path]::GetTempPath()) ('ui-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $script:Sandbox | Out-Null
    $env:DOTFILES_HOME = $script:Sandbox
    $env:REPO_DIR = $RepoRoot
    Import-Module (Join-Path $RepoRoot 'scripts/lib/dotfiles.psm1') -Force
    Import-Module (Join-Path $RepoRoot 'scripts/lib/ui.psm1') -Force
    $script:WantVersion = (Get-Content -LiteralPath (Join-Path $RepoRoot 'bin/VERSION') -Raw).Trim()
}

AfterAll {
    Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item env:DOTFILES_HOME, env:REPO_DIR, env:UI_BIN -ErrorAction SilentlyContinue
    Remove-Item env:LOG_KEEP_LINES, env:LOG_KEEP_ALL -ErrorAction SilentlyContinue
}

Describe 'Add-DotfilesUi' {
    It 'instala nui desde el repo local con la version pinneada' {
        $bin = Add-DotfilesUi -Force
        $bin | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $bin | Should -BeTrue
        (Get-DotfilesUiVersion -Bin $bin) | Should -Be $script:WantVersion
    }

    It 'es idempotente cuando la version ya coincide' {
        $before = Add-DotfilesUi -Force
        $t1 = (Get-Item -LiteralPath $before).LastWriteTimeUtc
        Start-Sleep -Milliseconds 1200
        $again = Add-DotfilesUi
        $again | Should -Be $before
        # no se reescribe: misma marca de tiempo
        (Get-Item -LiteralPath $before).LastWriteTimeUtc - $t1 | Should -BeLessThan ([TimeSpan]::FromSeconds(1))
    }

    It 'rechaza un binario cuyo checksum no coincide' {
        # Se monta un repo FALSO en el sandbox: el test corrompe sus propias
        # copias y no toca nunca bin/SHA256SUMS versionado.
        $fake = Join-Path $script:Sandbox 'fake-repo'
        New-Item -ItemType Directory -Force -Path (Join-Path $fake 'bin') | Out-Null
        $gzName = (Get-DotfilesUiBinaryName) + '.gz'
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot "bin/$gzName") -Destination (Join-Path $fake "bin/$gzName") -Force
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'bin/VERSION') -Destination (Join-Path $fake 'bin/VERSION') -Force
        $lines = @(Get-Content -LiteralPath (Join-Path $script:RepoRoot 'bin/SHA256SUMS')) | ForEach-Object {
            $_ -replace '^[0-9a-f]{64}', ('0' * 64)
        }
        Set-Content -LiteralPath (Join-Path $fake 'bin/SHA256SUMS') -Value $lines

        $prev = $env:REPO_DIR
        try {
            $env:REPO_DIR = $fake
            $r = Add-DotfilesUi -Force 2>$null
            $r | Should -BeNullOrEmpty -Because 'un checksum invalido no debe instalar el binario'
        } finally {
            $env:REPO_DIR = $prev
        }
    }

    It 'Get-DotfilesChecksumFor lee la entrada del binario concreto' {
        $name = Get-DotfilesUiBinaryName
        $h = Get-DotfilesChecksumFor -SumsFile (Join-Path $script:RepoRoot 'bin/SHA256SUMS') -Name $name
        $h | Should -Match '^[0-9a-f]{64}$'
        Get-DotfilesChecksumFor -SumsFile (Join-Path $script:RepoRoot 'bin/SHA256SUMS') -Name 'nui-inexistente' |
            Should -BeNullOrEmpty
    }

    It 'el nui instalado soporta el subcomando steps' {
        $v = Get-DotfilesUiVersion
        $v | Should -Not -BeNullOrEmpty
        Test-DotfilesUiSupportsSteps -Version $v | Should -BeTrue
        # versiones antiguas explicitas: sin `steps run` no hay panel
        Test-DotfilesUiSupportsSteps -Version '0.1.9' | Should -BeFalse
        Test-DotfilesUiSupportsSteps -Version '0.0.0' | Should -BeFalse
        Test-DotfilesUiSupportsSteps -Version 'basura' | Should -BeFalse
        # sin version explicita se pregunta al binario instalado (comportamiento
        # documentado: bootstrap usa esto para decidir panel vs texto)
        Test-DotfilesUiSupportsSteps | Should -BeTrue
    }
}

Describe 'Invoke-DotfilesLoggedArgv' {
    BeforeAll {
        $script:P = Get-DotfilesPaths
        Initialize-DotfilesUi -Paths $script:P
    }

    It 'devuelve el codigo real y deja el log' {
        $cmd = if ($IsWindows) { 'cmd.exe' } else { '/bin/sh' }
        $argv = if ($IsWindows) { @($cmd, '/c', 'exit 3') } else { @($cmd, '-c', 'echo hola; exit 3') }
        $code = Invoke-DotfilesLoggedArgv -Title 'prueba' -Argv $argv 2>$null
        $code | Should -Be 3
        $log = Get-DotfilesLastLog
        $log | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $log | Should -BeTrue
        (Get-DotfilesFileText -Path $log) | Should -BeLike '*hola*'
    }

    It 'recorta el log a LOG_KEEP_LINES' {
        $env:LOG_KEEP_LINES = '20'
        $cmd = if ($IsWindows) { 'cmd.exe' } else { '/bin/sh' }
        $argv = if ($IsWindows) { @($cmd, '/c', 'echo x') } else { @($cmd, '-c', 'for i in $(seq 1 40); do echo linea; done') }
        $null = Invoke-DotfilesLoggedArgv -Title 'largo' -Argv $argv 2>$null
        $log = Get-DotfilesLastLog
        # LOG_KEEP_LINES=20 deja como mucho 20 lineas en el log
        @([System.IO.File]::ReadAllLines($log)).Count | Should -BeLessOrEqual 20
        Remove-Item env:LOG_KEEP_LINES
    }
}

Describe 'Mensajes y directivas' {
    It 'dentro de un paso emite directivas, fuera no' {
        $env:NUI_PANEL = '1'
        $out = Write-DotfilesMessage -Level info -Text 'dentro'
        $out | Should -Be '##log dentro'
        $warnOut = Write-DotfilesMessage -Level warn -Text 'aviso'
        $warnOut | Should -Be '##warn aviso'
        Remove-Item env:NUI_PANEL
        $null = Write-DotfilesMessage -Level info -Text 'fuera' 6>$null
    }

    It 'Write-UiWarn alimenta el reporte final' {
        Clear-DotfilesReport
        $null = Write-UiWarn 'algo raro' 6>$null
        $r = Get-DotfilesReport
        $r.warn | Should -Contain 'algo raro'
        $r.err.Count | Should -Be 0
    }
}
