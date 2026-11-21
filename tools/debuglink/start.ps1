# Groove Coach Debug Link launcher (Windows). Starts tools/debuglink/server.py; the phone finds it by itself.
#
#   powershell -ExecutionPolicy Bypass -File tools\debuglink\start.ps1 [-Port 8765] [-Data <dir>] [-NoBonjour] [-NoInstall]
#
# - Adds the inbound firewall rules if missing (TCP <Port>, and UDP 5353 for Bonjour; Private + Public profiles).
#   Without admin rights it prints the one command to run in an elevated PowerShell and carries on.
# - Installs the optional `zeroconf` package (Bonjour advertising) with pip --user if it is missing, unless -NoInstall.
#   Without it the app still finds the PC by probing the Wi-Fi /24 for /health.
# - Opens nothing else; watch http://localhost:<Port>/ for the live screen + log.
param(
    [int]$Port = 8765,
    [string]$Data = "",
    [switch]$NoBonjour,
    [switch]$NoInstall
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$server = Join-Path $here "server.py"

# --- Python
$python = $null
foreach ($cand in @("py", "python", "python3")) {
    $cmd = Get-Command $cand -ErrorAction SilentlyContinue
    if ($cmd) { $python = $cmd.Source; break }
}
if (-not $python) {
    Write-Host "Python 3 not found on PATH. Install it from https://www.python.org/ and run this again." -ForegroundColor Red
    exit 1
}
$pyArgs = @()
if ((Split-Path -Leaf $python) -like "py.exe") { $pyArgs = @("-3") }

# --- Firewall
$rules = @(
    @{ Name = "GrooveCoach debuglink TCP $Port"; Protocol = "TCP"; LocalPort = "$Port" },
    @{ Name = "GrooveCoach debuglink mDNS"; Protocol = "UDP"; LocalPort = "5353" }
)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
$missing = @()
foreach ($r in $rules) {
    $existing = $null
    try { $existing = Get-NetFirewallRule -DisplayName $r.Name -ErrorAction Stop } catch { $existing = $null }
    if (-not $existing) { $missing += $r }
}
if ($missing.Count -eq 0) {
    Write-Host "Firewall: rules present."
} elseif ($isAdmin) {
    foreach ($r in $missing) {
        New-NetFirewallRule -DisplayName $r.Name -Direction Inbound -Protocol $r.Protocol -LocalPort $r.LocalPort `
            -Action Allow -Profile Private,Public | Out-Null
        Write-Host "Firewall: added '$($r.Name)' (Private + Public)."
    }
} else {
    Write-Host "Firewall: rule(s) missing and this shell is not elevated. Run once in an admin PowerShell:" -ForegroundColor Yellow
    foreach ($r in $missing) {
        Write-Host ("  New-NetFirewallRule -DisplayName `"{0}`" -Direction Inbound -Protocol {1} -LocalPort {2} -Action Allow -Profile Private,Public" -f $r.Name, $r.Protocol, $r.LocalPort)
    }
    Write-Host "Starting anyway (the phone cannot connect until the TCP rule exists, unless Windows already allows python)." -ForegroundColor Yellow
}

# --- Optional Bonjour dependency
if (-not $NoBonjour) {
    & $python @pyArgs -c "import zeroconf" 2>$null
    if ($LASTEXITCODE -ne 0) {
        if ($NoInstall) {
            Write-Host "zeroconf not installed: Bonjour off, the app falls back to the /24 probe."
        } else {
            Write-Host "Installing optional 'zeroconf' (pip --user) for Bonjour..."
            & $python @pyArgs -m pip install --user --quiet zeroconf
            if ($LASTEXITCODE -ne 0) { Write-Host "pip install failed; Bonjour off, the /24 probe still works." -ForegroundColor Yellow }
        }
    }
}

# --- Run
$serverArgs = @($server, "--port", "$Port")
if ($Data) { $serverArgs += @("--data", $Data) }
if ($NoBonjour) { $serverArgs += "--no-bonjour" }
Write-Host "Live page: http://localhost:$Port/"
& $python @pyArgs @serverArgs
exit $LASTEXITCODE
