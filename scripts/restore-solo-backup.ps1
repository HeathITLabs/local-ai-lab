param([Parameter(Mandatory=$true)][string]$BackupFile,[switch]$SkipSafetyBackup,[string]$BackupRoot)
$ErrorActionPreference='Stop'
$AiRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not $BackupRoot) { $BackupRoot = if ($env:LOCAL_AI_BACKUP_ROOT) { $env:LOCAL_AI_BACKUP_ROOT } else { Join-Path $AiRoot 'backups\local-ai-lab' } }
if(-not(Test-Path -LiteralPath $BackupFile -PathType Leaf)){throw "Backup file does not exist: $BackupFile"}
$resolved=(Resolve-Path -LiteralPath $BackupFile).Path
if((Get-Item -LiteralPath $resolved).Length -le 0){throw 'Backup file is empty'}
$validator="solo-restore-verify-$PID";$started=$false;$apiStopped=$false
function RunDocker([string[]]$a){$r=& docker @a 2>&1;if($LASTEXITCODE -ne 0){throw "Docker command failed: $($a[0]) $($a[1])"};return $r}
try{
  $state=(RunDocker @('inspect','--format','{{.State.Running}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}','solo-postgres')|Out-String).Trim()
  if($state -ne 'true|healthy'){throw "solo-postgres is not healthy: $state"}
  $image=(RunDocker @('inspect','--format','{{.Config.Image}}','solo-postgres')|Out-String).Trim()
  RunDocker @('run','-d','--name',$validator,'-e','POSTGRES_DB=solo','-e','POSTGRES_USER=solo','-e','POSTGRES_PASSWORD=validation-only',$image)|Out-Null
  $started=$true;$ready=$false
  for($i=0;$i -lt 40;$i++){& docker exec $validator pg_isready -U solo -d solo *> $null;if($LASTEXITCODE -eq 0){$ready=$true;break};Start-Sleep -Seconds 1}
  if(-not $ready){throw 'Validation container not ready'}
  RunDocker @('cp',$resolved,"$($validator):/tmp/selected.dump")|Out-Null
  RunDocker @('exec',$validator,'pg_restore','--list','/tmp/selected.dump')|Out-Null
  RunDocker @('exec',$validator,'pg_restore','-U','solo','-d','solo','--no-owner','--no-privileges','/tmp/selected.dump')|Out-Null
  $core=(RunDocker @('exec',$validator,'psql','-U','solo','-d','solo','-At','-c',"SELECT count(*) FROM pg_tables WHERE schemaname='public' AND tablename IN ('stories','chapters','scenes')")|Out-String).Trim()
  if($core -ne '3'){throw 'Selected dump lacks core Solo tables'}
  if(-not $SkipSafetyBackup){
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'backup-local-ai.ps1') -Backup Solo -BackupRoot $BackupRoot
    if($LASTEXITCODE -ne 0){throw 'Safety backup failed; live database untouched'}
  }
  $api=(RunDocker @('inspect','--format','{{.State.Running}}','solo')|Out-String).Trim()
  if($api -eq 'true'){RunDocker @('stop','solo')|Out-Null;$apiStopped=$true}
  RunDocker @('cp',$resolved,'solo-postgres:/tmp/selected-restore.dump')|Out-Null
  RunDocker @('exec','solo-postgres','psql','-U','solo','-d','postgres','-c','DROP DATABASE IF EXISTS solo WITH (FORCE)')|Out-Null
  RunDocker @('exec','solo-postgres','psql','-U','solo','-d','postgres','-c','CREATE DATABASE solo OWNER solo')|Out-Null
  RunDocker @('exec','solo-postgres','pg_restore','-U','solo','-d','solo','--no-owner','--no-privileges','/tmp/selected-restore.dump')|Out-Null
  $liveCore=(RunDocker @('exec','solo-postgres','psql','-U','solo','-d','solo','-At','-c',"SELECT count(*) FROM pg_tables WHERE schemaname='public' AND tablename IN ('stories','chapters','scenes')")|Out-String).Trim()
  if($liveCore -ne '3'){throw 'Restored live database lacks core tables'}
  Write-Output 'RESTORE_VERDICT=PASS'
}catch{Write-Output "RESTORE_ERROR=$($_.Exception.Message)";Write-Output 'RESTORE_VERDICT=FAIL';exit 1}
finally{
  & docker exec solo-postgres rm -f /tmp/selected-restore.dump *> $null
  if($started){& docker rm -f $validator *> $null}
  if($apiStopped){& docker start solo *> $null}
}
