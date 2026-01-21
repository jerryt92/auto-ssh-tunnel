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

        while ($true) {
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
                $Process = Start-Process -FilePath "ssh.exe" -ArgumentList $SshArgs -NoNewWindow -PassThru -Wait
                Write-Host "SSH process exited with code: $($Process.ExitCode)"
            } catch {
                Write-Host "Loop Error: $_"
            }

            if ([int]$Config.ReconnectInterval -gt 0) {
                Write-Host "Waiting $($Config.ReconnectInterval) seconds..."
                Start-Sleep -Seconds ([int]$Config.ReconnectInterval)
            } else {
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

    # 单条配置：保持旧行为（debug_log.txt）
    if ($Selected.Count -eq 1) {
        $LogFile = Join-Path $ScriptPath "debug_log.txt"
        Start-TunnelLoop -Config $Selected[0] -BaseDir $ScriptPath -LogFile $LogFile
        exit
    }

    # 多条配置：并行启动，每条独立日志，便于排查
    Write-Host "Detected $($Selected.Count) tunnel configs. Starting them in parallel..."
    $Jobs = @()
    foreach ($cfg in $Selected) {
        $safeName = ($cfg.ServiceName -replace '[\\/:*?"<>| ]', '_')
        $log = Join-Path $ScriptPath ("debug_log_{0}.txt" -f $safeName)
        $Jobs += Start-Job -ScriptBlock ${function:Start-TunnelLoop} -ArgumentList @($cfg, $ScriptPath, $log)
    }

    Write-Host "Started $($Jobs.Count) job(s). Use stop.ps1 to stop them."
    Wait-Job -Job $Jobs | Out-Null
} catch {
    Write-Error "Fatal Script Error: $_"
}