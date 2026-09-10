# ClaudeGuard - backup, diagnose, and verify Claude Code's local data on Windows.
#
# Built because of a real, documented Anthropic bug (github.com/anthropics/claude-code
# issue #88323): recent Claude Desktop MSIX builds bundle vk_swiftshader.dll, which
# Windows Code Integrity blocks on machines with Memory Integrity (HVCI) enabled. That
# crashes the GPU process, flags the whole package Modified/NeedsRemediation, and the
# next launch fails with "This app can't open." Repair/reinstall only resets the clock -
# it self-corrupts again within a session. Two more confirmed Anthropic bugs compound
# this: reinstalling can silently destroy Code chat history while other data survives
# (issue #62997), and lost sessions are often unrecoverable from the UI even though the
# transcript files are still on disk (issue #81907) - so a user has no reliable way to
# even tell what they lost.
#
# This does NOT replace github.com/jtklinger/claude-code-backup-guide, which is a
# excellent, actively maintained, git-versioned backup/restore system for people
# comfortable with bash/git/jq. ClaudeGuard is narrower and Windows-specific: it
# diagnoses the actual MSIX/Code-Integrity corruption (which that tool doesn't touch),
# and gives a zero-setup, double-clickable safety net for people who just want to know
# "is my install broken, and is my history safe" without adopting a git-based workflow.
#
# Commands:
#   ClaudeGuard.ps1 backup    - zips ~/.claude to a timestamped local file, writes a
#                               manifest (project/session/memory counts) so "did I lose
#                               anything" has a real number to check against later.
#   ClaudeGuard.ps1 diagnose  - read-only check for the MSIX Code Integrity corruption
#                               (AppxPackage status, Code Integrity event log, whether
#                               Memory Integrity is on). Never modifies anything.
#   ClaudeGuard.ps1 verify    - compares current ~/.claude against the most recent
#                               backup's manifest and reports exactly what's missing.
#
# This script never downloads files, never edits the hosts file, and never modifies
# Windows/Defender settings on its own - those are real system changes with real
# tradeoffs (see README.md's "Applying the permanent fix" section), so they're printed
# as manual steps, not auto-applied.

param(
    [Parameter(Position = 0)]
    [ValidateSet("backup", "diagnose", "verify")]
    [string]$Command = "diagnose"
)

$ErrorActionPreference = "Continue"
$claudeDir = Join-Path $env:USERPROFILE ".claude"
$guardDir = Join-Path $env:USERPROFILE "ClaudeGuard"
$backupsDir = Join-Path $guardDir "backups"

function Get-ClaudeCounts {
    $projectsDir = Join-Path $claudeDir "projects"
    if (-not (Test-Path $projectsDir)) {
        return @{ ProjectCount = 0; SessionCount = 0; MemoryFileCount = 0 }
    }
    $projectCount = (Get-ChildItem $projectsDir -Directory -ErrorAction SilentlyContinue | Measure-Object).Count
    $sessionCount = (Get-ChildItem $projectsDir -Recurse -Filter "*.jsonl" -ErrorAction SilentlyContinue | Measure-Object).Count
    $memoryCount = (Get-ChildItem $projectsDir -Recurse -Filter "MEMORY.md" -ErrorAction SilentlyContinue | Measure-Object).Count
    return @{ ProjectCount = $projectCount; SessionCount = $sessionCount; MemoryFileCount = $memoryCount }
}

function Invoke-Backup {
    if (-not (Test-Path $claudeDir)) {
        Write-Host "[ERROR] No ~/.claude folder found at $claudeDir - nothing to back up." -ForegroundColor Red
        return
    }
    New-Item -ItemType Directory -Path $backupsDir -Force | Out-Null
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $zipPath = Join-Path $backupsDir "claude-backup-$timestamp.zip"
    $manifestPath = Join-Path $backupsDir "claude-backup-$timestamp.manifest.json"

    Write-Host "==> Backing up $claudeDir ..." -ForegroundColor Cyan
    Compress-Archive -Path $claudeDir -DestinationPath $zipPath -CompressionLevel Optimal

    $counts = Get-ClaudeCounts
    $zipSize = (Get-Item $zipPath).Length
    $manifest = @{
        timestamp       = $timestamp
        zipPath         = $zipPath
        zipSizeBytes    = $zipSize
        projectCount    = $counts.ProjectCount
        sessionCount    = $counts.SessionCount
        memoryFileCount = $counts.MemoryFileCount
    }
    $manifest | ConvertTo-Json | Set-Content -Path $manifestPath -Encoding UTF8

    Write-Host "[OK] Backup complete: $zipPath ($([math]::Round($zipSize / 1MB, 1)) MB)" -ForegroundColor Green
    Write-Host "     Projects: $($counts.ProjectCount)   Sessions: $($counts.SessionCount)   Memory files: $($counts.MemoryFileCount)"
    Write-Host "     Manifest saved for later comparison: $manifestPath"
}

function Invoke-Diagnose {
    Write-Host "=================================================="
    Write-Host "  CLAUDEGUARD DIAGNOSIS"
    Write-Host "=================================================="
    Write-Host ""

    $currentlyBroken = $false
    $historicalRisk = $false

    Write-Host "--- Squirrel (fixed, unpackaged) build ---" -ForegroundColor Cyan
    $squirrelBuilds = Get-ChildItem "$env:LOCALAPPDATA\AnthropicClaude" -Directory -Filter "app-*" -ErrorAction SilentlyContinue
    $hasSquirrelBuild = $false
    if ($squirrelBuilds) {
        foreach ($b in $squirrelBuilds) {
            if (Test-Path (Join-Path $b.FullName "claude.exe")) {
                Write-Host "[OK] Fixed build present: $($b.FullName)\claude.exe" -ForegroundColor Green
                $hasSquirrelBuild = $true
            }
        }
    }
    if (-not $hasSquirrelBuild) {
        Write-Host "[INFO] No unpackaged (Squirrel) build found at %LOCALAPPDATA%\AnthropicClaude\ - still on the MSIX build, or the fix was applied to a non-default location." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "--- Package status ---" -ForegroundColor Cyan
    $pkgs = Get-AppxPackage -Name "*Claude*" -ErrorAction SilentlyContinue
    if (-not $pkgs) {
        if ($hasSquirrelBuild) {
            Write-Host "[OK] No MSIX Claude package found, and the fixed build is present - the fix is fully applied, nothing left to corrupt." -ForegroundColor Green
        } else {
            Write-Host "[INFO] No MSIX Claude package found - either not installed via MSIX, or Claude isn't installed." -ForegroundColor Yellow
        }
    } else {
        foreach ($pkg in $pkgs) {
            $status = $pkg.Status
            if ($status -match "NeedsRemediation|Modified|Tampered|LicenseIssue") {
                Write-Host "[PROBLEM] $($pkg.PackageFullName) status: $status - this IS currently broken." -ForegroundColor Red
                $currentlyBroken = $true
            } else {
                Write-Host "[OK] $($pkg.PackageFullName) status: $status" -ForegroundColor Green
            }
        }
        if ($hasSquirrelBuild) {
            Write-Host "[PROBLEM] Both the MSIX package AND the fixed Squirrel build are present. The old MSIX one still risks auto-updating itself in the background and can still surface in Windows Search/Start Menu by habit - uninstall it via Settings > Apps once you've confirmed the Squirrel build works (see README.md step 6)." -ForegroundColor Red
        }
    }

    Write-Host ""
    Write-Host "--- Code Integrity event log (last 200 events, filtered) ---" -ForegroundColor Cyan
    try {
        $allEvents = Get-WinEvent -FilterHashtable @{ LogName = "Microsoft-Windows-CodeIntegrity/Operational"; Id = 3033, 3010 } -MaxEvents 200 -ErrorAction Stop
        $claudeEvents = $allEvents | Where-Object { $_.Message -match "Claude|AnthropicClaude" }
        $otherVkEvents = $allEvents | Where-Object { $_.Message -match "vk_swiftshader" -and $_.Message -notmatch "Claude|AnthropicClaude" }
        if ($claudeEvents) {
            $recent = $claudeEvents | Select-Object -First 5
            foreach ($e in $recent) {
                Write-Host "[PROBLEM] Event $($e.Id) at $($e.TimeCreated): $($e.Message.Substring(0, [Math]::Min(140, $e.Message.Length)))..." -ForegroundColor Red
            }
            Write-Host "[PROBLEM] $($claudeEvents.Count) Code Integrity block(s) specifically naming Claude found - matches the known MSIX bug's signature. These are a history of past crashes, not necessarily happening right now (see Package status above for current state)." -ForegroundColor Red
            $historicalRisk = $true
        } else {
            Write-Host "[OK] No Code Integrity blocks naming Claude found." -ForegroundColor Green
        }
        if ($otherVkEvents) {
            Write-Host "[INFO] $($otherVkEvents.Count) other process(es) (e.g. Chrome) also hit the same vk_swiftshader block on this machine - expected on any machine with Memory Integrity enabled, not itself a Claude problem, just confirms the environment triggers this class of block." -ForegroundColor Yellow
        }
    } catch {
        Write-Host "[INFO] Could not read the Code Integrity event log (may need to run as Administrator, or the log doesn't exist on this system)." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "--- Memory Integrity (HVCI) status ---" -ForegroundColor Cyan
    try {
        $dg = Get-CimInstance -Namespace "root\Microsoft\Windows\DeviceGuard" -ClassName Win32_DeviceGuard -ErrorAction Stop
        Write-Host "[INFO] SecurityServicesRunning: $($dg.SecurityServicesRunning -join ', ') (raw value from Windows - a non-empty list here is what makes a machine susceptible to this bug in the first place; this script doesn't claim to decode every possible combination)." -ForegroundColor Yellow
    } catch {
        Write-Host "[INFO] Could not query Device Guard / Memory Integrity status on this system." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "--- Claude Code local data ---" -ForegroundColor Cyan
    $counts = Get-ClaudeCounts
    if ($counts.ProjectCount -eq 0) {
        Write-Host "[INFO] No ~/.claude/projects data found (or Claude Code has never run here)." -ForegroundColor Yellow
    } else {
        Write-Host "[OK] Found $($counts.ProjectCount) project(s), $($counts.SessionCount) session file(s), $($counts.MemoryFileCount) memory file(s)." -ForegroundColor Green
        Write-Host "     Run 'ClaudeGuard.ps1 backup' now if you haven't recently - especially before touching the install." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "=================================================="
    if ($currentlyBroken) {
        Write-Host "  VERDICT: Claude's MSIX package is CURRENTLY broken (NeedsRemediation/Modified)." -ForegroundColor Red
        Write-Host "  Back up now (ClaudeGuard.ps1 backup) before doing anything else, then see" -ForegroundColor Yellow
        Write-Host "  README.md's 'Applying the permanent fix' section." -ForegroundColor Yellow
    } elseif ($hasSquirrelBuild -and -not $pkgs) {
        Write-Host "  VERDICT: Fix fully applied. Running the unpackaged build, no MSIX package" -ForegroundColor Green
        Write-Host "  left to corrupt. Nothing further needed." -ForegroundColor Green
    } elseif ($hasSquirrelBuild -and $pkgs) {
        Write-Host "  VERDICT: Fix applied but incomplete - the fixed build exists, but the old" -ForegroundColor Yellow
        Write-Host "  MSIX package is still installed alongside it. Uninstall the old one (see" -ForegroundColor Yellow
        Write-Host "  README.md step 6) to finish closing this out." -ForegroundColor Yellow
    } elseif ($historicalRisk) {
        Write-Host "  VERDICT: Not currently broken, but this machine HAS hit the known MSIX Code" -ForegroundColor Yellow
        Write-Host "  Integrity bug before and is running with Memory Integrity enabled, so it will" -ForegroundColor Yellow
        Write-Host "  likely recur. Worth applying the permanent fix proactively - see README.md." -ForegroundColor Yellow
    } else {
        Write-Host "  VERDICT: No sign of the known MSIX corruption bug, past or present." -ForegroundColor Green
    }
    Write-Host "=================================================="
}

function Invoke-Verify {
    if (-not (Test-Path $backupsDir)) {
        Write-Host "[ERROR] No backups found yet. Run 'ClaudeGuard.ps1 backup' first." -ForegroundColor Red
        return
    }
    $latestManifest = Get-ChildItem $backupsDir -Filter "*.manifest.json" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latestManifest) {
        Write-Host "[ERROR] No backup manifest found in $backupsDir. Run 'ClaudeGuard.ps1 backup' first." -ForegroundColor Red
        return
    }
    $old = Get-Content $latestManifest.FullName -Raw | ConvertFrom-Json
    $current = Get-ClaudeCounts

    Write-Host "=================================================="
    Write-Host "  VERIFY AGAINST LAST BACKUP ($($old.timestamp))"
    Write-Host "=================================================="
    Write-Host ""

    function Compare-Count($label, $oldVal, $newVal) {
        if ($newVal -lt $oldVal) {
            Write-Host "[PROBLEM] $label dropped: $oldVal -> $newVal (missing $($oldVal - $newVal))" -ForegroundColor Red
        } elseif ($newVal -gt $oldVal) {
            Write-Host "[OK] $label increased: $oldVal -> $newVal" -ForegroundColor Green
        } else {
            Write-Host "[OK] $label unchanged: $newVal" -ForegroundColor Green
        }
    }

    Compare-Count "Projects" $old.projectCount $current.ProjectCount
    Compare-Count "Sessions" $old.sessionCount $current.SessionCount
    Compare-Count "Memory files" $old.memoryFileCount $current.MemoryFileCount
}

switch ($Command) {
    "backup"   { Invoke-Backup }
    "diagnose" { Invoke-Diagnose }
    "verify"   { Invoke-Verify }
}
