function Get-LiveGameProcess([string]$bin) {
    if (-not $bin) { return }
    $path = Join-Path $bin $exeName
    Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($exeName)) -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $path } | Select-Object -First 1
}

function Get-LiveBridgeDirectory {
    Join-Path $runtime 'live-bridge\ue4ss'
}

function Test-LiveBridge([string]$bin) {
    if (-not $bin) { return $false }
    $directory = Get-LiveBridgeDirectory
    $override = Join-Path $bin 'override.txt'
    (Test-Path -LiteralPath (Join-Path $directory 'UE4SS.dll') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $bin 'dwmapi.dll') -PathType Leaf) -and
        (Test-Path -LiteralPath $override -PathType Leaf) -and
        ([IO.File]::ReadAllText($override, [Text.Encoding]::Default).Trim() -eq $directory)
}

function ConvertTo-LuaPath([string]$path) {
    $escaped = [Text.Encoding]::Default.GetBytes($path) | ForEach-Object { '\{0:D3}' -f $_ }
    '"' + ($escaped -join '') + '"'
}

function New-LiveBridgeRuntime([string]$bridge, [string]$session) {
    New-Item -ItemType Directory -Path $bridge,$session -Force | Out-Null
    $modRoot = Join-Path $bridge 'ue4ss'
    $proxy = Join-Path $bridge 'dwmapi.dll'
    if (-not (Test-Path -LiteralPath (Join-Path $modRoot 'UE4SS.dll') -PathType Leaf) -or
        -not (Test-Path -LiteralPath $proxy -PathType Leaf)) {
        Expand-Archive -LiteralPath (Get-UE4SSArchive) -DestinationPath $bridge -Force
    }
    $mods = Join-Path $modRoot 'Mods'
    $scripts = Join-Path $mods 'RiverTownsLive\Scripts'
    New-Item -ItemType Directory -Path $scripts -Force | Out-Null
    $sourcePath = ConvertTo-LuaPath (Join-Path $PSScriptRoot 'mod')
    $sessionPath = ConvertTo-LuaPath $session
    $bootstrap = @"
local source = $sourcePath
assert(loadfile(source .. '/main.lua'))({live = true, source = source, session = $sessionPath})
"@
    [IO.File]::WriteAllText((Join-Path $scripts 'main.lua'), $bootstrap)
    [IO.File]::WriteAllText((Join-Path $mods 'mods.txt'), "RiverTownsLive : 1`r`n")
}

function Install-SteamBridge([string]$source) {
    if (-not $source) { throw '找不到河畔小镇的 Steam 安装目录。' }
    $bin = Join-Path ([IO.Path]::GetFullPath($source)) $relativeBin
    if (-not (Test-Path -LiteralPath (Join-Path $bin $exeName) -PathType Leaf)) {
        throw '指定目录内找不到河畔小镇的游戏程序。'
    }
    if (Get-LiveGameProcess $bin) { throw '请退出 Steam 中的河畔小镇，再安装连接组件。' }
    $proxy = Join-Path $bin 'dwmapi.dll'
    $override = Join-Path $bin 'override.txt'
    $directory = Get-LiveBridgeDirectory
    $configured = if (Test-Path -LiteralPath $override -PathType Leaf) {
        [IO.File]::ReadAllText($override, [Text.Encoding]::Default).Trim()
    }
    $oldPath = Join-Path $directory 'UE4SS.dll'
    if ($configured -notin $directory,$oldPath -and
            ((Test-Path -LiteralPath $override) -or (Test-Path -LiteralPath $proxy) -or
            (Test-Path -LiteralPath (Join-Path $bin 'ue4ss')) -or (Test-Path -LiteralPath (Join-Path $bin 'UE4SS.dll')))) {
        throw 'Steam 游戏目录中已有加载组件，需要先解决加载配置冲突。'
    }
    $bridge = Join-Path $runtime 'live-bridge'
    New-LiveBridgeRuntime $bridge (Join-Path $runtime 'live')
    # UE4SS 会在 override.txt 指定的目录下查找 UE4SS.dll。
    $bytes = [Text.Encoding]::Default.GetBytes($directory)
    if ($configured -eq $oldPath) {
        [IO.File]::WriteAllBytes($override, $bytes)
    } elseif ($configured -ne $directory) {
        $file = [IO.File]::Open($override, [IO.FileMode]::CreateNew)
        try {
            $file.Write($bytes, 0, $bytes.Length)
        } finally { $file.Dispose() }
    }
    if (-not (Test-Path -LiteralPath $proxy -PathType Leaf)) {
        [IO.File]::Copy((Join-Path $bridge 'dwmapi.dll'), $proxy)
    }
    Write-Host '连接组件已安装。现在可从 Steam 打开游戏，再启动助手。'
}

function Get-LiveLevels {
    Get-Content -LiteralPath (Join-Path $PSScriptRoot 'mod\levels.tsv') -Encoding UTF8 | ForEach-Object {
        $world, $level, $label = $_ -split "`t", 3
        [pscustomobject]@{ World = $world; Level = $level; Label = $label; Display = "世界 $([int]$world) · $label" }
    }
}

function Get-LiveAchievements {
    Get-Content -LiteralPath (Join-Path $PSScriptRoot 'mod\achievements.tsv') -Encoding UTF8 | ForEach-Object {
        $id, $level, $label, $condition = $_ -split "`t", 4
        [pscustomobject]@{ Id = $id; Level = $level; Label = $label; Condition = $condition }
    }
}

function Read-LiveStatus([string]$session) {
    $path = Join-Path $session 'status.tsv'
    try {
        $updated = [IO.File]::GetLastWriteTimeUtc($path)
        $fields = [IO.File]::ReadAllText($path).TrimEnd([char[]]"`r`n") -split "`t"
        if ($fields.Count -notin 12,14 -or $fields[8] -notmatch '^\d+-[0-9a-f]+$') { return }
        [pscustomobject]@{
            Phase = $fields[0]; Level = $fields[1]; Score = $fields[2]; Remaining = $fields[3]; Cleared = $fields[4]
            Stars = $fields[5]; Threshold = $fields[6]; Detail = $fields[7]; Bridge = $fields[8]; Current = $fields[9]
            Serial = $fields[10]; Job = $fields[11]; Updated = $updated
            AchievementSupport = $fields.Count -eq 14; Achievement = $fields[12]; AchievementProgress = $fields[13]
        }
    } catch [IO.IOException] { return }
}

function New-LiveRequest([string]$bridge, [string]$action, [string]$level = '') {
    [pscustomobject]@{ Bridge = $bridge; Serial = [guid]::NewGuid().ToString('N'); Action = $action; Level = $level }
}

function Write-LiveRequest([string]$session, $request) {
    $path = Join-Path $session 'command.tsv'
    $next = $path + '.next'
    $expires = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 12
    $row = ($request.Bridge, $request.Serial, $expires, $request.Action, $request.Level) -join "`t"
    [IO.File]::WriteAllText($next, $row + "`n")
    if ([IO.File]::Exists($path)) {
        [IO.File]::Replace($next, $path, [NullString]::Value)
    } else {
        [IO.File]::Move($next, $path)
    }
}

function Show-LiveAssistant([string]$source) {
    Add-Type -AssemblyName System.Windows.Forms,System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $bin = if ($source) { Join-Path ([IO.Path]::GetFullPath($source)) $relativeBin }
    $session = Join-Path $runtime 'live'
    $levels = @(Get-LiveLevels)
    $achievements = @(Get-LiveAchievements)
    $byLevel = @{}
    foreach ($level in $levels) { $byLevel[$level.Level] = $level }
    $byAchievement = @{}
    foreach ($achievement in $achievements) { $byAchievement[$achievement.Id] = $achievement }
    $ui = [pscustomobject]@{
        GameId = $null; State = $null; Request = $null; Error = ''; Installed = (Test-LiveBridge $bin)
    }

    $form = New-Object Windows.Forms.Form
    $form.Text = '河畔小镇闯关助手'
    $form.ClientSize = New-Object Drawing.Size(568, 322)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 10)
    $form.AutoScaleMode = 'Dpi'

    $status = New-Object Windows.Forms.Label
    $status.SetBounds(20, 18, 528, 25)
    $status.Text = '正在查找 Steam 游戏'
    $status.Font = New-Object Drawing.Font($form.Font, [Drawing.FontStyle]::Bold)
    $stats = New-Object Windows.Forms.Label
    $stats.SetBounds(20, 50, 528, 42)
    $hint = New-Object Windows.Forms.Label
    $hint.SetBounds(20, 269, 528, 42)
    $setup = New-Object Windows.Forms.Button
    $setup.SetBounds(20, 273, 146, 30)
    $setup.Text = '安装连接组件'
    $setup.Visible = $false

    $first = New-Object Windows.Forms.Button
    $first.SetBounds(20, 95, 148, 36)
    $first.Text = '从头闯关'
    $current = New-Object Windows.Forms.Button
    $current.SetBounds(180, 95, 212, 36)
    $current.Text = '从当前关卡开始闯关'
    $stop = New-Object Windows.Forms.Button
    $stop.SetBounds(420, 95, 128, 36)
    $stop.Text = '停止'
    $levelsBox = New-Object Windows.Forms.ComboBox
    $levelsBox.SetBounds(20, 148, 372, 31)
    $levelsBox.DropDownStyle = 'DropDownList'
    $levelsBox.AccessibleName = '指定关卡'
    $levelsBox.Items.AddRange([object[]]$levels.Display)
    $levelsBox.SelectedIndex = 0
    $single = New-Object Windows.Forms.Button
    $single.SetBounds(420, 144, 128, 36)
    $single.Text = '闯指定关'
    $achievementBox = New-Object Windows.Forms.ComboBox
    $achievementBox.SetBounds(20, 197, 372, 31)
    $achievementBox.DropDownStyle = 'DropDownList'
    $achievementBox.AccessibleName = '指定成就'
    $achievementBox.Items.AddRange([object[]]$achievements.Label)
    $achievementBox.SelectedIndex = 0
    $challenge = New-Object Windows.Forms.Button
    $challenge.SetBounds(420, 193, 128, 36)
    $challenge.Text = '挑战成就'
    $condition = New-Object Windows.Forms.Label
    $condition.SetBounds(20, 234, 528, 32)
    $condition.Text = $achievements[0].Condition
    $achievementBox.Add_SelectedIndexChanged({
        $condition.Text = $achievements[$achievementBox.SelectedIndex].Condition
    })
    foreach ($control in @($first, $current, $stop, $levelsBox, $single, $achievementBox, $challenge)) { $control.Enabled = $false }
    $form.Controls.AddRange(@($status, $stats, $hint, $first, $current, $stop, $levelsBox, $single,
        $achievementBox, $challenge, $condition, $setup))

    $phaseLabels = @{
        idle='已连接 Steam 游戏'; ready='正在准备闯关'; loading='正在加载游戏地图'; travel='正在切换关卡'
        solving='正在自动摆放'; settling='正在等待游戏结算'; paused='已停止闯关'
        blocked='闯关已停止'; finished='闯关已完成'
    }
    $messages = @{
        'live-current-changed'='游戏已经切换关卡，请重新选择。'
        'live-target-missing'='游戏在当前地图中没有提供这关。'
        'live-target-locked'='游戏尚未解锁这关。'
        'live-gate-locked'='下一世界的门还没解锁。'
        'live-game-changed'='游戏已离开助手正在挑战的关卡。'
        'live-travel-timeout'='游戏切换关卡超时，请在游戏窗口检查当前画面。'
        'world-transition'='游戏未完成跨世界切换。'
        'placement-no-progress'='游戏未能继续摆放下一块拼块。'
        'placement-rejected'='游戏未接受候选落点。'
        'shape-unavailable'='无法读取当前拼块。'
        'settlement-timeout'='等待游戏结算超时。'
        'score-not-saved'='游戏尚未写入本关成绩。'
        'connection-lost'='助手连接中断，已停止自动摆放。'
        'two-misses'='连续两局仍未取得三星。可从当前关卡重新开始。'
        'stopped'='可以继续手动操作游戏。'
        'single'='指定关已结算。'
        'retry'='本关再试一局。'
        'achievement-earned'='游戏已触发成就的解锁判定。'
        'achievement-already-earned'='Steam 已记录这项成就。'
        'achievement-retry'='本局未达成成就条件，正在重新挑战。'
        'achievement-missed'='两局均未触发成就判定，已停在结算画面。'
        'achievement-observer-unavailable'='当前游戏版本的成就判定无法读取。'
    }
    $send = {
        param([string]$action, [string]$level = '')
        if (-not $ui.State) { return }
        $ui.Request = New-LiveRequest $ui.State.Bridge $action $level
        $ui.Error = ''
        try { Write-LiveRequest $session $ui.Request } catch [IO.IOException] { $ui.Error = '正在重试发送指令。' }
        $status.Text = if ($action -eq 'stop') { '正在停止闯关' } else { '正在发送闯关指令' }
        $first.Enabled = $current.Enabled = $single.Enabled = $levelsBox.Enabled = $achievementBox.Enabled = $challenge.Enabled = $false
        $stop.Enabled = $action -ne 'stop'
    }
    $first.Add_Click({ & $send 'first' })
    $current.Add_Click({ & $send 'current' $ui.State.Current })
    $single.Add_Click({ if ($levelsBox.SelectedIndex -ge 0) { & $send 'single' $levels[$levelsBox.SelectedIndex].Level } })
    $challenge.Add_Click({ & $send 'achievement' $achievements[$achievementBox.SelectedIndex].Id })
    $stop.Add_Click({ & $send 'stop' })
    $setup.Add_Click({
        try {
            $setup.Enabled = $false
            $status.Text = '正在安装连接组件'
            $form.Refresh()
            Install-SteamBridge $source
            $ui.Installed = $true
            $ui.Error = ''
        } catch { $ui.Error = $_.Exception.Message }
    })

    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = 650
    $timer.Add_Tick({
        $process = Get-LiveGameProcess $bin
        $started = if ($process) {
            try { $process.StartTime.ToUniversalTime() } catch { $process = $null }
        }
        $gameId = if ($started) { "$($process.Id)/$($started.Ticks)" }
        if ($gameId -ne $ui.GameId) {
            $ui.GameId, $ui.State, $ui.Request = $gameId, $null, $null
        }
        if ($gameId) {
            $latest = Read-LiveStatus $session
            if ($latest -and $latest.Updated -ge $started) { $ui.State = $latest }
        }
        $state = $ui.State
        $fresh = $state -and $state.Level -and ([DateTime]::UtcNow - $state.Updated).TotalSeconds -le 8
        if ($ui.Request -and ($ui.Request.Bridge -ne $state.Bridge -or
                ($state.Serial -eq $ui.Request.Serial -and -not $state.Job))) { $ui.Request = $null }
        if ($ui.Request) {
            try { Write-LiveRequest $session $ui.Request; $ui.Error = '' }
            catch [IO.IOException] { $ui.Error = '正在重试发送指令。' }
        }
        $active = [bool]($state -and $state.Job)
        $pending = [bool]($ui.Request -and $state.Serial -ne $ui.Request.Serial)
        $canStart = $fresh -and -not ($active -or $pending)
        $first.Enabled = $canStart
        $current.Enabled = $canStart -and [bool]$state.Current
        $single.Enabled = $canStart -and $levelsBox.SelectedIndex -ge 0
        $levelsBox.Enabled = $canStart
        $achievementBox.Enabled = $challenge.Enabled = $canStart -and $state.AchievementSupport
        $stop.Enabled = ($active -or $pending) -and -not ($ui.Request -and $ui.Request.Action -eq 'stop')
        $setup.Visible = $bin -and -not $ui.Installed -and -not $process
        $setup.Enabled = $setup.Visible

        if (-not $fresh) {
            $status.Text = if ($process) { '正在连接 Steam 游戏' } else { '等待 Steam 游戏' }
            $stats.Text = if (-not $bin) { 'Steam 尚未找到游戏。可用 -GamePath 指定安装目录。' }
                elseif (-not $ui.Installed -and $process) { '首次使用时，请退出游戏并安装连接组件。' }
                elseif (-not $ui.Installed) { '安装连接组件后，从 Steam 打开游戏。' }
                elseif ($process) { '正在等待游戏响应。游戏刚打开时可能需要几秒。' }
                else { '从 Steam 打开《河畔小镇》（River Towns）后会自动连接。' }
            $hint.Text = $ui.Error
            if ($setup.Visible) {
                if ($ui.Error) { $stats.Text += "`r`n" + $ui.Error }
                $hint.Text = ''
            }
            return
        }
        $goal = if ($state.Achievement -and $byAchievement.ContainsKey($state.Achievement)) { $byAchievement[$state.Achievement] }
        $status.Text = if ($pending) {
            if ($ui.Request.Action -eq 'stop') { '正在停止闯关' } else { '正在发送闯关指令' }
        } elseif ($goal -and $active) { "正在挑战 $($goal.Label)" }
            elseif ($goal -and $state.Phase -eq 'finished') { "成就目标已完成 · $($goal.Label)" }
            elseif ($phaseLabels.ContainsKey($state.Phase)) { $phaseLabels[$state.Phase] } else { '已连接 Steam 游戏' }
        $levelLabel = if ($state.Level -and $byLevel.ContainsKey($state.Level)) { $byLevel[$state.Level].Label }
            elseif ($state.Current -and $byLevel.ContainsKey($state.Current)) { $byLevel[$state.Current].Label }
        $stats.Text = if ($state.Threshold -and $levelLabel) {
            "$levelLabel`r`n得分 $($state.Score) / $($state.Threshold)（三星）　剩余拼块 $($state.Remaining)"
        } elseif ($levelLabel) { $levelLabel } else { '可从头闯关，或在下拉列表选择关卡。' }
        $hint.Text = if ($ui.Error) { $ui.Error }
            elseif ($goal -and $active -and $state.AchievementProgress) { $state.AchievementProgress }
            elseif ($messages.ContainsKey($state.Detail)) { $messages[$state.Detail] }
            elseif ($state.Phase -eq 'blocked') { $state.Detail }
            elseif ($goal -and $active) { $goal.Condition }
            elseif (-not $state.AchievementSupport) { '重开游戏后可使用成就挑战。' }
            elseif ($active) { "本轮已结算 $($state.Cleared) 关" }
            elseif (-not $state.Current) { '在游戏中进入关卡或在选关地图上选中关卡后，可从当前关卡开始。' }
            elseif ($state.Phase -eq 'idle' -and $state.Threshold) { '从当前关卡开始会接着摆放棋盘上的剩余拼块。' }
            else { '' }
    })
    $form.Add_FormClosing({
        $timer.Stop()
        if ($ui.State -and ($ui.State.Job -or $ui.Request)) {
            try { Write-LiveRequest $session (New-LiveRequest $ui.State.Bridge 'stop') } catch [IO.IOException] {}
        }
    })
    $timer.Start()
    [void]$form.ShowDialog()
    $timer.Dispose()
    $form.Dispose()
}
