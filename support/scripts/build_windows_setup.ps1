param(
    [string]$PayloadDir = (Join-Path $env:USERPROFILE "Desktop\LanDrop-Release\LanDrop-1.0.0-Windows-x64"),
    [string]$ResultDir = (Join-Path $env:USERPROFILE "Desktop\LanDrop-Release")
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $PayloadDir)) {
    throw "Missing PayloadDir: $PayloadDir"
}
if (-not (Test-Path $ResultDir)) {
    New-Item -ItemType Directory -Path $ResultDir -Force | Out-Null
}

$signtool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Recurse -Filter "signtool.exe" -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match "\\x64\\signtool\.exe$" } |
    Sort-Object FullName -Descending |
    Select-Object -First 1
if (-not $signtool) {
    throw "signtool.exe (x64) not found under Windows Kits 10."
}

$iscc = Get-Command iscc.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue
if (-not $iscc) {
    $found = Get-ChildItem "C:\Program Files (x86)\Inno Setup*", "C:\Program Files\Inno Setup*", "$env:LOCALAPPDATA\Programs\Inno Setup*" -Filter "iscc.exe" -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($found) { $iscc = $found.FullName }
}
if (-not $iscc) {
    throw "iscc.exe (Inno Setup) not found."
}

$msixPath = Join-Path $PayloadDir "landrop_msix_helper.msix"
if (-not (Test-Path $msixPath)) {
    throw "Missing MSIX helper in payload: $msixPath"
}

$minValidity = (Get-Date).AddYears(5)
$cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert |
    Where-Object { $_.Subject -eq "CN=LanDrop" -and $_.NotAfter -gt $minValidity } |
    Sort-Object NotAfter -Descending |
    Select-Object -First 1

if (-not $cert) {
    Write-Host "Creating 10-year self-signed code signing certificate (CN=LanDrop)..." -ForegroundColor Cyan
    $cert = New-SelfSignedCertificate -Type Custom -Subject "CN=LanDrop" -KeyUsage DigitalSignature `
        -FriendlyName "LanDrop Sparse Package Signing Cert" -CertStoreLocation "Cert:\CurrentUser\My" `
        -NotAfter (Get-Date).AddYears(10) `
        -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3", "2.5.29.19={text}")
}

Write-Host "Pre-signing landrop_msix_helper.msix (thumbprint $($cert.Thumbprint), valid until $($cert.NotAfter))..."
& $signtool.FullName sign /fd SHA256 /sha1 $cert.Thumbprint $msixPath
if ($LASTEXITCODE -ne 0) {
    throw "signtool failed with exit code $LASTEXITCODE"
}

$cerPath = Join-Path $PayloadDir "landrop_signing.cer"
Export-Certificate -Cert $cert -FilePath $cerPath -Force | Out-Null

$issPath = Join-Path $PSScriptRoot "compile_windows_exe-inno.iss"
Write-Host "Compiling Inno Setup installer via $iscc ..."
& $iscc "/DPayloadDir=$PayloadDir" "/DResultDir=$ResultDir" "/DSkipSignTool" $issPath
if ($LASTEXITCODE -ne 0) {
    throw "iscc.exe failed with exit code $LASTEXITCODE"
}

$outExe = Join-Path $ResultDir "LanDrop-1.0.0-Setup.exe"
if (-not (Test-Path $outExe)) {
    throw "Expected output installer missing: $outExe"
}
$info = Get-Item $outExe
Write-Host ("Built installer: {0} ({1:N2} MB)" -f $outExe, ($info.Length / 1MB)) -ForegroundColor Green
