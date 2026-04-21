# Kuulutuste otsija - põhiskript
# Kasutamine:
#   powershell -ExecutionPolicy Bypass -File otsi.ps1
#   powershell -ExecutionPolicy Bypass -File otsi.ps1 -Keyword "iphone 13"    # üks märksõna
#   powershell -ExecutionPolicy Bypass -File otsi.ps1 -ShowAll                # kõik tulemused, mitte ainult uued heaga hinnaga

[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$Keyword,
    [switch]$ShowAll,
    [switch]$NoState
)

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$scriptRoot = $PSScriptRoot
if (-not $scriptRoot) { $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $scriptRoot) { $scriptRoot = (Get-Location).Path }
if (-not $ConfigPath) { $ConfigPath = Join-Path $scriptRoot 'config.json' }

. (Join-Path $scriptRoot 'lib\common.ps1')
. (Join-Path $scriptRoot 'lib\scrapers.ps1')

$config = Get-Config -Path $ConfigPath
$statePath = Join-Path $scriptRoot 'state\seen.json'
$state = Load-State -Path $statePath

$searches = if ($Keyword) {
    @([pscustomobject]@{ keyword = $Keyword; max_price = 999999; min_price = 0 })
} else {
    $config.searches
}
$blocklist = @()
if ($config.blocklist) { $blocklist = @($config.blocklist | ForEach-Object { $_.ToString().ToLower() }) }

$runStart = Get-Date
Write-Host ("=== Kuulutuste otsija | {0:yyyy-MM-dd HH:mm} ===" -f $runStart) -ForegroundColor Cyan

$allResults = @()
foreach ($search in $searches) {
    $kw = $search.keyword
    $maxPrice = [double]$search.max_price
    $minPrice = if ($search.PSObject.Properties['min_price']) { [double]$search.min_price } else { 0 }
    $maxStr = if ($maxPrice -ge 999999) { 'pole' } else { "$maxPrice€" }
    Write-Host ""
    Write-Host ("[{0}] (min {1}€, max {2})" -f $kw, $minPrice, $maxStr) -ForegroundColor Yellow

    $listings = @(Get-AllListings -Keyword $kw -Config $config)
    if ($listings.Count -eq 0) {
        Write-Host "  (tulemusi ei leitud)" -ForegroundColor DarkGray
        Start-Sleep -Milliseconds $config.request_delay_ms
        continue
    }

    # Filtreeri välja aksessuaarid blocklist-i põhjal (substring-match, sest Eesti keele
    # liitsõnad kirjutatakse kokku: "silikoonümbris", "toidukate" jne)
    $filtered = @()
    $blocked = 0
    foreach ($l in $listings) {
        $titleLower = $l.title.ToLower()
        $isBlocked = $false
        foreach ($word in $blocklist) {
            if ($titleLower.Contains($word)) { $isBlocked = $true; break }
        }
        if ($isBlocked) { $blocked++ } else { $filtered += $l }
    }

    # Mediaan arvutatakse ainult tõsiste kuulutuste põhjal (min_price..max_price vahemikus)
    $serious = @($filtered | Where-Object { $_.price -ge $minPrice -and $_.price -le $maxPrice })
    $prices = @($serious | ForEach-Object { [double]$_.price })
    $median = Get-MedianPrice -Prices $prices

    $goodDeals = @()
    foreach ($l in $filtered) {
        if ($l.price -lt $minPrice -or $l.price -gt $maxPrice) { continue }
        $underMedian = $true
        if ($median -ne $null -and $prices.Count -ge $config.min_samples_for_median) {
            $underMedian = $l.price -le ($median * $config.median_threshold)
        }
        if ($underMedian) {
            $pct = if ($median) { [math]::Round((1 - $l.price / $median) * 100) } else { 0 }
            $goodDeals += [pscustomobject]@{
                id            = $l.id
                title         = $l.title
                price         = $l.price
                url           = $l.url
                site          = $l.site
                location      = $l.location
                date          = $l.date
                keyword       = $l.keyword
                median        = $median
                pct_under_med = $pct
                first_seen    = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')
            }
        }
    }

    $new = if ($NoState) {
        $goodDeals
    } else {
        @($goodDeals | Where-Object { -not $state.seen.ContainsKey($_.id) })
    }

    $medianStr = if ($median) { [math]::Round($median).ToString() } else { '?' }
    Write-Host ("  leitud: {0} (filtr. aksessuaare: {1}) | mediaan: {2}€ | head hinnad: {3} | uued: {4}" -f `
        $listings.Count, $blocked, $medianStr, $goodDeals.Count, $new.Count) -ForegroundColor Green

    if ($ShowAll) { $allResults += $goodDeals } else { $allResults += $new }

    foreach ($d in $new) {
        $pctStr = if ($d.pct_under_med -gt 0) { "-$($d.pct_under_med)%" } else { '' }
        Write-Host ("    {0,7:N0}€ {1,-4} [{2}] {3}" -f $d.price, $pctStr, $d.site, $d.title) -ForegroundColor White
        Write-Host ("             {0}" -f $d.url) -ForegroundColor DarkGray
    }

    foreach ($g in $goodDeals) { $state.seen[$g.id] = (Get-Date -Format 'yyyy-MM-dd') }

    Start-Sleep -Milliseconds $config.request_delay_ms
}

# Salvesta tulemus: liida tänase päeva olemasolevale failile uued leiud juurde,
# et mitu käivitust ühel päeval ei kustutaks varasemate käivituste tulemusi.
$dateStr = Get-Date -Format 'yyyy-MM-dd'
$resultsDir = Join-Path $scriptRoot 'results'
if (-not (Test-Path -LiteralPath $resultsDir)) { New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null }
$resultsPath = Join-Path $resultsDir "$dateStr.json"

$existing = @()
if ((Test-Path -LiteralPath $resultsPath) -and -not $ShowAll) {
    try {
        $old = Get-Content -LiteralPath $resultsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($old.listings) { $existing = @($old.listings) }
    } catch {}
}
$combined = @($existing + $allResults)

$output = [ordered]@{
    run_at   = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')
    total    = $combined.Count
    listings = $combined
}
($output | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $resultsPath -Encoding UTF8

if (-not $NoState) {
    Save-State -Path $statePath -State $state
}

$elapsed = (Get-Date) - $runStart
Write-Host ""
$modeStr = if ($ShowAll) { 'head hinda' } else { 'uut head hinda' }
$elapsedStr = '{0:mm\:ss}' -f $elapsed
Write-Host ("=== Valmis. Leidsin {0} {1}, aeg {2}. Salvestatud: {3} ===" -f `
    $allResults.Count, $modeStr, $elapsedStr, $resultsPath) -ForegroundColor Cyan
