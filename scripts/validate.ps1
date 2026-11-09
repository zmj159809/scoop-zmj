#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$BucketPath = (Join-Path $PSScriptRoot '../bucket')
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $BucketPath -PathType Container)) {
    throw "Bucket directory does not exist: $BucketPath"
}
$files = @(Get-ChildItem -LiteralPath $BucketPath -Filter '*.json' -File)
$failures = 0
foreach ($file in $files) {
    try {
        if ($file.BaseName -cnotmatch '^[a-z0-9][a-z0-9._-]*$') {
            throw 'Use a lowercase app name containing only a-z, 0-9, dot, underscore or hyphen.'
        }
        $raw = Get-Content -LiteralPath $file.FullName -Raw
        if ($raw -match 'REPLACE_ME') { throw 'Replace all template placeholders before publishing.' }
        $manifest = ConvertFrom-Json -InputObject $raw -AsHashtable
        if ($manifest -isnot [System.Collections.IDictionary]) { throw 'Manifest must be a JSON object.' }
        foreach ($field in @('version', 'description', 'homepage', 'license')) {
            if (-not $manifest.Contains($field) -or -not $manifest[$field]) {
                throw "Missing required field: $field"
            }
        }
        $downloads = @()
        if ($manifest.Contains('architecture')) {
            if ($manifest.architecture -isnot [System.Collections.IDictionary] -or $manifest.architecture.Count -eq 0) {
                throw 'architecture must be a non-empty object.'
            }
            foreach ($arch in $manifest.architecture.Keys) {
                if ($arch -notin @('32bit', '64bit', 'arm64')) { throw "Unsupported architecture: $arch" }
                $downloads += $manifest.architecture[$arch]
            }
        } else {
            $downloads += $manifest
        }
        foreach ($download in $downloads) {
            if ($download -isnot [System.Collections.IDictionary] -or -not $download.url -or -not $download.hash) {
                throw 'Each download needs url and hash.'
            }
            $urls = @($download.url)
            $hashes = @($download.hash)
            if ($urls.Count -ne $hashes.Count) { throw 'url and hash counts must match.' }
            for ($i = 0; $i -lt $urls.Count; $i++) {
                $uri = $null
                if (-not [uri]::TryCreate([string]$urls[$i], [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('http', 'https')) {
                    throw "Expected an HTTP(S) download URL: $($urls[$i])"
                }
                if ([string]$hashes[$i] -notmatch '^[a-fA-F0-9]{64}$') {
                    throw 'Use an actual 64-character SHA256 hash for every download.'
                }
            }
        }
        Write-Host "PASS $($file.Name)"
    } catch {
        $failures++
        Write-Host "FAIL $($file.Name): $($_.Exception.Message)" -ForegroundColor Red
    }
}
if ($failures -gt 0) { throw "$failures manifest(s) failed validation." }
if ($files.Count -eq 0) {
    Write-Host 'Bucket is empty. Add manifests using templates/portable.json.'
} else {
    Write-Host "Validated $($files.Count) manifest(s)."
}
