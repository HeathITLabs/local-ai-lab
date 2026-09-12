param([ValidateSet('Solo','All')][string]$Backup='Solo',[string]$BackupRoot,[string]$SoloRepo)
$ErrorActionPreference='Stop'
$AiRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not $BackupRoot) { $BackupRoot = if ($env:LOCAL_AI_BACKUP_ROOT) { $env:LOCAL_AI_BACKUP_ROOT } else { Join-Path $AiRoot 'backups\local-ai-lab' } }
if (-not $SoloRepo) { $SoloRepo = if ($env:SOLO_REPO_ROOT) { $env:SOLO_REPO_ROOT } else { Join-Path $AiRoot 'solo' } }
$stamp=Get-Date -Format 'yyyy-MM-dd_HHmmss_fff'
$dumpName="solo-postgres-$stamp.dump"
$dumpPath=Join-Path $BackupRoot "solo-postgres\$dumpName"
$manifestPath=Join-Path $BackupRoot "manifests\solo-$stamp.json"
$containerTemp="/tmp/solo-backup-$stamp.dump"
$validator="solo-backup-verify-$PID"
$pg='FAIL';$restore='FAIL';$sqlite='INCOMPLETE';$started=$false;$failure=$null
$manifest=[ordered]@{formatVersion=1;createdAt=(Get-Date).ToUniversalTime().ToString('o');sourceProvider='postgres';postgresDump=$dumpName;sqliteSnapshot=$null;gitCommit=$null;postgresVersion=$null;schemaVersion=$null;tables=@();validation=[ordered]@{dump='FAIL';restore='FAIL';sqlite='INCOMPLETE'};status='FAIL';error=$null}
function Invoke-DockerCommand([string[]]$a) {
  $output=& docker @a 2>&1
  if($LASTEXITCODE -ne 0){throw "Docker command failed: $($a[0]) $($a[1])"}
  return $output
}
try {
  if(-not(Get-Command docker -ErrorAction SilentlyContinue)){throw 'Docker CLI unavailable'}
  Invoke-DockerCommand @('info','--format','{{.ServerVersion}}')|Out-Null
  $state=(Invoke-DockerCommand @('inspect','--format','{{.State.Running}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}','solo-postgres')|Out-String).Trim()
  if($state -ne 'true|healthy'){throw "solo-postgres not healthy: $state"}
  foreach($folder in @('solo-postgres','solo-sqlite','manifests','logs')){New-Item -ItemType Directory -Path (Join-Path $BackupRoot $folder) -Force|Out-Null}
  if(Test-Path (Join-Path $SoloRepo '.git')){
    $sha=& git -c "safe.directory=$SoloRepo" -C $SoloRepo rev-parse HEAD 2>$null
    if($LASTEXITCODE -eq 0){$manifest.gitCommit=($sha|Out-String).Trim()}
  }
  $manifest.postgresVersion=(Invoke-DockerCommand @('exec','solo-postgres','psql','-U','solo','-d','solo','-At','-c','SHOW server_version')|Out-String).Trim()
  $tables=@(Invoke-DockerCommand @('exec','solo-postgres','psql','-U','solo','-d','solo','-At','-c',"SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename"))
  if('schema_migrations' -in $tables){$manifest.schemaVersion=(Invoke-DockerCommand @('exec','solo-postgres','psql','-U','solo','-d','solo','-At','-c','SELECT id FROM schema_migrations ORDER BY applied_at DESC LIMIT 1')|Out-String).Trim()}
  if($tables.Count -eq 0){throw 'No public tables'}
  $details=@()
  foreach($table in $tables){
    $table=$table.Trim()
    if($table -notmatch '^[a-zA-Z_][a-zA-Z0-9_]*$'){throw "Unexpected table: $table"}
    $count=(Invoke-DockerCommand @('exec','solo-postgres','psql','-U','solo','-d','solo','-At','-c',"SELECT count(*) FROM public.$table")|Out-String).Trim()
    $details += [ordered]@{name=$table;sourceRows=[long]$count;sqlite='unsupported/error';reason='Provider-aware mapping not validated'}
  }
  $manifest.tables=$details
  Invoke-DockerCommand @('exec','solo-postgres','pg_dump','-U','solo','-d','solo','-Fc','-f',$containerTemp)|Out-Null
  Invoke-DockerCommand @('cp',"solo-postgres:$containerTemp",$dumpPath)|Out-Null
  if(-not(Test-Path -LiteralPath $dumpPath) -or (Get-Item -LiteralPath $dumpPath).Length -le 0){throw 'Dump absent or empty'}
  $pg='PASS';$manifest.validation.dump='PASS'
  $image=(Invoke-DockerCommand @('inspect','--format','{{.Config.Image}}','solo-postgres')|Out-String).Trim()
  Invoke-DockerCommand @('run','-d','--name',$validator,'-e','POSTGRES_DB=solo','-e','POSTGRES_USER=solo','-e','POSTGRES_PASSWORD=validation-only',$image)|Out-Null
  $started=$true;$ready=$false
  for($i=0;$i -lt 40;$i++){
    & docker exec $validator pg_isready -U solo -d solo *> $null
    if($LASTEXITCODE -eq 0){$ready=$true;break}
    Start-Sleep -Seconds 1
  }
  if(-not $ready){throw 'Validation database not ready'}
  Invoke-DockerCommand @('cp',$dumpPath,"$($validator):/tmp/verify.dump")|Out-Null
  Invoke-DockerCommand @('exec',$validator,'pg_restore','-U','solo','-d','solo','--no-owner','--no-privileges','/tmp/verify.dump')|Out-Null
  $restored=@(Invoke-DockerCommand @('exec',$validator,'psql','-U','solo','-d','solo','-At','-c',"SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename"))
  foreach($core in @('stories','chapters','scenes')){if($core -notin $restored){throw "Missing restored table $core"}}
  foreach($detail in $details){
    $count=(Invoke-DockerCommand @('exec',$validator,'psql','-U','solo','-d','solo','-At','-c',"SELECT count(*) FROM public.$($detail.name)")|Out-String).Trim()
    $detail.restoredRows=[long]$count
    if($detail.restoredRows -ne $detail.sourceRows){throw "Count mismatch: $($detail.name)"}
  }
  $restore='PASS';$manifest.validation.restore='PASS';$manifest.status='PARTIAL'
  $archiveName="solo-archive-$stamp.sqlite"
  $archivePath=Join-Path $BackupRoot "solo-sqlite\$archiveName"
  $archiveManifestPath=Join-Path $BackupRoot "manifests\solo-archive-$stamp.json"
  $python=Get-Command python -ErrorAction SilentlyContinue
  if($python){
    & $python.Source (Join-Path $PSScriptRoot 'export-postgres-archive.py') --output $archivePath --manifest $archiveManifestPath --container $validator --git-sha $manifest.gitCommit
    if(Test-Path -LiteralPath $archiveManifestPath){
      $archive=Get-Content -LiteralPath $archiveManifestPath -Raw | ConvertFrom-Json
      $manifest.archive=$archive
      $manifest.tables=$archive.tables
      if($LASTEXITCODE -eq 0 -and $archive.status -eq 'PASS' -and (Test-Path -LiteralPath $archivePath)){
        $sqlite='PASS';$manifest.sqliteSnapshot=$archiveName
        $manifest.validation.sqlite='PASS';$manifest.status='PASS'
      }
    }
  }
  if($sqlite -ne 'PASS'){$manifest.error='SQLite archive incomplete; PostgreSQL dump remains verified.'}
  # Keep every backup for seven days and always preserve the newest verified dump.
  $goodManifests=@(Get-ChildItem (Join-Path $BackupRoot 'manifests') -Filter 'solo-*.json' -File | ForEach-Object {
    try {
      $record=Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
      if($record.validation.dump -eq 'PASS' -and $record.validation.restore -eq 'PASS'){
        $archiveFile=$null
        if($record.validation.sqlite -eq 'PASS' -and $record.sqliteSnapshot -match '^solo-archive-[0-9_-]+\.sqlite$'){
          $archiveFile=Join-Path $BackupRoot "solo-sqlite\$($record.sqliteSnapshot)"
        }
        [pscustomobject]@{File=$_;Dump=Join-Path $BackupRoot "solo-postgres\$($record.postgresDump)";Archive=$archiveFile}
      }
    }catch{}
  } | Sort-Object { $_.File.LastWriteTime } -Descending)
  $cutoff=(Get-Date).AddDays(-7)
  foreach($old in @($goodManifests | Select-Object -Skip 1)){
    if($old.File.LastWriteTime -lt $cutoff -and (Test-Path -LiteralPath $old.Dump)){
      Remove-Item -LiteralPath $old.Dump -Force
      if($old.Archive -and (Test-Path -LiteralPath $old.Archive)){Remove-Item -LiteralPath $old.Archive -Force}
      Remove-Item -LiteralPath $old.File.FullName -Force
    }
  }
}catch{$failure=$_.Exception.Message;$manifest.error=$failure}
finally{
  & docker exec solo-postgres rm -f $containerTemp *> $null
  if($started){& docker rm -f $validator *> $null}
  if(Test-Path (Split-Path $manifestPath)){$manifest|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $manifestPath -Encoding UTF8}
}
Write-Output "SOLO_POSTGRES_BACKUP=$pg"
Write-Output "SOLO_SQLITE_SNAPSHOT=$sqlite"
Write-Output "RESTORE_VALIDATION=$restore"
Write-Output "BACKUP_PATH=$dumpPath"
Write-Output "MANIFEST_PATH=$manifestPath"
if($pg -eq 'PASS' -and $restore -eq 'PASS' -and $sqlite -eq 'PASS'){Write-Output 'FINAL_VERDICT=PASS';exit 0}
if($pg -eq 'PASS' -and $restore -eq 'PASS'){Write-Output 'FINAL_VERDICT=PARTIAL_SQLITE_INCOMPLETE';exit 0}
Write-Output 'FINAL_VERDICT=FAIL'
if($failure){Write-Error $failure}
exit 1
