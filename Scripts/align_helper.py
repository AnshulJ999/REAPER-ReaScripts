# @noindex
#!/usr/bin/env python3
"""
align_helper.py
Finds the time offset between two audio files using MFCC cross-correlation.

Author: Anshul
Uses the BBC audio-offset-finder library.

Usage:
    python align_helper.py <ref_file> <target_file> <ref_start> <target_start> <max_duration>

Arguments:
    ref_file      - path to reference audio file (any format ffmpeg supports)
    target_file   - path to target audio file
    ref_start     - seconds to skip from start of ref file (SOFFS from REAPER)
    target_start  - seconds to skip from start of target file (SOFFS from REAPER)
    max_duration  - max seconds of audio to analyze (default 120)

Output (stdout):
    OFFSET:<float>   - offset in seconds (positive = target starts later than reference)
    SCORE:<float>    - standard score (>10 = high confidence, <5 = manual check needed)

Installation:
    pip install audio-offset-finder
    FFmpeg must be installed and in PATH.
"""

import sys
import os
import site
import subprocess
import tempfile
import struct

# Force UTF-8 for stdout so Windows cp1252 doesn't crash on YouTube/Japanese filenames
if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8')

# When launched from REAPER via ExecProcess, user site-packages may not be
# in sys.path. Add them explicitly so installed packages are found.
try:
    user_site = site.getusersitepackages()
    if user_site not in sys.path:
        sys.path.insert(0, user_site)
except Exception:
    pass

# Check dependency before importing
try:
    from audio_offset_finder.audio_offset_finder import find_offset_between_files
except ImportError:
    print("ERROR:audio-offset-finder not installed. Run: pip install audio-offset-finder", flush=True)
    sys.exit(1)



def get_gapless_compensation(filepath, mp3_comp=True, m4a_comp=False):
    """Detect encoder delay compensation needed for the given file.

    Different formats store gapless metadata differently, and FFmpeg
    doesn't always honour it.  REAPER's native decoders do.  This
    function detects the discrepancy and returns a skip value so the
    proxy WAV extracted by FFmpeg starts at the same point as REAPER.

    Args:
        filepath: Path to the audio file.
        mp3_comp: Enable MP3 gapless compensation (Xing/LAME check).
        m4a_comp: Enable M4A gapless compensation (edit list check).

    Returns (compensation_seconds, info_string) or (0.0, None).
    """
    ext = os.path.splitext(filepath)[1].lower()

    if ext == '.mp3' and mp3_comp:
        return _mp3_compensation(filepath)
    elif ext in ('.m4a', '.aac', '.m4b') and m4a_comp:
        return _m4a_compensation(filepath)
    else:
        return 0.0, None


def _mp3_compensation(filepath):
    """Check MP3 for Xing/LAME header.  If missing, return 1152-sample default.

    Handles arbitrarily large ID3v2 tags (album art) by seeking past them
    rather than reading a fixed buffer.
    """
    try:
        with open(filepath, "rb") as f:
            # Check for ID3v2 tag and seek past it
            id3_header = f.read(10)
            if len(id3_header) < 10:
                return 0.0, None

            if id3_header[:3] == b"ID3":
                # Synchsafe integer: 4 x 7-bit values
                id3_size = ((id3_header[6] << 21) | (id3_header[7] << 14) |
                            (id3_header[8] << 7) | id3_header[9])
                f.seek(10 + id3_size)
            else:
                f.seek(0)

            # Read 4KB from after the ID3 tag - contains the MPEG frames
            data = f.read(4096)
    except IOError:
        return 0.0, None

    if len(data) < 4:
        return 0.0, None

    # Find first MPEG frame sync (0xFF followed by 0xE0+ in high bits)
    frame_start = None
    for i in range(len(data) - 4):
        if data[i] == 0xFF and (data[i + 1] & 0xE0) == 0xE0:
            frame_start = i
            break

    if frame_start is None:
        # Genuinely can't find MPEG frame - apply default compensation
        return 1152 / 44100, "MP3 default (no MPEG frame found)"

    # Parse MPEG header for sample rate
    header_int = struct.unpack(">I", data[frame_start:frame_start + 4])[0]
    mpeg_version = (header_int >> 19) & 3   # 0=2.5, 2=2, 3=1
    channel_mode = (header_int >> 6) & 3    # 0=stereo, 1=joint, 2=dual, 3=mono
    sr_idx = (header_int >> 10) & 3

    sr_table = {
        3: {0: 44100, 1: 48000, 2: 32000},   # MPEG1
        2: {0: 22050, 1: 24000, 2: 16000},   # MPEG2
        0: {0: 11025, 1: 12000, 2: 8000},    # MPEG2.5
    }
    sample_rate = sr_table.get(mpeg_version, {}).get(sr_idx, 44100)

    # Side info size determines where Xing/Info tag sits
    if mpeg_version == 3:  # MPEG1
        side_info_size = 17 if channel_mode == 3 else 32
    else:
        side_info_size = 9 if channel_mode == 3 else 17

    xing_offset = frame_start + 4 + side_info_size
    xing_tag = data[xing_offset:xing_offset + 4]

    if xing_tag in (b"Xing", b"Info"):
        # File HAS a Xing/LAME header - FFmpeg reads this and internally
        # handles the encoder delay.  No additional compensation needed.
        return 0.0, None

    # No Xing/LAME header - FFmpeg doesn't know about encoder delay.
    # Apply standard 1152-sample compensation (one full MPEG-1 frame =
    # 576 encoder delay + 576 decoder delay = 26.12ms at 44.1kHz).
    compensation = 1152 / sample_rate
    return compensation, f"MP3 1152/{sample_rate}Hz = {compensation * 1000:.2f}ms"


def _m4a_compensation(filepath):
    """Check M4A/MP4 for an edit list declaring AAC encoder priming.

    The MP4 container stores gapless info in an edts/elst atom.  REAPER
    reads this and skips the priming samples.  FFmpeg often ignores it
    (reports start_time=0).  If media_time > 0 in the edit list, we add
    that many samples as compensation.

    MP4 video files (YouTube, Bandicam, etc.) typically have NO edit list,
    so this returns 0 for them - safe to call on any MP4/M4A/MOV file.
    """
    try:
        with open(filepath, "rb") as f:
            data = f.read(128 * 1024)  # First 128KB covers container atoms
    except IOError:
        return 0.0, None

    # Find edts atom
    edts_pos = data.find(b"edts")
    if edts_pos < 0:
        return 0.0, None  # No edit list = no compensation needed

    # Find elst atom after edts
    elst_pos = data.find(b"elst", edts_pos)
    if elst_pos < 0:
        return 0.0, None

    try:
        version = data[elst_pos + 4]
        entry_count = struct.unpack(">I", data[elst_pos + 8:elst_pos + 12])[0]

        if entry_count < 1:
            return 0.0, None

        # Read media_time from first edit list entry
        if version == 0:
            media_time = struct.unpack(">i", data[elst_pos + 16:elst_pos + 20])[0]
        else:  # version 1: 8-byte fields
            media_time = struct.unpack(">q", data[elst_pos + 20:elst_pos + 28])[0]

        if media_time <= 0:
            return 0.0, None  # No priming skip or empty edit

        # Get timescale from the mdhd atom in the same track
        timescale = _find_audio_timescale(data, edts_pos)

        compensation = media_time / timescale
        return compensation, f"M4A edts {media_time}/{timescale}Hz = {compensation * 1000:.2f}ms"

    except (struct.error, IndexError):
        return 0.0, None


def _find_audio_timescale(data, edts_pos):
    """Find the mdhd timescale for the track containing the edit list.

    In an MP4 file, edts and mdia/mdhd are siblings under the same trak.
    The mdhd closest BEFORE the edts position belongs to the same track.
    """
    search_start = max(0, edts_pos - 16384)
    mdhd_pos = -1
    pos = search_start
    while True:
        p = data.find(b"mdhd", pos, edts_pos)
        if p < 0:
            break
        mdhd_pos = p  # Keep the last (closest to edts) match
        pos = p + 4

    if mdhd_pos >= 0:
        version = data[mdhd_pos + 4]
        if version == 0:
            return struct.unpack(">I", data[mdhd_pos + 16:mdhd_pos + 20])[0]
        else:
            return struct.unpack(">I", data[mdhd_pos + 24:mdhd_pos + 28])[0]

    return 44100  # Fallback if mdhd not found


def extract_segment(input_path, start_sec, duration_sec, sample_rate=16000,
                    mp3_comp=True, m4a_comp=False):
    """Extract a segment of audio using ffmpeg, returning path to temp WAV.

    Caller must delete the temp file.

    NOTE: -ss is placed AFTER -i (output-level seeking) so FFmpeg fully
    decodes the audio stream from byte 0.  This ensures the MP3 decoder
    processes its warmup frame naturally, matching how REAPER handles
    encoder delay / gapless playback.  The speed cost is negligible
    because MAX_ANALYZE_DURATION caps the decode length.
    """
    tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
    tmp.close()
    wav_path = tmp.name

    # Compensate for encoder delay (MP3 without Xing, M4A with edit list)
    comp_sec, comp_info = get_gapless_compensation(input_path, mp3_comp, m4a_comp)
    effective_start = start_sec + comp_sec
    if comp_info:
        print(f"INFO: Gapless compensation: +{comp_sec * 1000:.2f}ms ({comp_info})", flush=True)

    cmd = [
        "ffmpeg", "-y",
        "-i", input_path,
        "-ss", f"{effective_start:.6f}",
        "-t", f"{duration_sec:.6f}",
        "-vn",
        "-ac", "1",
        "-ar", str(sample_rate),
        "-sample_fmt", "s16",
        wav_path,
    ]

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    except FileNotFoundError:
        os.unlink(wav_path)
        print("ERROR:ffmpeg not found in PATH. Install FFmpeg and ensure it is in PATH.", flush=True)
        sys.exit(1)
    except subprocess.TimeoutExpired:
        os.unlink(wav_path)
        print("ERROR:ffmpeg timed out during audio extraction (>120s).", flush=True)
        sys.exit(1)

    if result.returncode != 0:
        os.unlink(wav_path)
        stderr_tail = result.stderr[-500:] if result.stderr else "(no stderr)"
        print(f"ERROR:ffmpeg extraction failed (exit {result.returncode}): {stderr_tail}", flush=True)
        sys.exit(1)

    if not os.path.isfile(wav_path) or os.path.getsize(wav_path) < 100:
        if os.path.isfile(wav_path):
            os.unlink(wav_path)
        print("ERROR:ffmpeg produced empty or missing output file.", flush=True)
        sys.exit(1)

    return wav_path


def extract_mixed(target_paths, target_starts, duration_sec, sample_rate=16000,
                  mp3_comp=True, m4a_comp=False):
    """Extract and mix multiple audio segments using ffmpeg amix.

    Uses atrim filter instead of per-input -ss to achieve output-level
    decoding for each input.  This ensures MP3 encoder delay is handled
    correctly (same rationale as extract_segment).
    """
    tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
    tmp.close()
    wav_path = tmp.name

    # Build inputs without -ss (let FFmpeg decode from byte 0)
    inputs_args = []
    for path in target_paths:
        inputs_args.extend(["-i", path])

    n_inputs = len(target_paths)

    # Use atrim filter per-input to seek after full decode,
    # then asetpts to reset timestamps for amix compatibility.
    filter_parts = []
    for i, (path, start) in enumerate(zip(target_paths, target_starts)):
        # Compensate for encoder delay (MP3 without Xing, M4A with edit list)
        comp_sec, comp_info = get_gapless_compensation(path, mp3_comp, m4a_comp)
        effective_start = start + comp_sec
        if comp_info and i == 0:  # Log once (all stems from same source)
            print(f"INFO: Gapless compensation: +{comp_sec * 1000:.2f}ms ({comp_info})", flush=True)

        if effective_start > 0.0001:
            filter_parts.append(
                f"[{i}:a]atrim=start={effective_start:.6f},asetpts=PTS-STARTPTS[a{i}]"
            )
        else:
            filter_parts.append(f"[{i}:a]asetpts=PTS-STARTPTS[a{i}]")

    mix_inputs = "".join(f"[a{i}]" for i in range(n_inputs))
    filter_parts.append(
        f"{mix_inputs}amix=inputs={n_inputs}:duration=longest:dropout_transition=0"
    )
    filter_arg = ";".join(filter_parts)

    cmd = ["ffmpeg", "-y"] + inputs_args + [
        "-filter_complex", filter_arg,
        "-t", f"{duration_sec:.6f}",
        "-vn", "-ac", "1", "-ar", str(sample_rate), "-sample_fmt", "s16",
        wav_path
    ]

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    except FileNotFoundError:
        os.unlink(wav_path)
        print("ERROR:ffmpeg not found in PATH. Install FFmpeg and ensure it is in PATH.", flush=True)
        sys.exit(1)
    except subprocess.TimeoutExpired:
        os.unlink(wav_path)
        print("ERROR:ffmpeg timed out during mixed extraction (>120s).", flush=True)
        sys.exit(1)

    if result.returncode != 0:
        os.unlink(wav_path)
        stderr_tail = result.stderr[-500:] if result.stderr else "(no stderr)"
        print(f"ERROR:ffmpeg mix extraction failed (exit {result.returncode}): {stderr_tail}", flush=True)
        sys.exit(1)

    if not os.path.isfile(wav_path) or os.path.getsize(wav_path) < 100:
        if os.path.isfile(wav_path):
            os.unlink(wav_path)
        print("ERROR:ffmpeg mix produced empty or missing output file.", flush=True)
        sys.exit(1)

    return wav_path


def main():
    import argparse
    parser = argparse.ArgumentParser(description="Finds time offset between reference audio and (mixed) target audio items.")
    parser.add_argument("--ref", required=True, help="Path to reference audio file")
    parser.add_argument("--ref-start", type=float, required=True, help="Seconds to skip from start of ref file")
    parser.add_argument("--target", action="append", required=True, help="Path to target audio file(s)")
    parser.add_argument("--target-start", type=float, action="append", required=True, help="Seconds to skip from start of target file(s)")
    parser.add_argument("--max-dur", type=float, default=120.0, help="Max seconds of audio to analyze")
    parser.add_argument("--sample-rate", type=int, default=16000, help="Analysis sample rate in Hz (default: 16000)")
    parser.add_argument("--hop-length", type=int, default=128, help="MFCC hop length in samples (default: 128)")
    parser.add_argument("--mp3-comp", action="store_true", default=False, help="Enable MP3 gapless compensation")
    parser.add_argument("--m4a-comp", action="store_true", default=False, help="Enable M4A gapless compensation")

    # Fallback to old positional args just in case
    if len(sys.argv) >= 5 and not sys.argv[1].startswith("--"):
        ref_file = sys.argv[1]
        target_files = [sys.argv[2]]
        ref_start = float(sys.argv[3])
        target_starts = [float(sys.argv[4])]
        max_duration = float(sys.argv[5]) if len(sys.argv) > 5 else 120.0
        sample_rate = 16000
        hop_length = 128
        mp3_comp = True
        m4a_comp = False
    else:
        args = parser.parse_args()
        ref_file = args.ref
        ref_start = args.ref_start
        target_files = args.target
        target_starts = args.target_start
        max_duration = args.max_dur
        sample_rate = args.sample_rate
        hop_length = args.hop_length
        mp3_comp = args.mp3_comp
        m4a_comp = args.m4a_comp

        if len(target_files) != len(target_starts):
            print("ERROR: Number of --target arguments must match --target-start arguments.", flush=True)
            sys.exit(1)

    # Validate input files
    if not os.path.isfile(ref_file):
        print(f"ERROR:Reference file not found: {ref_file}", flush=True)
        sys.exit(1)
    
    for tf in target_files:
        if not os.path.isfile(tf):
            print(f"ERROR:Target file not found: {tf}", flush=True)
            sys.exit(1)

    print(f"INFO: Reference: {os.path.basename(ref_file)} (start={ref_start:.3f}s)", flush=True)
    if len(target_files) == 1:
        print(f"INFO: Target: {os.path.basename(target_files[0])} (start={target_starts[0]:.3f}s)", flush=True)
    else:
        print(f"INFO: Targets: {len(target_files)} files mixed together", flush=True)
    
    print(f"INFO: Analyzing up to {max_duration:.0f}s of audio...", flush=True)
    print(f"INFO: Analysis params: fs={sample_rate}Hz, hop_length={hop_length} samples (resolution={hop_length/sample_rate*1000:.2f}ms)", flush=True)

    # Extract segments starting from SOFFS
    ref_wav = extract_segment(ref_file, ref_start, max_duration, sample_rate, mp3_comp, m4a_comp)
    
    if len(target_files) == 1:
        target_wav = extract_segment(target_files[0], target_starts[0], max_duration, sample_rate, mp3_comp, m4a_comp)
    else:
        target_wav = extract_mixed(target_files, target_starts, max_duration, sample_rate, mp3_comp, m4a_comp)

    try:
        # Run BBC offset finder - fs must match extraction sample rate,
        # hop_length controls resolution (step_size = hop_length / fs)
        results = find_offset_between_files(ref_wav, target_wav, fs=sample_rate, hop_length=hop_length)

        offset = results["time_offset"]
        score = results["standard_score"]

        print(f"OFFSET:{offset:.6f}", flush=True)
        print(f"SCORE:{score:.4f}", flush=True)
    except Exception as e:
        print(f"ERROR:Offset detection failed: {e}", flush=True)
        sys.exit(1)
    finally:
        # Clean up temp files
        for f in (ref_wav, target_wav):
            try:
                os.unlink(f)
            except OSError:
                pass


if __name__ == "__main__":
    main()
