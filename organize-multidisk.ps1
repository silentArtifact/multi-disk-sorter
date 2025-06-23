<#
  Organize-MultiDisc.ps1  – v3.1 (NextUI layout, Track-aware, idempotent)

  • Groups dumps by base title, stripping Disc/CD/Part/Track markers.
  • Moves every file into "<Game>\" (no dot-prefix – NextUI rule).
  • Fixes FILE lines in each moved .cue so they point to local bin/wav.
  • Creates <Game>.m3u **inside** the folder when there are ≥ 2 discs.
  • Supports cue / iso / img / chd / bin / wav / pbp.
  • Post-audit: OK / WARN / FAIL for playlists & cue integrity.
#>

param(
    [string]$Path = ".",
    [switch]$Recurse
)

# 1 ─ settings ─────────────────────────────────────────────
$ExtAll   = ".cue", ".iso", ".img", ".chd", ".bin", ".wav", ".pbp"
$TagRx    = '(?i)[\s\-_]*(?:[\(\[\{]?)(?:disc|disk|cd|d|part|p|track)[\s\-_]*([0-9]{1,2})(?:[\)\]\}]?)'
# ─────────────────────────────────────────────────────────

if (-not (Test-Path $Path)) { throw "Path '$Path' does not exist." }
Write-Host "`nScanning '$Path' …" -fg Cyan

$all = Get-ChildItem -Path $Path -File -Recurse:$Recurse |
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
    if (-not (Test-Path $src)) { return $null }        # already moved
    if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
    $dst = Join-Path $dstDir ([IO.Path]::GetFileName($src))
    if ($src -ne $dst) { Move-Item $src $dst -Force }
    return $dst
}

$playlists = @()

# 3 ─ organise every set ───────────────────────────────
foreach ($pair in $groups.GetEnumerator()) {

    $game    = $pair.Key
    $files   = $pair.Value
    $rootDir = $files[0].Directory.FullName
    $gDir    = Join-Path $rootDir $game

    # master= cue / iso / img / chd (bins & wavs are data tracks)
    $masters = $files | Where-Object { $_.Extension -match '\.(cue|iso|img|chd)$' }

    Write-Host "→ $game  [$($masters.Count) disc(s)]" -fg Cyan

    $cueFixList = @()
    foreach ($f in $files) {
        $moved = Move-File $f.FullName $gDir
        if ($moved -and $f.Extension -ieq ".cue") { $cueFixList += @{Path=$moved;OrigDir=$f.Directory.FullName} }
    }

    # fix cue FILE targets
    foreach ($c in $cueFixList) {
        if (-not (Test-Path $c.Path)) { continue }
        $dir = Split-Path $c.Path -Parent
        (Get-Content $c.Path) |
        ForEach-Object {
            if ($_ -match '^\s*FILE\s+"([^"]+)"') {
                $srcT = Join-Path $c.OrigDir $Matches[1]
                $dstT = Move-File $srcT $dir
                'FILE "' + ([IO.Path]::GetFileName($dstT)) + '" BINARY'
            } else { $_ }
        } | Set-Content $c.Path
    }

    # write playlist only if multi-disc
    if ($masters.Count -gt 1) {
        $m3u = Join-Path $gDir "$game.m3u"
        ($masters | Sort-Object FullName | ForEach-Object { [IO.Path]::GetFileName($_.Name) }) |
            Set-Content $m3u
        $playlists += $m3u
        Write-Host "   ✔  m3u → $game\$game.m3u" -fg Green
    }
}

Write-Host "`nOrganise phase complete." -fg Cyan

# 4 ─ audit ─────────────────────────────────────────────
Write-Host "`n=== AUDIT REPORT ===" -fg Magenta

function Check-Cue($cue){
    $bad = 0; $d = Split-Path $cue -Parent
    Get-Content $cue | ForEach-Object {
        if ($_ -match '^\s*FILE\s+"([^"]+)"') {
            if (-not (Test-Path (Join-Path $d $Matches[1]))) { $bad++ }
        }
    }; return $bad
}

foreach ($pl in $playlists) {
    if (-not (Test-Path $pl)) { Write-Host "FAIL  (playlist missing)  $pl" -fg Red; continue }

    $raw = Get-Content $pl -Raw
    if ($raw -notmatch "`r?`n") { Write-Host "FAIL  $(Split-Path $pl -Leaf)  (no line breaks)" -fg Red; continue }

    $entries   = Get-Content $pl
    $missing   = 0
    $cueErrors = 0
    foreach ($rel in $entries) {
        $abs = Join-Path (Split-Path $pl -Parent) $rel
        if (-not (Test-Path $abs)) { $missing++ ; continue }
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
