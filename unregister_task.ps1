# unregister_as_task.ps1
# 必须以管理员身份运行

param(
    [int]$ConfigIndex = 0,
    [string]$ServiceName
)

if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Warning "请以管理员身份运行此脚本！"
    exit
}

$ScriptPath = $PSScriptRoot
$ConfigPath = Join-Path $ScriptPath "config.json"

if (-not (Test-Path $ConfigPath)) {
    Write-Error "Config file not found!"
    exit
}
$RawConfig = Get-Content $ConfigPath | ConvertFrom-Json

# New schema: { taskName, sshTunnel: [] } -> scheduled task name uses taskName
if ($RawConfig -and ($RawConfig.PSObject.Properties.Name -contains 'sshTunnel')) {
    $TaskName = $RawConfig.taskName
    if ([string]::IsNullOrWhiteSpace($TaskName)) {
        Write-Error "config.json missing 'taskName' (required for scheduled task name)."
        exit 1
    }
} else {
    # Legacy schemas: object or array-of-objects, task name defaults to selected entry ServiceName (or TaskName if present)
    $Configs = @()
    if ($RawConfig -is [System.Array]) { $Configs = @($RawConfig) } else { $Configs = @($RawConfig) }
    if ($Configs.Count -eq 0) {
        Write-Error "No config entries found in config.json"
        exit 1
    }

    $Config = $null
    if (-not [string]::IsNullOrWhiteSpace($ServiceName)) {
        $match = @($Configs | Where-Object { $_.ServiceName -eq $ServiceName })
        if ($match.Count -eq 0) {
            Write-Error "No config entry matched ServiceName='$ServiceName'"
            exit 1
        }
        $Config = $match[0]
    } else {
        if ($ConfigIndex -lt 0 -or $ConfigIndex -ge $Configs.Count) {
            Write-Error "ConfigIndex out of range. Count=$($Configs.Count), Index=$ConfigIndex"
            exit 1
        }
        $Config = $Configs[$ConfigIndex]
    }

    $TaskName = $Config.TaskName
    if ([string]::IsNullOrWhiteSpace($TaskName)) { $TaskName = $Config.ServiceName }
    if ([string]::IsNullOrWhiteSpace($TaskName)) {
        Write-Error "Could not determine task name from config (missing TaskName/ServiceName)."
        exit 1
    }
}

$Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

if ($Task) {
    # 如果正在运行，先停止
    if ($Task.State -eq 'Running') {
        Write-Host "正在停止任务..."
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }

    # 额外：停止 run.ps1/ssh.exe 进程（避免“任务删了但进程仍在跑”）
    try {
        $StopScript = Join-Path $ScriptPath "stop.ps1"
        if (Test-Path $StopScript) {
            & $StopScript | Out-Host
        }
    } catch { }
    
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "✅ 任务 '$TaskName' 已删除。" -ForegroundColor Green
}
else {
    Write-Host "未找到任务 '$TaskName'。" -ForegroundColor Yellow
}