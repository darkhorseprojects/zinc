param(
    [string]$Version = "latest",
    [string]$InstallDir = "$env:LOCALAPPDATA\zinc\bin",
    [string]$Binary = ""
)

$ErrorActionPreference = "Stop"
$Repo = "darkhorseprojects/zinc"
$Asset = "zn-x86_64-windows.exe"
$Temp = Join-Path ([System.IO.Path]::GetTempPath()) ("zn-install-" + [System.Guid]::NewGuid().ToString("N"))

New-Item -ItemType Directory -Force -Path $Temp | Out-Null
try {
    $BinaryPath = Join-Path $Temp $Asset
    if ($Binary) {
        Copy-Item -LiteralPath $Binary -Destination $BinaryPath
    } else {
        if ((Get-Command gh -ErrorAction SilentlyContinue) -and (gh auth status 2>&1 | Out-String -Stream | Select-String "Logged in to")) {
            Write-Host "Downloading release using GitHub CLI..."
            if ($Version -eq "latest") {
                gh release download -R $Repo -p $Asset -O $BinaryPath
            } else {
                gh release download $Version -R $Repo -p $Asset -O $BinaryPath
            }
        } else {
            if ($Version -eq "latest") {
                $Url = "https://github.com/$Repo/releases/latest/download/$Asset"
            } else {
                $Url = "https://github.com/$Repo/releases/download/$Version/$Asset"
            }
            Invoke-WebRequest -Uri $Url -OutFile $BinaryPath
        }
    }

    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    Copy-Item -LiteralPath $BinaryPath -Destination (Join-Path $InstallDir "zn.exe") -Force

    Write-Host "installed zn: $(Join-Path $InstallDir 'zn.exe')"
    Write-Host "add to PATH if needed: $InstallDir"
}
finally {
    Remove-Item -LiteralPath $Temp -Recurse -Force -ErrorAction SilentlyContinue
}
