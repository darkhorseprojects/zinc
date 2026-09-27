param(
    [string]$Destination
)

$ErrorActionPreference = 'Stop'
$Source = (Resolve-Path -LiteralPath $PSScriptRoot).Path
if (-not (Test-Path -LiteralPath (Join-Path $Source 'data/cygnet.db')) -or
    -not (Get-ChildItem (Join-Path $Source 'package/native') -Filter 'lsqlite3complete.*' -File)) {
    throw 'Zinc release payload is incomplete'
}
if (-not $Destination) {
    if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is unavailable' }
    $Destination = Join-Path $env:LOCALAPPDATA 'Zinc'
}
New-Item -ItemType Directory -Force -Path (Join-Path $Destination 'state') | Out-Null
$Destination = (Resolve-Path -LiteralPath $Destination).Path
if ($Source -ne $Destination) {
    foreach ($path in @('package', 'data')) {
        $output = Join-Path $Destination $path
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $output
        Copy-Item -Recurse -LiteralPath (Join-Path $Source $path) -Destination $output
    }
    foreach ($path in @(
        'install.sh', 'install.ps1', 'lux.toml', 'lux.lock', 'models.lock', 'README.md', 'RELEASE_NOTES.md', 'LICENSE', 'NOTICE'
    )) {
        Copy-Item -LiteralPath (Join-Path $Source $path) -Destination (Join-Path $Destination $path)
    }
    foreach ($path in @('ac.yaml', 'models.ini')) {
        $output = Join-Path $Destination $path
        if (-not (Test-Path -LiteralPath $output)) {
            Copy-Item -LiteralPath (Join-Path $Source $path) -Destination $output
        }
    }
}
Write-Output $Destination
