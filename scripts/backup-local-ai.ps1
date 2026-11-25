param([ValidateSet('Solo','All')][string]$Backup='Solo',[string]$BackupRoot,[string]$SoloRepo,[string]$SourceContainer='solo-postgres',[ValidateRange(1,3600)][int]$CommandTimeoutSeconds=300,[switch]$PreserveExistingBackups)
$ErrorActionPreference='Stop'
$AiRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not $BackupRoot) { $BackupRoot = if ($env:LOCAL_AI_BACKUP_ROOT) { $env:LOCAL_AI_BACKUP_ROOT } else { Join-Path $AiRoot 'backups\local-ai-lab' } }
if (-not $SoloRepo) { $SoloRepo = if ($env:SOLO_REPO_ROOT) { $env:SOLO_REPO_ROOT } else { Join-Path $AiRoot 'solo' } }
$stamp=Get-Date -Format 'yyyy-MM-dd_HHmmss_fff'
$dumpName="solo-postgres-$stamp.dump"
$dumpPath=Join-Path $BackupRoot "solo-postgres\$dumpName"
$manifestPath=Join-Path $BackupRoot "manifests\solo-$stamp.json"
$containerTemp="/tmp/solo-backup-$stamp.dump"
$validator="solo-backup-verify-$PID-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$helper=Join-Path $PSScriptRoot 'postgres-backup-snapshot.py'
$manifestOwned=$false
$pg='FAIL';$restore='FAIL';$started=$false;$failure=$null
$manifest=[ordered]@{formatVersion=1;createdAt=(Get-Date).ToUniversalTime().ToString('o');sourceProvider='postgres';postgresDump=$dumpName;gitCommit=$null;postgresVersion=$null;schemaVersion=$null;tables=@();validation=[ordered]@{dump='FAIL';restore='FAIL'};status='FAIL';error=$null}
function Invoke-DockerCommand([string[]]$a) {
  $output=& $python.Source $helper command --timeout $CommandTimeoutSeconds -- docker @a
  if($LASTEXITCODE -ne 0){throw "Docker command failed or timed out: $($a[0]) $($a[1])"}
  return $output
}
try {
  if(-not(Get-Command docker -ErrorAction SilentlyContinue)){throw 'Docker CLI unavailable'}
  $python=Get-Command python -ErrorAction Stop
  Invoke-DockerCommand @('info','--format','{{.ServerVersion}}')|Out-Null
  $state=(Invoke-DockerCommand @('inspect','--format','{{.State.Running}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}',$SourceContainer)|Out-String).Trim()
  if($state -ne 'true|healthy'){throw "solo-postgres not healthy: $state"}
  foreach($folder in @('solo-postgres','manifests','logs')){New-Item -ItemType Directory -Path (Join-Path $BackupRoot $folder) -Force|Out-Null}
  if((Test-Path -LiteralPath $dumpPath) -or (Test-Path -LiteralPath $manifestPath)){throw 'Refusing to overwrite an existing recovery point'}
  $reservation=[IO.File]::Open($manifestPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
  $reservation.Dispose();$manifestOwned=$true
  if(Test-Path (Join-Path $SoloRepo '.git')){
    $sha=& git -c "safe.directory=$SoloRepo" -C $SoloRepo rev-parse HEAD 2>$null
    if($LASTEXITCODE -eq 0){$manifest.gitCommit=($sha|Out-String).Trim()}
  }
  # One holder transaction owns inventory, schema and counts; pg_dump imports that exact snapshot.
  $snapshotJson=& $python.Source $helper snapshot --container $SourceContainer --dump $containerTemp --timeout $CommandTimeoutSeconds
  if($LASTEXITCODE -ne 0){throw 'Snapshot capture or dump failed'}
  $snapshot=($snapshotJson|Out-String)|ConvertFrom-Json
  $manifest.sourceSnapshot=$snapshot
  $manifest.postgresVersion=$snapshot.postgresVersion
  $manifest.schemaVersion=$snapshot.schemaVersion
  $details=@($snapshot.tables)
  $manifest.tables=$details
  Invoke-DockerCommand @('cp',"$($SourceContainer):$containerTemp",$dumpPath)|Out-Null
  if(-not(Test-Path -LiteralPath $dumpPath) -or (Get-Item -LiteralPath $dumpPath).Length -le 0){throw 'Dump absent or empty'}
  $pg='PASS';$manifest.validation.dump='PASS'
  $image=(Invoke-DockerCommand @('inspect','--format','{{.Config.Image}}',$SourceContainer)|Out-String).Trim()
  $started=$true # Cleanup also runs if Docker starts the container but its client fails.
  Invoke-DockerCommand @('run','-d','--pull=never','--name',$validator,'--network','none','--tmpfs','/var/lib/postgresql/data:rw,size=1073741824','-e','POSTGRES_DB=solo','-e','POSTGRES_USER=solo','-e','POSTGRES_HOST_AUTH_METHOD=trust',$image)|Out-Null
  $ready=$false
  for($i=0;$i -lt 40;$i++){
    try { Invoke-DockerCommand @('exec',$validator,'pg_isready','-U','solo','-d','solo')|Out-Null; $ready=$true;break } catch { }
    Start-Sleep -Seconds 1
  }
  if(-not $ready){throw 'Validation database not ready'}
  Invoke-DockerCommand @('cp',$dumpPath,"$($validator):/tmp/verify.dump")|Out-Null
  Invoke-DockerCommand @('exec',$validator,'pg_restore','-U','solo','-d','solo','--no-owner','--no-privileges','--single-transaction','--exit-on-error','/tmp/verify.dump')|Out-Null
  $restoredJson=& $python.Source $helper inspect --container $validator --timeout $CommandTimeoutSeconds
  if($LASTEXITCODE -ne 0){throw 'Restored inventory failed'}
  $restoredInventory=($restoredJson|Out-String)|ConvertFrom-Json
  $expectedNames=@($details|ForEach-Object {$_.name})
  $restoredNames=@($restoredInventory.tables|ForEach-Object {$_.name})
  if(@(Compare-Object $expectedNames $restoredNames).Count -ne 0){throw 'Restored table set differs from snapshot'}
  foreach($core in @('stories','chapters','scenes')){if($core -notin $restoredNames){throw "Missing restored table $core"}}
  if($snapshot.schemaVersion -ne $restoredInventory.schemaVersion){throw 'Restored schema migration version mismatch'}
  foreach($detail in $details){
    $actual=@($restoredInventory.tables|Where-Object {$_.name -eq $detail.name})[0]
    $detail|Add-Member -NotePropertyName restoredRows -NotePropertyValue ([long]$actual.sourceRows)
    if($detail.restoredRows -ne $detail.sourceRows){throw "Count mismatch: $($detail.name)"}
    $expectedSchema=$detail.schema|ConvertTo-Json -Depth 12 -Compress
    $actualSchema=$actual.schema|ConvertTo-Json -Depth 12 -Compress
    if($expectedSchema -cne $actualSchema){throw "Schema/constraint/index mismatch: $($detail.name)"}
  }
  $manifest.restoreVerification=[ordered]@{tableSet='PASS';schema='PASS';constraints='PASS';indexes='PASS';rowCounts='PASS';tableCount=$details.Count}
  $restore='PASS';$manifest.validation.restore='PASS';$manifest.status='PASS'
  if(-not $PreserveExistingBackups){
  # Keep every backup for seven days and always preserve the newest verified dump.
  $goodManifests=@(Get-ChildItem (Join-Path $BackupRoot 'manifests') -Filter 'solo-*.json' -File | ForEach-Object {
    try {
      $record=Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
      if($record.validation.dump -eq 'PASS' -and $record.validation.restore -eq 'PASS'){
        [pscustomobject]@{File=$_;Dump=Join-Path $BackupRoot "solo-postgres\$($record.postgresDump)"}
      }
    }catch{}
  } | Sort-Object { $_.File.LastWriteTime } -Descending)
  $cutoff=(Get-Date).AddDays(-7)
  foreach($old in @($goodManifests | Select-Object -Skip 1)){
    if($old.File.LastWriteTime -lt $cutoff -and (Test-Path -LiteralPath $old.Dump)){
      Remove-Item -LiteralPath $old.Dump -Force
      Remove-Item -LiteralPath $old.File.FullName -Force
    }
  }
  }
}catch{$failure=$_.Exception.Message;$manifest.error=$failure;$manifest.status='FAIL'}
finally{
  foreach($cleanup in @(@('exec',$SourceContainer,'timeout','15','rm','-f',$containerTemp),@('rm','-f',$validator))){
    if($cleanup[0] -eq 'rm' -and -not $started){continue}
    try { Invoke-DockerCommand $cleanup|Out-Null } catch {
      $failure='Backup cleanup failed: '+$_.Exception.Message
      $manifest.error=$failure;$manifest.status='FAIL'
    }
  }
  if($manifestOwned){
    # Publish complete JSON atomically on the same filesystem.
    $pending=$manifestPath+'.pending'
    $manifest|ConvertTo-Json -Depth 16|Set-Content -LiteralPath $pending -Encoding UTF8
    if(Test-Path -LiteralPath $manifestPath){[IO.File]::Replace($pending,$manifestPath,[NullString]::Value)}
    else{[IO.File]::Move($pending,$manifestPath)}
  }
}
Write-Output "SOLO_POSTGRES_BACKUP=$pg"
Write-Output "RESTORE_VALIDATION=$restore"
Write-Output "BACKUP_PATH=$dumpPath"
Write-Output "MANIFEST_PATH=$manifestPath"
if(-not $failure -and $pg -eq 'PASS' -and $restore -eq 'PASS'){Write-Output 'FINAL_VERDICT=PASS';exit 0}
Write-Output 'FINAL_VERDICT=FAIL'
if($failure){Write-Error $failure}
exit 1
