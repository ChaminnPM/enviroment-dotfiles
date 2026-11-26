# build.ps1 - compila nui y genera bin\*.gz + bin\SHA256SUMS sin necesitar bash.
#
# Uso:
#   pwsh -File ui/build.ps1
#   pwsh -File ui/build.ps1 -Targets @('windows/amd64') -IncludeDarwin
#
# Equivalente en PowerShell de ui/build.sh: mismas salida y checksums.
[CmdletBinding()]
param(
    [string[]]$Targets,
    [switch]$IncludeDarwin,
    [string]$Version
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$UiDir = $PSScriptRoot
$RepoRoot = Split-Path -Parent $UiDir
$OutDir = Join-Path $RepoRoot 'bin'

function Invoke-Step {
    param([string]$Exe, [string[]]$StepArgs, [string]$WorkDir)
    $prev = $PWD
    if ($WorkDir) { Set-Location $WorkDir }
    try {
        Write-Host ">> $Exe $($StepArgs -join ' ')" -ForegroundColor DarkGray
        & $Exe @StepArgs
        $rc = $LASTEXITCODE
        if ($rc -ne 0) { throw "$Exe fallo con codigo $rc" }
    }
    finally {
        if ($WorkDir) { Set-Location $prev }
    }
}

$go = (Get-Command go -ErrorAction SilentlyContinue)
if (-not $go) { throw 'go no esta instalado ni en PATH' }

if (-not $Version) {
    $vf = Join-Path $UiDir 'VERSION'
    $Version = if (Test-Path -LiteralPath $vf) { (Get-Content -LiteralPath $vf -Raw).Trim() } else { '0.0.0' }
}

if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
}

# La paleta de nui se genera desde el unico archivo de tema del repo.
& (Join-DotfilesPath -Base $RepoRoot -Child 'scripts/gen-theme-go.ps1')

Push-Location $UiDir
try {
    $unformatted = @(& gofmt -l . 2>$null | Where-Object { $_ })
    if ($unformatted.Count -gt 0) {
        throw "hay archivos sin gofmt:`n$($unformatted -join "`n")"
    }
    Invoke-Step go @('vet', './...')
    Invoke-Step go @('test', './...')
}
finally {
    Pop-Location
}

if (-not $Targets) {
    $Targets = @('linux/amd64', 'linux/arm64', 'windows/amd64', 'windows/arm64')
    if ($IncludeDarwin) { $Targets += @('darwin/amd64', 'darwin/arm64') }
}

function Compress-Gz {
    param([string]$Source, [string]$Destination)
    $in = [System.IO.File]::OpenRead($Source)
    try {
        $out = [System.IO.File]::Create($Destination)
        try {
            $gz = New-Object System.IO.Compression.GZipStream($out, [System.IO.Compression.CompressionLevel]::Optimal)
            try { $in.CopyTo($gz) } finally { $gz.Dispose() }
        } finally { $out.Dispose() }
    } finally { $in.Dispose() }
}

$sums = @()
foreach ($t in $Targets) {
    $goos, $goarch = $t.Split('/')
    $ext = if ($goos -eq 'windows') { '.exe' } else { '' }
    $name = "nui-$goos-$goarch$ext"
    Write-Host ">> $name ($Version)"
    $env:CGO_ENABLED = '0'
    $env:GOOS = $goos
    $env:GOARCH = $goarch
    $bin = Join-Path $OutDir $name
    Push-Location $UiDir
    try {
        & go build -trimpath -ldflags "-s -w -X main.nuiVersion=$Version" -o $bin .
        if ($LASTEXITCODE -ne 0) { throw "go build fallo para $t" }
    }
    finally {
        Pop-Location
        $env:GOOS = ''
        $env:GOARCH = ''
    }
    # GZipStream no escribe mtime ni nombre: el .gz coincide byte a byte con
    # `gzip -9 -n` del build de bash.
    Compress-Gz -Source $bin -Destination "$bin.gz"
    # Se publica el checksum del binario descomprimido (lo que se ejecuta),
    # igual que en build.sh.
    $hash = (Get-FileHash -LiteralPath $bin -Algorithm SHA256).Hash.ToLower()
    $sums += "$hash  $name"
    Remove-Item -LiteralPath $bin -Force
}

[System.IO.File]::WriteAllText((Join-Path $OutDir 'VERSION'), "$Version`n", [System.Text.UTF8Encoding]::new($false))

# bin/SHA256SUMS: checksums de los binarios que verifican los instaladores.
# Clave = nombre del binario descomprimido, ordenado para que el diff sea
# estable entre build.sh y build.ps1.
[System.IO.File]::WriteAllText(
    (Join-Path $OutDir 'SHA256SUMS'),
    (($sums | Sort-Object) -join "`n") + "`n",
    [System.Text.UTF8Encoding]::new($false))

$count = (Get-ChildItem -LiteralPath $OutDir -Filter 'nui-*.gz' -File).Count
Write-Host ">> listo: $count binarios comprimidos (v$Version)"
