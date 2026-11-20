$campaignDir = Join-Path $runtime $(if ($SteamSave) { 'campaign-steam' } else { 'campaign' })
$checkpointFile = Join-Path $campaignDir 'state.json'
$stopFile = Join-Path $campaignDir 'stop'

function Write-CampaignJson([string]$path, $value) {
    $next = $path + '.next'
    [IO.File]::WriteAllText($next, ($value | ConvertTo-Json -Depth 4))
    if ([IO.File]::Exists($path)) {
        [IO.File]::Replace($next, $path, [NullString]::Value)
    } else {
        [IO.File]::Move($next, $path)
    }
}

function New-CampaignState {
    [pscustomobject]@{
        Phase = 'ready'; World = ''; Level = ''; Misses = 0; Last = 0; Run = ''; Revision = ''
        Score = 0; Best = 0; Threshold = 0; Detail = ''; Pid = 0; Started = ''
    }
}

function Request-CampaignStop {
    New-Item -ItemType Directory -Path $campaignDir -Force | Out-Null
    [IO.File]::WriteAllText($stopFile, 'stop')
    Write-Host '已请求停止全三星闯关。'
}

function Read-GameResults([string]$directory) {
    $path = Join-Path $directory 'events.tsv'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    try { $content = [IO.File]::ReadAllText($path) } catch [IO.IOException] { return }
    $pattern = '(?m)^result\t(LVL\w+)\t(\d+),(0[1-4]),(\d+),(\d+),(\d+),([0-3]),([0-3])\r?\n'
    foreach ($record in [regex]::Matches($content, $pattern)) {
        $field = $record.Groups
        [pscustomobject]@{
            Level = $field[1].Value; Number = [int]$field[2].Value; World = $field[3].Value
            Score = [int]$field[4].Value; Best = [int]$field[5].Value; Threshold = [int]$field[6].Value
            Stars = [int]$field[7].Value; BestStars = [int]$field[8].Value
        }
    }
}

function Set-CampaignResult($state, $result) {
    if ($result.Number -le $state.Last) { return }
    if ($result.Threshold -le 0 -or $result.Best -lt $result.Score -or
            (($result.Score -ge $result.Threshold) -ne ($result.Stars -eq 3)) -or
            (($result.Best -ge $result.Threshold) -ne ($result.BestStars -eq 3))) {
        throw '关卡结算与星级门槛不一致。'
    }
    if ($state.World -ne $result.World -or $state.Level -ne $result.Level) { $state.Misses = 0 }
    $state.Last = $result.Number
    $state.World, $state.Level = $result.World, $result.Level
    $state.Score, $state.Best, $state.Threshold = $result.Score, $result.Best, $result.Threshold
    if ($result.Stars -eq 3) {
        $state.Misses = 0
        return 'advance'
    }
    $state.Misses++
    if ($state.Misses -ge 2) {
        $state.Phase = 'review'
        return 'review'
    }
    return 'retry'
}

function Receive-CampaignResults($state, [string]$directory, [bool]$persist) {
    $decision = $null
    foreach ($result in Read-GameResults $directory) {
        $action = Set-CampaignResult $state $result
        if (-not $action) { continue }
        if ($persist) { Write-CampaignJson $checkpointFile $state }
        Write-Host ("{0} 本局 {1}/{2}，存档最高 {3}，连续低于三星 {4}/2" -f
            $result.Level, $result.Score, $result.Threshold, $result.Best, $state.Misses)
        $decision = $action
    }
    return $decision
}

function Close-PreviousCampaignGame($state) {
    if (-not $state.Pid) { return }
    $previous = Get-Process -Id $state.Pid -ErrorAction SilentlyContinue
    if ($previous -and $previous.StartTime.ToFileTimeUtc().ToString() -eq $state.Started) {
        [void]$previous.CloseMainWindow()
        if (-not $previous.WaitForExit(5000)) { $previous.Kill(); $previous.WaitForExit() }
    }
}

function Accept-CampaignReview($state, [string]$revision) {
    if ($state.Phase -ne 'review' -or $revision -eq $state.Revision) {
        throw '复盘续跑需要待复盘的关卡和一版新的策略。'
    }
    $directory = Join-Path $runtime $ReviewedRun
    $metadata = Get-Content -LiteralPath (Join-Path $directory 'run.json') -Raw | ConvertFrom-Json
    $gold = Read-GameResults $directory | Where-Object {
        $_.World -eq $state.World -and $_.Level -eq $state.Level -and $_.Stars -eq 3 -and
        $_.BestStars -eq 3 -and $_.Score -ge $_.Threshold -and $_.Threshold -gt 0
    } | Select-Object -First 1
    if ($metadata.Mode -ne 'trial' -or $metadata.Revision -ne $revision -or -not $gold) {
        throw '新策略需要当前关卡的隔离实机三星记录。'
    }
    $state.Misses = 0
    $state.Phase = 'ready'
    $state.Revision = $revision
    Write-CampaignJson $checkpointFile $state
}

function Invoke-Campaign([string]$source) {
    New-Item -ItemType Directory -Path $campaignDir -Force | Out-Null
    if ($Resume -and [IO.File]::Exists($stopFile)) { [IO.File]::Delete($stopFile) }
    if ([IO.File]::Exists($stopFile)) { Write-Host '全三星闯关已手动停止。'; return }

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $revision = @(foreach ($file in 'mod\main.lua', 'mod\solver.lua') {
            $content = [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot $file))
            [BitConverter]::ToString($sha.ComputeHash($content)).Replace('-', '')
        }) -join '-'
    } finally {
        $sha.Dispose()
    }
    $state = New-CampaignState
    $seed = ''
    if ($Trial) {
        $state.World, $state.Level = $Trial -split '/', 2
        $seed = Join-Path $runtime 'profile\Saved\SaveGames\SGSaveLevelData.sav'
        if (-not (Test-Path -LiteralPath $seed -PathType Leaf)) { throw '试跑需要助手关卡存档。' }
    } elseif (Test-Path -LiteralPath $checkpointFile -PathType Leaf) {
        $state = Get-Content -LiteralPath $checkpointFile -Raw | ConvertFrom-Json
        Close-PreviousCampaignGame $state
        if ($state.Run) { [void](Receive-CampaignResults $state (Join-Path $runtime $state.Run) $true) }
        if ($ReviewedRun) { Accept-CampaignReview $state $revision }
        elseif ($state.Phase -eq 'review' -and ($revision -ne $state.Revision -or ($SteamSave -and $Resume))) {
            $state.Misses = 0
            $state.Phase = 'ready'
            $state.Revision = $revision
            Write-CampaignJson $checkpointFile $state
            Write-Host ('复盘后恢复挑战 {0}。' -f $state.Level)
        }
        if ($state.Phase -eq 'review') { Write-Host ('待复盘 {0}，记录 {1}' -f $state.Level, $state.Run); return }
        if ($state.Phase -eq 'complete') { Write-Host ('全三星已确认 {0} 关。' -f $state.Detail); return }
    } elseif ($ReviewedRun) {
        throw '当前没有待复盘的闯关记录。'
    }

    if ([IO.File]::Exists($stopFile)) { Write-Host '全三星闯关已手动停止。'; return }
    $env:RIVER_ASSISTANT_MODE = if ($Trial) { 'trial' } else { 'campaign' }
    $env:RIVER_ASSISTANT_WORLD = $state.World
    $env:RIVER_ASSISTANT_TARGET = $state.Level
    $env:RIVER_ASSISTANT_MISSES = [string]$state.Misses
    $env:RIVER_ASSISTANT_STOP = $stopFile
    Start-Game $source $seed
    $state.Run = Split-Path -Leaf $script:sessionDir
    $state.Last = 0
    $state.Pid = $script:gameProcess.Id
    $state.Started = $script:gameProcess.StartTime.ToFileTimeUtc().ToString()
    $state.Phase = 'ready'
    $state.Revision = $revision
    if (-not $Trial) { Write-CampaignJson $checkpointFile $state }
    Write-CampaignJson (Join-Path $script:sessionDir 'run.json') @{ Mode = $env:RIVER_ASSISTANT_MODE; Revision = $revision; SteamSave = [bool]$SteamSave }
    Write-Host "游戏日志 $script:sessionDir"

    $lastStatus = ''
    $lastChange = [DateTime]::UtcNow
    while ($true) {
        $status = Read-Status
        $phase = if ($status) { $status[0] } else { '' }
        $signature = $status -join "`t"
        if ($signature -ne $lastStatus) {
            $lastStatus = $signature
            $lastChange = [DateTime]::UtcNow
        }
        $stopping = [IO.File]::Exists($stopFile)
        $exited = $script:gameProcess.HasExited
        $decision = $null
        if ($phase -eq 'awaiting' -or $exited -or $stopping) {
            $decision = Receive-CampaignResults $state $script:sessionDir (-not $Trial)
        }
        if ($stopping) { Write-Host '全三星闯关已手动停止。'; return }
        if ($decision -eq 'review') { Write-Host ('待复盘 {0}，记录 {1}' -f $state.Level, $state.Run); return }
        if ($Trial -and $decision -eq 'advance') { Write-Host ("试跑三星 {0}" -f $state.Run); return }
        if ($phase -eq 'finished' -and -not $Trial) {
            $state.Phase, $state.Detail = 'complete', $status[7]
            Write-CampaignJson $checkpointFile $state
            Get-Content -LiteralPath (Join-Path $script:sessionDir 'events.tsv') | Where-Object { $_ -match '^coverage\t' }
            Write-Host ('全三星已确认 {0} 关。' -f $state.Detail)
            return
        }
        if ($exited) { throw "游戏提前退出，记录 $($state.Run)" }
        if ($phase -eq 'blocked') { throw "游戏暂停 $($status[7])，记录 $($state.Run)" }
        if (([DateTime]::UtcNow - $lastChange).TotalSeconds -gt 120) { throw "两分钟内游戏状态没有变化，记录 $($state.Run)" }
        if ($decision) { Set-AssistantState $decision }
        Start-Sleep -Milliseconds 400
    }
}
