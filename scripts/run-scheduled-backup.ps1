param([string]$BackupRoot)
$ErrorActionPreference='Stop'
$AiRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not $BackupRoot) { $BackupRoot = if ($env:LOCAL_AI_BACKUP_ROOT) { $env:LOCAL_AI_BACKUP_ROOT } else { Join-Path $AiRoot 'backups\local-ai-lab' } }
$logDir=Join-Path $BackupRoot 'logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$log=Join-Path $logDir ("scheduled-{0}.log" -f (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
try {
  & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'backup-local-ai.ps1') -Backup Solo -BackupRoot $BackupRoot *>&1 | Out-File -LiteralPath $log -Encoding utf8
  exit $LASTEXITCODE
} catch {
  $_ | Out-File -LiteralPath $log -Append
  exit 1
}
