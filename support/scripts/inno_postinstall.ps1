param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("InstallFirewall", "InstallShell")]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [string]$AppDir
)

$ErrorActionPreference = "Stop"

switch ($Action) {
    "InstallFirewall" {
        $exePath = Join-Path $AppDir "landrop.exe"

        $byProg = Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue |
            Where-Object { $_.Program -like "*landrop.exe" } |
            Get-NetFirewallRule -ErrorAction SilentlyContinue
        $byName = @("LanDrop", "LanDrop Inbound TCP", "LanDrop Inbound UDP") | ForEach-Object {
            Get-NetFirewallRule -DisplayName $_ -ErrorAction SilentlyContinue
        }

        @($byProg) + @($byName) |
            Where-Object { $_ -ne $null } |
            Sort-Object Name -Unique |
            Remove-NetFirewallRule -ErrorAction SilentlyContinue

        New-NetFirewallRule `
            -DisplayName "LanDrop Inbound TCP" `
            -Direction Inbound `
            -Action Allow `
            -Profile @("Private", "Public") `
            -Enabled True `
            -Protocol TCP `
            -Program $exePath | Out-Null

        New-NetFirewallRule `
            -DisplayName "LanDrop Inbound UDP" `
            -Direction Inbound `
            -Action Allow `
            -Profile @("Private", "Public") `
            -Enabled True `
            -Protocol UDP `
            -Program $exePath | Out-Null
    }

    "InstallShell" {
        $cerPath = Join-Path $AppDir "landrop_signing.cer"
        $msixPath = Join-Path $AppDir "landrop_msix_helper.msix"

        if (Test-Path $cerPath) {
            Import-Certificate -FilePath $cerPath -CertStoreLocation "Cert:\LocalMachine\TrustedPeople" | Out-Null
            Import-Certificate -FilePath $cerPath -CertStoreLocation "Cert:\LocalMachine\Root" | Out-Null
        }

        Get-AppxPackage -Name "LanDrop.App" -ErrorAction SilentlyContinue | Remove-AppxPackage -ErrorAction SilentlyContinue
        if (Test-Path $msixPath) {
            Add-AppxPackage -Path $msixPath -ExternalLocation $AppDir
        }

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
    }
}
