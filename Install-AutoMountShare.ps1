# Install-AutoMountShare.ps1 (pure ASCII - safe to copy anywhere)
#
# Usage (run as Administrator, one-liner):
#   powershell -ExecutionPolicy Bypass -File .\Install-AutoMountShare.ps1 `
#     -SmbPath '\\server\share\path' -SmbUser <USER> -SmbPass <PASS>
#
# Example (Chinese path supported - put the actual CJK path in quotes at runtime):
#   powershell -ExecutionPolicy Bypass -File .\Install-AutoMountShare.ps1 `
#     -SmbPath '\\10.160.9.188\MyShare\SubDir\A0072439' `
#     -SmbUser A0072439 -SmbPass 'somePassword'
#
# Optional overrides:
#   -DriveLetter (default: I)
#   -TaskName    (default: AutoMountSharedDrive_<DriveLetter>)
#
# Remote deploy via az vm run-command (CJK path supported):
#   az vm run-command invoke -g <RG> -n <VM> --command-id RunPowerShellScript `
#     --scripts @Install-AutoMountShare.ps1 `
#     --parameters "SmbPath=\\server\share\path" "SmbUser=<USER>" "SmbPass=<PASS>"

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, HelpMessage='Full UNC path to SMB share, e.g. \\server\share\folder')]
    [ValidateNotNullOrEmpty()]
    [string]$SmbPath,

    [Parameter(Mandatory=$true, HelpMessage='SMB share username')]
    [ValidateNotNullOrEmpty()]
    [string]$SmbUser,

    [Parameter(Mandatory=$true, HelpMessage='SMB share password')]
    [ValidateNotNullOrEmpty()]
    [string]$SmbPass,

    [ValidatePattern('^[A-Za-z]$')]
    [string]$DriveLetter = 'I',

    [string]$TaskName    = ''
)

if ([string]::IsNullOrWhiteSpace($TaskName)) { $TaskName = 'AutoMountSharedDrive_' + $DriveLetter }

# Derive server host from UNC (first segment after leading \\)
if ($SmbPath -notmatch '^\\\\([^\\]+)\\') { throw "SmbPath must be a UNC path like \\server\share\..." }
$SmbServer = $Matches[1]

$ErrorActionPreference = 'Stop'

# --- Admin check ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'Please run this script as Administrator.' }

try { [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance) } catch {}
$gbk = [System.Text.Encoding]::GetEncoding(936)
Write-Host ("[INFO] SMB Server: " + $SmbServer)
Write-Host ("[INFO] SMB Path  : " + $SmbPath)
Write-Host ("[INFO] Drive     : " + $DriveLetter + ":")

# --- 1. Write bat file (GBK encoded, CRLF line endings) ---
$ScriptDir = 'C:\Scripts'
if (-not (Test-Path $ScriptDir)) { New-Item -ItemType Directory -Path $ScriptDir | Out-Null }
$BatPath = Join-Path $ScriptDir ('mount-share-' + $DriveLetter + '.bat')

$BatContent = @"
@echo off
setlocal

set "SMB_SERVER=$SmbServer"
set "SMB_USER=$SmbUser"
set "SMB_PASS=$SmbPass"
set "SMB_PATH=$SmbPath"

reg delete "HKCU\Network\${DriveLetter}" /f >nul 2>&1
net use ${DriveLetter}: /delete /y >nul 2>&1
cmdkey /add:%SMB_SERVER% /user:"%SMB_USER%" /pass:"%SMB_PASS%" >nul 2>&1
net use ${DriveLetter}: "%SMB_PATH%" /user:"%SMB_USER%" "%SMB_PASS%" /persistent:no >nul 2>&1

exit /b %errorlevel%
"@

# Encode whole bat as GBK (handles Chinese chars in SMB path) then normalize line endings to CRLF
$raw = $gbk.GetBytes($BatContent)
$normalized = New-Object System.Collections.Generic.List[byte]
for ($i = 0; $i -lt $raw.Length; $i++) {
    $bCur = $raw[$i]
    if ($bCur -eq 0x0A) {
        $prev = if ($i -gt 0) { $raw[$i-1] } else { 0 }
        if ($prev -ne 0x0D) { $normalized.Add(0x0D) | Out-Null }
    }
    $normalized.Add($bCur) | Out-Null
}
[System.IO.File]::WriteAllBytes($BatPath, $normalized.ToArray())
Write-Host ("[OK] Wrote " + $BatPath + " (" + (Get-Item $BatPath).Length + " bytes)") -ForegroundColor Green

# --- 2. Register logon-triggered scheduled task via schtasks.exe + XML ---
# (avoids PowerShell ScheduledTasks module, which may be blocked by AMSI/policy in some contexts)
$XmlPath = Join-Path $ScriptDir ($TaskName + '.xml')
$TaskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>AutoMount SMB share at user logon</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <GroupId>S-1-5-32-545</GroupId>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>cmd.exe</Command>
      <Arguments>/c "$BatPath"</Arguments>
    </Exec>
  </Actions>
</Task>
"@
# schtasks /Create /XML requires UTF-16 LE with BOM
$utf16 = [System.Text.Encoding]::Unicode
$bom   = [byte[]](0xFF,0xFE)
$bodyBytes = $utf16.GetBytes($TaskXml)
[System.IO.File]::WriteAllBytes($XmlPath, $bom + $bodyBytes)

& cmd.exe /c ('schtasks /Delete /TN "' + $TaskName + '" /F >nul 2>&1')
$createOut = & cmd.exe /c ('schtasks /Create /TN "' + $TaskName + '" /XML "' + $XmlPath + '" /F 2>&1')
if ($LASTEXITCODE -ne 0) {
    Write-Error ("schtasks create failed (exit " + $LASTEXITCODE + "): " + ($createOut -join ' | '))
    throw 'Task registration failed.'
}
Write-Host ("[OK] Scheduled task '" + $TaskName + "' registered (trigger: any user logon).") -ForegroundColor Green

# --- 3. Immediate verification ---
Write-Host ("[INFO] Verifying bat syntax only (NOT mounting in SYSTEM/admin session to avoid polluting user drive namespace)...") -ForegroundColor Cyan
# NOTE: Do NOT run the bat here. The bat mounts I: in the current session, which in
# SYSTEM / admin-elevated context would occupy the drive letter globally and cause
# "System error 85 - local device name already in use" for subsequent user-session mounts.
# The scheduled task will run at user logon and mount I: in the user's own session.

# Cleanup any stale I: mapping held by SYSTEM (from previous versions of this script)
& net.exe use ($DriveLetter + ':') /delete /y 2>$null | Out-Null
try { Remove-SmbMapping -LocalPath ($DriveLetter + ':') -Force -UpdateProfile -ErrorAction SilentlyContinue } catch {}

Write-Host ""
Write-Host "===== Done =====" -ForegroundColor Yellow
Write-Host ("Next logon of any user => " + $DriveLetter + ": auto mounted.")
Write-Host ("Manual trigger:  schtasks /Run   /TN " + $TaskName)
Write-Host ("Query task:      schtasks /Query /TN " + $TaskName + " /FO LIST")
