# register_as_task.ps1
# 功能：以管理员身份注册一个“开机即跑”的计划任务
# 默认：使用当前控制台登录用户（需要保存该用户的凭据，才能在未登录时启动）
# 可选：-RunAsSystem 使用 SYSTEM 运行（不需要用户密码，但访问用户目录/网络资源可能受限）
# 必须以管理员身份运行此脚本！

param(
    [switch]$RunAsSystem,
    [string]$RunAsUser,
    [int]$ConfigIndex = 0,
    [string]$ServiceName
)

Import-Module ScheduledTasks -ErrorAction SilentlyContinue

$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
if (-not $IsAdmin) {
    Write-Warning "【请以管理员身份运行此脚本！】"
    Write-Warning "我们需要管理员权限来写入任务计划。"
    Write-Host "正在尝试自动提权（将弹出 UAC 确认）..." -ForegroundColor Yellow
    try {
        $Self = $PSCommandPath
        $HostExe = (Get-Process -Id $PID).Path
        if ([string]::IsNullOrWhiteSpace($HostExe)) { $HostExe = "powershell.exe" }

        Start-Process -FilePath $HostExe -Verb RunAs -ArgumentList @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", "`"$Self`""
        ) | Out-Null
    } catch {
        Write-Error "自动提权失败：$($_.Exception.Message)"
    }
    exit 1
}

$ScriptPath = $PSScriptRoot
$ConfigPath = Join-Path $ScriptPath "config.json"
$RunScriptPath = Join-Path $ScriptPath "run.ps1"

# 0. 选择 PowerShell 宿主（强烈建议用 pwsh，以避免 Windows PowerShell 5.1 解析差异）
$PowerShellExe = $null
try {
    $PwshCmd = Get-Command "pwsh.exe" -ErrorAction Stop
    $PowerShellExe = $PwshCmd.Source
} catch {
    $PowerShellExe = "powershell.exe"
}

# 1. 读取配置
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

# 2) 确定要运行的用户
# - RunAsUser 未指定时，优先取当前控制台用户（通常是 COMPUTER\user 或 DOMAIN\user）
$TargetUser = $null
if (-not [string]::IsNullOrWhiteSpace($RunAsUser)) {
    $TargetUser = $RunAsUser
} else {
    try { $TargetUser = (Get-CimInstance Win32_ComputerSystem).UserName } catch { $TargetUser = $null }
    if ([string]::IsNullOrWhiteSpace($TargetUser)) {
        $TargetUser = "$env:USERDOMAIN\$env:USERNAME"
    }
}

if ($RunAsSystem) {
    Write-Host "正在配置开机自启动任务（SYSTEM）..." -ForegroundColor Cyan
} else {
    Write-Host "正在为用户 '$TargetUser' 配置开机自启动任务（需要保存凭据）..." -ForegroundColor Cyan
}

# 3. 清理旧任务
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

# 4. 创建操作 (PowerShell)
# -WindowStyle Hidden: 隐藏窗口
# -ExecutionPolicy Bypass: 允许运行脚本
$Action = New-ScheduledTaskAction -Execute $PowerShellExe -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -NoProfile -File `"$RunScriptPath`"" -WorkingDirectory $ScriptPath

# 5. 创建触发器 (开机时)
$Trigger = New-ScheduledTaskTrigger -AtStartup

# 6. 创建主体
if ($RunAsSystem) {
    # SYSTEM：可在未登录状态运行
    $Principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
} else {
    # 指定用户：要在“未登录”时运行，需要存储用户凭据（LogonType Password）
    $Principal = New-ScheduledTaskPrincipal -UserId $TargetUser -LogonType Password -RunLevel Highest
}

# 7. 创建设置 (优化笔记本体验)
$Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Days 365)

# 8. 注册任务
try {
    if ($RunAsSystem) {
        Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Principal $Principal -Settings $Settings -Force -ErrorAction Stop
    } else {
        # 重要：这里会保存一次用户密码到任务计划中（Windows 机制），以便开机未登录也能启动
        $Cred = Get-Credential -UserName $TargetUser -Message "请输入用户 '$TargetUser' 的密码（用于开机未登录时运行任务）"
        # Register-ScheduledTask 的 -User/-Password 参数集不能与 -Principal 同时使用；
        # 这里用 InputObject 参数集：先组装 Task，再用凭据注册。
        $TaskObject = New-ScheduledTask -Action $Action -Trigger $Trigger -Principal $Principal -Settings $Settings
        Register-ScheduledTask -TaskName $TaskName -InputObject $TaskObject -User $Cred.UserName -Password $Cred.GetNetworkCredential().Password -Force -ErrorAction Stop
    }
    
    Write-Host "✅ 任务 '$TaskName' 注册成功！" -ForegroundColor Green
    if ($RunAsSystem) {
        Write-Host "   运行身份: SYSTEM"
    } else {
        Write-Host "   运行身份: $TargetUser"
        Write-Host "   运行方式: Run whether user is logged on or not（已保存凭据）"
    }
    Write-Host "   触发条件: 开机时"
    
    Write-Host "正在尝试启动任务..."
    Start-ScheduledTask -TaskName $TaskName
    Write-Host "任务已启动。请查看 debug_log.txt 确认连接状态。" -ForegroundColor Cyan
}
catch {
    Write-Error "注册失败: $($_.Exception.Message)"
    Write-Host "排查建议：" -ForegroundColor Yellow
    Write-Host "  1) 确认脚本用管理员权限运行" -ForegroundColor Yellow
    Write-Host "  2) 运行: whoami /all 以确认当前用户与组策略限制" -ForegroundColor Yellow
    Write-Host "  3) 若选择“指定用户开机运行”，必须输入正确的用户密码（任务计划需要保存凭据）" -ForegroundColor Yellow
}