# stop.ps1
$ScriptPath = $PSScriptRoot
$ConfigPath = Join-Path $ScriptPath "config.json"
$RawConfig = Get-Content $ConfigPath | ConvertFrom-Json
$Configs = @()
if ($RawConfig -and ($RawConfig.PSObject.Properties.Name -contains 'sshTunnel')) {
    $Configs = @($RawConfig.sshTunnel)
} elseif ($RawConfig -is [System.Array]) {
    $Configs = @($RawConfig)
} else {
    $Configs = @($RawConfig)
}

# 新 schema 没有 ServiceName，这里仅在存在时尝试 Stop-Service
$ServiceNames = @($Configs | ForEach-Object { $_.ServiceName } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)

# 1. 检查是否作为服务运行
foreach ($ServiceName in $ServiceNames) {
    $ServiceStatus = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($ServiceStatus -and $ServiceStatus.Status -eq 'Running') {
        Write-Host "Service '$ServiceName' is running. Stopping service..." -ForegroundColor Yellow
        Stop-Service -Name $ServiceName
        Write-Host "Service stopped." -ForegroundColor Green
    }
}

# 2. 检查是否有手动运行的实例 (通过互斥锁检查不太容易直接Kill，这里用WMI查找)
# 注意：为了简化，这里查找命令行包含脚本路径的 PowerShell 进程
$Processes = Get-CimInstance Win32_Process | Where-Object { 
    $_.CommandLine -like "*run.ps1*" -and ($_.Name -eq "powershell.exe" -or $_.Name -eq "pwsh.exe")
}

if ($Processes) {
    foreach ($proc in $Processes) {
        # 排除当前进程
        if ($proc.ProcessId -ne $PID) {
            Write-Host "Stopping process ID $($proc.ProcessId)..." -ForegroundColor Yellow
            # 先尝试杀掉其子 ssh 进程，避免留下孤儿隧道
            try {
                $childSsh = Get-CimInstance Win32_Process | Where-Object { $_.Name -eq "ssh.exe" -and $_.ParentProcessId -eq $proc.ProcessId }
                foreach ($c in $childSsh) {
                    Write-Host "Stopping child ssh.exe PID $($c.ProcessId)..." -ForegroundColor Yellow
                    Stop-Process -Id $c.ProcessId -Force -ErrorAction SilentlyContinue
                }
            } catch { }
            Stop-Process -Id $proc.ProcessId -Force
        }
    }
    # 同时也杀掉残留的 ssh 进程 (可选，风险较高，建议仅杀掉子进程，但在Windows这很复杂)
    # 简单做法：run.ps1 被杀掉后，ssh 进程通常会因为父进程消失或管道断开而关闭
    Write-Host "Manual tunnel instance stopped." -ForegroundColor Green
} else {
    Write-Host "No running instance found via Service or Process check." -ForegroundColor Gray
    Write-Host "Nothing to stop."
}

# 3) 兜底：精准停止本工具启动的 ssh.exe
# 说明：多隧道模式会用 Start-Job 生成额外 pwsh.exe 子进程，其命令行不一定包含 run.ps1，
# 导致上面的“按 run.ps1 查进程”漏杀。这里按 ssh.exe 的命令行特征兜底。
try {
    $targets = @($Configs | ForEach-Object { $_.SshTarget } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    if ($targets.Count -gt 0) {
        $allSsh = @(Get-CimInstance Win32_Process | Where-Object { $_.Name -eq "ssh.exe" })
        $killed = 0
        foreach ($t in $targets) {
            # 同时要求包含我们 run.ps1 固定附加的参数，避免误杀你手动开的 ssh 会话
            $matches = @($allSsh | Where-Object {
                $_.CommandLine -and
                ($_.CommandLine -like "*$t*") -and
                ($_.CommandLine -like "*ExitOnForwardFailure=yes*") -and
                ($_.CommandLine -like "*UserKnownHostsFile=NUL*")
            })
            foreach ($m in $matches) {
                Write-Host "Stopping tunnel ssh.exe PID $($m.ProcessId) (target=$t)..." -ForegroundColor Yellow
                Stop-Process -Id $m.ProcessId -Force -ErrorAction SilentlyContinue
                $killed++
            }
        }
        if ($killed -gt 0) {
            Write-Host "Stopped $killed ssh.exe tunnel process(es)." -ForegroundColor Green
        }
    }
} catch { }