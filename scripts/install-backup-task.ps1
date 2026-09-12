param([string]$TaskName='Solo PostgreSQL Backup',[string]$BackupRoot)
$ErrorActionPreference='Stop'
$AiRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not $BackupRoot) { $BackupRoot = if ($env:LOCAL_AI_BACKUP_ROOT) { $env:LOCAL_AI_BACKUP_ROOT } else { Join-Path $AiRoot 'backups\local-ai-lab' } }
$script=Join-Path $PSScriptRoot 'run-scheduled-backup.ps1'
if(-not(Test-Path -LiteralPath $script)){throw "Missing backup script: $script"}
$arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$script+'" -BackupRoot "'+$BackupRoot+'"'
$action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
$trigger=New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddMinutes(5) -RepetitionInterval (New-TimeSpan -Hours 4) -RepetitionDuration (New-TimeSpan -Days 3650)
$settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 2)
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Description 'Verified Solo PostgreSQL backups every four hours' -Force | Out-Null
Write-Output "TASK_INSTALLED=$TaskName"

