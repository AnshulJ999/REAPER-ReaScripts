-- @description Extract Tempo Map (Click Track)
-- @author Anshul
-- @version 1.0
-- @about
--   Extracts a tempo map from a perfectly-aligned click track using transient detection
--   and grid analysis. Useful for recordings that need accurate tempo mapping without
--   relying on beat detection AI.
--
--   Workflow:
--   1. Select an audio item containing a click track or metronome
--   2. Run this script
--   3. Configure anchor point, time signature, and transient detection settings
--   4. Place markers at detected transients and snap to nearest grid
--   5. Review and approve; markers are converted to the project tempo envelope
--
--   **Requirements:**
--   - SWS Extensions (for SNM transient detection functions)
--   - Python 3.x (for optional tempo normalization)
--   - beat_this or beat_net packages (optional, for advanced detection)
-- @changelog
--   v1.0 (2026-04-06)
--     + Initial release

local function Msg(str) reaper.ShowConsoleMsg(tostring(str).."\n") end
local function show_error(msg) reaper.MB(msg, "Error", 0) end

local function prompt_config(anchor_time, det_bpm)
  -- Ask REAPER mathematically what the project thinks this time is right now:
  local beats, measures, cml, fullbeats, cdenom = reaper.TimeMap2_timeToBeats(0, anchor_time)
  
  -- Round it intelligently to the nearest whole integer beat
  local nearest_beat = math.floor(beats + 1.5)
  local nearest_meas = math.floor(measures + 1)
  
  if nearest_beat > cml then 
    nearest_meas = nearest_meas + 1
    nearest_beat = 1 
  end
  
  -- Get the current Time Signature
  local ts_num, ts_den = reaper.TimeMap_GetTimeSigAtTime(0, anchor_time)
  
  local def_meas = tostring(math.floor(nearest_meas))
  local def_beat = tostring(math.floor(nearest_beat))
  local def_ts   = tostring(math.floor(ts_num)) .. "/" .. tostring(math.floor(ts_den))
  local def_bpm  = det_bpm and string.format("%.3f", det_bpm) or ""
  local def_click = reaper.HasExtState("ExtractTempoClick", "LastClick") and reaper.GetExtState("ExtractTempoClick", "LastClick") or "1/4"
  local def_move = reaper.HasExtState("ExtractTempoClick", "LastMove") and reaper.GetExtState("ExtractTempoClick", "LastMove") or "no"
  
  local mem_sens = reaper.HasExtState("ExtractTempoClick", "LastSensPct") and reaper.GetExtState("ExtractTempoClick", "LastSensPct")
  local real_sens = reaper.SNM_GetDoubleConfigVar and (reaper.SNM_GetDoubleConfigVar("transientsens", 0.5) * 100) or 50.0
  local def_sens_pct = mem_sens or string.format("%.0f", real_sens)
  
  local def_gate = reaper.HasExtState("ExtractTempoClick", "LastGate") and reaper.GetExtState("ExtractTempoClick", "LastGate") or 
                   (reaper.SNM_GetDoubleConfigVar and string.format("%.1f", reaper.SNM_GetDoubleConfigVar("transientgate", -999)) or "-24.0")
  
  local def_smooth = reaper.HasExtState("ExtractTempoClick", "LastSmooth") and reaper.GetExtState("ExtractTempoClick", "LastSmooth") or "no"
  
  local def_csv = string.format("%s,%s,%s,%s,%s,%s,%s,%s,%s", def_meas, def_beat, def_ts, def_click, def_bpm, def_move, def_sens_pct, def_gate, def_smooth)
  
  local ok, input = reaper.GetUserInputs(
    "Click Track Tempo Map", 9,
    "Target Measure,Target Beat,Time Signature,Click Rhythm (1/4 or 1/8),Expected BPM,Move Item?,Transient Sens (%),Transient Threshold (dB),Grid Smoothing (no/1/2)", 
    def_csv)
    
  if not ok then return nil end
  
  local fields = {}
  for field in (input .. ","):gmatch("([^,]*),") do
    fields[#fields + 1] = field:match("^%s*(.-)%s*$")
  end
  
  local t_meas = tonumber(fields[1])
  if not t_meas or t_meas < 1 then show_error("Invalid measure") return nil end
  
  local t_beat = tonumber(fields[2])
  if not t_beat or t_beat < 1 then show_error("Invalid beat") return nil end
  
  local parsed_num, parsed_den = fields[3]:match("^(%d+)/(%d+)$")
  parsed_num = tonumber(parsed_num)
  parsed_den = tonumber(parsed_den)
  if not parsed_num or not parsed_den then show_error("Invalid time signature (e.g. 4/4)") return nil end
  
  local click_num, click_den = fields[4]:match("^(%d+)/(%d+)$")
  local click_rhythm = 0.25
  if click_num and click_den then
    click_rhythm = tonumber(click_num) / tonumber(click_den)
  end
  if click_rhythm <= 0.0 then click_rhythm = 0.25 end
  
  local expected_bpm = tonumber(fields[5])
  
  local move_item = false
  local ms = fields[6]:lower()
  if ms == "yes" or ms == "y" or ms == "1" or ms == "on" then
    move_item = true
  end
  
  local t_sens_pct = tonumber(fields[7]) or 50
  local t_gate = tonumber(fields[8]) or -24.0
  local t_sens = t_sens_pct / 100.0  -- Convert back to 0.0-1.0 internally
  
  local t_smooth_str = (fields[9] or ""):lower()
  local t_smooth = 0
  local num_match = t_smooth_str:match("(%d+)")
  if num_match then
    t_smooth = tonumber(num_match)
  elseif t_smooth_str:match("meas") or t_smooth_str:match("bar") or t_smooth_str == "y" or t_smooth_str == "yes" then
    t_smooth = 1
  end
  
  if t_beat > parsed_num then show_error("Target Beat cannot exceed Time Signature Numerator") return nil end
  
  reaper.SetExtState("ExtractTempoClick", "LastClick", fields[4] or "1/4", true)
  reaper.SetExtState("ExtractTempoClick", "LastMove", ms, true)
  reaper.SetExtState("ExtractTempoClick", "LastSensPct", string.format("%.0f", t_sens_pct), true)
  reaper.SetExtState("ExtractTempoClick", "LastSens", tostring(t_sens), true)
  reaper.SetExtState("ExtractTempoClick", "LastGate", tostring(t_gate), true)
  reaper.SetExtState("ExtractTempoClick", "LastSmooth", fields[9] or "no", true)
  
  return {
    t_meas = t_meas,
    t_beat = t_beat,
    ts_num = parsed_num,
    ts_den = parsed_den,
    click_rhythm = click_rhythm,
    raw_click_str = fields[4],
    expected_bpm = expected_bpm,
    move_item = move_item,
    t_sens = t_sens,
    t_gate = t_gate,
    smooth_bars = t_smooth
  }
end

local function scan_transients(item, item_pos, item_end)
  local clicks = {}
  reaper.PreventUIRefresh(1)
  local orig_cursor = reaper.GetCursorPosition()
  
  -- Save selection, select only this item
  local sel_items = {}
  for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
    sel_items[i+1] = reaper.GetSelectedMediaItem(0, i)
  end
  reaper.Main_OnCommand(40289, 0) -- Item: Unselect all items
  reaper.SetMediaItemSelected(item, true)
  
  reaper.SetEditCurPos(item_pos - 0.01, false, false)
  
  local prev_t = -1
  local max_count = 10000
  local count = 0
  
  while count < max_count do
    reaper.Main_OnCommand(40375, 0) -- Move cursor to next transient
    local t = reaper.GetCursorPosition()
    if t >= item_end - 0.002 or math.abs(t - prev_t) < 0.0001 then break end
    
    if t >= item_pos - 0.002 then
      -- Filter out double-transients (min 100ms gap = max 600 BPM)
      if #clicks == 0 or (t - clicks[#clicks]) > 0.1 then
        clicks[#clicks + 1] = t
      end
    end
    
    prev_t = t
    count = count + 1
  end
  
  -- Restore selection
  reaper.Main_OnCommand(40289, 0)
  for _, sel in ipairs(sel_items) do
    if reaper.ValidatePtr(sel, "MediaItem*") then reaper.SetMediaItemSelected(sel, true) end
  end
  
  reaper.SetEditCurPos(orig_cursor, false, false)
  reaper.PreventUIRefresh(-1)
  return clicks
end

local function get_median_gap(clicks)
  if #clicks < 2 then return 0.5 end
  local gaps = {}
  for i = 1, #clicks - 1 do
    gaps[#gaps + 1] = clicks[i+1] - clicks[i]
  end
  table.sort(gaps)
  return gaps[math.ceil(#gaps/2)]
end

local function apply_partial_measure_flag(time)
  local count = reaper.CountTempoTimeSigMarkers(0)
  for i = 0, count - 1 do
    local _, t = reaper.GetTempoTimeSigMarker(0, i)
    if math.abs(t - time) < 0.001 then
      local flags = reaper.GetSetTempoTimeSigMarkerFlag(0, i, 0, false)
      reaper.GetSetTempoTimeSigMarkerFlag(0, i, flags | 1 | 4, true)
      break
    end
  end
end

local function main()
  local sel_items = reaper.CountSelectedMediaItems(0)
  if sel_items ~= 1 then
    show_error("Please select exactly one audio item (the click track).")
    return
  end
  local item = reaper.GetSelectedMediaItem(0, 0)
  
  local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  
  local old_sens = reaper.SNM_GetDoubleConfigVar and reaper.SNM_GetDoubleConfigVar("transientsens", 0.5)
  local old_gate = reaper.SNM_GetDoubleConfigVar and reaper.SNM_GetDoubleConfigVar("transientgate", -24.0)
  
  local pre_sens = tonumber(reaper.GetExtState("ExtractTempoClick", "LastSens")) or old_sens or 0.5
  local pre_gate = tonumber(reaper.GetExtState("ExtractTempoClick", "LastGate")) or old_gate or -24.0
  
  if reaper.SNM_SetDoubleConfigVar then
    reaper.SNM_SetDoubleConfigVar("transientsens", pre_sens)
    reaper.SNM_SetDoubleConfigVar("transientgate", pre_gate)
  end
  
  local clicks = scan_transients(item, item_pos, item_pos + item_len)
  
  if #clicks < 2 then
    if reaper.SNM_SetDoubleConfigVar then
      reaper.SNM_SetDoubleConfigVar("transientsens", old_sens)
      reaper.SNM_SetDoubleConfigVar("transientgate", old_gate)
    end
    show_error("Found fewer than 2 clicks inside the item bounds.")
    return
  end
  
  local median_gap = get_median_gap(clicks)
  local intro_gap = (#clicks >= 4) and get_median_gap({clicks[1], clicks[2], clicks[3], clicks[4]}) or median_gap
  local detected_bpm = 60 / intro_gap
  
  local opts = prompt_config(clicks[1], detected_bpm)
  if not opts then 
    if reaper.SNM_SetDoubleConfigVar then
      reaper.SNM_SetDoubleConfigVar("transientsens", old_sens)
      reaper.SNM_SetDoubleConfigVar("transientgate", old_gate)
    end
    return 
  end
  
  if math.abs(opts.t_sens - pre_sens) > 0.01 or math.abs(opts.t_gate - pre_gate) > 0.1 then
    if reaper.SNM_SetDoubleConfigVar then
      reaper.SNM_SetDoubleConfigVar("transientsens", opts.t_sens)
      reaper.SNM_SetDoubleConfigVar("transientgate", opts.t_gate)
    end
    clicks = scan_transients(item, item_pos, item_pos + item_len)
    
    if #clicks < 2 then
      if reaper.SNM_SetDoubleConfigVar then
        reaper.SNM_SetDoubleConfigVar("transientsens", old_sens)
        reaper.SNM_SetDoubleConfigVar("transientgate", old_gate)
      end
      show_error("Found fewer than 2 clicks with the new transient settings.")
      return
    end
    median_gap = get_median_gap(clicks)
    intro_gap = (#clicks >= 4) and get_median_gap({clicks[1], clicks[2], clicks[3], clicks[4]}) or median_gap
    detected_bpm = 60 / intro_gap
  end
  
  -- Restore original transient settings immediately before math mapping
  if reaper.SNM_SetDoubleConfigVar then
    reaper.SNM_SetDoubleConfigVar("transientsens", old_sens)
    reaper.SNM_SetDoubleConfigVar("transientgate", old_gate)
  end
  
  local assumed_bpm = opts.expected_bpm or detected_bpm
  local beat_len = 60 / assumed_bpm
  
  local take = reaper.GetActiveTake(item)
  local src = take and reaper.GetMediaItemTake_Source(take)
  local filename = src and reaper.GetMediaSourceFileName(src, "") or "Unknown"
  local basename = filename:match("([^/\\]+)$") or filename
  
  Msg(string.format("----- Click Track Tempo Mapping -----"))
  Msg(string.format("Target File: %s", basename))
  Msg(string.format("Scanner Config: Threshold: %.1fdB | Sensitivity: %.0f%%", opts.t_gate, opts.t_sens * 100))
  Msg(string.format("Item Start: %.3fs. Length: %.3fs", item_pos, item_len))
  Msg(string.format("Detected %d total clicks. Anchor Click: %.4fs", #clicks, clicks[1]))
  Msg(string.format("Micro-Median Intro Gap: %.4fs -> Detected BPM: %.3f", intro_gap, detected_bpm))
  Msg(string.format("User Target: Measure %d, Beat %d, TimeSig %d/%d", opts.t_meas, opts.t_beat, opts.ts_num, opts.ts_den))
  
  if opts.ts_den ~= 4 or opts.click_rhythm ~= 0.25 then
    Msg(string.format("Assumed internal clicks: %.3f/min (Scaled for REAPER at %s = %.3f BPM)", assumed_bpm, opts.raw_click_str, assumed_bpm * (opts.click_rhythm / 0.25)))
  else
    Msg(string.format("Assumed BPM lock: %.3f", assumed_bpm))
  end
  Msg(string.format("Move Item? %s", tostring(opts.move_item)))
  
  local denominator_value = 1.0 / opts.ts_den
  local beats_per_click = opts.click_rhythm / denominator_value
  
  local anchor_time = clicks[1]
  local t_meas0 = opts.t_meas - 1
  local t_beat0 = opts.t_beat - 1
  local t_beat0_clicks = t_beat0 / beats_per_click
  
  local function get_api_bpm(bpm)
    return bpm * (opts.click_rhythm / 0.25)
  end
  
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  
  -- Clear existing map
  local count = reaper.CountTempoTimeSigMarkers(0)
  for i = count - 1, 0, -1 do
    reaper.DeleteTempoTimeSigMarker(0, i)
  end
  
  local final_anchor_time = anchor_time
  local t_measure_start = nil
  
  if opts.move_item then
    -- Grid remains uniform, mathematically offset the item physically
    reaper.SetTempoTimeSigMarker(0, -1, 0.0, 0, 0, get_api_bpm(assumed_bpm), opts.ts_num, opts.ts_den, false)
    local target_grid_time = ((t_meas0 * (opts.ts_num / beats_per_click)) + t_beat0_clicks) * (60 / assumed_bpm)
    local slip = target_grid_time - anchor_time
    reaper.SetMediaItemInfo_Value(item, "D_POSITION", item_pos + slip)
    for i=1, #clicks do clicks[i] = clicks[i] + slip end
    final_anchor_time = clicks[1]
    Msg(string.format("[ClickMap] Item moved by %.3fs to intercept rigid grid.", slip))
  else
    -- Bend the grid to the item
    local denom_len_seconds = beat_len / beats_per_click
    t_measure_start = anchor_time - (t_beat0 * denom_len_seconds)
    
    if t_measure_start > 0.0 then
      if t_meas0 > 0 then
        -- Backward Projection Bridge
        local setup_beats = t_meas0 * opts.ts_num
        local setup_clicks = setup_beats / beats_per_click
        local setup_bpm = (setup_clicks / t_measure_start) * 60
        
        if get_api_bpm(setup_bpm) < 20 or get_api_bpm(setup_bpm) > 300 then
          -- Setup BPM is crazy, fallback to Partial Measure flag
          Msg("[ClickMap] Setup bridge requires insane " .. math.floor(get_api_bpm(setup_bpm)) .. " (REAPER) BPM. Falling back to partial measure flag.")
          reaper.SetTempoTimeSigMarker(0, -1, 0.0, 0, 0, get_api_bpm(assumed_bpm), opts.ts_num, opts.ts_den, false)
          reaper.SetTempoTimeSigMarker(0, -1, t_measure_start, t_meas0, 0, get_api_bpm(assumed_bpm), opts.ts_num, opts.ts_den, false)
          apply_partial_measure_flag(t_measure_start)
        else
          reaper.SetTempoTimeSigMarker(0, -1, 0.0, 0, 0, get_api_bpm(setup_bpm), opts.ts_num, opts.ts_den, false)
          reaper.SetTempoTimeSigMarker(0, -1, t_measure_start, t_meas0, 0, get_api_bpm(assumed_bpm), opts.ts_num, opts.ts_den, false)
          Msg(string.format("[ClickMap] Bridging 0.0s to %.3fs seamlessly at %.1f BPM.", t_measure_start, get_api_bpm(setup_bpm)))
        end
      else
        -- Target Measure is 1, so t_measure_start dictates a gap from 0.0s to M1 B1.
        reaper.SetTempoTimeSigMarker(0, -1, 0.0, 0, 0, get_api_bpm(assumed_bpm), opts.ts_num, opts.ts_den, false)
        reaper.SetTempoTimeSigMarker(0, -1, t_measure_start, t_meas0, 0, get_api_bpm(assumed_bpm), opts.ts_num, opts.ts_den, false)
        apply_partial_measure_flag(t_measure_start)
        Msg(string.format("[ClickMap] Absorbing %.3fs gap into a partial measure.", t_measure_start))
      end
    else
      -- t_measure_start <= 0.0
      -- Anchor conceptually requires Measure 1 to occur before or exactly at 0.0s
      reaper.SetTempoTimeSigMarker(0, -1, 0.0, t_meas0, 0, get_api_bpm(assumed_bpm), opts.ts_num, opts.ts_den, false)
      apply_partial_measure_flag(0.0)
      Msg(string.format("[ClickMap] Anchor projects negative time (%.3fs). Absorbing gap with explicit partial measure flag at 0.0.", t_measure_start))
    end
  end
  
  -- Lay down individual clicks
  local added_markers = 0
  local running_gap = intro_gap
  local anomalies = 0
  local max_bpm = 0
  local min_bpm = 999
  
  local accum_dt = 0
  local accum_grid_beats = 0
  local accum_clicks = 0
  local last_marker_time = clicks[1]
  local smoothing_target_beats = opts.smooth_bars > 0 and (opts.smooth_bars * opts.ts_num) or 0
  
  local function place_marker(time, marker_bpm)
    local api_bpm = get_api_bpm(marker_bpm)
    local found_dup = false
    if not opts.move_item and t_measure_start and math.abs(time - t_measure_start) < 0.005 then
      local n = reaper.CountTempoTimeSigMarkers(0)
      for j = 0, n - 1 do
        local _, t, mpos, bpos, _, num, den, lin = reaper.GetTempoTimeSigMarker(0, j)
        if math.abs(t - time) < 0.005 then
          reaper.SetTempoTimeSigMarker(0, j, time, mpos, bpos, api_bpm, num, den, lin)
          found_dup = true
          break
        end
      end
    end
    
    if not found_dup then
      reaper.SetTempoTimeSigMarker(0, -1, time, -1, -1, api_bpm, 0, 0, false)
    end
    added_markers = added_markers + 1
  end
  
  for i = 1, #clicks - 1 do
    local dt = clicks[i+1] - clicks[i]
    local ratio = dt / running_gap
    local beats = math.floor(ratio + 0.5)
    if beats < 1 then beats = 1 end
    
    local bpm = (beats * 60) / dt
    if bpm > 400 then bpm = 400 end
    if bpm < 20 then bpm = 20 end
    
    if beats > 1 or math.abs(bpm - assumed_bpm) > 2.0 then
       anomalies = anomalies + 1
    end
    if bpm > max_bpm then max_bpm = bpm end
    if bpm < min_bpm then min_bpm = bpm end
    
    -- Smooth running gap progressively ONLY if the beat was completely uniform (no dropped clicks)
    if beats == 1 then
      running_gap = (running_gap * 0.7) + (dt * 0.3)
    end
    
    if opts.smooth_bars > 0 then
      accum_dt = accum_dt + dt
      accum_clicks = accum_clicks + beats
      accum_grid_beats = accum_grid_beats + (beats * beats_per_click)
      
      if accum_grid_beats >= smoothing_target_beats or i == #clicks - 1 then
        local avg_bpm = (accum_clicks * 60) / accum_dt
        if avg_bpm > 400 then avg_bpm = 400 end
        if avg_bpm < 20 then avg_bpm = 20 end
        place_marker(last_marker_time, avg_bpm)
        
        last_marker_time = clicks[i+1]
        accum_dt = 0
        accum_clicks = 0
        accum_grid_beats = accum_grid_beats - smoothing_target_beats
      end
    else
      -- Regular per-click marker
      place_marker(clicks[i], bpm)
    end
  end
  
  reaper.PreventUIRefresh(-1)
  reaper.UpdateTimeline()
  reaper.Undo_EndBlock("Extract Tempo Map (Click Track)", -1)
  Msg(string.format("----- SUMMARY -----"))
  Msg(string.format("Mapped %d clicks successfully.", added_markers))
  if anomalies > 0 then
    Msg(string.format("Corrected %d transient jitters/deviations.", anomalies))
    Msg(string.format("BPM Boundary: %.1f to %.1f", get_api_bpm(min_bpm), get_api_bpm(max_bpm)))
  else
    Msg(string.format("Grid perfectly locked to %.1f BPM.", get_api_bpm(assumed_bpm)))
  end
end

reaper.ClearConsole()
Msg("Starting Click Track Tempo Mapping...")
main()
