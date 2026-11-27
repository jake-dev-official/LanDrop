$ErrorActionPreference = "Stop"

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "Please run Install-LanDrop.ps1 from an Administrator PowerShell window."
    exit 1
}

$sourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$installDir = "C:\Program Files\LanDrop"

Write-Host "Installing LanDrop from $sourceDir to $installDir ..." -ForegroundColor Cyan

Get-Process -Name landrop -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500

if (-not (Test-Path $installDir)) {
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
}

foreach ($sub in @("data", "Images")) {
    $destSub = Join-Path $installDir $sub
    if (Test-Path $destSub) {
        Remove-Item -Path $destSub -Recurse -Force
    }
}

$itemsToCopy = @(
    "landrop.exe",
    "landrop.exe.manifest",
    "landrop_msix_helper.msix",
    "resources.pri",
    "install_context_menu.ps1",
    "uninstall_context_menu.ps1",
    "Install-LanDrop.ps1"
)

foreach ($item in $itemsToCopy) {
    $srcItem = Join-Path $sourceDir $item
    if (Test-Path $srcItem) {
        Copy-Item -Path $srcItem -Destination $installDir -Force
    }
}

Get-ChildItem -Path $sourceDir -Filter "*.dll" -File | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination $installDir -Force
}

foreach ($dirName in @("data", "Images")) {
    $srcDir = Join-Path $sourceDir $dirName
    if (-not (Test-Path $srcDir)) {
        throw "Missing required folder: $srcDir"
    }
    Copy-Item -Path $srcDir -Destination (Join-Path $installDir $dirName) -Recurse -Force
}

$ctxScript = Join-Path $installDir "install_context_menu.ps1"
if (-not (Test-Path $ctxScript)) {
    throw "Missing $ctxScript"
}
& $ctxScript
if ($LASTEXITCODE -ne 0) {
    throw "install_context_menu.ps1 failed with exit code $LASTEXITCODE"
}

$installedExe = Join-Path $installDir "landrop.exe"
$wshShell = New-Object -ComObject WScript.Shell
$shortcutTargets = @(
    (Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\LanDrop.lnk"),
    (Join-Path $env:USERPROFILE "Desktop\LanDrop.lnk")
)

foreach ($lnkPath in $shortcutTargets) {
    $shortcut = $wshShell.CreateShortcut($lnkPath)
    $shortcut.TargetPath = $installedExe
    $shortcut.WorkingDirectory = $installDir
    $shortcut.Description = "LanDrop - Offline Local Network File Transfer"
    $shortcut.Save()
}

Start-Process -FilePath $installedExe -WorkingDirectory $installDir
Write-Host "LanDrop installed to $installDir, registered, shortcuts created, and launched." -ForegroundColor Green
