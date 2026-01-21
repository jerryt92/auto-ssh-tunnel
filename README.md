简体中文 | [English](README_en.md)

## auto-ssh-tunnel（Windows）

在 Windows 上用 `ssh.exe` 建立 **反向端口转发（Remote Port Forwarding）**，把你本机的 RDP（默认 3389）映射到远端服务器端口，从而实现“从外网连到家里/办公室 Windows 的远程桌面”。

本项目提供：

- `run.ps1`：启动并保持 SSH 隧道（断线自动重连），写入 `debug_log*.txt` 便于排查
- `stop.ps1`：停止正在运行的实例
- `register_as_task.ps1`：注册“用户登录时自动启动”的计划任务（需要管理员权限）
- `unregister_task.ps1`：注销计划任务（需要管理员权限）
- `config.json`：配置 SSH 目标与端口转发规则

---

## 前置条件

### 1) Windows OpenSSH 客户端

确保 `ssh.exe` 可用：

```powershell
ssh -V
```

输出类似 `OpenSSH_for_Windows_...` 即可。

### 2) 远端服务器允许端口转发

你要连接的服务器（`SshTarget`）需要满足：

- 你能用私钥 SSH 登陆（无交互）
- `sshd` 允许远程端口转发（通常需要 `AllowTcpForwarding yes`）
- 如果你要让远端端口对公网开放（`0.0.0.0:PORT`），服务器侧通常还需要 `GatewayPorts yes`
- 服务器防火墙/云安全组放通对应端口（例如 3389 或你自定义的 13389/443 等）

> 注意：`run.ps1` 默认加了 `StrictHostKeyChecking=no` 与 `UserKnownHostsFile=NUL`，用于无人值守运行；更严格的安全需求请自行调整。

### 3) 本机 RDP 服务

本机需开启远程桌面并确保 3389 在监听：

```powershell
Get-NetTCPConnection -LocalPort 3389 -State Listen
```

---

## 私钥放置（默认路径）

`run.ps1` 会按以下顺序查找 SSH 私钥：

1. `$HOME\.ssh\id_ed25519`
2. `$HOME\.ssh\id_rsa`
3. `$env:USERPROFILE\.ssh\id_ed25519`
4. `$env:USERPROFILE\.ssh\id_rsa`
5. 项目目录下的 `id_ed25519` / `id_rsa`（兼容旧版）

运行时会在 `debug_log.txt` 写出实际使用的 key 路径（`Using SSH key: ...`）。

### 开机即跑（SYSTEM 运行）时的私钥建议

当计划任务以 **SYSTEM** 运行时，通常 **拿不到你的用户目录**（`$HOME\.ssh\...`）里的私钥。推荐二选一：

- **放到项目目录**：`.\id_ed25519`（最简单）
- **放到 ProgramData**：`C:\ProgramData\rdp-ssh-tunnel\id_ed25519`（更规范）

也可以在 `config.json` 的隧道条目里增加 `KeyPath` 显式指定（相对路径会相对项目目录解析）：

```json
{
  "taskName": "AutoSSHTunnel",
  "sshTunnel": [
    {
      "KeyPath": "id_ed25519"
    }
  ]
}
```

---

## 配置说明（config.json）

当前版本推荐使用如下结构（支持多个隧道）：

```json
{
  "taskName": "AutoSSHTunnel",
  "sshTunnel": [
    {
      "SshTarget": "root@server.example.com",
      "ForwardRules": "-R 0.0.0.0:3389:127.0.0.1:3389",
      "ReconnectInterval": 30
    }
  ]
}
```

- **taskName**：计划任务名称（例如 `AutoSSHTunnel`）
- **sshTunnel**：隧道数组，每个元素包含：
  - **SshTarget**：SSH 目标（`user@host` 或 `user@ip`）
  - **ForwardRules**：转发规则字符串（会按空格拆分传给 `ssh.exe`）
    - 常见：`-R 0.0.0.0:远端端口:127.0.0.1:本机端口`
    - 建议把“远端端口”换成不容易被封的端口（例如 13389/8443/443），避免外部网络屏蔽 3389
  - **ReconnectInterval**：SSH 断开后多少秒重连；设为 `0` 则退出
  - **KeyPath**（可选）：私钥路径（相对路径相对项目目录）

### 日志与多隧道行为

- **只有 1 条隧道**：日志写到 `debug_log.txt`
- **有多条隧道**：`run.ps1` 会并行启动，并分别写到 `debug_log_<名字>.txt`
  - `<名字>` 会自动生成：
    - 第一条：`<taskName>_0`
    - 第二条：`<taskName>_1`
    - 以此类推

---

## 手动运行（建议先跑通再上计划任务）

在项目根目录运行：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\run.ps1
```

会生成/追加 `debug_log*.txt`（见上面“日志与多隧道行为”）。

停止：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\stop.ps1
```

---

## 计划任务：开机/登录自动启动

### 注册（需要管理员权限）

> `register_as_task.ps1` 需要管理员写入任务计划。任务本身会以你当前登录的用户身份运行。

运行：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\register_as_task.ps1
```

> 使用当前推荐的 `taskName + sshTunnel[]` 配置时，计划任务名直接取 `taskName`，无需额外参数。

如果你不是管理员运行，它会尝试自动提权并弹出 UAC。

> 当前版本默认注册的是 **开机触发（AtStartup）+ 指定用户运行**。为了“未登录也能跑”，任务计划需要保存一次该用户的密码（Windows 机制）。
>
> 任务执行宿主默认使用 `pwsh.exe`（PowerShell 7）。如果机器上没有安装 PowerShell 7，则回退到 `powershell.exe`（Windows PowerShell 5.1）。
> 如果你不想保存密码，可以用 `-RunAsSystem` 让任务以 SYSTEM 运行，但此时通常拿不到用户目录里的私钥，需要把 key 放到项目目录/ProgramData 或用 `KeyPath` 指定。

### 注销（需要管理员权限）

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\unregister_task.ps1
```

同样支持选择数组中的某一条：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\unregister_task.ps1 -ConfigIndex 0
pwsh -NoProfile -ExecutionPolicy Bypass -File .\unregister_task.ps1 -ServiceName "RdpSSHTunnelService"
```

> 说明：上面 `-ConfigIndex/-ServiceName` 仅用于兼容旧版“数组根节点 + ServiceName”的配置格式；如果你用的是 `taskName + sshTunnel[]`，直接运行不带参数的注销命令即可。

---

## 改 config.json 后要不要重新注册？

- **不需要重新注册**：`run.ps1` 每次启动都会读取 `config.json`，所以改配置后只要 **重启隧道** 即可生效。
- 让新配置生效的方法：
  - 运行 `stop.ps1` 停掉旧实例
  - 再运行 `run.ps1`（或让计划任务重启一次/注销再登录）

---

## 目录（项目路径）改动后要不要重新注册？

**需要**。

计划任务里保存了 `run.ps1` 的绝对路径与工作目录；你把仓库挪位置后，任务仍指向旧路径，会导致任务启动失败（通常也就不会生成新的 `debug_log.txt`）。

解决：

1. 以管理员运行 `unregister_task.ps1`
2. 以管理员运行 `register_as_task.ps1`

---

## 常见问题排查

### 1) 没有生成 debug_log.txt

通常是 **`run.ps1` 没有被启动**：

- 计划任务未注册（未用管理员运行注册脚本）
- 计划任务仍指向旧目录（你挪动了项目路径）

### 2) SSH 能连，但转发没起来/立刻退出

`run.ps1` 使用了：

- `BatchMode=yes`：禁止交互式输入（没权限/没 key 会直接失败）
- `ExitOnForwardFailure=yes`：远端端口绑定失败会直接退出并重连

看 `debug_log.txt` 中 `SSH process exited with code: ...` 以及附近错误输出。

常见原因：

- 远端端口已被占用（例如服务器上已经有 `sshd` 在监听该端口）
- 服务器 `sshd_config` 禁止转发或不允许对公网开放
- 云安全组/iptables 未放通远端端口

### 3) 外网连不上远端 3389

很多网络环境会屏蔽 3389。建议改成其它端口，例如：

- `ForwardRules`: `-R 0.0.0.0:13389:127.0.0.1:3389`

然后用 `mstsc` 连接：

- 主机：`server.example.com:13389`

### 4) 快速自检命令

- 看 ssh 进程是否存在：

```powershell
Get-Process -Name ssh -ErrorAction SilentlyContinue
```

- 测试远端端口是否可达（在本机跑）：

```powershell
Test-NetConnection server.example.com -Port 13389
```

- 测试 SSH 免交互登录（在本机跑）：

```powershell
ssh -o BatchMode=yes -o ConnectTimeout=8 user@server.example.com exit
echo $LASTEXITCODE
```

---

## 安全提示

- `ForwardRules` 里用 `0.0.0.0:PORT` 会把远端端口暴露到公网；请用防火墙/安全组限制来源 IP，或改成只监听 `127.0.0.1:PORT` 并通过 VPN/跳板访问。
- `StrictHostKeyChecking=no` 便于无人值守，但降低了对中间人攻击的防护；生产环境建议固定 known_hosts。

