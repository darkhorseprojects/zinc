param(
    [string]$Version = "latest",
    [string]$InstallDir = "$env:LOCALAPPDATA\zinc\bin",
    [string]$Archive = ""
)

$ErrorActionPreference = "Stop"
$Repo = "darkhorseprojects/zinc"
$Asset = "zinc-windows-x86_64.zip"
$Temp = Join-Path ([System.IO.Path]::GetTempPath()) ("zinc-install-" + [System.Guid]::NewGuid().ToString("N"))

New-Item -ItemType Directory -Force -Path $Temp | Out-Null
try {
    $ArchivePath = Join-Path $Temp $Asset
    if ($Archive) {
        Copy-Item -LiteralPath $Archive -Destination $ArchivePath
    } else {
        if ((Get-Command gh -ErrorAction SilentlyContinue) -and (gh auth status 2>&1 | Out-String -Stream | Select-String "Logged in to")) {
            Write-Host "Downloading release using GitHub CLI..."
            if ($Version -eq "latest") {
                gh release download -R $Repo -p $Asset -O $ArchivePath
            } else {
                gh release download $Version -R $Repo -p $Asset -O $ArchivePath
            }
        } else {
            if ($Version -eq "latest") {
                $Url = "https://github.com/$Repo/releases/latest/download/$Asset"
            } else {
                $Url = "https://github.com/$Repo/releases/download/$Version/$Asset"
            }
            Invoke-WebRequest -Uri $Url -OutFile $ArchivePath
        }
    }

    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $Temp -Force

    $Binary = Join-Path $Temp "zn.exe"
    if (-not (Test-Path -LiteralPath $Binary)) { throw "release archive did not contain zn.exe" }

    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    Copy-Item -LiteralPath $Binary -Destination (Join-Path $InstallDir "zn.exe") -Force

    Write-Host "installed Zinc: $(Join-Path $InstallDir 'zn.exe')"
    Write-Host "add to PATH if needed: $InstallDir"
}
finally {
    Remove-Item -LiteralPath $Temp -Recurse -Force -ErrorAction SilentlyContinue
}
