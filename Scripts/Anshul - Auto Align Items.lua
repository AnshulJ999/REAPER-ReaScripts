-- @description Auto Align Items
-- @version 1.5
-- @author Anshul
-- @about
--   Automatically aligns two audio items by their audio content using MFCC cross-correlation.
--   Best for aligning ~95%-100% similar recordings of the same source (vocals + instrumental, stem tracks, etc).
--
--   **Workflow:**
--   1. Select exactly 2 audio items
--   2. Run this script
--   3. Review detected offset and confidence score
--   4. Optionally apply Phase Alignment (native REAPER micro-alignment)
--
--   **Reference/Target Assignment:**
--   Lower track number = reference (stays put). Same track: earlier position = reference.
--
--   **Requirements:**
--   - Python 3.x (https://www.python.org)
--   - pip install audio-offset-finder
--   - FFmpeg in PATH (https://ffmpeg.org)
--   - Companion file: align_helper.py (same folder as script)
-- @provides
--   align_helper.py
-- @changelog
--   v1.5 (2026-04-06)
--     + ReaPack release formatting

-- ============================================================
-- CONFIG
-- ============================================================
local DEBUG = true          -- set false to suppress console output
local TIMEOUT_MS = 30000     -- 30 seconds for Python execution
local MAX_ANALYZE_DURATION = 180  -- max seconds of audio to analyze
local PROMPT_PHASE_ALIGN = false   -- set false to hide Phase Alignment prompt/options
local PHASE_ALIGN_ACTION = 43466  -- "Item edit: Phase alignment..."

-- Analysis tuning (controls BBC audio-offset-finder)
-- Resolution per step = HOP_LENGTH / SAMPLE_RATE seconds
--   128/8000  = 16ms (fastest)    128/16000 = 8ms (default)
--    64/16000 =  4ms (finer)       32/16000 = 2ms (slowest)
local SAMPLE_RATE = 16000    -- Hz: extraction + analysis rate
local HOP_LENGTH  = 64      -- samples: MFCC cross-correlation step size

-- Gapless compensation (encoder delay correction)
local ENABLE_MP3_COMP = true   -- MP3 without Xing/LAME header (~26ms skip)
local ENABLE_M4A_COMP = false  -- M4A edit list priming (disabled: over-corrects)

-- ============================================================
-- PATHS
-- ============================================================
local _, script_path = reaper.get_action_context()
local SCRIPT_DIR = script_path:match("^(.+[\\/])") or ""
local HELPER_PY = SCRIPT_DIR .. "align_helper.py"

-- ============================================================
-- UTILITY
-- ============================================================
local function Msg(str)
  if DEBUG then
    reaper.ShowConsoleMsg("[AutoAlign] " .. tostring(str) .. "\n")
  end
end

-- reaper.ExecProcess returns a SINGLE string: "<exit_code>\n<stdout>"
local function parse_exec_result(raw)
  if not raw then return nil, "" end
  local nl = raw:find("\n")
  if nl then
    return tonumber(raw:sub(1, nl - 1)), raw:sub(nl + 1)
  end
  return tonumber(raw), ""
end

-- ============================================================
-- FIND PYTHON (same pattern as Extract Tempo Map script)
-- ============================================================
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

-- ============================================================
-- ITEM INFO HELPERS
-- ============================================================
local function get_item_info(item)
  local take = reaper.GetActiveTake(item)
  if not take then return nil end

  local source = reaper.GetMediaItemTake_Source(take)
  if not source then return nil end

  local source_path = reaper.GetMediaSourceFileName(source, "")
  if not source_path or source_path == "" then return nil end

  local track = reaper.GetMediaItemTrack(item)
  local track_num = math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER"))

  local _, track_name = reaper.GetTrackName(track)

  local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local soffs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
  local playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")

  local filename = source_path:match("([^\\/]+)$") or source_path

  return {
    item = item,
    take = take,
    source = source,
    source_path = source_path,
    filename = filename,
    track = track,
    track_num = track_num,
    track_name = track_name,
    pos = pos,
    length = length,
    soffs = soffs,
    playrate = playrate,
  }
end

-- ============================================================
-- MAIN
-- ============================================================
local function main()
  -- Step 1: Validate selection
  local sel_count = reaper.CountSelectedMediaItems(0)
  if sel_count < 2 then
    reaper.MB(
      "Select at least 2 audio items (1 Reference, N Targets), then run this script.\n\n" ..
      "Currently selected: " .. sel_count .. " item(s).",
      "Auto Align Items", 0)
    return
  end

  -- Step 2: Validate Python
  local PYTHON_EXE = find_python()
  if not PYTHON_EXE then
    reaper.MB(
      "Python not found.\n\n" ..
      "Install Python 3.x from python.org and ensure it is in PATH.",
      "Auto Align Items — Error", 0)
    return
  end
  Msg("Python: " .. PYTHON_EXE)

  -- Step 3: Validate helper script
  local f = io.open(HELPER_PY, "r")
  if not f then
    reaper.MB(
      "align_helper.py not found.\n\n" ..
      "Expected at: " .. HELPER_PY,
      "Auto Align Items — Error", 0)
    return
  end
  f:close()

  -- Step 4: Get item info
  local items_info = {}
  for i = 0, sel_count - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    local info = get_item_info(item)
    if not info then
      reaper.MB("Item " .. i+1 .. " has no audio source.", "Auto Align Items — Error", 0)
      return
    end
    local fh = io.open(info.source_path, "rb")
    if not fh then
      reaper.MB("Source file not found:\n" .. info.source_path, "Auto Align Items — Error", 0)
      return
    end
    fh:close()
    table.insert(items_info, info)
  end

  -- Step 5: Assign reference vs targets
  -- Lowest track number = reference (stays put). Earlier position breaks ties.
  local ref_idx = 1
  for i = 2, sel_count do
    if items_info[i].track_num < items_info[ref_idx].track_num then
      ref_idx = i
    elseif items_info[i].track_num == items_info[ref_idx].track_num then
      if items_info[i].pos < items_info[ref_idx].pos then
        ref_idx = i
      end
    end
  end

  local ref = items_info[ref_idx]
  local targets = {}
  for i, inf in ipairs(items_info) do
    if i ~= ref_idx then
      table.insert(targets, inf)
    end
  end

  local anchor = targets[1]

  Msg("Reference: " .. ref.filename .. " (track " .. ref.track_num .. ", pos=" .. ref.pos .. "s)")
  if #targets == 1 then
    Msg("Target: " .. anchor.filename .. " (track " .. anchor.track_num .. ", pos=" .. anchor.pos .. "s)")
  else
    Msg("Targets: " .. #targets .. " items (Anchor: " .. anchor.filename .. ")")
  end

  -- Safety Check for Multiple Targets
  local align_individually = false
  if #targets > 1 then
    local mismatches = {}
    for i = 2, #targets do
      local t = targets[i]
      if math.abs(t.pos - anchor.pos) > 0.001 then
        table.insert(mismatches, string.format("Track %d starts at %.3fs (Anchor is %.3fs)", t.track_num, t.pos, anchor.pos))
      elseif math.abs(t.soffs - anchor.soffs) > 0.001 then
        table.insert(mismatches, string.format("Track %d padding is %.3fs (Anchor is %.3fs)", t.track_num, t.soffs, anchor.soffs))
      end
    end
    
    if #mismatches > 0 then
      local msg = "WARNING: The selected target items are not perfectly parallel/flush.\n\n" ..
                  "Differences found:\n" .. table.concat(mismatches, "\n") .. "\n\n" ..
                  "[Yes] = Align as GROUP/STEMS (mix together, move all by same offset)\n" ..
                  "[No] = Align INDIVIDUALLY (each target gets its own offset)\n" ..
                  "[Cancel] = Abort"
      local choice = reaper.MB(msg, "Auto Align — Multiple Targets", 3) -- Yes/No/Cancel
      if choice == 2 then Msg("Cancelled by user."); return end
      if choice == 7 then align_individually = true end
    end
  end

  -- ────────────────────────────────────────────────────────────────────────
  -- INDIVIDUAL ALIGNMENT MODE
  -- Each target is aligned independently to the reference.
  -- ────────────────────────────────────────────────────────────────────────
  if align_individually then
    Msg("Mode: Individual alignment (" .. #targets .. " targets)")
    local ref_extr_start = math.max(0, ref.soffs)

    local results = {}
    for i, t in ipairs(targets) do
      local t_extr = math.max(0, t.soffs)
      local max_dur = math.min(ref.length, t.length, MAX_ANALYZE_DURATION)
      if max_dur < 2 then max_dur = MAX_ANALYZE_DURATION end

      local cmd = string.format('"%s" "%s" --ref "%s" --ref-start %.6f --max-dur %.1f --target "%s" --target-start %.6f --sample-rate %d --hop-length %d',
        PYTHON_EXE, HELPER_PY, ref.source_path, ref_extr_start, max_dur, t.source_path, t_extr, SAMPLE_RATE, HOP_LENGTH)
      if ENABLE_MP3_COMP then cmd = cmd .. ' --mp3-comp' end
      if ENABLE_M4A_COMP then cmd = cmd .. ' --m4a-comp' end

      Msg(string.format("  [%d/%d] %s", i, #targets, t.filename))

      local raw = reaper.ExecProcess(cmd, TIMEOUT_MS)
      local exit_code, out = parse_exec_result(raw)

      if out and out ~= "" then
        for line in out:gmatch("[^\r\n]+") do
          if line:match("^INFO:") then
            Msg("    " .. line)
          end
        end
      end

      if exit_code and exit_code == 0 then
        local offset = tonumber(out:match("OFFSET:([%d%.%-]+)"))
        local score = tonumber(out:match("SCORE:([%d%.%-]+)")) or 0

        if offset then
          local ref_pad = ref_extr_start - ref.soffs
          local t_pad = t_extr - t.soffs
          local new_pos = ref.pos + ref_pad - t_pad + offset
          local delta = new_pos - t.pos
          table.insert(results, {target = t, offset = offset, score = score, new_pos = new_pos, delta = delta})

          local conf = score >= 10 and "HIGH" or (score >= 5 and "MED" or "LOW")
          Msg(string.format("    OFFSET:%.6f  SCORE:%.2f (%s)  delta:%+.4f", offset, score, conf, delta))
        else
          Msg("    FAILED: Could not parse offset from output")
        end
      else
        Msg("    FAILED: exit code " .. tostring(exit_code))
      end
    end

    if #results == 0 then
      reaper.MB("All individual alignments failed.", "Auto Align — Error", 0)
      return
    end

    -- Build summary dialog
    local summary = string.format("REFERENCE (Track %d):\n  %s\n\n", ref.track_num, ref.filename)
    summary = summary .. string.format("Individual Results (%d/%d succeeded):\n\n", #results, #targets)

    local any_low = false
    for _, r in ipairs(results) do
      local conf = r.score >= 10 and "HIGH" or (r.score >= 5 and "MED" or "LOW")
      if r.score < 5 then any_low = true end
      local sign = r.delta >= 0 and "+" or ""
      summary = summary .. string.format("  Track %d: %s\n    Offset: %.4fs  |  Score: %.1f (%s)  |  Move: %s%.4fs\n\n",
        r.target.track_num, r.target.filename, r.offset, r.score, conf, sign, r.delta)
    end

    if any_low then
      summary = summary .. "WARNING: Some results have LOW confidence - verify manually.\n\n"
    end

    summary = summary .. "[Yes] = Apply all offsets\n[No] = Cancel"

    local choice = reaper.MB(summary, "Auto Align — Individual Results", 4) -- Yes/No
    if choice == 7 then Msg("Cancelled."); return end

    -- Apply all individual offsets
    reaper.Undo_BeginBlock()
    for _, r in ipairs(results) do
      reaper.SetMediaItemInfo_Value(r.target.item, "D_POSITION", r.new_pos)
      local sign = r.delta >= 0 and "+" or ""
      Msg(string.format("Applied: moved %s by %s%.4fs to %.4fs", r.target.filename, sign, r.delta, r.new_pos))
    end
    reaper.UpdateArrange()
    reaper.Undo_EndBlock("Auto-align items (individual)", -1)

    if PROMPT_PHASE_ALIGN then
      reaper.Main_OnCommand(PHASE_ALIGN_ACTION, 0)
    end

    Msg("Done (individual mode).")
    return
  end

  -- Step 6: Construct Python Command
  local ref_extr_start = math.max(0, ref.soffs)
  
  local max_dur = math.min(ref.length, anchor.length, MAX_ANALYZE_DURATION)
  if max_dur < 10 then max_dur = math.min(math.max(ref.length, anchor.length), MAX_ANALYZE_DURATION) end
  if max_dur < 2 then
    reaper.MB("Items are too short to analyze (< 2 seconds).", "Auto Align Items — Error", 0)
    return
  end
  
  -- Use argparse format
  local cmd = string.format('"%s" "%s" --ref "%s" --ref-start %.6f --max-dur %.1f',
    PYTHON_EXE, HELPER_PY, ref.source_path, ref_extr_start, max_dur)
    
  for _, t in ipairs(targets) do
    local t_extr = math.max(0, t.soffs)
    cmd = cmd .. string.format(' --target "%s" --target-start %.6f', t.source_path, t_extr)
  end

  -- Analysis parameters
  cmd = cmd .. string.format(' --sample-rate %d --hop-length %d', SAMPLE_RATE, HOP_LENGTH)
  if ENABLE_MP3_COMP then cmd = cmd .. ' --mp3-comp' end
  if ENABLE_M4A_COMP then cmd = cmd .. ' --m4a-comp' end

  Msg("Command: " .. cmd)
  Msg("Running offset detection...")

  local raw = reaper.ExecProcess(cmd, TIMEOUT_MS)
  local exit_code, out = parse_exec_result(raw)

  Msg("Exit code: " .. tostring(exit_code))
  if out and out ~= "" then Msg("Output:\n" .. out) end

  -- Step 7: Parse results
  if not exit_code or exit_code ~= 0 then
    local err_msg = "Unknown error"
    if out then
      local err = out:match("ERROR:(.+)")
      if err then err_msg = err end
    end
    reaper.MB(
      "Offset detection failed.\n\n" .. err_msg,
      "Auto Align Items — Error", 0)
    return
  end

  local offset_str = out:match("OFFSET:([%d%.%-]+)")
  local score_str = out:match("SCORE:([%d%.%-]+)")

  if not offset_str then
    reaper.MB(
      "Could not parse offset from Python.\n\nRaw output:\n" .. (out or "(nil)"),
      "Auto Align Items — Error", 0)
    return
  end

  local time_offset = tonumber(offset_str)
  local score = tonumber(score_str) or 0.0

  -- Step 8: Calculate new position using Anchor
  local tar_extr_start = math.max(0, anchor.soffs)
  local ref_pad = ref_extr_start - ref.soffs
  local tar_pad = tar_extr_start - anchor.soffs
  local target_new_pos = ref.pos + ref_pad - tar_pad + time_offset
  local target_delta = target_new_pos - anchor.pos

  local ref_delta = -target_delta
  local ref_new_pos = ref.pos + ref_delta

  -- Confidence label
  local confidence_label
  if score >= 10 then
    confidence_label = "HIGH"
  elseif score >= 5 then
    confidence_label = "MEDIUM"
  else
    confidence_label = "LOW — verify manually"
  end

  -- Warnings
  local warnings = ""
  if math.abs(ref.playrate - 1.0) > 0.001 then
    warnings = warnings .. string.format("\nWARNING: Reference PLAYRATE = %.4f (not 1.0)", ref.playrate)
  end
  for _, t in ipairs(targets) do
    if math.abs(t.playrate - 1.0) > 0.001 then
      warnings = warnings .. string.format("\nWARNING: Target (Track %d) PLAYRATE = %.4f (not 1.0)", t.track_num, t.playrate)
    end
  end

  -- Step 9: Single confirmation dialog
  local target_sign = target_delta >= 0 and "+" or ""
  local ref_sign = ref_delta >= 0 and "+" or ""
  local offset_sign = time_offset >= 0 and "+" or ""
  
  local low_conf_warn = ""
  if score < 5 then low_conf_warn = "WARNING: Low confidence — files may not match.\n\n" end

  local target_text = ""
  if #targets == 1 then
    target_text = string.format("TARGET (Track %d):\n  %s\n  %s\n\n",
      anchor.track_num, anchor.track_name, anchor.filename)
  else
    target_text = string.format("TARGETS (%d items will move):\n  [Anchor] Track %d: %s\n  (+ %d other items)\n\n",
      #targets, anchor.track_num, anchor.filename, #targets - 1)
  end

  local dialog_text = string.format(
    "%s" ..
    "REFERENCE (Track %d):\n" ..
    "  %s\n" ..
    "  %s\n\n" ..
    "%s" ..
    "Offset: %s%.4fs  |  Confidence: %.1f (%s)\n" ..
    "Target Move:  %.4fs  →  %.4fs  (delta: %s%.4fs)\n" ..
    "Ref Move:     %.4fs  →  %.4fs  (delta: %s%.4fs)" ..
    "%s\n\n",
    low_conf_warn,
    ref.track_num, ref.track_name, ref.filename,
    target_text,
    offset_sign, time_offset, score, confidence_label,
    anchor.pos, target_new_pos, target_sign, target_delta,
    ref.pos, ref_new_pos, ref_sign, ref_delta,
    warnings
  )

  dialog_text = dialog_text .. "[Yes] = Apply to Target(s)\n[No] = Swap (Apply to Reference)\n[Cancel] = Abort"
  local choice = reaper.MB(dialog_text, "Auto Align — Result", 3)  -- Yes/No/Cancel
  if choice == 2 then Msg("Cancelled."); return end

  -- Step 10: Apply offset
  reaper.Undo_BeginBlock()
  
  if choice == 6 then -- Yes (Targets move)
    for _, t in ipairs(targets) do
      local new_pos = t.pos + target_delta
      reaper.SetMediaItemInfo_Value(t.item, "D_POSITION", new_pos)
    end
    if #targets == 1 then
      Msg(string.format("Applied: moved %s by %s%.4fs to %.4fs", anchor.filename, target_sign, target_delta, target_new_pos))
    else
      Msg(string.format("Applied: moved %d target items by %s%.4fs", #targets, target_sign, target_delta))
    end
  else -- No (Reference moves)
    reaper.SetMediaItemInfo_Value(ref.item, "D_POSITION", ref_new_pos)
    Msg(string.format("Applied: moved %s by %s%.4fs to %.4fs", ref.filename, ref_sign, ref_delta, ref_new_pos))
  end
  
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Auto-align items", -1)

  -- Step 11: Open Phase Alignment dialog if requested
  if PROMPT_PHASE_ALIGN then
    Msg("Opening Phase Alignment dialog (action " .. PHASE_ALIGN_ACTION .. ")...")
    reaper.Main_OnCommand(PHASE_ALIGN_ACTION, 0)
  end

  Msg("Done.")
end

-- Run
main()
