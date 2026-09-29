param(
    [string]$Destination
)

$ErrorActionPreference = 'Stop'
$Source = (Resolve-Path -LiteralPath $PSScriptRoot).Path
foreach ($path in @(
    'package/zinc.md', 'package/native/lsqlite3complete.dll', 'data/cygnet.db', 'ac.yaml', 'models.ini',
    'install.sh', 'install.ps1', 'lux.toml', 'lux.lock', 'models.lock', 'README.md', 'RELEASE_NOTES.md', 'LICENSE', 'NOTICE'
)) {
    $item = Get-Item -LiteralPath (Join-Path $Source $path) -ErrorAction SilentlyContinue
    if (-not $item -or $item.PSIsContainer -or $item.Length -eq 0) {
        throw "Zinc release payload is incomplete: $path"
    }
}
if (-not $Destination) {
    if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is unavailable' }
    $Destination = Join-Path $env:LOCALAPPDATA 'Zinc'
}
New-Item -ItemType Directory -Force -Path $Destination | Out-Null
$Destination = (Resolve-Path -LiteralPath $Destination).Path
if ($Destination -eq [IO.Path]::GetPathRoot($Destination)) {
    throw 'Refusing to install Zinc at the filesystem root'
}
New-Item -ItemType Directory -Force -Path (Join-Path $Destination 'state') | Out-Null
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
        } elseif ($path -eq 'ac.yaml') {
            Write-Warning 'Preserved ac.yaml; verify its Zinc config is version 2 before running. Older config is not migrated.'
        }
    }
}
Write-Output $Destination
