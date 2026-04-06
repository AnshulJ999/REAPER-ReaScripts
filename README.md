# REAPER Scripts

A collection of personal scripts for [REAPER](https://www.reaper.fm/)

To use this, please add this repo to your ReaPack

```
https://github.com/AnshulJ999/REAPER-ReaScripts/raw/main/index.xml
```

Or manually download script files and load them into REAPER as you wish.

---

## ReaDashboard

A modern project dashboard built with ReaImGui — browse, search, and manage your REAPER projects with album art, custom tags, metadata, filters, grid/list views, and much more.

→ [Full documentation](ReaDashboard/README.md)

**Requirements:** REAPER, ReaImGui, SWS Extensions  
**Install via ReaPack** or drop `Anshul_ReaDashboard.lua` into your Scripts folder.

---

## Scripts

A set of workflow tools for tempo mapping, audio alignment, and stem management. All were created for personal usage.

→ [Full documentation + install guide](Scripts/README.md)

| Script | What It Does |
|---|---|
| **Extract Tempo Map (Audio)** | BeatThis! detection on drum/mixed stems → tempo markers |
| **Extract Tempo Map (Click Track)** | Fast transient-based click track analysis |
| **Auto Align Items** | Align two audio takes via MFCC cross-correlation |
| **Fit Item To Tempo Map** | Stretch markers to sync video/audio to project tempo |
| **Export / Import Tempo Map** | Save and restore tempo markers as CSV |
| **Delete Tempo Markers** | Clear all markers with confirmation |
| **Import Moises Stems** | Import Moises ZIP or folder → organized tracks |

**Requirements vary by script** — Python 3.x + FFmpeg for the heavy tools. See [Scripts/README.md](Scripts/README.md).

---

## Install via ReaPack

1. `Extensions > ReaPack > Import repositories`
2. Paste: `https://github.com/AnshulJ999/REAPER-ReaScripts/raw/main/index.xml`
3. Browse packages and install what you need

---

# Note

All scripts were created for personal use and are provided as-is. The development process included AI assistance.

Please file any issues if you find any bugs or have any suggestions.

## Credits

- **solger** — ReaLauncher concept (ReaDashboard is built on this idea)
- **X-Raym** — Tempo marker deletion script base
- **BBC Audio Offset Finder** — MFCC alignment algorithm
- **Beat This! / BeatNet** — ML beat detection models