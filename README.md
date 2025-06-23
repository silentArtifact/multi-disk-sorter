# Multi-Disk Sorter

`organize-multidisk.ps1` is a PowerShell helper that rearranges multi-disc game dumps into tidy folders. It is safe to run multiple times and works on Windows PowerShell or PowerShell Core.

## Prerequisites

* A recent version of PowerShell (5.x or 7+).
* Disc images placed in a directory containing `.cue`, `.iso`, `.img`, `.chd`, `.bin`, `.wav` or `.pbp` files.

## Usage

Invoke the script from a PowerShell prompt:

```powershell
# Sort the current directory
./organize-multidisk.ps1
```

The optional `-Path` parameter specifies the directory to process. `-Recurse` tells the script to search subfolders as well.

```powershell
# Only process the given folder
./organize-multidisk.ps1 -Path 'D:\Rips'

# Process the folder and all of its subdirectories
./organize-multidisk.ps1 -Path 'D:\Rips' -Recurse
```

On non-Windows systems you can call it with `pwsh`:

```bash
pwsh ./organize-multidisk.ps1 -Path '/mnt/dumps' -Recurse
```

## What the script does

1. Scans for supported image files and groups them by base game title (removing `Disc`, `CD`, `Part`, etc.).
2. Places multi-disc games in a `<Game>` directory (single-disc titles remain in the root) and fixes any `FILE` lines inside moved `.cue` files.
3. Creates a `<Game>.m3u` playlist whenever there are multiple master images and fixes any broken playlists it finds. Playlists for single-disc games are removed.
4. Runs an audit reporting `OK`, `WARN` or `FAIL` for each playlist and cue file so you can verify integrity.

After the audit completes the console will display `Done.`

