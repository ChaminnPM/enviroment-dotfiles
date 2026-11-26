# Acl.Tests.ps1 - ACLs de Windows (sustituto de chmod 600).
#
# Solo se ejecutan en Windows: en Linux Set-DotfilesPrivateAcl es un no-op y un
# test que pasara ahi no habria detectado que el instalador concedia permisos a
# una cuenta inexistente ("MAQUINA+usuario" en lugar de "MAQUINA\usuario").

# El skip se decide en descubrimiento: tiene que ser una variable de nivel de
# script asignada FUERA de BeforeAll (que solo corre al ejecutar).
$script:OnWindows = [System.Environment]::OSVersion.Platform -eq 'Win32NT'

BeforeAll {
    $RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
    Import-Module (Join-Path $RepoRoot 'scripts/lib/dotfiles.psm1') -Force
}

Describe 'ACLs privadas' -Skip:(-not $script:OnWindows) {
    BeforeEach {
        $script:Dir = Join-Path ([IO.Path]::GetTempPath()) ('acl-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $script:Dir | Out-Null
        $script:File = Join-Path $script:Dir 'clave'
        Set-Content -LiteralPath $script:File -Value 'privada'
    }
    AfterEach {
        Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'restringe un archivo al usuario actual' {
        (Set-DotfilesPrivateAcl -Path $script:File) | Should -BeTrue
        (Test-DotfilesPrivateAcl -Path $script:File) | Should -BeTrue
        (Get-Acl -LiteralPath $script:File).AreAccessRulesProtected | Should -BeTrue
    }

    It 'concede acceso al SID del usuario, no a un nombre que icacls no resuelve' {
        (Set-DotfilesPrivateAcl -Path $script:File) | Should -BeTrue
        $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $sid | Should -Match '^S-1-5-'
        (Get-DotfilesAclSids -Path $script:File) | Should -Contain $sid
    }

    It 'acepta los SIDs de sistema que Windows necesita' {
        (Set-DotfilesPrivateAcl -Path $script:File) | Should -BeTrue
        $sids = @(Get-DotfilesAclSids -Path $script:File)
        $sids | Should -Contain 'S-1-5-18'      # SYSTEM
        $sids | Should -Contain 'S-1-5-32-544'  # Administrators (localizado)
    }

    It 'el dueno conserva escritura (chmod 600, no chmod 400)' {
        (Set-DotfilesPrivateAcl -Path $script:File) | Should -BeTrue
        Set-Content -LiteralPath $script:File -Value 'se puede reescribir'
        (Get-Content -LiteralPath $script:File -Raw).Trim() | Should -Be 'se puede reescribir'
    }

    It 'restringe un directorio y sus hijos heredan' {
        (Set-DotfilesPrivateAcl -Path $script:Dir -Kind dir) | Should -BeTrue
        (Test-DotfilesPrivateAcl -Path $script:Dir) | Should -BeTrue
        (Get-Acl -LiteralPath $script:Dir).AreAccessRulesProtected | Should -BeTrue
        $hijo = Join-Path $script:Dir 'hijo.txt'
        Set-Content -LiteralPath $hijo -Value 'x'
        $acl = Get-Acl -LiteralPath $hijo
        @($acl.Access | Where-Object { -not $_.IsInherited }).Count | Should -Be 0
    }

    It 'detecta una ACL con un principal ajeno' {
        $abierto = Join-Path $script:Dir 'abierto'
        Set-Content -LiteralPath $abierto -Value 'x'
        # SID bien conocido de BUILTIN\Users: se usa el SID para no depender del
        # idioma del runner (en espanol es BUILTIN\Usuarios).
        $acl = Get-Acl -LiteralPath $abierto
        $sidObj = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($sidObj, 'Read', 'Allow')
        $acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $abierto -AclObject $acl
        (Test-DotfilesPrivateAcl -Path $abierto) | Should -BeFalse
    }

    It 'Get-DotfilesUserSid devuelve un SID valido' {
        (Get-DotfilesUserSid) | Should -Match '^S-1-5-\d+-\d+'
    }
}

Describe 'ACLs en no-Windows' -Skip:$script:OnWindows {
    It 'Set-DotfilesPrivateAcl es un no-op (manda chmod)' {
        $f = Join-Path ([IO.Path]::GetTempPath()) ('acl-' + [guid]::NewGuid().ToString('N'))
        Set-Content -LiteralPath $f -Value 'x'
        try {
            (Set-DotfilesPrivateAcl -Path $f) | Should -BeFalse
            (Test-DotfilesPrivateAcl -Path $f) | Should -BeTrue
        } finally {
            Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        }
    }
}
