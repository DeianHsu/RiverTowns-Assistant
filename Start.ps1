param(
    [string]$GamePath,
    [switch]$Verify,
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

function Install-Assistant([string]$source) {
    if (-not $source -or -not (Test-Path -LiteralPath (Join-Path $source "$relativeBin\$exeName") -PathType Leaf)) {
        throw '请选择 Steam 安装的河畔小镇目录。该目录包含 EmpireBuilder.exe。'
    }
    $copy = Join-Path $runtime 'game'
    $bin = Join-Path $copy $relativeBin
    New-Item -ItemType Directory -Path $copy -Force | Out-Null
    if ([IO.Path]::GetFullPath($source).TrimEnd('\') -ne [IO.Path]::GetFullPath($copy).TrimEnd('\')) {
        & robocopy.exe $source $copy /E /XJ /COPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "复制游戏文件失败（Robocopy $LASTEXITCODE）。" }
    }
    $modRoot = Join-Path $bin 'ue4ss'
    if (-not (Test-Path -LiteralPath (Join-Path $modRoot 'UE4SS.dll') -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $bin 'dwmapi.dll') -PathType Leaf)) {
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
        Expand-Archive -LiteralPath $zip -DestinationPath $bin -Force
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
    if ($Verify -or $Campaign -or $Trial) {
        $arguments += @('-nosound', '-unattended', '-ResX=960', '-ResY=540')
        $windowStyle = if ($Visible) { 'Normal' } else { 'Hidden' }
        $script:gameProcess = Start-Process -FilePath (Join-Path $bin $exeName) -WorkingDirectory $bin `
            -ArgumentList $arguments -WindowStyle $windowStyle -PassThru
    } else {
        $script:gameProcess = Start-Process -FilePath (Join-Path $bin $exeName) -WorkingDirectory $bin `
            -ArgumentList $arguments -PassThru
    }
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

function Show-Assistant([string]$source) {
    Add-Type -AssemblyName System.Windows.Forms,System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $form = New-Object Windows.Forms.Form
    $form.Text = '河畔小镇闯关助手'
    $form.ClientSize = New-Object Drawing.Size(520, 240)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 10)
    $form.AutoScaleMode = 'Dpi'

    $status = New-Object Windows.Forms.Label
    $status.SetBounds(24, 24, 472, 28)
    $status.Text = '准备启动本地闯关'

    $stats = New-Object Windows.Forms.Label
    $stats.SetBounds(24, 66, 472, 45)
    $stats.Text = '通过游戏内部接口读取棋盘和结算。'

    $location = New-Object Windows.Forms.Label
    $location.SetBounds(24, 118, 472, 36)
    $location.Text = '本地副本使用独立存档。'

    $start = New-Object Windows.Forms.Button
    $start.SetBounds(24, 172, 138, 38)
    $start.Text = '启动闯关'
    $pause = New-Object Windows.Forms.Button
    $pause.SetBounds(176, 172, 138, 38)
    $pause.Text = '暂停'
    $pause.Enabled = $false

    $form.Controls.AddRange(@($status, $stats, $location, $start, $pause))
    $form.AcceptButton = $start
    $labels = @{
        waiting='正在连接游戏'; ready='准备闯关'; loading='正在加载关卡'; travel='正在切换关卡'
        solving='正在求解与摆放'; settling='正在等待结算'; paused='已暂停'
        blocked='已暂停，游戏需要检查'; finished='战役已完成'
    }
    $reasons = @{
        'gate-locked'='已用完当前可玩关卡的补分次数，世界门仍未解锁。'
        'world-transition'='世界门已解锁，游戏未完成跨世界转场。'
        'shape-unavailable'='无法从游戏读取当前拼块。'
        'placement-no-progress'='摆放后游戏未推进到下一块。'
        'placement-rejected'='游戏未接受候选落点。'
        'settlement-timeout'='等待结算超时。'
        'score-not-saved'='游戏尚未写入本关成绩。'
    }
    $activities = @{
        'read-save'='读取助手存档'
        'upgrade'='补刷已通关的低星关卡'
        'new-level'='挑战尚未通关的关卡'
        'retry'='换一种摆法重试'
        'gate-retry'='为解锁世界门补星'
    }

    $start.Add_Click({
        try {
            $selected = $source
            if (-not $selected) {
                $picker = New-Object Windows.Forms.FolderBrowserDialog
                $picker.Description = '选择河畔小镇安装目录'
                if ($picker.ShowDialog($form) -ne 'OK') { return }
                $selected = $picker.SelectedPath
            }
            $start.Enabled = $false
            $status.Text = '正在准备本地副本'
            $form.Refresh()
            Start-Game $selected
            $status.Text = '正在连接游戏'
            $pause.Text = '暂停'
            $pause.Enabled = $true
            $timer.Start()
        } catch {
            $status.Text = '启动失败'
            $location.Text = $_.Exception.Message
            $start.Enabled = $true
        }
    })
    $pause.Add_Click({
        if ($pause.Text -eq '继续') {
            Set-AssistantState 'run'
            $pause.Text = '暂停'
        } else {
            Set-AssistantState 'pause'
            $pause.Text = '继续'
        }
    })
    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = 400
    $timer.Add_Tick({
        if ($script:gameProcess.HasExited) {
            $timer.Stop()
            $status.Text = '游戏已退出'
            $pause.Enabled = $false
            $start.Enabled = $true
            return
        }
        $state = Read-Status
        if (-not $state) { return }
        $status.Text = $labels[$state[0]]
        $stats.Text = if ($state[6]) {
            ('关卡 {0}' -f $state[1]) + "`r`n" +
                ('得分 {0} / {1}（三星）    当前 {2} 星    剩余拼块 {3}' -f $state[2], $state[6], $state[5], $state[3])
        } else {
            '关卡 {0}' -f $state[1]
        }
        $location.Text = if ($state[0] -eq 'blocked') {
            if ($reasons.ContainsKey($state[7])) { $reasons[$state[7]] } else { $state[7] }
        } elseif ($activities.ContainsKey($state[7])) {
            "$($activities[$state[7]])    本轮已结算 $($state[4]) 关"
        } else { "本轮已结算 $($state[4]) 关" }
        $pause.Text = if ($state[0] -in 'blocked','paused') { '继续' } else { '暂停' }
        if ($state[0] -eq 'finished') { $pause.Enabled = $false }
    })
    [void]$form.ShowDialog()
    $timer.Dispose()
    $form.Dispose()
}

$modes = @([bool]$Verify, [bool]$Campaign, [bool]$StopCampaign, [bool]$Trial) | Where-Object { $_ }
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
    else { Show-Assistant $GamePath }
} finally {
    if ($gameProcess -and -not $gameProcess.HasExited) {
        Set-AssistantState 'pause'
        [void]$gameProcess.CloseMainWindow()
        if (($Verify -or $Campaign -or $Trial) -and -not $gameProcess.WaitForExit(5000)) { $gameProcess.Kill() }
    }
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
