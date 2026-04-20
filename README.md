# AVD Auto-Mount SMB Share (Logon-Triggered)

A one-shot PowerShell installer that configures any Windows VM (AVD Session Host / regular Windows 10/11) so that every user gets a persistent SMB drive letter automatically mounted **on every logon**, even if the VM reboots and whatever user logs in.

Built and battle-tested against Azure Virtual Desktop on **Azure China (21Vianet)** with Windows 11 Enterprise session hosts joined to AD DS, authenticating to a third-party SMB server with per-user credentials (`cmdkey`).

---

## Features

- ✅ **Logon trigger** — mounts for any user in `BUILTIN\Users` on logon (no hard-coded username).
- ✅ **Fully parameterized** — pass `SmbPath` / `SmbUser` / `SmbPass` at run time; no secrets in the script.
- ✅ **CJK / Chinese UNC path support** — bat file written in GBK (code page 936) with CRLF line endings.
- ✅ **Idempotent** — cleans stale `HKCU\Network\<drive>` entries and prior `net use` mappings before reconnecting.
- ✅ **Remote-deploy friendly** — runs end-to-end via `az vm run-command` (SYSTEM context) with no polluting SYSTEM-scope mappings.
- ✅ **AMSI-safe** — avoids `Register-ScheduledTask` / `[Convert]::FromBase64String` that some Defender policies silently block in run-command sessions; uses `schtasks.exe + XML` instead.
- ✅ **Pure ASCII source** — the .ps1 file itself contains zero non-ASCII bytes, which avoids PowerShell 5.1 GBK-vs-UTF8-BOM parsing traps when piped through run-command.

---

## What gets installed on the target VM

| Artifact | Purpose |
|---|---|
| `C:\Scripts\mount-share-<L>.bat` | GBK+CRLF batch: clears stale mapping, re-caches creds, `net use`. |
| `C:\Scripts\AutoMountSharedDrive_<L>.xml` | UTF-16-LE-BOM scheduled-task definition. |
| Scheduled Task `AutoMountSharedDrive_<L>` | Triggers on **any** user logon (`BUILTIN\Users`, LeastPrivilege). |

`<L>` = drive letter, default `I`.

---

## Prerequisites

- Windows 10/11 or Windows Server with PowerShell 5.1+
- Local Administrator rights on the target VM
- Network reachability to the SMB server on TCP 445
- (Optional) Azure CLI installed and `az login`ed for remote deployment

---

## One-shot Usage

### 1. Run locally on a session host (as Administrator)

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-AutoMountShare.ps1 `
    -SmbPath '\\10.160.9.188\BlueberryShare\sub\path\A0072439' `
    -SmbUser 'A0072439' `
    -SmbPass 'somePassword'
```

CJK (Chinese) paths are supported directly at the parameter — the installer encodes the generated batch file in GBK:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-AutoMountShare.ps1 `
    -SmbPath '\\fileserver\sharepoint\个人盘\A0072439' `
    -SmbUser 'A0072439' -SmbPass 'p@ssw0rd'
```

### 2. Remote deploy to a single Azure VM

```bash
az vm run-command invoke \
    -g <ResourceGroup> -n <VmName> \
    --command-id RunPowerShellScript \
    --scripts @Install-AutoMountShare.ps1 \
    --parameters "SmbPath=\\\\server\\share\\path" \
                 "SmbUser=<USER>" \
                 "SmbPass=<PASSWORD>" \
    -o tsv --query "value[0].message"
```

### 3. Batch deploy to multiple session hosts with per-user credentials

```bash
declare -A VM_USER=(
  [avd-cpu-u1]="A0000001:pass1"
  [avd-cpu-u2]="A0000002:pass2"
  [avd-gpu-u6]="A0072439:somePassword"
)
RG='rg-avd-haier-20260312'
SHARE_BASE='\\10.160.9.188\BlueberryShare\sub\path'

for vm in "${!VM_USER[@]}"; do
  IFS=':' read -r user pass <<< "${VM_USER[$vm]}"
  az vm run-command invoke -g "$RG" -n "$vm" \
      --command-id RunPowerShellScript \
      --scripts @Install-AutoMountShare.ps1 \
      --parameters "SmbPath=${SHARE_BASE}\\${user}" \
                   "SmbUser=${user}" \
                   "SmbPass=${pass}" \
      -o tsv --query "value[0].message"
done
```

---

## Parameters

| Name | Required | Default | Description |
|---|---|---|---|
| `-SmbPath`     | ✅ | —   | Full UNC path, e.g. `\\server\share\folder` (CJK OK). |
| `-SmbUser`     | ✅ | —   | SMB username. |
| `-SmbPass`     | ✅ | —   | SMB password. |
| `-DriveLetter` |    | `I` | Single letter A–Z. |
| `-TaskName`    |    | `AutoMountSharedDrive_<L>` | Scheduled-task name. |

---

## Verify after install

```powershell
# Show scheduled task
schtasks /Query /TN AutoMountSharedDrive_I /FO LIST

# Trigger manually (runs as whoever is currently logged in)
schtasks /Run /TN AutoMountSharedDrive_I

# Inside the logged-in user's session, confirm
net use
dir I:\
```

For a fresh effect, **log off and log back in** — the `Users` logon trigger mounts the drive in the user's own session. Note that an elevated admin PowerShell can't see user-session mappings due to UAC token split; verify with an ordinary Explorer window.

---

## Uninstall

```powershell
schtasks /Delete /TN AutoMountSharedDrive_I /F
Remove-Item C:\Scripts\mount-share-I.bat, C:\Scripts\AutoMountSharedDrive_I.xml -Force
net use I: /delete /y        # remove current mapping (per user)
reg delete HKCU\Network\I /f # remove persistent mapping record
cmdkey /delete:<smbserver>    # remove cached credential
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Drive shows **"Disconnected network drive"** in Explorer | Stale `HKCU\Network\<L>` + no active mount | The installed task auto-fixes on next logon; or run `schtasks /Run /TN AutoMountSharedDrive_I`. |
| `System error 85 - Local device name already in use` | Drive letter is held by SYSTEM (e.g. left over from an elevated test) | `Remove-SmbMapping -LocalPath I: -Force -UpdateProfile` (as admin) then logoff/logon. |
| Task shows `LastResult=2` with no log | Early bat parse failure (e.g. LF-only line endings) | This installer already writes CRLF; re-run installer to refresh bat. |
| Ping to SMB server fails but mount works | ICMP blocked, 445 open — normal. |  |
| Chinese path displays as `????` or garbled in logs | Viewer used wrong codepage — the .bat itself is correct GBK | Read the log with `[Text.Encoding]::GetEncoding(936)`. |

Enable diagnostic logging temporarily by editing `C:\Scripts\mount-share-I.bat` to redirect each step's output into `C:\Users\Public\AutoMountLogs\mount-%USERNAME%.log` and re-run `schtasks /Run`.

---

## Design notes

1. **Why `schtasks + XML` instead of `Register-ScheduledTask`?**
   In some hardened Windows images (notably Azure-managed AVD images running under the RunCommand extension), the `ScheduledTasks` PowerShell module is blocked by AMSI, silently returning no error and no registered task. `schtasks.exe` with a pre-built XML is universally reliable.

2. **Why don't we pre-mount during install?**
   The installer runs under SYSTEM (via run-command) or an elevated admin. A `net use I: …` from that context pins the letter in the *global device namespace*, making later user-session mounts fail with error 85. We only write the bat + register the task; the mount happens at user logon.

3. **Why re-derive `SmbServer` from the UNC path?**
   `cmdkey /add:<server>` needs the exact hostname; deriving it from `\\server\share\…` ensures `cmdkey` and `net use` agree.

4. **Why write the bat in GBK, not UTF-8?**
   Legacy `cmd.exe` on Chinese Windows parses .bat files in the OEM codepage (936 / GBK by default on zh-CN). UTF-8 without BOM causes mis-decoding; UTF-8 with BOM breaks the very first `@echo off` line.

---

## License

MIT
