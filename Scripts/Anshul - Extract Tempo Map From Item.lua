--[[
@description Extract Tempo Map from Audio Item (Beat This!)
@author Anshul
@version 5.3
@about
  Detects beats and downbeats in an audio item using the Beat This! machine learning model,
  then converts them into a project tempo map with automatic anchor/setup tempos.

  **Workflow:**
  1. Select a drum stem or metronome audio item
  2. Run this script (or select 2+ items to mix for richer detection)
  3. Configure source type (auto/click/drum/mix), BPM hint, detail level
  4. Phase 1: place markers at detected beats and snap to transients
  5. Phase 2: review and convert markers to tempo envelope

  **Requirements:**
  - Python 3.x (https://www.python.org)
  - pip install torch (from https://pytorch.org — match your CUDA version)
  - pip install tqdm einops soxr rotary-embedding-torch soundfile
  - pip install https://github.com/CPJKU/beat_this/archive/main.zip
  - FFmpeg in PATH (https://ffmpeg.org)
  - SWS Extensions (for advanced snap features)
  - Companion files: beat_this_helper.py, audio_mix_helper.py (same folder as script)
@provides
  beat_this_helper.py
  audio_mix_helper.py
  beat_net_helper.py
@changelog
  v5.3 (2026-04-06)
    + ReaPack release formatting
  v5.2 (2026-03-29)
    + Marker names simplified: __BT_<token>_N -> BT_N (drop session tokens)
    + Marker colours unified: all BT markers are plain blue (was cyan/green/magenta)
    + audio_mix_helper.py: ffmpeg pre-decode for all inputs (MP3/FLAC/OGG/M4A support)
    + audio_mix_helper.py: site-packages injection before third-party imports (crash fix)
    + audio_mix_helper.py: try/except prints errors to stdout so REAPER shows them
    + SWS safety check added to Phase 1 Preview (parity with Phase 2)
  v5.1 (2026-03-29)
    + Multi-item merge: select 2+ items to combine audio for richer beat detection
    + New audio_mix_helper.py: mixes files with resampling to highest sample rate
    + Preview tempo map: interactive=on creates markers + preview grid (two undo blocks)
    + Interactive field now tri-state: off (auto), on (preview), map (markers only)
    + Separate undo blocks: Ctrl+Z removes preview map first, then markers
    + Phase 2 handles preview map cleanup before rebuilding
  v5.0 (2026-03-29)
    + Interactive two-phase mode: Phase 1 places/snaps markers, Phase 2 converts
    + ProjExtState carries source type, detail mode, BPM context between phases
    + Color-coded markers: cyan=anchor, green=downbeat, magenta=regular beat
    + Phase 2 short prompt (conversion + action) with abort+cleanup option
    + Phase 2 validates marker count before converting
    + Orphaned marker handling (BT markers exist but no stored state)
    + Edit cursor moves to first marker after Phase 1
    + Phase 1 cleanup on error (partial markers removed)
  v4.0 (2026-03-29)
    + Added transient snap pipeline: temp project markers -> snap to transients -> convert
    + Three conversion backends: native (action 40338), SWS, direct (API)
    + Config popup expanded to 6 fields: source, BPM, detail, snap, window, conversion
    + Snap window defaults to 50% of one beat interval (dynamic from reference BPM)
    + Temp markers use unique session token + color for safe cleanup
    + Snap statistics: accepted/rejected/unchanged count, avg/max delta
    + Direct+snap mode preserves all time sig/anchor metadata via existing apply_events
  v3.0 (2026-03-29)
    + Added source-aware modes: auto, click, drum, mix
    + Added optional expected BPM hint (manual or filename-derived)
    + Added wrap-aware source projection for looped/slip-edited items
    + Click mode now prioritizes beat/grid alignment over synthetic setup tempo
    + Improved error logging and Beat This process output visibility
  v2.1 (2026-03-28)
    + Require exactly one selected audio item to avoid grouped-item mistakes
    + Detect unreliable downbeats automatically and fall back to beat-grouped bars
    + Setup tempo now comes from early beat timing instead of fragile downbeat bars
    + Avoid double-defining bar 1 when project start and song anchor are effectively the same bar
  v2.0 (2026-03-28)
    + Reworked around a cleanup and anchor pipeline instead of raw per-beat import
    + Setup tempo at project start derived from the first 2-3 detected bars
    + First usable downbeat is treated as the song anchor candidate
    + Preserves current project time signatures by default
    + Supports bar-level (default) and beat-level marker detail
    + Shorter Beat This timeout to reduce long REAPER freezes

Workflow:
  1. Select a drum stem or metronome audio item in REAPER
  2. Run this script
  3. Beat This! detects beats + downbeats in the source audio
  4. Beat data is normalized before any tempo markers are written
  5. Tempo markers are placed from the first usable anchor onward
  6. Click-like sources prioritize beat/grid alignment over a synthetic setup marker
  7. Non-click overwrite mode can still write a setup tempo at project start

Requires:
  beat_this_helper.py in the same folder as this script
  Python 3.x on the system
  Beat This! installed -- see beat_this_helper.py for install steps

The source-to-project mapping is:
  project_time = item_pos + (beat_source_time - D_STARTOFFS)

This correctly accounts for slip-edited items, because D_STARTOFFS is the
source-media position that plays at the item's left edge. Wrapped/looped
source spans are also projected into the visible item range.
--]]

local version = "Extract Tempo Map v5.3"

-- ============================================================
-- CONFIGURATION
-- ============================================================
local PYTHON_EXE = nil
local HELPER_PY  = nil
local MIXER_PY   = nil

local DEFAULT_SOURCE_MODE = "auto"
local DEFAULT_DETAIL_MODE = "bar"
local DEFAULT_SETUP_BARS  = 3

local TIME_EPS           = 0.001
local MIN_BEAT_INTERVAL  = 0.08   -- treat closer detections as duplicate artifacts
local LARGE_GAP_INTERVAL = 2.0    -- do not convert long dropouts into literal BPM
local MIN_BPM            = 10.0
local MAX_BPM            = 600.0
local BEAT_THIS_TIMEOUT  = 60000

-- Transient snap pipeline
local TEMP_MARKER_PREFIX   = "BT_"
local DEFAULT_SNAP_ENABLED = true
local DEFAULT_SNAP_WINDOW  = "auto"   -- "auto" = 50% of one beat interval
local DEFAULT_CONVERSION   = "auto" -- "auto", "native", "sws", or "direct"

-- Interactive mode
local DEFAULT_INTERACTIVE    = false
local EXTSTATE_SECTION       = "BeatThisInteractive"

-- ============================================================
-- UTILITIES
-- ============================================================
local function Msg(s)
  reaper.ShowConsoleMsg(tostring(s) .. "\n")
end

local function show_error(msg)
  Msg("[TempoMap] ERROR: " .. tostring(msg):gsub("\n", " "))
  reaper.MB(msg, "Extract Tempo Map -- Error", 0)
end

local function get_script_dir()
  local _, script_path = reaper.get_action_context()
  return script_path:match("^(.+[/\\])") or ""
end

local function sort_by_time(t)
  table.sort(t, function(a, b)
    return a.time < b.time
  end)
end

local function clamp(x, lo, hi)
  if x < lo then return lo end
  if x > hi then return hi end
  return x
end

local function trim(s)
  return (tostring(s or ""):match("^%s*(.-)%s*$"))
end

local function median(values)
  if #values == 0 then return nil end
  table.sort(values)
  local mid = math.floor(#values / 2) + 1
  if (#values % 2) == 1 then
    return values[mid]
  end
  return (values[mid - 1] + values[mid]) * 0.5
end

local function get_project_timesig_at(t)
  local num, denom = reaper.TimeMap_GetTimeSigAtTime(0, t)
  num   = tonumber(num)   or 4
  denom = tonumber(denom) or 4
  if num <= 0 then num = 4 end
  if denom <= 0 then denom = 4 end
  return num, denom
end

local function get_anchor_measure_index(t)
  local _, measures = reaper.TimeMap2_timeToBeats(0, t)
  measures = tonumber(measures) or 0
  if measures < 0 then measures = 0 end
  return math.floor(measures + 0.0001)
end

local function find_python()
  local function parse_where(out)
    local first_stub = nil
    for line in out:gmatch("[^\r\n]+") do
      local path = line:match("^%s*(.-)%s*$")
      if path ~= "" then
        if path:lower():find("windowsapps", 1, true) then
          if not first_stub then first_stub = path end
        else
          return path
        end
      end
    end
    return first_stub
  end

  local raw1 = reaper.ExecProcess("C:\\Windows\\System32\\where.exe python", 5000)
  local exc1, out1 = parse_exec_result(raw1)
  if out1 and out1 ~= "" then
    local p = parse_where(out1)
    if p then return p end
  end

  local raw2 = reaper.ExecProcess("C:\\Windows\\System32\\where.exe python3", 5000)
  local exc2, out2 = parse_exec_result(raw2)
  if out2 and out2 ~= "" then
    local p = parse_where(out2)
    if p then return p end
  end

  local lad  = os.getenv("LOCALAPPDATA")     or ""
  local pf   = os.getenv("ProgramFiles")      or "C:\\Program Files"
  local pf86 = os.getenv("ProgramFiles(x86)") or "C:\\Program Files (x86)"
  local candidates = {
    lad  .. "\\Programs\\Python\\Python313\\python.exe",
    lad  .. "\\Programs\\Python\\Python312\\python.exe",
    lad  .. "\\Programs\\Python\\Python311\\python.exe",
    lad  .. "\\Programs\\Python\\Python310\\python.exe",
    pf   .. "\\Python313\\python.exe",
    pf   .. "\\Python312\\python.exe",
    pf   .. "\\Python311\\python.exe",
    pf86 .. "\\Python313\\python.exe",
    pf86 .. "\\Python311\\python.exe",
    "C:\\Python313\\python.exe",
    "C:\\Python311\\python.exe",
  }

  for _, p in ipairs(candidates) do
    local f = io.open(p, "rb")
    if f then
      f:close()
      return p
    end
  end

  return nil
end

local function prompt_options()
  local defaults = DEFAULT_SOURCE_MODE .. ",," .. DEFAULT_DETAIL_MODE .. "," ..
    (DEFAULT_SNAP_ENABLED and "on" or "off") .. "," ..
    DEFAULT_SNAP_WINDOW .. "," ..
    DEFAULT_CONVERSION .. "," ..
    (DEFAULT_INTERACTIVE and "on" or "off") .. ",auto,auto,no,auto"

  local ok, input = reaper.GetUserInputs(
    "Extract Tempo Map Options", 11,
    "Source type (auto/click/drum/mix)," ..
    "Expected BPM (blank=auto)," ..
    "Detail mode (bar/beat)," ..
    "Transient snap (on/off)," ..
    "Snap window (auto/N ms)," ..
    "Conversion (native/sws/direct)," ..
    "Interactive (off/on/map)," ..
    "Anchor Pos (e.g. 2.1 or auto)," ..
    "Time Sig (e.g. 4/4 or auto)," ..
    "Move Items (yes/no)," ..
    "Filter Ghosts (yes/no/auto):",
    defaults)
  if not ok then return nil end

  local fields = {}
  for field in (input .. ","):gmatch("([^,]*),") do
    fields[#fields + 1] = trim(field)
  end

  local source_str      = (fields[1] or ""):lower()
  local bpm_str         = fields[2] or ""
  local detail_str      = (fields[3] or ""):lower()
  local snap_str        = (fields[4] or ""):lower()
  local window_str      = (fields[5] or ""):lower()
  local conv_str        = (fields[6] or ""):lower()
  local interactive_str = (fields[7] or ""):lower()
  local anchor_str      = (fields[8] or ""):lower()
  local ts_str          = (fields[9] or ""):lower()
  local move_str        = (fields[10] or ""):lower()
  local ghosts_str      = (fields[11] or ""):lower()

  if source_str ~= "auto" and source_str ~= "click" and source_str ~= "drum" and source_str ~= "mix" then
    show_error("Invalid source type.\n\nEnter auto, click, drum, or mix.")
    return nil
  end

  if detail_str ~= "bar" and detail_str ~= "beat" and detail_str ~= "auto" then
    show_error("Invalid detail mode.\n\nEnter 'auto', 'bar', or 'beat'.")
    return nil
  end

  bpm_str = trim(bpm_str)
  local expected_bpm = nil
  if bpm_str ~= "" then
    expected_bpm = tonumber(bpm_str)
    if not expected_bpm or expected_bpm <= 0 then
      show_error("Invalid expected BPM.\n\nLeave it blank or enter a number > 0.")
      return nil
    end
  end

  local snap_enabled = true
  if snap_str == "off" or snap_str == "no" or snap_str == "0" then
    snap_enabled = false
  elseif snap_str ~= "on" and snap_str ~= "yes" and snap_str ~= "1" and snap_str ~= "" then
    show_error("Invalid transient snap value.\n\nEnter 'on' or 'off'.")
    return nil
  end

  local snap_window = nil  -- nil = auto
  if window_str ~= "auto" and window_str ~= "" then
    snap_window = tonumber(window_str)
    if not snap_window or snap_window <= 0 then
      show_error("Invalid snap window.\n\nEnter 'auto' or a positive number in ms.")
      return nil
    end
    snap_window = snap_window / 1000.0  -- ms to seconds
  end

  if conv_str == "" then conv_str = DEFAULT_CONVERSION end
  if conv_str ~= "auto" and conv_str ~= "native" and conv_str ~= "sws" and conv_str ~= "direct" then
    show_error("Invalid conversion backend.\n\nEnter 'auto', 'native', 'sws', or 'direct'.")
    return nil
  end

  -- interactive: "off" (default), "on" (preview tempo map + markers), "map" (markers only)
  local interactive = "off"
  if interactive_str == "on" or interactive_str == "yes" or interactive_str == "1" then
    interactive = "on"
  elseif interactive_str == "map" then
    interactive = "map"
  elseif interactive_str ~= "off" and interactive_str ~= "no" and interactive_str ~= "0" and interactive_str ~= "" then
    show_error("Invalid interactive value.\n\nEnter 'off', 'on', or 'map'.")
    return nil
  end

  local anchor_measure, anchor_beat
  if anchor_str == "auto" or anchor_str == "" then
    anchor_measure, anchor_beat = 3, 1
  else
    local m_str, b_str = anchor_str:match("^(%d+)%.?(%d*)$")
    anchor_measure = tonumber(m_str)
    anchor_beat = (b_str == "") and 1 or tonumber(b_str)
    if not anchor_measure or anchor_measure < 1 then
      show_error("Invalid anchor position.\n\nEnter 'auto' or a decimal (e.g., 2.1, 3.4).")
      return nil
    end
  end
  
  local ts_num, ts_den
  if ts_str ~= "auto" and ts_str ~= "" then
    local n_str, d_str = ts_str:match("^(%d+)/(%d+)$")
    ts_num = tonumber(n_str)
    ts_den = tonumber(d_str)
    if not ts_num or not ts_den or ts_num < 1 or ts_den < 1 then
      show_error("Invalid time signature.\n\nEnter 'auto' or a valid signature (e.g., 4/4, 6/8).")
      return nil
    end
  end
  
  local move_items = false
  if move_str == "yes" or move_str == "on" or move_str == "1" then
    move_items = true
  elseif move_str ~= "no" and move_str ~= "off" and move_str ~= "0" and move_str ~= "" then
    show_error("Invalid Move Items value.\n\nEnter 'yes' or 'no'.")
    return nil
  end
  
  local cull_ghosts = "auto"
  if ghosts_str == "yes" or ghosts_str == "on" or ghosts_str == "1" then
    cull_ghosts = "yes"
  elseif ghosts_str == "no" or ghosts_str == "off" or ghosts_str == "0" then
    cull_ghosts = "no"
  elseif ghosts_str ~= "auto" and ghosts_str ~= "" then
    show_error("Invalid Filter Ghosts value.\n\nEnter 'yes', 'no', or 'auto'.")
    return nil
  end

  return {
    source_mode    = source_str,
    expected_bpm   = expected_bpm,
    detail_mode    = detail_str,
    setup_bars     = DEFAULT_SETUP_BARS,
    snap_enabled   = snap_enabled,
    snap_window    = snap_window,
    conversion     = conv_str,
    interactive    = interactive,
    anchor_measure = anchor_measure,
    anchor_beat    = anchor_beat,
    ts_num         = ts_num,
    ts_den         = ts_den,
    move_items     = move_items,
    cull_ghosts    = cull_ghosts,
  }
end

local function parse_filename_bpm(path)
  local lower = (path or ""):lower()
  local value = lower:match("%-(%d%d?%d)bpm%-")
             or lower:match("(%d%d?%d)%s*bpm")
  value = tonumber(value)
  if value and value > 0 then
    return value
  end
  return nil
end

local function resolve_expected_bpm(user_bpm, audio_path)
  if user_bpm then
    return user_bpm, "user"
  end

  local parsed = parse_filename_bpm(audio_path)
  if parsed then
    return parsed, "filename"
  end

  return nil, "none"
end

local function resolve_source_type(requested_mode, audio_path, raw_db_ratio)
  if requested_mode ~= "auto" then
    return requested_mode, "user"
  end

  local lower = (audio_path or ""):lower()
  if lower:find("metronome", 1, true) or lower:find("click", 1, true) then
    return "click", "filename"
  end
  if lower:find("drums", 1, true) then
    return "drum", "filename"
  end
  if raw_db_ratio and raw_db_ratio > 0.85 then
    return "click", "downbeat-ratio"
  end
  return "mix", "fallback"
end

local function compute_median_bpm_from_beats(beats, start_idx)
  local values = {}
  start_idx = start_idx or 1
  for i = start_idx, #beats - 1 do
    local t1 = beats[i].project_time or beats[i].source_time
    local t2 = beats[i + 1].project_time or beats[i + 1].source_time
    local dt = t2 - t1
    if dt > TIME_EPS then
      local bpm = 60.0 / dt
      if bpm >= MIN_BPM and bpm <= MAX_BPM then
        values[#values + 1] = bpm
      end
    end
  end
  return median(values)
end

local function compute_median_raw_bar_bpm(bars, limit)
  local values = {}
  limit = math.min(limit or #bars, #bars)
  for i = 1, limit do
    local bpm = bars[i].raw_bpm
    if bpm and bpm >= MIN_BPM and bpm <= MAX_BPM * 2 then
      values[#values + 1] = bpm
    end
  end
  return median(values)
end

local function normalize_bpm_octave(bpm, reference_bpm)
  if not bpm or not reference_bpm or bpm <= 0 or reference_bpm <= 0 then
    return bpm, false
  end

  local adjusted = bpm
  local changed = false
  for _ = 1, 3 do
    if adjusted < reference_bpm * 0.6 then
      adjusted = adjusted * 2.0
      changed = true
    elseif adjusted > reference_bpm * 1.8 then
      adjusted = adjusted * 0.5
      changed = true
    else
      break
    end
  end

  return adjusted, changed
end

local function large_gap_threshold(reference_bpm, beats_per_bar)
  if not reference_bpm or reference_bpm <= 0 then
    return LARGE_GAP_INTERVAL
  end

  local beat_dur = 60.0 / reference_bpm
  local bar_dur = beat_dur * math.max(1, beats_per_bar or 4)
  return math.max(LARGE_GAP_INTERVAL, bar_dur * 1.75)
end

-- ============================================================
-- BT MARKER HELPERS (interactive mode)
-- ============================================================

local function is_bt_marker(name)
  if not name then return false end
  return name:sub(1, #TEMP_MARKER_PREFIX) == TEMP_MARKER_PREFIX
end

local function count_bt_markers()
  local count = 0
  local total = reaper.CountProjectMarkers(0)
  for i = 0, total - 1 do
    local _, isrgn, _, _, name = reaper.EnumProjectMarkers(i)
    if not isrgn and is_bt_marker(name) then
      count = count + 1
    end
  end
  return count
end

local function read_all_bt_marker_positions()
  local positions = {}
  local total = reaper.CountProjectMarkers(0)
  for i = 0, total - 1 do
    local _, isrgn, pos, _, name = reaper.EnumProjectMarkers(i)
    if not isrgn and is_bt_marker(name) then
      positions[#positions + 1] = pos
    end
  end
  table.sort(positions)
  return positions
end

local function cleanup_all_bt_markers()
  local removed = 0
  local total = reaper.CountProjectMarkers(0)
  for i = total - 1, 0, -1 do
    local _, isrgn, _, _, name, markrgnidx = reaper.EnumProjectMarkers(i)
    if not isrgn and is_bt_marker(name) then
      reaper.DeleteProjectMarkerByIndex(0, i)
      removed = removed + 1
    end
  end
  Msg(string.format("[Cleanup] Removed %d BT markers", removed))
  return removed
end

-- ============================================================
-- PROJEXTSTATE (interactive phase context)
-- ============================================================

local function save_interactive_state(data)
  for key, value in pairs(data) do
    reaper.SetProjExtState(0, EXTSTATE_SECTION, key, tostring(value))
  end
  Msg("[ExtState] Saved interactive state: " .. tostring(data.marker_count or "?") .. " markers")
end

local function load_interactive_state()
  local keys = {"source_type", "detail_mode", "reference_bpm", "median_bpm",
                 "beats_per_bar", "marker_count", "conversion", "setup_bpm",
                 "interactive_mode"}
  local state = {}
  local has_any = false
  for _, key in ipairs(keys) do
    local rv, val = reaper.GetProjExtState(0, EXTSTATE_SECTION, key)
    if rv > 0 and val ~= "" then
      state[key] = val
      has_any = true
    end
  end
  return has_any and state or nil
end

local function clear_interactive_state()
  local keys = {"source_type", "detail_mode", "reference_bpm", "median_bpm",
                 "beats_per_bar", "marker_count", "conversion", "setup_bpm",
                 "interactive_mode"}
  for _, key in ipairs(keys) do
    reaper.SetProjExtState(0, EXTSTATE_SECTION, key, "")
  end
  Msg("[ExtState] Cleared interactive state")
end

-- ============================================================
-- EXEC PROCESS HELPER
-- ============================================================
-- reaper.ExecProcess returns a SINGLE string: "<exit_code>\n<stdout>"
-- It does NOT return two separate values. This helper splits them correctly.
local function parse_exec_result(raw)
  if not raw then return nil, "" end
  local nl = raw:find("\n")
  if nl then
    return tonumber(raw:sub(1, nl - 1)), raw:sub(nl + 1)
  end
  return tonumber(raw), ""
end

-- ============================================================
-- BEAT TRACKER
-- ============================================================
local function run_beat_tracker(audio_path)
  local temp_csv = string.format("%s\\reaper_beats_%d_%05d.csv",
    os.getenv("TEMP"), os.time(), math.random(10000, 99999))
  local cmd      = string.format('"%s" "%s" "%s" "%s"',
                     PYTHON_EXE, HELPER_PY, audio_path, temp_csv)

  Msg("[BeatThis] Source: " .. audio_path)
  Msg("[BeatThis] Command: " .. cmd)
  Msg("[BeatThis] Running...")

  local raw = reaper.ExecProcess(cmd, BEAT_THIS_TIMEOUT)
  local exit_code, out = parse_exec_result(raw)
  if out and out ~= "" then
    Msg("[BeatThis] Output:")
    Msg(out)
  end
  if exit_code and exit_code ~= 0 then
    Msg(string.format("[BeatThis] Process exit code: %d", exit_code))
  end

  local f = io.open(temp_csv, "r")
  if not f then
    show_error(
      "Beat tracker produced no output.\n\n" ..
      "Check the REAPER console for details.\n\n" ..
      "Ensure Beat This! is installed:\n" ..
      "  1. pip install torch  (from https://pytorch.org)\n" ..
      "  2. pip install tqdm einops soxr rotary-embedding-torch\n" ..
      "  3. pip install https://github.com/CPJKU/beat_this/archive/main.zip")
    return nil
  end

  local beats = {}
  local is_header = true
  for line in f:lines() do
    if is_header then
      is_header = false
    else
      local t_str, db_str = line:match("([%d%.]+),(%d)")
      if t_str then
        beats[#beats + 1] = {
          source_time = tonumber(t_str),
          is_downbeat = (db_str == "1"),
        }
      end
    end
  end
  f:close()
  os.remove(temp_csv)

  if #beats == 0 then
    show_error("No beats were detected in the audio file.\n\nCheck the REAPER console for error details.")
    return nil
  end

  local db_count = 0
  for _, beat in ipairs(beats) do
    if beat.is_downbeat then db_count = db_count + 1 end
  end

  Msg(string.format("[BeatThis] Detected %d beats (%d downbeats).", #beats, db_count))
  return beats
end

-- ============================================================
-- BEAT PREP
-- ============================================================
local function project_beats_into_item(raw_beats, item_pos, item_end, soffs, source_len, allow_wrap)
  local beats = {}
  local skipped_pre  = 0
  local skipped_post = 0

  for _, beat in ipairs(raw_beats) do
    local rel = beat.source_time - soffs
    local placed_any = false

    if allow_wrap and source_len and source_len > TIME_EPS then
      while rel < -TIME_EPS do
        rel = rel + source_len
      end
    end

    while true do
      local project_time = item_pos + rel
      if project_time < item_pos - TIME_EPS then
        skipped_pre = skipped_pre + 1
      elseif project_time > item_end + TIME_EPS then
        if not placed_any then
          skipped_post = skipped_post + 1
        end
        break
      else
        beats[#beats + 1] = {
          source_time  = beat.source_time,
          project_time = project_time,
          is_downbeat  = beat.is_downbeat,
        }
        placed_any = true
      end

      if not (allow_wrap and source_len and source_len > TIME_EPS) then
        break
      end

      rel = rel + source_len
      if rel > (item_end - item_pos) + TIME_EPS then
        break
      end
    end
  end

  table.sort(beats, function(a, b)
    if math.abs(a.project_time - b.project_time) > TIME_EPS then
      return a.project_time < b.project_time
    end
    return a.source_time < b.source_time
  end)

  return beats, {
    skipped_pre  = skipped_pre,
    skipped_post = skipped_post,
  }
end

local function normalize_beats(beats)
  local cleaned = {}
  local stats = {
    removed_non_monotonic = 0,
    removed_clusters      = 0,
  }

  for _, beat in ipairs(beats) do
    local prev = cleaned[#cleaned]
    if not prev then
      cleaned[#cleaned + 1] = beat
    else
      -- Use project_time for ordering checks, not source_time.
      -- After wrap-aware projection, source_time can be non-monotonic
      -- (e.g. 280s followed by 2s) while project_time is always correct.
      local dt = beat.project_time - prev.project_time
      if dt <= 0 then
        stats.removed_non_monotonic = stats.removed_non_monotonic + 1
      elseif dt < MIN_BEAT_INTERVAL then
        if beat.is_downbeat and not prev.is_downbeat then
          cleaned[#cleaned] = beat
        end
        stats.removed_clusters = stats.removed_clusters + 1
      else
        cleaned[#cleaned + 1] = beat
      end
    end
  end

  return cleaned, stats
end

local function analyze_downbeats(beats, default_beats_per_bar)
  local stats = {
    detected_count   = 0,
    ratio            = 0.0,
    dominant_interval = nil,
    dominant_share   = 0.0,
    reliable         = false,
    reason           = "",
  }

  local downbeats = {}
  for i, beat in ipairs(beats) do
    if beat.is_downbeat then
      downbeats[#downbeats + 1] = i
    end
  end

  stats.detected_count = #downbeats
  stats.ratio = (#beats > 0) and (#downbeats / #beats) or 0.0

  if #downbeats == 0 then
    stats.reason = "none detected"
    return stats
  end

  if stats.ratio > 0.5 then
    stats.reason = "too many beats flagged as downbeats"
    return stats
  end

  if #downbeats < 2 then
    stats.reason = "too few downbeats"
    return stats
  end

  local interval_counts = {}
  local interval_total = 0
  local dominant_count = 0
  local dominant_interval = nil

  for i = 1, #downbeats - 1 do
    local interval = downbeats[i + 1] - downbeats[i]
    if interval > 0 then
      interval_total = interval_total + 1
      interval_counts[interval] = (interval_counts[interval] or 0) + 1
      if interval_counts[interval] > dominant_count then
        dominant_count = interval_counts[interval]
        dominant_interval = interval
      end
    end
  end

  stats.dominant_interval = dominant_interval
  if interval_total > 0 then
    stats.dominant_share = dominant_count / interval_total
  end

  if not dominant_interval then
    stats.reason = "no stable spacing"
    return stats
  end

  if dominant_interval == 1 then
    stats.reason = "every beat behaves like a downbeat"
    return stats
  end

  if stats.dominant_share < 0.6 then
    stats.reason = "downbeat spacing is inconsistent"
    return stats
  end

  if default_beats_per_bar and default_beats_per_bar > 0 then
    local delta = math.abs(dominant_interval - default_beats_per_bar)
    if delta > 2 then
      stats.reason = string.format("dominant spacing %d disagrees with project meter %d", dominant_interval, default_beats_per_bar)
      return stats
    end
  end

  stats.reliable = true
  stats.reason = "stable"
  return stats
end

local function find_anchor_index(beats, use_downbeats)
  if use_downbeats then
    for i, beat in ipairs(beats) do
      if beat.is_downbeat then
        return i, true
      end
    end
  end
  return 1, false
end

local function derive_bar_segments(beats, anchor_idx, default_beats_per_bar, use_downbeats)
  local bars = {}
  local downbeats = {}

  if use_downbeats then
    for i = anchor_idx, #beats do
      if beats[i].is_downbeat then
        downbeats[#downbeats + 1] = i
      end
    end
  end

  if use_downbeats and #downbeats >= 2 then
    for j = 1, #downbeats do
      local start_idx = downbeats[j]
      local next_idx  = downbeats[j + 1]
      local beats_in_bar
      local duration = nil
      local bpm = nil

      if next_idx then
        beats_in_bar = next_idx - start_idx
        duration = beats[next_idx].project_time - beats[start_idx].project_time
        if duration and duration > TIME_EPS then
          bpm = beats_in_bar * 60.0 / duration
        end
      elseif j > 1 then
        beats_in_bar = math.max(1, downbeats[j] - downbeats[j - 1])
      else
        beats_in_bar = default_beats_per_bar
      end

      bars[#bars + 1] = {
        start_idx    = start_idx,
        project_time = beats[start_idx].project_time,
        source_time  = beats[start_idx].source_time,
        beats_in_bar = math.max(1, beats_in_bar or default_beats_per_bar),
        duration     = duration,
        raw_bpm      = bpm,
      }
    end
  else
    local i = anchor_idx
    while i <= #beats do
      local next_idx = i + default_beats_per_bar
      local beats_in_bar = math.min(default_beats_per_bar, #beats - i + 1)
      local duration = nil
      local bpm = nil

      if next_idx <= #beats then
        duration = beats[next_idx].project_time - beats[i].project_time
        if duration and duration > TIME_EPS then
          bpm = beats_in_bar * 60.0 / duration
        end
      end

      bars[#bars + 1] = {
        start_idx    = i,
        project_time = beats[i].project_time,
        source_time  = beats[i].source_time,
        beats_in_bar = math.max(1, beats_in_bar),
        duration     = duration,
        raw_bpm      = bpm,
      }

      if next_idx > #beats then break end
      i = next_idx
    end
  end

  return bars
end

local function should_trust_downbeats(source_type, downbeat_stats, candidate_bars, reference_bpm)
  if source_type == "click" then
    return false, "click mode ignores downbeats"
  end

  if not downbeat_stats.reliable then
    return false, downbeat_stats.reason
  end

  if reference_bpm then
    local early_bar_bpm = compute_median_raw_bar_bpm(candidate_bars, DEFAULT_SETUP_BARS)
    if early_bar_bpm then
      local ratio = early_bar_bpm / reference_bpm
      if (ratio > 0.45 and ratio < 0.55) or (ratio > 1.8 and ratio < 2.2) then
        return false, string.format("early bar BPM %.1f looks octave-shifted vs reference %.1f", early_bar_bpm, reference_bpm)
      end
      if ratio < 0.7 or ratio > 1.3 then
        return false, string.format("early bar BPM %.1f disagrees with reference %.1f", early_bar_bpm, reference_bpm)
      end
    end
  end

  return true, "stable"
end

local function sanitize_bar_bpms(bars, fallback_bpm, reference_bpm)
  local stats = {
    large_gap_bars = 0,
    out_of_range_bars = 0,
    octave_corrected_bars = 0,
  }

  local last_valid = fallback_bpm
  for _, bar in ipairs(bars) do
    local bpm = bar.raw_bpm
    local gap = bar.duration
    if bpm and reference_bpm then
      local adjusted, changed = normalize_bpm_octave(bpm, reference_bpm)
      bpm = adjusted
      if changed then
        stats.octave_corrected_bars = stats.octave_corrected_bars + 1
      end
    end

    if not bpm then
      bar.bpm = last_valid
    elseif gap and gap > large_gap_threshold(reference_bpm or last_valid, bar.beats_in_bar) then
      stats.large_gap_bars = stats.large_gap_bars + 1
      bar.bpm = last_valid
    elseif bpm < MIN_BPM or bpm > MAX_BPM then
      stats.out_of_range_bars = stats.out_of_range_bars + 1
      bar.bpm = last_valid
    else
      bar.bpm = bpm
      last_valid = bpm
    end
  end

  return stats
end

local function compute_setup_bpm_from_early_beats(beats, anchor_idx, beats_per_bar, setup_bar_count, fallback_bpm)
  local sample_intervals = math.max(1, beats_per_bar * setup_bar_count)
  local dt_values = {}
  local last_index = math.min(#beats - 1, anchor_idx + sample_intervals - 1)

  for i = anchor_idx, last_index do
    local current = beats[i]
    local nxt = beats[i + 1]
    if current and nxt then
      local dt = nxt.project_time - current.project_time
      local bpm = (dt > TIME_EPS) and (60.0 / dt) or nil
      if bpm and bpm >= MIN_BPM and bpm <= MAX_BPM and dt <= LARGE_GAP_INTERVAL then
        dt_values[#dt_values + 1] = dt
      end
    end
  end

  local med_dt = median(dt_values)
  if med_dt and med_dt > TIME_EPS then
    local used_bars = math.max(1, math.floor((#dt_values / math.max(1, beats_per_bar)) + 0.0001))
    return 60.0 / med_dt, used_bars, #dt_values
  end

  return fallback_bpm, 0, 0
end

local function compute_average_bpm_from_beats(beats)
  if #beats < 2 then return nil end
  local t1 = beats[1].project_time or beats[1].source_time
  local t2 = beats[#beats].project_time or beats[#beats].source_time
  local duration = t2 - t1
  if duration <= TIME_EPS then return nil end
  return (#beats - 1) * 60.0 / duration
end

local function sanitize_beat_bpm(dt, last_valid, stats, reference_bpm)
  if not dt or dt <= TIME_EPS then
    stats.invalid_beat_dt = stats.invalid_beat_dt + 1
    return last_valid
  end

  if dt > large_gap_threshold(reference_bpm or last_valid, 1) then
    stats.large_gap_beats = stats.large_gap_beats + 1
    return last_valid
  end

  local bpm = 60.0 / dt
  if reference_bpm then
    local adjusted, _ = normalize_bpm_octave(bpm, reference_bpm)
    bpm = adjusted
  end
  if bpm < MIN_BPM or bpm > MAX_BPM then
    stats.out_of_range_beats = stats.out_of_range_beats + 1
    return last_valid
  end

  return bpm
end

-- ============================================================
-- TEMPO EVENT BUILDING
-- ============================================================
local function add_event(events, event)
  events[#events + 1] = event
end

local function dedupe_events(events)
  sort_by_time(events)
  local deduped = {}

  for _, event in ipairs(events) do
    local prev = deduped[#deduped]
    if prev and math.abs(prev.time - event.time) <= TIME_EPS then
      if prev.time <= TIME_EPS and (prev.ts_num or 0) > 0 then
        if event.measurepos and event.measurepos >= 0 then prev.measurepos = event.measurepos end
        if event.beatpos and event.beatpos >= 0 then prev.beatpos = event.beatpos end
      else
        deduped[#deduped] = event
      end
    else
      deduped[#deduped + 1] = event
    end
  end

  return deduped
end

local function apply_preserved_timesigs(events)
  local prev_num, prev_den = nil, nil
  for _, event in ipairs(events) do
    if event.force_timesig then
      prev_num = event.ts_num
      prev_den = event.ts_denom
    else
      local num, den = get_project_timesig_at(event.time)
      if not prev_num or num ~= prev_num or den ~= prev_den then
        event.ts_num = num
        event.ts_denom = den
        prev_num = num
        prev_den = den
      else
        event.ts_num = 0
        event.ts_denom = 0
      end
    end
  end
end

local function build_bar_events(bars, anchor_measure, anchor_beat, include_setup_marker, setup_bpm, explicit_anchor, source_type, ts_num, ts_den)
  local events = {}

  if include_setup_marker then
    add_event(events, {
      time         = 0.0,
      bpm          = setup_bpm,
      measurepos   = 0,
      beatpos      = 0,
      ts_num       = ts_num,
      ts_denom     = ts_den,
      force_timesig = true,
    })
  end

  local use_anchor = explicit_anchor

  for bar_idx, bar in ipairs(bars) do
    if bar.project_time > TIME_EPS or not include_setup_marker then
      add_event(events, {
        time       = bar.project_time,
        bpm        = bar.bpm,
        is_downbeat = true,
        measurepos = (bar_idx == 1 and use_anchor) and anchor_measure or -1,
        beatpos    = (bar_idx == 1 and use_anchor) and (anchor_beat - 1) or -1,
      })
    end
  end

  return dedupe_events(events)
end

local function build_beat_events(beats, anchor_idx, anchor_measure, anchor_beat, include_setup_marker, setup_bpm, fallback_bpm, explicit_anchor, reference_bpm, source_type, ts_num, ts_den)
  local events = {}
  local stats = {
    invalid_beat_dt  = 0,
    large_gap_beats  = 0,
    out_of_range_beats = 0,
  }

  if include_setup_marker then
    add_event(events, {
      time          = 0.0,
      bpm           = setup_bpm,
      measurepos    = 0,
      beatpos       = 0,
      ts_num        = ts_num,
      ts_denom      = ts_den,
      force_timesig = true,
    })
  end

  local use_anchor = explicit_anchor

  local last_valid = fallback_bpm
  for i = anchor_idx, #beats do
    local beat = beats[i]
    local next_beat = beats[i + 1]
    local dt = next_beat and (next_beat.project_time - beat.project_time) or nil
    local bpm = sanitize_beat_bpm(dt, last_valid, stats, reference_bpm)
    last_valid = bpm

    if beat.project_time > TIME_EPS or not include_setup_marker then
      add_event(events, {
        time       = beat.project_time,
        bpm        = bpm,
        is_downbeat = beat.is_downbeat,
        measurepos = (i == anchor_idx and use_anchor) and anchor_measure or -1,
        beatpos    = (i == anchor_idx and use_anchor) and (anchor_beat - 1) or -1,
      })
    end
  end

  return dedupe_events(events), stats
end

local function apply_events(events, clear_existing, source_type)
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  if clear_existing then
    local n = reaper.CountTempoTimeSigMarkers(0)
    for i = n - 1, 0, -1 do
      reaper.DeleteTempoTimeSigMarker(0, i)
    end
  end

  for _, event in ipairs(events) do
    reaper.SetTempoTimeSigMarker(
      0, -1,
      event.time,
      event.measurepos or -1,
      event.beatpos or -1,
      event.bpm,
      event.ts_num or 0,
      event.ts_denom or 0,
      false
    )
  end

  reaper.UpdateTimeline()
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Extract Tempo Map From Item", -1)
end

-- ============================================================
-- TRANSIENT SNAP PIPELINE
-- ============================================================

local function make_marker_name(index)
  return TEMP_MARKER_PREFIX .. tostring(index)
end

local function get_marker_color_for_event(_event)
  return reaper.ColorToNative(55, 118, 235) | 0x1000000  -- plain blue for all BT markers
end

local function place_temp_markers(events, skip_time_zero)
  local placed = 0
  local color = get_marker_color_for_event({})  -- single blue for all

  for i, event in ipairs(events) do
    if skip_time_zero and event.time <= TIME_EPS then
      Msg(string.format("[TransientSnap] Skipping time-0 setup marker (BPM=%.1f)", event.bpm))
    else
      local name = make_marker_name(i)
      reaper.AddProjectMarker2(0, false, event.time, 0, name, -1, color)
      placed = placed + 1
    end
  end

  Msg(string.format("[TransientSnap] Placed %d BT markers", placed))
  return placed
end

local function compute_snap_window(reference_bpm, user_override)
  if user_override then
    return user_override  -- already in seconds (converted from ms in prompt)
  end
  if reference_bpm and reference_bpm > 0 then
    return (60.0 / reference_bpm) * 0.50  -- 50% of one beat
  end
  return 0.200  -- fallback 200ms if no BPM reference at all
end

local function snap_markers_to_transients(item, reference_bpm, snap_window_override, drop_rejected)
  local snap_window = compute_snap_window(reference_bpm, snap_window_override)

  Msg(string.format("[TransientSnap] Snap window: %.1f ms (50%% of beat at %.1f BPM)",
    snap_window * 1000,
    reference_bpm or 0))

  -- Ensure item is selected (action 40836 operates on selected items)
  reaper.SetMediaItemSelected(item, true)

  -- Collect our markers (must re-enumerate since indices may have shifted)
  local our_markers = {}
  local total_markers = reaper.CountProjectMarkers(0)
  for i = 0, total_markers - 1 do
    local retval, isrgn, pos, rgnend, name, markrgnidx, color = reaper.EnumProjectMarkers3(0, i)
    if not isrgn and is_bt_marker(name) then
      our_markers[#our_markers + 1] = {
        enum_idx = i,
        markrgnidx = markrgnidx,
        original_pos = pos,
        name = name,
        color = color,
      }
    end
  end

  Msg(string.format("[TransientSnap] Found %d BT markers to snap", #our_markers))

  local stats = {
    total = #our_markers,
    accepted = 0,
    rejected = 0,
    dropped = 0,
    unchanged = 0,
    deltas = {},
  }

  for _, m in ipairs(our_markers) do
    -- Move cursor to marker position
    reaper.SetEditCurPos(m.original_pos, false, false)

    -- Action 40836: Move cursor to nearest transient in selected items
    reaper.Main_OnCommand(40836, 0)

    -- Read where the cursor landed
    local snapped_pos = reaper.GetCursorPosition()
    local delta = math.abs(snapped_pos - m.original_pos)

    local event_idx = m.name:match("_(%d+)$") or "?"

    if delta <= TIME_EPS then
      -- Transient is at the exact same position (or no transient found)
      stats.unchanged = stats.unchanged + 1
    elseif delta <= snap_window then
      -- Accept: move marker to snapped position
      reaper.SetProjectMarker3(0, m.markrgnidx, false, snapped_pos, 0, m.name, m.color)
      stats.accepted = stats.accepted + 1
      stats.deltas[#stats.deltas + 1] = delta
    else
      -- Reject: no valid transient nearby
      if drop_rejected then
        -- Remove this marker entirely (phantom/bogus beat)
        reaper.DeleteProjectMarker(0, m.markrgnidx, false)
        stats.dropped = stats.dropped + 1
        Msg(string.format("[TransientSnap] Event#%s: %.4fs -> %.4fs (delta=%.1fms DROPPED - no valid transient)",
          event_idx, m.original_pos, snapped_pos, delta * 1000))
      else
        -- Keep at original position
        stats.rejected = stats.rejected + 1
        Msg(string.format("[TransientSnap] Event#%s: %.4fs -> %.4fs (delta=%.1fms REJECTED, window=%.1fms)",
          event_idx, m.original_pos, snapped_pos, delta * 1000, snap_window * 1000))
      end
    end
  end

  -- Summary stats
  local avg_delta = 0
  local max_delta = 0
  if #stats.deltas > 0 then
    local sum = 0
    for _, d in ipairs(stats.deltas) do
      sum = sum + d
      if d > max_delta then max_delta = d end
    end
    avg_delta = sum / #stats.deltas
  end
  stats.avg_delta = avg_delta
  stats.max_delta = max_delta

  Msg(string.format(
    "[TransientSnap] Summary: %d total, %d accepted, %d rejected, %d dropped, %d unchanged, avg=%.1fms, max=%.1fms",
    stats.total, stats.accepted, stats.rejected, stats.dropped, stats.unchanged,
    avg_delta * 1000, max_delta * 1000))

  return stats
end

local function read_snapped_positions()
  local positions = {}
  local total_markers = reaper.CountProjectMarkers(0)
  for i = 0, total_markers - 1 do
    local retval, isrgn, pos, rgnend, name = reaper.EnumProjectMarkers(i)
    if not isrgn and is_bt_marker(name) then
      local idx_str = name:match("_(%d+)$")
      if idx_str then
        positions[tonumber(idx_str)] = pos
      end
    end
  end
  return positions
end

local function update_events_with_snapped_positions(events, snapped_positions, reference_bpm, source_type)
  -- Update positions, remove dropped events, and preserve click-anchor semantics
  local updated = 0
  local removed = 0
  local click_anchor_num, click_anchor_den = nil, nil
  local had_click_anchor = false
  local surviving = {}

  for i, event in ipairs(events) do
    event._orig_time = event.time  -- attach to event so it follows through sort/filter

    if event.force_timesig and event.time > TIME_EPS then
      had_click_anchor = true
      click_anchor_num = event.ts_num
      click_anchor_den = event.ts_denom
    end

    if event.time > TIME_EPS and snapped_positions[i] == nil then
      removed = removed + 1
    else
      if snapped_positions[i] and math.abs(snapped_positions[i] - event.time) > TIME_EPS then
        event.time = snapped_positions[i]
        updated = updated + 1
      end
      surviving[#surviving + 1] = event
    end
  end

  -- Replace original table contents in-place
  for i = #events, 1, -1 do
    events[i] = nil
  end
  for i, event in ipairs(surviving) do
    events[i] = event
  end

  if source_type == "click" and had_click_anchor then
    local has_nonsetup_anchor = false
    for _, event in ipairs(events) do
      if event.force_timesig and event.time > TIME_EPS then
        has_nonsetup_anchor = true
        break
      end
    end

    if not has_nonsetup_anchor then
      for _, event in ipairs(events) do
        if event.time > TIME_EPS then
          local fallback_num, fallback_den = get_project_timesig_at(0)
          event.force_timesig = true
          event.ts_num = click_anchor_num or event.ts_num or fallback_num
          event.ts_denom = click_anchor_den or event.ts_denom or fallback_den
          Msg(string.format("[TransientSnap] Promoted first surviving beat at %.4fs to click anchor", event.time))
          break
        end
      end
    end
  end

  -- Sort by new positions (safe: _orig_time travels with each event)
  sort_by_time(events)

  -- Recompute BPMs proportionally: new_bpm = old_bpm * (old_dt / new_dt)
  -- This is exact for both beat mode (BPM=60/dt) and bar mode (BPM=n*60/dt)
  local bpm_recomputed = 0
  for i = 1, #events - 1 do
    local old_dt = events[i + 1]._orig_time - events[i]._orig_time
    local new_dt = events[i + 1].time - events[i].time
    if old_dt > TIME_EPS and new_dt > TIME_EPS and not events[i].force_timesig then
      local new_bpm = events[i].bpm * (old_dt / new_dt)
      new_bpm = clamp(new_bpm, MIN_BPM, MAX_BPM)
      if math.abs(new_bpm - events[i].bpm) > 0.01 then
        bpm_recomputed = bpm_recomputed + 1
      end
      events[i].bpm = new_bpm
    end
  end

  -- Clean up temp field
  for _, event in ipairs(events) do
    event._orig_time = nil
  end

  Msg(string.format("[TransientSnap] Updated %d event positions, removed %d dropped events, recomputed %d BPMs",
    updated, removed, bpm_recomputed))
  return updated, removed
end

local function convert_markers_native()
  -- Save time selection and loop points
  local ts_start, ts_end = reaper.GetSet_LoopTimeRange(0, 0, 0, 0, 0)
  local lp_start, lp_end = reaper.GetSet_LoopTimeRange(0, 1, 0, 0, 0)

  -- Collect BT markers sorted by position
  local our_markers = {}
  local total_markers = reaper.CountProjectMarkers(0)
  for i = 0, total_markers - 1 do
    local retval, isrgn, pos, rgnend, name = reaper.EnumProjectMarkers(i)
    if not isrgn and is_bt_marker(name) then
      our_markers[#our_markers + 1] = pos
    end
  end
  table.sort(our_markers)

  -- Convert consecutive pairs via action 40338 (set tempo from time selection)
  local converted = 0
  for i = 2, #our_markers do
    local prev_pos = our_markers[i - 1]
    local cur_pos = our_markers[i]
    if cur_pos - prev_pos > TIME_EPS then
      reaper.GetSet_LoopTimeRange(1, 0, prev_pos, cur_pos, 0)
      reaper.Main_OnCommand(40338, 0)
      converted = converted + 1
    end
  end

  -- Restore time selection and loop points
  reaper.GetSet_LoopTimeRange(1, 0, ts_start, ts_end, 0)
  reaper.GetSet_LoopTimeRange(1, 1, lp_start, lp_end, 0)

  Msg(string.format("[Conversion] Native: %d marker pairs -> tempo markers via action 40338", converted))
  return converted
end

local function convert_markers_sws()
  local cmd_id = reaper.NamedCommandLookup("_SWS_BRCONVERTMARKERSTOTEMPO")
  if cmd_id == 0 then
    show_error("SWS extension not found.\n\nInstall SWS or use 'native' or 'direct' conversion.")
    return 0
  end

  -- WARNING: SWS converts ALL project markers (not just BT ones). Log if others exist.
  local total_markers = reaper.CountProjectMarkers(0)
  local bt_count = 0
  local other_count = 0
  for i = 0, total_markers - 1 do
    local _, isrgn, _, _, name = reaper.EnumProjectMarkers(i)
    if not isrgn then
      if is_bt_marker(name) then bt_count = bt_count + 1
      else other_count = other_count + 1
      end
    end
  end

  if other_count > 0 then
    Msg(string.format("[Conversion] WARNING: SWS will convert ALL %d project markers (including %d non-BT markers)",
      bt_count + other_count, other_count))
  end

  reaper.Main_OnCommand(cmd_id, 0)
  Msg("[Conversion] SWS: _SWS_BRCONVERTMARKERSTOTEMPO executed")
  return 1
end




-- ============================================================
-- PHASE 2: CONVERT EXISTING MARKERS
-- ============================================================

local function prompt_phase2(stored_state)
  local default_conv = (stored_state and stored_state.conversion) or DEFAULT_CONVERSION

  local ok, input = reaper.GetUserInputs(
    "Extract Tempo Map — Phase 2", 2,
    "Conversion (native/sws/direct)," ..
    "Action (convert/abort):",
    default_conv .. ",convert")
  if not ok then return nil end

  local fields = {}
  for field in (input .. ","):gmatch("([^,]*),") do
    fields[#fields + 1] = trim(field)
  end

  local conv_str   = (fields[1] or ""):lower()
  local action_str = (fields[2] or ""):lower()

  if conv_str == "" then conv_str = default_conv end
  if conv_str ~= "native" and conv_str ~= "sws" and conv_str ~= "direct" then
    show_error("Invalid conversion backend.\n\nEnter 'native', 'sws', or 'direct'.")
    return nil
  end

  if action_str == "" then action_str = "convert" end
  if action_str ~= "convert" and action_str ~= "abort" then
    show_error("Invalid action.\n\nEnter 'convert' or 'abort'.")
    return nil
  end

  return {
    conversion = conv_str,
    action     = action_str,
  }
end

local function run_phase2(stored_state, bt_count)
  Msg("============================================================")
  Msg("[Phase2] Starting conversion of " .. bt_count .. " BT markers")

  -- Log stored context
  local stored_interactive_mode = (stored_state and stored_state.interactive_mode) or "map"
  if stored_state then
    Msg(string.format("[Phase2] Stored context: source=%s  detail=%s  refBPM=%s  medianBPM=%s  bpb=%s  origCount=%s  imode=%s",
      stored_state.source_type or "?",
      stored_state.detail_mode or "?",
      stored_state.reference_bpm or "?",
      stored_state.median_bpm or "?",
      stored_state.beats_per_bar or "?",
      stored_state.marker_count or "?",
      stored_interactive_mode))
  else
    Msg("[Phase2] No stored context (orphaned markers). Using defaults.")
  end

  local p2_options = prompt_phase2(stored_state)
  if not p2_options then return end

  -- Abort path: clean up everything including preview tempo map if present
  if p2_options.action == "abort" then
    reaper.Undo_BeginBlock()
    cleanup_all_bt_markers()
    -- If a preview tempo map was created (interactive=on), remove it too
    if stored_interactive_mode == "on" then
      local n = reaper.CountTempoTimeSigMarkers(0)
      for i = n - 1, 0, -1 do
        reaper.DeleteTempoTimeSigMarker(0, i)
      end
      Msg(string.format("[Phase2] Abort: cleared %d preview tempo markers", n))
    end
    clear_interactive_state()
    reaper.Undo_EndBlock("Beat This: Abort interactive mode", -1)
    Msg("[Phase2] Aborted. All BT markers removed.")
    local abort_msg = stored_interactive_mode == "on"
      and "Interactive mode aborted.\nAll BT markers and preview tempo map removed."
      or  "Interactive mode aborted.\nAll BT markers removed."
    reaper.MB(abort_msg, version .. " -- Aborted", 0)
    return
  end

  -- Read surviving markers
  local markers = read_all_bt_marker_positions()
  if #markers < 2 then
    show_error("Only " .. #markers .. " BT marker(s) found.\n\nNeed at least 2 to convert.\n\nRun Phase 1 again or abort.")
    return
  end

  -- Warn if count changed significantly
  if stored_state and stored_state.marker_count then
    local orig = tonumber(stored_state.marker_count)
    if orig and orig > 0 then
      local diff = math.abs(#markers - orig)
      if diff > orig * 0.3 then
        Msg(string.format("[Phase2] WARNING: Marker count changed significantly: %d → %d (%.0f%% change)",
          orig, #markers, (diff / orig) * 100))
      end
    end
  end

  -- Extract stored context with defaults
  local source_type   = (stored_state and stored_state.source_type) or "click"
  local detail_mode   = (stored_state and stored_state.detail_mode) or "beat"
  local reference_bpm = stored_state and tonumber(stored_state.reference_bpm)
  local median_bpm    = stored_state and tonumber(stored_state.median_bpm)
  local setup_bpm     = stored_state and tonumber(stored_state.setup_bpm)
  local beats_per_bar = (stored_state and tonumber(stored_state.beats_per_bar)) or 4

  -- Existing tempo check (overwrite/merge)
  -- If a preview map was created in Phase 1 (interactive=on), the existing tempo markers
  -- ARE the preview map — auto-overwrite them without prompting, since they're ours.
  local existing = reaper.CountTempoTimeSigMarkers(0)
  local doOverwrite = false
  if existing > 0 then
    if stored_interactive_mode == "on" then
      -- Auto-overwrite: preview map is being replaced by the final conversion
      doOverwrite = true
      Msg(string.format("[Phase2] Auto-overwriting %d preview tempo markers (interactive=on)", existing))
    else
      local choice = reaper.MB(
        string.format("%d BT markers ready to convert.\n\nProject has %d existing tempo marker(s).\n\nYES = Overwrite\nNO = Merge\nCANCEL = Cancel",
          #markers, existing),
        "Phase 2: Convert Beat Markers", 3)
      if choice == 2 then return end
      doOverwrite = (choice == 6)
    end
  end

  Msg(string.format("[Phase2] Converting: %d markers | source=%s | detail=%s | conversion=%s | overwrite=%s",
    #markers, source_type, detail_mode, p2_options.conversion, tostring(doOverwrite)))

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  -- Clear existing tempo markers if overwriting
  if doOverwrite then
    local n = reaper.CountTempoTimeSigMarkers(0)
    for i = n - 1, 0, -1 do
      reaper.DeleteTempoTimeSigMarker(0, i)
    end
    Msg(string.format("[Phase2] Cleared %d existing tempo markers", n))
  end

  -- Write time-0 setup marker (update-or-insert)
  if doOverwrite or existing == 0 then
    -- Use stored BPM if available, else derive from first marker intervals
    local s_bpm = setup_bpm or median_bpm or reference_bpm
    if not s_bpm or s_bpm <= 0 then
      if #markers >= 2 then
        local dt = markers[2] - markers[1]
        if dt > TIME_EPS then
          if detail_mode == "bar" then
            s_bpm = beats_per_bar * 60.0 / dt
          else
            s_bpm = 60.0 / dt
          end
        end
      end
      s_bpm = s_bpm or 120.0
    end

    local num, den = get_project_timesig_at(0)
    local existing_idx = -1
    local n_markers = reaper.CountTempoTimeSigMarkers(0)
    for i = 0, n_markers - 1 do
      local _, t = reaper.GetTempoTimeSigMarker(0, i)
      if t <= TIME_EPS then
        existing_idx = i
        break
      end
    end
    reaper.SetTempoTimeSigMarker(0, existing_idx, 0.0, 0, 0, s_bpm, num, den, false)
    Msg(string.format("[Phase2] Setup marker: BPM=%.3f ts=%d/%d (%s)",
      s_bpm, num, den, existing_idx >= 0 and "updated" or "inserted"))
  end

  -- Convert based on selected backend
  local mode_to_run = p2_options.conversion
  if mode_to_run == "native" and detail_mode == "beat" then
    Msg("[Conversion] WARNING: Native Action 40338 multiplies BPM by 4 for 1-beat loops. Automatically executing 'direct' mode math instead for flawless geometry.")
    mode_to_run = "direct"
  end

  if mode_to_run == "native" then
    -- Native: time selection between consecutive marker pairs + action 40338
    local ts_start, ts_end = reaper.GetSet_LoopTimeRange(0, 0, 0, 0, 0)
    local lp_start, lp_end = reaper.GetSet_LoopTimeRange(0, 1, 0, 0, 0)
    local converted = 0
    
    for i = 2, #markers do
      if markers[i] - markers[i - 1] > TIME_EPS then
        reaper.GetSet_LoopTimeRange(1, 0, markers[i - 1], markers[i], 0)
        reaper.Main_OnCommand(40338, 0)
        converted = converted + 1
      end
    end
    
    reaper.GetSet_LoopTimeRange(1, 0, ts_start, ts_end, 0)
    reaper.GetSet_LoopTimeRange(1, 1, lp_start, lp_end, 0)
    Msg(string.format("[Phase2] Native conversion: %d marker pairs processed", converted))

  elseif mode_to_run == "sws" then
    local cmd_id = reaper.NamedCommandLookup("_SWS_BRCONVERTMARKERSTOTEMPO")
    if cmd_id == 0 then
      show_error("SWS extension not found.\n\nInstall SWS or use 'native' conversion.")
      reaper.PreventUIRefresh(-1)
      reaper.Undo_EndBlock("Beat This: Phase 2 (failed)", -1)
      return
    end

    -- SWS converts ALL project markers, not just BT markers. Warn if others exist.
    local total_proj_markers = reaper.CountProjectMarkers(0)
    local other_count = 0
    for i = 0, total_proj_markers - 1 do
      local _, isrgn, _, _, name = reaper.EnumProjectMarkers(i)
      if not isrgn and not is_bt_marker(name) then
        other_count = other_count + 1
      end
    end

    if other_count > 0 then
      Msg(string.format("[Phase2] WARNING: SWS will convert ALL %d project markers (including %d non-BT markers)",
        #markers + other_count, other_count))
      local sws_choice = reaper.MB(
        string.format("WARNING: SWS converts ALL project markers, not just BT markers.\n\n" ..
          "Your project has %d non-BT markers (Verse, Chorus, etc.) that will also be converted.\n\n" ..
          "YES = Proceed with SWS conversion\n" ..
          "NO = Cancel (use 'native' conversion instead)",
          other_count),
        "SWS Warning — Non-BT Markers Found", 4)
      if sws_choice ~= 6 then
        Msg("[Phase2] SWS conversion cancelled by user due to non-BT markers")
        reaper.PreventUIRefresh(-1)
        reaper.Undo_EndBlock("Beat This: Phase 2 (cancelled)", -1)
        return
      end
    end

    reaper.Main_OnCommand(cmd_id, 0)
    Msg("[Phase2] SWS conversion executed")

  else -- direct
    -- Build events from marker positions, compute BPMs
    local events = {}
    local ref = reference_bpm or median_bpm or 120.0
    for i = 1, #markers do
      local dt = (i < #markers) and (markers[i + 1] - markers[i]) or nil
      local bpm
      if dt and dt > TIME_EPS then
        if detail_mode == "bar" then
          local dist_bars = math.max(1, math.floor((dt / (beats_per_bar * 60.0 / ref)) + 0.5))
          bpm = beats_per_bar * dist_bars * 60.0 / dt
        else
          local dist_beats = math.max(1, math.floor((dt / (60.0 / ref)) + 0.5))
          bpm = dist_beats * 60.0 / dt
        end
        bpm = clamp(bpm, MIN_BPM, MAX_BPM)
      else
        bpm = ref
      end
      events[#events + 1] = {
        time       = markers[i],
        bpm        = bpm,
        measurepos = -1,
        beatpos    = -1,
      }
    end
    -- Apply via existing function (skip clear — already done above if overwriting)
    apply_events(events, false, source_type)
    Msg(string.format("[Phase2] Direct conversion: %d events written", #events))
  end



  -- Cleanup: remove all BT markers + clear ExtState
  cleanup_all_bt_markers()
  clear_interactive_state()

  reaper.UpdateTimeline()
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Extract Tempo Map (Phase 2: Convert)", -1)

  local written = reaper.CountTempoTimeSigMarkers(0)
  local summary = string.format(
    "Phase 2 complete.\n\n" ..
    "BT markers converted: %d\n" ..
    "Tempo markers in project: %d\n" ..
    "Source type: %s\n" ..
    "Conversion: %s",
    #markers, written, source_type, p2_options.conversion)

  Msg("[Phase2] Done. " .. written .. " tempo markers.")
  reaper.MB(summary, version .. " -- Phase 2 Done", 0)
end

-- ============================================================
-- MAIN
-- ============================================================
local function main()
  local script_dir = get_script_dir()
  if not HELPER_PY then
    HELPER_PY = script_dir .. "beat_this_helper.py"
  end
  if not MIXER_PY then
    MIXER_PY = script_dir .. "audio_mix_helper.py"
  end
  if not PYTHON_EXE then
    PYTHON_EXE = find_python()
  end

  -- ====== PHASE DETECTION ======
  local bt_count = count_bt_markers()
  if bt_count > 0 then
    local stored_state = load_interactive_state()
    if stored_state then
      Msg(string.format("[PhaseDetect] Found %d BT markers + valid ExtState → Phase 2", bt_count))
      run_phase2(stored_state, bt_count)
    else
      -- Orphaned markers: BT markers exist but no stored context
      Msg(string.format("[PhaseDetect] Found %d BT markers but NO ExtState → orphaned", bt_count))
      local choice = reaper.MB(
        string.format("Found %d BT markers from a previous run, but no stored context.\n\n" ..
          "YES = Convert these markers (using defaults)\n" ..
          "NO = Clean up markers and start fresh\n" ..
          "CANCEL = Cancel",
          bt_count),
        "Orphaned Beat Markers", 3)
      if choice == 6 then
        -- Convert with nil state (defaults)
        run_phase2(nil, bt_count)
      elseif choice == 7 then
        -- Cleanup
        reaper.Undo_BeginBlock()
        cleanup_all_bt_markers()
        reaper.Undo_EndBlock("Beat This: Clean up orphaned markers", -1)
        Msg("[PhaseDetect] Orphaned markers cleaned up.")
      end
      -- choice == 2 (cancel): do nothing
    end
    return
  end

  local options = prompt_options()
  if not options then return end

  -- Resolve Python early — needed for both mixer and Beat This
  if not PYTHON_EXE then
    show_error(
      "Python not found on this system.\n\n" ..
      "Install Python 3 from python.org, ensure it is in PATH, then restart REAPER.")
    return
  end

  local selected_items = reaper.CountSelectedMediaItems(0)
  if selected_items == 0 then
    show_error("No items selected.\n\nSelect one or more audio items (drum stem, metronome, full mix).")
    return
  end

  -- Validate all selected items are audio (not MIDI, have takes)
  local all_items = {}
  for idx = 0, selected_items - 1 do
    local sel_item = reaper.GetSelectedMediaItem(0, idx)
    local sel_take = reaper.GetActiveTake(sel_item)
    if not sel_take then
      show_error(string.format("Selected item %d has no active take.", idx + 1))
      return
    end
    if reaper.TakeIsMIDI(sel_take) then
      show_error(string.format("Selected item %d is MIDI.\n\nPlease select audio items only.", idx + 1))
      return
    end
    local sel_source = reaper.GetMediaItemTake_Source(sel_take)
    local sel_path = reaper.GetMediaSourceFileName(sel_source, "")
    if not sel_path or sel_path == "" then
      show_error(string.format("Could not retrieve source file path from selected item %d.", idx + 1))
      return
    end
    all_items[#all_items + 1] = {
      item   = sel_item,
      take   = sel_take,
      source = sel_source,
      path   = sel_path,
    }
  end

  -- Multi-item merge: combine audio files for Beat This
  local merged_temp_path = nil  -- non-nil if we created a temp mix file
  local audio_path       -- the path Beat This will analyze

  if #all_items > 1 then
    -- Build filename list for dialog
    local file_list = {}
    for i, ai in ipairs(all_items) do
      file_list[#file_list + 1] = string.format("  %d. %s", i, ai.path:match("([^\\/]+)$") or ai.path)
    end
    local merge_msg = string.format(
      "%d items selected. Mix audio for combined beat detection?\n\n%s\n\n" ..
      "YES = Merge and analyze combined audio\n" ..
      "NO = Cancel",
      #all_items, table.concat(file_list, "\n"))
    local merge_choice = reaper.MB(merge_msg, version .. " -- Multi-Item Merge", 4)
    if merge_choice ~= 6 then return end

    -- Check mixer helper exists
    local mixer_check = io.open(MIXER_PY, "r")
    if not mixer_check then
      show_error("audio_mix_helper.py not found:\n" .. MIXER_PY ..
        "\n\nEnsure it is in the same folder as this script.")
      return
    end
    mixer_check:close()

    -- Build command: python audio_mix_helper.py output.wav input1 input2 ...
    local temp_dir = os.getenv("TEMP") or os.getenv("TMP") or "."
    merged_temp_path = temp_dir .. "\\bt_merged_" .. os.time() .. ".wav"
    local cmd_parts = {
      '"' .. PYTHON_EXE .. '"',
      '"' .. MIXER_PY .. '"',
      '"' .. merged_temp_path .. '"',
    }
    for _, ai in ipairs(all_items) do
      cmd_parts[#cmd_parts + 1] = '"' .. ai.path .. '"'
    end
    local cmd = table.concat(cmd_parts, " ")

    Msg("[MultiMerge] Mixing " .. #all_items .. " files...")
    Msg("[MultiMerge] Command: " .. cmd)

    local raw = reaper.ExecProcess(cmd, BEAT_THIS_TIMEOUT)
    local exit_code, output = parse_exec_result(raw)
    if output and output ~= "" then Msg("[MultiMerge] " .. output) end
    if not raw or exit_code ~= 0 or not output or not output:find("OK:", 1, true) then
      if merged_temp_path then os.remove(merged_temp_path) end
      show_error("Audio mixing failed.\n\nCheck the REAPER console for details.")
      return
    end

    audio_path = merged_temp_path
    Msg("[MultiMerge] Merged audio: " .. audio_path)
  else
    audio_path = all_items[1].path
  end

  -- Use the first selected item for all position metadata
  local item      = all_items[1].item
  local take      = all_items[1].take
  local source    = all_items[1].source
  local item_pos    = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local item_end    = item_pos + item_length
  local soffs       = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
  local source_len  = reaper.GetMediaSourceLength(source)
  source_len = tonumber(source_len) or 0.0
  local loopsrc     = reaper.GetMediaItemInfo_Value(item, "B_LOOPSRC") > 0.5
  local wraps_source = source_len > TIME_EPS and (soffs + item_length > source_len + TIME_EPS)

  Msg(string.format("[TempoMap] requested source=%s  detail=%s  setupBars=%d",
    options.source_mode, options.detail_mode, options.setup_bars))
  Msg(string.format("[TempoMap] item_pos=%.3fs  soffs=%.3fs  length=%.3fs  sourceLen=%.3fs  loopsrc=%s  wraps=%s",
    item_pos, soffs, item_length, source_len, tostring(loopsrc), tostring(wraps_source)))

  if options.source_mode == "auto" then
    local fname = string.lower(audio_path)
    if string.find(fname, "click") or string.find(fname, "metronome") then
      options.source_mode = "click"
      Msg("[TempoMap] Auto-detect: filename contained click/metronome -> assuming Click Mode.")
    end
  end

  local raw_beats = {}
  if options.source_mode == "click" then
    Msg("[BeatThis] Bypassing AI for click track. Using native transient detection.")
    reaper.PreventUIRefresh(1)
    local original_cursor = reaper.GetCursorPosition()
    reaper.SetEditCurPos(item_pos, false, false)
    
    local max_count = 10000
    local i = 0
    while reaper.GetCursorPosition() <= item_end and i < max_count do
      reaper.Main_OnCommand(40375, 0) -- Move edit cursor to next transient in items
      local t = reaper.GetCursorPosition()
      if t > item_end then break end
      if #raw_beats > 0 and math.abs(t - ((raw_beats[#raw_beats].source_time - soffs) + item_pos)) < TIME_EPS then
        break -- cursor didn't move
      end
      raw_beats[#raw_beats + 1] = { source_time = (t - item_pos) + soffs, is_downbeat = false }
      i = i + 1
    end
    
    reaper.SetEditCurPos(original_cursor, false, false)
    reaper.PreventUIRefresh(-1)
    
    if #raw_beats < 2 then
      show_error("Native transient detection found too few clicks.\n\nEnsure item has clear peaks and sensitivity is correct.")
      return
    end
    Msg(string.format("[BeatThis] Native scan complete: %d transients found.", #raw_beats))
  else
    local check = io.open(HELPER_PY, "r")
    if not check then
      show_error("beat_this_helper.py not found:\n" .. HELPER_PY ..
        "\n\nEnsure it is in the same folder as this script.")
      return
    end
    check:close()

    raw_beats = run_beat_tracker(audio_path)
  end

  -- Clean up merged temp file immediately after Beat This finishes
  if merged_temp_path then
    os.remove(merged_temp_path)
    Msg("[MultiMerge] Deleted temp file: " .. merged_temp_path)
    -- For source type resolution, use the first item's original path (not the temp mix)
    audio_path = all_items[1].path
  end

  if not raw_beats then return end

  local raw_db_count = 0
  for _, beat in ipairs(raw_beats) do
    if beat.is_downbeat then
      raw_db_count = raw_db_count + 1
    end
  end
  local raw_db_ratio = (#raw_beats > 0) and (raw_db_count / #raw_beats) or 0.0

  local source_type, source_reason = resolve_source_type(options.source_mode, audio_path, raw_db_ratio)
  local expected_bpm, expected_bpm_source = resolve_expected_bpm(options.expected_bpm, audio_path)

  -- Ghost Marker Culling (Phase-Aware Octave Illusion Fix)
  if options.cull_ghosts ~= "no" and expected_bpm and raw_beats and #raw_beats >= 2 and source_type ~= "click" then
    local median_raw = compute_median_bpm_from_beats(raw_beats)
    if median_raw then
      local ratio = median_raw / expected_bpm
      if ratio > 1.8 and ratio < 2.2 then
        -- Find which phase aligns with downbeats better
        local keep_even = false
        if raw_beats[2] and raw_beats[2].is_downbeat and not raw_beats[1].is_downbeat then
          keep_even = true
        end
        local start_idx = keep_even and 2 or 1
        Msg(string.format("[Cull] AI Octave Illusion detected (median=%.1f expected=%.1f). Culling %s ghost markers.", median_raw, expected_bpm, keep_even and "odd" or "even"))
        local culled = {}
        for i = start_idx, #raw_beats, 2 do
          culled[#culled + 1] = raw_beats[i]
        end
        raw_beats = culled
      elseif ratio > 0.45 and ratio < 0.55 then
        Msg(string.format("[Cull] AI Octave Illusion detected (median=%.1f expected=%.1f). Interpolating missing beats.", median_raw, expected_bpm))
        local inter = {}
        for i = 1, #raw_beats - 1 do
          inter[#inter + 1] = raw_beats[i]
          inter[#inter + 1] = {
            source_time = (raw_beats[i].source_time + raw_beats[i+1].source_time) / 2.0,
            is_downbeat = false
          }
        end
        inter[#inter + 1] = raw_beats[#raw_beats]
        raw_beats = inter
      end
    end
  end

  Msg(string.format("[TempoMap] sourceType=%s (%s)  expectedBPM=%s (%s)",
    source_type,
    source_reason,
    expected_bpm and string.format("%.3f", expected_bpm) or "none",
    expected_bpm_source))
  Msg(string.format("[TempoMap] snap=%s  snapWindow=%s  conversion=%s",
    options.snap_enabled and "on" or "off",
    options.snap_window and string.format("%.0fms", options.snap_window * 1000) or "auto",
    options.conversion))

  local projected_beats, projection_stats = project_beats_into_item(
    raw_beats, item_pos, item_end, soffs, source_len, loopsrc or wraps_source)
  if #projected_beats < 2 then
    Msg(string.format("[TempoMap] projection failure: usable=%d skippedPre=%d skippedPost=%d raw=%d",
      #projected_beats, projection_stats.skipped_pre, projection_stats.skipped_post, #raw_beats))
    if projection_stats.skipped_pre >= math.floor(#raw_beats * 0.8) then
      show_error(
        "Too few usable beats remain inside the selected item.\n\n" ..
        "Most beats fell before the visible item region. The item may be heavily slip-edited or wrapping the source.\n\n" ..
        "Try resetting the take start offset or fixing accidental looping, then run again.")
    else
      show_error("Too few usable beats remain inside the selected item.\n\nTry a longer item or a cleaner drum/metronome source.")
    end
    return
  end

  local beats, cleanup_stats = normalize_beats(projected_beats)
  if #beats < 2 then
    show_error("Beat cleanup removed too many detections.\n\nTry a cleaner source or use a longer selection.")
    return
  end

  local start_num, start_den = get_project_timesig_at(0)
  if options.ts_num and options.ts_den then
    start_num, start_den = options.ts_num, options.ts_den
  end
  local default_beats_per_bar = start_num
  local downbeat_stats = analyze_downbeats(beats, default_beats_per_bar)
  local global_median_bpm = compute_median_bpm_from_beats(beats, 1)
  local avg_bpm = compute_average_bpm_from_beats(beats) or global_median_bpm or reaper.Master_GetTempo()
  local reference_bpm = expected_bpm or global_median_bpm or avg_bpm

  local candidate_anchor_idx, has_candidate_downbeat = find_anchor_index(beats, downbeat_stats.reliable)
  local candidate_anchor_time = beats[candidate_anchor_idx].project_time

  local candidate_bars = derive_bar_segments(beats, candidate_anchor_idx, default_beats_per_bar, downbeat_stats.reliable)
  local use_downbeats, downbeat_reason = should_trust_downbeats(source_type, downbeat_stats, candidate_bars, reference_bpm)

  local anchor_idx, has_downbeat = find_anchor_index(beats, use_downbeats)
  local anchor_time = beats[anchor_idx].project_time
  
  -- Grid Anchor Calculation
  local target_anchor_measure = options.anchor_measure or 3
  local target_anchor_beat = options.anchor_beat or 1
  local target_measure_0idx = target_anchor_measure - 1  -- 0-indexed API
  local target_beat_0idx = target_anchor_beat - 1        -- 0-indexed API
  
  local target_grid_time = reaper.TimeMap2_beatsToTime(0, target_beat_0idx, target_measure_0idx)
  local slip_offset = target_grid_time - anchor_time
  
  if math.abs(slip_offset) > TIME_EPS then
    if options.move_items then
      reaper.Undo_BeginBlock()
      Msg(string.format("[Anchor Slip] Moving items to anchor Pos %d.%d (offset %.3fs)", target_anchor_measure, target_anchor_beat, slip_offset))
      for _, ai in ipairs(all_items) do
         local cur_pos = reaper.GetMediaItemInfo_Value(ai.item, "D_POSITION")
         reaper.SetMediaItemInfo_Value(ai.item, "D_POSITION", cur_pos + slip_offset)
      end
      for _, b in ipairs(beats) do
        b.project_time = b.project_time + slip_offset
      end
      item_pos = item_pos + slip_offset
      item_end = item_end + slip_offset
      anchor_time = target_grid_time
      reaper.Undo_EndBlock("Beat This: Anchor item slip-edit", -1)
    else
      Msg(string.format("[Anchor Slip] Move Items=Off. Grid will naturally bend backwards from anchor %.3fs. (Target Pos %d.%d effectively placed here).", anchor_time, target_anchor_measure, target_anchor_beat))
    end
  end
  
  local anchor_measure = target_measure_0idx
  local bars = derive_bar_segments(beats, anchor_idx, default_beats_per_bar, use_downbeats)

  if use_downbeats then
    Msg(string.format("[TempoMap] downbeats=trusted  ratio=%.3f  dominantSpacing=%d  share=%.3f",
      downbeat_stats.ratio,
      downbeat_stats.dominant_interval or -1,
      downbeat_stats.dominant_share))
  else
    Msg(string.format("[TempoMap] WARNING: downbeats untrusted (%s). Falling back to beat-grouped bars.", downbeat_reason))
    if not has_downbeat or not has_candidate_downbeat then
      Msg("[TempoMap] WARNING: No usable downbeat anchor remains. Using the first beat as anchor.")
    end
  end

  local effective_detail_mode = options.detail_mode
  if effective_detail_mode == "auto" then
    effective_detail_mode = use_downbeats and "bar" or "beat"
    Msg(string.format("[TempoMap] auto detail intelligently resolved to '%s' (downbeats=%s)", effective_detail_mode, tostring(use_downbeats)))
  end

  if source_type == "click" and effective_detail_mode ~= "beat" then
    effective_detail_mode = "beat"
    Msg("[TempoMap] click mode forcing beat detail to prioritize transient/grid alignment.")
  end

  if options.conversion == "auto" then
    options.conversion = "direct"
    Msg("[Conversion] auto mode resolved to mathematically flawless 'direct' engine.")
  elseif options.conversion == "native" and effective_detail_mode == "beat" then
    options.conversion = "direct"
    Msg("[Conversion] WARNING: Native Action 40338 multiplies BPM by 4 for 1-beat loops. Executing 'direct' mode math.")
  end

  local setup_bpm, used_setup_bars, used_setup_intervals =
    compute_setup_bpm_from_early_beats(beats, anchor_idx, default_beats_per_bar, options.setup_bars, reference_bpm or avg_bpm)

  if reference_bpm and setup_bpm > 0 then
    local setup_ratio = setup_bpm / reference_bpm
    if setup_ratio < 0.8 or setup_ratio > 1.2 then
      Msg(string.format("[TempoMap] WARNING: setup BPM %.3f disagrees with reference %.3f. Using reference.", setup_bpm, reference_bpm))
      setup_bpm = reference_bpm
    end
  end

  local bar_bpm_stats = sanitize_bar_bpms(bars, setup_bpm, reference_bpm)

  Msg(string.format("[TempoMap] usable beats=%d  skippedPre=%d  skippedPost=%d  removedClusters=%d",
    #beats,
    projection_stats.skipped_pre,
    projection_stats.skipped_post,
    cleanup_stats.removed_clusters))
  Msg(string.format("[TempoMap] medianBPM=%.3f  avgBPM=%.3f  referenceBPM=%s",
    global_median_bpm or 0.0,
    avg_bpm or 0.0,
    reference_bpm and string.format("%.3f", reference_bpm) or "none"))
  Msg(string.format("[TempoMap] anchorTime=%.3fs  anchorMeasure=%d  startTS=%d/%d  setupBPM=%.3f (from %d bar(s), %d beat intervals)",
    anchor_time, anchor_measure + 1, start_num, start_den, setup_bpm, used_setup_bars, used_setup_intervals))

  local existing = reaper.CountTempoTimeSigMarkers(0)
  local doOverwrite = false
  if existing > 0 then
    local msg = string.format(
      "%d beat(s) detected from audio.\n\n" ..
      "Project already has %d tempo marker(s).\n\n" ..
      "YES    = Overwrite: rebuild tempo map using the selected source reference\n" ..
      "NO     = Merge: keep existing map and add extracted markers (setup marker at 0 is skipped)\n" ..
      "CANCEL = Abort",
      #beats, existing)
    local choice = reaper.MB(msg, "Extract Tempo Map", 3)
    if choice == 2 then return end
    doOverwrite = (choice == 6)
  end

  local include_setup_marker = false
  if doOverwrite or existing == 0 then
    include_setup_marker = true
  end

  local effective_setup_bpm = setup_bpm
  local explicit_anchor = (not include_setup_marker) or (anchor_measure > 0)
  
  local target_anchor_beat = math.max(1, math.min(options.anchor_beat or 1, default_beats_per_bar))

  local events, beat_bpm_stats
  if effective_detail_mode == "bar" then
    events = build_bar_events(bars, anchor_measure, target_anchor_beat, include_setup_marker, effective_setup_bpm, explicit_anchor, source_type, start_num, start_den)
  else
    events, beat_bpm_stats = build_beat_events(beats, anchor_idx, anchor_measure, target_anchor_beat, include_setup_marker, effective_setup_bpm, avg_bpm, explicit_anchor, reference_bpm, source_type, start_num, start_den)
  end

  if #events == 0 then
    show_error("No tempo events were built from the selected item.")
    return
  end

  apply_preserved_timesigs(events)

  -- ====== INTERACTIVE PHASE 1: place markers and exit ======
  if options.interactive ~= "off" then
    local is_preview = (options.interactive == "on")
    Msg("============================================================")
    Msg(string.format("[Phase1] Interactive mode=%s", options.interactive))

    -- === Undo Block 1: Place and snap markers ===
    reaper.Undo_BeginBlock()
    reaper.PreventUIRefresh(1)

    -- Place colored temp markers (skip time-0 setup)
    local placed = place_temp_markers(events, true)

    -- Transient snap pass (if enabled)
    local snap_stats_p1 = nil
    if options.snap_enabled then
      local drop_rejected = (source_type == "click")
      snap_stats_p1 = snap_markers_to_transients(item, reference_bpm, options.snap_window, drop_rejected)
    end

    -- Count surviving markers and find first (anchor candidate)
    local surviving_count = 0
    local first_marker_pos = nil
    local total_markers = reaper.CountProjectMarkers(0)
    for i = 0, total_markers - 1 do
      local _, isrgn, pos, _, name = reaper.EnumProjectMarkers(i)
      if not isrgn and is_bt_marker(name) then
        surviving_count = surviving_count + 1
        if not first_marker_pos or pos < first_marker_pos then
          first_marker_pos = pos
        end
      end
    end

    -- Store state for Phase 2
    save_interactive_state({
      source_type    = source_type,
      detail_mode    = effective_detail_mode,
      reference_bpm  = reference_bpm or "",
      median_bpm     = global_median_bpm or "",
      setup_bpm      = effective_setup_bpm or "",
      beats_per_bar  = default_beats_per_bar,
      marker_count   = surviving_count,
      conversion     = options.conversion,
      interactive_mode = options.interactive,
    })

    -- Move edit cursor to first marker
    if first_marker_pos then
      reaper.SetEditCurPos(first_marker_pos, true, false)
    end

    reaper.UpdateTimeline()
    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock("Beat This: Place beat markers (interactive)", -1)

    -- === Undo Block 2: Preview tempo map (only for interactive=on) ===
    local do_preview = is_preview and (surviving_count >= 2)
    if do_preview and options.conversion == "sws" then
      -- SWS converts ALL project markers — check for non-BT markers before proceeding
      local total_proj_markers = reaper.CountProjectMarkers(0)
      local other_count = 0
      for i = 0, total_proj_markers - 1 do
        local _, isrgn, _, _, name = reaper.EnumProjectMarkers(i)
        if not isrgn and not is_bt_marker(name) then
          other_count = other_count + 1
        end
      end
      if other_count > 0 then
        local sws_choice = reaper.MB(
          string.format("WARNING: SWS converts ALL project markers, not just BT markers.\n\n" ..
            "Your project has %d non-BT marker(s) that will also be converted by the preview.\n\n" ..
            "YES = Proceed with SWS preview\n" ..
            "NO = Skip preview (markers placed, no tempo map)",
            other_count),
          "SWS Warning — Phase 1 Preview", 4)
        if sws_choice ~= 6 then
          do_preview = false
          Msg("[Phase1] SWS preview skipped by user due to non-BT markers")
        end
      end
    end
    if do_preview then
      Msg("[Phase1] Creating preview tempo map (separate undo block)...")
      reaper.Undo_BeginBlock()
      reaper.PreventUIRefresh(1)

      -- Read marker positions for conversion
      local preview_markers = read_all_bt_marker_positions()

      -- Clear existing tempo markers (overwrite for preview)
      local existing_tempo = reaper.CountTempoTimeSigMarkers(0)
      if existing_tempo > 0 then
        for i = existing_tempo - 1, 0, -1 do
          reaper.DeleteTempoTimeSigMarker(0, i)
        end
        Msg(string.format("[Phase1-Preview] Cleared %d existing tempo markers", existing_tempo))
      end

      -- Write time-0 setup marker
      local preview_setup_bpm = effective_setup_bpm or global_median_bpm or 120.0
      local num, den = get_project_timesig_at(0)
      local existing_idx = -1
      local n_markers = reaper.CountTempoTimeSigMarkers(0)
      for i = 0, n_markers - 1 do
        local _, t = reaper.GetTempoTimeSigMarker(0, i)
        if t <= TIME_EPS then
          existing_idx = i
          break
        end
      end
      reaper.SetTempoTimeSigMarker(0, existing_idx, 0.0, 0, 0, preview_setup_bpm, num, den, false)
      Msg(string.format("[Phase1-Preview] Setup marker: BPM=%.3f ts=%d/%d", preview_setup_bpm, num, den))

      -- Convert using the chosen backend
      local mode_to_run = options.conversion
      if mode_to_run == "native" and effective_detail_mode == "beat" then
        Msg("[Phase1-Preview] WARNING: Native Action 40338 multiplies BPM by 4 for 1-beat loops. Automatically executing 'direct' mode math instead for flawless geometry.")
        mode_to_run = "direct"
      end

      if mode_to_run == "native" then
        -- Native: time selection between consecutive marker pairs + action 40338
        local ts_start, ts_end = reaper.GetSet_LoopTimeRange(0, 0, 0, 0, 0)
        local lp_start, lp_end = reaper.GetSet_LoopTimeRange(0, 1, 0, 0, 0)
        local converted = 0
        
        for i = 2, #preview_markers do
          if preview_markers[i] - preview_markers[i - 1] > TIME_EPS then
            reaper.GetSet_LoopTimeRange(1, 0, preview_markers[i - 1], preview_markers[i], 0)
            reaper.Main_OnCommand(40338, 0)
            converted = converted + 1
          end
        end
        
        reaper.GetSet_LoopTimeRange(1, 0, ts_start, ts_end, 0)
        reaper.GetSet_LoopTimeRange(1, 1, lp_start, lp_end, 0)
        Msg(string.format("[Phase1-Preview] Native conversion: %d marker pairs", converted))

      elseif mode_to_run == "sws" then
        local cmd_id = reaper.NamedCommandLookup("_SWS_BRCONVERTMARKERSTOTEMPO")
        if cmd_id > 0 then
          reaper.Main_OnCommand(cmd_id, 0)
          Msg("[Phase1-Preview] SWS conversion executed")
        else
          Msg("[Phase1-Preview] WARNING: SWS not found, skipping preview conversion")
        end

      else -- direct
        -- Build events from marker positions
        local preview_events = {}
        local ref = reference_bpm or global_median_bpm or 120.0
        for i = 1, #preview_markers do
          local dt = (i < #preview_markers) and (preview_markers[i + 1] - preview_markers[i]) or nil
          local bpm
          if dt and dt > TIME_EPS then
            if effective_detail_mode == "bar" then
              local dist_bars = math.max(1, math.floor((dt / (default_beats_per_bar * 60.0 / ref)) + 0.5))
              bpm = default_beats_per_bar * dist_bars * 60.0 / dt
            else
              local dist_beats = math.max(1, math.floor((dt / (60.0 / ref)) + 0.5))
              bpm = dist_beats * 60.0 / dt
            end
            bpm = clamp(bpm, MIN_BPM, MAX_BPM)
          else
            bpm = ref
          end
          preview_events[#preview_events + 1] = {
            time       = preview_markers[i],
            bpm        = bpm,
            measurepos = -1,
            beatpos    = -1,
          }
        end
        apply_events(preview_events, false, source_type)
        Msg(string.format("[Phase1-Preview] Direct conversion: %d events", #preview_events))
      end



      reaper.UpdateTimeline()
      reaper.PreventUIRefresh(-1)
      reaper.Undo_EndBlock("Beat This: Preview tempo map (interactive)", -1)
      Msg("[Phase1-Preview] Preview tempo map created.")
    end

    -- Console summary
    Msg(string.format("[Phase1] Complete. %d markers placed (%d surviving after snap).",
      placed, surviving_count))
    if is_preview then
      Msg("[Phase1] Preview tempo map active. Ctrl+Z removes map; Ctrl+Z again removes markers.")
    end
    Msg("[Phase1] Inspect and edit blue BT markers, then run the script again to convert.")

    if snap_stats_p1 then
      Msg(string.format("[Phase1] Snap: %d accepted, %d rejected, %d dropped, %d unchanged",
        snap_stats_p1.accepted, snap_stats_p1.rejected, snap_stats_p1.dropped, snap_stats_p1.unchanged))
    end

    local preview_note = ""
    if is_preview then
      preview_note = "\nPreview tempo map is active.\n" ..
        "Ctrl+Z = undo tempo map (keep markers)\n" ..
        "Ctrl+Z again = undo markers\n"
    end

    reaper.MB(
      string.format("Phase 1 complete.\n\n" ..
        "%d markers placed (%d after snap).\n" ..
        "Source: %s | Detail: %s\n" ..
        "%s\n" ..
        "Inspect the blue BT markers in the timeline.\n" ..
        "Delete bad markers, then run this script again to convert.",
        placed, surviving_count, source_type, effective_detail_mode, preview_note),
      version .. " -- Phase 1 Done", 0)
    return  -- EXIT: do not convert
  end

  -- ====== PIPELINE DISPATCH (full-auto mode) ======
  local snap_stats = nil
  local conversion_used = options.conversion

  if options.snap_enabled and options.conversion ~= "direct" then
    -- ---- Marker-based pipeline: snap + native/sws conversion ----
    Msg(string.format("[Pipeline] Mode: marker-based | snap=on | conversion=%s",
      options.conversion))

    reaper.Undo_BeginBlock()
    reaper.PreventUIRefresh(1)

    -- Clear existing tempo markers if overwriting
    if doOverwrite then
      local n = reaper.CountTempoTimeSigMarkers(0)
      for i = n - 1, 0, -1 do
        reaper.DeleteTempoTimeSigMarker(0, i)
      end
      -- Debug: log post-clear state to verify REAPER behavior
      local remaining = reaper.CountTempoTimeSigMarkers(0)
      Msg(string.format("[Pipeline] Cleared %d existing tempo markers (%d remain after clear)", n, remaining))
      if remaining > 0 then
        for i = 0, remaining - 1 do
          local _, t, _, _, bpm = reaper.GetTempoTimeSigMarker(0, i)
          Msg(string.format("[Pipeline] Post-clear survivor: index=%d time=%.4fs BPM=%.3f", i, t, bpm))
        end
      end
    end

    -- Write time-0 setup marker: update-or-insert strategy
    -- After clearing, REAPER may silently re-create a default marker at time 0.
    -- Check if one exists and update in-place to avoid duplicates.
    if include_setup_marker then
      local setup_event = nil
      for _, e in ipairs(events) do
        if e.time <= TIME_EPS then
          setup_event = e
          break
        end
      end
      if setup_event then
        -- Check if a tempo marker already exists at time 0
        local existing_idx = -1
        local n_markers = reaper.CountTempoTimeSigMarkers(0)
        for i = 0, n_markers - 1 do
          local _, t = reaper.GetTempoTimeSigMarker(0, i)
          if t <= TIME_EPS then
            existing_idx = i
            break
          end
        end

        reaper.SetTempoTimeSigMarker(0, existing_idx,
          setup_event.time,
          setup_event.measurepos or -1,
          setup_event.beatpos or -1,
          setup_event.bpm,
          setup_event.ts_num or 0,
          setup_event.ts_denom or 0,
          false)
        Msg(string.format("[Pipeline] Setup marker at t=0: BPM=%.3f ts=%d/%d (%s)",
          setup_event.bpm, setup_event.ts_num or 0, setup_event.ts_denom or 0,
          existing_idx >= 0 and "updated in-place" or "inserted new"))
      end
    end

    -- Place temporary project markers (skip time-0)
    place_temp_markers(events, true)

    -- Transient snap pass (click mode: drop rejected beats, others: keep)
    local drop_rejected = (source_type == "click")
    snap_stats = snap_markers_to_transients(item, reference_bpm, options.snap_window, drop_rejected)

    -- Convert markers to tempo markers
    if options.conversion == "native" then
      convert_markers_native()
    elseif options.conversion == "sws" then
      convert_markers_sws()
    end

    -- Clean up temporary markers
    cleanup_all_bt_markers()

    reaper.UpdateTimeline()
    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock("Extract Tempo Map From Item", -1)

  elseif options.snap_enabled and options.conversion == "direct" then
    -- ---- Direct backend with transient snapping ----
    -- Snap positions via temp markers, read back, update events, then use apply_events
    Msg("[Pipeline] Mode: direct+snap")

    -- Place temp markers, snap, read back corrected positions
    reaper.PreventUIRefresh(1)
    place_temp_markers(events, true)
    local drop_rejected = (source_type == "click")
    snap_stats = snap_markers_to_transients(item, reference_bpm, options.snap_window, drop_rejected)
    local snapped_positions = read_snapped_positions()
    cleanup_all_bt_markers()
    reaper.PreventUIRefresh(-1)

    -- Update events with corrected positions and recomputed BPMs
    update_events_with_snapped_positions(events, snapped_positions, reference_bpm, source_type)

    -- Apply via existing direct path (preserves all time sig/anchor metadata)
    apply_events(events, doOverwrite, source_type)
    conversion_used = "direct+snap"

  else
    -- ---- No snap: current behavior unchanged ----
    Msg("[Pipeline] Mode: direct (no transient snap)")
    apply_events(events, doOverwrite, source_type)
    conversion_used = "direct"
  end

  -- ====== SUMMARY ======
  local summary = {
    string.format("Source type: %s", source_type),
    string.format("Detail: %s", effective_detail_mode),
    string.format("Detected beats: %d", #raw_beats),
    string.format("Usable beats: %d", #beats),
    string.format("Setup BPM: %.3f", effective_setup_bpm),
    string.format("Anchor time: %.3fs", anchor_time),
    string.format("Tempo events written: %d", reaper.CountTempoTimeSigMarkers(0)),
    string.format("Conversion: %s", conversion_used),
  }

  if effective_detail_mode == "bar" then
    summary[#summary + 1] = string.format("Large-gap bars carried: %d", bar_bpm_stats.large_gap_bars)
    summary[#summary + 1] = string.format("Out-of-range bars carried: %d", bar_bpm_stats.out_of_range_bars)
    summary[#summary + 1] = string.format("Octave-corrected bars: %d", bar_bpm_stats.octave_corrected_bars)
  else
    summary[#summary + 1] = string.format("Large-gap beats carried: %d", beat_bpm_stats.large_gap_beats)
    summary[#summary + 1] = string.format("Out-of-range beats carried: %d", beat_bpm_stats.out_of_range_beats)
  end

  if snap_stats then
    summary[#summary + 1] = string.format("Snap: %d accepted, %d rejected, %d dropped, %d unchanged",
      snap_stats.accepted, snap_stats.rejected, snap_stats.dropped, snap_stats.unchanged)
    summary[#summary + 1] = string.format("Snap delta: avg=%.1fms, max=%.1fms",
      snap_stats.avg_delta * 1000, snap_stats.max_delta * 1000)
  else
    summary[#summary + 1] = "Snap: disabled"
  end

  Msg("[TempoMap] Done.")
  for _, line in ipairs(summary) do
    Msg("[TempoMap] " .. line)
  end

  reaper.MB(
    table.concat(summary, "\n"),
    version .. " -- Done", 0)
end

main()
reaper.defer(function() end)
