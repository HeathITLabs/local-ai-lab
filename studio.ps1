<#
.SYNOPSIS
  One command for the whole studio (H5, ja-heath-studios#10): up, down, status, logs.

.DESCRIPTION
  studio up      Starts Docker Desktop if needed, backs up Solo's database, builds Solo and Studio from their working
                 checkouts, starts the localai stack, starts LM Studio's server and loads the production model, then
                 waits until `status` says READY.
  studio down    Stops the localai stack (containers and data are kept) and unloads LM Studio's models.
  studio status  Says whether the studio is READY, and why not. Exit code 0 when ready, 1 when not.
  studio logs    Solo (API and factory worker) and Studio logs, interleaved with timestamps.

  Run from anywhere: F:\AI\local-ai-lab\studio.cmd <command>. See ja-heath-studios docs/OPERATIONS.md.

.EXAMPLE
  studio up
  studio up -NoBuild
  studio status
  studio logs -Follow
  studio logs solo -Tail 500
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)][ValidateSet('up', 'down', 'status', 'logs', 'help')][string]$Command = 'help',
  [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Services,
  # up: skip the image builds (a plain restart after a reboot when nothing changed).
  [switch]$NoBuild,
  # up: refresh base images from the registry while building (needs internet).
  [switch]$Update,
  # up: how long to wait for READY.
  [int]$TimeoutMinutes = 10,
  # up: LM Studio context length for the production model; 0 keeps LM Studio's saved default for that model.
  [int]$ContextLength = 0,
  # down: leave LM Studio's models loaded.
  [switch]$KeepModels,
  [ValidateSet('none', 'cpu', 'gpu-nvidia', 'gpu-amd')][string]$ComposeProfile = 'none',
  [ValidateSet('public', 'private')][string]$Environment = 'public',
  # logs
  [switch]$Follow,
  [int]$Tail = 200
)

$ErrorActionPreference = 'Stop'
$LabDir = $PSScriptRoot
$AiRoot = Split-Path -Parent $LabDir
$SoloRepo = if ($env:SOLO_REPO_ROOT) { $env:SOLO_REPO_ROOT } else { Join-Path $AiRoot 'solo' }
$StudioRepo = if ($env:STUDIO_REPO_ROOT) { $env:STUDIO_REPO_ROOT } else { Join-Path $AiRoot 'ja-heath-studios' }
$BackupRoot = if ($env:LOCAL_AI_BACKUP_ROOT) { $env:LOCAL_AI_BACKUP_ROOT } else { Join-Path $AiRoot 'backups\local-ai-lab' }
$Model = 'qwen3.5-9b'                                   # LLM_MODEL / BOOK_AGENT_MODEL in docker-compose.yml
$EmbeddingModel = 'text-embedding-nomic-embed-text-v1.5'  # LOCAL_EMBEDDING_MODEL
$LmStudio = 'http://127.0.0.1:1234'
$Host_ = 'rainbow'
$RequiredContainers = @('solo-postgres', 'neo4j', 'solo', 'studio')

function Write-Step([string]$text) { Write-Host "==> $text" -ForegroundColor Cyan }
function Get-ComposeArgs {
  $a = @('compose', '-p', 'localai')
  if ($ComposeProfile -ne 'none') { $a += @('--profile', $ComposeProfile) }
  $a += @('-f', (Join-Path $LabDir 'docker-compose.yml'))
  $override = Join-Path $LabDir "docker-compose.override.$Environment.yml"
  if (Test-Path $override) { $a += @('-f', $override) }
  return $a
}
function Invoke-Native([string]$exe, [string[]]$arguments) {
  & $exe @arguments | Out-Host
  if ($LASTEXITCODE -ne 0) { throw "$exe $($arguments -join ' ') failed (exit $LASTEXITCODE)" }
}
function Test-Docker { & docker info *> $null; return ($LASTEXITCODE -eq 0) }
function Get-Lms {
  $cmd = Get-Command lms -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $p = Join-Path $env:USERPROFILE '.lmstudio\bin\lms.exe'
  if (Test-Path $p) { return $p }
  return $null
}
# One HTTP GET: status code (0 when unreachable) and parsed JSON when there is any.
function Get-Http([string]$url, [int]$timeout = 5) {
  try {
    $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec $timeout
    $json = $null; try { $json = $r.Content | ConvertFrom-Json } catch { }
    return @{ code = [int]$r.StatusCode; json = $json }
  } catch [System.Net.WebException] {
    $resp = $_.Exception.Response
    if ($resp) {
      $json = $null
      try { $json = $_.ErrorDetails.Message | ConvertFrom-Json } catch { }
      return @{ code = [int]$resp.StatusCode; json = $json }
    }
    return @{ code = 0; json = $null }
  } catch { return @{ code = 0; json = $null } }
}
function Get-LmModels {
  $r = Get-Http "$LmStudio/api/v0/models" 5
  if ($r.code -ne 200 -or -not $r.json) { return $null }
  return @($r.json.data)
}

# ---------------------------------------------------------------- status
function Get-StudioStatus {
  $checks = New-Object System.Collections.Generic.List[object]
  function Add-Check([string]$name, [bool]$ok, [string]$detail, [bool]$required = $true) {
    $checks.Add([pscustomobject]@{ Check = $name; Ok = $ok; Required = $required; Detail = $detail })
  }

  $docker = Test-Docker
  Add-Check 'Docker engine' $docker ($(if ($docker) { 'running' } else { 'not running: start Docker Desktop or run studio up' }))

  if ($docker) {
    $states = @{}
    foreach ($line in (& docker ps -a --filter 'label=com.docker.compose.project=localai' --format '{{.Names}}|{{.State}}|{{.Status}}')) {
      $parts = $line -split '\|', 3
      $states[$parts[0]] = $parts
    }
    foreach ($name in $RequiredContainers) {
      $s = $states[$name]
      if (-not $s) { Add-Check "Container $name" $false 'missing: run studio up'; continue }
      $healthy = ($s[1] -eq 'running') -and ($s[2] -notmatch 'unhealthy|health: starting')
      Add-Check "Container $name" $healthy $s[2]
    }
    $running = @($states.Values | Where-Object { $_[1] -eq 'running' }).Count
    Add-Check 'localai stack' $true "$running of $($states.Count) containers running" $false
  }

  $solo = Get-Http 'http://127.0.0.1:3050/api/health/readiness' 10
  if ($solo.code -eq 0) { Add-Check 'Solo readiness' $false 'no answer on :3050' }
  else {
    $svc = $solo.json.services
    $detail = "HTTP $($solo.code) $($solo.json.status); database $($svc.database), neo4j $($svc.neo4j), comfyui $($svc.comfyui) (optional)"
    Add-Check 'Solo readiness' ($solo.code -eq 200) $detail
  }

  # As a LAN browser reaches it: the host's IPv4 LAN address, with Host: rainbow (Studio's host guard).
  $ip = @(Resolve-DnsName $Host_ -Type A -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -like '192.168.*' } | ForEach-Object { $_.IPAddress })[0]
  if (-not $ip) { $ip = @(Resolve-DnsName $Host_ -Type A -ErrorAction SilentlyContinue | ForEach-Object { $_.IPAddress })[0] }
  if (-not $ip) { Add-Check "Studio at http://${Host_}:4250" $false "'$Host_' does not resolve to an IPv4 address" }
  else {
    $body = & curl.exe -s -m 5 --resolve "${Host_}:4250:$ip" "http://${Host_}:4250/api/health"
    $h = $null; try { $h = $body | ConvertFrom-Json } catch { }
    $ok = [bool]($h -and $h.status -eq 'ok')
    Add-Check "Studio at http://${Host_}:4250" $ok ($(if ($ok) { "via $ip; execution $(if ($h.executionEnabled) { 'enabled' } else { 'disabled' })" } else { "no Studio answer via $ip" }))
  }

  $svcList = Get-Http 'http://127.0.0.1:4250/api/services' 10
  if ($svcList.code -eq 200) {
    $soloSeen = @($svcList.json | Where-Object { $_.id -eq 'solo' })[0]
    Add-Check 'Studio -> Solo' ($soloSeen.status -eq 'available') "Studio sees Solo as $($soloSeen.status)"
  } else { Add-Check 'Studio -> Solo' $false 'Studio did not answer /api/services' }

  $models = Get-LmModels
  if ($null -eq $models) { Add-Check 'LM Studio server' $false "no answer on $LmStudio" }
  else {
    Add-Check 'LM Studio server' $true $LmStudio
    $m = @($models | Where-Object { $_.id -eq $Model })[0]
    $loaded = $m -and $m.state -eq 'loaded'
    $ctx = if ($m -and $m.loaded_context_length) { ", context $($m.loaded_context_length)" } else { '' }
    Add-Check "Model $Model" $loaded ($(if ($loaded) { "loaded$ctx" } elseif ($m) { 'not loaded: run studio up' } else { 'not downloaded in LM Studio' }))
  }

  $comfy = Get-Http 'http://127.0.0.1:8188/system_stats' 3
  Add-Check 'ComfyUI (images)' ($comfy.code -eq 200) ($(if ($comfy.code -eq 200) { 'up' } else { 'down; image generation unavailable' })) $false

  if ($solo.code -ne 0) {
    $q = Get-Http 'http://127.0.0.1:3050/api/v1/production/queue' 10
    if ($q.code -eq 200) {
      $active = @($q.json.queue.assignments | Where-Object { $_.state -notin @('CANCELLED', 'DELIVERED', 'COMPLETED', 'FAILED') }).Count
      $state = if ($q.json.queue.paused) { "PAUSED ($($q.json.queue.pauseReason))" } else { 'running' }
      Add-Check 'Production queue' (-not $q.json.queue.paused) "$state; $active active assignment(s), $(@($q.json.queue.waiting).Count) waiting" $false
    }
  }

  $dumpDir = Join-Path $BackupRoot 'solo-postgres'
  $last = if (Test-Path $dumpDir) { Get-ChildItem $dumpDir -Filter '*.dump' | Sort-Object LastWriteTime -Descending | Select-Object -First 1 } else { $null }
  $task = Get-ScheduledTask -TaskName 'Solo PostgreSQL Backup' -ErrorAction SilentlyContinue
  if ($last) {
    $age = (Get-Date) - $last.LastWriteTime
    $fresh = $age.TotalHours -lt 5
    $taskNote = if ($task) { "task $($task.State)" } else { 'scheduled task MISSING: run scripts\install-backup-task.ps1' }
    Add-Check 'Last database backup' ($fresh -and $task) ("{0:N1} h ago ({1}); {2}" -f $age.TotalHours, $last.Name, $taskNote) $false
  } else { Add-Check 'Last database backup' $false "none in $dumpDir" $false }

  return $checks
}

function Show-Status($checks) {
  foreach ($c in $checks) {
    $mark = if ($c.Ok) { ' OK ' } elseif ($c.Required) { 'FAIL' } else { 'WARN' }
    $color = if ($c.Ok) { 'Green' } elseif ($c.Required) { 'Red' } else { 'Yellow' }
    Write-Host ('[{0}] ' -f $mark) -ForegroundColor $color -NoNewline
    Write-Host ('{0,-28} {1}' -f $c.Check, $c.Detail)
  }
  $failed = @($checks | Where-Object { $_.Required -and -not $_.Ok })
  Write-Host ''
  if ($failed.Count -eq 0) {
    Write-Host "READY  Studio http://${Host_}:4250   Solo http://${Host_}:3050" -ForegroundColor Green
  } else {
    Write-Host ("NOT READY  ({0})" -f (($failed | ForEach-Object { $_.Check }) -join ', ')) -ForegroundColor Red
  }
  return ($failed.Count -eq 0)
}

# ---------------------------------------------------------------- up
function Start-DockerDesktop {
  if (Test-Docker) { return }
  $exe = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
  if (-not (Test-Path $exe)) { throw 'Docker is not running and Docker Desktop is not installed where expected.' }
  Write-Step 'Starting Docker Desktop'
  Start-Process $exe
  for ($i = 0; $i -lt 90; $i++) { Start-Sleep -Seconds 2; if (Test-Docker) { return } }
  throw 'Docker Desktop did not become ready within 3 minutes.'
}

function Backup-SoloDatabase {
  $container = & docker ps -a --filter 'name=^/solo-postgres$' --format '{{.Names}}'
  if (-not $container) {
    $volume = & docker volume ls --filter 'name=^localai_solo-postgres-data$' --format '{{.Name}}'
    if ($volume) { throw 'BACKUP_FAILED: Solo volume exists but the solo-postgres container is missing.' }
    Write-Host 'FIRST_RUN_NO_DATABASE: no Solo container or volume found.'
    return
  }
  $running = & docker ps --filter 'name=^/solo-postgres$' --format '{{.Names}}'
  if (-not $running) {
    # After a reboot with the stack stopped: start the database alone so it can be backed up before anything changes.
    Invoke-Native docker ((Get-ComposeArgs) + @('up', '-d', '--no-deps', 'solo-postgres'))
    for ($i = 0; $i -lt 60; $i++) {
      Start-Sleep -Seconds 2
      if ((& docker inspect -f '{{.State.Health.Status}}' solo-postgres) -eq 'healthy') { break }
    }
  }
  Write-Step 'Backing up Solo database (verified dump)'
  & powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $LabDir 'scripts\backup-local-ai.ps1') -Backup Solo | Out-Host
  if ($LASTEXITCODE -ne 0) { throw 'BACKUP_FAILED: refusing to update the environment.' }
}

function Start-LmStudio {
  $lms = Get-Lms
  if ($null -eq (Get-LmModels)) {
    if (-not $lms) { Write-Warning 'LM Studio is not running and its lms CLI was not found. Start LM Studio and its server.'; return }
    Write-Step 'Starting LM Studio server'
    & $lms server start | Out-Host
    for ($i = 0; $i -lt 30 -and $null -eq (Get-LmModels); $i++) { Start-Sleep -Seconds 2 }
  }
  $models = Get-LmModels
  if ($null -eq $models) { Write-Warning "LM Studio server did not answer on $LmStudio."; return }
  foreach ($key in @($Model, $EmbeddingModel)) {
    $m = @($models | Where-Object { $_.id -eq $key })[0]
    if ($m -and $m.state -eq 'loaded') { continue }
    if (-not $m) { Write-Warning "LM Studio has no model '$key' downloaded."; continue }
    if (-not $lms) { Write-Warning "Load '$key' in LM Studio (lms CLI not found)."; continue }
    Write-Step "Loading $key in LM Studio"
    $args_ = @('load', $key, '-y')
    if ($key -eq $Model -and $ContextLength -gt 0) { $args_ += @('--context-length', "$ContextLength") }
    & $lms @args_ | Out-Host
    if ($LASTEXITCODE -ne 0) { Write-Warning "lms load $key failed (exit $LASTEXITCODE)." }
  }
}

function Invoke-Up {
  Set-Location $LabDir
  Start-DockerDesktop
  Backup-SoloDatabase
  foreach ($repo in @($SoloRepo, $StudioRepo)) {
    if (-not (Test-Path (Join-Path $repo 'Dockerfile'))) { throw "$repo has no Dockerfile; is the repository checked out there?" }
  }
  $env:SOLO_BUILD_CONTEXT = $SoloRepo
  $env:STUDIO_BUILD_CONTEXT = $StudioRepo
  if (-not $NoBuild) {
    Write-Step "Building Solo ($SoloRepo) and Studio ($StudioRepo) from their working checkouts"
    $build = (Get-ComposeArgs) + @('build')
    if ($Update) { $build += '--pull' }
    Invoke-Native docker ($build + @('solo', 'studio'))
  }
  Write-Step 'Starting the localai stack'
  Invoke-Native python @((Join-Path $LabDir 'start_services.py'), '--profile', $ComposeProfile, '--environment', $Environment)
  Start-LmStudio

  Write-Step "Waiting for READY (up to $TimeoutMinutes min)"
  $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
  do {
    $checks = Get-StudioStatus
    $pending = @($checks | Where-Object { $_.Required -and -not $_.Ok })
    if ($pending.Count -eq 0) { break }
    Write-Host ("  waiting on: {0}" -f (($pending | ForEach-Object { $_.Check }) -join ', '))
    Start-Sleep -Seconds 10
  } while ((Get-Date) -lt $deadline)
  Write-Host ''
  return (Show-Status $checks)
}

# ---------------------------------------------------------------- down / logs
function Invoke-Down {
  Set-Location $LabDir
  if (Test-Docker) {
    Write-Step 'Stopping the localai stack (containers and data are kept)'
    # `stop`, not `down`: the next `up` backs up the database from its existing container.
    Invoke-Native docker ((Get-ComposeArgs) + @('stop'))
  } else { Write-Host 'Docker is not running; nothing to stop.' }
  $lms = Get-Lms
  if (-not $KeepModels -and $lms -and $null -ne (Get-LmModels)) {
    Write-Step 'Unloading LM Studio models'
    & $lms unload --all | Out-Host
  }
  Write-Host 'Stopped. Start again with: studio up'
}

function Invoke-Logs {
  Set-Location $LabDir
  $names = if ($Services) { $Services } else { @('solo', 'studio') }
  $a = (Get-ComposeArgs) + @('logs', '--timestamps', '--tail', "$Tail")
  if ($Follow) { $a += '--follow' }
  & docker @($a + $names)
  Write-Host ''
  Write-Host "Solo's own rotated log files: $(Join-Path $AiRoot 'solo-data\logs')   Backup task logs: $(Join-Path $BackupRoot 'logs')" -ForegroundColor DarkGray
}

switch ($Command) {
  'up' { if (Invoke-Up) { exit 0 } else { exit 1 } }
  'down' { Invoke-Down }
  'status' { if (Show-Status (Get-StudioStatus)) { exit 0 } else { exit 1 } }
  'logs' { Invoke-Logs }
  default { Get-Help $PSCommandPath -Detailed }
}
