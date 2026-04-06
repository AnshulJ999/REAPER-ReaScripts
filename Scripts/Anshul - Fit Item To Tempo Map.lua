--[[
@description Fit Item To Tempo Map
@author Anshul
@version 2.0
@about
  Fits a selected audio or video item to the project's tempo map via stretch markers.

  **Two modes:**

  **MODE 1 — Fixed BPM:**
  The item was recorded at one constant BPM. User enters that BPM.
  Stretch markers are placed at every project tempo-change boundary,
  scaling source positions proportionally.

  **MODE 2 — Variable Tempo Map (MIDI / CSV):**
  The item was recorded in Guitar Pro (or similar) following its own variable tempo map.
  User provides a GP MIDI export or CSV tempo file. Python parses the MIDI to extract
  per-measure timestamps. Stretch markers align each measure to the corresponding
  project measure.

  Both modes support snapping the first stretch marker to the item's first
  audio transient, eliminating video render latency/silence.

  **Requirements:**
  - Python 3.x (https://www.python.org)
  - pip install mido
  - js_ReaScriptAPI extension (install via Extensions > ReaPack)
  - Companion file: midi_tempo_parse.py (same folder as script)
@provides
midi_tempo_parse.py
@changelog
 v2.0 (2026-03-31)
   + Two-mode system: fixed BPM or variable MIDI tempo map
   + Transient snapping for render latency compensation
]]

local version = "Fit Item To Tempo Map v2.0"

-- ============================================================
-- GUARD: js_ReaScriptAPI required for file picker dialog
-- ============================================================
if not reaper.JS_Dialog_BrowseForOpenFiles then
  reaper.MB(
    "This script requires the js_ReaScriptAPI extension.\n"
    .. "Install it via Extensions > ReaPack > Browse packages.",
    "Missing Extension", 0
  )
  return
end

-- ============================================================
-- CONFIGURATION
-- ============================================================
local PYTHON_EXE    = nil
local MIDI_PARSE_PY = nil

local EXTSTATE_SECTION = "FitItemToTempoMap"

-- ============================================================
-- UTILITIES
-- ============================================================
local function Msg(s)
  reaper.ShowConsoleMsg(tostring(s) .. "\n")
end

local function show_error(msg)
  reaper.MB(msg, "Fit Item To Tempo Map -- Error", 0)
end

local function get_script_dir()
  local _, script_path = reaper.get_action_context()
  return script_path:match("^(.+[/\\])") or ""
end

local function parse_exec_result(raw)
  if not raw then return nil, "" end
  local nl = raw:find("\n")
  if nl then
    return tonumber(raw:sub(1, nl - 1)), raw:sub(nl + 1)
  end
  return tonumber(raw), ""
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

local function clear_stretch_markers(take)
  local count = reaper.GetTakeNumStretchMarkers(take)
  for i = count - 1, 0, -1 do
    reaper.DeleteTakeStretchMarker(take, i)
  end
end

-- ============================================================
-- TRANSIENT FINDER
-- ============================================================
-- Returns the time offset (in seconds) from the item's start to its first transient.
-- Uses REAPER's native transient detection action.
local function find_first_transient_offset(item)
  local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  
  -- Prevent UI jumpiness
  reaper.PreventUIRefresh(1)
  
  local cur_pos = reaper.GetCursorPosition()
  -- Move edit cursor precisely to item start
  reaper.SetEditCurPos(item_pos, false, false)
  
  -- Unselect all, then reselect just this item so the action specifically targets it
  reaper.Main_OnCommand(40289, 0) -- Item: Unselect all items
  reaper.SetMediaItemSelected(item, true)
  
  -- Action 40375: Item navigation: Move cursor to next transient in items
  reaper.Main_OnCommand(40375, 0)
  
  local trans_pos = reaper.GetCursorPosition()
  
  -- Restore original cursor position
  reaper.SetEditCurPos(cur_pos, false, false)
  reaper.PreventUIRefresh(-1)
  
  if trans_pos > item_pos and trans_pos < item_pos + item_len then
    local offset = trans_pos - item_pos
    if offset < 2.0 then -- Sanity check: if it's > 2s away, it might just be a very quiet video.
        return offset
    end
  end
  return 0
end

-- ============================================================
-- MODE 1 -- FIXED BPM
-- ============================================================
local function fit_fixed(item, take, source_bpm, snap_transient, force_anchor)
  local item_pos    = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local item_end    = item_pos + item_length
  local soffs       = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")

  local silence_pad = 0
  if snap_transient then
    silence_pad = find_first_transient_offset(item)
    if silence_pad > 0 then
      Msg(string.format("[Fixed] First transient found at +%.3fs (added as silence padding)", silence_pad))
    end
  end

  local start_time = item_pos + silence_pad
  
  -- Physically slide the item so the transient mathematically locks to the grid,
  -- perfectly preserving the 1.0x playback rate at the left/right boundaries.
  if snap_transient then
      local starting_meas = 0
      
      if force_anchor and force_anchor > 0 then
          starting_meas = force_anchor - 1
      else
          local _, curr_meas = reaper.TimeMap2_timeToBeats(0, start_time)
          local m_start = reaper.TimeMap2_beatsToTime(0, 0, curr_meas)
          local m_next  = reaper.TimeMap2_beatsToTime(0, 0, curr_meas + 1)
          starting_meas = curr_meas
          if (start_time - m_start) > (m_next - start_time) then
              starting_meas = curr_meas + 1
          end
      end
      
      if starting_meas < 0 then starting_meas = 0 end
      local anchor_proj_time = reaper.TimeMap2_beatsToTime(0, 0, starting_meas)
      
      local shift_amt = anchor_proj_time - start_time
      if math.abs(shift_amt) > 0.001 then
          item_pos = item_pos + shift_amt
          reaper.SetMediaItemInfo_Value(item, "D_POSITION", item_pos)
          item_end = item_pos + item_length
          start_time = item_pos + silence_pad
          Msg(string.format("[Fixed] Slid item position by %+.3fs to lock transient to grid", shift_amt))
      end
  end

  local segments = {}
  segments[1] = { time = start_time }

  local n = reaper.CountTempoTimeSigMarkers(0)
  for i = 0, n - 1 do
    local ok, t = reaper.GetTempoTimeSigMarker(0, i)
    if ok and t > start_time and t < item_end then
      segments[#segments + 1] = { time = t }
    end
  end

  local src_pos  = soffs + silence_pad
  local sm_count = 0

  for i, seg in ipairs(segments) do
    local seg_end = (segments[i + 1] and segments[i + 1].time) or item_end
    
    local qn_start = reaper.TimeMap2_timeToQN(0, seg.time)
    local qn_end   = reaper.TimeMap2_timeToQN(0, seg_end)
    local elapsed_qn = qn_end - qn_start
    
    -- The source audio plays at exactly `source_bpm` all the time.
    -- QN_duration * (60s / QNs per minute) = Source Audio Time in seconds
    local source_dur = elapsed_qn * (60.0 / source_bpm)
    
    local pos = seg.time - item_pos
    reaper.SetTakeStretchMarker(take, -1, pos, src_pos)
    sm_count = sm_count + 1

    src_pos = src_pos + source_dur
  end

  reaper.SetTakeStretchMarker(take, -1, item_length, src_pos)

  Msg(string.format("[Fixed] Source BPM: %.3f | Stretch markers placed: %d", source_bpm, sm_count + 1))
end

-- ============================================================
-- VARIABLE TEMPO PARSER (MIDI / CSV)
-- Run the Python helper (if MIDI) and parse the resulting CSV,
-- or directly parse a provided CSV.
-- ============================================================
local function parse_file_to_data(filepath)
  local is_midi = filepath:lower():match("%.mid$") or filepath:lower():match("%.midi$")
  local csv_path = filepath

  if is_midi then
    if not PYTHON_EXE then
      show_error("Python not found. Install Python 3 and add it to PATH to parse MIDI files.")
      return nil
    end

    local check = io.open(MIDI_PARSE_PY, "r")
    if not check then
      show_error("Python helper not found:\n" .. tostring(MIDI_PARSE_PY))
      return nil
    end
    check:close()

    local temp_csv = os.getenv("TEMP") .. "\\reaper_midi_" .. os.time() .. ".csv"
    local cmd      = string.format('"%s" "%s" "%s" "%s"', PYTHON_EXE, MIDI_PARSE_PY, filepath, temp_csv)

    Msg("[MIDI] Running parser...")
    Msg("[MIDI] " .. cmd)
    local raw = reaper.ExecProcess(cmd, 15000)
    local exit_code, out = parse_exec_result(raw)
    
    if out and out ~= "" then Msg(out) end
    if exit_code and exit_code ~= 0 then Msg(string.format("[MIDI] Process exit code: %d", exit_code)) end

    csv_path = temp_csv
  end

  local f = io.open(csv_path, "r")
  if not f then
    if is_midi then
      show_error("Python parser failed or produced no output.\nCheck console. Ensure mido is installed.")
    else
      show_error("Could not open CSV file.")
    end
    return nil
  end

  local data = {}
  local header = f:read("*l") or ""
  
  if header:match("qn_length") then
    -- Python MIDI Output Format
    for line in f:lines() do
      local meas, t, qn = line:match("(%d+),([%d%.]+),([%d%.]+)")
      if meas then
        data[#data + 1] = {
          type      = "midi",
          measure   = tonumber(meas),
          time      = tonumber(t),
          qn_length = tonumber(qn)
        }
      end
    end
  elseif header:match("Marker N%.") then
    -- Anshul - Export Tempo Map CSV Format
    for line in f:lines() do
      local count, bpm, timepos, measurepos, Beat, beatpos = line:match("([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+)")
      if count and tonumber(timepos) then
        data[#data + 1] = {
          type       = "tempo",
          timepos    = tonumber(timepos),
          measurepos = tonumber(measurepos),
          beatpos    = tonumber(beatpos)
        }
      end
    end
  else
    f:close()
    show_error("Unrecognized CSV format.")
    if is_midi then os.remove(csv_path) end
    return nil
  end

  f:close()
  if is_midi then os.remove(csv_path) end
  
  if #data == 0 then
    show_error("No valid data parsed from file.")
    return nil
  end

  return data
end

-- ============================================================
-- MODE 2 -- VARIABLE TEMPO (MIDI / CSV)
-- All work here is destructive (stretch marker placement) and runs
-- inside the caller's undo block. No early returns, no IO.
-- ============================================================
local function fit_variable(item, take, data, snap_transient, force_anchor)
  local item_pos    = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local item_end    = item_pos + item_length
  local soffs       = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")

  local silence_pad = 0
  if snap_transient then
    silence_pad = find_first_transient_offset(item)
    if silence_pad > 0 then
      Msg(string.format("[Variable] First transient found at %+.3fs (added as silence padding)", silence_pad))
    end
  end

  -- ----------------------------------------------------------
  -- 1. Determine Starting Project Measure & QN
  --    Finds the exact project measure where the first transient begins.
  --    We then calculate the exact Cumulative Quarter Note (QN) for
  --    each MIDI measure based on its own Time Signatures.
  --    This aligns video purely by relative musical time (QN), rendering
  --    it 100% immune to mismatched Time Signatures between MIDI and REAPER!
  -- ----------------------------------------------------------
  local start_time = item_pos + silence_pad
  local starting_meas = 0
  
  if force_anchor and force_anchor > 0 then
      starting_meas = force_anchor - 1
  else
      local _, curr_meas = reaper.TimeMap2_timeToBeats(0, start_time)
      local m_start = reaper.TimeMap2_beatsToTime(0, 0, curr_meas)
      local m_next  = reaper.TimeMap2_beatsToTime(0, 0, curr_meas + 1)
      starting_meas = curr_meas
      if (start_time - m_start) > (m_next - start_time) then
          starting_meas = curr_meas + 1
      end
  end
  
  if starting_meas < 0 then starting_meas = 0 end
  local anchor_proj_time = reaper.TimeMap2_beatsToTime(0, 0, starting_meas)
  
  -- Physically slide the item so the transient mathematically locks to the grid,
  -- perfectly preserving the 1.0x playback rate at the left/right boundaries.
  local shift_amt = anchor_proj_time - start_time
  if math.abs(shift_amt) > 0.001 then
      item_pos = item_pos + shift_amt
      reaper.SetMediaItemInfo_Value(item, "D_POSITION", item_pos)
      item_end = item_pos + item_length
      Msg(string.format("[Variable] Slid item position by %+.3fs to lock transient to grid", shift_amt))
  end

  local anchor_proj_qn = reaper.TimeMap2_timeToQN(0, anchor_proj_time)
  local src_pos  = soffs + silence_pad
  local sm_count = 0
  
  if data[1].type == "midi" then
      Msg(string.format("[Variable] Snapping first transient to Project Measure %d (QN %.2f)", starting_meas + 1, anchor_proj_qn))

      local midi_cumulative_qn = {}
      local current_qn = 0.0
      for i, midi_m in ipairs(data) do
          midi_cumulative_qn[i] = current_qn
          current_qn = current_qn + midi_m.qn_length
      end

      local current_idx = nil
      for i, midi_m in ipairs(data) do
          local proj_time = reaper.TimeMap2_QNToTime(0, anchor_proj_qn + midi_cumulative_qn[i])
          local pos       = proj_time - item_pos
          
          if pos > item_length then
            Msg(string.format("[Variable] Stopped at MIDI measure %d: exceeds item end.", midi_m.measure))
            current_idx = i
            break
          end

          local src_time  = src_pos + midi_m.time
          reaper.SetTakeStretchMarker(take, -1, pos, src_time)
          sm_count = sm_count + 1
      end

      if current_idx and current_idx > 1 and sm_count >= 1 then
        -- Item ended midway through this measure. Extrapolate exact rate bridging the item end.
        local last_i    = current_idx - 1
        local last_proj = reaper.TimeMap2_QNToTime(0, anchor_proj_qn + midi_cumulative_qn[last_i]) - item_pos
        local last_src  = src_pos + data[last_i].time
        
        local next_proj = reaper.TimeMap2_QNToTime(0, anchor_proj_qn + midi_cumulative_qn[current_idx]) - item_pos
        local next_src  = src_pos + data[current_idx].time
        
        local proj_diff = next_proj - last_proj
        if proj_diff > 0 then
            local src_rate  = (next_src - last_src) / proj_diff
            local term_src  = last_src + (item_length - last_proj) * src_rate
            reaper.SetTakeStretchMarker(take, -1, item_length, term_src)
            sm_count = sm_count + 1
        end
        
      elseif sm_count >= 2 then
        -- We ran out of markers before the item ended. Extrapolate using the last two parsed map points.
        local last_proj = reaper.TimeMap2_QNToTime(0, anchor_proj_qn + midi_cumulative_qn[sm_count]) - item_pos
        local last_src  = src_pos + data[sm_count].time
        local prev_proj = reaper.TimeMap2_QNToTime(0, anchor_proj_qn + midi_cumulative_qn[sm_count - 1]) - item_pos
        local prev_src  = src_pos + data[sm_count - 1].time
        
        local proj_diff = last_proj - prev_proj
        if proj_diff > 0 then
            local src_rate  = (last_src - prev_src) / proj_diff
            local term_src  = last_src + (item_length - last_proj) * src_rate
            reaper.SetTakeStretchMarker(take, -1, item_length, term_src)
            sm_count = sm_count + 1
        end
      end

      Msg(string.format("[Variable] Stretch markers placed: %d  (from %d MIDI measures)", sm_count, #data))
      
  elseif data[1].type == "tempo" then
      local first_meas_pos = data[1].measurepos
      local measure_offset = starting_meas - first_meas_pos
      
      Msg(string.format("[Variable] Snapping Marker 1 to Project Measure %d (Offset: %+d)", starting_meas + 1, measure_offset))

      local last_pos, prev_pos
      local last_src_time, prev_src_time
      local next_marker = nil

      for i, marker in ipairs(data) do
          local dest_measure = marker.measurepos + measure_offset
          local dest_time = reaper.TimeMap2_beatsToTime(0, marker.beatpos, dest_measure)
          
          local src_time = src_pos + (marker.timepos - data[1].timepos)
          local pos = dest_time - item_pos
          
          if pos > item_length then 
              next_marker = marker
              break 
          end
          
          if pos >= 0 then
              reaper.SetTakeStretchMarker(take, -1, pos, src_time)
              sm_count = sm_count + 1
              
              prev_pos = last_pos
              last_pos = pos
              prev_src_time = last_src_time
              last_src_time = src_time
          end
      end
      
      if next_marker and last_pos and sm_count >= 1 then
          -- We have a marker bridging the end of the item. Calculate exact interval rate!
          local dest_measure = next_marker.measurepos + measure_offset
          local dest_time = reaper.TimeMap2_beatsToTime(0, next_marker.beatpos, dest_measure)
          local next_pos = dest_time - item_pos
          local next_src_time = src_pos + (next_marker.timepos - data[1].timepos)
          
          local proj_diff = next_pos - last_pos
          if proj_diff > 0 then
              local src_rate = (next_src_time - last_src_time) / proj_diff
              local term_src = last_src_time + (item_length - last_pos) * src_rate
              reaper.SetTakeStretchMarker(take, -1, item_length, term_src)
              sm_count = sm_count + 1
          end
          
      elseif sm_count >= 2 and prev_pos and last_pos then
          -- We ran out of markers, extrapolate from the preceding internal interval
          local proj_diff = last_pos - prev_pos
          if proj_diff > 0 then
              local src_rate = (last_src_time - prev_src_time) / proj_diff
              local term_src = last_src_time + (item_length - last_pos) * src_rate
              reaper.SetTakeStretchMarker(take, -1, item_length, term_src)
              sm_count = sm_count + 1
          end
      end
      
      Msg(string.format("[Variable] Stretch markers placed: %d  (from %d Tempo Markers)", sm_count, #data))
  end
end

-- ============================================================
-- MAIN
-- ============================================================
local function main()
  MIDI_PARSE_PY = get_script_dir() .. "midi_tempo_parse.py"
  PYTHON_EXE    = find_python()

  local item_count = reaper.CountSelectedMediaItems(0)
  if item_count == 0 then
    show_error("No item selected.\nPlease select the tab video item(s).")
    return
  end
  
  if item_count > 1 then
    local confirm = reaper.MB(
      string.format("You have %d items selected.\n\nApply 'Fit Item to Tempo Map' to ALL of them simultaneously?", item_count),
      "Multi-Item Merge", 4)
    if confirm ~= 6 then return end
  end

  -- Restore previous settings
  local last_mode   = "2"
  local last_bpm    = tostring(reaper.Master_GetTempo())
  local last_snap   = "yes"
  local last_anchor = "0"
  
  local rv, saved_state = reaper.GetProjExtState(0, EXTSTATE_SECTION, "Settings_v2")
  if rv > 0 and saved_state ~= "" then
    local m, b, s, a = saved_state:match("([^,]+),([^,]+),([^,]+),([^,]+)")
    if m then last_mode = m end
    if b then last_bpm = b end
    if s then last_snap = s end
    if a then last_anchor = a end
  end

  local ok, inputs = reaper.GetUserInputs(
    "Fit Item To Tempo Map", 4,
    "Mode (1=Fixed, 2=Variable):,Fixed BPM (if 1):,Snap 1st Transient (y/n):,Force Anchor Meas(0=Auto):",
    string.format("%s,%s,%s,%s", last_mode, last_bpm, last_snap, last_anchor)
  )
  if not ok then return end

  local mode_str, bpm_str, snap_str, anchor_str = inputs:match("([^,]+),([^,]+),([^,]+),([^,]+)")
  local mode = tonumber(mode_str)
  if mode ~= 1 and mode ~= 2 then
    show_error("Invalid mode. Enter 1 or 2.")
    return
  end

  local source_bpm = nil
  if mode == 1 then
    source_bpm = tonumber(bpm_str)
    if not source_bpm or source_bpm <= 0 then
      show_error("Invalid BPM entered.")
      return
    end
  end

  local snap_transient = false
  if (snap_str or ""):lower():find("y") then
      snap_transient = true
  end
  
  local force_anchor = tonumber(anchor_str) or 0

  reaper.SetProjExtState(0, EXTSTATE_SECTION, "Settings_v2", inputs)

  local parsed_data = nil

  if mode == 2 then
    local initial_path = reaper.GetExtState(EXTSTATE_SECTION, "LastMidiDir")
    if not initial_path or initial_path == "" then
      initial_path = os.getenv("USERPROFILE") .. "\\Downloads"
    end

    local ok, filepath = reaper.JS_Dialog_BrowseForOpenFiles(
      "Select Source Map",
      initial_path,
      "",
      "MIDI & CSV files\0*.mid;*.midi;*.csv\0MIDI files\0*.mid;*.midi\0CSV files\0*.csv\0All files\0*.*\0\0",
      false
    )
    if ok ~= 1 or not filepath or filepath == "" then return end

    local new_dir = filepath:match("^(.+[/\\])")
    if new_dir then reaper.SetExtState(EXTSTATE_SECTION, "LastMidiDir", new_dir, true) end

    parsed_data = parse_file_to_data(filepath)
    if not parsed_data then return end
  end

  -- Pre-check if any selected item already has stretch markers
  local any_existing = false
  for i = 0, item_count - 1 do
      local item = reaper.GetSelectedMediaItem(0, i)
      local take = reaper.GetActiveTake(item)
      if take and reaper.GetTakeNumStretchMarkers(take) > 0 then
          any_existing = true
          break
      end
  end

  if any_existing then
    local confirm = reaper.MB(
      "One or more selected items already have stretch markers.\nClear and replace?",
      "Confirm", 4)
    if confirm ~= 6 then return end
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  
  -- Re-select logic inside the transient finding action can deselect other items. 
  -- We must safely iterate by saving the initial selection.
  local items = {}
  for i = 0, item_count - 1 do
      items[#items+1] = reaper.GetSelectedMediaItem(0, i)
  end

  for _, item in ipairs(items) do
      local take = reaper.GetActiveTake(item)
      if take then
          clear_stretch_markers(take)
          reaper.SetMediaItemSelected(item, true) -- ensure it's selected after potential unselections
          
          if mode == 1 then
            fit_fixed(item, take, source_bpm, snap_transient, force_anchor)
          else
            fit_variable(item, take, parsed_data, snap_transient, force_anchor)
          end
      end
  end
  
  -- Restore original full selection just in case
  reaper.Main_OnCommand(40289, 0) -- Unselect all
  for _, item in ipairs(items) do
      reaper.SetMediaItemSelected(item, true)
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.UpdateTimeline()
  reaper.Undo_EndBlock("Fit Item To Tempo Map", -1)
end

main()
reaper.defer(function() end)
