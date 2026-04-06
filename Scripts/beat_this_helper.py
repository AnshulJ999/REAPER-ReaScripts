# @noindex
#!/usr/bin/env python3
"""
beat_this_helper.py
Runs Beat This! beat tracker on an audio file and outputs beat/downbeat times as CSV.

Author: Anshul

Usage:
    python beat_this_helper.py <audio_file> <output_csv>

Output CSV columns:
    beat_time   - beat position in seconds (from start of audio file)
    is_downbeat - 1 if downbeat (measure start), 0 if regular beat

Installation (in this exact order):
    1. pip install torch             <- from https://pytorch.org (pick your CUDA version)
    2. pip install tqdm einops soxr rotary-embedding-torch
    3. pip install https://github.com/CPJKU/beat_this/archive/main.zip
    4. pip install soundfile         <- torchaudio audio backend (omitted from beat-this deps)
    For non-WAV audio: FFmpeg must be installed and in PATH.

Notes:
    - First run downloads model weights (~78 MB) automatically to cache.
    - Subsequent runs use the cached model and are fast.
    - GPU (CUDA) is used automatically if available, otherwise falls back to CPU.
"""

import sys
import csv
import os
import site
import subprocess
import tempfile

# When launched from REAPER via ExecProcess, user site-packages may not be
# in sys.path. Add them explicitly so installed packages are found.
try:
    user_site = site.getusersitepackages()
    if user_site not in sys.path:
        sys.path.insert(0, user_site)
except Exception:
    pass


def _is_wav(path):
    return path.lower().endswith(".wav")


def _convert_to_wav(audio_path):
    """Convert audio to a temporary WAV file using ffmpeg.exe.

    torchaudio's soundfile backend (which ships with torchaudio on Windows)
    only supports WAV/FLAC/AIFF natively.  MP3, OGG, and other formats require
    the FFmpeg *shared-library* backend, which needs avcodec/avformat DLLs.
    The winget FFmpeg package is a static build (no DLLs), so that backend is
    unavailable.  Using ffmpeg.exe via subprocess is the reliable cross-platform
    alternative: it works with any FFmpeg installation that is in PATH.

    Returns the path to the temp WAV file.  Caller is responsible for deleting it.
    """
    tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
    tmp.close()
    wav_path = tmp.name
    print(f"INFO: Converting to temp WAV via ffmpeg ({os.path.basename(audio_path)})...", flush=True)
    try:
        result = subprocess.run(
            ["ffmpeg", "-y", "-i", audio_path, wav_path],
            capture_output=True,
            text=True,
            timeout=300,
        )
    except FileNotFoundError:
        os.unlink(wav_path)
        print(
            "ERROR: ffmpeg not found in PATH.\n"
            "Install FFmpeg from https://ffmpeg.org and ensure it is in PATH.",
            file=sys.stderr,
        )
        sys.exit(1)
    except subprocess.TimeoutExpired:
        os.unlink(wav_path)
        print("ERROR: ffmpeg conversion timed out.", file=sys.stderr)
        sys.exit(1)

    if result.returncode != 0:
        os.unlink(wav_path)
        print(
            f"ERROR: ffmpeg conversion failed (exit {result.returncode}).\n{result.stderr[-2000:]}",
            file=sys.stderr,
        )
        sys.exit(1)

    print(f"INFO: Conversion done -> {wav_path}", flush=True)
    return wav_path


def run(audio_path, output_path):
    try:
        from beat_this.inference import File2Beats
    except ImportError:
        print(
            "ERROR: beat_this is not installed.\n"
            "Install in this order:\n"
            "  1. pip install torch  (from https://pytorch.org -- pick your CUDA version)\n"
            "  2. pip install tqdm einops soxr rotary-embedding-torch\n"
            "  3. pip install https://github.com/CPJKU/beat_this/archive/main.zip",
            file=sys.stderr,
        )
        sys.exit(1)

    if not os.path.isfile(audio_path):
        print(f"ERROR: Audio file not found: {audio_path}", file=sys.stderr)
        sys.exit(1)

    # Convert non-WAV formats to a temporary WAV file.
    # torchaudio's bundled soundfile backend on Windows handles WAV natively;
    # other formats need FFmpeg DLLs which the static winget build does not provide.
    # Using ffmpeg.exe via subprocess avoids that dependency entirely.
    temp_wav = None
    infer_path = audio_path
    if not _is_wav(audio_path):
        temp_wav = _convert_to_wav(audio_path)
        infer_path = temp_wav

    # Auto-detect device: prefer CUDA (GPU), fall back to CPU
    try:
        import torch
        device = "cuda" if torch.cuda.is_available() else "cpu"
    except ImportError:
        device = "cpu"
    print(f"INFO: device={device}", flush=True)
    print("INFO: Loading model (first run downloads ~78 MB weights -- please wait)...", flush=True)

    try:
        f2b = File2Beats(checkpoint_path="final0", device=device, dbn=False)
        beats, downbeats = f2b(infer_path)
    except Exception as e:
        print(f"ERROR: Beat This! inference failed: {e}", file=sys.stderr)
        sys.exit(1)
    finally:
        if temp_wav and os.path.exists(temp_wav):
            os.unlink(temp_wav)

    # beats     = numpy array of all beat times in seconds
    # downbeats = numpy array of downbeat times in seconds (a strict subset of beats)
    #
    # Mark each beat as downbeat using millisecond-rounded set membership.
    # Rounding to 3dp (1ms) is reliable because both arrays come from the same algorithm.
    db_set = set(round(float(x), 3) for x in downbeats)

    try:
        with open(output_path, "w", newline="", encoding="utf-8") as f:
            writer = csv.writer(f)
            writer.writerow(["beat_time", "is_downbeat"])
            for b in beats:
                t = float(b)
                is_db = 1 if round(t, 3) in db_set else 0
                writer.writerow([f"{t:.6f}", is_db])
    except Exception as e:
        print(f"ERROR: Could not write CSV: {e}", file=sys.stderr)
        sys.exit(1)

    print(f"OK: {len(beats)} beats ({len(downbeats)} downbeats) written to {output_path}", flush=True)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python beat_this_helper.py <audio_file> <output_csv>")
        sys.exit(1)
    run(sys.argv[1], sys.argv[2])
