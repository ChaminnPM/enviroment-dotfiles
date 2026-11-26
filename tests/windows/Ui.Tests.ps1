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
        # cmd.exe necesita el echo DENTRO del comando: con `/c exit 3` no habria
        # nada que loguear y la comprobacion del log seria falsa.
        $argv = if ($IsWindows) { @($cmd, '/c', 'echo hola & exit 3') } else { @($cmd, '-c', 'echo hola; exit 3') }
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

Describe 'Invoke-DotfilesPanelRun -Plain' {
    BeforeAll {
        $script:PlainLog = Join-Path $script:Sandbox 'plain-logs'
        New-Item -ItemType Directory -Force -Path $script:PlainLog | Out-Null
    }

    It 'ejecuta los pasos en texto y devuelve 0' {
        $p = New-DotfilesPanel -Title 'plain'
        $p = Add-DotfilesPanelStep -Panel $p -Title 'Paso texto' -Body {
            Write-DotfilesMessage -Level info -Text 'hola-plain'
        }
        $all = @(Invoke-DotfilesPanelRun -Panel $p -Plain -LogDir $script:PlainLog 6>&1)
        $rc = $all[-1]
        $text = (@($all | Select-Object -SkipLast 1) | ForEach-Object { "$_" }) -join "`n"
        $rc | Should -Be 0
        $text | Should -BeLike '*Paso texto*'
        $text | Should -BeLike '*hola-plain*'
        $text | Should -BeLike '*REPORTE FINAL*'
    }

    It 'devuelve 1 cuando un paso obligatorio falla' {
        $p = New-DotfilesPanel -Title 'plain-fail'
        $p = Add-DotfilesPanelStep -Panel $p -Title 'Falla' -Body { exit 7 }
        $rc = Invoke-DotfilesPanelRun -Panel $p -Plain -LogDir $script:PlainLog 6>$null
        $rc | Should -Be 1
        (Get-DotfilesReport).err.Count | Should -BeGreaterThan 0
    }

    It 'un paso opcional que falla no aborta el resto' {
        $p = New-DotfilesPanel -Title 'plain-opt'
        $p = Add-DotfilesPanelStep -Panel $p -Title 'Opcional' -Optional -Body { exit 5 }
        $p = Add-DotfilesPanelStep -Panel $p -Title 'Siguiente' -Body { Write-Output 'sigo' }
        $rc = Invoke-DotfilesPanelRun -Panel $p -Plain -LogDir $script:PlainLog 6>$null
        $rc | Should -Be 0
        (Get-DotfilesReport).ok | Should -Contain 'Siguiente'
    }

    It 'con -NonInteractive aplica los defaults y escribe el result file' {
        $env:NUI_NONINTERACTIVE = '1'
        try {
            $p = New-DotfilesPanel -Title 'plain-inputs'
            $p = Add-DotfilesPanelInput -Panel $p -Type input -Name 'extras' -Prompt 'Extras' -Default 'sin-extras'
            $p = Add-DotfilesPanelStep -Panel $p -Title 'Usa default' -Body {
                Write-Output "extras=$extras"
            }
            $all = @(Invoke-DotfilesPanelRun -Panel $p -Plain -NonInteractive -LogDir $script:PlainLog 6>&1)
            $rc = $all[-1]
            $text = (@($all | Select-Object -SkipLast 1) | ForEach-Object { "$_" }) -join "`n"
            $rc | Should -Be 0
            $text | Should -BeLike '*extras=sin-extras*'
        } finally {
            Remove-Item env:NUI_NONINTERACTIVE -ErrorAction SilentlyContinue
        }
    }

    It 'NUI_PLAIN=1 tambien fuerza el runner de texto' {
        $env:NUI_PLAIN = '1'
        try {
            $p = New-DotfilesPanel -Title 'plain-env'
            $p = Add-DotfilesPanelStep -Panel $p -Title 'Texto por env' -Body { Write-Output 'por-env' }
            $all = @(Invoke-DotfilesPanelRun -Panel $p -LogDir $script:PlainLog 6>&1)
            $text = (@($all | Select-Object -SkipLast 1) | ForEach-Object { "$_" }) -join "`n"
            $text | Should -BeLike '*por-env*'
        } finally {
            Remove-Item env:NUI_PLAIN -ErrorAction SilentlyContinue
        }
    }

    It 'un panel que no ejecuta nada cae al runner de texto' -Skip:(-not [Environment]::UserInteractive) {
        # Regresion del fallo real en maquina: nui volvia sin crear un solo log de
        # paso (consola no adjunta) y el instalador parecia no haber hecho nada.
        # El detector es "el panel no dejo log de paso", y se prueba con un nui
        # de juguete. En Windows el falso es un .cmd, que ProcessStartInfo no
        # puede lanzar: ahi se comprueba la misma salida (trabajo no hecho ->
        # runner de texto), no el codigo 0 del panel.
        $fake = Join-Path $script:Sandbox 'fake-nui'
        if ($IsWindows) {
            $fake = "$fake.cmd"
            # `fake-nui version` -> version soportada; `steps run` -> no hace nada.
            $body = @(
                '@echo off',
                'if "%1"=="version" echo nui 9.9.9',
                'exit /b 0'
            ) -join "`r`n"
            Set-Content -LiteralPath $fake -Value $body -Encoding ascii
        } else {
            $body = "#!/bin/sh`ncase `"`$1`" in`n  version) echo 'nui 9.9.9' ;;`nesac`nexit 0`n"
            Set-Content -LiteralPath $fake -Value $body
            chmod +x $fake
        }
        $prevUi = $env:UI_BIN
        $prevPlain = $env:NUI_PLAIN
        try {
            $env:UI_BIN = $fake
            Remove-Item env:NUI_PLAIN -ErrorAction SilentlyContinue
            (Get-DotfilesUiBin) | Should -Be $fake
            (Get-DotfilesUiVersion) | Should -Be '9.9.9'
            $p = New-DotfilesPanel -Title 'panel-mudo'
            $p = Add-DotfilesPanelStep -Panel $p -Title 'Paso rescatado' -Body {
                Write-DotfilesMessage -Level info -Text 'ejecutado-en-texto'
            }
            $all = @(Invoke-DotfilesPanelRun -Panel $p -LogDir $script:PlainLog 6>&1)
            $rc = $all[-1]
            $text = (@($all | Select-Object -SkipLast 1) | ForEach-Object { "$_" }) -join "`n"
            $rc | Should -Be 0
            $text | Should -BeLike '*se continua en modo texto*'
            $text | Should -BeLike '*ejecutado-en-texto*'
        } finally {
            $env:UI_BIN = $prevUi
            if ($prevPlain) { $env:NUI_PLAIN = $prevPlain }
        }
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
