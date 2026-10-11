<#
    install-task.ps1
    ------------------------------------------------------------------
    Installs the carnival sync job on this server:

      1. copies carnival-sync.ps1 / carnival-sync.cmd into the work dir
      2. writes work-dir\config.json with the repo coordinates
      3. registers a scheduled task that runs the sync every minute
      4. runs one sync immediately so you can see it work

    Usage (elevated PowerShell):

      .\install-task.ps1 -Repo "your-name/your-repo"
      .\install-task.ps1 -Repo "your-name/your-repo" -Branch main
      .\install-task.ps1 -Remove

    ASCII-only on purpose: Windows PowerShell 5.1 parses .ps1 files using
    the system ANSI code page unless a UTF-8 BOM is present, which
    corrupts non-ASCII literals. See deploy/README.md.
#>

[CmdletBinding()]
param(
    [string] $Repo     = "",
    [string] $Branch   = "main",
    [string] $SiteRoot = "C:\inetpub\wwwroot",
    [string] $WorkDir  = "C:\inetpub\carnival-sync",
    [string] $TaskName = "Carnival Sync",
    [int]    $IntervalMinutes = 1,
    [switch] $Remove,
    [switch] $NoRun
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

function Say  { param([string] $m) Write-Host $m }
function Step { param([string] $m) Write-Host ""; Write-Host "== $m" -ForegroundColor Cyan }
function Ok   { param([string] $m) Write-Host "   $m" -ForegroundColor Gray }
function Bad  { param([string] $m) Write-Host "   $m" -ForegroundColor Red }

$Here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$SrcPs1  = Join-Path $Here "carnival-sync.ps1"
$SrcCmd  = Join-Path $Here "carnival-sync.cmd"
$DstPs1  = Join-Path $WorkDir "carnival-sync.ps1"
$DstCmd  = Join-Path $WorkDir "carnival-sync.cmd"
$CfgFile = Join-Path $WorkDir "config.json"

# ------------------------------------------------------------ remove mode
if ($Remove) {
    Step "Removing scheduled task '$TaskName'"
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Ok "task removed"
    } else {
        Ok "task was not registered"
    }
    Say ""
    Say "Work dir kept at $WorkDir (delete it by hand if you want)."
    exit 0
}

if (-not $Repo -or $Repo -notmatch "^[^/\s]+/[^/\s]+$") {
    Bad "-Repo must look like owner/name, got '$Repo'"
    exit 2
}

Say ""
Say "=== Carnival sync installer ===" -ForegroundColor Green
Say ""
Ok ("repo      : " + $Repo + " (" + $Branch + ")")
Ok ("site root : " + $SiteRoot)
Ok ("work dir  : " + $WorkDir)
Ok ("task name : " + $TaskName + " every " + $IntervalMinutes + " min")

# ------------------------------------------------------------ 1. files
Step "1/5  Copying sync scripts"
$null = New-Item -ItemType Directory -Path $WorkDir -Force
foreach ($pair in @(@($SrcPs1, $DstPs1), @($SrcCmd, $DstCmd))) {
    if (-not (Test-Path $pair[0])) { Bad ("missing source file: " + $pair[0]); exit 1 }
    $src = (Resolve-Path $pair[0]).Path
    # When install-task.ps1 is run from the work dir itself, source and
    # destination are the same file and Copy-Item refuses to overwrite itself.
    if (Test-Path $pair[1]) {
        if ($src -eq (Resolve-Path $pair[1]).Path) {
            Ok ("= " + $pair[1] + " (already in place)")
            continue
        }
    }
    Copy-Item -Path $src -Destination $pair[1] -Force
    Ok ("-> " + $pair[1])
}

# ------------------------------------------------------------ 2. config
Step "2/5  Writing config.json"
@{
    repo     = $Repo
    branch   = $Branch
    siteRoot = $SiteRoot
} | ConvertTo-Json | Set-Content -Path $CfgFile -Encoding UTF8
Ok ("-> " + $CfgFile)

# ------------------------------------------------------------ 3. task
Step "3/5  Registering scheduled task"
$action = New-ScheduledTaskAction -Execute "cmd.exe" `
                                  -Argument ('/c "' + $DstCmd + '"')

$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
            -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
            -RepetitionDuration (New-TimeSpan -Days 3650)

$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" `
            -LogonType ServiceAccount -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -StartWhenAvailable -MultipleInstances IgnoreNew `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null
Ok "registered (runs as SYSTEM, every $IntervalMinutes minute(s))"

# ------------------------------------------------------------ 4. first run
if ($NoRun) {
    Step "4/5  Skipping the first run (-NoRun)"
} else {
    Step "4/5  Running one sync now"
    & $DstCmd
    Ok ("exit code: " + $LASTEXITCODE)
}

# ------------------------------------------------------------ 5. verify
Step "5/5  State"
if (Test-Path $CfgFile) {
    $cfgText = (Get-Content $CfgFile -Raw).Trim() -replace "\s+", " "
    Ok ("config: " + $cfgText)
}
$stateFile = Join-Path $WorkDir "state.json"
if (Test-Path $stateFile) {
    $stateText = (Get-Content $stateFile -Raw).Trim() -replace "\s+", " "
    Ok ("state : " + $stateText)
} else {
    Ok "state : (no successful sync yet)"
}
$logFile = Join-Path $WorkDir "sync.log"
if (Test-Path $logFile) {
    Say ""
    Say "--- last log lines ---"
    Get-Content $logFile -Tail 12 | ForEach-Object { Say $_ }
    Say "----------------------"
}

Say ""
Say "Done. Task '$TaskName' is live." -ForegroundColor Green
Say ("Watch it with:  Get-ScheduledTask -TaskName '" + $TaskName + "' | Get-ScheduledTaskInfo")
Say ("Read the log :  Get-Content '" + $logFile + "' -Tail 30 -Wait")
Say ""
