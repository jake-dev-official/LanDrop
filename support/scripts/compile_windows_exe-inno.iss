; Minimalist Inno Setup script for LanDrop Windows installer (Setup.exe)

#ifndef PayloadDir
  #define PayloadDir GetEnv("USERPROFILE") + "\Desktop\LanDrop-Release\LanDrop-1.0.0-Windows-x64"
#endif
#ifndef ResultDir
  #define ResultDir GetEnv("USERPROFILE") + "\Desktop\LanDrop-Release"
#endif

#define MyAppName "LanDrop"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "LanDrop"
#define MyAppURL "https://github.com/jake-dev-official/LanDrop"
#define MyAppExeName "landrop.exe"
#define MyAppMsixHelper "landrop_msix_helper.msix"

[Setup]
AppId={{8C4F3E19-5B2A-4D7E-9A11-6F8B2E40C3D5}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={autopf}\{#MyAppName}
DirExistsWarning=no
DisableWelcomePage=yes
DisableProgramGroupPage=yes
DisableReadyPage=yes
PrivilegesRequired=admin
OutputDir={#ResultDir}
OutputBaseFilename=LanDrop-{#MyAppVersion}-Setup
SetupIconFile=..\..\app\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern dynamic
WizardImageFile=..\build\windows\inno\wizard_sidebar.png
WizardSmallImageFile=..\build\windows\inno\wizard_small.png
WizardImageStretch=yes
#ifndef SkipSignTool
SignTool=MySignTool
#endif
ArchitecturesInstallIn64BitMode=x64compatible
ArchitecturesAllowed=x64compatible

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Messages]
SetupWindowTitle=LanDrop Setup
WizardSelectDir=Install LanDrop
SelectDirDesc=Version {#MyAppVersion} • Offline LAN file transfer
SelectDirLabel3=Choose where to install LanDrop.
WizardInstalling=Installing LanDrop
InstallingLabel=Please wait while LanDrop is set up on your PC...
FinishedHeadingLabel=LanDrop is ready
FinishedLabel=LanDrop has been installed on your computer.
FinishedLabelNoIcons=LanDrop has been installed on your computer.

[Files]
Source: "inno_postinstall.ps1"; DestDir: "{tmp}"; Flags: deleteafterinstall
Source: "{#PayloadDir}\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PayloadDir}\*.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PayloadDir}\data\*"; DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\build\windows\x64\*.dll"; DestDir: "{app}"; Flags: ignoreversion
#ifndef SkipMsixHelper
Source: "{#PayloadDir}\{#MyAppExeName}.manifest"; DestDir: "{app}"; Flags: ignoreversion; Check: IsContextMenuChecked
Source: "{#PayloadDir}\{#MyAppMsixHelper}"; DestDir: "{app}"; Flags: ignoreversion; Check: IsContextMenuChecked
Source: "{#PayloadDir}\landrop_signing.cer"; DestDir: "{app}"; Flags: ignoreversion; Check: IsContextMenuChecked
Source: "{#PayloadDir}\resources.pri"; DestDir: "{app}"; Flags: ignoreversion; Check: IsContextMenuChecked
Source: "{#PayloadDir}\Images\*"; DestDir: "{app}\Images"; Flags: ignoreversion; Check: IsContextMenuChecked
#endif

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; Check: IsDesktopShortcutChecked

[Run]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{tmp}\inno_postinstall.ps1"" -Action InstallFirewall -AppDir ""{app}"""; Flags: runhidden waituntilterminated; StatusMsg: "Configuring local network access..."
#ifndef SkipMsixHelper
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{tmp}\inno_postinstall.ps1"" -Action InstallShell -AppDir ""{app}"""; Flags: runhidden waituntilterminated; Check: IsContextMenuChecked; StatusMsg: "Registering Windows 11 integration..."
#endif
Filename: "{app}\{#MyAppExeName}"; Description: "Launch LanDrop"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -Command ""Get-Process -Name landrop -ErrorAction SilentlyContinue | Stop-Process -Force"""; Flags: runhidden waituntilterminated; RunOnceId: "CloseApp"
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -Command ""$exe = '{app}\{#MyAppExeName}'; $lnk = Join-Path ([Environment]::GetFolderPath('SendTo')) '{#MyAppName}.lnk'; if ((Test-Path -LiteralPath $lnk) -and (New-Object -ComObject WScript.Shell).CreateShortcut($lnk).TargetPath -eq $exe) {{ Remove-Item -LiteralPath $lnk }"""; WorkingDir: "{app}"; Flags: runhidden waituntilterminated; RunOnceId: "RemoveSendToShortcut"
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -Command ""Get-NetFirewallRule -DisplayName 'LanDrop Inbound TCP','LanDrop Inbound UDP' -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue"""; Flags: runhidden waituntilterminated; Check: IsAdminInstallMode; RunOnceId: "DeleteNamedFirewallRules"
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=all program=""{app}\{#MyAppExeName}"""; Flags: runhidden waituntilterminated; Check: IsAdminInstallMode; RunOnceId: "DeleteProgramFirewallRules"
#ifndef SkipMsixHelper
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -Command ""Get-AppxPackage -Name 'LanDrop.App' -ErrorAction SilentlyContinue | Remove-AppxPackage -ErrorAction SilentlyContinue"""; Flags: runhidden waituntilterminated; RunOnceId: "RemoveAppx"
#endif

[Code]
var
  DesktopShortcutCheck: TNewCheckBox;
  ContextMenuCheck: TNewCheckBox;

procedure InitializeWizard();
var
  TopPos: Integer;
begin
  TopPos := WizardForm.DirEdit.Top + WizardForm.DirEdit.Height + ScaleY(26);

  DesktopShortcutCheck := TNewCheckBox.Create(WizardForm);
  DesktopShortcutCheck.Parent := WizardForm.SelectDirPage;
  DesktopShortcutCheck.Left := WizardForm.DirEdit.Left;
  DesktopShortcutCheck.Top := TopPos;
  DesktopShortcutCheck.Width := WizardForm.SelectDirPage.Width - WizardForm.DirEdit.Left - ScaleX(8);
  DesktopShortcutCheck.Height := ScaleY(22);
  DesktopShortcutCheck.Caption := 'Create a desktop shortcut';
  DesktopShortcutCheck.Checked := True;

  ContextMenuCheck := TNewCheckBox.Create(WizardForm);
  ContextMenuCheck.Parent := WizardForm.SelectDirPage;
  ContextMenuCheck.Left := WizardForm.DirEdit.Left;
  ContextMenuCheck.Top := TopPos + ScaleY(30);
  ContextMenuCheck.Width := DesktopShortcutCheck.Width;
  ContextMenuCheck.Height := ScaleY(22);
  ContextMenuCheck.Caption := 'Add Windows 11 right-click menu ("Send with LanDrop")';
  ContextMenuCheck.Checked := True;
end;

function IsDesktopShortcutChecked(): Boolean;
begin
  Result := DesktopShortcutCheck.Checked;
end;

function IsContextMenuChecked(): Boolean;
begin
  Result := ContextMenuCheck.Checked;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
begin
  Exec('powershell.exe',
    '-NoProfile -ExecutionPolicy Bypass -Command "Get-Process -Name landrop -ErrorAction SilentlyContinue | Stop-Process -Force"',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Result := '';
end;

const
  RunKey = 'Software\Microsoft\Windows\CurrentVersion\Run';
  RunValue = 'LanDrop';

function IsAppExe(Path: String): Boolean;
begin
  Result := CompareText(Path, ExpandConstant('{app}\{#MyAppExeName}')) = 0;
end;

function CommandExe(Command: String): String;
var
  P: Integer;
begin
  Result := Trim(Command);
  if (Length(Result) > 0) and (Result[1] = '"') then
  begin
    Delete(Result, 1, 1);
    P := Pos('"', Result);
    if P > 0 then
      Result := Copy(Result, 1, P - 1);
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Value: String;
begin
  if (CurUninstallStep = usPostUninstall) and RegQueryStringValue(HKCU, RunKey, RunValue, Value) and IsAppExe(CommandExe(Value)) then
    RegDeleteValue(HKCU, RunKey, RunValue);
end;
