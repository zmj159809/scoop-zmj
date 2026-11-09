<#
.SYNOPSIS
    检查 bucket 里每个软件是否有新版本，可选地就地更新清单。

.DESCRIPTION
    对 bucket/ 下的每个清单：
      1. 从 manifest 的 checkver.github 或 homepage 推出 GitHub 仓库；
      2. 查询该仓库最新的正式 Release（不含预发布）；
      3. 版本更高时打印最新版本号和 Release 链接，并询问 yes/no；
      4. 选择 yes 时改写 version / url / hash / extract_dir，并把改动追加到日志。

    查询最新版本有两种途径：
      - GitHub API（快，哈希直接取 asset digest）；
      - 网页回退（API 限流或不可用时自动启用：先读 releases/latest 的跳转，
        再退回 releases.atom），此时哈希靠下载资产本地计算。

    改写只做精确的字符串替换，不会重排或重新格式化清单；写入前会重新解析
    JSON 自检，自检不通过则放弃该文件、保持原样。

.PARAMETER BucketPath
    清单目录，默认 ../bucket。

.PARAMETER LogPath
    更新日志路径，默认 ../update-log.txt（已在 .gitignore 中忽略）。

.PARAMETER Token
    GitHub 令牌，默认读环境变量 GITHUB_TOKEN。设置后 API 限额从每小时 60 次
    提高到 5000 次，一般不需要设置。

.PARAMETER Yes
    不询问，直接更新所有有新版本的软件。

.PARAMETER CheckOnly
    只检查并提示，不改写任何文件。

.EXAMPLE
    pwsh -NoProfile -File ./scripts/check-updates.ps1

.EXAMPLE
    pwsh -NoProfile -File ./scripts/check-updates.ps1 -CheckOnly

.EXAMPLE
    $env:GITHUB_TOKEN = 'ghp_xxx'; pwsh -NoProfile -File ./scripts/check-updates.ps1
#>
#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$BucketPath = (Join-Path $PSScriptRoot '../bucket'),
    [string]$LogPath = (Join-Path $PSScriptRoot '../update-log.txt'),
    [string]$Token = $env:GITHUB_TOKEN,
    [switch]$Yes,
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:ApiHeaders = @{
    'User-Agent' = 'scoop-bucket-updater'
    'Accept'     = 'application/vnd.github+json'
}
if ($Token) { $script:ApiHeaders['Authorization'] = "Bearer $Token" }

$script:WebHeaders = @{ 'User-Agent' = 'Mozilla/5.0 scoop-bucket-updater' }
$script:ApiDisabled = $false

$script:TempDir = Join-Path ([IO.Path]::GetTempPath()) ('scoop-bucket-update-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:TempDir -Force | Out-Null

# ---------------------------------------------------------------- 工具函数

function Get-ErrorDetail {
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)

    $detail = [string]$ErrorRecord.Exception.Message
    $inner = $ErrorRecord.Exception.InnerException
    while ($inner) {
        $detail += ' / ' + $inner.Message
        $inner = $inner.InnerException
    }
    return $detail
}

function Get-StatusCode {
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)

    $response = $ErrorRecord.Exception.PSObject.Properties['Response']
    if ($response -and $response.Value) {
        $code = $response.Value.PSObject.Properties['StatusCode']
        if ($code) { return [int]$code.Value }
    }
    return $null
}

function Get-GitHubRepo {
    param([pscustomobject]$Manifest)

    $checkver = $Manifest.PSObject.Properties['checkver']
    if ($checkver -and $checkver.Value -and $checkver.Value.PSObject.Properties['github']) {
        $spec = [string]$checkver.Value.github
        if ($spec -match 'github\.com[:/]+(?<owner>[^/]+)/(?<repo>[^/#?]+)') {
            return ('{0}/{1}' -f $Matches.owner, ($Matches.repo -replace '\.git$', ''))
        }
        if ($spec -match '^(?<owner>[^/]+)/(?<repo>[^/]+)$') {
            return $spec
        }
    }

    $homepage = $Manifest.PSObject.Properties['homepage']
    if ($homepage -and ([string]$homepage.Value) -match 'github\.com[:/]+(?<owner>[^/]+)/(?<repo>[^/#?]+)') {
        return ('{0}/{1}' -f $Matches.owner, ($Matches.repo -replace '\.git$', ''))
    }

    return $null
}

function ConvertTo-VersionParts {
    param([string]$Version)

    $clean = ($Version -replace '^[vV]', '') -split '-' | Select-Object -First 1
    $parts = @()
    foreach ($piece in ($clean -split '\.')) {
        $number = 0
        if ([int]::TryParse($piece, [ref]$number)) { $parts += $number } else { $parts += 0 }
    }
    return , $parts
}

function Compare-VersionLike {
    param([string]$Left, [string]$Right)

    $a = ConvertTo-VersionParts -Version $Left
    $b = ConvertTo-VersionParts -Version $Right
    $length = [Math]::Max($a.Count, $b.Count)
    for ($i = 0; $i -lt $length; $i++) {
        $x = if ($i -lt $a.Count) { $a[$i] } else { 0 }
        $y = if ($i -lt $b.Count) { $b[$i] } else { 0 }
        if ($x -gt $y) { return 1 }
        if ($x -lt $y) { return -1 }
    }
    return 0
}

function Get-LatestRelease {
    param([string]$Repo)

    $uri = "https://api.github.com/repos/$Repo/releases/latest"
    return Invoke-RestMethod -Uri $uri -Headers $script:ApiHeaders -TimeoutSec 30
}

function Get-LatestTagFromWeb {
    param([string]$Repo)

    # 1) releases/latest 会 302 跳到 /releases/tag/<tag>，不需要 API，也不占配额
    $latestUri = "https://github.com/$Repo/releases/latest"
    try {
        $response = Invoke-WebRequest -Uri $latestUri -Headers $script:WebHeaders -MaximumRedirection 0 -SkipHttpErrorCheck -TimeoutSec 30
        $location = (@($response.Headers['Location']) -join '')
        if ($location -match '/releases/tag/(?<tag>[^/?#]+)') {
            return [uri]::UnescapeDataString($Matches.tag)
        }
        if ($response.StatusCode -eq 200) {
            $body = [string]$response.Content
            if ($body -match '/releases/tag/(?<tag>[^"''<>\s]+)') {
                return [uri]::UnescapeDataString($Matches.tag)
            }
        }
    }
    catch {
        # 落到 2) atom 源
    }

    # 2) atom 源，第一条 entry 就是最新的 release
    $atomUri = "https://github.com/$Repo/releases.atom"
    $feed = [xml]([string](Invoke-WebRequest -Uri $atomUri -Headers $script:WebHeaders -TimeoutSec 30).Content)
    $entry = @($feed.feed.entry) | Select-Object -First 1
    if (-not $entry) { throw "atom 源里没有任何 release：$atomUri" }
    foreach ($link in @($entry.link)) {
        if ($link.href -match '/releases/tag/(?<tag>[^/?#]+)') {
            return [uri]::UnescapeDataString($Matches.tag)
        }
    }
    throw "无法从 atom 源解析版本号：$atomUri"
}

function Get-AssetHash {
    param(
        [pscustomobject]$Asset,
        [string]$Url
    )

    if ($Asset) {
        $digest = [string]$Asset.digest
        if ($digest -match '^sha256:(?<hash>[0-9a-fA-F]{64})$') {
            return $Matches.hash.ToLowerInvariant()
        }
    }

    $file = Join-Path $script:TempDir ([IO.Path]::GetFileName(([uri]$Url).AbsolutePath))
    Write-Host ("  下载并计算 SHA256：{0}" -f [IO.Path]::GetFileName($file)) -ForegroundColor DarkGray
    try {
        Invoke-WebRequest -Uri $Url -OutFile $file -Headers $script:WebHeaders -TimeoutSec 900
    }
    catch {
        if ((Get-StatusCode -ErrorRecord $_) -eq 404) {
            throw "资产不存在（404）：$Url —— 上游命名可能变了，请手动更新"
        }
        throw
    }
    try {
        return (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
}

function Get-ManifestTargets {
    param([pscustomobject]$Manifest)

    $targets = @()
    $architecture = $Manifest.PSObject.Properties['architecture']
    if ($architecture -and $architecture.Value) {
        foreach ($property in $architecture.Value.PSObject.Properties) {
            $entry = $property.Value
            $targets += [pscustomobject]@{
                Arch       = $property.Name
                Urls       = @($entry.url)
                Hashes     = @($entry.hash)
                ExtractDir = [string]$entry.extract_dir
            }
        }
    }
    else {
        $extractDir = ''
        if ($Manifest.PSObject.Properties['extract_dir']) { $extractDir = [string]$Manifest.extract_dir }
        $targets += [pscustomobject]@{
            Arch       = 'default'
            Urls       = @($Manifest.url)
            Hashes     = @($Manifest.hash)
            ExtractDir = $extractDir
        }
    }
    return $targets
}

function Read-YesNo {
    param([string]$Question)

    while ($true) {
        $answer = Read-Host "$Question [yes/no]"
        switch -Regex (([string]$answer).Trim().ToLowerInvariant()) {
            '^(y|yes|是|好|确认|更新)$' { return $true }
            '^(n|no|否|不|跳过)$' { return $false }
            default { Write-Host '请输入 yes 或 no。' -ForegroundColor Yellow }
        }
    }
}

function Add-UpdateLog {
    param(
        [string]$Path,
        [string[]]$Lines
    )

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    Add-Content -LiteralPath $Path -Value $Lines -Encoding utf8
}

# ---------------------------------------------------------------- 版本查询

function Resolve-LatestVersion {
    param([string]$Repo)

    $info = [pscustomobject]@{
        Tag        = $null
        Version    = $null
        ReleaseUrl = $null
        Release    = $null
        Source     = $null
        Note       = $null
    }

    if (-not $script:ApiDisabled) {
        try {
            $release = Get-LatestRelease -Repo $Repo
            $info.Release = $release
            $info.Tag = [string]$release.tag_name
            $info.Version = $info.Tag -replace '^[vV]', ''
            $info.ReleaseUrl = [string]$release.html_url
            $info.Source = 'api'
            return $info
        }
        catch {
            $detail = Get-ErrorDetail -ErrorRecord $_
            $status = Get-StatusCode -ErrorRecord $_
            if ($status -eq 403 -or $status -eq 429) {
                $script:ApiDisabled = $true
                $info.Note = 'GitHub API 已限流（未登录每小时 60 次），本次改用网页查询；设置环境变量 GITHUB_TOKEN 可提高限额'
            }
            else {
                $info.Note = "GitHub API 不可用（$detail），改用网页查询"
            }
            Write-Host ("  {0}" -f $info.Note) -ForegroundColor DarkYellow
        }
    }

    $tag = Get-LatestTagFromWeb -Repo $Repo
    $info.Tag = $tag
    $info.Version = $tag -replace '^[vV]', ''
    $info.ReleaseUrl = "https://github.com/$Repo/releases/tag/$tag"
    $info.Source = 'web'
    return $info
}

# ---------------------------------------------------------------- 单个软件

function Invoke-ManifestCheck {
    param([System.IO.FileInfo]$File)

    $result = [pscustomobject]@{
        Name       = $File.BaseName
        Repo       = $null
        Current    = $null
        Latest     = $null
        ReleaseUrl = $null
        Status     = 'error'
        Message    = $null
    }

    $text = Get-Content -LiteralPath $File.FullName -Raw
    try {
        $manifest = $text | ConvertFrom-Json
    }
    catch {
        $result.Message = '清单不是合法 JSON：' + (Get-ErrorDetail -ErrorRecord $_)
        return $result
    }

    $result.Current = [string]$manifest.version
    $repo = Get-GitHubRepo -Manifest $manifest
    $result.Repo = $repo

    if (-not $repo) {
        $result.Status = 'skipped'
        $result.Message = '跳过：清单没有 checkver.github，homepage 也不是 GitHub 地址'
        return $result
    }

    try {
        $latestInfo = Resolve-LatestVersion -Repo $repo
    }
    catch {
        $result.Message = "查询 $repo 最新版本失败：" + (Get-ErrorDetail -ErrorRecord $_)
        return $result
    }

    $latest = $latestInfo.Version
    $result.Latest = $latest
    $result.ReleaseUrl = $latestInfo.ReleaseUrl

    if ((Compare-VersionLike -Left $latest -Right $result.Current) -le 0) {
        $result.Status = 'current'
        $result.Message = "已是最新版本 $($result.Current)"
        return $result
    }

    $result.Status = 'update-available'
    $result.Message = "$($result.Current) -> $latest"

    Write-Host ''
    Write-Host ("{0}：发现新版本 {1}（当前 {2}）" -f $File.BaseName, $latest, $result.Current) -ForegroundColor Green
    Write-Host ("  最新版本：{0}" -f $latest)
    Write-Host ("  Release ：{0}" -f $result.ReleaseUrl)

    if ($CheckOnly) {
        $result.Message = "$($result.Current) -> $latest（仅检查，未更新）"
        return $result
    }

    $shouldUpdate = $Yes.IsPresent
    if (-not $shouldUpdate) {
        $shouldUpdate = Read-YesNo -Question "是否更新 $($File.BaseName) 到 $latest？"
    }
    if (-not $shouldUpdate) {
        $result.Status = 'declined'
        $result.Message = "$($result.Current) -> $latest（你选择了否，保持原样）"
        return $result
    }

    # 逐个架构确定新资产与哈希，任何一个失败就整体放弃，避免写出半更新的清单
    $replacements = [System.Collections.Generic.List[object]]::new()
    $logLines = [System.Collections.Generic.List[string]]::new()
    $logLines.Add('=' * 68)
    $logLines.Add(("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $File.BaseName))
    $logLines.Add(("  版本    ：{0} -> {1}" -f $result.Current, $latest))
    $logLines.Add(("  Release ：{0}" -f $result.ReleaseUrl))
    $logLines.Add(("  查询方式：{0}" -f $latestInfo.Source))

    foreach ($target in (Get-ManifestTargets -Manifest $manifest)) {
        if ($target.Urls.Count -ne $target.Hashes.Count) {
            $result.Message = "架构 $($target.Arch) 的 url 与 hash 数量不一致，请手工检查"
            return $result
        }

        $logLines.Add(("  [{0}]" -f $target.Arch))

        for ($i = 0; $i -lt $target.Urls.Count; $i++) {
            $oldUrl = [string]$target.Urls[$i]
            $oldHash = [string]$target.Hashes[$i]

            if (-not $oldUrl) {
                $result.Message = "架构 $($target.Arch) 的第 $($i + 1) 个 url 为空，请手工检查"
                return $result
            }

            $fileName = [IO.Path]::GetFileName(([uri]$oldUrl).AbsolutePath)
            $newName = $fileName -replace [regex]::Escape($result.Current), $latest

            $asset = $null
            if ($latestInfo.Release -and $latestInfo.Release.assets) {
                $asset = @($latestInfo.Release.assets | Where-Object { [string]$_.name -eq $newName }) | Select-Object -First 1
                if (-not $asset) {
                    $result.Message = "新版本里找不到资产 $newName（架构 $($target.Arch)），上游命名可能变了，请手动更新"
                    return $result
                }
                $newUrl = [string]$asset.browser_download_url
            }
            else {
                $newUrl = "https://github.com/$repo/releases/download/$($latestInfo.Tag)/$newName"
            }

            try {
                $newHash = Get-AssetHash -Asset $asset -Url $newUrl
            }
            catch {
                $result.Message = "获取 $newName 的哈希失败：" + (Get-ErrorDetail -ErrorRecord $_)
                return $result
            }

            if ($newUrl -ne $oldUrl) { $replacements.Add(@{ Old = $oldUrl; New = $newUrl }) }
            if ($newHash -ne $oldHash) { $replacements.Add(@{ Old = $oldHash; New = $newHash }) }

            $logLines.Add(("    url  ：{0}" -f $oldUrl))
            $logLines.Add(("        -> {0}" -f $newUrl))
            $logLines.Add(("    hash ：{0}" -f $oldHash))
            $logLines.Add(("        -> {0}" -f $newHash))
        }

        if ($target.ExtractDir) {
            $newDir = $target.ExtractDir -replace [regex]::Escape($result.Current), $latest
            if ($newDir -ne $target.ExtractDir) {
                $replacements.Add(@{
                        Old = ('"extract_dir": "' + $target.ExtractDir + '"')
                        New = ('"extract_dir": "' + $newDir + '"')
                    })
                $logLines.Add(("    extract_dir：{0} -> {1}" -f $target.ExtractDir, $newDir))
            }
        }
    }

    $replacements.Add(@{ Old = ('"version": "' + $result.Current + '"'); New = ('"version": "' + $latest + '"') })

    $newText = $text
    foreach ($item in $replacements) {
        if (-not $newText.Contains($item.Old)) {
            $result.Message = "清单里找不到待替换的内容：$($item.Old)"
            return $result
        }
        $newText = $newText.Replace($item.Old, $item.New)
    }

    # 自检：能解析、版本正确
    try {
        $check = $newText | ConvertFrom-Json
    }
    catch {
        $result.Message = '改写后的清单不是合法 JSON，已放弃写入：' + (Get-ErrorDetail -ErrorRecord $_)
        return $result
    }
    if ([string]$check.version -ne $latest) {
        $result.Message = '改写后的 version 与目标版本不一致，已放弃写入'
        return $result
    }

    Set-Content -LiteralPath $File.FullName -Value $newText -Encoding utf8 -NoNewline

    $logLines.Add(("  结果    ：已写入 {0}" -f $File.Name))
    Add-UpdateLog -Path $LogPath -Lines $logLines.ToArray()

    $result.Status = 'updated'
    $result.Message = "$($result.Current) -> $latest（已更新，日志：$LogPath）"
    Write-Host ("  已更新 {0}，改动写入日志 {1}" -f $File.Name, $LogPath) -ForegroundColor Green
    return $result
}

# ---------------------------------------------------------------- 主流程

try {
    if (-not (Test-Path -LiteralPath $BucketPath)) {
        throw "bucket 目录不存在：$BucketPath"
    }
    $BucketPath = (Resolve-Path -LiteralPath $BucketPath).Path

    $manifests = @(Get-ChildItem -LiteralPath $BucketPath -Filter *.json -File | Sort-Object Name)
    if ($manifests.Count -eq 0) {
        Write-Host "bucket 里还没有清单：$BucketPath" -ForegroundColor Yellow
        return
    }

    Write-Host ("检查 {0} 个清单：{1}" -f $manifests.Count, $BucketPath) -ForegroundColor Cyan
    if (-not $Token) { Write-Host '未设置 GITHUB_TOKEN：API 限额每小时 60 次，超限会自动改用网页查询。' -ForegroundColor DarkGray }

    $results = @()
    foreach ($manifest in $manifests) {
        try {
            $results += Invoke-ManifestCheck -File $manifest
        }
        catch {
            Write-Host ("  {0} 检查失败：{1}" -f $manifest.BaseName, (Get-ErrorDetail -ErrorRecord $_)) -ForegroundColor Red
            $results += [pscustomobject]@{
                Name       = $manifest.BaseName
                Repo       = $null
                Current    = $null
                Latest     = $null
                ReleaseUrl = $null
                Status     = 'error'
                Message    = (Get-ErrorDetail -ErrorRecord $_)
            }
        }
    }

    Write-Host ''
    Write-Host '---------- 结果 ----------' -ForegroundColor Cyan
    foreach ($item in $results) {
        $color = switch ($item.Status) {
            'updated' { 'Green' }
            'update-available' { 'Yellow' }
            'current' { 'DarkGray' }
            'declined' { 'DarkYellow' }
            'skipped' { 'DarkGray' }
            default { 'Red' }
        }
        Write-Host ("{0,-16} {1}" -f $item.Name, $item.Message) -ForegroundColor $color
    }

    $updateCount = @($results | Where-Object { $_.Status -in @('update-available', 'updated') }).Count
    $updatedCount = @($results | Where-Object { $_.Status -eq 'updated' }).Count
    $errorCount = @($results | Where-Object { $_.Status -eq 'error' }).Count

    Write-Host ''
    if ($errorCount -gt 0) {
        Write-Host ("{0} 个清单检查失败，见上面的失败原因。" -f $errorCount) -ForegroundColor Red
    }
    if ($updateCount -eq 0) {
        if ($errorCount -eq 0) { Write-Host '全部已是最新版本。' -ForegroundColor Green }
    }
    else {
        Write-Host ("{0} 个有新版本，{1} 个已更新。" -f $updateCount, $updatedCount)
        if ($updatedCount -gt 0) {
            Write-Host '记得提交改动并推送：git add bucket && git commit -m "update manifests" && git push' -ForegroundColor Cyan
            Write-Host '本机生效：scoop update && scoop update <软件名>' -ForegroundColor Cyan
        }
    }
}
finally {
    if (Test-Path -LiteralPath $script:TempDir) {
        Remove-Item -LiteralPath $script:TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}