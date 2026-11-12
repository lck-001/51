param([switch]$UserApproved)
if (-not $UserApproved) { throw "Changing Developer Mode requires explicit approval for this machine." }
# Optional local setup helper; never run by default.
$ErrorActionPreference = 'Stop'
$receiptPath = Join-Path $PSScriptRoot 'results/developer-mode-change.json'
try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {throw 'Administrative consent was not granted'}
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
    $old = Get-ItemProperty -Path $key -Name AllowDevelopmentWithoutDevLicense -ErrorAction SilentlyContinue
    $previous = if ($null -eq $old) {$null} else {$old.AllowDevelopmentWithoutDevLicense}
    if (-not (Test-Path -LiteralPath $key)) {New-Item -Path $key -Force | Out-Null}
    New-ItemProperty -Path $key -Name AllowDevelopmentWithoutDevLicense -PropertyType DWord -Value 1 -Force | Out-Null
    $current = (Get-ItemProperty -Path $key -Name AllowDevelopmentWithoutDevLicense).AllowDevelopmentWithoutDevLicense
    if ($current -ne 1) {throw 'Setting readback failed'}
    [pscustomobject]@{status='success';setting='AllowDevelopmentWithoutDevLicense';previousValue=$previous;currentValue=$current;userApproved=$true;devicePortalEnabledByTask=$false;remoteDebugEnabledByTask=$false;time=(Get-Date).ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath $receiptPath -Encoding utf8
} catch {
    [pscustomobject]@{status='failed';setting='AllowDevelopmentWithoutDevLicense';message=$_.Exception.Message;time=(Get-Date).ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath $receiptPath -Encoding utf8
    exit 1
}
