<#
    carnival-sync.ps1
    ------------------------------------------------------------------
    Pull the latest commit of a GitHub repo and publish it to the IIS
    site root. Designed to run from Task Scheduler every minute.

    Why zip download instead of git clone:
      This server cannot reach github.com (TCP timeout), but
      codeload.github.com / api.github.com are reachable. git clone
      needs github.com, so we fetch the archive zip instead.

    Why a conditional API request first:
      GET /repos/{repo}/commits/{branch} with If-None-Match returns
      304 when nothing changed. GitHub does not count 304s against the
      rate limit, so polling every minute costs nothing.

    IMPORTANT: this file is intentionally ASCII-only.
      Windows PowerShell 5.1 reads .ps1 files as ANSI (GBK on a zh-CN
      box) unless the file carries a UTF-8 BOM, which corrupts any
      non-ASCII string literal. Keep it ASCII and it works everywhere.

    Exit codes:
      0  up to date, or sync succeeded
      1  sync failed (network / robocopy / verification)
      2  repo not configured yet
#>

[CmdletBinding()]
param(
    [string] $Repo     = "",
    [string] $Branch   = "main",
    [string] $SiteRoot = "C:\inetpub\wwwroot",
    [string] $WorkDir  = "",
    [switch] $Force
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Default the work dir to the folder this script lives in, so the job keeps
# working no matter where it gets installed.
if (-not $WorkDir) { $WorkDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$WorkDir = $WorkDir.TrimEnd("\", "/")

$ConfigFile = Join-Path $WorkDir "config.json"
$StateFile  = Join-Path $WorkDir "state.json"
$LogFile    = Join-Path $WorkDir "sync.log"
$LockFile   = Join-Path $WorkDir "sync.lock"
$TmpDir     = Join-Path $WorkDir "tmp"

$null = New-Item -ItemType Directory -Path $WorkDir -Force

# ---------------------------------------------------------------- helpers
function Write-Log {
    param([string] $Level, [string] $Message)
    $line = "{0} [{1,-5}] {2}" -f (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Write-Host $line
    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch { }
}

function Fail {
    param([string] $Message)
    Write-Log "ERROR" $Message
    exit 1
}

# Native commands such as robocopy write progress to stderr. With
# $ErrorActionPreference = "Stop" PowerShell turns that into a
# terminating NativeCommandError, so relax it for the duration of the call.
function Resolve-Robocopy {
    # Task Scheduler and hardened hosts do not always inherit a usable PATH,
    # so look the binary up by absolute path first.
    $p = Join-Path $env:SystemRoot "System32\robocopy.exe"
    if (Test-Path $p) { return $p }
    return "robocopy"
}

function Invoke-Robocopy {
    param([string[]] $ArgList)
    $exe  = Resolve-Robocopy
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $text = (& $exe @ArgList 2>&1 | Out-String)
        return @{ code = $LASTEXITCODE; text = $text }
    } finally {
        $ErrorActionPreference = $prev
    }
}

# ---------------------------------------------------------------- config
if (-not $Repo) {
    if (Test-Path $ConfigFile) {
        try {
            $cfg = Get-Content -Path $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($cfg.repo)     { $Repo     = [string]$cfg.repo }
            if ($cfg.branch)   { $Branch   = [string]$cfg.branch }
            if ($cfg.siteRoot) { $SiteRoot = [string]$cfg.siteRoot }
        } catch {
            Write-Log "ERROR" ("config.json is not valid JSON: " + $_.Exception.Message)
            exit 1
        }
    }
}

if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt 512KB)) {
    Move-Item -Path $LogFile -Destination ($LogFile + ".1") -Force
}

# Not configured yet: stay completely silent. The task fires every minute,
# so logging here would flood the log file. Run install-task.ps1 to set up.
if (-not $Repo -or $Repo -notmatch "^[^/\s]+/[^/\s]+$") {
    exit 2
}

# ---------------------------------------------------------------- lock
if (Test-Path $LockFile) {
    $age = (Get-Date) - (Get-Item $LockFile).LastWriteTime
    if ($age.TotalMinutes -lt 10) {
        Write-Log "INFO " "another run is in progress, skipping"
        exit 0
    }
    Write-Log "WARN " "stale lock file, taking over"
    Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
}
$null = New-Item -ItemType File -Path $LockFile -Force

try {
    Write-Log "INFO " ("checking " + $Repo + "@" + $Branch)

    # ------------------------------------------------------------ state
    $state = @{ sha = ""; etag = "" }
    if (Test-Path $StateFile) {
        try {
            $s = Get-Content -Path $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($s.sha)  { $state.sha  = [string]$s.sha }
            if ($s.etag) { $state.etag = [string]$s.etag }
        } catch { Write-Log "WARN " "state.json unreadable, starting fresh" }
    }

    # ------------------------------------------------------------ 1. cheap check
    $api     = "https://api.github.com/repos/$Repo/commits/$Branch"
    $headers = @{
        "User-Agent" = "carnival-sync"
        "Accept"     = "application/vnd.github+json"
    }
    if ($state.etag -and -not $Force) { $headers["If-None-Match"] = $state.etag }

    $sha         = ""
    $newEtag     = ""
    $notModified = $false

    try {
        $r = Invoke-WebRequest -Uri $api -Headers $headers -UseBasicParsing -TimeoutSec 30
        $sha     = ([string]$r.Content | ConvertFrom-Json).sha
        $newEtag = [string]$r.Headers["ETag"]
    } catch {
        $resp = $_.Exception.Response
        if ($resp -and ([int]$resp.StatusCode -eq 304)) {
            $notModified = $true
        } else {
            $msg = $_.Exception.Message
            if ($resp) { $msg = "HTTP " + [int]$resp.StatusCode }
            Fail ("GitHub API request failed: " + $msg)
        }
    }

    if ($notModified -and -not $Force) {
        Write-Log "INFO " "no change (304), nothing to do"
        exit 0
    }

    if ($sha -and $sha -eq $state.sha -and -not $Force) {
        Write-Log "INFO " ("no change (" + $sha.Substring(0,7) + "), nothing to do")
        @{ sha = $state.sha; etag = $newEtag } | ConvertTo-Json |
            Set-Content -Path $StateFile -Encoding UTF8
        exit 0
    }

    if (-not $sha) { $sha = "unknown" }
    Write-Log "INFO " ("new commit " + $sha.Substring(0, [Math]::Min(7, $sha.Length)) + ", syncing")

    # ------------------------------------------------------------ 2. download
    if (Test-Path $TmpDir) { Remove-Item $TmpDir -Recurse -Force }
    $null = New-Item -ItemType Directory -Path $TmpDir -Force

    $zip    = Join-Path $TmpDir "site.zip"
    $zipUrl = "https://codeload.github.com/$Repo/zip/refs/heads/$Branch"

    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        Invoke-WebRequest -Uri $zipUrl -OutFile $zip -UseBasicParsing -TimeoutSec 300
    } catch {
        Fail ("archive download failed: " + $_.Exception.Message)
    }
    $sw.Stop()
    $kb = [Math]::Round((Get-Item $zip).Length / 1KB, 0)
    Write-Log "INFO " ("downloaded " + $kb + " KB in " + [Math]::Round($sw.Elapsed.TotalSeconds,1) + "s")

    # ------------------------------------------------------------ 3. extract
    $stage = Join-Path $TmpDir "stage"
    try {
        Expand-Archive -Path $zip -DestinationPath $stage -Force
    } catch {
        Fail ("unzip failed: " + $_.Exception.Message)
    }

    $inner = Get-ChildItem -Path $stage -Directory | Select-Object -First 1
    if (-not $inner) { Fail "archive has no top level directory" }
    if (-not (Test-Path (Join-Path $inner.FullName "index.html"))) {
        Fail ("index.html not found in archive root (" + $inner.Name + ")")
    }
    Write-Log "INFO " ("archive root: " + $inner.Name)

    # ------------------------------------------------------------ 4. publish
    # /MIR mirrors the source onto the site root, so files removed from the
    # repo also disappear from the server. .github / deploy / .git are not
    # part of the published site and are excluded from both copy and delete.
    $null = New-Item -ItemType Directory -Path $SiteRoot -Force

    $rcArgs = @(
        $inner.FullName, $SiteRoot,
        "/MIR",
        "/XD", ".github", "deploy", ".git",
        "/XF", ".gitignore", ".gitattributes",
        "/R:2", "/W:2",
        "/NFL", "/NDL", "/NJH", "/NJS", "/NP"
    )
    $rc = Invoke-Robocopy -ArgList $rcArgs

    # robocopy: 0-7 mean success, 8 and above mean failure
    if ($rc.code -ge 8) {
        Fail ("robocopy failed (exit " + $rc.code + "): " + $rc.text.Trim())
    }
    Write-Log "INFO " ("published to " + $SiteRoot + " (robocopy exit " + $rc.code + ")")

    foreach ($junk in @("iisstart.htm", "iisstart.png", "CNAME")) {
        $p = Join-Path $SiteRoot $junk
        if (Test-Path $p) { Remove-Item $p -Force -ErrorAction SilentlyContinue }
    }

    $files = (Get-ChildItem -Path $SiteRoot -Recurse -File).Count
    Write-Log "INFO " ("site now holds " + $files + " files")

    # ------------------------------------------------------------ 5. verify
    $healthy = $false
    foreach ($attempt in 1..3) {
        try {
            $v = Invoke-WebRequest -Uri "http://127.0.0.1/" -UseBasicParsing -TimeoutSec 15
            Write-Log "INFO " ("self check: HTTP " + $v.StatusCode + ", " + $v.RawContentLength + " bytes")
            $healthy = $true
            break
        } catch {
            Start-Sleep -Seconds 2
        }
    }
    if (-not $healthy) { Fail "self check failed: http://127.0.0.1/ did not answer" }

    # ------------------------------------------------------------ 6. state
    @{
        sha        = $sha
        etag       = $newEtag
        repo       = $Repo
        branch     = $Branch
        files      = $files
        updated_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    } | ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8

    Write-Log "INFO " "sync complete"
    exit 0
}
catch {
    Write-Log "ERROR" ("unhandled: " + $_.Exception.Message)
    Write-Log "ERROR" ("  at " + $_.InvocationInfo.PositionMessage)
    exit 1
}
finally {
    Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
    if (Test-Path $TmpDir) { Remove-Item $TmpDir -Recurse -Force -ErrorAction SilentlyContinue }
}
