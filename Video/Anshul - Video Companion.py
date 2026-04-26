#!/usr/bin/env python3
# REAPER Video Companion — Phase 6 IPC Script
# Version: 1.3.0
#
# v1.3.0: Single-instance guard (ExtState), video item cache (GetProjectStateChangeCount),
#         multi-video support (all_videos array in UDP payload for tablet UI selector).
#
# v1.2.0: Added file logging (companion.log), 30s rolling stats, state transition logging.
#         Added try/except safety net in _tick() to prevent defer loop death.
#
# v1.1.0: Fixed D_PLAYRATE queried on item instead of take (caused rate=0.0 and frozen video).
#         Added item-level mute, track-level mute, and solo awareness to active video detection.
#         Added effective_rate safety clamp (never zero).
#
# Runs INSIDE REAPER as a Python ReaScript.
# Polls REAPER's playback state at 20 Hz and sends JSON state via UDP to the
# Python video streamer (port 9063), which uses it for Mode B direct-file sync.
#
# How to run:
#   REAPER → Actions → New/Load ReaScript → select this file → Run
#   Leave it running. It uses RPR_defer (cooperative scheduling) — zero REAPER impact.
#
# Requires: Python configured in REAPER preferences
#   Options → Preferences → Plug-Ins → ReaScript → Enable Python → set DLL path
#
# UDP payload schema (JSON):
#   pos       (float)  : current project position in seconds (latency-compensated)
#   state     (int)    : 0=stop, 1=play, 2=pause, 4=record
#   rate      (float)  : effective video playback rate = global_rate * segment_rate
#   src_time  (float|null) : source file timestamp in seconds, null if no video item
#   file      (str|null)   : absolute path to source video file, null if none

from reaper_python import *
import socket
import json
import time
import os

# ─── Configuration ─────────────────────────────────────────────────────────────
UDP_HOST      = "127.0.0.1"
UDP_PORT      = 9063
SYNCLYRICS_UDP_PORT = 9064      # Secondary port for SyncLyrics IPC
COMMAND_UDP_PORT    = 9065      # Incoming port for SyncLyrics control commands
PUSH_INTERVAL = 0.05  # seconds between pushes (20 Hz is more than enough for sync)
HEARTBEAT_INTERVAL = 1.0 # seconds before sending a duplicate packet to keep stream alive
LOG_STATS_INTERVAL = 30.0 # seconds between rolling stats log entries
LOG_ENABLED = True        # set False to disable file logging entirely

# Video file extensions to recognise when scanning items.
# Python server handles MIME types and browser compatibility.
VIDEO_EXTS = {".mp4", ".mov", ".avi", ".mkv", ".webm", ".m4v", ".ts", ".mts", ".m2ts"}

# ─── Single Instance Guard ────────────────────────────────────────────────────
_GUARD_SECTION = "VideoCompanion"
_GUARD_KEY     = "running"

# ─── UDP Socket ────────────────────────────────────────────────────────────────
# Non-blocking: sendto() never waits. If OS buffer is full it raises an exception
# which we swallow — a dropped datagram is fine, we only care about the latest state.
_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
_sock.setblocking(False)

# Command receiver socket
# Buffer any bind error until the file logger is up (module-level bind happens before _log_init).
_cmd_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
_cmd_bind_error = None  # Stores bind failure message for logging by _log_init
try:
    # Use REUSEADDR to prevent bind failures if the script was restarted quickly
    _cmd_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    _cmd_sock.bind((UDP_HOST, COMMAND_UDP_PORT))
except Exception as e:
    _cmd_bind_error = "Failed to bind command socket on {}:{} - {} (transport commands from SyncLyrics will NOT work)".format(
        UDP_HOST, COMMAND_UDP_PORT, e
    )
_cmd_sock.setblocking(False)

# ─── Runtime State ─────────────────────────────────────────────────────────────
_last_push    = 0.0  # RPR_time_precise() value of last UDP push
_last_payload = ""   # Last JSON string sent; skip send when nothing changed
_last_send_time = 0.0

# ─── Video Item Cache ─────────────────────────────────────────────────────────
# Rebuilt only when RPR_GetProjectStateChangeCount changes (item add/remove/move,
# take change, project switch, etc.). During continuous playback the counter is
# static, so the cache is locked in and API calls drop by ~90%.
_item_cache = []          # list of (item_ptr, take_ptr, fname, track_num)
_item_cache_state = -1    # last seen RPR_GetProjectStateChangeCount value
_item_cache_count = -1    # last seen item count in cache (for logging)

# ─── File Logger ──────────────────────────────────────────────────────────────
# Simple append-to-file logger. Overwrites on each script start for freshness.
# No Python logging module — keep it minimal inside REAPER's Python.
# __file__ is not available when running as REAPER ReaScript, so use fallback.
try:
    _script_dir = os.path.dirname(os.path.abspath(__file__))
except NameError:
    _script_dir = RPR_GetResourcePath()
_log_path = os.path.join(_script_dir, "companion.log")
_log_file = None

def _log_init():
    """Open log file (overwrite) and write startup header."""
    global _log_file
    if not LOG_ENABLED:
        return
    try:
        _log_file = open(_log_path, "w", buffering=1)  # line-buffered
        _log_file.write("=" * 60 + "\n")
        _log_file.write("REAPER Video Companion v1.2.0\n")
        _log_file.write("Started: {}\n".format(time.strftime("%Y-%m-%d %H:%M:%S")))
        _log_file.write("UDP target 1: {}:{} (Streamer)\n".format(UDP_HOST, UDP_PORT))
        _log_file.write("UDP target 2: {}:{} (SyncLyrics)\n".format(UDP_HOST, SYNCLYRICS_UDP_PORT))
        _log_file.write("UDP cmd rx  : {}:{}\n".format(UDP_HOST, COMMAND_UDP_PORT))
        _log_file.write("Push rate: {} Hz | Heartbeat: {}s | Stats interval: {}s\n".format(
            int(1.0 / PUSH_INTERVAL), HEARTBEAT_INTERVAL, LOG_STATS_INTERVAL))
        if _cmd_bind_error:
            _log_file.write("WARNING: {}\n".format(_cmd_bind_error))
        _log_file.write("=" * 60 + "\n")
    except Exception:
        _log_file = None

def _log(msg):
    """Append a timestamped line to the log file."""
    if _log_file:
        try:
            _log_file.write("[{}] {}\n".format(time.strftime("%H:%M:%S"), msg))
        except Exception:
            pass

def _log_close():
    """Flush and close the log file."""
    global _log_file
    if _log_file:
        try:
            _log_file.close()
        except Exception:
            pass
        _log_file = None

# ─── Stats Tracking ──────────────────────────────────────────────────────────
_stats_pushes = 0         # total UDP sends in this stats window
_stats_heartbeats = 0     # how many were heartbeat duplicates
_stats_errors = 0         # transient errors caught in _push_state
_stats_last_time = 0.0    # wall-clock time of last stats log
_prev_play_state = -1     # for detecting state transitions
_prev_file = None         # for detecting file changes


# ─── REAPER API Helpers ────────────────────────────────────────────────────────

def _build_video_item_cache():
    """Full project scan: return list of (item_ptr, take_ptr, fname, track_num)
    for every video item in the project. Called only when project structure changes."""
    cache = []
    active_proj = RPR_EnumProjects(-1, "", 512)[0]
    count = RPR_CountMediaItems(active_proj)
    for i in range(count):
        item = RPR_GetMediaItem(active_proj, i)

        take = RPR_GetActiveTake(item)
        if not take:
            continue

        src = RPR_GetMediaItemTake_Source(take)
        if not src:
            continue

        fname = RPR_GetMediaSourceFileName(src, "", 4096)[1].strip()
        if not fname:
            continue

        dot_idx = fname.rfind(".")
        ext = ("." + fname[dot_idx + 1:].lower()) if dot_idx >= 0 else ""
        if ext not in VIDEO_EXTS:
            continue

        track = RPR_GetMediaItemTrack(item)
        track_num = RPR_GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")
        cache.append((item, take, fname, track_num))

    return cache


def _refresh_cache_if_needed():
    """Check RPR_GetProjectStateChangeCount and rebuild cache if project changed.
    Returns immediately on cache hit (1 API call). Rebuilds on miss (~1ms)."""
    global _item_cache, _item_cache_state, _item_cache_count
    active_proj = RPR_EnumProjects(-1, "", 512)[0]
    state_count = RPR_GetProjectStateChangeCount(active_proj)
    if state_count != _item_cache_state:
        _item_cache = _build_video_item_cache()
        _item_cache_state = state_count
        new_count = len(_item_cache)
        if new_count != _item_cache_count:
            _log("Cache rebuilt: {} video item(s)".format(new_count))
            _item_cache_count = new_count


def _find_all_video_items(proj_pos):
    """Return list of all eligible video items at proj_pos, sorted by track number.

    Uses the cached video item list. Only checks dynamic properties per tick:
    bounds (D_POSITION, D_LENGTH), item mute (B_MUTE), track mute/solo.

    Returns list of (item, take, fname, track_num) sorted by track_num ascending.
    First element is the "active" item (lowest track = rendered on top by REAPER).
    """
    results = []

    for (item, take, fname, track_num) in _item_cache:
        # Bounds check (dynamic — item could be moved)
        ipos = RPR_GetMediaItemInfo_Value(item, "D_POSITION")
        ilen = RPR_GetMediaItemInfo_Value(item, "D_LENGTH")
        if proj_pos < ipos or proj_pos >= ipos + ilen:
            continue

        track = RPR_GetMediaItemTrack(item)
        if RPR_GetMediaTrackInfo_Value(track, "B_SHOWINTCP") == 0.0:
            continue  # ignore hidden tracks completely
            
        # Check mutes to separate active vs purely secondary selection
        is_muted = False
        if RPR_GetMediaItemInfo_Value(item, "B_MUTE") > 0.0:
            is_muted = True
        else:
            track_mute = RPR_GetMediaTrackInfo_Value(track, "B_MUTE")
            track_solo = RPR_GetMediaTrackInfo_Value(track, "I_SOLO")
            if track_mute > 0.0 and track_solo == 0.0:
                is_muted = True

        results.append((item, take, fname, track_num, is_muted))

    results.sort(key=lambda x: x[3])  # sort by track number (highest priority/rendered item first)

    # Deduplicate purely identical filenames so the UI doesn't bloat with chopped items.
    # MUTE-AWARE: Prioritize unmuted items over muted ones. If a video exists on a
    # muted track and an unmuted track, ensure the unmuted track survives deduplication.
    deduped_dict = {}
    for res in results:
        fname = res[2]
        is_muted = res[4]
        
        if fname not in deduped_dict:
            deduped_dict[fname] = res
        else:
            # Current entry is Muted, but new entry is Unmuted -> upgrade it!
            if deduped_dict[fname][4] == True and is_muted == False:
                deduped_dict[fname] = res

    # Restore the track priority sort order (highest priority/rendered item first)
    deduped = list(deduped_dict.values())
    deduped.sort(key=lambda x: x[3])
            
    return deduped


def _get_source_time(take, item, proj_pos):
    """Compute the source file timestamp (seconds) at the given project position.

    Handles all cases:
    1. Plain item (no stretch markers): linear mapping via D_PLAYRATE + D_STARTOFFS
    2. Item with stretch markers: piecewise linear mapping
       — stretch marker srcpos values are ABSOLUTE (already include D_STARTOFFS)
       — do NOT add D_STARTOFFS again in the stretch marker path

    Stretch markers produced by Fit Item To Tempo Map.lua use this absolute
    srcpos convention (confirmed from reading that script's source).
    """
    item_pos  = RPR_GetMediaItemInfo_Value(item, "D_POSITION")
    # D_PLAYRATE is a TAKE property, not an item property — must use GetMediaItemTakeInfo_Value
    item_rate = RPR_GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
    take_time = proj_pos - item_pos  # item-relative time (seconds from item start)

    sm_count = RPR_GetTakeNumStretchMarkers(take)

    # ── Case 1: no stretch markers ─────────────────────────────────────────────
    if sm_count == 0:
        startoffs = RPR_GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
        return take_time * item_rate + startoffs

    # ── Case 2: stretch markers present — piecewise linear ───────────────────
    # RPR_GetTakeStretchMarker returns tuple: (retval, take, idx, pos, srcpos)
    #   [3] = pos    : item-relative time at this marker
    #   [4] = srcpos : ABSOLUTE source file position at this marker
    #
    # O(n) loop: cache the previous marker to avoid re-fetching

    sm0 = RPR_GetTakeStretchMarker(take, 0, 0, 0)
    pos0, src0 = sm0[3], sm0[4]

    # Edge case: before the first marker — extrapolate backward from first segment
    if take_time <= pos0:
        if sm_count >= 2:
            sm1 = RPR_GetTakeStretchMarker(take, 1, 0, 0)
            pos1, src1 = sm1[3], sm1[4]
            seg_rate = (src1 - src0) / max(pos1 - pos0, 0.001)
            return src0 - (pos0 - take_time) * seg_rate
        return src0

    # Walk through segments, keeping a rolling window of (prev, curr)
    prev_pos = pos0
    prev_src = src0
    for i in range(1, sm_count):
        sm_i = RPR_GetTakeStretchMarker(take, i, 0, 0)
        curr_pos, curr_src = sm_i[3], sm_i[4]

        if take_time <= curr_pos:
            # take_time falls in segment [prev_pos, curr_pos]
            t = (take_time - prev_pos) / max(curr_pos - prev_pos, 0.001)
            return prev_src + t * (curr_src - prev_src)

        prev_pos, prev_src = curr_pos, curr_src

    # Past the last marker — extrapolate forward using last segment rate
    # prev_pos/prev_src now hold the last marker's values
    # We need the second-to-last marker to compute the last segment rate.
    # Fetch it fresh (only done once, outside the hot loop).
    pos_last, src_last = prev_pos, prev_src
    if sm_count >= 2:
        sm_prev_last = RPR_GetTakeStretchMarker(take, sm_count - 2, 0, 0)
        pos_penult, src_penult = sm_prev_last[3], sm_prev_last[4]
        seg_rate = (src_last - src_penult) / max(pos_last - pos_penult, 0.001)
        return src_last + (take_time - pos_last) * seg_rate
    return src_last


def _get_segment_rate(take, item, proj_pos):
    """Return the local source-to-project time ratio at this position.

    This is the value to multiply global_rate by to get video.playbackRate:
        video.playbackRate = global_rate * _get_segment_rate(...)

    For plain items (no stretch markers): returns D_PLAYRATE.
    For stretch-marked items: returns (src_delta / take_time_delta) for the
    active segment, which is the ratio of source seconds per project second.
    """
    item_pos  = RPR_GetMediaItemInfo_Value(item, "D_POSITION")
    # D_PLAYRATE is a TAKE property, not an item property — must use GetMediaItemTakeInfo_Value
    item_rate = RPR_GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
    take_time = proj_pos - item_pos

    sm_count = RPR_GetTakeNumStretchMarkers(take)
    if sm_count < 2:
        # 0 markers: plain item rate
        # 1 marker:  single point, can't compute a segment rate
        return item_rate

    # Walk segments and return the rate of the one containing take_time.
    # O(n) with one API call per iteration.
    # Also correctly handles take_time before the first marker (returns first segment rate).
    sm_prev = RPR_GetTakeStretchMarker(take, 0, 0, 0)
    prev_pos, prev_src = sm_prev[3], sm_prev[4]
    last_seg_rate = item_rate  # fallback if loop doesn't return

    for i in range(1, sm_count):
        sm_curr = RPR_GetTakeStretchMarker(take, i, 0, 0)
        curr_pos, curr_src = sm_curr[3], sm_curr[4]
        seg_rate = (curr_src - prev_src) / max(curr_pos - prev_pos, 0.001)

        # Return this segment's rate if take_time is within or before it.
        # Handles "before first marker" on i=1: take_time <= curr_pos is true.
        if take_time <= curr_pos:
            return seg_rate

        prev_pos, prev_src = curr_pos, curr_src
        last_seg_rate = seg_rate

    # Past the last marker: use the last segment rate
    return last_seg_rate


# ─── Main Push Function ────────────────────────────────────────────────────────

def _push_state():
    """Read current REAPER playback state and send as JSON via UDP.

    Deduplicates: if the state hasn't changed since the last push, does nothing,
    UNLESS 1 second has passed (heartbeat).
    Each call completes in well under 1ms (pure in-memory REAPER API reads +
    a non-blocking UDP send syscall).
    """
    global _last_payload, _last_send_time
    global _stats_pushes, _stats_heartbeats, _stats_errors, _stats_last_time
    global _prev_play_state, _prev_file

    # Refresh video item cache if project structure changed (1 API call on hit)
    _refresh_cache_if_needed()

    play_state  = RPR_GetPlayState()      # 0=stop 1=play 2=pause 4=record
    if play_state == 0 or play_state == 2:
        proj_pos = RPR_GetCursorPosition()
    else:
        proj_pos = RPR_GetPlayPosition()   # latency-compensated "what you hear"

    active_proj = RPR_EnumProjects(-1, "", 512)[0]
    global_rate = RPR_Master_GetPlayRate(active_proj)  # global playback rate (0 = current project)

    # Live tempo/time-signature at the current cursor position.
    # RPR_TimeMap2_timeSigAtTime returns (bpm, num, denom) — bpm is tempo at that point.
    try:
        _live_bpm, _live_ts_num, _live_ts_denom = RPR_TimeMap2_timeSigAtTime(active_proj, proj_pos)
        live_bpm = round(_live_bpm, 3) if _live_bpm and _live_bpm > 0 else None
        live_time_sig = "{}/{}".format(int(_live_ts_num), int(_live_ts_denom)) if _live_ts_num and _live_ts_denom else None
    except Exception:
        live_bpm = None
        live_time_sig = None

    # Project name — used by streamer JS for per-project video preference storage.
    # basename only (e.g. "MySong.rpp") — path is irrelevant and may vary by machine.
    proj_name = os.path.basename(RPR_GetProjectName(active_proj, "", 512)[1].strip())


    all_items = _find_all_video_items(proj_pos)

    # Build all_videos list for multi-video selector and compute their accurate times
    all_videos = []
    active_item_data = None
    
    for (v_item, v_take, v_fname, v_tnum, v_muted) in all_items:
        v_src = RPR_GetMediaItemTake_Source(v_take)
        v_source_len, _, _ = RPR_GetMediaSourceLength(v_src, 0)
        
        v_src_time = _get_source_time(v_take, v_item, proj_pos)
        if v_source_len > 0:
            v_src_time = v_src_time % v_source_len
            
        v_segment_rate = _get_segment_rate(v_take, v_item, proj_pos)
        v_eff_rate = global_rate * v_segment_rate
        if v_eff_rate <= 0.0:
            v_eff_rate = 1.0

        all_videos.append({
            "file": v_fname,
            "track": int(v_tnum),
            "name": os.path.basename(v_fname),
            "src_time": round(v_src_time, 4),
            "rate": round(v_eff_rate, 4),
            "muted": v_muted
        })

        if not v_muted and active_item_data is None:
            active_item_data = {
                "file": v_fname,
                "src_time": round(v_src_time, 4),
                "rate": round(v_eff_rate, 4)
            }

    if active_item_data or all_videos:
        payload = json.dumps({
            "pos":      round(proj_pos,       4),
            "state":    play_state,
            "rate":     active_item_data["rate"]     if active_item_data else round(global_rate, 4),
            "src_time": active_item_data["src_time"] if active_item_data else None,
            "file":     active_item_data["file"]     if active_item_data else None,
            "all_videos": all_videos,
            "project":  proj_name,
            "live_bpm": live_bpm,
            "live_time_sig": live_time_sig,
        })
    else:
        payload = json.dumps({
            "pos":      round(proj_pos,    4),
            "state":    play_state,
            "rate":     round(global_rate, 4),
            "src_time": None,
            "file":     None,
            "all_videos": [],
            "project":  proj_name,
            "live_bpm": live_bpm,
            "live_time_sig": live_time_sig,
        })


    # ── State transition logging (rare events, high diagnostic value) ──
    _state_names = {0: "Stopped", 1: "Playing", 2: "Paused", 4: "Recording", 5: "Play+Rec"}
    if play_state != _prev_play_state:
        old_name = _state_names.get(_prev_play_state, str(_prev_play_state))
        new_name = _state_names.get(play_state, str(play_state))
        _log("State: {} -> {}  pos={:.2f}".format(old_name, new_name, proj_pos))
        _prev_play_state = play_state

    # File change logging
    fname = active_item_data["file"] if active_item_data else None
    short_fname = os.path.basename(fname) if fname else None
    short_prev = os.path.basename(_prev_file) if _prev_file else None
    if short_fname != short_prev:
        _log("Video: {} -> {}".format(short_prev or "(none)", short_fname or "(none)"))
        _prev_file = fname

    # ── Deduplication with heartbeat ──
    now = time.time()
    is_heartbeat = (payload == _last_payload)
    if is_heartbeat and (now - _last_send_time) < HEARTBEAT_INTERVAL:
        return  # nothing changed and heartbeat not due, skip UDP send

    try:
        _sock.sendto(payload.encode("utf-8"), (UDP_HOST, UDP_PORT))
        _sock.sendto(payload.encode("utf-8"), (UDP_HOST, SYNCLYRICS_UDP_PORT))
    except Exception:
        _stats_errors += 1

    _last_payload = payload
    _last_send_time = now
    _stats_pushes += 1
    if is_heartbeat:
        _stats_heartbeats += 1

    # ── 30-second rolling stats ──
    if _stats_last_time == 0.0:
        _stats_last_time = now
    elif now - _stats_last_time >= LOG_STATS_INTERVAL:
        elapsed = now - _stats_last_time
        _log("Stats [{:.0f}s]: pushes={} heartbeats={} errors={} | state={} rate={} proj={} file={}".format(
            elapsed, _stats_pushes, _stats_heartbeats, _stats_errors,
            _state_names.get(play_state, str(play_state)),
            round(global_rate, 2),
            proj_name or "(none)",
            short_fname or "(none)"))
        _stats_pushes = 0
        _stats_heartbeats = 0
        _stats_errors = 0
        _stats_last_time = now


# ─── Cooperative Defer Loop ───────────────────────────────────────────────────

def _process_commands():
    """Read any pending UDP commands from SyncLyrics and execute them in REAPER."""
    try:
        while True:
            data, addr = _cmd_sock.recvfrom(1024)
            try:
                cmd_json = json.loads(data.decode("utf-8"))
                if "cmd" in cmd_json:
                    cmd_val = cmd_json["cmd"]
                    if isinstance(cmd_val, int):
                        RPR_Main_OnCommand(cmd_val, 0)
                    elif isinstance(cmd_val, str):
                        if cmd_val.startswith("_"):
                            action_id = RPR_NamedCommandLookup(cmd_val)
                            if action_id > 0:
                                RPR_Main_OnCommand(action_id, 0)
                        elif cmd_val.isdigit():
                            RPR_Main_OnCommand(int(cmd_val), 0)
                elif "seek" in cmd_json:
                    seek_pos = cmd_json["seek"]
                    if isinstance(seek_pos, (int, float)) and seek_pos >= 0:
                        RPR_SetEditCurPos(float(seek_pos), True, True)

            except Exception:
                pass  # Ignore malformed packets
    except BlockingIOError:
        pass  # No more data in OS buffer
    except Exception as e:
        _log("Command socket error: {}".format(e))

def _tick():
    """Called by REAPER's idle mechanism ~30-60x per second.

    Rate-limited to PUSH_INTERVAL so we push at 20 Hz rather than ~60 Hz.
    Must return quickly — each call takes <0.5ms (item count is small for
    typical Guitar Pro sessions with a handful of video items).
    """
    global _last_push
    _process_commands()  # Process incoming commands every REAPER tick

    now = RPR_time_precise()
    if now - _last_push >= PUSH_INTERVAL:
        _last_push = now
        try:
            _push_state()
        except Exception:
            pass  # never let a transient API error kill the defer loop
    RPR_defer("_tick()")  # re-schedule: RPR_defer takes a string, not a callable


# ─── Cleanup ──────────────────────────────────────────────────────────────────

def _cleanup():
    """Called when the script is stopped by the user or REAPER closes.

    Sends a final 'stopped' payload so the Python server knows the companion
    script is no longer running and can fall back to Mode A (MJPEG).
    """
    RPR_DeleteExtState(_GUARD_SECTION, _GUARD_KEY, False)  # release single-instance lock
    _log("Script stopping — sending final stop payload")
    stop = json.dumps({
        "pos": 0.0, "state": 0, "rate": 1.0, "src_time": None, "file": None,
        "all_videos": [],
    })
    try:
        _sock.sendto(stop.encode("utf-8"), (UDP_HOST, UDP_PORT))
        _sock.sendto(stop.encode("utf-8"), (UDP_HOST, SYNCLYRICS_UDP_PORT))
    except Exception:
        pass
    try:
        _sock.close()
        _cmd_sock.close()
    except Exception:
        pass
    _log_close()


# ─── Entry Point ──────────────────────────────────────────────────────────────

if RPR_GetExtState(_GUARD_SECTION, _GUARD_KEY) == "1":
    # Another instance is already running — abort silently.
    # No RPR_defer call = script exits immediately after this block.
    pass
else:
    RPR_SetExtState(_GUARD_SECTION, _GUARD_KEY, "1", False)  # persist=False: session-only
    _log_init()
    RPR_atexit("_cleanup()")  # register cleanup for when script ends

    try:
        RPR_defer("_tick()")      # start the cooperative defer loop
        _log("Defer loop started successfully")
    except Exception as e:
        _log("FATAL: RPR_defer failed: {}".format(e))
        _log_close()
