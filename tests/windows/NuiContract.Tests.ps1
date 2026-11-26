# NuiContract.Tests.ps1 - prueba real contra el binario nui.
#
# Es LA prueba que mantiene unido el triangulo bootstrap.ps1 -> plan JSON ->
# nui -> paso PowerShell. Si alguien cambia el formato sin actualizar nui (o al
# reves), esto rompe aqui y no en la VM de un usuario.

BeforeAll {
    $RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
    $script:RepoRoot = $RepoRoot
    $script:Sandbox = Join-Path ([IO.Path]::GetTempPath()) ('nui-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $script:Sandbox | Out-Null
    $env:DOTFILES_HOME = $script:Sandbox
    $env:DOTFILES_PLATFORM_OVERRIDE = 'windows'
    $env:DOTFILES_RUN_ID = "nuitest-$PID"
    Import-Module (Join-Path $RepoRoot 'scripts/lib/dotfiles.psm1') -Force
    Import-Module (Join-Path $RepoRoot 'scripts/lib/ui.psm1') -Force

    # nui se compila del fuente del repo: la prueba siempre habla con la
    # version que se esta revisando, no con un binario descargado.
    $script:NuiBin = Join-Path $script:Sandbox 'nui'
    if ($IsWindows) { $script:NuiBin += '.exe' }
    Push-Location (Join-Path $RepoRoot 'ui')
    try {
        & go build -o $script:NuiBin .
        if ($LASTEXITCODE -ne 0) { throw "go build fallo ($LASTEXITCODE)" }
    } finally {
        Pop-Location
    }
}

AfterAll {
    Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item env:DOTFILES_HOME -ErrorAction SilentlyContinue
    Remove-Item env:DOTFILES_PLATFORM_OVERRIDE -ErrorAction SilentlyContinue
    Remove-Item env:DOTFILES_RUN_ID -ErrorAction SilentlyContinue
}

Describe 'nui ejecuta un plan pwsh' {
    BeforeEach {
        $script:Panel = New-DotfilesPanel -Title 'PRUEBA NUI'
        $script:LogDir = Join-Path $script:Sandbox ('logs-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null
    }

    It 'ejecuta un paso simple y lo marca como OK' {
        $script:Panel = Add-DotfilesPanelStep -Panel $script:Panel -Title 'Paso simple' -Body {
            Write-Output '##log linea del paso'
            'salida final'
        }
        $json = ConvertTo-DotfilesPlanJson -Panel $script:Panel
        $plan = Join-Path $script:Sandbox 'plan-ok.json'
        [IO.File]::WriteAllText($plan, $json, (New-Object System.Text.UTF8Encoding($false)))

        $out = & $script:NuiBin steps run --plan $plan --log-dir $script:LogDir --plain --non-interactive 2>&1
        $code = $LASTEXITCODE
        $text = ($out | Out-String)

        $code | Should -Be 0
        $text | Should -BeLike '*Paso simple*'
        # el ##log del paso no debe aparecer como texto crudo
        $text | Should -Not -BeLike '*##log*'
        $text | Should -BeLike '*linea del paso*'
    }

    It 'escribe los resultados de formulario en formato PowerShell' {
        $script:Panel = Add-DotfilesPanelInput -Panel $script:Panel -Type 'input' -Name 'p_name' -Prompt 'Nombre' -Default 'Chaminn'
        $script:Panel = Add-DotfilesPanelInput -Panel $script:Panel -Type 'select' -Name 'extras' -Prompt 'Paquetes' -Options @('bat', 'eza') -Multi -Default @('bat', 'eza')
        $script:Panel = Add-DotfilesPanelStep -Panel $script:Panel -Title 'Con inputs' -Body {
            # los multivalor llegan separados por salto de linea (docs/STEPS.md)
            "n=[$p_name]"
            "x=[$(($extras -split "`n" | Where-Object { $_ }) -join '|')]"
        }
        $json = ConvertTo-DotfilesPlanJson -Panel $script:Panel
        $plan = Join-Path $script:Sandbox 'plan-inputs.json'
        [IO.File]::WriteAllText($plan, $json, (New-Object System.Text.UTF8Encoding($false)))

        $out = (& $script:NuiBin steps run --plan $plan --log-dir $script:LogDir --plain --non-interactive 2>&1 | Out-String)
        $LASTEXITCODE | Should -Be 0
        # el paso recibio los valores como variables PowerShell
        # -like trata [abc] como clase de caracteres: hay que escapar los
        # corchetes literales del paso de prueba.
        $out | Should -Match 'n=\[Chaminn\]'
        $out | Should -Match 'x=\[bat\|eza\]'
        # en modo no interactivo no se debe haber impreso ningun prompt
        $out | Should -Not -BeLike '*Seleccion*'
    }

    It 'un paso opcional que falla solo produce aviso' {
        $script:Panel = Add-DotfilesPanelStep -Panel $script:Panel -Title 'Opcional roto' -Optional -Body { exit 7 }
        $script:Panel = Add-DotfilesPanelStep -Panel $script:Panel -Title 'Siguiente' -Body { 'sigue' }
        $json = ConvertTo-DotfilesPlanJson -Panel $script:Panel
        $plan = Join-Path $script:Sandbox 'plan-opt.json'
        [IO.File]::WriteAllText($plan, $json, (New-Object System.Text.UTF8Encoding($false)))

        $out = (& $script:NuiBin steps run --plan $plan --log-dir $script:LogDir --plain --non-interactive 2>&1 | Out-String)
        $LASTEXITCODE | Should -Be 0
        $out | Should -BeLike '*Opcional roto*'
        $out | Should -BeLike '*sigue*'

    }

    It 'un paso obligatorio que falla aborta el plan con exit 1' {
        $script:Panel = Add-DotfilesPanelStep -Panel $script:Panel -Title 'Roto' -Body { exit 3 }
        $script:Panel = Add-DotfilesPanelStep -Panel $script:Panel -Title 'No llega' -Body { 'no deberia correr' }
        $json = ConvertTo-DotfilesPlanJson -Panel $script:Panel
        $plan = Join-Path $script:Sandbox 'plan-fail.json'
        [IO.File]::WriteAllText($plan, $json, (New-Object System.Text.UTF8Encoding($false)))

        $out = (& $script:NuiBin steps run --plan $plan --log-dir $script:LogDir --plain --non-interactive 2>&1 | Out-String)
        $LASTEXITCODE | Should -Be 1
        $out | Should -Not -BeLike '*no deberia correr*'
    }

    It 'rechaza un plan sin argv ni cmd' {
        $plan = Join-Path $script:Sandbox 'plan-malo.json'
        [IO.File]::WriteAllText($plan, '{"steps":[{"title":"sin comando"}]}', (New-Object System.Text.UTF8Encoding($false)))
        $out = & $script:NuiBin steps run --plan $plan --log-dir $script:LogDir --plain 2>&1
        $LASTEXITCODE | Should -Not -Be 0
        ($out | Out-String) | Should -BeLike '*sin comando*'
    }

    It 'rechaza una shell desconocida en el plan' {
        $plan = Join-Path $script:Sandbox 'plan-shell.json'
        [IO.File]::WriteAllText($plan, '{"shell":"fish","steps":[{"title":"t","cmd":"true"}]}', (New-Object System.Text.UTF8Encoding($false)))
        $null = & $script:NuiBin steps run --plan $plan --log-dir $script:LogDir --plain 2>&1
        $LASTEXITCODE | Should -Not -Be 0
    }
}

Describe 'nui como helper de UI' {
    It 'spin ejecuta el comando y propaga el codigo de salida' {
        $pwsh = (Get-Command pwsh, powershell -ErrorAction SilentlyContinue | Select-Object -First 1).Source
        { $null = & $pwsh } | Should -Not -Throw

        $null = & $script:NuiBin spin --title 'ok' -- $pwsh -NoProfile -Command 'exit 0' 2>&1
        $LASTEXITCODE | Should -Be 0

        # El spinner NO puede enmascarar el fracaso del comando: bootstrap
        # depende de ese codigo para decidir aviso/error.
        $null = & $script:NuiBin spin --title 'mal' -- $pwsh -NoProfile -Command 'exit 5' 2>&1
        $LASTEXITCODE | Should -Be 5
    }

    It 'log y version responden' {
        $out = & $script:NuiBin log --level warn 'aviso de prueba' 2>&1
        $LASTEXITCODE | Should -Be 0
        ($out | Out-String) | Should -BeLike '*aviso de prueba*'
        $v = (& $script:NuiBin version 2>&1 | Out-String)
        $v | Should -Match '\d+\.\d+\.\d+'
    }
}
