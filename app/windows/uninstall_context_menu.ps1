$ErrorActionPreference = "Stop"

$pkg = Get-AppxPackage -Name "LanDrop.App" -ErrorAction SilentlyContinue
if ($pkg) {
    $pkg | Remove-AppxPackage
    Write-Host "Removed LanDrop.App sparse package."
} else {
    Write-Host "LanDrop.App sparse package is not currently installed."
}
