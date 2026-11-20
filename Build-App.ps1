$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'UE4SS.ps1')

$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$automation = & $powershell -NoLogo -NoProfile -NonInteractive -Command '[System.Management.Automation.PowerShell].Assembly.Location'
if ($LASTEXITCODE -ne 0) { throw '无法找到 Windows PowerShell 5.1 程序集。' }

$archive = Get-UE4SSArchive (Join-Path $PSScriptRoot '.river-runtime')
$files = @(
    'Start.ps1', 'Live.ps1', 'Campaign.ps1', 'UE4SS.ps1',
    'mod\main.lua', 'mod\live.lua', 'mod\solver.lua', 'mod\levels.tsv',
    'mod\achievements.lua', 'mod\achievements.tsv',
    (Join-Path '.river-runtime' ([IO.Path]::GetFileName($archive)))
)
$resources = $files | ForEach-Object { "/resource:$_,$_" }

$dist = Join-Path $PSScriptRoot 'dist'
New-Item -ItemType Directory -Path $dist -Force | Out-Null
$output = Join-Path $dist 'RiverTownsAssistant.exe'
Push-Location -LiteralPath $PSScriptRoot
try {
    & $compiler /nologo /target:winexe /platform:x64 /optimize+ /codepage:65001 `
        /reference:System.Windows.Forms.dll "/reference:$automation" "/out:$output" @resources 'App.cs'
    if ($LASTEXITCODE -ne 0) { throw '应用打包失败。' }
    Write-Output $output
} finally {
    Pop-Location
}
