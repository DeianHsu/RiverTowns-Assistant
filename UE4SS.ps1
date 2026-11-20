function Get-UE4SSArchive([string]$directory) {
    $releaseName = 'UE4SS_v4.0.0.zip'
    $releaseHash = '251ad0d1381a241750e036f5918cbf2b5d7ec58ebc608cb2dd09d459d0c81e45'
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $zip = Join-Path $directory $releaseName
    if (-not (Test-Path -LiteralPath $zip -PathType Leaf)) {
        & curl.exe --fail --silent --show-error --location --connect-timeout 12 --max-time 120 `
            --output ($zip + '.part') "https://github.com/UE4SS-RE/RE-UE4SS/releases/download/v4.0.0/$releaseName"
        if ($LASTEXITCODE -ne 0) {
            throw "下载 UE4SS 失败。请将官方 $releaseName 放到 $directory 后重试。"
        }
        Move-Item -LiteralPath ($zip + '.part') -Destination $zip
    }
    if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $releaseHash) {
        throw 'UE4SS 压缩包校验失败，请换用官方 v4.0.0 发行包。'
    }
    return $zip
}
