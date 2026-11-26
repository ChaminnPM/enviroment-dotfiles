# Dotfiles.Tests.ps1 - tests de las primitivas de manipulacion de archivos.
#
# Usan DOTFILES_HOME para apuntar a un home desechable: ningun test escribe en
# la cuenta real del runner.

BeforeAll {
    $RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
    $env:DOTFILES_PLATFORM_OVERRIDE = 'windows'
    Import-Module (Join-Path $RepoRoot 'scripts/lib/dotfiles.psm1') -Force
}

AfterAll {
    Remove-Item env:DOTFILES_PLATFORM_OVERRIDE -ErrorAction SilentlyContinue
}

Describe 'Bloques gestionados' {
    BeforeEach {
        $script:Sandbox = Join-Path ([IO.Path]::GetTempPath()) ('df-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $script:Sandbox | Out-Null
    $env:DOTFILES_HOME = $script:Sandbox
        $env:DOTFILES_RUN_ID = "run-$([guid]::NewGuid().ToString('N'))"
        $script:P = Get-DotfilesPaths
        $script:F = Join-Path $script:P.Project 'rc.sh'
        New-Item -ItemType Directory -Force -Path (Split-Path $script:F) | Out-Null
        $script:H = '# >>> dotfiles-env (no editar)'
        $script:Fn = '# <<< dotfiles-env'
    }
    AfterEach {
        Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item env:DOTFILES_HOME -ErrorAction SilentlyContinue
    }

    It 'crea el bloque cuando el archivo no existe' {
        $ok = Set-DotfilesManagedBlock -Path $script:F -Header $script:H -Footer $script:Fn -Body "export A='1'"
        $ok | Should -BeTrue
        (Get-Content -LiteralPath $script:F -Raw) | Should -BeLike "*$($script:H)*export A='1'*$($script:Fn)*"
    }

    It 'conserva lo que hay fuera del bloque' {
        Set-Content -LiteralPath $script:F -Value 'linha del usuario'
        $null = Set-DotfilesManagedBlock -Path $script:F -Header $script:H -Footer $script:Fn -Body "export A='1'"
        $txt = Get-Content -LiteralPath $script:F -Raw
        $txt | Should -BeLike '*linha del usuario*'
        $null = Set-DotfilesManagedBlock -Path $script:F -Header $script:H -Footer $script:Fn -Body "export A='2'"
        $txt2 = Get-Content -LiteralPath $script:F -Raw
        $txt2 | Should -BeLike '*linha del usuario*'
        $txt2 | Should -Not -BeLike "*export A='1'*"
        $txt2 | Should -BeLike "*export A='2'*"
    }

    It 'NO toca un bloque sin footer (a medio escribir)' {
        Set-Content -LiteralPath $script:F -Value ($script:H + "`nconfig suelta`n")
        $ok = Set-DotfilesManagedBlock -Path $script:F -Header $script:H -Footer $script:Fn -Body 'x'
        $ok | Should -BeFalse
        (Get-Content -LiteralPath $script:F -Raw) | Should -BeLike '*config suelta*'
    }

    It 'prepend pone el bloque al principio (prioridad en ~/.ssh/config)' {
        Set-Content -LiteralPath $script:F -Value 'Host usuario'
        $null = Set-DotfilesManagedBlock -Path $script:F -Header $script:H -Footer $script:Fn -Body 'Host github.com' -Position 'prepend'
        $lines = Get-Content -LiteralPath $script:F
        $lines[0] | Should -Be $script:H
        ($lines | Select-Object -Last 1) | Should -Be 'Host usuario'
    }

    It 'Get-DotfilesManagedBlockBody devuelve SOLO el interior' {
        $null = Set-DotfilesManagedBlock -Path $script:F -Header $script:H -Footer $script:Fn -Body "export A='9'"
        (Get-DotfilesManagedBlockBody -Path $script:F -Header $script:H -Footer $script:Fn) | Should -Be "export A='9'"
        Test-DotfilesManagedBlock -Path $script:F -Header $script:H -Footer $script:Fn -MustContain "export A='9'" |
            Should -BeTrue
        Test-DotfilesManagedBlock -Path $script:F -Header $script:H -Footer $script:Fn -MustContain 'inexistente' |
            Should -BeFalse
    }

    It 'un bloque vacio no pasa el chequeo de contenido' {
        # Falso positivo historico del doctor: los marcadores sin nada dentro.
        $null = Set-DotfilesManagedBlock -Path $script:F -Header $script:H -Footer $script:Fn -Body ''
        Test-DotfilesManagedBlock -Path $script:F -Header $script:H -Footer $script:Fn -MustContain 'env.ps1' |
            Should -BeFalse
    }
}

Describe 'PATH persistente' {
    BeforeEach {
        $script:Sandbox = Join-Path ([IO.Path]::GetTempPath()) ('df-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $script:Sandbox | Out-Null
    $env:DOTFILES_HOME = $script:Sandbox
        $env:DOTFILES_RUN_ID = "run-$([guid]::NewGuid().ToString('N'))"
        $script:P = Get-DotfilesPaths
    }
    AfterEach {
        Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item env:DOTFILES_HOME -ErrorAction SilentlyContinue
    }

    It 'es idempotente: una sola entrada por directorio' {
        $d = Join-Path $script:P.BinDir 'herramientas'
        $null = Add-DotfilesEnvPath -Dir $d
        $null = Add-DotfilesEnvPath -Dir $d
        $null = Add-DotfilesEnvPath -Dir $d
        $txt = Get-Content -LiteralPath (Get-DotfilesEnvFilePath) -Raw
        ([regex]::Matches($txt, [regex]::Escape("`$ddDir="))).Count | Should -Be 1
    }

    It 'anade cada directorio nuevo' {
        $null = Add-DotfilesEnvPath -Dir (Join-Path $script:P.BinDir 'a')
        $null = Add-DotfilesEnvPath -Dir (Join-Path $script:P.BinDir 'b')
        $txt = Get-Content -LiteralPath (Get-DotfilesEnvFilePath) -Raw
        $txt | Should -BeLike '*a*'
        $txt | Should -BeLike '*b*'
        ([regex]::Matches($txt, [regex]::Escape("`$ddDir="))).Count | Should -Be 2
    }

    It 'el env.ps1 generado es dot-sourceable' {
        $dir = Join-Path $script:P.BinDir 'x'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $null = Add-DotfilesEnvPath -Dir $dir
        $before = $env:Path
        $null = Use-DotfilesEnv
        $env:Path | Should -BeLike "*$dir*"
        $env:Path = $before
    }
}

Describe 'Respaldos' {
    BeforeEach {
        $script:Sandbox = Join-Path ([IO.Path]::GetTempPath()) ('df-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $script:Sandbox | Out-Null
    $env:DOTFILES_HOME = $script:Sandbox
        $env:DOTFILES_RUN_ID = "run-$([guid]::NewGuid().ToString('N'))"
        $script:P = Get-DotfilesPaths
        New-Item -ItemType Directory -Force -Path $script:P.BackupDir | Out-Null
    }
    AfterEach {
        Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item env:DOTFILES_HOME -ErrorAction SilentlyContinue
        $env:DOTFILES_RUN_ID = $null
    }

    It 'crea un respaldo por archivo y ejecucion' {
        $env:DOTFILES_RUN_ID = 'run-prueba'
        $f = Join-Path $script:P.Project 'gitconfig'
        New-Item -ItemType Directory -Force -Path (Split-Path $f) | Out-Null
        Set-Content -LiteralPath $f -Value 'original'
        $b1 = Backup-DotfilesFile -Path $f
        $b2 = Backup-DotfilesFile -Path $f
        $b1 | Should -Not -BeNullOrEmpty
        $b1 | Should -Be $b2
        @(Get-ChildItem -LiteralPath $script:P.BackupDir -File).Count | Should -Be 1
    }

    It 'no respalda archivos inexistentes' {
        $env:DOTFILES_RUN_ID = 'run-prueba2'
        Backup-DotfilesFile -Path (Join-Path $script:P.Project 'no-existe') | Should -BeNullOrEmpty
    }
}

Describe 'Scritura atomica y JSON' {
    BeforeEach {
        $script:Sandbox = Join-Path ([IO.Path]::GetTempPath()) ('df-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $script:Sandbox | Out-Null
    $env:DOTFILES_HOME = $script:Sandbox
        $env:DOTFILES_RUN_ID = "run-$([guid]::NewGuid().ToString('N'))"
        $script:P = Get-DotfilesPaths
    }
    AfterEach {
        Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item env:DOTFILES_HOME -ErrorAction SilentlyContinue
    }

    It 'no deja temporales y escribe UTF-8 sin BOM' {
        $f = Join-Path $script:P.Project 'sub/escrito.toml'
        Write-DotfilesFile -Path $f -Content 'a = "x"' | Out-Null
        $bytes = [IO.File]::ReadAllBytes($f)
        $bytes[0] | Should -Not -Be 0xEF
        @(Get-ChildItem -LiteralPath (Split-Path $f) -Filter '.dotfiles-*' -Force).Count | Should -Be 0
    }

    It 'Write/Read-DotfilesJson preservan valores con comillas' {
        $f = Join-Path $script:P.Project 'acc.json'
        $obj = [ordered]@{ personal = [ordered]@{ name = "O'Brien"; email = 'a@b.c' }; spaces = @() }
        Write-DotfilesJson -Path $f -Object $obj | Out-Null
        $back = Read-DotfilesJson -Path $f -AsHashtable
        $back['personal']['name'] | Should -Be "O'Brien"
    }

    It 'Get-DotfilesFileHash y Test-DotfilesHash' {
        New-Item -ItemType Directory -Force -Path $script:P.Project | Out-Null
        $f = Join-Path $script:P.Project 'bin.dat'
        [IO.File]::WriteAllBytes($f, [byte[]](1, 2, 3))
        $h = Get-DotfilesFileHash -Path $f
        $h | Should -Be '039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81'
        Test-DotfilesHash -Path $f -Sha256 $h | Should -BeTrue
        Test-DotfilesHash -Path $f -Sha256 ('0' * 64) | Should -BeFalse
    }
}

Describe 'Rutas y plataforma' {
    It 'Windows: todo el estado bajo ~/.config/enviroment-dotfiles' {
        $env:DOTFILES_PLATFORM_OVERRIDE = 'windows'
        $env:DOTFILES_HOME = 'C:/Users/Test'
        try {
            $p = Get-DotfilesPaths
            $p.Project | Should -Be 'C:/Users/Test/.config/enviroment-dotfiles'
            $p.EnvFile | Should -BeLike '*enviroment-dotfiles*env.ps1'
            $p.OpenCodeDir | Should -BeLike '*.config*opencode'
            $p.BinDir | Should -BeLike '*enviroment-dotfiles*bin*'
            # Las unicas rutas fuera del arbol son las que impone el SO.
            $p.FontDir | Should -BeLike '*Microsoft*Windows*Fonts*'
            $p.SshDir | Should -BeLike '*.ssh'
            $p.Project | Should -Not -BeLike '*//*'
        } finally {
            Remove-Item env:DOTFILES_HOME
        }
    }

    It 'linux: conserva ~/.local/state' {
        $env:DOTFILES_PLATFORM_OVERRIDE = 'linux'
        $env:DOTFILES_HOME = '/tmp/x'
        try {
            $p = Get-DotfilesPaths
            $p.FontDir | Should -BeLike '*.local*share*fonts*'
            $p.TerminalSettings | Should -BeNullOrEmpty
        } finally {
            Remove-Item env:DOTFILES_HOME
        }
    }
}

Describe 'Citado de argumentos nativos' {
    It 'vacio -> "" (PowerShell 5.1 descarta el vacio sin comillas)' {
        Get-DotfilesQuotedArgs -Values @('-N', '') | Should -Be '-N ""'
    }
    It 'espacios se entrecomillan' {
        Get-DotfilesQuotedArgs -Values @('-File', 'C:\Users\John Doe\step-01.ps1') |
            Should -Be '-File "C:\Users\John Doe\step-01.ps1"'
    }
    It 'comillas internas se escapan con backslash' {
        Get-DotfilesQuotedArgs -Values @('--msg', 'hola "mundo"') | Should -Be '--msg "hola \"mundo\""'
    }
    It 'backslashes antes de comilla se duplican' {
        Get-DotfilesQuotedArgs -Values @('--dir', 'C:\tmp\"x"') | Should -Be '--dir "C:\tmp\\\"x\""'
    }
}

Describe 'Resolucion de ejecutables' {
    # Regresion: Get-Command devuelve TODAS las coincidencias del PATH. Si hay
    # dos copias de una herramienta (curl de system32 + curl de scoop/conda),
    # `.Source` era un array y ese array se colaba como FileName/argv: el
    # instalador fallaba con "el termino 'C:\...\curl.exe C:\...\curl.exe' no se
    # reconoce".
    It 'elige UNA ruta cuando hay varias copias en el PATH' {
        $sep = [IO.Path]::PathSeparator
        $dirs = @('a', 'b') | ForEach-Object {
            $d = Join-Path ([IO.Path]::GetTempPath()) ("exe-$_-" + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Force -Path $d | Out-Null
            $f = Join-Path $d 'df-curl.exe'
            Set-Content -LiteralPath $f -Value '@echo off'
            if (-not $IsWindows) { chmod +x $f }
            $d
        }
        $prev = $env:PATH
        try {
            $env:PATH = (($dirs + $prev) -join $sep)
            $one = Resolve-DotfilesExe -Name 'df-curl.exe'
            $one | Should -BeOfType ([string])
            @($one).Count | Should -Be 1
            $self = Get-DotfilesSelfPwsh
            $self | Should -BeOfType ([string])
            @($self).Count | Should -Be 1
        } finally {
            $env:PATH = $prev
            $dirs | ForEach-Object { Remove-Item -LiteralPath $_ -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}

Describe 'Get-DotfilesSelfPwsh y Resolve-DotfilesExe' {
    # Regresion: con dos copias de una herramienta en el PATH, `Get-Command`
    # devuelve un array y `(Get-Command x).Source` tambien. Ese array, al
    # asignarse a [string], se une con espacios y el proceso hijo no arranca.
    It 'devuelve UNA ruta aunque el PATH tenga varias copias' {
        $sep = [IO.Path]::PathSeparator
        $dirs = @(1, 2) | ForEach-Object {
            $d = Join-Path ([IO.Path]::GetTempPath()) ('path-' + $_ + '-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Force -Path $d | Out-Null
            $f = Join-Path $d 'dfprobe.exe'
            Set-Content -LiteralPath $f -Value '@echo off'
            if (-not $IsWindows) { chmod +x $f }
            $d
        }
        $prevPath = $env:PATH
        try {
            $env:PATH = (($dirs + $prevPath) -join $sep)
            $r = Resolve-DotfilesExe -Name 'dfprobe.exe'
            $r | Should -BeOfType ([string])
            ($r -split ' ')[0] | Should -Be (Join-Path $dirs[0] 'dfprobe.exe')
        } finally {
            $env:PATH = $prevPath
            $dirs | ForEach-Object { Remove-Item -LiteralPath $_ -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'Get-DotfilesSelfPwsh devuelve una ruta suelta' {
        $p = Get-DotfilesSelfPwsh
        $p | Should -BeOfType ([string])
        @($p).Count | Should -Be 1
    }
}

Describe 'Aplanado de argv' {
    # Regresion del instalador en maquina real: `(Get-Command curl.exe).Source`
    # con dos copias en PATH es un array y al encajar en [string[]] se unia en un
    # solo elemento ("ruta1 ruta2"), produciendo un ejecutable inexistente.
    It 'un elemento array se reduce a su primer valor' {
        $flat = ConvertTo-DotfilesArgv -Values @(@('C:\x\curl.exe', 'C:\y\curl.exe'), '-fsSL', 'http://z')
        @($flat).Count | Should -Be 3
        $flat[0] | Should -Be 'C:\x\curl.exe'
        $flat[1] | Should -Be '-fsSL'
        $flat[2] | Should -Be 'http://z'
    }

    It 'null y elementos vacios no generan argumentos fantasma' {
        $flat = ConvertTo-DotfilesArgv -Values @('cmd', $null, @(), '-c')
        @($flat) -join '|' | Should -Be 'cmd|-c'
    }

    It 'Invoke-DotfilesNative ejecuta con argv anidada' {
        # La salida del hijo va a [Console]::Out (no al pipeline), asi que se
        # comprueba el codigo: con el bug, el FileName era "ruta1 ruta2" y el
        # proceso no arrancaba (CommandNotFound / 127).
        $argv = if ($IsWindows) {
            @(@('cmd.exe', 'cmd.exe'), '/c', 'exit 0')
        } else {
            @(@('/bin/sh', '/bin/sh'), '-c', 'exit 0')
        }
        (Invoke-DotfilesNative -Argv $argv) | Should -Be 0
        $argvFail = if ($IsWindows) {
            @(@('cmd.exe', 'cmd.exe'), '/c', 'exit 5')
        } else {
            @(@('/bin/sh', '/bin/sh'), '-c', 'exit 5')
        }
        (Invoke-DotfilesNative -Argv $argvFail) | Should -Be 5
    }
}

Describe 'Copia de trees' {
    BeforeEach {
        $script:Sandbox = Join-Path ([IO.Path]::GetTempPath()) ('ct-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $script:Sandbox | Out-Null
        $env:DOTFILES_HOME = $script:Sandbox
        $script:P = Get-DotfilesPaths
        $script:Src = Join-Path $script:Sandbox 'src'
        New-Item -ItemType Directory -Force -Path (Join-Path $script:Src 'sub') | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Src 'a.md') -Value 'A'
        Set-Content -LiteralPath (Join-Path $script:Src 'sub/b.md') -Value 'B'
        $script:Dst = Join-Path $script:Sandbox 'dst'
    }
    AfterEach {
        Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item env:DOTFILES_HOME -ErrorAction SilentlyContinue
    }

    It 'copia el CONTENIDO en el destino, no la carpeta dentro' {
        $null = Copy-DotfilesTree -Source $script:Src -Destination $script:Dst
        Test-Path -LiteralPath (Join-Path $script:Dst 'a.md') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Dst 'sub/b.md') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Dst 'src') | Should -BeFalse
    }

    It 'es idempotente: relanzar no anida (regresion theme/theme)' {
        $null = Copy-DotfilesTree -Source $script:Src -Destination $script:Dst
        $null = Copy-DotfilesTree -Source $script:Src -Destination $script:Dst
        $null = Copy-DotfilesTree -Source $script:Src -Destination $script:Dst
        Test-Path -LiteralPath (Join-Path $script:Dst 'a.md') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Dst 'src') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:Dst 'dst') | Should -BeFalse
        @(Get-ChildItem -LiteralPath $script:Dst -Recurse -File).Count | Should -Be 2
    }

    It 'fuente con barra final da el mismo resultado' {
        $null = Copy-DotfilesTree -Source ($script:Src + [IO.Path]::DirectorySeparatorChar) -Destination ($script:Dst + [IO.Path]::DirectorySeparatorChar)
        Test-Path -LiteralPath (Join-Path $script:Dst 'a.md') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Dst 'src') | Should -BeFalse
    }

    It '-Mirror elimina lo que sobra en el destino' {
        New-Item -ItemType Directory -Force -Path $script:Dst | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Dst 'sobrante.md') -Value 'X'
        $null = Copy-DotfilesTree -Source $script:Src -Destination $script:Dst -Mirror
        Test-Path -LiteralPath (Join-Path $script:Dst 'sobrante.md') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:Dst 'a.md') | Should -BeTrue
    }

    It 'sin -Mirror conserva lo del usuario en el destino' {
        New-Item -ItemType Directory -Force -Path $script:Dst | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Dst 'mio.md') -Value 'X'
        $null = Copy-DotfilesTree -Source $script:Src -Destination $script:Dst
        Test-Path -LiteralPath (Join-Path $script:Dst 'mio.md') | Should -BeTrue
    }

    It 'un archivo se copia como archivo' {
        $null = Copy-DotfilesTree -Source (Join-Path $script:Src 'a.md') -Destination (Join-Path $script:Dst 'otro.md')
        (Get-Content -LiteralPath (Join-Path $script:Dst 'otro.md') -Raw).Trim() | Should -Be 'A'
    }

    It 'fuente inexistente devuelve false sin crear nada' {
        $r = Copy-DotfilesTree -Source (Join-Path $script:Sandbox 'no-existe') -Destination $script:Dst
        $r | Should -BeFalse
    }
}
