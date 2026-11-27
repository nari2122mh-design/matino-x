# One-click launcher for the MATINO X file-drop site.
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root

# Pick whatever Python launcher this machine has.
$py = $null
foreach ($candidate in @("py", "python")) {
    if (Get-Command $candidate -ErrorAction SilentlyContinue) { $py = $candidate; break }
}
if (-not $py) { Write-Host "Python not found. Install Python 3." -ForegroundColor Red; exit 1 }

& $py -m pip install --quiet -r site/requirements.txt

Write-Host "Site running at http://127.0.0.1:5000" -ForegroundColor Green
& $py site/app.py
