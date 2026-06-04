param(
    [string]$Version = "latest",
    [string]$InstallDir = "$env:LOCALAPPDATA\zinc\bin",
    [string]$Archive = "",
    [switch]$NoDoctor
)

$ErrorActionPreference = "Stop"
$Repo = "darkhorseprojects/zinc"
$Asset = "zinc-windows-x86_64.zip"
$ConfigDir = Join-Path $env:APPDATA "zinc"
$DataDir = Join-Path $env:APPDATA "zinc"
$ConfigFile = Join-Path $ConfigDir "config.yaml"
$Temp = Join-Path ([System.IO.Path]::GetTempPath()) ("zinc-install-" + [System.Guid]::NewGuid().ToString("N"))

New-Item -ItemType Directory -Force -Path $Temp | Out-Null
try {
    $ArchivePath = Join-Path $Temp $Asset
    if ($Archive) {
        Copy-Item -LiteralPath $Archive -Destination $ArchivePath
    } else {
        if ($Version -eq "latest") {
            $Url = "https://github.com/$Repo/releases/latest/download/$Asset"
        } else {
            $Url = "https://github.com/$Repo/releases/download/$Version/$Asset"
        }
        Invoke-WebRequest -Uri $Url -OutFile $ArchivePath
    }

    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $Temp -Force

    $Binary = Join-Path $Temp "zn.exe"
    $Stock = Join-Path $Temp "stock"
    if (-not (Test-Path -LiteralPath $Binary)) { throw "release archive did not contain zn.exe" }
    if (-not (Test-Path -LiteralPath $Stock)) { throw "release archive did not contain stock assets" }

    New-Item -ItemType Directory -Force -Path $InstallDir, $ConfigDir, $DataDir | Out-Null
    Copy-Item -LiteralPath $Binary -Destination (Join-Path $InstallDir "zn.exe") -Force

    $Graphs = Join-Path $DataDir "graphs"
    $Prompts = Join-Path $DataDir "prompts"
    Remove-Item -LiteralPath $Graphs -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Prompts -Recurse -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath (Join-Path $Stock "graphs") -Destination $Graphs -Recurse
    Copy-Item -LiteralPath (Join-Path $Stock "prompts") -Destination $Prompts -Recurse

    if (-not (Test-Path -LiteralPath $ConfigFile)) {
        Copy-Item -LiteralPath (Join-Path $Stock "config.yaml") -Destination $ConfigFile
    }

    Write-Host "installed Zinc: $(Join-Path $InstallDir 'zn.exe')"
    Write-Host "installed stock assets: $DataDir"
    Write-Host "config: $ConfigFile"
    Write-Host "add to PATH if needed: $InstallDir"

    if (-not $NoDoctor) {
        & (Join-Path $InstallDir "zn.exe") doctor
    } else {
        Write-Host "run doctor: $(Join-Path $InstallDir 'zn.exe') doctor"
    }
}
finally {
    Remove-Item -LiteralPath $Temp -Recurse -Force -ErrorAction SilentlyContinue
}
