$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$runtime = Join-Path (Join-Path $root '.river-runtime') ('checkpoint-test-' + [guid]::NewGuid().ToString('N'))
. (Join-Path $root 'Campaign.ps1')

function Assert-Value($actual, $expected, [string]$scenario) {
    if ($actual -ne $expected) { throw "$scenario expected [$expected], received [$actual]" }
}

$world = '02'
$level = 'LVL04_Geyser'
$result = [pscustomobject]@{ World = $world; Level = $level; Number = 1
    Score = 345; Best = 345; Threshold = 350; Stars = 2; BestStars = 2 }
$state = New-CampaignState
Assert-Value (Set-CampaignResult $state $result) 'retry' 'First miss'
Assert-Value (Set-CampaignResult $state $result) $null 'Duplicate result'
Assert-Value $state.Misses 1 'Duplicate preserves count'

$run = 'run-00000000000000000000000000000001'
$directory = Join-Path $runtime $run
$events = Join-Path $directory 'events.tsv'
$metadata = Join-Path $directory 'run.json'
try {
    New-Item -ItemType Directory -Path $campaignDir,$directory -Force | Out-Null
    Write-CampaignJson $checkpointFile $state
    $state = Get-Content -LiteralPath $checkpointFile -Raw | ConvertFrom-Json
    Assert-Value $state.Misses 1 'Restart preserves count'
    [IO.File]::WriteAllText($events, "result`t$level`t2,02,0,345,350,0,2")
    Assert-Value @(Read-GameResults $directory).Count 0 'Incomplete result'
    [IO.File]::AppendAllText($events, "`n")
    Assert-Value (Receive-CampaignResults $state $directory $true) 'review' 'Two misses after restart'
    Assert-Value $state.Misses 2 'Zero-score settlement counts'
    Assert-Value $state.Best 345 'Historical best survives a miss'

    $ReviewedRun = $run
    $state.Revision = 'baseline'
    Write-CampaignJson $metadata @{ Mode = 'trial'; Revision = 'candidate' }
    $rejected = $false
    try { Accept-CampaignReview $state 'candidate' } catch { $rejected = $true }
    Assert-Value $rejected $true 'Trial below three stars blocks promotion'
    [IO.File]::AppendAllText($events, "result`t$level`t3,02,358,358,350,3,3`n")
    Accept-CampaignReview $state 'candidate'
    Assert-Value $state.Misses 0 'Promotion starts another pair'
    Assert-Value $state.Level $level 'Promotion retains the target'
    Assert-Value $state.Phase 'ready' 'Promotion allows restart'

    Assert-Value (Set-CampaignResult $state (Read-GameResults $directory | Select-Object -Last 1)) 'advance' 'Three stars advance'
    Assert-Value $state.Misses 0 'Three stars clear the failure streak'
    Request-CampaignStop
    Assert-Value ([IO.File]::Exists($stopFile)) $true 'Stop is persistent'
    Write-Output 'Campaign checkpoint tests passed.'
} finally {
    foreach ($path in $events,$metadata,$checkpointFile,$stopFile,$directory,$campaignDir,$runtime) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
    }
}
