# run.ps1 (带日志诊断版)
# 兼容 config.json：
# - 旧格式：单对象（含 ServiceName）
# - 旧格式：数组（每项含 ServiceName）
# - 新格式：{ taskName: "...", sshTunnel: [ {SshTarget, ForwardRules, ReconnectInterval, (KeyPath)} ] }
param(
    [switch]$IsService,
    [int]$ConfigIndex = -1,
    [string]$ServiceName
)

$ScriptPath = $PSScriptRoot
$ConfigPath = Join-Path $ScriptPath "config.json"

function Resolve-ConfigList {
    param([object]$RawConfig)
    if ($null -eq $RawConfig) { return @() }
    if ($RawConfig -is [System.Array]) { return @($RawConfig) }
    return @($RawConfig)
}

function Read-ConfigFile {
    param([string]$Path)

    $raw = Get-Content $Path | ConvertFrom-Json

    # New schema: { taskName, sshTunnel: [] }
    if ($raw -and ($raw.PSObject.Properties.Name -contains 'sshTunnel')) {
        $taskName = $raw.taskName
        $entries = @($raw.sshTunnel)
        return @{
            TaskName = $taskName
            Entries  = $entries
            Schema   = 'taskName+sshTunnel'
        }
    }

    # Legacy schemas: object or array of objects
    $entries = Resolve-ConfigList -RawConfig $raw
    return @{
        TaskName = $null
        Entries  = $entries
        Schema   = 'legacy'
    }
}

function Normalize-Entries {
    param(
        [object[]]$Entries,
        [string]$TaskName
    )

    $out = @()
    for ($i = 0; $i -lt $Entries.Count; $i++) {
        $e = $Entries[$i]
        if ($null -eq $e) { continue }

        # Fill ServiceName if missing (needed for mutex/log identity)
        $sn = $null
        if ($e.PSObject.Properties.Name -contains 'ServiceName') { $sn = $e.ServiceName }

        if ([string]::IsNullOrWhiteSpace($sn)) {
            if ($Entries.Count -le 1) {
                $sn = $TaskName
            } else {
                $sn = "{0}_{1}" -f $TaskName, $i
            }
        }

        # If TaskName is still empty, fall back to ServiceName
        if ([string]::IsNullOrWhiteSpace($TaskName)) { $TaskName = $sn }

        # Build a normalized object
        $obj = [pscustomobject]@{
            SshTarget          = $e.SshTarget
            ForwardRules       = $e.ForwardRules
            ReconnectInterval  = $e.ReconnectInterval
            ServiceName        = $sn
        }

        if ($e.PSObject.Properties.Name -contains 'KeyPath') {
            Add-Member -InputObject $obj -NotePropertyName KeyPath -NotePropertyValue $e.KeyPath -Force
        }

        $out += $obj
    }
    return ,$out
}

function Select-Configs {
    param([object[]]$AllConfigs, [int]$Index, [string]$Name)

    if ($AllConfigs.Count -eq 0) { return @() }

    if (-not [string]::IsNullOrWhiteSpace($Name)) {
        $match = @($AllConfigs | Where-Object { $_.ServiceName -eq $Name })
        if ($match.Count -eq 0) { throw "No config entry matched ServiceName='$Name'." }
        return $match
    }

    if ($Index -ge 0) {
        if ($Index -ge $AllConfigs.Count) { throw "ConfigIndex out of range. Count=$($AllConfigs.Count), Index=$Index." }
        return @($AllConfigs[$Index])
    }

    return @($AllConfigs)
}

function Start-TunnelLoop {
    param(
        [Parameter(Mandatory=$true)][object]$Config,
        [Parameter(Mandatory=$true)][string]$BaseDir,
        [Parameter(Mandatory=$true)][string]$LogDir,
        [Parameter(Mandatory=$true)][string]$LogFile
    )

    Start-Transcript -Path $LogFile -Append -Force
    Write-Host "--- New Session Started: $(Get-Date) ---"
    Write-Host "Running as user: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"

    $Mutex = $null
    try {
        # 1) 基础字段校验
        foreach ($k in @("SshTarget","ForwardRules","ReconnectInterval","ServiceName")) {
            if (-not ($Config.PSObject.Properties.Name -contains $k)) {
                throw "Missing required config field: '$k'."
            }
        }

        # 2) 互斥锁 (防止重复运行)
        $MutexName = "Global\$($Config.ServiceName)_Mutex"
        try {
            $Mutex = [System.Threading.Mutex]::OpenExisting($MutexName)
            Write-Host "Error: The tunnel is ALREADY running (Mutex detected): $MutexName"
            exit 2
        } catch {
            $Mutex = New-Object System.Threading.Mutex($true, $MutexName)
        }

        # 3) SSH Key 选择
        $CurrentUserName = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $IsSystem = ($CurrentUserName -match '\\SYSTEM$')

        $ExplicitKeyPath = $null
        if ($Config.PSObject.Properties.Name -contains 'KeyPath') {
            $ExplicitKeyPath = $Config.KeyPath
        }
        if (-not [string]::IsNullOrWhiteSpace($ExplicitKeyPath)) {
            try {
                $ExplicitKeyPath = [System.IO.Path]::GetFullPath((Join-Path $BaseDir $ExplicitKeyPath))
            } catch {
                # 如果不是相对路径或解析失败，就按原样尝试
            }
        }

        $ProgramDataKeyDir = Join-Path $env:ProgramData "rdp-ssh-tunnel"
        $KeyPathCandidates = @()
        if (-not [string]::IsNullOrWhiteSpace($ExplicitKeyPath)) {
            $KeyPathCandidates += $ExplicitKeyPath
        }

        if ($IsSystem) {
            $KeyPathCandidates += (Join-Path $BaseDir "id_ed25519")
            $KeyPathCandidates += (Join-Path $BaseDir "id_rsa")
            $KeyPathCandidates += (Join-Path $ProgramDataKeyDir "id_ed25519")
            $KeyPathCandidates += (Join-Path $ProgramDataKeyDir "id_rsa")
        } else {
            $KeyPathCandidates += (Join-Path $HOME ".ssh\\id_ed25519")
            $KeyPathCandidates += (Join-Path $HOME ".ssh\\id_rsa")
            $KeyPathCandidates += (Join-Path $env:USERPROFILE ".ssh\\id_ed25519")
            $KeyPathCandidates += (Join-Path $env:USERPROFILE ".ssh\\id_rsa")
            $KeyPathCandidates += (Join-Path $BaseDir "id_ed25519")
            $KeyPathCandidates += (Join-Path $BaseDir "id_rsa")
        }

        $KeyPathCandidates = $KeyPathCandidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
        $KeyPath = $KeyPathCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $KeyPath) {
            throw "SSH Key not found. Tried: $($KeyPathCandidates -join ', ')"
        }
        Write-Host "Using SSH key: $KeyPath"

        # 4) ssh.exe 可用性检查
        try {
            $SshVersion = ssh -V 2>&1
            Write-Host "SSH Binary found: $SshVersion"
        } catch {
            throw "ssh.exe not found in PATH. Please install OpenSSH."
        }

        Write-Host "Starting Tunnel '$($Config.ServiceName)' -> $($Config.SshTarget)..."

        # 计划任务/无交互环境下，有时会出现 PipelineStoppedException（"The pipeline has been stopped."）
        # 为了保证按 ReconnectInterval 重试，这里显式捕获并继续循环。
        trap [System.Management.Automation.PipelineStoppedException] {
            Write-Host "Native command/pipeline was stopped: $($_.Exception.Message)"
            if ([int]$Config.ReconnectInterval -gt 0) {
                Write-Host "Waiting $($Config.ReconnectInterval) seconds..."
                Start-Sleep -Seconds ([int]$Config.ReconnectInterval)
                continue
            }
            break
        }

        while ($true) {
            $shouldContinue = $true
            try {
                $SshArgs = @()
                $SshArgs += "-i"; $SshArgs += $KeyPath

                $ForwardParts = $Config.ForwardRules.Split(' ', [StringSplitOptions]::RemoveEmptyEntries)
                $SshArgs += $ForwardParts

                $SshArgs += "-N"
                $SshArgs += "-o"; $SshArgs += "BatchMode=yes"
                $SshArgs += "-o"; $SshArgs += "ExitOnForwardFailure=yes"
                $SshArgs += "-o"; $SshArgs += "ServerAliveInterval=60"
                $SshArgs += "-o"; $SshArgs += "ServerAliveCountMax=3"
                $SshArgs += "-o"; $SshArgs += "StrictHostKeyChecking=no"
                $SshArgs += "-o"; $SshArgs += "UserKnownHostsFile=NUL"

                $SshArgs += $Config.SshTarget

                Write-Host "Executing: ssh $($SshArgs -join ' ')"

                # 在计划任务/无交互会话里，-NoNewWindow 可能导致宿主直接中断。
                # 这里改为重定向 stdout/stderr 到文件，既能无人值守，也能保留 ssh 的真实报错。
                $safeName = ($Config.ServiceName -replace '[\\/:*?"<>| ]', '_')

                # 你希望“文件名不带日期”，但仍要避免每次启动覆盖掉历史输出：
                # - Start-Process 的 Redirect 会覆盖文件，因此用临时文件接收，再追加到固定文件名。
                $SshOut = Join-Path $LogDir ("ssh_{0}.out.log" -f $safeName)
                $SshErr = Join-Path $LogDir ("ssh_{0}.err.log" -f $safeName)
                $tmpId = "{0}_{1}" -f $PID, ([Guid]::NewGuid().ToString("N").Substring(0,8))
                $TmpOut = Join-Path $LogDir ("ssh_{0}.out.tmp.{1}.log" -f $safeName, $tmpId)
                $TmpErr = Join-Path $LogDir ("ssh_{0}.err.tmp.{1}.log" -f $safeName, $tmpId)

                $Process = Start-Process -FilePath "ssh.exe" -ArgumentList $SshArgs -PassThru -Wait -RedirectStandardOutput $TmpOut -RedirectStandardError $TmpErr
                Write-Host "SSH process exited with code: $($Process.ExitCode)"

                # 把 ssh 输出也写进 transcript（只打印尾部，避免爆日志）
                if (Test-Path $TmpErr) {
                    Add-Content -Path $SshErr -Value (Get-Content -Path $TmpErr -ErrorAction SilentlyContinue) -ErrorAction SilentlyContinue
                    Remove-Item -Path $TmpErr -Force -ErrorAction SilentlyContinue
                }
                if (Test-Path $TmpOut) {
                    Add-Content -Path $SshOut -Value (Get-Content -Path $TmpOut -ErrorAction SilentlyContinue) -ErrorAction SilentlyContinue
                    Remove-Item -Path $TmpOut -Force -ErrorAction SilentlyContinue
                }

                if (Test-Path $SshErr) {
                    $errTail = @(Get-Content -Path $SshErr -ErrorAction SilentlyContinue -Tail 200)
                    if ($errTail.Count -gt 0) {
                        Write-Host "--- ssh stderr (tail) ---"
                        $errTail | ForEach-Object { Write-Host $_ }
                    }
                }
                if (Test-Path $SshOut) {
                    $outTail = @(Get-Content -Path $SshOut -ErrorAction SilentlyContinue -Tail 200)
                    if ($outTail.Count -gt 0) {
                        Write-Host "--- ssh stdout (tail) ---"
                        $outTail | ForEach-Object { Write-Host $_ }
                    }
                }
            } catch {
                Write-Host "Loop Error: $_"
            } finally {
                # 无论 ssh 是正常退出、失败退出、还是抛异常，都按 ReconnectInterval 做重试等待
                if ([int]$Config.ReconnectInterval -gt 0) {
                    Write-Host "Waiting $($Config.ReconnectInterval) seconds..."
                    Start-Sleep -Seconds ([int]$Config.ReconnectInterval)
                    $shouldContinue = $true
                } else {
                    $shouldContinue = $false
                }
            }

            if (-not $shouldContinue) {
                break
            }
        }
    } catch {
        Write-Error "Fatal Script Error: $_"
    } finally {
        if ($Mutex) { $Mutex.ReleaseMutex(); $Mutex.Dispose() }
        Stop-Transcript
    }
}

try {
    if (-not (Test-Path $ConfigPath)) {
        throw "Config file not found at $ConfigPath"
    }

    $cfg = Read-ConfigFile -Path $ConfigPath
    $AllConfigs = @($cfg.Entries)
    if ($AllConfigs.Count -eq 0) {
        throw "No config entries found in $ConfigPath"
    }

    $taskName = $cfg.TaskName
    $AllConfigs = Normalize-Entries -Entries $AllConfigs -TaskName $taskName
    $Selected = Select-Configs -AllConfigs $AllConfigs -Index $ConfigIndex -Name $ServiceName

    # 日志目录：logs/{yyyy-MM-dd}/
    $dateDir = Get-Date -Format "yyyy-MM-dd"
    $LogDir = Join-Path $ScriptPath (Join-Path "logs" $dateDir)
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

    # 单条配置：保持旧行为（debug_log.txt）
    if ($Selected.Count -eq 1) {
        $LogFile = Join-Path $LogDir "debug_log.txt"
        Start-TunnelLoop -Config $Selected[0] -BaseDir $ScriptPath -LogDir $LogDir -LogFile $LogFile
        exit
    }

    # 多条配置：并行启动，每条独立日志，便于排查
    Write-Host "Detected $($Selected.Count) tunnel configs. Starting them in parallel..."
    $Jobs = @()
    foreach ($cfg in $Selected) {
        $safeName = ($cfg.ServiceName -replace '[\\/:*?"<>| ]', '_')
        $log = Join-Path $LogDir ("debug_log_{0}.txt" -f $safeName)
        $Jobs += Start-Job -ScriptBlock ${function:Start-TunnelLoop} -ArgumentList @($cfg, $ScriptPath, $LogDir, $log)
    }

    Write-Host "Started $($Jobs.Count) job(s). Use stop.ps1 to stop them."
    Wait-Job -Job $Jobs | Out-Null
} catch {
    Write-Error "Fatal Script Error: $_"
}