# @noindex
#!/usr/bin/env python3
"""
beat_net_helper.py
Runs BeatNet (Heydari et al., ISMIR 2021) on an audio file and outputs
beat/downbeat/meter data as CSV.

Author: Anshul

Usage:
    python beat_net_helper.py <audio_file> <output_csv> [options]

    Options (positional, after csv path):
        --model <1|2|3>     Pre-trained CRNN model (default: 1)
                              1 = GTZAN (general-purpose, recommended)
                              2 = Ballroom (dance/electronic)
                              3 = Rock Corpus (rock/metal)
        --mode <offline|online>
                            Inference mode (default: offline)
                              offline = non-causal DBN (best accuracy)
                              online  = causal particle filter (tempo continuity)
        --device <cpu|cuda> Force device (default: auto-detect)

Output CSV columns:
    beat_time        - beat position in seconds from start of audio
    beat_number      - beat position within bar (1 = downbeat, 2/3/4 = other beats)
    is_downbeat      - 1 if downbeat (beat_number == 1), 0 otherwise
    beats_per_bar    - inferred beats per bar at this position (from beat number cycling)

Installation:
    1. pip install torch              <- from https://pytorch.org (pick CUDA version)
    2. pip install librosa pyaudio
    3. pip install git+https://github.com/CPJKU/madmom
       (NOT 'pip install madmom' - PyPI version is broken on Python 3.12+)
    4. pip install BeatNet

Notes:
    - BeatNet uses librosa internally; it handles MP3/OGG/FLAC natively.
      No separate ffmpeg conversion needed (unlike Beat This!).
    - Three pre-trained models ship with BeatNet (GTZAN, Ballroom, Rock Corpus).
      Model 1 (GTZAN) is the most general-purpose.
    - GPU (CUDA) is used automatically when available.
    - The 'online' mode uses particle filtering which maintains tempo continuity
      and may resist half-time/double-time jumps better than the DBN offline mode.
    - The 'offline' mode uses madmom's DBNDownBeatTrackingProcessor with BeatNet's
      neural activations. It supports beats_per_bar=[2,3,4] (i.e. 2/4, 3/4, 4/4).
"""

import sys
import csv
import os
import site
import argparse
import time as _time

# ---------------------------------------------------------------------------
# Path fixup: REAPER's ExecProcess may not include user site-packages.
# ---------------------------------------------------------------------------
try:
    user_site = site.getusersitepackages()
    if user_site not in sys.path:
        sys.path.insert(0, user_site)
except Exception:
    pass


# ---------------------------------------------------------------------------
# pyaudio stub: BeatNet unconditionally imports pyaudio at module level for
# its 'stream' mode. We never use stream mode (no microphone), so if pyaudio
# is not installed we inject a harmless stub to let the import succeed.
# ---------------------------------------------------------------------------
try:
    import pyaudio  # noqa: F401
except ImportError:
    import types
    _pa = types.ModuleType("pyaudio")
    for _attr in ("PyAudio", "paFloat32", "paInt16", "paInt32",
                  "paContinue", "paComplete"):
        setattr(_pa, _attr, None)
    sys.modules["pyaudio"] = _pa


def _detect_device():
    """Auto-detect CUDA availability, fall back to CPU."""
    try:
        import torch
        if torch.cuda.is_available():
            return "cuda"
    except ImportError:
        pass
    return "cpu"


def _infer_beats_per_bar(beat_numbers):
    """Given the full array of beat_number values (1-indexed), infer the
    beats_per_bar for each beat by looking at local bar cycling.

    For each beat, we look at the downbeat boundaries around it and count
    the beats within that bar. This handles time-signature changes mid-song.
    """
    import numpy as np
    n = len(beat_numbers)
    bpb = np.zeros(n, dtype=int)

    # Find all downbeat indices
    db_indices = [i for i in range(n) if int(beat_numbers[i]) == 1]

    if len(db_indices) == 0:
        # No downbeats found; assume 4/4 throughout
        bpb[:] = 4
        return bpb

    # For beats before the first downbeat, use the first complete bar's size
    if len(db_indices) >= 2:
        first_bar_size = db_indices[1] - db_indices[0]
    else:
        first_bar_size = 4
    for i in range(db_indices[0]):
        bpb[i] = first_bar_size

    # For each complete bar between consecutive downbeats
    for j in range(len(db_indices) - 1):
        bar_size = db_indices[j + 1] - db_indices[j]
        for i in range(db_indices[j], db_indices[j + 1]):
            bpb[i] = bar_size

    # For beats from the last downbeat to the end, carry from previous bar
    if len(db_indices) >= 2:
        last_bar_size = db_indices[-1] - db_indices[-2]
    else:
        last_bar_size = first_bar_size
    for i in range(db_indices[-1], n):
        bpb[i] = last_bar_size

    return bpb


def run(audio_path, output_path, model=1, mode="offline", device=None):
    """Run BeatNet inference and write results to CSV.

    Parameters
    ----------
    audio_path : str
        Path to audio file (WAV, MP3, OGG, FLAC - librosa handles all).
    output_path : str
        Path to write output CSV.
    model : int
        Pre-trained model number (1=GTZAN, 2=Ballroom, 3=RockCorpus).
    mode : str
        'offline' (DBN, non-causal, best accuracy) or
        'online' (PF, causal, tempo continuity).
    device : str or None
        'cpu', 'cuda', or None for auto-detect.
    """
    import numpy as np

    # Validate inputs
    if not os.path.isfile(audio_path):
        print(f"ERROR: Audio file not found: {audio_path}", file=sys.stderr)
        sys.exit(1)

    if model not in (1, 2, 3):
        print(f"ERROR: Model must be 1, 2, or 3. Got: {model}", file=sys.stderr)
        sys.exit(1)

    if mode not in ("offline", "online"):
        print(f"ERROR: Mode must be 'offline' or 'online'. Got: {mode}",
              file=sys.stderr)
        sys.exit(1)

    if device is None:
        device = _detect_device()

    # Map mode to inference model
    # offline -> DBN (non-causal, madmom DBN with BeatNet activations)
    # online  -> PF  (causal particle filter, tempo continuity)
    inference_model = "DBN" if mode == "offline" else "PF"

    print(f"INFO: model={model}  mode={mode}  inference={inference_model}  "
          f"device={device}", flush=True)

    # Import BeatNet
    try:
        from BeatNet.BeatNet import BeatNet
    except ImportError:
        print(
            "ERROR: BeatNet is not installed.\n"
            "Install in this order:\n"
            "  1. pip install torch  (from https://pytorch.org)\n"
            "  2. pip install librosa pyaudio\n"
            "  3. pip install git+https://github.com/CPJKU/madmom\n"
            "  4. pip install BeatNet",
            file=sys.stderr,
        )
        sys.exit(1)

    # Run inference
    print(f"INFO: Loading BeatNet model {model} and processing audio...",
          flush=True)
    t0 = _time.perf_counter()

    try:
        estimator = BeatNet(
            model,
            mode=mode,
            inference_model=inference_model,
            plot=[],      # No plotting
            thread=False,  # Run in main thread
            device=device,
        )
        output = estimator.process(audio_path)
    except Exception as e:
        print(f"ERROR: BeatNet inference failed: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc(file=sys.stderr)
        sys.exit(1)

    elapsed = _time.perf_counter() - t0

    if output is None or len(output) == 0:
        print("ERROR: BeatNet returned no beats.", file=sys.stderr)
        sys.exit(1)

    # output shape: (num_beats, 2)
    #   column 0: beat time in seconds
    #   column 1: beat number within bar (1 = downbeat)
    times = output[:, 0]
    beat_numbers = output[:, 1].astype(int)

    total_beats = len(times)
    downbeats = int((beat_numbers == 1).sum())

    # Infer beats_per_bar for each beat from the cycling pattern
    bpb = _infer_beats_per_bar(beat_numbers)

    # Compute summary statistics
    if total_beats > 1:
        intervals = np.diff(times)
        valid = (intervals > 0.10) & (intervals < 3.0)
        if valid.sum() > 0:
            median_interval = float(np.median(intervals[valid]))
            median_bpm = 60.0 / median_interval
        else:
            median_bpm = 0.0
    else:
        median_bpm = 0.0

    unique_beats = sorted(set(beat_numbers))
    song_length = float(times[-1]) if total_beats > 0 else 0.0

    print(f"INFO: inference completed in {elapsed:.2f}s", flush=True)
    print(f"INFO: {total_beats} beats, {downbeats} downbeats, "
          f"median BPM={median_bpm:.1f}, "
          f"beat_nums={unique_beats}, "
          f"length={song_length:.1f}s", flush=True)

    # Write CSV
    try:
        with open(output_path, "w", newline="", encoding="utf-8") as f:
            writer = csv.writer(f)
            writer.writerow(["beat_time", "beat_number", "is_downbeat",
                             "beats_per_bar"])
            for i in range(total_beats):
                t = float(times[i])
                bn = int(beat_numbers[i])
                is_db = 1 if bn == 1 else 0
                writer.writerow([f"{t:.6f}", bn, is_db, int(bpb[i])])
    except Exception as e:
        print(f"ERROR: Could not write CSV: {e}", file=sys.stderr)
        sys.exit(1)

    print(f"OK: {total_beats} beats ({downbeats} downbeats) written to "
          f"{output_path}", flush=True)


def main():
    parser = argparse.ArgumentParser(
        description="BeatNet helper - beat/downbeat/meter tracking for REAPER",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Models:
  1  GTZAN (general-purpose, recommended default)
  2  Ballroom (dance/electronic music)
  3  Rock Corpus (rock and metal)

Modes:
  offline  Non-causal DBN inference. Best accuracy for pre-recorded audio.
           Supports 2/4, 3/4, and 4/4 time signatures.
  online   Causal particle filter. Maintains tempo continuity, may resist
           half-time/double-time jumps. Supports arbitrary meters.

Examples:
  python beat_net_helper.py song.mp3 output.csv
  python beat_net_helper.py drums.wav output.csv --model 3 --mode online
  python beat_net_helper.py click.mp3 output.csv --device cuda
        """,
    )
    parser.add_argument("audio_file", help="Path to audio file")
    parser.add_argument("output_csv", help="Path to write output CSV")
    parser.add_argument("--model", type=int, default=1, choices=[1, 2, 3],
                        help="Pre-trained model (default: 1)")
    parser.add_argument("--mode", default="offline",
                        choices=["offline", "online"],
                        help="Inference mode (default: offline)")
    parser.add_argument("--device", default=None,
                        help="Device: cpu, cuda, or auto (default: auto)")

    args = parser.parse_args()
    run(args.audio_file, args.output_csv,
        model=args.model, mode=args.mode, device=args.device)


if __name__ == "__main__":
    main()
