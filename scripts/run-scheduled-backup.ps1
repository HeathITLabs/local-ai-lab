param([string]$BackupRoot,[switch]$PreserveExistingBackups)
$ErrorActionPreference='Stop'
$AiRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not $BackupRoot) { $BackupRoot = if ($env:LOCAL_AI_BACKUP_ROOT) { $env:LOCAL_AI_BACKUP_ROOT } else { Join-Path $AiRoot 'backups\local-ai-lab' } }
$logDir=Join-Path $BackupRoot 'logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$log=Join-Path $logDir ("scheduled-{0}.log" -f (Get-Date -Format 'yyyy-MM-dd_HHmmss_fff'))
$process=New-Object System.Diagnostics.Process
try {
  # Drain both OS streams concurrently; stderr must not become a terminating
  # PowerShell error record that interrupts the child's retry/finally blocks.
  $process.StartInfo.FileName=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $child=Join-Path $PSScriptRoot 'backup-local-ai.ps1'
  $process.StartInfo.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Backup Solo -BackupRoot "{1}"' -f $child,$BackupRoot.TrimEnd('\')
  if($PreserveExistingBackups){$process.StartInfo.Arguments+=' -PreserveExistingBackups'}
  $process.StartInfo.UseShellExecute=$false
  $process.StartInfo.CreateNoWindow=$true
  $process.StartInfo.RedirectStandardOutput=$true
  $process.StartInfo.RedirectStandardError=$true
  $null=$process.Start()
  $stdout=$process.StandardOutput.ReadToEndAsync()
  $stderr=$process.StandardError.ReadToEndAsync()
  $process.WaitForExit()
  $exitCode=$process.ExitCode
  [IO.File]::WriteAllText($log,$stdout.Result+"`r`n--- child stderr ---`r`n"+$stderr.Result,[Text.Encoding]::UTF8)
  exit $exitCode
} catch {
  $_ | Out-File -LiteralPath $log -Append
  exit 1
} finally {
  $process.Dispose()
}
