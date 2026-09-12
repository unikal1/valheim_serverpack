[CmdletBinding()]
param(
    [string]$ValheimPath,
    [string]$ManifestPath = "$PSScriptRoot\manifest.json",
    [string]$JoinCode,
    [switch]$SkipLaunch,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Get-SteamPath {
    $candidates = @()
    foreach ($key in @(
        "HKCU:\Software\Valve\Steam",
        "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam",
        "HKLM:\SOFTWARE\Valve\Steam"
    )) {
        try {
            $value = (Get-ItemProperty -Path $key -ErrorAction Stop).SteamPath
            if ($value) { $candidates += $value }
        } catch {}
    }
    $candidates += @(
        "$env:ProgramFiles(x86)\Steam",
        "$env:ProgramFiles\Steam"
    )
    $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
}

function Get-LibraryFolders {
    param([string]$SteamPath)
    $folders = New-Object System.Collections.Generic.List[string]
    $folders.Add($SteamPath)
    $vdf = Join-Path $SteamPath "steamapps\libraryfolders.vdf"
    if (Test-Path $vdf) {
        $content = Get-Content -LiteralPath $vdf -Raw
        foreach ($match in [regex]::Matches($content, '"path"\s+"([^"]+)"')) {
            $folders.Add(($match.Groups[1].Value -replace "\\\\", "\"))
        }
    }
    $folders | Select-Object -Unique
}

function Find-ValheimPath {
    $steam = Get-SteamPath
    if (-not $steam) {
        throw "Steam installation was not found. Pass -ValheimPath 'C:\...\Valheim' manually."
    }

    foreach ($library in Get-LibraryFolders -SteamPath $steam) {
        $candidate = Join-Path $library "steamapps\common\Valheim"
        if (Test-Path (Join-Path $candidate "valheim.exe")) {
            return (Resolve-Path $candidate).Path
        }
    }

    throw "Valheim was not found in Steam libraries. Pass -ValheimPath manually."
}

function Invoke-Download {
    param(
        [string]$Url,
        [string]$OutFile
    )
    try {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
    } catch {
        & curl.exe --ssl-no-revoke -L $Url -o $OutFile
        if ($LASTEXITCODE -ne 0) {
            throw "Download failed: $Url"
        }
    }
}

function Expand-ZipNormalized {
    param(
        [string]$ZipPath,
        [string]$Destination
    )
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Destination | Out-Null

    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName.Replace("\", "/")
            if ([string]::IsNullOrWhiteSpace($name) -or $name.EndsWith("/")) { continue }
            $target = Join-Path $Destination $name
            $targetDir = Split-Path -Parent $target
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        }
    } finally {
        $archive.Dispose()
    }
}

function Sync-Directory {
    param(
        [string]$Source,
        [string]$Destination
    )
    if (-not (Test-Path $Source)) { return }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $Source "*") -Destination $Destination -Recurse -Force
}

if (-not (Test-Path $ManifestPath)) {
    throw "Manifest not found: $ManifestPath"
}

$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
if (-not $ValheimPath) {
    Write-Step "Finding Steam Valheim installation"
    $ValheimPath = Find-ValheimPath
}
$ValheimPath = (Resolve-Path $ValheimPath).Path
$valheimExe = Join-Path $ValheimPath "valheim.exe"
if (-not (Test-Path $valheimExe)) {
    throw "valheim.exe not found under $ValheimPath"
}

$gameBepInEx = Join-Path $ValheimPath "BepInEx"
$pluginRoot = Join-Path $gameBepInEx "plugins\sang-serverpack"
$cacheRoot = Join-Path $env:TEMP "sang-valheim-serverpack"
$stampPath = Join-Path $pluginRoot ".serverpack.json"

Write-Step "Using Valheim at $ValheimPath"
New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null

if ((Test-Path $stampPath) -and -not $Force) {
    $current = Get-Content -LiteralPath $stampPath -Raw
    $desired = $manifest | ConvertTo-Json -Depth 10
    if ($current.Trim() -eq $desired.Trim()) {
        Write-Host "Serverpack is already installed. Use -Force to reinstall."
        if (-not $SkipLaunch) {
            Start-Process "steam://rungameid/892970"
        }
        return
    }
}

Write-Step "Installing BepInExPack"
$bep = $manifest.mods | Where-Object { $_.name -eq "BepInExPack_Valheim" } | Select-Object -First 1
if (-not $bep) { throw "BepInExPack_Valheim is missing from manifest.json." }
$bepZip = Join-Path $cacheRoot "$($bep.owner)-$($bep.name)-$($bep.version).zip"
$bepExtract = Join-Path $cacheRoot "bepinex"
Invoke-Download "https://thunderstore.io/package/download/$($bep.owner)/$($bep.name)/$($bep.version)/" $bepZip
Expand-ZipNormalized $bepZip $bepExtract

$bepPackRoot = Join-Path $bepExtract "BepInExPack_Valheim"
if (Test-Path $bepPackRoot) {
    Sync-Directory $bepPackRoot $ValheimPath
} else {
    Sync-Directory $bepExtract $ValheimPath
}

Write-Step "Installing serverpack plugins"
if (Test-Path $pluginRoot) {
    $backup = Join-Path $gameBepInEx ("plugins\sang-serverpack.backup-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
    Move-Item -LiteralPath $pluginRoot -Destination $backup
    Write-Host "Existing serverpack moved to $backup"
}
New-Item -ItemType Directory -Path $pluginRoot -Force | Out-Null

foreach ($mod in $manifest.mods | Where-Object { $_.name -ne "BepInExPack_Valheim" }) {
    $zip = Join-Path $cacheRoot "$($mod.owner)-$($mod.name)-$($mod.version).zip"
    $extract = Join-Path $cacheRoot "$($mod.owner)-$($mod.name)-$($mod.version)"
    $dest = Join-Path $pluginRoot "$($mod.owner)-$($mod.name)-$($mod.version)"
    $url = "https://thunderstore.io/package/download/$($mod.owner)/$($mod.name)/$($mod.version)/"
    Write-Host "Installing $($mod.owner)-$($mod.name)-$($mod.version)"
    Invoke-Download $url $zip
    Expand-ZipNormalized $zip $extract
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    foreach ($child in Get-ChildItem -LiteralPath $extract -Force) {
        if ($child.Name -in @("manifest.json", "README.md", "README", "icon.png", "CHANGELOG.md")) { continue }
        Copy-Item -LiteralPath $child.FullName -Destination $dest -Recurse -Force
    }
}

($manifest | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $stampPath -Encoding UTF8

Write-Step "Installed"
Write-Host "Server: $($manifest.server.name)"
if ($JoinCode) {
    Write-Host "Join code: $JoinCode"
} else {
    Write-Host "Join code: ask the server host for the current private code."
}
Write-Host ""
Write-Host "Valheim does not expose a supported command-line way to pre-add a Join Code favorite."
Write-Host "Open Valheim, choose Join Game, then Join Code, and enter the private code from the server host."

if (-not $SkipLaunch) {
    Write-Step "Launching Valheim"
    Start-Process "steam://rungameid/892970"
}
