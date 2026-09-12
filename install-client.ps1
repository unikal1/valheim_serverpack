[CmdletBinding()]
param(
    [string]$ValheimPath,
    [string]$ManifestPath,
    [string]$JoinCode,
    [ValidateSet("Install", "Reset", "Check", "List")]
    [string]$Mode,
    [switch]$SkipLaunch,
    [switch]$Force,
    [switch]$CheckOnly,
    [switch]$ListOnly
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not $ManifestPath) {
    $scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $PSCommandPath }
    $ManifestPath = Join-Path $scriptRoot "manifest.json"
}

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
    Copy-Item -Path (Join-Path $Source "*") -Destination $Destination -Recurse -Force
}

function Show-ModList {
    param($Manifest)
    Write-Step "서버 모드 목록"
    Write-Host "서버: $($Manifest.server.name)"
    Write-Host "발헤임 기준 버전: $($Manifest.valheimVersion)"
    Write-Host ""
    foreach ($mod in $Manifest.mods) {
        $scope = if ($mod.requiredOnClient) { "클라이언트 필요" } else { "서버 전용" }
        Write-Host ("- {0}/{1} {2} ({3})" -f $mod.owner, $mod.name, $mod.version, $scope)
    }
}

function Read-InstallerMode {
    Write-Host ""
    Write-Host "============================================"
    Write-Host "  sang Valheim 서버 모드팩 설치기"
    Write-Host "============================================"
    Write-Host ""
    Write-Host "1. 신규 설치"
    Write-Host "   - 이미 같은 버전이 설치되어 있으면 건너뜁니다."
    Write-Host ""
    Write-Host "2. 초기화 후 설치"
    Write-Host "   - 기존 sang 모드팩을 백업한 뒤 다시 설치합니다."
    Write-Host ""
    Write-Host "3. 검사하기"
    Write-Host "   - BepInEx와 모드팩 파일이 정상 위치에 있는지 확인합니다."
    Write-Host ""
    Write-Host "4. 목록 보기"
    Write-Host "   - 서버가 요구하는 모드 목록을 표시합니다."
    Write-Host ""

    switch (Read-Host "번호를 입력하세요 [1-4]") {
        "1" { return "Install" }
        "2" { return "Reset" }
        "3" { return "Check" }
        "4" { return "List" }
        default {
            Write-Host "잘못된 번호입니다." -ForegroundColor Red
            exit 1
        }
    }
}

function Test-Serverpack {
    param(
        $Manifest,
        [string]$ValheimPath,
        [string]$PluginRoot,
        [string]$GamePlugins,
        [string]$StampPath
    )

    $ok = $true
    Write-Step "호환성 검사"
    Write-Host "Valheim: $ValheimPath"

    foreach ($file in @(
        "winhttp.dll",
        "doorstop_config.ini",
        "BepInEx\core\BepInEx.dll"
    )) {
        $path = Join-Path $ValheimPath $file
        if (Test-Path $path) {
            Write-Host "[OK] BepInEx 파일: $file" -ForegroundColor Green
        } else {
            Write-Host "[FAIL] BepInEx 파일 없음: $file" -ForegroundColor Red
            $ok = $false
        }
    }

    if (Test-Path $StampPath) {
        $current = Get-Content -LiteralPath $StampPath -Raw | ConvertFrom-Json
        $expected = @{}
        foreach ($mod in $Manifest.mods) { $expected[$mod.name] = $mod.version }
        foreach ($mod in $current.mods) {
            if ($expected.ContainsKey($mod.name) -and $expected[$mod.name] -ne $mod.version) {
                Write-Host "[FAIL] 버전 불일치: $($mod.name) installed=$($mod.version) expected=$($expected[$mod.name])" -ForegroundColor Red
                $ok = $false
            }
        }
        Write-Host "[OK] 설치 기록: $StampPath" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] 설치 기록 없음: $StampPath" -ForegroundColor Red
        $ok = $false
    }

    foreach ($mod in $Manifest.mods | Where-Object { $_.name -ne "BepInExPack_Valheim" }) {
        $dir = Join-Path $PluginRoot "$($mod.owner)-$($mod.name)-$($mod.version)"
        if (Test-Path $dir) {
            Write-Host "[OK] 모드 폴더: $($mod.name) $($mod.version)" -ForegroundColor Green
        } else {
            Write-Host "[FAIL] 모드 폴더 없음: $($mod.name) $($mod.version)" -ForegroundColor Red
            $ok = $false
        }
    }

    $badBackups = @()
    if (Test-Path $GamePlugins) {
        $badBackups = Get-ChildItem -LiteralPath $GamePlugins -Directory -Filter "sang-serverpack.backup-*" -ErrorAction SilentlyContinue
    }
    if ($badBackups.Count -gt 0) {
        Write-Host "[FAIL] plugins 폴더 안에 백업이 남아있습니다. 초기화 후 설치를 실행하세요." -ForegroundColor Red
        foreach ($backup in $badBackups) { Write-Host "       $($backup.FullName)" }
        $ok = $false
    } else {
        Write-Host "[OK] plugins 안에 잘못된 백업 없음" -ForegroundColor Green
    }

    if ($ok) {
        Write-Host ""
        Write-Host "검사 결과: 정상입니다. Steam에서 Valheim을 실행해서 접속하세요." -ForegroundColor Green
    } else {
        Write-Host ""
        Write-Host "검사 결과: 문제가 있습니다. 메뉴에서 '초기화 후 설치'를 실행하세요." -ForegroundColor Red
        exit 1
    }
}

if (-not (Test-Path $ManifestPath)) {
    throw "Manifest not found: $ManifestPath"
}

$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json

if (-not $Mode) {
    if ($ListOnly) { $Mode = "List" }
    elseif ($CheckOnly) { $Mode = "Check" }
    elseif ($Force) { $Mode = "Reset" }
    else { $Mode = Read-InstallerMode }
}

switch ($Mode) {
    "List" { $ListOnly = $true }
    "Check" { $CheckOnly = $true }
    "Reset" { $Force = $true }
}

if ($ListOnly) {
    Show-ModList $manifest
    return
}

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
$gamePlugins = Join-Path $gameBepInEx "plugins"
$pluginRoot = Join-Path $gameBepInEx "plugins\sang-serverpack"
$backupRoot = Join-Path $gameBepInEx "serverpack-backups"
$cacheRoot = Join-Path $env:TEMP "sang-valheim-serverpack"
$stampPath = Join-Path $pluginRoot ".serverpack.json"

Write-Step "Using Valheim at $ValheimPath"

if (Test-Path $gamePlugins) {
    $oldBackups = Get-ChildItem -LiteralPath $gamePlugins -Directory -Filter "sang-serverpack.backup-*" -ErrorAction SilentlyContinue
    if ($oldBackups) {
        New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
        foreach ($oldBackup in $oldBackups) {
            $target = Join-Path $backupRoot $oldBackup.Name
            if (Test-Path $target) {
                $target = Join-Path $backupRoot ($oldBackup.Name + "-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
            }
            Move-Item -LiteralPath $oldBackup.FullName -Destination $target
            Write-Host "Moved old backup out of plugins: $target"
        }
    }
}

if ($CheckOnly) {
    Test-Serverpack $manifest $ValheimPath $pluginRoot $gamePlugins $stampPath
    return
}

New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null

if ((Test-Path $stampPath) -and -not $Force) {
    $current = Get-Content -LiteralPath $stampPath -Raw
    $desired = $manifest | ConvertTo-Json -Depth 10
    if ($current.Trim() -eq $desired.Trim()) {
        Write-Host "Serverpack is already installed. Use -Force to reinstall."
        Write-Host "Start Valheim from Steam when you are ready to play."
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
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    $backup = Join-Path $backupRoot ("sang-serverpack.backup-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
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
Write-Host "BepInEx files: $ValheimPath"
Write-Host "Serverpack plugins: $pluginRoot"
Write-Host "Backups: $backupRoot"
if ($JoinCode) {
    Write-Host "Join code: $JoinCode"
} else {
    Write-Host "Join code: ask the server host for the current private code."
}
Write-Host ""
Write-Host "Valheim does not expose a supported command-line way to pre-add a Join Code favorite."
Write-Host "Open Valheim, choose Join Game, then Join Code, and enter the private code from the server host."
Write-Host "Start Valheim from Steam when you are ready to play."
