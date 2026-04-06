# @noindex
#!/usr/bin/env python3
"""
audio_mix_helper.py
Mixes multiple audio files into a single mono float32 WAV for beat detection.

Author: Anshul

Uses ffmpeg amix filter directly (no numpy/soundfile/soxr dependencies).
Reads MP3, FLAC, OGG, M4A, WAV or any format ffmpeg supports.

Outputs normalized mono float32 PCM WAV suitable for machine learning beat trackers.

Usage:
    python audio_mix_helper.py <output_wav> <input1> <input2> [input3 ...]

Arguments:
    output_wav  - path to output WAV file (float32 mono, any sample rate)
    input1, ... - input audio files (any format ffmpeg supports)

Requirements:
    FFmpeg in PATH (https://ffmpeg.org)
"""

import sys
import os
import subprocess


def mix_files(output_path, input_paths):
    n = len(input_paths)
    if n < 2:
        raise RuntimeError(f"Need at least 2 input files, got {n}")

    for path in input_paths:
        if not os.path.isfile(path):
            raise RuntimeError(f"File not found: {path}")

    # Build amix filter graph:
    #   [0:a][1:a][2:a]amix=inputs=3:duration=longest:normalize=1[out]
    # normalize=1 divides by number of inputs (equivalent to averaging),
    # preventing clipping when summing multiple signals.
    filter_inputs = "".join(f"[{i}:a]" for i in range(n))
    filter_str = (
        f"{filter_inputs}"
        f"amix=inputs={n}:duration=longest:normalize=1"
        f"[out]"
    )

    cmd = ["ffmpeg", "-y"]
    for path in input_paths:
        cmd += ["-i", path]
    cmd += [
        "-filter_complex", filter_str,
        "-map", "[out]",
        "-ac", "1",            # downmix to mono
        "-c:a", "pcm_f32le",   # 32-bit float little-endian PCM (WAV)
        output_path,
    ]

    names = ", ".join(os.path.basename(p) for p in input_paths)
    print(f"INFO: Mixing {n} file(s) via ffmpeg amix: {names}", flush=True)

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    except FileNotFoundError:
        raise RuntimeError(
            "ffmpeg not found in PATH.\n"
            "Install FFmpeg from https://ffmpeg.org and ensure it is in PATH."
        )
    except subprocess.TimeoutExpired:
        raise RuntimeError("ffmpeg timed out during audio mixing (>300s)")

    if result.returncode != 0:
        raise RuntimeError(
            f"ffmpeg mix failed (exit {result.returncode}):\n"
            f"{result.stderr[-2000:]}"
        )

    if not os.path.isfile(output_path):
        raise RuntimeError("ffmpeg reported success but output file was not created")

    size_kb = os.path.getsize(output_path) // 1024
    print(f"OK: Mixed {n} file(s) -> {output_path} ({size_kb} KB)", flush=True)


if __name__ == "__main__":
    if len(sys.argv) < 4:
        print("Usage: python audio_mix_helper.py <output_wav> <input1> <input2> [input3 ...]")
        sys.exit(1)
    try:
        mix_files(sys.argv[1], sys.argv[2:])
    except Exception as e:
        print(f"ERROR: {e}", flush=True)
        sys.exit(1)
