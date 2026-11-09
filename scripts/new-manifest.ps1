<#
.SYNOPSIS
    输入一个 GitHub 仓库地址，自动生成 Scoop 清单到 bucket/。

.DESCRIPTION
    1. 解析仓库地址（支持完整 URL、owner/repo、带 .git 后缀）；
    2. 查询最新正式 Release（API 优先，限流时自动改用网页），取版本号、说明、许可证；
    3. 从发布资产里挑出 Windows 平台的安装包，按文件名识别 64bit / arm64 / 32bit；
    4. 下载选中资产、计算 SHA256，并列出压缩包内容，推断 extract_dir 和 bin；
    5. 生成 JSON 清单写入 bucket/<名称>.json，然后跑一遍 validate.ps1。

    推断不出来的部分（比如 bin 有多个候选、7z 无法查看内容）会打印出来，
    请用 -Bin / -ExtractDir 手工指定，或生成后直接改文件。

.PARAMETER RepoUrl
    GitHub 仓库地址，例如 https://github.com/unixwin/niubash。

.PARAMETER BucketPath
    清单目录，默认 ../bucket。

.PARAMETER Name
    清单文件名（不含 .json），默认取仓库名。

.PARAMETER Version
    指定版本（tag），例如 1.5.0、v1.5.0；默认取最新正式版本。
    上游 tag 带前缀（如 niubash-v1.5.0）时也能匹配上。

.PARAMETER Bin
    手工指定要加入 PATH 的程序，默认自动推断。

.PARAMETER ExtractDir
    手工指定压缩包内的子目录，默认自动推断。

.PARAMETER Token
    GitHub 令牌，默认读环境变量 GITHUB_TOKEN，一般不需要。

.PARAMETER Prerelease
    允许生成预发布版本。

.PARAMETER Force
    清单已存在时覆盖。

.PARAMETER DryRun
    只打印生成的清单，不写文件。

.PARAMETER NoHash
    不下载资产（因此不做哈希和结构检查），只按命名规则生成骨架。

.EXAMPLE
    pwsh -NoProfile -File ./scripts/new-manifest.ps1 https://github.com/unixwin/niubash

.EXAMPLE
    pwsh -NoProfile -File ./scripts/new-manifest.ps1 https://github.com/unixwin/niubash -Version 1.4.2

.EXAMPLE
    pwsh -NoProfile -File ./scripts/new-manifest.ps1 BurntSushi/ripgrep -Name ripgrep -DryRun

.EXAMPLE
    pwsh -NoProfile -File ./scripts/new-manifest.ps1 https://github.com/owner/app -Bin app.exe -ExtractDir app-1.2.3
#>
#Requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$RepoUrl,

    [string]$BucketPath = (Join-Path $PSScriptRoot '../bucket'),
    [string]$Name,
    [string]$Version,
    [string]$Bin,
    [string]$ExtractDir,
    [string]$Token = $env:GITHUB_TOKEN,
    [switch]$Prerelease,
    [switch]$Force,
    [switch]$DryRun,
    [switch]$NoHash
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:ApiHeaders = @{
    'User-Agent' = 'scoop-bucket-manifest'
    'Accept'     = 'application/vnd.github+json'
}
if ($Token) { $script:ApiHeaders['Authorization'] = "Bearer $Token" }

$script:WebHeaders = @{ 'User-Agent' = 'Mozilla/5.0 scoop-bucket-manifest' }
$script:ApiDisabled = $false

$script:TempDir = Join-Path ([IO.Path]::GetTempPath()) ('scoop-bucket-manifest-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:TempDir -Force | Out-Null

$script:ArchiveExtensions = @(
    '.tar.gz', '.tar.bz2', '.tar.xz', '.tgz', '.zip', '.7z', '.exe', '.msi'
)

# ---------------------------------------------------------------- 基础工具

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

function ConvertFrom-GitHubUrl {
    param([string]$Value)

    if (-not $Value) { return $null }
    $text = $Value.Trim()

    if ($text -match '^(?<owner>[A-Za-z0-9_.-]+)/(?<repo>[A-Za-z0-9_.-]+)$') {
        return ('{0}/{1}' -f $Matches.owner, ($Matches.repo -replace '\.git$', ''))
    }
    if ($text -match 'github\.com[:/]+(?<owner>[^/]+)/(?<repo>[^/?#]+?)(?:\.git)?(?:[/?#].*)?$') {
        return ('{0}/{1}' -f $Matches.owner, $Matches.repo)
    }
    return $null
}

function Get-ArchFromText {
    param([string]$Text)

    $value = $Text.ToLowerInvariant()
    if ($value -match 'arm64|aarch64') { return 'arm64' }
    if ($value -match 'x86_64|x64|amd64|win64|64bit|64-bit') { return '64bit' }
    if ($value -match 'x86|i386|i686|win32|32bit|32-bit') { return '32bit' }
    return $null
}

function Test-IsWindowsAsset {
    param([string]$Name)

    $value = $Name.ToLowerInvariant()

    foreach ($pattern in @('darwin', 'macos', 'osx', 'apple', 'linux', 'freebsd', 'android', '\.deb$', '\.rpm$', '\.appimage$', '\.dmg$', '\.pkg$', '\.apk$', '\.jar$')) {
        if ($value -match $pattern) { return $false }
    }
    foreach ($pattern in @('\.sha256$', '\.sha512$', '\.sha1$', '\.md5$', '\.sig$', '\.asc$', '\.txt$', '\.json$', '\.yml$', '\.yaml$', '\.blockmap$', '\.pdb$', '\.symbols?$', '^checksums?', '^shasums?')) {
        if ($value -match $pattern) { return $false }
    }
    foreach ($extension in $script:ArchiveExtensions) {
        if ($value.EndsWith($extension)) { return $true }
    }
    return $false
}

function Get-AssetScore {
    param([string]$Name)

    $value = $Name.ToLowerInvariant()
    $score = 0

    if ($value.EndsWith('.zip')) { $score = 10 }
    elseif ($value.EndsWith('.7z')) { $score = 20 }
    elseif ($value.EndsWith('.tar.gz') -or $value.EndsWith('.tgz') -or $value.EndsWith('.tar.bz2') -or $value.EndsWith('.tar.xz')) { $score = 30 }
    elseif ($value.EndsWith('.exe')) { $score = 40 }
    elseif ($value.EndsWith('.msi')) { $score = 50 }
    else { $score = 90 }

    if ($value -match 'portable|standalone|static|full') { $score -= 2 }
    if ($value -match 'installer|setup') { $score += 5 }
    if ($value -match 'win|windows') { $score -= 1 }

    return $score
}

# ---------------------------------------------------------------- 查询 Release

function Get-LatestTagFromWeb {
    param([string]$Repo)

    $latestUri = "https://github.com/$Repo/releases/latest"
    $status = $null
    try {
        $response = Invoke-WebRequest -Uri $latestUri -Headers $script:WebHeaders -MaximumRedirection 0 -SkipHttpErrorCheck -TimeoutSec 30
        $status = $response.StatusCode
        $location = (@($response.Headers['Location']) -join '')
        if ($location -match '/releases/tag/(?<tag>[^/?#]+)') {
            return [uri]::UnescapeDataString($Matches.tag)
        }
        if ($status -eq 200) {
            $body = [string]$response.Content
            if ($body -match '/releases/tag/(?<tag>[^"''<>\s]+)') {
                return [uri]::UnescapeDataString($Matches.tag)
            }
        }
    }
    catch {
        # 落到 atom 源
    }

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

function Get-AssetsFromWeb {
    param(
        [string]$Repo,
        [string]$Tag
    )

    $uri = "https://github.com/$Repo/releases/expanded_assets/$Tag"
    $html = [string](Invoke-WebRequest -Uri $uri -Headers $script:WebHeaders -TimeoutSec 30).Content

    $assets = @()
    $pattern = '/releases/download/(?<tag>[^"/]+)/(?<file>[^"]+)"'
    foreach ($match in [regex]::Matches($html, $pattern)) {
        $file = [uri]::UnescapeDataString($match.Groups['file'].Value)
        $assets += [pscustomobject]@{
            name                 = $file
            browser_download_url = "https://github.com/$Repo/releases/download/$Tag/$file"
            digest               = $null
        }
    }
    return @($assets | Sort-Object name -Unique)
}

function Get-RepositoryInfo {
    param([string]$Repo)

    if ($script:ApiDisabled) { return $null }
    try {
        return Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo" -Headers $script:ApiHeaders -TimeoutSec 30
    }
    catch {
        $status = Get-StatusCode -ErrorRecord $_
        if ($status -eq 403 -or $status -eq 429) { $script:ApiDisabled = $true }
        return $null
    }
}

function ConvertTo-VersionFromTag {
    param([string]$Tag)

    $value = ([string]$Tag).Trim()
    if (-not $value) { return $null }

    # 上游 tag 常带前缀：niubash-v1.5.0 -> 1.5.0，v1.5.0 -> 1.5.0，release-2024 -> 2024
    if ($value -match '(?<version>\d+(?:\.\d+)*(?:[-+][0-9A-Za-z.-]+)?)$') {
        return $Matches.version
    }
    return ($value -replace '^[vV]', '')
}

function Get-BasicTagCandidates {
    param([string]$Tag)

    $value = $Tag.Trim()
    $candidates = @($value)
    if ($value -match '^[vV]') { $candidates += ($value -replace '^[vV]', '') }
    else { $candidates += "v$value" }
    return @($candidates | Where-Object { $_ } | Select-Object -Unique)
}

function Get-AvailableTags {
    param([string]$Repo)

    if (-not $script:ApiDisabled) {
        try {
            $releases = @(Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases?per_page=15" -Headers $script:ApiHeaders -TimeoutSec 30)
            $tags = @($releases | ForEach-Object { [string]$_.tag_name } | Where-Object { $_ })
            if ($tags.Count -gt 0) { return $tags }
        }
        catch {
            if ((Get-StatusCode -ErrorRecord $_) -eq 403) { $script:ApiDisabled = $true }
        }
    }

    try {
        $feed = [xml]([string](Invoke-WebRequest -Uri "https://github.com/$Repo/releases.atom" -Headers $script:WebHeaders -TimeoutSec 30).Content)
        return @($feed.feed.entry | ForEach-Object { [string]$_.title } | Where-Object { $_ })
    }
    catch {
        return @()
    }
}

function Get-TagCandidates {
    param(
        [string]$Repo,
        [string]$Tag
    )

    $candidates = @(Get-BasicTagCandidates -Tag $Tag)
    if ($Tag -notmatch '^[vV]?\d') { return $candidates }

    # 上游常见命名是 niubash-v1.5.0 这种带前缀的，版本号本身匹配不上时按后缀模糊找一次
    $version = $Tag -replace '^[vV]', ''
    $available = @(Get-AvailableTags -Repo $Repo)
    if ($available.Count -eq 0) { return $candidates }

    $pattern = '(?:^|[^0-9.])[vV]?' + [regex]::Escape($version) + '$'
    $alias = $available | Where-Object { $_ -match $pattern } | Select-Object -First 1
    if ($alias) { $candidates += $alias }
    return @($candidates | Select-Object -Unique)
}

function Get-ReleaseByTag {
    param(
        [string]$Repo,
        [string[]]$Tags
    )

    foreach ($tag in $Tags) {
        $uri = "https://api.github.com/repos/$Repo/releases/tags/" + [uri]::EscapeDataString($tag)
        try {
            return Invoke-RestMethod -Uri $uri -Headers $script:ApiHeaders -TimeoutSec 30
        }
        catch {
            if ((Get-StatusCode -ErrorRecord $_) -ne 404) { throw }
        }
    }
    return $null
}

function Resolve-Release {
    param(
        [string]$Repo,
        [string]$Tag
    )

    $info = [pscustomobject]@{
        Repo        = $Repo
        Tag         = $null
        Version     = $null
        ReleaseUrl  = $null
        Assets      = @()
        Description = $null
        License     = $null
        Homepage    = $null
        Source      = $null
    }

    $repository = Get-RepositoryInfo -Repo $Repo
    if ($repository) {
        if ($repository.PSObject.Properties['description']) { $info.Description = [string]$repository.description }
        if ($repository.license -and $repository.license.PSObject.Properties['spdx_id']) {
            $spdx = [string]$repository.license.spdx_id
            if ($spdx -and $spdx -ne 'NOASSERTION') { $info.License = $spdx }
        }
        if ($repository.PSObject.Properties['homepage'] -and $repository.homepage) { $info.Homepage = [string]$repository.homepage }
    }

    $requested = $Tag
    $candidates = @()
    if ($requested) { $candidates = @(Get-TagCandidates -Repo $Repo -Tag $requested) }

    if (-not $script:ApiDisabled) {
        try {
            if ($requested) {
                $release = Get-ReleaseByTag -Repo $Repo -Tags $candidates
                if (-not $release) {
                    Write-Host ("  API 里没有版本 {0}，改用网页确认" -f $requested) -ForegroundColor DarkYellow
                }
            }
            else {
                $uri = "https://api.github.com/repos/$Repo/releases"
                $releases = @(Invoke-RestMethod -Uri $uri -Headers $script:ApiHeaders -TimeoutSec 30)
                $release = $releases | Where-Object { -not $_.draft -and ($Prerelease -or -not $_.prerelease) } | Select-Object -First 1
                if (-not $release) { throw '该仓库没有任何可用的 Release' }
            }

            if ($release) {
                $info.Tag = [string]$release.tag_name
                $info.Version = ConvertTo-VersionFromTag -Tag $info.Tag
                $info.ReleaseUrl = [string]$release.html_url
                $info.Assets = @($release.assets)
                $info.Source = 'api'

                if ($release.body -and -not $info.Description) {
                    $line = ($release.body -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
                    $info.Description = (ConvertTo-ShortDescription -Text $line)
                }
                return $info
            }
        }
        catch {
            $status = Get-StatusCode -ErrorRecord $_
            if ($status -eq 404) {
                throw "仓库不存在（404）：$Repo —— 确认地址正确、仓库公开"
            }
            if ($status -eq 403 -or $status -eq 429) {
                $script:ApiDisabled = $true
                Write-Host '  GitHub API 已限流，改用网页查询（拿不到资产 digest，哈希靠下载计算）' -ForegroundColor DarkYellow
            }
            else {
                Write-Host ("  GitHub API 不可用（{0}），改用网页查询" -f (Get-ErrorDetail -ErrorRecord $_)) -ForegroundColor DarkYellow
            }
        }
    }

    if ($requested) {
        $resolved = $null
        try {
            foreach ($candidate in $candidates) {
                $probe = Invoke-WebRequest -Uri "https://github.com/$Repo/releases/tag/$([uri]::EscapeDataString($candidate))" -Headers $script:WebHeaders -SkipHttpErrorCheck -TimeoutSec 30
                if ($probe.StatusCode -eq 200) { $resolved = $candidate; break }
            }
        }
        catch {
            throw ("访问 github.com 失败：{0}（检查网络/代理）" -f (Get-ErrorDetail -ErrorRecord $_))
        }

        if (-not $resolved) {
            $available = @(Get-AvailableTags -Repo $Repo)
            $hint = if ($available.Count -gt 0) { '可用的版本：' + ($available -join '、') } else { '这个仓库可能还没发布 Release' }
            throw "找不到版本 $requested。$hint"
        }

        try { $assets = @(Get-AssetsFromWeb -Repo $Repo -Tag $resolved) }
        catch { throw ("读取版本 {0} 的发布资产失败：{1}" -f $resolved, (Get-ErrorDetail -ErrorRecord $_)) }
        if ($assets.Count -eq 0) { throw "版本 $resolved 没有可下载的资产" }
    }
    else {
        try {
            $resolved = Get-LatestTagFromWeb -Repo $Repo
            $assets = @(Get-AssetsFromWeb -Repo $Repo -Tag $resolved)
        }
        catch {
            throw ("查询 $Repo 的最新 Release 失败：{0}（检查网络/代理，或确认仓库公开）" -f (Get-ErrorDetail -ErrorRecord $_))
        }
    }

    $info.Tag = $resolved
    $info.Version = ConvertTo-VersionFromTag -Tag $resolved
    $info.ReleaseUrl = "https://github.com/$Repo/releases/tag/$resolved"
    $info.Assets = $assets
    $info.Source = 'web'
    return $info
}

function ConvertTo-ShortDescription {
    param([string]$Text)

    if (-not $Text) { return $null }
    $value = $Text.Trim()
    $value = $value -replace '^#+\s*', ''
    $value = $value -replace '\[([^\]]+)\]\([^)]+\)', '$1'
    $value = $value -replace '[*_`>]', ''
    $value = ($value -replace '\s+', ' ').Trim()
    if ($value.Length -gt 160) { $value = $value.Substring(0, 157) + '...' }
    return $value
}

# ---------------------------------------------------------------- 选择资产

function Select-ArchAssets {
    param([object[]]$Assets)

    $candidates = @($Assets | Where-Object { Test-IsWindowsAsset -Name ([string]$_.name) })
    if ($candidates.Count -eq 0) { return @() }

    $grouped = @{}
    foreach ($asset in $candidates) {
        $assetName = [string]$asset.name
        $arch = Get-ArchFromText -Text $assetName
        if (-not $arch) { $arch = '64bit' }   # 没有架构标记时按 64 位处理
        if (-not $grouped.ContainsKey($arch)) { $grouped[$arch] = @() }
        $grouped[$arch] += $asset
    }

    $selected = @()
    foreach ($arch in $grouped.Keys) {
        $best = $grouped[$arch] |
            Sort-Object -Property @{ Expression = { Get-AssetScore -Name ([string]$_.name) } }, @{ Expression = { ([string]$_.name).Length } } |
            Select-Object -First 1
        $selected += [pscustomobject]@{ Arch = $arch; Asset = $best }
    }

    $order = @{ '64bit' = 0; 'arm64' = 1; '32bit' = 2 }
    return @($selected | Sort-Object -Property @{ Expression = { $order[$_.Arch] } })
}

# ---------------------------------------------------------------- 下载与检查

function Get-RemoteFile {
    param(
        [string]$Url,
        [string]$Destination
    )

    try {
        Invoke-WebRequest -Uri $Url -OutFile $Destination -Headers $script:WebHeaders -TimeoutSec 1800
    }
    catch {
        if ((Get-StatusCode -ErrorRecord $_) -eq 404) {
            throw "下载地址不存在（404）：$Url"
        }
        throw
    }
}

function Get-ArchiveEntries {
    param(
        [string]$Path,
        [string]$Kind
    )

    switch -Regex ($Kind) {
        '^zip$' {
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
            $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
            try {
                return @($archive.Entries | ForEach-Object { $_.FullName })
            }
            finally { $archive.Dispose() }
        }
        '^(tar|tgz|tar\.gz|tar\.bz2|tar\.xz)$' {
            $tar = Get-Command tar -ErrorAction SilentlyContinue
            if (-not $tar) { return $null }
            $lines = & $tar.Source -tf $Path 2>$null
            if ($LASTEXITCODE -ne 0) { return $null }
            return @($lines | ForEach-Object { [string]$_ })
        }
        '^7z$' {
            $sevenZipPath = $null
            $sevenZip = Get-Command 7z -ErrorAction SilentlyContinue
            if ($sevenZip) {
                $sevenZipPath = $sevenZip.Source
            }
            else {
                foreach ($guess in @("$env:USERPROFILE\scoop\apps\7zip\current\7z.exe", 'C:\Program Files\7-Zip\7z.exe')) {
                    if (Test-Path -LiteralPath $guess) { $sevenZipPath = $guess; break }
                }
            }
            if (-not $sevenZipPath) { return $null }

            $lines = & $sevenZipPath l -slt $Path 2>$null
            if ($LASTEXITCODE -ne 0) { return $null }

            $entries = @()
            foreach ($line in $lines) {
                if ($line -match '^Path = (.+)$') {
                    $entry = $Matches[1].Trim()
                    if ($entry -and $entry -ne $Path) { $entries += $entry }
                }
            }
            return @($entries | Select-Object -Unique)
        }
        default { return $null }
    }
}

function Get-ArchiveKind {
    param([string]$FileName)

    $value = $FileName.ToLowerInvariant()
    if ($value.EndsWith('.zip')) { return 'zip' }
    if ($value.EndsWith('.7z')) { return '7z' }
    if ($value.EndsWith('.tar.gz')) { return 'tar.gz' }
    if ($value.EndsWith('.tgz')) { return 'tgz' }
    if ($value.EndsWith('.tar.bz2')) { return 'tar.bz2' }
    if ($value.EndsWith('.tar.xz')) { return 'tar.xz' }
    if ($value.EndsWith('.exe')) { return 'exe' }
    if ($value.EndsWith('.msi')) { return 'msi' }
    return 'unknown'
}

function Get-CommonRoot {
    param([string[]]$Entries)

    $paths = @($Entries | Where-Object { $_ } | ForEach-Object {
            ($_ -replace '\\', '/').TrimStart('/').TrimEnd('/')
        } | Where-Object { $_ })
    if ($paths.Count -eq 0) { return $null }

    $roots = @($paths | ForEach-Object { ($_ -split '/')[0] } | Sort-Object -Unique)
    if ($roots.Count -ne 1) { return $null }

    $root = $roots[0]
    $nested = @($paths | Where-Object { $_ -match '/' }).Count
    if ($nested -eq 0) { return $null }   # 顶层只有一个文件，不是目录
    return $root
}

function Get-BinCandidates {
    param(
        [string[]]$Entries,
        [string]$Root
    )

    if (-not $Entries) { return @() }

    $paths = @($Entries | Where-Object { $_ } | ForEach-Object {
            ($_ -replace '\\', '/').TrimStart('/').TrimEnd('/')
        } | Where-Object { $_ -and -not $_.EndsWith('/') })

    if ($Root) {
        $prefix = $Root + '/'
        $paths = @($paths | Where-Object { $_.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) } |
                ForEach-Object { $_.Substring($prefix.Length) })
    }

    $candidates = @()
    foreach ($path in $paths) {
        if ($path -match '/') { continue }
        if ($path -notmatch '\.(exe|cmd|bat|ps1)$') { continue }
        if ($path -match '(?i)(^|[/_-])(unins|uninstall|uninst|setup|install|update|updater|crash|report|elevate|helper)') { continue }
        $candidates += $path
    }
    return $candidates
}

# ---------------------------------------------------------------- 生成清单

function New-ManifestContent {
    param(
        [string]$Repo,
        [string]$Version,
        [string]$Description,
        [string]$License,
        [string]$Homepage,
        [object[]]$ArchEntries,
        [string]$Bin,
        [string[]]$Notes
    )

    $manifest = [ordered]@{
        version     = $Version
        description = if ($Description) { $Description } else { "$Repo" }
        homepage    = if ($Homepage) { $Homepage } else { "https://github.com/$Repo" }
        license     = if ($License) { $License } else { 'Unknown' }
    }

    if ($ArchEntries.Count -eq 1 -and $ArchEntries[0].Arch -eq 'default') {
        $entry = $ArchEntries[0]
        $manifest['url'] = $entry.Url
        $manifest['hash'] = $entry.Hash
        if ($entry.ExtractDir) { $manifest['extract_dir'] = $entry.ExtractDir }
    }
    else {
        $architecture = [ordered]@{}
        foreach ($entry in $ArchEntries) {
            $item = [ordered]@{
                url  = $entry.Url
                hash = $entry.Hash
            }
            if ($entry.ExtractDir) { $item['extract_dir'] = $entry.ExtractDir }
            $architecture[$entry.Arch] = $item
        }
        $manifest['architecture'] = $architecture
    }

    if ($Bin) { $manifest['bin'] = $Bin }
    if ($Notes -and $Notes.Count -gt 0) { $manifest['notes'] = @($Notes) }

    $manifest['checkver'] = [ordered]@{ github = "https://github.com/$Repo" }

    return $manifest
}

# ---------------------------------------------------------------- 主流程

function Invoke-Generate {
    [CmdletBinding()]
    param(
        [string]$RepoUrl,
        [string]$BucketPath,
        [string]$Name,
        [string]$Version,
        [string]$Bin,
        [string]$ExtractDir,
        [switch]$Prerelease,
        [switch]$Force,
        [switch]$DryRun,
        [switch]$NoHash
    )

try {
    if (-not $RepoUrl) {
        $RepoUrl = Read-Host '请输入 GitHub 仓库地址（例如 https://github.com/owner/repo）'
    }
    if (-not $RepoUrl) {
        throw '没有输入仓库地址'
    }

    $repo = ConvertFrom-GitHubUrl -Value $RepoUrl
    if (-not $repo) {
        throw "无法识别的仓库地址：$RepoUrl（示例：https://github.com/owner/repo 或 owner/repo）"
    }

    if (-not (Test-Path -LiteralPath $BucketPath)) {
        New-Item -ItemType Directory -Path $BucketPath -Force | Out-Null
    }
    $BucketPath = (Resolve-Path -LiteralPath $BucketPath).Path

    if (-not $Name) { $Name = ($repo -split '/')[1] }
    $Name = ($Name.ToLowerInvariant() -replace '[^a-z0-9._-]', '-')
    $targetPath = Join-Path $BucketPath ($Name + '.json')

    Write-Host ("仓库：{0}" -f $repo) -ForegroundColor Cyan
    if ((Test-Path -LiteralPath $targetPath) -and -not $Force) {
        throw "清单已存在：$targetPath（确认要覆盖请加 -Force，或换一个 -Name）"
    }

    $release = Resolve-Release -Repo $repo -Tag $Version
    if ($Version) {
        Write-Host ("指定版本：{0}（{1}）" -f $release.Version, $release.ReleaseUrl)
    }
    else {
        Write-Host ("最新版本：{0}（{1}）" -f $release.Version, $release.ReleaseUrl)
    }

    $archAssets = @(Select-ArchAssets -Assets $release.Assets)
    if ($archAssets.Count -eq 0) {
        $names = @($release.Assets | ForEach-Object { [string]$_.name })
        $hint = if ($names.Count -gt 0) { "可用的资产：" + ($names -join '、') } else { '该 Release 没有资产' }
        throw "没找到 Windows 平台的安装包。$hint"
    }

    $archEntries = @()
    $notes = @()
    $warnings = @()

    foreach ($item in $archAssets) {
        $assetName = [string]$item.Asset.name
        Write-Host ("[{0}] {1}" -f $item.Arch, $assetName) -ForegroundColor DarkCyan

        $kind = Get-ArchiveKind -FileName $assetName
        $url = [string]$item.Asset.browser_download_url
        $hash = $null
        $detectedRoot = $null
        $candidates = @()

        if ($NoHash) {
            $hash = 'REPLACE_ME'
            $warnings += "加了 -NoHash，$assetName 的 hash 需要自己填"
        }
        else {
            $localPath = Join-Path $script:TempDir $assetName
            Write-Host '  下载中……' -ForegroundColor DarkGray
            Get-RemoteFile -Url $url -Destination $localPath

            $hash = (Get-FileHash -LiteralPath $localPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $digest = [string]$item.Asset.digest
            if ($digest -match '^sha256:(?<value>[0-9a-fA-F]{64})$' -and $Matches.value.ToLowerInvariant() -ne $hash) {
                $warnings += "$assetName 的 digest 与下载内容不一致，已使用下载内容的哈希"
            }

            if ($kind -in @('zip', '7z', 'tar.gz', 'tgz', 'tar.bz2', 'tar.xz')) {
                $entries = Get-ArchiveEntries -Path $localPath -Kind $kind
                if ($null -eq $entries) {
                    $warnings += "无法查看 $assetName 的内容（缺少解压工具），extract_dir / bin 需要手工确认"
                }
                else {
                    $detectedRoot = Get-CommonRoot -Entries $entries
                    $candidates = @(Get-BinCandidates -Entries $entries -Root $detectedRoot)
                }
            }
            elseif ($kind -eq 'exe') {
                $candidates = @($assetName)
            }
            elseif ($kind -eq 'msi') {
                $notes += '这是 MSI 安装包，需要补 installer 字段（例如 $dir\setup.msi /qn）后才能安装'
                $warnings += 'MSI 需要手工补 installer 脚本'
            }

            Remove-Item -LiteralPath $localPath -Force -ErrorAction SilentlyContinue
        }

        $entry = [pscustomobject]@{
            Arch       = $item.Arch
            Url        = $url
            Hash       = $hash
            ExtractDir = $null
            Candidates = $candidates
        }
        $archEntries += $entry

        if ($ExtractDir) {
            $entry.ExtractDir = $ExtractDir
        }
        elseif ($detectedRoot) {
            $entry.ExtractDir = $detectedRoot
            Write-Host ("  extract_dir：{0}" -f $detectedRoot) -ForegroundColor DarkGray
        }

        if ($candidates.Count -gt 0) {
            Write-Host ("  可执行文件：{0}" -f ($candidates -join '、')) -ForegroundColor DarkGray
        }
    }

    # bin：命令行参数优先，其次自动推断
    $resolvedBin = $Bin
    if (-not $resolvedBin) {
        $allCandidates = @($archEntries | ForEach-Object { $_.Candidates } | Select-Object -Unique)
        if ($allCandidates.Count -eq 1) {
            $resolvedBin = $allCandidates[0]
        }
        elseif ($allCandidates.Count -gt 1) {
            $repoName = ($repo -split '/')[1]
            $match = $allCandidates | Where-Object {
                ([IO.Path]::GetFileNameWithoutExtension($_)) -ieq $repoName
            } | Select-Object -First 1
            if ($match) { $resolvedBin = $match }
            else {
                $warnings += "有多个可执行文件，未自动填 bin：$($allCandidates -join '、')；请用 -Bin 指定或用 bin 数组全部加入"
            }
        }
    }
    if ($resolvedBin) { Write-Host ("bin：{0}" -f $resolvedBin) -ForegroundColor DarkGray }

    $manifest = New-ManifestContent `
        -Repo $repo `
        -Version $release.Version `
        -Description $release.Description `
        -License $release.License `
        -Homepage $release.Homepage `
        -ArchEntries $archEntries `
        -Bin $resolvedBin `
        -Notes $notes

    $json = $manifest | ConvertTo-Json -Depth 8

    Write-Host ''
    Write-Host '---------- 生成的清单 ----------' -ForegroundColor Cyan
    Write-Host $json

    if ($warnings.Count -gt 0) {
        Write-Host ''
        Write-Host '需要留意：' -ForegroundColor Yellow
        foreach ($warning in ($warnings | Select-Object -Unique)) {
            Write-Host ("  - {0}" -f $warning) -ForegroundColor Yellow
        }
    }

    if ($DryRun) {
        Write-Host ''
        Write-Host '（-DryRun：没有写入文件）' -ForegroundColor DarkYellow
        return
    }

    Set-Content -LiteralPath $targetPath -Value $json -Encoding utf8
    Write-Host ''
    Write-Host ("已写入：{0}" -f $targetPath) -ForegroundColor Green

    $validator = Join-Path $PSScriptRoot 'validate.ps1'
    if (Test-Path -LiteralPath $validator) {
        Write-Host ''
        & $validator -BucketPath $BucketPath
    }

    Write-Host ''
    Write-Host '安装试试：' -ForegroundColor Cyan
    Write-Host ("  scoop update；然后 scoop install {0}" -f $Name)
    Write-Host '本机已订阅这个 bucket 时直接装即可；否则先 scoop bucket add <名字> <仓库地址>。'
    Write-Host ''
    Write-Host ("别忘了在 README.md 的「已收录软件」里补一节 {0} 的使用说明。" -f $Name) -ForegroundColor DarkGray
}
finally {
    if (Test-Path -LiteralPath $script:TempDir) {
        Remove-Item -LiteralPath $script:TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
}

# ---------------------------------------------------------------- 入口

if ($MyInvocation.InvocationName -ne '.') {
    try {
        Invoke-Generate `
            -RepoUrl $RepoUrl `
            -BucketPath $BucketPath `
            -Name $Name `
            -Version $Version `
            -Bin $Bin `
            -ExtractDir $ExtractDir `
            -Prerelease:$Prerelease `
            -Force:$Force `
            -DryRun:$DryRun `
            -NoHash:$NoHash
    }
    catch {
        Write-Host ''
        Write-Host ('失败：' + $_.Exception.Message) -ForegroundColor Red
        exit 1
    }
}