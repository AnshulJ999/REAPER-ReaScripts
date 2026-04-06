# REAPER-ReaScripts

A collection of Lua scripts for [REAPER](https://www.reaper.fm/) — focused on tempo mapping, audio alignment, and project management.

---

## ReaDashboard

A modern project dashboard built with ReaImGui — browse, search, and manage your REAPER projects with album art, custom tags, metadata, grid/list views, and keyboard navigation.

→ [Full documentation](ReaDashboard/README.md)

**Requirements:** REAPER v6+, ReaImGui, SWS Extensions  
**Install via ReaPack** or drop `Anshul_ReaDashboard.lua` into your Scripts folder.

---

## Scripts

A set of workflow tools for tempo mapping, audio alignment, and stem management.

→ [Full documentation + install guide](Scripts/README.md)

| Script | What It Does |
|---|---|
| **Extract Tempo Map (Audio)** | AI beat detection on drum/mixed stems → tempo markers |
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

## Credits

- **solger** — ReaLauncher concept (ReaDashboard is built on this idea)
- **X-Raym** — Tempo marker deletion script base
- **BBC Audio Offset Finder** — MFCC alignment algorithm
- **Beat This! / BeatNet** — ML beat detection models