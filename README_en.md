[Simplified Chinese](README.md) | English

## auto-ssh-tunnel (Windows)

This project uses Windows `ssh.exe` to keep an SSH tunnel alive (auto-reconnect). It’s mainly aimed at **remote port forwarding** (e.g. exposing your local RDP 3389 through a remote server port).

Included scripts:

- `run.ps1`: start and keep the tunnel(s) alive (auto-reconnect), logs to `debug_log*.txt`
- `stop.ps1`: stop the running instance(s)
- `register_as_task.ps1`: register a scheduled task to auto-start on boot (admin required)
- `unregister_task.ps1`: remove the scheduled task (admin required)
- `config.json`: tunnel configuration

---

## Prerequisites

### 1) Windows OpenSSH client

Make sure `ssh.exe` is available:

```powershell
ssh -V
```

### 2) Server allows port forwarding

Your SSH server should allow remote port forwarding:

- `AllowTcpForwarding yes`
- If you bind `0.0.0.0:PORT` on the server side, you typically also need `GatewayPorts yes`
- Open the port in firewall / security group

> Note: `run.ps1` uses `StrictHostKeyChecking=no` and `UserKnownHostsFile=NUL` for unattended runs. Tighten these if you need stronger security.

### 3) Local RDP is listening

```powershell
Get-NetTCPConnection -LocalPort 3389 -State Listen
```

---

## SSH key location

`run.ps1` searches keys in this order:

1. `~\.ssh\id_ed25519`
2. `~\.ssh\id_rsa`
3. `%USERPROFILE%\.ssh\id_ed25519`
4. `%USERPROFILE%\.ssh\id_rsa`
5. `.\id_ed25519` / `.\id_rsa` (project directory)

You can also set `KeyPath` in `config.json` (relative paths are resolved from the project folder):

```json
[
  {
    "KeyPath": "id_ed25519"
  }
]
```

---

## Configuration (`config.json`)

Recommended schema (supports multiple tunnels):

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

- **taskName**: the Windows Scheduled Task name (e.g. `AutoSSHTunnel`)
- **sshTunnel**: an array of tunnels. Each item contains:
  - **SshTarget**: SSH target (`user@host` or `user@ip`)
  - **ForwardRules**: forwarding rules string (split by spaces and passed to `ssh.exe`)
  - **ReconnectInterval**: seconds to wait before reconnect; `0` means exit
  - **KeyPath** (optional): SSH private key path (relative to the project folder)

### Logs & multi-tunnel behavior

- **Single tunnel**: writes to `debug_log.txt`
- **Multiple tunnels**: `run.ps1` starts them in parallel and writes `debug_log_<name>.txt` per tunnel
  - `<name>` is auto-generated as `<taskName>_0`, `<taskName>_1`, ...

---

## Run manually

From project root:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\run.ps1
```

Stop:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\stop.ps1
```

---

## Scheduled task (auto-start on boot)

Register (admin required):

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\register_as_task.ps1
```

> With the recommended `taskName + sshTunnel[]` schema, the task name is taken from `taskName` and you don't need extra parameters.

Unregister (admin required):

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\unregister_task.ps1
```

Also supports selecting the entry:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\unregister_task.ps1 -ConfigIndex 0
pwsh -NoProfile -ExecutionPolicy Bypass -File .\unregister_task.ps1 -ServiceName "RdpSSHTunnelService"
```

> Note: `-ConfigIndex/-ServiceName` are only for the legacy schema where `config.json` is an array of entries with `ServiceName`.

---

## Security notes

- `0.0.0.0:PORT` exposes the server-side port to the public internet. Restrict it with firewall/security group rules, or bind to `127.0.0.1:PORT` and access via VPN/bastion.
- Disabling host key checking is convenient but reduces MITM protection. Consider pinning `known_hosts` for production use.

