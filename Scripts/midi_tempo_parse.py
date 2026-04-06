# @noindex
#!/usr/bin/env python3
"""
midi_tempo_parse.py
Parses a MIDI file and outputs measure boundary times as CSV.

Author: Anshul

Usage:
    python midi_tempo_parse.py <midi_file> <output_csv>

Output CSV columns:
    measure       - measure number (1-indexed)
    time_seconds  - absolute start time of the measure in seconds
    qn_length     - length of the measure in quarter notes (derived from time signature)

Requirements:
    pip install mido
"""

import sys
import csv
import os
import site

# When launched from REAPER via ExecProcess, user site-packages are often not
# included in sys.path. Add them explicitly so user-installed packages (mido etc.)
# are found regardless of how Python was invoked.
try:
    user_site = site.getusersitepackages()
    if user_site not in sys.path:
        sys.path.insert(0, user_site)
except Exception:
    pass

def parse_midi(midi_path, output_path):
    try:
        import mido
    except ImportError:
        print("ERROR: mido not installed. Run: pip install mido", file=sys.stderr)
        sys.exit(1)

    if not os.path.isfile(midi_path):
        print(f"ERROR: MIDI file not found: {midi_path}", file=sys.stderr)
        sys.exit(1)

    try:
        mid = mido.MidiFile(midi_path)
    except Exception as e:
        print(f"ERROR: Could not open MIDI file: {e}", file=sys.stderr)
        sys.exit(1)

    ppq = mid.ticks_per_beat
    if ppq <= 0:
        print("ERROR: Invalid PPQ in MIDI file.", file=sys.stderr)
        sys.exit(1)

    # ----------------------------------------------------------------
    # Parse tempo track
    # Type 0: single track, Type 1: track 0 is conductor, Type 2: each track independent
    # We always read track 0 for tempo/timesig events.
    # ----------------------------------------------------------------
    tempo_events   = []  # list of (abs_tick, microseconds_per_beat)
    timesig_events = []  # list of (abs_tick, numerator, denominator)

    abs_tick = 0
    for msg in mid.tracks[0]:
        abs_tick += msg.time
        if msg.type == 'set_tempo':
            tempo_events.append((abs_tick, msg.tempo))
        elif msg.type == 'time_signature':
            timesig_events.append((abs_tick, msg.numerator, msg.denominator))

    # Ensure defaults at tick 0
    if not tempo_events or tempo_events[0][0] != 0:
        tempo_events.insert(0, (0, 500000))   # 120 BPM default
    if not timesig_events or timesig_events[0][0] != 0:
        timesig_events.insert(0, (0, 4, 4))   # 4/4 default

    # ----------------------------------------------------------------
    # Find total ticks across all tracks
    # ----------------------------------------------------------------
    max_tick = 0
    for track in mid.tracks:
        tick = 0
        for msg in track:
            tick += msg.time
        max_tick = max(max_tick, tick)

    # ----------------------------------------------------------------
    # tick_to_seconds: convert absolute tick to wall-clock time in seconds
    # Correctly handles multiple tempo events.
    # ----------------------------------------------------------------
    def tick_to_seconds(target_tick):
        time_sec  = 0.0
        prev_tick  = 0
        prev_tempo = tempo_events[0][1]

        for ev_tick, ev_tempo in tempo_events[1:]:
            if ev_tick >= target_tick:
                break
            time_sec  += (ev_tick - prev_tick) * prev_tempo / (ppq * 1_000_000)
            prev_tick  = ev_tick
            prev_tempo = ev_tempo

        time_sec += (target_tick - prev_tick) * prev_tempo / (ppq * 1_000_000)
        return time_sec

    # ----------------------------------------------------------------
    # Generate measure boundary ticks by dynamically tracking time-sig events.
    # If a new time-sig event occurs before the expected end of the measure,
    # it forces an early barline (handles anacrusis / pickup measures perfectly).
    # ----------------------------------------------------------------
    measure_boundaries = []   # list of (tick, measure_num, qn_length)
    current_tick = 0
    measure_num  = 1
    
    time_sig_queue = list(timesig_events)
    active_num   = 4
    active_denom = 4

    while current_tick <= max_tick:
        # Update active time signature if we reached a new event exactly on this tick
        while time_sig_queue and time_sig_queue[0][0] <= current_tick:
            ev = time_sig_queue.pop(0)
            active_num   = ev[1]
            active_denom = ev[2]

        # Calculate theoretical full measure length
        ticks_per_measure = round(ppq * active_num * 4 / active_denom)
        if ticks_per_measure <= 0:
            ticks_per_measure = ppq * 4
        
        expected_next_tick = current_tick + ticks_per_measure
        actual_next_tick   = expected_next_tick
        
        # Intercept jump if a time sig event forces an early barline
        if time_sig_queue and time_sig_queue[0][0] < expected_next_tick:
            actual_next_tick = time_sig_queue[0][0]
            
        measure_ticks = actual_next_tick - current_tick
        qn_length = measure_ticks / ppq

        measure_boundaries.append((current_tick, measure_num, qn_length))
        
        current_tick = actual_next_tick
        measure_num += 1

    if not measure_boundaries:
        print("ERROR: No measure boundaries could be generated.", file=sys.stderr)
        sys.exit(1)

    # ----------------------------------------------------------------
    # Write CSV
    # ----------------------------------------------------------------
    try:
        with open(output_path, 'w', newline='', encoding='utf-8') as f:
            writer = csv.writer(f)
            writer.writerow(['measure', 'time_seconds', 'qn_length'])
            for tick, meas, qn_len in measure_boundaries:
                writer.writerow([meas, f'{tick_to_seconds(tick):.6f}', f'{qn_len:.6f}'])
    except Exception as e:
        print(f"ERROR: Could not write output CSV: {e}", file=sys.stderr)
        sys.exit(1)

    print(f"OK: {len(measure_boundaries)} measures written to {output_path}")


if __name__ == '__main__':
    if len(sys.argv) < 3:
        print("Usage: python midi_tempo_parse.py <midi_file> <output_csv>")
        sys.exit(1)
    parse_midi(sys.argv[1], sys.argv[2])
