# AVD 登录自动挂载 SMB 共享盘

一个开箱即用的 PowerShell 安装脚本，在任意 Windows 10/11（AVD Session Host 或普通 Windows 桌面）上配置：**任何用户登录时，自动把指定 SMB 共享挂载为固定盘符**（默认 `I:`），重启和切换用户后持续有效。

在 **Azure China（21Vianet）** 的 AVD 环境下实测通过，Windows 11 企业版会话主机加入本地 AD DS，连接到第三方 SMB 服务器，使用 `cmdkey` 缓存每用户凭据。

---

## 功能特性

- ✅ **登录触发**：计划任务在 `BUILTIN\Users` 组的任意用户登录时触发，不绑定具体用户名。
- ✅ **完全参数化**：运行时传入 `SmbPath` / `SmbUser` / `SmbPass`，脚本本身不包含任何凭据或路径。
- ✅ **支持中文 UNC 路径**：生成的 .bat 使用 GBK（代码页 936）+ CRLF 换行，中文路径不乱码。
- ✅ **幂等可重入**：挂载前清理历史 `HKCU\Network\<盘符>` 和 `net use` 残留，避免"断开的网络驱动器"。
- ✅ **远程部署友好**：通过 `az vm run-command` 在 SYSTEM 上下文完整执行，且**不会污染 SYSTEM 级盘符命名空间**。
- ✅ **绕过 AMSI 拦截**：使用 `schtasks.exe + XML` 注册任务，避免部分 Defender 策略静默拦截 `Register-ScheduledTask` / `[Convert]::FromBase64String`。
- ✅ **源码纯 ASCII**：脚本本体 0 个非 ASCII 字节，消除 PowerShell 5.1 把无 BOM 的 UTF-8 按 GBK 解析的隐患。

---

## 目标机器上会生成的内容

| 产物 | 作用 |
|---|---|
| `C:\Scripts\mount-share-<L>.bat` | GBK + CRLF 格式的批处理：清理残留 → 缓存凭据 → `net use`。 |
| `C:\Scripts\AutoMountSharedDrive_<L>.xml` | UTF-16-LE-BOM 的计划任务定义文件。 |
| 计划任务 `AutoMountSharedDrive_<L>` | 登录触发，运行身份 `BUILTIN\Users`，`LeastPrivilege`。 |

`<L>` = 盘符，默认 `I`。

---

## 前置条件

- Windows 10 / 11 或 Windows Server，PowerShell 5.1+
- 目标机器的本地管理员权限
- 能连通 SMB 服务器的 TCP 445
- （远程部署场景）已安装 Azure CLI 并 `az login`

---

## 一键部署用法

### 1. 在 Session Host 本机运行（管理员 PowerShell）

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-AutoMountShare.ps1 `
    -SmbPath '\\10.160.9.188\BlueberryShare\sub\path\A0072439' `
    -SmbUser 'A0072439' `
    -SmbPass 'somePassword'
```

中文路径可直接作为参数传入（脚本自动以 GBK 写入 .bat）：

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-AutoMountShare.ps1 `
    -SmbPath '\\fileserver\sharepoint\个人盘\A0072439' `
    -SmbUser 'A0072439' -SmbPass 'p@ssw0rd'
```

### 2. 远程部署到单台 Azure VM

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

### 3. 批量部署多台 Session Host（每台不同账号）

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

## 参数说明

| 名称 | 必填 | 默认值 | 说明 |
|---|---|---|---|
| `-SmbPath`     | ✅ | —   | 完整 UNC 路径，如 `\\server\share\folder`（支持中文）。 |
| `-SmbUser`     | ✅ | —   | SMB 用户名。 |
| `-SmbPass`     | ✅ | —   | SMB 密码。 |
| `-DriveLetter` |    | `I` | 单个字母 A–Z。 |
| `-TaskName`    |    | `AutoMountSharedDrive_<盘符>` | 计划任务名。 |

脚本会自动从 `SmbPath` 的前两段解析出 SMB 服务器主机名，用于 `cmdkey /add`。

---

## 安装后验证

```powershell
# 查看计划任务
schtasks /Query /TN AutoMountSharedDrive_I /FO LIST

# 手动触发（作为当前登录用户执行）
schtasks /Run /TN AutoMountSharedDrive_I

# 在用户会话中确认
net use
dir I:\
```

**推荐做法**：注销后重新登录 —— 任务会在用户自己的会话里挂载盘符。注意：由于 UAC 令牌拆分，**管理员 PowerShell 里看不到普通用户会话的映射**，应在资源管理器中确认。

---

## 卸载

```powershell
schtasks /Delete /TN AutoMountSharedDrive_I /F
Remove-Item C:\Scripts\mount-share-I.bat, C:\Scripts\AutoMountSharedDrive_I.xml -Force
net use I: /delete /y          # 移除当前映射（每用户）
reg delete HKCU\Network\I /f   # 移除持久化映射记录
cmdkey /delete:<smbserver>     # 移除缓存凭据
```

---

## 常见问题

| 现象 | 原因 | 解决方案 |
|---|---|---|
| 资源管理器显示**"断开的网络驱动器"** | `HKCU\Network\<L>` 有历史持久化项，但当前会话未挂载 | 任务会在下次登录自动修复；也可运行 `schtasks /Run /TN AutoMountSharedDrive_I`。 |
| `发生系统错误 85 - 本地设备名已在使用中` | 盘符被 SYSTEM 或管理员会话占用 | 以管理员身份执行 `Remove-SmbMapping -LocalPath I: -Force -UpdateProfile`，然后注销重登。 |
| 任务显示 `上次结果=2` 且无日志 | .bat 文件早期解析失败（例如 LF-only 换行） | 本脚本已写入 CRLF；重新运行安装脚本刷新 .bat 即可。 |
| Ping SMB 服务器失败但挂载成功 | ICMP 被防火墙拦截，445 端口正常——属于正常现象。 | — |
| 日志里中文显示为 `????` / 乱码 | 查看工具用了错误的代码页 | 用 `[Text.Encoding]::GetEncoding(936)` 读取日志文件。 |

如需定位问题，可临时编辑 `C:\Scripts\mount-share-I.bat`，把每一步输出追加到 `C:\Users\Public\AutoMountLogs\mount-%USERNAME%.log`，再 `schtasks /Run` 触发。

---

## 设计说明

1. **为什么用 `schtasks + XML` 而不是 `Register-ScheduledTask`？**
   某些加固过的 Windows 镜像（特别是 Azure AVD 镜像在 RunCommand 扩展里执行时），`ScheduledTasks` 模块会被 AMSI 静默拦截，既不报错也不会真的注册任务。`schtasks.exe + 预生成 XML` 的路径稳定可靠。

2. **为什么安装阶段不预挂载一次？**
   安装脚本运行在 SYSTEM（通过 run-command）或提升的管理员上下文。在这些上下文里 `net use I: ...` 会把盘符占到**全局设备命名空间**，导致后续用户会话挂载时报错 85。所以脚本只写入 .bat + 注册任务，真正的挂载发生在**用户登录时**。

3. **为什么要从 UNC 解析出 `SmbServer`？**
   `cmdkey /add:<主机>` 必须和 `net use` 指向完全一致的主机名；从 `\\server\share\…` 自动推导出第一段，保证两者一致。

4. **为什么 .bat 写成 GBK 而不是 UTF-8？**
   老版本 `cmd.exe` 在中文 Windows 上按 OEM 代码页（`zh-CN` 默认 936 / GBK）解析 .bat。无 BOM 的 UTF-8 会乱码；带 BOM 的 UTF-8 会破坏 `@echo off` 第一行。

---

## License

MIT
