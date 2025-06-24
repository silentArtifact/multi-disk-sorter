#!/usr/bin/env pwsh
<#
.SYNOPSIS
Organizes multi-disc game dumps into tidy, playlist-ready folders.

.DESCRIPTION
The script scans a directory for disc images (cue, iso, img, chd, bin, wav
or pbp) and groups them by base game title. Each set is moved to a new
"<Game>" directory, cue sheets are updated so their FILE entries point to the
local files, and a <Game>.m3u playlist is generated when multiple master discs
are detected. Existing playlists are checked for mistakes and corrected, and an
audit reports `OK`, `WARN` or `FAIL` for each playlist and cue file so you can
verify integrity.

.PARAMETER Path
Root directory containing the disc images. Defaults to the current directory.

.PARAMETER Recurse
Recursively search subdirectories for supported files.

.PARAMETER DryRun
Show the operations that would be performed without making changes.

.EXAMPLE
# Organize the current directory
./organize-multidisk.ps1

.EXAMPLE
# Process a custom path and include subfolders
./organize-multidisk.ps1 -Path 'D:\Rips' -Recurse

.EXAMPLE
# Preview the actions without touching the filesystem
./organize-multidisk.ps1 -DryRun
#>

param(
    [string]$Path = ".",
    [switch]$Recurse,
    [switch]$DryRun
)

# 1 ─ settings ─────────────────────────────────────────────
$ExtAll   = ".cue", ".iso", ".img", ".chd", ".bin", ".wav", ".pbp"
$TagRx    = '(?i)[\s\-_]*(?:[\(\[\{]?)(?:disc|disk|cd|d|part|p|track)[\s\-_]*(?:([0-9]{1,2}|[ivxlcdm]+|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve))(?:[\)\]\}]?)'
# ─────────────────────────────────────────────────────────

if (-not (Test-Path -LiteralPath $Path)) { throw "Path '$Path' does not exist." }
$RootPath = (Get-Item -LiteralPath $Path).FullName
Write-Host "`nScanning '$RootPath' …" -fg Cyan

$all = Get-ChildItem -LiteralPath $RootPath -File -Recurse:$Recurse |
       Where-Object { $ExtAll -contains $_.Extension.ToLower() } |
       Sort-Object FullName
Write-Host "Found $($all.Count) disc-related files" -fg Yellow

# 2 ─ group by base-title (tags removed) ────────────────
$groups = @{}
foreach ($f in $all) {
    $base = ($f.BaseName -replace $TagRx, "").Trim(" .-_")
    if (-not $groups.ContainsKey($base)) { $groups[$base] = @() }
    $groups[$base] += ,$f
}

function Move-File($src, $dstDir) {
    if (-not (Test-Path -LiteralPath $src)) { return $null }        # already moved
    if (-not (Test-Path -LiteralPath $dstDir)) {
        if ($DryRun) { Write-Host "[DRYRUN] mkdir $dstDir" }
        else { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
    }
    $dst = Join-Path $dstDir ([IO.Path]::GetFileName($src))
    if ($src -ne $dst) {
        if ($DryRun) { Write-Host "[DRYRUN] move $src -> $dst" }
        else { Move-Item -LiteralPath $src -Destination $dst -Force }
    }
    return $dst
}

$playlists = @()

function Repair-Playlists($root) {
    Write-Host "`nChecking playlists …" -fg Cyan
    $list = Get-ChildItem -LiteralPath $root -Filter *.m3u -File -Recurse:$Recurse |
            Sort-Object FullName
    foreach ($p in $list) {
        $base = [IO.Path]::GetFileNameWithoutExtension($p.Name)
        $dir  = $p.Directory.FullName
        if ($p.Directory.Name -ne $base -and (Test-Path -LiteralPath (Join-Path $dir $base))) {
            $p = Move-File $p.FullName (Join-Path $dir $base)
        } else {
            $p = $p.FullName
        }
        $gdir    = Split-Path $p -Parent
        $masters = Get-ChildItem -LiteralPath $gdir -File |
                   Where-Object { $_.Extension -match '\.(cue|iso|img|chd)$' }
        if ($masters.Count -lt 2) {
            if ($DryRun) { Write-Host "[DRYRUN] remove $p" -fg Yellow }
            else { Remove-Item -LiteralPath $p -Force }
            continue
        }
        $expected = $masters | Sort-Object Name | ForEach-Object { $_.Name }
        $current  = Get-Content -LiteralPath $p 2>$null
        $needFix  = ($expected.Count -ne $current.Count) -or
                    (Compare-Object $expected $current)
        if ($needFix) {
            if ($DryRun) { Write-Host "[DRYRUN] update $p" -fg Yellow }
            else { $expected | Set-Content -LiteralPath $p }
        }
        $script:playlists += $p
    }
}

# 3 ─ organise every set ───────────────────────────────
foreach ($pair in $groups.GetEnumerator()) {

    $game  = $pair.Key
    $files = $pair.Value

    # master= cue / iso / img / chd (bins & wavs are data tracks)
    $masters = $files | Where-Object { $_.Extension -match '\.(cue|iso|img|chd)$' }

    $targetDir = if ($masters.Count -gt 1) {
        Join-Path $RootPath $game
    } else {
        $RootPath
    }
    $origDirs = $files | ForEach-Object { $_.Directory.FullName } | Sort-Object -Unique

    Write-Host "→ $game  [$($masters.Count) disc(s)]" -fg Cyan

    $cueFixList = @()
    foreach ($f in $files) {
        $moved = Move-File $f.FullName $targetDir
        if ($moved -and $f.Extension -ieq ".cue") { $cueFixList += @{Path=$moved;OrigDir=$f.Directory.FullName} }
    }

    # fix cue FILE targets
    foreach ($c in $cueFixList) {
        if (-not (Test-Path -LiteralPath $c.Path)) { continue }
        $dir = Split-Path $c.Path -Parent
        $newContent = (Get-Content -LiteralPath $c.Path) |
            ForEach-Object {
                if ($_ -match '^\s*FILE\s+"([^"]+)"') {
                    $srcT = Join-Path $c.OrigDir $Matches[1]
                    $dstT = Move-File $srcT $dir
                    'FILE "' + ([IO.Path]::GetFileName($dstT)) + '" BINARY'
                } else { $_ }
            }
        if ($DryRun) {
            Write-Host "[DRYRUN] update $($c.Path)" -fg Yellow
        } else {
            $newContent | Set-Content -LiteralPath $c.Path
        }
    }

    # write playlist only if multi-disc
    if ($masters.Count -gt 1) {
        $m3u = Join-Path $targetDir "$game.m3u"
        $content = $masters | Sort-Object FullName | ForEach-Object { [IO.Path]::GetFileName($_.Name) }
        if ($DryRun) {
            Write-Host "[DRYRUN] create $game\$game.m3u" -fg Yellow
        } else {
            $content | Set-Content -LiteralPath $m3u
            $playlists += $m3u
            Write-Host "   ✔  m3u → $game\$game.m3u" -fg Green
        }
    } else {
        $p1 = Join-Path $RootPath "$game.m3u"
        $p2 = Join-Path (Join-Path $RootPath $game) "$game.m3u"
        foreach ($p in @($p1,$p2)) {
            if (Test-Path -LiteralPath $p) {
                if ($DryRun) { Write-Host "[DRYRUN] remove $p" -fg Yellow }
                else { Remove-Item -LiteralPath $p -Force }
            }
        }
    }

    foreach ($d in $origDirs) {
        if ($d -eq $targetDir) { continue }
        if (Test-Path -LiteralPath $d) {
            if ((Get-ChildItem -LiteralPath $d -Force | Measure-Object).Count -eq 0) {
                if ($DryRun) { Write-Host "[DRYRUN] rmdir $d" -fg Yellow }
                else { Remove-Item -LiteralPath $d -Force -Recurse }
            }
        }
    }
}

Write-Host "`nOrganise phase complete." -fg Cyan

Repair-Playlists $RootPath

if ($DryRun) {
    Write-Host "`nDry run - skipping audit." -fg Cyan
    return
}

# 4 ─ audit ─────────────────────────────────────────────
Write-Host "`n=== AUDIT REPORT ===" -fg Magenta

function Check-Cue($cue){
    $bad = 0; $d = Split-Path $cue -Parent
    Get-Content -LiteralPath $cue | ForEach-Object {
        if ($_ -match '^\s*FILE\s+"([^"]+)"') {
            if (-not (Test-Path -LiteralPath (Join-Path $d $Matches[1]))) { $bad++ }
        }
    }; return $bad
}

foreach ($pl in $playlists) {
    if (-not (Test-Path -LiteralPath $pl)) { Write-Host "FAIL  (playlist missing)  $pl" -fg Red; continue }

    $raw = Get-Content -LiteralPath $pl -Raw
    if ($raw -notmatch "`r?`n") { Write-Host "FAIL  $(Split-Path $pl -Leaf)  (no line breaks)" -fg Red; continue }

    $entries   = Get-Content -LiteralPath $pl
    $missing   = 0
    $cueErrors = 0
    foreach ($rel in $entries) {
        $abs = Join-Path (Split-Path $pl -Parent) $rel
        if (-not (Test-Path -LiteralPath $abs)) { $missing++ ; continue }
        if ($abs -like "*.cue") { $cueErrors += Check-Cue $abs }
    }

    switch ($true) {
        { $missing -eq 0 -and $cueErrors -eq 0 } {
            Write-Host " OK    $(Split-Path $pl -Leaf)" -fg Green ; break
        }
        { $missing -eq 0 } {
            Write-Host " WARN  $(Split-Path $pl -Leaf)  ($cueErrors bad FILE refs)" -fg Yellow ; break
        }
        default {
            Write-Host " FAIL  $(Split-Path $pl -Leaf)  ($missing missing, $cueErrors bad cues)" -fg Red
        }
    }
}

Write-Host "`nDone." -fg Cyan
