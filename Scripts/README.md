# REAPER Scripts Collection

A suite of REAPER tools for tempo mapping, item alignment, and Moises stem imports. All scripts are tied together with a floating Command Center GUI. 

## Installation

**1. Install via ReaPack**
- `Extensions > ReaPack > Import repositories`
- Paste: `https://raw.githubusercontent.com/AnshulJ999/REAPER-ReaScripts/main/index.xml`
- Browse packages and install the scripts you want.

**2. REAPER Extensions Required**
Ensure you have the following installed from ReaPack:
- **ReaImGui** (GUI framework)
- **SWS Extensions** (Audio transient detection / logic)
- **js_ReaScriptAPI** (File dialogs and import/export)

**3. External Dependencies (For Python Scripts)**
Some scripts ("Auto Align", "Extract Tempo Map") rely on Python 3 and FFmpeg. Ensure FFmpeg is in your system `PATH`. Python dependencies can be installed natively:

```bash
# 1. Install PyTorch with CUDA support specifically from https://pytorch.org/ (Optional, but highly recommended for fast GPU tempo mapping)
# Or for standard CPU-only:
pip install torch

# 2. Install script tools
pip install audio-offset-finder mido https://github.com/CPJKU/beat_this/archive/main.zip
```

---

## 🛠️ The Scripts

### Command Center GUI
A floating toolbar to quickly launch your tools. It automatically detects any `.lua` scripts added to your folder and creates buttons for them. You can completely customize the grid layout by creating a `cc_buttons.json` file in the same directory.

### Extract Tempo Map (Audio & Click Track)
Automatically extracts tempo maps from audio files. 
- **Audio Mode:** Uses the AI `beat_this` model to detect transients and downbeats in complex musical stems.
- **Click Track Mode:** Skips the AI and uses SWS Transient detection to instantly generate markers from a metronome track.

### Auto Align Items
Select two audio takes and run this. It uses an MFCC cross-correlation algorithm from BBC to mathematically shift the second item so it perfectly aligns with the first. Only works efficiently on highly similar audio (e.g., matching a mic'd take to a DI take).

### Fit Item To Tempo Map
Calculates and inserts stretch markers to lock an audio or video item to your project's tempo map. Supports Fixed BPM or Variable (MIDI/CSV). 
**Killer Feature:** Includes an optional Transient Snapping mode to calculate and erase the render latency from video files mathematically by locking the very first audio transient to the grid.

### Import Moises Stems (ZIP)
A universal file picker for Moises stems. Select a `.zip` file (or raw audio stem) and it will automatically extract, scan, and import all the stems into organized, color-coded, and volume-adjusted child tracks.
*Note: Uses Windows native `tar`. RAR archives are not natively supported; use ZIP.*

### Import / Export Tempo Maps
Save your project's current tempo map (and time signatures) as a CSV file to share between different REAPER projects, or import CSVs easily.

---

## Known Constraints

- Scripts using Python lookup paths are heavily optimized for Windows explicitly (`where python`, `AppData` sweeps). macOS/Linux may require you to edit the Lua command paths. 
- MIDI parsing (`Fit Item To Tempo Map` mode 2) requires the `mido` library.
