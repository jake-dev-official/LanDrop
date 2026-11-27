# Using Visual Studio 2022 Developer PowerShell
# or Windows Kits 10 makepri.exe / makeappx.exe
$ErrorActionPreference = "Stop"

function Resolve-WinKitTool {
    param([string]$ToolName)
    $cmd = Get-Command $ToolName -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    $found = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Recurse -Filter $ToolName -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match "\\x64\\$ToolName$" } |
        Sort-Object FullName -Descending |
        Select-Object -First 1
    if (-not $found) {
        throw "$ToolName (x64) not found on PATH or under Windows Kits 10."
    }
    return $found.FullName
}

$makepri = Resolve-WinKitTool "makepri.exe"
$makeappx = Resolve-WinKitTool "makeappx.exe"

$priPath = ".\support\build\msix\content\resources.pri"
if (Test-Path $priPath) {
    Remove-Item $priPath -Force
}

# The resource map name inside resources.pri must match the Identity Name in AppxManifest.xml,
# otherwise the shell cannot resolve the logos (e.g. blank taskbar / Share icon).
& $makepri new /pr .\support\build\msix\content /cf .\support\build\msix\priconfig.xml /mn .\support\build\msix\content\AppxManifest.xml /of $priPath /o
if ($LASTEXITCODE -ne 0) {
    throw "makepri.exe failed with exit code $LASTEXITCODE"
}

& $makeappx pack /o /d .\support\build\msix\content /nv /p .\app\windows\landrop_msix_helper.msix
if ($LASTEXITCODE -ne 0) {
    throw "makeappx.exe failed with exit code $LASTEXITCODE"
}
