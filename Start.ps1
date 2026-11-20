param(
    [string]$GamePath,
    [switch]$Verify,
    [switch]$InstallSteamBridge,
    [switch]$Campaign,
    [switch]$StopCampaign,
    [switch]$SteamSave,
    [switch]$Visible,
    [switch]$Resume,
    [ValidatePattern('^run-[0-9a-f]{32}$')][string]$ReviewedRun,
    [ValidatePattern('^0[1-4]/LVL\w+$')][string]$Trial
)

$ErrorActionPreference = 'Stop'
$runtime = Join-Path $PSScriptRoot '.river-runtime'
$releaseName = 'UE4SS_v4.0.0.zip'
$releaseHash = '251ad0d1381a241750e036f5918cbf2b5d7ec58ebc608cb2dd09d459d0c81e45'
$exeName = 'EmpireBuilder-Win64-Shipping.exe'
$relativeBin = 'EmpireBuilder\Binaries\Win64'
$gameProcess = $null
$sessionDir = $null

function Find-Game {
    $roots = @(
        (Get-ItemProperty -LiteralPath 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
        (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -ErrorAction SilentlyContinue).InstallPath
        (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Valve\Steam' -ErrorAction SilentlyContinue).InstallPath
    ) | Where-Object { $_ } | Select-Object -Unique
    foreach ($steam in $roots) {
        $libraries = @($steam)
        $libraryFile = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $libraryFile -PathType Leaf) {
            $libraries += Select-String -LiteralPath $libraryFile -Pattern '^\s*"path"\s+"([^"]+)"' |
                ForEach-Object { $_.Matches[0].Groups[1].Value.Replace('\\', '\') }
        }
        foreach ($library in $libraries | Select-Object -Unique) {
            $manifest = Join-Path $library 'steamapps\appmanifest_2485350.acf'
            if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { continue }
            $installed = Select-String -LiteralPath $manifest -Pattern '^\s*"installdir"\s+"([^"]+)"'
            if ($installed) {
                $folder = Join-Path (Join-Path $library 'steamapps\common') $installed.Matches[0].Groups[1].Value
                if (Test-Path -LiteralPath (Join-Path $folder "$relativeBin\$exeName") -PathType Leaf) {
                    return $folder
                }
            }
        }
    }
}

function Get-UE4SSArchive {
    New-Item -ItemType Directory -Path $runtime -Force | Out-Null
    $zip = Join-Path $runtime $releaseName
    if (-not (Test-Path -LiteralPath $zip -PathType Leaf)) {
        & curl.exe --fail --silent --show-error --location --connect-timeout 12 --max-time 120 `
            --output ($zip + '.part') "https://github.com/UE4SS-RE/RE-UE4SS/releases/download/v4.0.0/$releaseName"
        if ($LASTEXITCODE -ne 0) {
            throw "下载 UE4SS 失败。请将官方 $releaseName 放到 $runtime 后重试。"
        }
        Move-Item -LiteralPath ($zip + '.part') -Destination $zip
    }
    if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $releaseHash) {
        throw 'UE4SS 压缩包校验失败，请换用官方 v4.0.0 发行包。'
    }
    return $zip
}

function Install-Assistant([string]$source) {
    if (-not $source -or -not (Test-Path -LiteralPath (Join-Path $source "$relativeBin\$exeName") -PathType Leaf)) {
        throw '请选择 Steam 安装的河畔小镇目录。该目录包含 EmpireBuilder.exe。'
    }
    $copy = Join-Path $runtime 'game'
    $bin = Join-Path $copy $relativeBin
    $introMovies = @('UE_moving_logo_v01_4k.mp4', 'FrogIntro_02.mp4', 'Metaroot_Logo_SplashScreen.mp4', 'StrayFawnSplash.mp4')
    New-Item -ItemType Directory -Path $copy -Force | Out-Null
    if ([IO.Path]::GetFullPath($source).TrimEnd('\') -ne [IO.Path]::GetFullPath($copy).TrimEnd('\')) {
        $excluded = @('override.txt', 'dwmapi.dll') + $introMovies
        & robocopy.exe $source $copy /E /XJ /COPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS /NP `
            /XF @excluded /XD ue4ss | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "复制游戏文件失败（Robocopy $LASTEXITCODE）。" }
    }
    # 片头视频独立输出音频，测试副本从游戏主菜单启动。
    $movies = Join-Path $copy 'EmpireBuilder\Content\Movies'
    foreach ($name in $introMovies) {
        $movie = Join-Path $movies $name
        if (Test-Path -LiteralPath $movie -PathType Leaf) {
            Move-Item -LiteralPath $movie -Destination ($movie + '.disabled') -Force
        }
    }
    $modRoot = Join-Path $bin 'ue4ss'
    if (-not (Test-Path -LiteralPath (Join-Path $modRoot 'UE4SS.dll') -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $bin 'dwmapi.dll') -PathType Leaf)) {
        Expand-Archive -LiteralPath (Get-UE4SSArchive) -DestinationPath $bin -Force
    }
    $mods = Join-Path $modRoot 'Mods'
    $scripts = Join-Path $mods 'RiverAssistant\Scripts'
    New-Item -ItemType Directory -Path $scripts -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'mod\main.lua') -Destination (Join-Path $scripts 'main.lua') -Force
    [IO.File]::WriteAllText((Join-Path $mods 'mods.txt'), "RiverAssistant : 1`r`n")
    return $bin
}

function Set-AssistantState([string]$state) {
    $file = Join-Path $script:sessionDir 'control.txt'
    [IO.File]::WriteAllText($file, ([guid]::NewGuid().ToString('N') + ' ' + $state))
}

function Get-SteamCampaignProfile {
    if (Get-Process -Name 'EmpireBuilder','EmpireBuilder-Win64-Shipping' -ErrorAction SilentlyContinue) {
        throw '河畔小镇已在运行。请退出游戏后再从 Steam 存档续打。'
    }
    $saveDir = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'AppData\Local\EmpireBuilder\Saved\SaveGames'
    if (-not (Test-Path -LiteralPath (Join-Path $saveDir 'SGSaveLevelData.sav') -PathType Leaf)) {
        throw "找不到 Steam 正式存档 $saveDir"
    }
    $profile = Join-Path $runtime 'steam-profile'
    $parent = Join-Path $profile 'Saved'
    $link = Join-Path $parent 'SaveGames'
    $existing = Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
    if ($existing) {
        if ($existing.LinkType -ne 'Junction' -or [string]$existing.Target -ne $saveDir) {
            throw "Steam 闯关目录未指向正式存档 $link"
        }
    } else {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        New-Item -ItemType Junction -Path $link -Target $saveDir | Out-Null
    }
    return $profile
}

function Start-Game([string]$source, [string]$seedSave) {
    $steamProfile = if ($SteamSave) { Get-SteamCampaignProfile }
    $bin = Install-Assistant $source
    $script:sessionDir = Join-Path $runtime ('run-' + [guid]::NewGuid().ToString('N'))
    $profile = if ($steamProfile) { $steamProfile }
        elseif ($Verify -or $Trial) { Join-Path $script:sessionDir 'profile' }
        else { Join-Path $runtime 'profile' }
    New-Item -ItemType Directory -Path $script:sessionDir,$profile -Force | Out-Null
    if ($seedSave) {
        $saveDir = Join-Path $profile 'Saved\SaveGames'
        New-Item -ItemType Directory -Path $saveDir -Force | Out-Null
        Copy-Item -LiteralPath $seedSave -Destination $saveDir
    }
    Set-AssistantState 'run'
    $env:RIVER_ASSISTANT_SESSION = $script:sessionDir
    $env:RIVER_ASSISTANT_SOURCE = Join-Path $PSScriptRoot 'mod'
    $arguments = @(
        '-NoSplash', '-windowed', '-dx11', '-NoSteam', "-UserDir=`"$profile`"",
        '"-ini:Engine:[OnlineSubsystem]:DefaultPlatformService=Null,[OnlineSubsystemSteam]:bEnabled=false"'
    )
    $arguments += @('-nosound', '-unattended', '-ResX=960', '-ResY=540')
    $windowStyle = if ($Visible) { 'Normal' } else { 'Hidden' }
    $script:gameProcess = Start-Process -FilePath (Join-Path $bin $exeName) -WorkingDirectory $bin `
        -ArgumentList $arguments -WindowStyle $windowStyle -PassThru
}

function Read-Status {
    if (-not $script:sessionDir) { return }
    $file = Join-Path $script:sessionDir 'status.tsv'
    try {
        if (Test-Path -LiteralPath $file -PathType Leaf) {
            $parts = ([IO.File]::ReadAllText($file)).TrimEnd([char[]]"`r`n") -split "`t", 8
            if ($parts.Count -eq 8) { return ,$parts }
        }
    } catch [IO.IOException] {
        return
    }
}

function Test-Assistant([string]$source) {
    Start-Game $source
    Write-Output "验证日志 $script:sessionDir"
    $deadline = [DateTime]::UtcNow.AddMinutes(6)
    while (-not $script:gameProcess.HasExited -and [DateTime]::UtcNow -lt $deadline) {
        $state = Read-Status
        if ($state -and $state[0] -eq 'blocked') { throw "闯关暂停 $($state[7])" }
        $log = Join-Path $script:sessionDir 'events.tsv'
        if (Test-Path -LiteralPath $log) {
            $lines = Get-Content -LiteralPath $log -Encoding UTF8
            $finished = @($lines | Where-Object { $_ -match '^recorded\t.*\t[1-9][0-9]*$' })
            $distinct = @($finished | ForEach-Object { ($_ -split "`t")[1] } | Sort-Object -Unique)
            if ($distinct.Count -ge 2) {
                $finished
                return
            }
        }
        Start-Sleep -Milliseconds 500
    }
    throw '验证期间未完成两关。'
}

$modes = @([bool]$Verify, [bool]$Campaign, [bool]$StopCampaign, [bool]$Trial, [bool]$InstallSteamBridge) | Where-Object { $_ }
if (@($modes).Count -gt 1 -or (($Resume -or $ReviewedRun) -and -not $Campaign)) {
    throw '请选择一种启动模式。续跑和复盘记录用于全三星模式。'
}
if ($SteamSave -and -not ($Campaign -or $StopCampaign)) {
    throw 'Steam 存档用于启动或停止全三星闯关。'
}
if ($Campaign -or $Trial -or $StopCampaign) { . (Join-Path $PSScriptRoot 'Campaign.ps1') }
if ($StopCampaign) { Request-CampaignStop; return }

$mutex = New-Object Threading.Mutex($false, 'Local\RiverTownsAssistant')
$ownsMutex = $false
try {
    try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (-not $ownsMutex) { throw '河畔小镇闯关助手已经在运行。' }
    if (-not $GamePath -and ($Campaign -or $Trial)) {
        $copy = Join-Path $runtime 'game'
        if (Test-Path -LiteralPath (Join-Path $copy "$relativeBin\$exeName") -PathType Leaf) { $GamePath = $copy }
    }
    if (-not $GamePath) { $GamePath = Find-Game }
    if ($Campaign -or $Trial) { Invoke-Campaign $GamePath }
    elseif ($Verify) { Test-Assistant $GamePath }
    else {
        . (Join-Path $PSScriptRoot 'Live.ps1')
        if ($InstallSteamBridge) { Install-SteamBridge $GamePath }
        else { Show-LiveAssistant $GamePath }
    }
} finally {
    if ($gameProcess -and -not $gameProcess.HasExited) {
        Set-AssistantState 'pause'
        [void]$gameProcess.CloseMainWindow()
        if (-not $gameProcess.WaitForExit(5000)) { $gameProcess.Kill() }
    }
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
