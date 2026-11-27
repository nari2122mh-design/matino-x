# One-click launcher for the MATINO X file-drop bot.
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root

# Pick whatever Python launcher this machine has.
$py = $null
foreach ($candidate in @("py", "python")) {
    if (Get-Command $candidate -ErrorAction SilentlyContinue) { $py = $candidate; break }
}
if (-not $py) { Write-Host "Python not found. Install Python 3." -ForegroundColor Red; exit 1 }

if (-not (Test-Path ".env")) {
    Copy-Item ".env.example" ".env"
    Write-Host "Created .env from .env.example — open it and fill in your token and chat ID." -ForegroundColor Yellow
    notepad .env
    exit 1
}

& $py -m pip install --quiet requests
& $py telegram_file_bot.py
