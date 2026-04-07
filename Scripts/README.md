# REAPER Scripts Collection

A comprehensive set of Lua and Python helper scripts for advanced audio workflow in [REAPER](https://www.reaper.fm/). This collection includes tempo map extraction, audio alignment, stem separation, and a floating command center for quick script access.

Designed to complement **ReaDashboard** and support professional audio production, music learning, and stem-based workflows.

## Features

- **Automatic Tempo Mapping** — Extract tempo and time signature markers from click tracks or mixed audio using AI beat detection (Beat This! or BeatNet)
- **Audio Alignment** — Automatically align two similar audio files using MFCC cross-correlation
- **Video/Item Stretching** — Fit audio/video items to variable tempo maps via stretch markers
- **Stem Separation Import** — Import Moises audio stems (drums, bass, vocals, etc.) with pre-organized tracks
- **Tempo Map Export/Import** — Save and restore tempo maps as CSV for sharing or backup
- **Command Center GUI** — Floating panel for quick access to all scripts. Automatically detects new scripts in the folder, and supports custom grid layouts via `cc_buttons.json`.

![Command Center GUI](images/command_center.png)

## Requirements

### REAPER Extensions (Install via ReaPack)

| Extension | Purpose | Install |
|---|---|---|
| **ReaImGui** | ImGui framework for Command Center GUI | `Extensions > ReaPack > Browse packages` → search "ReaImGui" |
| **SWS Extensions** | Advanced scripting API (transient detection, clipboard, file dialogs) | Install via ReaPack or [sws-extension.org](https://www.sws-extension.org/) |
| **js_ReaScriptAPI** | File dialogs for Tempo Map export/import and stem imports | `Extensions > ReaPack > Browse packages` → search "js_ReaScriptAPI" |

### Python & pip Packages

Python 3.x is required. Install via [python.org](https://www.python.org).

**By Script** (install only what you need):

| Script | pip Packages | Notes |
|---|---|---|
| Extract Tempo Map (Audio) | `torch` (CUDA or CPU), `tqdm`, `einops`, `soxr`, `rotary-embedding-torch`, `soundfile`, `beat_this` (GitHub) | GPU recommended for faster processing |
| Extract Tempo Map (Click Track) | Optional: `beat_this` or `beat_net` | Can work without Python for basic click track processing |
| Auto Align Items | `audio-offset-finder` | Lightweight, no GPU needed |
| Fit Item To Tempo Map (MIDI mode) | `mido` | Only needed for Guitar Pro MIDI parsing mode |

**Quick Install** (copy/paste one command):

```bash
# Beat This! + align tools
pip install torch tqdm einops soxr rotary-embedding-torch soundfile audio-offset-finder mido
pip install https://github.com/CPJKU/beat_this/archive/main.zip

# Or if you prefer BeatNet instead of Beat This!
pip install torch librosa pyaudio
pip install git+https://github.com/CPJKU/madmom
pip install BeatNet
```

> **CUDA Setup:** For GPU acceleration, install PyTorch from https://pytorch.org (match your CUDA version). Otherwise, CPU-only installs work but are slower.

### Other Tools

| Tool | Purpose | Install |
|---|---|---|
| **FFmpeg** | Audio encoding/decoding for Python scripts | [ffmpeg.org](https://ffmpeg.org/) — add to PATH |

---

## Installation

### Option 1: ReaPack (Recommended)

Install directly from my ReaPack repository:

1. `Extensions > ReaPack > Import repositories`
2. Paste: `https://github.com/AnshulJ999/REAPER-ReaScripts/raw/main/index.xml`
3. `Extensions > ReaPack > Browse packages`
4. Search for the script name and click Install
5. Scripts and Python companions auto-install together

### Option 2: Manual Installation

1. Download all `.lua`, `.eel`, `.py` files from this folder
2. Place in REAPER's Scripts folder:
   - **Windows:** `%APPDATA%\REAPER\Scripts\`
   - **macOS:** `~/Library/Application Support/REAPER/Scripts/`
   - **Linux:** `~/.config/REAPER/Scripts/`
3. Reload script list in REAPER (`Actions > Show action list > Reload scripts`)

---

## Script Reference

| Script | What It Does | Key Dependencies | Learn |
|---|---|---|---|
| **Command Center GUI** | Floating toolbar that auto-detects scripts. Supports `cc_buttons.json` custom layouts. | ReaImGui, json.lua | Launch once, keep open |
| **Extract Tempo Map (Audio)** | Beat detection on drum/mixed stems → tempo markers | Python: Beat This! or BeatNet, FFmpeg, SWS | Advanced; AI-powered |
| **Extract Tempo Map (Click Track)** | Fast click-track analysis using transient detection | SWS Extensions, Python (optional) | Medium; best for clicks |
| **Auto Align Items** | Align 2 audio items via MFCC correlation | Python: audio-offset-finder, FFmpeg | Easy; ~95%+ similar audio only |
| **Fit Item To Tempo Map** | Fit video/audio via calculated stretch markers. Includes **Transient Snapping** to mathematically fix video render latency. | Python: mido (if using MIDI mode), js_ReaScriptAPI | Medium; 2 modes |
| **Export Tempo Map** | Save project tempo markers to CSV | js_ReaScriptAPI | Easy; one-click export |
| **Import Tempo Map** | Load tempo markers from CSV | js_ReaScriptAPI | Easy; one-click import |
| **Delete Tempo Markers** | Clear all tempo/time sig markers (with confirmation) | None | Easy; safe cleanup |
| **Import Moises Stems (ZIP)** | Universal file picker. Select a ZIP/TAR archive OR any extracted audio stem to auto-import into organized tracks. | js_ReaScriptAPI, Windows tar | Easy; single click |

---

## Common Workflows

### 1. Learn a Song (Full Tempo Mapping)

1. **Get stems** — Use Moises.ai to separate drums/vocals/bass/guitar
2. **Import stems** — Run "Import Moises Stems (ZIP)" and pick the ZIP
3. **Extract tempo** — Select drum stem → "Extract Tempo Map (Audio)" or "(Click Track)"
4. **Review** — Phase 1: place markers, Phase 2: convert to tempo envelope
5. **Fit video** — If you have a tab video, "Fit Item To Tempo Map" with its tempo map

### 2. Align Multiple Takes

1. Select 2 audio items (reference + target)
2. Run "Auto Align Items"
3. Review detected offset + confidence
4. Apply (optionally with Phase Alignment for micro-sync)

### 3. Share Tempo Maps Between Projects

1. **Export** — Project A: "Export Tempo Map" → `my_song.csv`
2. **Import** — Project B: "Import Tempo Map" → select CSV
3. Done — all markers, time sigs, and tempos copied over

---

## Known Limitations

- **Click Track extraction:** Works best on clean metronome clicks. Busy drum recordings need AI (Beat This!/BeatNet)
- **Auto Align:** Only for ~95%-100% similar audio (same source, different takes). Won't work on radically different recordings
- **Moises imports:** RAR archives not supported on Windows (tar limitation) — use ZIP or 7Z instead
- **MIDI parsing:** Guitar Pro MIDI mode requires Python 3.x + mido; CSV mode needs manual CSV format (use "Export Tempo Map" as template)

---

## Troubleshooting

### "Extension required" Error

**Fix:** Install the missing extension via `Extensions > ReaPack > Browse packages` and restart REAPER.

### Python Script Not Found / Timeout

**Causes:**
- Python not in PATH
- pip package not installed
- FFmpeg not in PATH

**Fix:**
```bash
# Check Python installation
python --version

# Reinstall missing package (e.g., Beat This!)
pip install https://github.com/CPJKU/beat_this/archive/main.zip

# Verify FFmpeg is in PATH
ffmpeg -version
```

### Audio Mix Fails (Multi-Item Extract)

**Cause:** FFmpeg decode error on MP3/M4A files without proper metadata.

**Fix:** Ensure FFmpeg is up-to-date:
```bash
# Windows (via winget)
winget install ffmpeg

# Or download from https://ffmpeg.org/download.html
```

### Tempo Map Conversion Hangs

**Cause:** SWS Extensions not installed or long audio (>5 min) + slow CPU.

**Fix:**
- Install SWS via ReaPack
- Increase `BEAT_THIS_TIMEOUT` in script config (line ~96)
- Use shorter audio clips for testing

---

## Contributing & Feedback

Scripts are version-controlled and maintained at [GitHub](https://github.com/AnshulJ999/...).

Found a bug? Have a feature request? Open an issue with:
- REAPER version
- Which script + what went wrong
- Error message from console (`Ctrl+/` in REAPER)
- Python version if applicable

---

**Credits:**
- **X-Raym** — Original tempo marker deletion script structure
- **Tormy Van Cool** — CSV export/import framework
- **BBC Audio Offset Finder** — MFCC correlation algorithm
- **Beat This!** & **BeatNet** — Machine learning beat detection models
- **Moises** — Audio stem separation service
