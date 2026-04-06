# ReaDashboard

A modern, feature-rich project dashboard for [REAPER](https://www.reaper.fm/), built with [ReaImGui](https://forum.cockos.com/showthread.php?t=250419).

Browse, search, filter, and manage your REAPER projects with album art, metadata, custom tags, and more.

# Note

This was built for my personal use and is optimized for my workflow: I'm a guitarist who learns/covers a lot of songs.

## Features

- **Recent & All Projects** - Browse recent projects from REAPER's history or scan an entire folder tree
- **Grid & List Views** - Switch between a visual grid with album art or a detailed sortable table
- **Search & Filters** - Full-text search across project names, artists, albums, tags, and more. Filter by string count, tuning, status, genre, favorites, and metadata coverage
- **Custom Tags** - Tag projects with status (Learning, Complete, etc.), tuning, difficulty, strings, guitar, amp, and free-text notes
- **Metadata Enrichment** - BPM, key, time signature, and duration extracted from project files
- **Album Art** - Automatic album art display from local databases
- **Keyboard Navigation** - Full keyboard support with arrow keys, Enter to open, and search history
- **Theming** - Customizable accent colors, dark mode, window opacity, and corner rounding
- **Export** - Export project lists as CSV, Markdown, or JSON
- **Spicetify Integration** (Optional) - Enrich projects with metadata from a local Spicetify database

## Requirements

- **REAPER** v5.0+ (v6+ recommended)
- **ReaImGui** - Install via ReaPack (`Extensions > ReaPack > Browse packages`, search "ReaImGui")
- **SWS Extension** - Required for clipboard, file browsing, and project management features. [Download SWS](https://www.sws-extension.org/)
- **js_ReaScriptAPI** (Recommended) - Install via ReaPack for fast file info lookups

## Installation

1. Install the required extensions above via ReaPack
2. Place `Anshul_ReaDashboard.lua` in your REAPER Scripts folder
3. In REAPER: `Actions > Show action list > Load ReaScript...` and select the file
4. Assign a keyboard shortcut for quick access (recommended)

## First Launch

1. Open Settings (the Settings tab at the top)
2. Set **Projects Folder** to the root folder containing your `.rpp` files
3. Adjust **Max Scan Depth** if your projects are nested deeper than the default
4. Press **Shift+F5** (Hard Refresh) to scan and build the metadata cache

The **Recent** tab works immediately with no configuration - it reads directly from REAPER's recent projects list.

## Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| `F5` | Refresh (uses cached data) |
| `Shift+F5` | Hard Refresh (re-scans everything) |
| `Enter` | Open selected project |
| `Up/Down` | Navigate project list |
| `Ctrl+Click` | Multi-select |
| `Shift+Click` | Range select |
| `Ctrl+C` | Copy project path |
| `Ctrl+B` | Close the launcher |
| `Ctrl+Tab` | Switch tabs |
| `Ctrl+1,2,3,4` | Switch tabs |

## Known Limitations

- **Unique filenames required**: The script identifies projects by their filename. If two projects in different folders have the same `.rpp` filename, they will share metadata. Ensure project files have unique names across directories.
- **Spicetify integration is optional**: Most users will not have a Spicetify database. The script is fully functional without it - BPM, key, and other metadata can be overridden manually via tags.

Based on [ReaLauncher's](https://forum.cockos.com/showthread.php?t=244541) concept by solger.
