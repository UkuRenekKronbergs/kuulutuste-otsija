# Ühised utiliidid kuulutuste otsija jaoks
# Kasutab PowerShell 5.1 sisseehitatud funktsioone.

$script:EdgeExe = @(
    'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
    'C:\Program Files\Microsoft\Edge\Application\msedge.exe'
) | Where-Object { Test-Path $_ } | Select-Object -First 1

function Get-Config {
    param([string]$Path = (Join-Path $PSScriptRoot '..\config.json'))
    Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Invoke-CurlFetch {
    param(
        [string]$Url,
        [string]$UserAgent,
        [int]$TimeoutSec = 30
    )
    $tmpFile = [System.IO.Path]::GetTempFileName()
    try {
        $args = @(
            '-s', '-L', '--compressed',
            '-A', $UserAgent,
            '-H', 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
            '-H', 'Accept-Language: et-EE,et;q=0.9,en;q=0.8',
            '--max-time', $TimeoutSec.ToString(),
            '-o', $tmpFile,
            '-w', '%{http_code}',
            $Url
        )
        $code = & curl.exe @args
        if ($LASTEXITCODE -ne 0) { return $null }
        $html = Get-Content -LiteralPath $tmpFile -Raw -Encoding UTF8
        [pscustomobject]@{ StatusCode = [int]$code; Body = $html }
    } finally {
        if (Test-Path -LiteralPath $tmpFile) { Remove-Item -LiteralPath $tmpFile -Force }
    }
}

function Invoke-EdgeFetch {
    param(
        [string]$Url,
        [int]$WaitMs = 12000,
        [string]$UserAgent
    )
    if (-not $script:EdgeExe) {
        Write-Warning "Microsoft Edge ei leitud - Edge fetch pole saadaval"
        return $null
    }
    $profileDir = Join-Path $env:TEMP ("kuulutuste_otsija_edge_" + [guid]::NewGuid().ToString('N').Substring(0,8))
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $script:EdgeExe
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.Arguments = @(
            '--headless=new',
            '--disable-gpu',
            '--no-sandbox',
            '--disable-blink-features=AutomationControlled',
            '--disable-features=IsolateOrigins,site-per-process',
            "--user-data-dir=`"$profileDir`"",
            "--user-agent=`"$UserAgent`"",
            '--dump-dom',
            "--virtual-time-budget=$WaitMs",
            "`"$Url`""
        ) -join ' '
        $proc = [System.Diagnostics.Process]::Start($psi)
        $body = $proc.StandardOutput.ReadToEnd()
        $null = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        if ([string]::IsNullOrWhiteSpace($body)) { return $null }
        [pscustomobject]@{ StatusCode = 200; Body = $body }
    } finally {
        if (Test-Path -LiteralPath $profileDir) {
            Remove-Item -LiteralPath $profileDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function ConvertFrom-PriceString {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $clean = $Text -replace '<[^>]+>', ' ' -replace '&[a-zA-Z]+;', ' '
    if ($clean -match 'kokkuleppe|l.brr..k|tasuta|free|vahetus') { return $null }
    if ($clean -notmatch '\d') { return $null }
    # Leia esimene numbrite jada eraldajatega
    $match = [regex]::Match($clean, '\d[\d\s\u00A0.,]*\d|\d')
    if (-not $match.Success) { return $null }
    $n = $match.Value -replace '[\s\u00A0]', ''
    # Normaliseeri eraldajad
    if ($n -match '^\d{1,3}(,\d{3})+(\.\d+)?$') {
        # US stiil: 1,234,567.89
        $n = $n -replace ','
    } elseif ($n -match '^\d{1,3}(\.\d{3})+(,\d+)?$') {
        # DE/EE stiil: 1.234.567,89
        $n = ($n -replace '\.') -replace ',', '.'
    } elseif ($n -match '^\d+,\d+$') {
        # EE komakoht: 123,45
        $n = $n -replace ',', '.'
    } elseif ($n -match '^\d+\.\d{3}$') {
        # "5.000" = 5000 (Eesti kuulutustes on punkt tuhandete eraldaja)
        $n = $n -replace '\.'
    }
    [double]$price = 0
    if ([double]::TryParse($n, [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$price)) {
        if ($price -le 0) { return $null }
        return $price
    }
    return $null
}

function ConvertFrom-HtmlEntities {
    param([string]$Text)
    if (-not $Text) { return '' }
    Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
    $t = [System.Web.HttpUtility]::HtmlDecode($Text)
    if (-not $t) { $t = $Text }
    ($t -replace '\s+', ' ').Trim()
}

function Remove-HtmlTags {
    param([string]$Text)
    if (-not $Text) { return '' }
    # Asenda blokk-tagid tühikuga, inline-tagid otsese eemaldusega
    # Nii ei lõhu otsinguterminite esiletõstmine sõnu (nt "tool<font class=search>ipad</font>jad" → "toolipadjad")
    $t = $Text -replace '</?(?:strong|b|em|i|span|u|mark|font)(?:\s[^>]*)?>', ''
    $t = $t -replace '<[^>]+>', ' '
    (ConvertFrom-HtmlEntities $t)
}

function Get-ListingId {
    param([string]$Url)
    if (-not $Url) { return $null }
    $match = [regex]::Match($Url, '(\d{4,})')
    if ($match.Success) { return $match.Value }
    return $Url
}

function Load-State {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return @{ seen = @{}; last_run = $null }
    }
    try {
        $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        $seen = @{}
        if ($json.seen) {
            $json.seen.PSObject.Properties | ForEach-Object { $seen[$_.Name] = $_.Value }
        }
        return @{ seen = $seen; last_run = $json.last_run }
    } catch {
        return @{ seen = @{}; last_run = $null }
    }
}

function Save-State {
    param([string]$Path, [hashtable]$State)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $obj = [ordered]@{
        last_run = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')
        seen = $State.seen
    }
    ($obj | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-MedianPrice {
    param([double[]]$Prices)
    $valid = @($Prices | Where-Object { $_ -gt 0 } | Sort-Object)
    if ($valid.Count -eq 0) { return $null }
    $mid = [math]::Floor($valid.Count / 2)
    if ($valid.Count % 2 -eq 0) {
        return ($valid[$mid - 1] + $valid[$mid]) / 2
    }
    return $valid[$mid]
}

function Test-MatchesKeyword {
    param([string]$Title, [string]$Keyword)
    if (-not $Title) { return $false }
    $titleLower = $Title.ToLower()
    # Märksõna sõnade vahel võib olla ükskõik milline tühik/punktuatsioon (nt "playstation 5" kattub "Playstation-5"-ga)
    # Aga sõna ise peab olema terve (sõnapiiridega)
    $words = $Keyword.ToLower().Split(@(' '), [StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object { [regex]::Escape($_) }
    $phrase = $words -join '[\s\-_,./]+'
    $pattern = "(^|[^a-z0-9\u00e4\u00f6\u00fc\u00f5])${phrase}([^a-z0-9\u00e4\u00f6\u00fc\u00f5]|$)"
    return [bool]([regex]::IsMatch($titleLower, $pattern))
}
