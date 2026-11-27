$ErrorActionPreference = "Stop"

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "Please run install_context_menu.ps1 from an Administrator PowerShell window."
    exit 1
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir

$msixPath = Join-Path $scriptDir "landrop_msix_helper.msix"
$dllPath = Join-Path $scriptDir "landrop_shell_ext.dll"
$priPath = Join-Path $scriptDir "resources.pri"
$imagesDir = Join-Path $scriptDir "Images"
if (-not (Test-Path $msixPath)) { throw "Missing $msixPath" }
if (-not (Test-Path $dllPath)) { throw "Missing $dllPath" }
if (-not (Test-Path $priPath)) { throw "Missing $priPath" }
if (-not (Test-Path $imagesDir)) { throw "Missing $imagesDir" }

$signtool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Recurse -Filter "signtool.exe" -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match "\\x64\\signtool\.exe$" } |
    Sort-Object FullName -Descending |
    Select-Object -First 1
if (-not $signtool) {
    throw "signtool.exe (x64) not found under Windows Kits 10."
}

$cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert |
    Where-Object { $_.Subject -eq "CN=LanDrop" } |
    Sort-Object NotAfter -Descending |
    Select-Object -First 1

if (-not $cert) {
    $cert = New-SelfSignedCertificate -Type Custom -Subject "CN=LanDrop" -KeyUsage DigitalSignature `
        -FriendlyName "LanDrop Sparse Package Signing Cert" -CertStoreLocation "Cert:\CurrentUser\My" `
        -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3", "2.5.29.19={text}")
}

$cerPath = Join-Path $env:TEMP "landrop_signing.cer"
Export-Certificate -Cert $cert -FilePath $cerPath -Force | Out-Null
Import-Certificate -FilePath $cerPath -CertStoreLocation "Cert:\LocalMachine\TrustedPeople" | Out-Null
Import-Certificate -FilePath $cerPath -CertStoreLocation "Cert:\LocalMachine\Root" | Out-Null
Remove-Item $cerPath -Force -ErrorAction SilentlyContinue

& $signtool.FullName sign /fd SHA256 /sha1 $cert.Thumbprint $msixPath
if ($LASTEXITCODE -ne 0) {
    throw "signtool failed with exit code $LASTEXITCODE"
}

Get-AppxPackage -Name "LanDrop.App" -ErrorAction SilentlyContinue | Remove-AppxPackage -ErrorAction SilentlyContinue
Add-AppxPackage -Path $msixPath -ExternalLocation $scriptDir

# Best-effort Windows Shell icon cache refresh without restarting Explorer.
try {
    $ie4uinit = Join-Path $env:SystemRoot "System32\ie4uinit.exe"
    if (Test-Path $ie4uinit) {
        & $ie4uinit -show | Out-Null
    }
} catch {}

try {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class LanDropShellNotify {
    [DllImport("shell32.dll")]
    public static extern void SHChangeNotify(int wEventId, uint uFlags, IntPtr dwItem1, IntPtr dwItem2);
}
"@ -ErrorAction SilentlyContinue
    [LanDropShellNotify]::SHChangeNotify(0x08000000, 0x0000, [IntPtr]::Zero, [IntPtr]::Zero)
} catch {}

# Ensure Windows Firewall allows LanDrop inbound TCP/UDP (port 53317) on Private and Public networks,
# and remove any conflicting Inbound Block rules created for LanDrop.
Get-NetFirewallRule -Direction Inbound -Action Block -ErrorAction SilentlyContinue | Where-Object {
    $_.DisplayName -eq "LanDrop" -or (
        ($_ | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue).Program -like "*landrop.exe"
    )
} | Remove-NetFirewallRule -ErrorAction SilentlyContinue

foreach ($ruleName in @("LanDrop Inbound TCP", "LanDrop Inbound UDP")) {
    Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
}

$exePath = Join-Path $scriptDir "landrop.exe"
$fwBaseParams = @{
    Direction = "Inbound"
    Action    = "Allow"
    Profile   = @("Private", "Public")
    Enabled   = "True"
    LocalPort = 53317
}
if (Test-Path $exePath) {
    New-NetFirewallRule @fwBaseParams -DisplayName "LanDrop Inbound TCP" -Protocol TCP -Program $exePath | Out-Null
    New-NetFirewallRule @fwBaseParams -DisplayName "LanDrop Inbound UDP" -Protocol UDP -Program $exePath | Out-Null
} else {
    New-NetFirewallRule @fwBaseParams -DisplayName "LanDrop Inbound TCP" -Protocol TCP | Out-Null
    New-NetFirewallRule @fwBaseParams -DisplayName "LanDrop Inbound UDP" -Protocol UDP | Out-Null
}

Write-Host "LanDrop Windows 11 context menu and firewall rules registered successfully from $scriptDir." -ForegroundColor Green
