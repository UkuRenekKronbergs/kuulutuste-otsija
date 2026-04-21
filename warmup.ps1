# Warmup - käivita korra enne okidoki.ee lubamist, et Cloudflare cf_clearance cookie profili salvestuks.
# Kasutamine:
#   powershell -ExecutionPolicy Bypass -File warmup.ps1
#
# Teadmiseks: cf_clearance kehtib ~30 min kuni paar tundi, seejärel tuleb uuesti käivitada.
# See on põhjus, miks okidoki on vaikimisi off - kui soovid seda jooksvalt igapäevaselt kasutada,
# on vaja lisaks luua Windows Task Scheduleri ülesanne, mis käivitab warmup.ps1-i enne otsi.ps1-i.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$scriptRoot = $PSScriptRoot
if (-not $scriptRoot) { $scriptRoot = (Get-Location).Path }

. (Join-Path $scriptRoot 'lib\common.ps1')

$configPath = Join-Path $scriptRoot 'config.json'
$config = Get-Config -Path $configPath

if (-not $config.edge_profile_dir) {
    Write-Host "config.json-is pole 'edge_profile_dir' määratud. Kasutan vaikimisi: ./edge_profile" -ForegroundColor Yellow
    $profileDir = Join-Path $scriptRoot 'edge_profile'
} else {
    $profileDir = $config.edge_profile_dir
}
if (-not (Test-Path -LiteralPath $profileDir)) { New-Item -ItemType Directory -Path $profileDir -Force | Out-Null }

$edgeExe = @(
    'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
    'C:\Program Files\Microsoft\Edge\Application\msedge.exe'
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $edgeExe) {
    Write-Host "Microsoft Edge ei leitud." -ForegroundColor Red
    exit 1
}

$urls = @(
    'https://www.okidoki.ee/buy/all/?query=iphone',
    'https://www.kuldnebors.ee/'
)

Write-Host "=== Cloudflare warmup ===" -ForegroundColor Cyan
Write-Host "Ava iga sait, oota kuni challenge laheneb (~5-10 sek) ja sulge aken."
Write-Host "Profile dir: $profileDir"
Write-Host ""

foreach ($url in $urls) {
    Write-Host "Avan: $url" -ForegroundColor Yellow
    $args = @(
        "--user-data-dir=`"$profileDir`"",
        '--no-first-run',
        '--disable-blink-features=AutomationControlled',
        '--window-size=1280,800',
        "`"$url`""
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $edgeExe
    $psi.Arguments = $args -join ' '
    $psi.UseShellExecute = $false
    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.WaitForExit()
    Write-Host "  Aken suletud." -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "Warmup valmis. Cookie'd on salvestatud. Nüüd saad otsi.ps1 käivitada okidoki lubatuna." -ForegroundColor Green
