-- @description Command Center Tools GUI
-- @author Anshul
-- @version 1.8
-- @about
--   Floating control panel for quick access to custom REAPER scripts and community tools.
--   Features a button grid organized by sections, live project info strip, and customizable
--   button layout via cc_buttons.json.
--
--   **Button Types:**
--   - Personal scripts (Anshul's custom scripts in Scripts folder)
--   - Community scripts (Reference folder scripts)
--   - REAPER native actions (workflow actions like Phase Alignment)
--   - Workflow utilities (imported from elsewhere)
--
--   **Requirements:**
--   - ReaImGui extension (install via Extensions > ReaPack)
--   - Companion file: json.lua (same folder as script)
--   - Optional: cc_buttons.json for button customization
-- @provides
--   json.lua
-- @changelog
--   v1.8
--     + Auto-detect scripts in same folder
--   v1.7 (2026-03-31)
--     + Finalized for ReaPack release

-- ============================================================================
-- DEPENDENCY CHECK
-- ============================================================================
if not reaper.ImGui_GetBuiltinPath then
  reaper.MB("ReaImGui is required.\nInstall via Extensions > ReaPack > Browse Packages.", "Command Center", 0)
  return
end

-- ============================================================================
-- IMGUI MODULE
-- ============================================================================
package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.10'

-- Declared here (before ALL functions) so every closure captures the same upvalue.
-- Bug if declared later: functions defined before the local see global ctx (nil).
local ctx, font
local TOOLBAR_SEC, TOOLBAR_CMD   -- set in Init(); used for toolbar toggle highlight

-- ============================================================================
-- PATHS
-- ============================================================================
local SEP         = package.config:sub(1, 1)
local _script_path = ({reaper.get_action_context()})[2]
local BASE_DIR    = _script_path:match("^(.*[/\\])")
local SELF_NAME   = (_script_path:match("[^/\\]+$") or ""):lower()
local REF_DIR     = BASE_DIR .. ".." .. SEP .. "Reference" .. SEP
local USER_DIR    = reaper.GetResourcePath():gsub("\\", "/") .. "/Scripts/"

-- JSON library (json.lua lives alongside this script)
-- Append BASE_DIR to package.path so require('json') finds it.
package.path = package.path .. ';' .. BASE_DIR:gsub('\\', '/') .. '?.lua'
local json_ok, json = pcall(require, 'json')
if not json_ok then
  reaper.ShowConsoleMsg("[Command Center] Warning: json.lua not found — cc_buttons.json disabled.\n")
  json = nil
end

-- ============================================================================
-- CONSTANTS
-- ============================================================================
local SCRIPT_NAME = "Anshul Command Center"
local WIN_ID      = "Tools###AnshulCommandCenter"  -- stable ImGui ID; display title = "Tools"
local EXT_SECTION = "AnshulCommandCenter"          -- ExtState namespace (never changes)
local DEFAULT_W   = 660
local DEFAULT_H   = 540
local INFO_H      = 72    -- fixed height of the 3-row info strip at bottom
local MIN_BTN_W   = 145   -- minimum button width for adaptive column count

-- ============================================================================
-- BUTTON DATA  (built-in default layout — overridden by cc_buttons.json if present)
-- ============================================================================
-- SECTIONS: visual groups rendered in order as SeparatorText headers.
local SECTIONS = {
  { id = "default", label = "Default" },
}

-- BUTTONS: each entry targets one section.
--   script    = filename relative to BASE_DIR    (script in same folder as CC)
--   user      = path relative to USER_DIR        (any script in REAPER Scripts folder)
--   ref       = filename inside REF_DIR          (community Reference folder scripts)
--   path      = absolute path                    (anything else)
--   action_id = integer or named command ID      (native REAPER action)
--   tooltip   = hover text
local BUTTONS = {

  { sec="default", label="ReaDashboard",
    user   ="Anshul-ReaScripts/ReaDashboard/Anshul_ReaDashboard.lua",
    tooltip="Modern project browser for REAPER — browse, search, filter, and manage all your projects" },

  { sec="default", label="Extract Tempo Map (Audio)",
    script ="Anshul - Extract Tempo Map From Item.lua",
    tooltip="Run Beat This! on the selected audio item to build the project tempo map" },

  { sec="default", label="Extract Tempo Map (Click)",
    script ="Anshul - Extract Tempo Map (Click Track).lua",
    tooltip="Fast transient grid anchoring for click tracks (mathematically rigorous)" },

  { sec="default", label="Export Tempo Map",
    script ="Anshul - Export Tempo Map.lua",
    tooltip="Save the current project tempo map to a CSV file" },

  { sec="default", label="Import Tempo Map",
    script ="Anshul - Import Tempo Map.lua",
    tooltip="Load a tempo map from a CSV file into the current project" },

  { sec="default", label="Fit Item to Tempo Map",
    script ="Anshul - Fit Item To Tempo Map.lua",
    tooltip="Place stretch markers on a video/audio item to match the project tempo map" },

  { sec="default", label="Delete Tempo Markers",
    script ="Anshul - Delete All Tempo Map Markers.eel",
    tooltip="Delete all tempo map markers from the current project" },

  { sec="default", label="Import Moises Stems",
    script ="Anshul - Import Moises Stems (ZIP).lua",
    tooltip="Pick a ZIP archive or audio file to extract and import Moises stems into the project" },

  { sec="default", label="Auto Align Items",
    script ="Anshul - Auto Align Items.lua",
    tooltip="MFCC cross-correlation time alignment for selected items (best for similar audio)" },
}

-- Resolve ref → path (REF_DIR is now known). Extracted as a function so both
-- the hardcoded table and any JSON-loaded table can use it.
local function resolve_refs(buttons)
  for _, btn in ipairs(buttons) do
    if btn.ref then
      btn.path = REF_DIR .. btn.ref
    elseif btn.user then
      btn.path = USER_DIR .. btn.user
    end
  end
end

resolve_refs(BUTTONS)

-- ============================================================================
-- AUTO-DETECT SCRIPTS
-- Scans BASE_DIR for any .lua/.eel not already in the hardcoded BUTTONS table
-- and appends them to the Default section. Reads @description from each file
-- header for the tooltip. Only meaningful on fresh installs (no cc_buttons.json);
-- if cc_buttons.json exists, LoadButtons() overrides BUTTONS entirely anyway.
-- ============================================================================
local function ScanBuiltinButtons()
  -- Build a set of filenames already explicitly hardcoded (lowercased)
  local covered = {}
  for _, btn in ipairs(BUTTONS) do
    if btn.script then covered[btn.script:lower()] = true end
  end
  covered[SELF_NAME]  = true   -- the CC script itself
  covered["json.lua"] = true   -- JSON helper library

  local idx = 0
  repeat
    local fname = reaper.EnumerateFiles(BASE_DIR, idx)
    if fname then
      local ext = fname:match("%.([^%.]+)$")
      if ext and (ext:lower() == "lua" or ext:lower() == "eel") then
        if not covered[fname:lower()] then
          -- Read @description from file header (first 1 KB) for tooltip
          local tip = nil
          local fh = io.open((BASE_DIR .. fname):gsub("/", SEP), "r")
          if fh then
            local head = fh:read(1024)
            fh:close()
            if head then
              tip = head:match("@description%s+([^\r\n]+)")
              if tip then tip = tip:match("^%s*(.-)%s*$") end  -- trim
            end
          end
          -- Derive button label: strip leading "Anshul - " prefix and file extension
          local label = fname:match("^(.+)%.[^%.]+$") or fname
          label = label:gsub("^Anshul%s*%-%s*", "")
          BUTTONS[#BUTTONS + 1] = {
            sec     = "default",
            label   = label,
            script  = fname,
            tooltip = tip or nil,
          }
        end
      end
    end
    idx = idx + 1
  until not fname
end

ScanBuiltinButtons()

-- ============================================================================
-- JSON LAYOUT LOADER
-- Reads cc_buttons.json next to this script and overwrites SECTIONS/BUTTONS.
-- Falls back silently to the hardcoded tables if file is missing or corrupt.
-- ============================================================================
local function LoadButtons()
  if not json then return end

  local path = BASE_DIR .. "cc_buttons.json"
  local f = io.open(path, "r")
  if not f then return end   -- no file → keep hardcoded defaults

  local text = f:read("*a")
  f:close()

  local ok, data = pcall(json.decode, text)
  if not ok or type(data) ~= "table" then
    reaper.ShowConsoleMsg("[Command Center] cc_buttons.json parse error — using built-in defaults.\n")
    return
  end

  -- Load sections (only replace if JSON has at least one valid entry)
  if type(data.sections) == "table" and #data.sections > 0 then
    for i = #SECTIONS, 1, -1 do SECTIONS[i] = nil end
    for _, sec in ipairs(data.sections) do
      if type(sec.id) == "string" and type(sec.label) == "string" then
        SECTIONS[#SECTIONS + 1] = { id = sec.id, label = sec.label }
      end
    end
  end

  -- Load buttons (only replace if JSON has at least one valid entry)
  if type(data.buttons) == "table" and #data.buttons > 0 then
    for i = #BUTTONS, 1, -1 do BUTTONS[i] = nil end
    for _, btn in ipairs(data.buttons) do
      if type(btn.label) == "string" and type(btn.sec) == "string" then
        local entry = {
          sec     = btn.sec,
          label   = btn.label,
          tooltip = type(btn.tooltip) == "string" and btn.tooltip or nil,
        }
        if type(btn.script)    == "string" then entry.script    = btn.script    end
        if type(btn.user)      == "string" then entry.user      = btn.user      end
        if type(btn.ref)       == "string" then entry.ref       = btn.ref       end
        if type(btn.path)      == "string" then entry.path      = btn.path      end
        if type(btn.action_id) == "number" or type(btn.action_id) == "string" then entry.action_id = btn.action_id end
        BUTTONS[#BUTTONS + 1] = entry
      end
    end
    resolve_refs(BUTTONS)   -- resolve any ref → path entries loaded from JSON
  end
end

-- ============================================================================
-- STATE  (S table — all mutable state, uses ONE local slot to dodge 200-limit)
-- ============================================================================
local S = {
  -- Editor state
  edit_mode          = false,
  editor_dirty       = false,
  editor_last_change = 0,
  last_browse_dir    = BASE_DIR,

  -- Window
  window_open  = true,
  frame_count  = 0,
  win_w        = DEFAULT_W,
  win_h        = DEFAULT_H,
  win_x        = -1,    -- -1 = not yet saved; let ImGui pick initial position
  win_y        = -1,

  -- Appearance (persisted)
  font_size      = 14,
  btn_h          = 55,    -- large button height
  prefer_cols    = 4,     -- max adaptive column count
  min_cols       = 1,     -- min adaptive column count
  bg_brightness  = 0.0,   -- 0.0 (current dark) – 1.0 (lighter backgrounds)
  btn_rounding   = 4,     -- 0–12 corner rounding for buttons/frames
  opacity        = 1.0,   -- 0.3–1.0 surface alpha (text always stays opaque)
  btn_text_left  = false, -- false = centered, true = left-aligned

  -- Accent colour stored as 0–255 integers (persisted)
  accent_r     = 74,
  accent_g     = 158,
  accent_b     = 255,

  -- Window behaviour (persisted)
  allow_docking    = false,
  topmost          = false,
  close_on_unfocus = false,  -- close when REAPER UI regains focus
  close_on_escape  = false,  -- close when Escape is pressed while focused
  open_at_cursor   = false,  -- teleport window to mouse cursor on each open (default OFF)
  hide_missing     = false,  -- hide buttons whose script file is not found

  -- Layout (persisted)
  show_info_strip   = true,
  show_section_hdrs = true,
  show_tooltips     = true,

  -- Runtime only (never persisted)
  had_focus = false,   -- guard: only trigger close-on-unfocus after first focus
  is_dirty  = false,   -- true when any persisted value changed → SaveState needed

  -- Data paths (persisted)
  tags_json_path = "G:/GitHub/Personal-Stuff/ReaLauncher/project-tags.json",

  -- Info strip cache (runtime only — not persisted)
  info_item    = "No item selected",
  info_tempo   = "No tempo markers",
  info_proj    = "No project open",
  info_tick    = 0,
  cached_proj  = "",    -- last proj_path for which tags were read
  cached_tags  = nil,   -- parsed tag table for current project
}

local ED = {
  open_btn_idx  = -1,   -- global BUTTONS index of open form (-1 = none)
  open_sec_idx  = -1,   -- SECTIONS index of open rename (-1 = none)
  buf_label     = "",
  buf_tooltip   = "",
  buf_path      = "",
  buf_sec       = "",
  buf_type      = 1,    -- 1=script, 2=ref, 3=path, 4=action_id
  buf_sec_label = "",
  new_sec_open  = false,
  buf_new_sec   = "",
  snap_sections = nil,
  snap_buttons  = nil,
}

-- ============================================================================
-- THEME  (C table — computed from S accent + bg_brightness + opacity)
-- ============================================================================
local C = {}

local function cl(v)  return math.max(0, math.min(255, math.floor(v + 0.5))) end
local function rgba(r, g, b, a)
  -- Pure arithmetic — no bitwise. Format: RRGGBBAA.
  return cl(r) * 0x1000000 + cl(g) * 0x10000 + cl(b) * 0x100 + cl(a or 255)
end

local function RecomputeTheme()
  local r, g, b = S.accent_r, S.accent_g, S.accent_b
  local op      = S.opacity        -- 0.3–1.0
  local bri     = S.bg_brightness  -- 0.0–1.0

  -- Surface color helper: applies opacity to alpha. Text uses rgba() directly
  -- (text intentionally stays at full opacity so it stays readable).
  local function surf(rv, gv, bv, av)
    return rgba(rv, gv, bv, cl((av or 255) * op))
  end

  -- Background base values brightened by bri
  local bg_r, bg_g, bg_b = cl(20 + bri * 55), cl(20 + bri * 55), cl(24 + bri * 60)
  local bs_r, bs_g, bs_b = cl(14 + bri * 50), cl(14 + bri * 50), cl(18 + bri * 55)
  local mb_r, mb_g, mb_b = cl(16 + bri * 52), cl(16 + bri * 52), cl(22 + bri * 58)

  C.accent    = rgba(r,        g,        b,        255)
  C.accentHov = rgba(r * 1.2, g * 1.2, b * 1.2, 255)
  C.accentAct = rgba(r * 0.8, g * 0.8, b * 0.8, 255)
  C.bg        = surf(bg_r, bg_g, bg_b)
  C.bgStrip   = surf(bs_r, bs_g, bs_b)
  C.menuBar   = surf(mb_r, mb_g, mb_b)
  C.border    = surf(cl(55 + bri * 30), cl(55 + bri * 30), cl(68 + bri * 30))
  C.text      = rgba(218, 218, 222, 255)   -- text: never opacity-scaled
  C.textDim   = rgba(120, 120, 132, 255)   -- text: never opacity-scaled
  C.sep       = surf(cl(48 + bri * 20), cl(48 + bri * 20), cl(60 + bri * 20))
  C.btn       = surf(cl(36 + bri * 20), cl(36 + bri * 20), cl(46 + bri * 20))
  C.btnHov    = surf(cl(r * 0.22 + 42 + bri * 10),
                     cl(g * 0.22 + 42 + bri * 10),
                     cl(b * 0.30 + 48 + bri * 10))
  C.btnAct    = surf(cl(r * 0.40), cl(g * 0.40), cl(b * 0.50))
  C.frame     = surf(cl(42 + bri * 20), cl(42 + bri * 20), cl(54 + bri * 20))
  C.frameHov  = surf(cl(52 + bri * 20), cl(52 + bri * 20), cl(66 + bri * 20))

  -- Title bar: inactive is near-bg; active blends bg toward accent.
  C.titleBg          = surf(cl(bg_r + 8),  cl(bg_g + 8),  cl(bg_b + 10))
  C.titleBgActive    = surf(cl(bg_r + r * 0.12 + 5), cl(bg_g + g * 0.12 + 5), cl(bg_b + b * 0.15 + 6))
  C.titleBgCollapsed = surf(cl(bg_r * 0.6), cl(bg_g * 0.6), cl(bg_b * 0.6))

  -- Tabs: unselected near bg, selected elevated with accent hint.
  C.tab              = surf(cl(bg_r + 6),  cl(bg_g + 6),  cl(bg_b + 8))
  C.tabHov           = C.btnHov
  C.tabActive        = surf(cl(bg_r + 22 + r * 0.12), cl(bg_g + 22 + g * 0.12), cl(bg_b + 24 + b * 0.15))
  C.tabUnfocused     = surf(cl(bg_r + 2),  cl(bg_g + 2),  cl(bg_b + 3))
  C.tabUnfocusedAct  = surf(cl(bg_r + 12), cl(bg_g + 12), cl(bg_b + 14))

  -- CheckMark / SliderGrab: accent-boosted so they're always visible on dark bg.
  local function vis(v) return cl(v * 0.8 + 100) end
  C.checkMark        = rgba(vis(r),                vis(g),                vis(b),                255)
  C.sliderGrab       = surf(cl(r * 0.6 + 60 + bri * 10), cl(g * 0.6 + 60 + bri * 10), cl(b * 0.7 + 65 + bri * 10))
  C.sliderGrabAct    = surf(cl(r * 0.8 + 70 + bri * 10), cl(g * 0.8 + 70 + bri * 10), cl(b * 0.9 + 75 + bri * 10))

  -- Scrollbar: track dark, grab accent-influenced.
  C.scrollBg         = surf(cl(bg_r * 0.7), cl(bg_g * 0.7), cl(bg_b * 0.7))
  C.scrollGrab       = surf(cl(bg_r + 30),  cl(bg_g + 30),  cl(bg_b + 32))
  C.scrollGrabHov    = C.btnHov
  C.scrollGrabAct    = surf(cl(r * 0.6 + 60), cl(g * 0.6 + 60), cl(b * 0.7 + 65))

  -- Resize grip: nearly transparent, subtle.
  local rg = cl(r + 40)
  local gg = cl(g + 40)
  local bg = cl(b + 40)
  C.resizeGrip       = rgba(rg, gg, bg, 26)    -- ~10% opacity
  C.resizeGripHov    = rgba(rg, gg, bg, 90)    -- ~35% opacity
  C.resizeGripAct    = rgba(rg, gg, bg, 180)   -- ~70% opacity
end

-- PushTheme / PopTheme — counted so PopStyleColor/Var always matches exactly.
local _pc = 0   -- pushed colour count for this frame
local _pv = 0   -- pushed var count for this frame

local function PushTheme()
  _pc = 0; _pv = 0
  local function PC(col, val) ImGui.PushStyleColor(ctx, col, val); _pc = _pc + 1 end
  local function PV(var, ...) ImGui.PushStyleVar(ctx, var, ...);   _pv = _pv + 1 end

  PC(ImGui.Col_WindowBg,       C.bg)
  PC(ImGui.Col_ChildBg,        C.bg)
  PC(ImGui.Col_PopupBg,        C.bg)
  PC(ImGui.Col_Border,         C.border)
  PC(ImGui.Col_Text,           C.text)
  PC(ImGui.Col_TextDisabled,   C.textDim)
  PC(ImGui.Col_Button,         C.btn)
  PC(ImGui.Col_ButtonHovered,  C.btnHov)
  PC(ImGui.Col_ButtonActive,   C.btnAct)
  PC(ImGui.Col_Header,         C.btn)
  PC(ImGui.Col_HeaderHovered,  C.btnHov)
  PC(ImGui.Col_HeaderActive,   C.btnAct)
  PC(ImGui.Col_Separator,      C.sep)
  PC(ImGui.Col_MenuBarBg,      C.menuBar)
  PC(ImGui.Col_FrameBg,        C.frame)
  PC(ImGui.Col_FrameBgHovered, C.frameHov)

  -- Title bar
  PC(ImGui.Col_TitleBg,          C.titleBg)
  PC(ImGui.Col_TitleBgActive,    C.titleBgActive)
  PC(ImGui.Col_TitleBgCollapsed, C.titleBgCollapsed)

  -- Tab bar
  PC(ImGui.Col_Tab,                C.tab)
  PC(ImGui.Col_TabHovered,         C.tabHov)
  PC(ImGui.Col_TabSelected,        C.tabActive)
  PC(ImGui.Col_TabDimmed,          C.tabUnfocused)
  PC(ImGui.Col_TabDimmedSelected,  C.tabUnfocusedAct)

  -- Interactive elements
  PC(ImGui.Col_CheckMark,          C.checkMark)
  PC(ImGui.Col_SliderGrab,         C.sliderGrab)
  PC(ImGui.Col_SliderGrabActive,   C.sliderGrabAct)

  -- Scrollbar
  PC(ImGui.Col_ScrollbarBg,          C.scrollBg)
  PC(ImGui.Col_ScrollbarGrab,        C.scrollGrab)
  PC(ImGui.Col_ScrollbarGrabHovered, C.scrollGrabHov)
  PC(ImGui.Col_ScrollbarGrabActive,  C.scrollGrabAct)

  -- Resize grip
  PC(ImGui.Col_ResizeGrip,        C.resizeGrip)
  PC(ImGui.Col_ResizeGripHovered, C.resizeGripHov)
  PC(ImGui.Col_ResizeGripActive,  C.resizeGripAct)

  PV(ImGui.StyleVar_WindowRounding,  6)
  PV(ImGui.StyleVar_FrameRounding,   S.btn_rounding)
  PV(ImGui.StyleVar_GrabRounding,    S.btn_rounding)
  PV(ImGui.StyleVar_WindowPadding,   10, 10)
  PV(ImGui.StyleVar_ItemSpacing,      8,  6)
  PV(ImGui.StyleVar_FramePadding,     6,  5)
  PV(ImGui.StyleVar_ButtonTextAlign,  S.btn_text_left and 0.0 or 0.5, 0.5)
end

local function PopTheme()
  ImGui.PopStyleColor(ctx, _pc)
  ImGui.PopStyleVar(ctx, _pv)
end

-- ============================================================================
-- SCRIPT LAUNCH
-- ============================================================================
local function launch_button(btn)
  if btn.action_id then
    local cid = btn.action_id
    if type(cid) == "string" then cid = tonumber(cid) or reaper.NamedCommandLookup(cid) end
    if cid and cid > 0 then reaper.Main_OnCommand(cid, 0) end
    return
  end
  local p
  if     btn.path   then p = btn.path
  elseif btn.script then p = BASE_DIR .. btn.script
  end
  if not p then return end
  p = p:gsub("/", SEP)   -- normalise slashes for OS
  local id = reaper.AddRemoveReaScript(true, 0, p, true)
  if id and id > 0 then
    reaper.Main_OnCommand(id, 0)
  else
    reaper.ShowMessageBox("Script not found:\n" .. p, "Command Center", 0)
  end
end

-- ============================================================================
-- PROJECT TAGS  (reads project-tags.json; updates only when project changes)
-- ============================================================================
local function parse_project_tags(json_path, proj_path)
  if not json_path or json_path == "" then return nil end
  if not proj_path or proj_path == "" then return nil end

  local f = io.open(json_path, "rb")
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  if not text or text == "" then return nil end

  local function normpath(s)
    return s:lower():gsub("\\\\", "/"):gsub("\\", "/")
  end
  local target = normpath(proj_path)

  local in_obj    = false
  local depth     = 0
  local obj_lines = {}

  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if not in_obj then
      local key = line:match('^%s*"(.-)":%s*%{?')
      if key and normpath(key) == target then
        in_obj    = true
        depth     = 0
        obj_lines = {}
      end
    end

    if in_obj then
      obj_lines[#obj_lines + 1] = line
      for c in line:gmatch(".") do
        if     c == "{" then depth = depth + 1
        elseif c == "}" then
          depth = depth - 1
          if depth == 0 then
            local obj  = table.concat(obj_lines, "\n")
            local tags = {}
            for k, v in obj:gmatch('"([^"]+)"%s*:%s*"([^"]*)"') do tags[k] = v end
            for k, v in obj:gmatch('"([^"]+)"%s*:%s*(%d+%.?%d*)') do
              if not tags[k] then tags[k] = tonumber(v) end
            end
            for k in obj:gmatch('"([^"]+)"%s*:%s*true')  do tags[k] = true  end
            for k in obj:gmatch('"([^"]+)"%s*:%s*false') do tags[k] = false end
            return tags
          end
        end
      end
    end
  end
  return nil
end

-- ============================================================================
-- INFO STRIP UPDATE  (throttled — called every 5 frames, ~12 Hz at 60 fps)
-- ============================================================================
local function update_info()
  -- Row 1: selected item
  local item = reaper.GetSelectedMediaItem(0, 0)
  if item then
    local take = reaper.GetActiveTake(item)
    if take then
      local src   = reaper.GetMediaItemTake_Source(take)
      local fname = reaper.GetMediaSourceFileName(src, "")
      local base  = fname:match("[^/\\]+$") or fname
      local soffs = reaper.GetMediaItemInfo_Value(item, "D_STARTOFFS")
      local rate  = reaper.GetMediaItemInfo_Value(item, "D_PLAYRATE")
      local len   = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      S.info_item = string.format(
        "%s    SOFFS %.3fs    Rate %.4f    Len %.1fs", base, soffs, rate, len)
    else
      S.info_item = "Item selected (no active take)"
    end
  else
    S.info_item = "No item selected"
  end

  -- Row 2: tempo markers
  local n = reaper.CountTempoTimeSigMarkers(0)
  if n > 0 then
    local lo, hi = math.huge, -math.huge
    local sigs = {}
    for i = 0, n - 1 do
      local _, _, _, _, bpm, tsn, tsd = reaper.GetTempoTimeSigMarker(0, i)
      if bpm < lo then lo = bpm end
      if bpm > hi then hi = bpm end
      if tsn > 0 then sigs[tsn .. "/" .. tsd] = true end
    end
    local siglist = {}
    for k in pairs(sigs) do siglist[#siglist + 1] = k end
    table.sort(siglist)
    local sigstr = (#siglist > 0) and table.concat(siglist, "  ") or "4/4"
    if hi - lo < 0.5 then
      S.info_tempo = string.format("%d markers    %.1f BPM    %s", n, lo, sigstr)
    else
      S.info_tempo = string.format("%d markers    %.1f\226\128\147%.1f BPM    %s", n, lo, hi, sigstr)
    end
  else
    S.info_tempo = "No tempo markers"
  end

  -- Row 3: project name + metadata from project-tags.json
  local _, proj_path = reaper.EnumProjects(-1, "")
  if proj_path and proj_path ~= "" then
    local name = proj_path:match("[^/\\]+$") or proj_path
    name = name:gsub("%.rpp$", ""):gsub("%.RPP$", "")

    if proj_path ~= S.cached_proj then
      S.cached_proj = proj_path
      S.cached_tags = parse_project_tags(S.tags_json_path, proj_path)
    end

    local parts = { "Project: " .. name }
    local t = S.cached_tags
    if t then
      if t.tuning  then parts[#parts + 1] = t.tuning end
      if t.strings then parts[#parts + 1] = t.strings .. "-str" end
      if t.bpm     then parts[#parts + 1] = string.format("%.0f BPM", t.bpm) end
      if t.status  then parts[#parts + 1] = t.status end
    end
    S.info_proj = table.concat(parts, "  \194\183  ")
  else
    S.info_proj   = "Project: (unsaved)"
    S.cached_proj = ""
    S.cached_tags = nil
  end
end

-- ============================================================================
-- BUTTON GRID
-- ============================================================================
local _has_sep_text = (ImGui.SeparatorText ~= nil)
local function SepText(label)
  if _has_sep_text then
    ImGui.SeparatorText(ctx, label)
  else
    ImGui.Separator(ctx)
    ImGui.TextDisabled(ctx, label)
    ImGui.Separator(ctx)
  end
end

local function draw_grid()
  for _, sec in ipairs(SECTIONS) do
    -- Collect buttons; run lazy existence checks while building the list.
    -- btn.exists is cached permanently after first render — zero startup cost.
    local btns = {}
    for _, btn in ipairs(BUTTONS) do
      if btn.sec == sec.id then
        if btn.exists == nil then
          if btn.action_id then
            btn.exists = true
          else
            local p
            if     btn.path   then p = btn.path
            elseif btn.script then p = BASE_DIR .. btn.script
            end
            btn.exists = p ~= nil and reaper.file_exists(p:gsub("/", SEP)) or false
          end
        end
        -- Respect "hide missing scripts" setting
        if not (S.hide_missing and not btn.exists) then
          btns[#btns + 1] = btn
        end
      end
    end
    if #btns == 0 then goto next_sec end

    if S.show_section_hdrs then SepText(sec.label) end

    local avail_w = ImGui.GetContentRegionAvail(ctx)
    local cols    = math.max(S.min_cols, math.min(S.prefer_cols, math.floor(avail_w / MIN_BTN_W)))

    if ImGui.BeginTable(ctx, "##tbl_" .. sec.id, cols) then
      for _ = 1, cols do
        ImGui.TableSetupColumn(ctx, "", ImGui.TableColumnFlags_WidthStretch)
      end
      for i, btn in ipairs(btns) do
        ImGui.TableNextColumn(ctx)
        if not btn.exists then ImGui.BeginDisabled(ctx) end
        if ImGui.Button(ctx, btn.label .. "##" .. sec.id .. i, -1, S.btn_h) then
          launch_button(btn)
        end
        if not btn.exists then ImGui.EndDisabled(ctx) end
        if S.show_tooltips and btn.tooltip and ImGui.IsItemHovered(ctx) then
          ImGui.SetTooltip(ctx, btn.tooltip)
        end
      end
      ImGui.EndTable(ctx)
    end

    ImGui.Spacing(ctx)
    ::next_sec::
  end
end

-- ============================================================================
-- EDITOR LOGIC & UI (v1.6)
-- ============================================================================
local function deep_copy_table(orig)
  local orig_type = type(orig)
  local copy
  if orig_type == 'table' then
    copy = {}
    for orig_key, orig_value in next, orig, nil do
      copy[deep_copy_table(orig_key)] = deep_copy_table(orig_value)
    end
  else
    copy = orig
  end
  return copy
end

local function ed_mark_dirty()
  S.editor_dirty = true
  S.editor_last_change = reaper.time_precise()
end

local function browse_for_script(initial_dir)
  local title = "Select Script"
  local extList = "Script Files\0*.lua;*.eel\0All Files\0*.*\0\0"
  local rv, files = reaper.JS_Dialog_BrowseForOpenFiles(title, initial_dir, "", extList, false)
  if rv == 1 and files and files ~= "" then
    local path = files
    -- Extract directory to save as last_browse_dir
    local dir = path:match("^(.*[/\\])")
    if dir then S.last_browse_dir = dir end
    return path:gsub("\\", "/")
  end
  return nil
end

local function esc(str)
  if not str then return "" end
  return tostring(str):gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
end

local function SaveButtons()
  local out = {}
  table.insert(out, "{")
  table.insert(out, '  "sections": [')
  for i, sec in ipairs(SECTIONS) do
    local line = string.format('    { "id": "%s", "label": "%s" }', esc(sec.id), esc(sec.label))
    if i < #SECTIONS then line = line .. "," end
    table.insert(out, line)
  end
  table.insert(out, '  ],')
  table.insert(out, '  "buttons": [')
  for i, btn in ipairs(BUTTONS) do
    table.insert(out, "    {")
    table.insert(out, string.format('      "sec": "%s",', esc(btn.sec)))
    table.insert(out, string.format('      "label": "%s",', esc(btn.label)))
    
    -- Core routing identifier
    if btn.action_id then
      if type(btn.action_id) == "number" then table.insert(out, string.format('      "action_id": %d,', btn.action_id))
      else table.insert(out, string.format('      "action_id": "%s",', esc(btn.action_id))) end
    elseif btn.user then table.insert(out, string.format('      "user": "%s",', esc(btn.user)))
    elseif btn.ref then table.insert(out, string.format('      "ref": "%s",', esc(btn.ref)))
    elseif btn.script then table.insert(out, string.format('      "script": "%s",', esc(btn.script)))
    else table.insert(out, string.format('      "path": "%s",', esc(btn.path))) end
    
    -- Optional tooltip
    if type(btn.tooltip) == "string" and btn.tooltip ~= "" then
      table.insert(out, string.format('      "tooltip": "%s"', esc(btn.tooltip)))
    else
      local last = out[#out]
      if last:sub(-1) == "," then out[#out] = last:sub(1, -2) end
    end
    
    local endline = "    }"
    if i < #BUTTONS then endline = endline .. "," end
    table.insert(out, endline)
  end
  table.insert(out, '  ]')
  table.insert(out, "}")
  
  local f = io.open(BASE_DIR .. "cc_buttons.json", "wb")
  if not f then return false end
  f:write(table.concat(out, "\n"))
  f:close()

  S.editor_dirty = false
  S.editor_last_change = 0
  return true
end

local function btn_prev_in_sec(g_i)
  local sec = BUTTONS[g_i].sec
  for i = g_i - 1, 1, -1 do
    if BUTTONS[i].sec == sec then return i end
  end
  return nil
end

local function btn_next_in_sec(g_i)
  local sec = BUTTONS[g_i].sec
  for i = g_i + 1, #BUTTONS do
    if BUTTONS[i].sec == sec then return i end
  end
  return nil
end

local function draw_editor()
  local pending = nil
  local function act(op, i, j, src, dst, val)
    pending = {op=op, i=i, j=j, src=src, dst=dst, val=val}
  end

  ImGui.Spacing(ctx)
  if S.editor_dirty then
    if ImGui.Button(ctx, "Save to JSON##ed", 120) then SaveButtons() end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Discard##ed", 120) and ED.snap_sections then
      SECTIONS = deep_copy_table(ED.snap_sections)
      BUTTONS  = deep_copy_table(ED.snap_buttons)
      resolve_refs(BUTTONS)
      S.editor_dirty = false
      ED.open_btn_idx = -1; ED.open_sec_idx = -1; ED.new_sec_open = false
    end
    ImGui.SameLine(ctx)
    ImGui.TextColored(ctx, 0xFF5555FF, "\226\151\143 Unsaved changes")
  else
    ImGui.TextDisabled(ctx, "Layout matches cc_buttons.json")
  end
  ImGui.Spacing(ctx)
  ImGui.Separator(ctx)
  ImGui.Spacing(ctx)

  for s_i, sec in ipairs(SECTIONS) do
    ImGui.PushID(ctx, "sec_" .. sec.id)

    -- Section Header
    if ED.open_sec_idx == s_i then
      ImGui.SetNextItemWidth(ctx, 200)
      local rc, rv = ImGui.InputText(ctx, "##secren", ED.buf_sec_label)
      if rc then ED.buf_sec_label = rv end
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "Save") then
        if ED.buf_sec_label ~= "" then
          sec.label = ED.buf_sec_label
          ed_mark_dirty()
        end
        ED.open_sec_idx = -1
      end
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "Cancel") then ED.open_sec_idx = -1 end
    else
      ImGui.SeparatorText(ctx, sec.label)
      ImGui.SameLine(ctx, ImGui.GetWindowWidth(ctx) - 130)
      if ImGui.ArrowButton(ctx, "##sup", ImGui.Dir_Up) and s_i > 1 then
        act("sec_swap", s_i, s_i - 1)
      end
      ImGui.SameLine(ctx)
      if ImGui.ArrowButton(ctx, "##sdn", ImGui.Dir_Down) and s_i < #SECTIONS then
        act("sec_swap", s_i, s_i + 1)
      end
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "Ren") then
        ED.open_sec_idx = s_i
        ED.buf_sec_label = sec.label
        ED.open_btn_idx = -1; ED.new_sec_open = false
      end
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "X") then act("sec_del", s_i) end
    end

    ImGui.Spacing(ctx)

    -- Buttons in Section
    for b_i, btn in ipairs(BUTTONS) do
      if btn.sec == sec.id then
        ImGui.PushID(ctx, "btn_" .. b_i)
        
        -- Minimal row view
        ImGui.Indent(ctx, 16)
        ImGui.AlignTextToFramePadding(ctx)
        
        local typ = "Path  "
        if btn.action_id then typ = "Action"
        elseif btn.user then typ = "User  "
        elseif btn.ref then typ = "Comm. "
        elseif btn.script then typ = "Local " end
        
        ImGui.TextDisabled(ctx, "[" .. typ .. "]")
        ImGui.SameLine(ctx)
        ImGui.Text(ctx, btn.label)
        
        -- Drag & Drop implementation
        if ImGui.BeginDragDropSource(ctx, ImGui.DragDropFlags_SourceAllowNullID) then
          ImGui.SetDragDropPayload(ctx, "BTN_DND", tostring(b_i))
          ImGui.Text(ctx, "Move " .. btn.label)
          ImGui.EndDragDropSource(ctx)
        end
        if ImGui.BeginDragDropTarget(ctx) then
          local rv, payload = ImGui.AcceptDragDropPayload(ctx, "BTN_DND")
          if rv then
            local src_i = tonumber(payload)
            if src_i and src_i ~= b_i then
              act("btn_move", nil, nil, src_i, b_i, sec.id)
            end
          end
          ImGui.EndDragDropTarget(ctx)
        end

        local right_align = ImGui.GetWindowWidth(ctx) - 150
        ImGui.SameLine(ctx, right_align < 200 and 200 or right_align)
        local p_i = btn_prev_in_sec(b_i)
        if not p_i then ImGui.BeginDisabled(ctx) end
        if ImGui.ArrowButton(ctx, "##bup", ImGui.Dir_Up) then act("btn_swap", b_i, p_i) end
        if not p_i then ImGui.EndDisabled(ctx) end

        ImGui.SameLine(ctx)
        local n_i = btn_next_in_sec(b_i)
        if not n_i then ImGui.BeginDisabled(ctx) end
        if ImGui.ArrowButton(ctx, "##bdn", ImGui.Dir_Down) then act("btn_swap", b_i, n_i) end
        if not n_i then ImGui.EndDisabled(ctx) end

        ImGui.SameLine(ctx)
        if ImGui.Button(ctx, "Edit") then
          ED.open_btn_idx = b_i
          ED.open_sec_idx = -1; ED.new_sec_open = false
          ED.buf_label = btn.label
          ED.buf_tooltip = btn.tooltip or ""
          ED.buf_sec = btn.sec
          if btn.action_id then ED.buf_path = type(btn.action_id) == "number" and tostring(math.floor(btn.action_id)) or tostring(btn.action_id)
          elseif btn.path then ED.buf_path = btn.path
          elseif btn.user then ED.buf_path = USER_DIR .. btn.user
          elseif btn.ref then ED.buf_path = REF_DIR .. btn.ref
          elseif btn.script then ED.buf_path = BASE_DIR:gsub("\\","/") .. btn.script
          else ED.buf_path = "" end
        end
        ImGui.SameLine(ctx)
        if ImGui.Button(ctx, "X##bdl") then act("btn_del", b_i) end
        ImGui.Unindent(ctx, 16)

        -- Inline Form
        if ED.open_btn_idx == b_i then
          ImGui.Spacing(ctx)
          ImGui.Indent(ctx, 32)
          ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, C.frame)
          if ImGui.BeginChild(ctx, "##form_" .. b_i, 0, 165, ImGui.ChildFlags_Borders) then
            ImGui.Spacing(ctx)
            ImGui.Indent(ctx, 10)
            
            ImGui.Text(ctx, "Label:")
            ImGui.SameLine(ctx, 80); ImGui.SetNextItemWidth(ctx, 200)
            local lc, lv = ImGui.InputText(ctx, "##flbl", ED.buf_label)
            if lc then ED.buf_label = lv end
            
            ImGui.Text(ctx, "Section:")
            ImGui.SameLine(ctx, 80); ImGui.SetNextItemWidth(ctx, 200)
            if ImGui.BeginCombo(ctx, "##fsec", ED.buf_sec) then
              for _, sx in ipairs(SECTIONS) do
                if ImGui.Selectable(ctx, sx.label, ED.buf_sec == sx.id) then ED.buf_sec = sx.id end
              end
              ImGui.EndCombo(ctx)
            end

            ImGui.Text(ctx, "Path/ID:")
            ImGui.SameLine(ctx, 80); ImGui.SetNextItemWidth(ctx, 300)
            local pc, pv = ImGui.InputText(ctx, "##fpath", ED.buf_path)
            if pc then ED.buf_path = pv end
            ImGui.SameLine(ctx)
            if ImGui.Button(ctx, "Browse...") then
              local got = browse_for_script(S.last_browse_dir)
              if got then ED.buf_path = got end
            end

            ImGui.Text(ctx, "Tooltip:")
            ImGui.SameLine(ctx, 80); ImGui.SetNextItemWidth(ctx, 300)
            local tlc, tlv = ImGui.InputText(ctx, "##ftip", ED.buf_tooltip)
            if tlc then ED.buf_tooltip = tlv end

            ImGui.Spacing(ctx)
            if ImGui.Button(ctx, "Save Changes", 120) then
              if ED.buf_label ~= "" and ED.buf_path ~= "" then
                btn.label = ED.buf_label
                btn.sec = ED.buf_sec
                btn.tooltip = (ED.buf_tooltip ~= "") and ED.buf_tooltip or nil
                
                -- Auto Tooltip Extraction if blank
                if not btn.tooltip and not ED.buf_path:match("^%d+$") then
                  local test_path = ED.buf_path:gsub("\\", "/")
                  local f_path = nil
                  if not test_path:match("^[A-Za-z]:/") and not test_path:match("^/") then
                    for _, dir in ipairs({BASE_DIR, REF_DIR, USER_DIR}) do
                      local check = dir:gsub("\\", "/") .. test_path
                      if reaper.file_exists(check) then f_path = check; break end
                    end
                  elseif reaper.file_exists(test_path) then
                    f_path = test_path
                  end
                  
                  if f_path then
                    local f = io.open(f_path, "r")
                    if f then
                      local content = f:read(1024)
                      f:close()
                      if content then
                        local desc = content:match("@description%s+([^\r\n]+)")
                        if desc then btn.tooltip = desc end
                      end
                    end
                  end
                end

                btn.script = nil; btn.ref = nil; btn.path = nil; btn.action_id = nil; btn.user = nil; btn.exists = nil
                local input = ED.buf_path:gsub("\\", "/")
                
                if input:match("^%d+$") then
                  btn.action_id = tonumber(input)
                elseif reaper.NamedCommandLookup(input) > 0 then
                  btn.action_id = input
                else
                  local b_dir = BASE_DIR:gsub("\\", "/")
                  local r_dir = REF_DIR:gsub("\\", "/")
                  local u_dir = USER_DIR
                  local lo_in = input:lower()
                  
                  if lo_in:find(u_dir:lower(), 1, true) == 1 then
                    btn.user = input:sub(#u_dir + 1)
                  elseif lo_in:find(r_dir:lower(), 1, true) == 1 then
                    btn.ref = input:sub(#r_dir + 1)
                  elseif lo_in:find(b_dir:lower(), 1, true) == 1 then
                    btn.script = input:sub(#b_dir + 1)
                  elseif not input:match("^[A-Za-z]:/") and not input:match("^/") then
                    if reaper.file_exists((b_dir .. input):gsub("/", package.config:sub(1,1))) then
                      btn.script = input
                    else
                      btn.path = input
                    end
                  else
                    btn.path = input
                  end
                end
                
                resolve_refs({btn})
                ED.open_btn_idx = -1
                ed_mark_dirty()
              end
            end
            ImGui.SameLine(ctx)
            if ImGui.Button(ctx, "Cancel", 80) then ED.open_btn_idx = -1 end

            ImGui.Unindent(ctx, 10)
            ImGui.EndChild(ctx)
          end
          ImGui.PopStyleColor(ctx)
          ImGui.Unindent(ctx, 32)
        end
        
        ImGui.PopID(ctx)
      end
    end

    -- Add Button to Section
    ImGui.Spacing(ctx)
    ImGui.Indent(ctx, 16)
    if ImGui.Button(ctx, "+ Add Button##add_" .. sec.id) then
      local nbtn = { sec = sec.id, label = "New Button", path = "" }
      local ins_idx = #BUTTONS + 1
      for i = #BUTTONS, 1, -1 do
        if BUTTONS[i].sec == sec.id then ins_idx = i + 1; break end
      end
      act("btn_add", ins_idx, nil, nil, nil, nbtn)
    end
    ImGui.Unindent(ctx, 16)
    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    
    ImGui.PopID(ctx)
  end

  -- Add Section
  ImGui.Spacing(ctx)
  if ED.new_sec_open then
    ImGui.SetNextItemWidth(ctx, 200)
    local nc, nv = ImGui.InputText(ctx, "New Section Name", ED.buf_new_sec)
    if nc then ED.buf_new_sec = nv end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Create") and ED.buf_new_sec ~= "" then
      local id = ED.buf_new_sec:lower():gsub("%W+", "_")
      act("sec_add", nil, nil, nil, nil, {id = id, label = ED.buf_new_sec})
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Cancel##ns") then ED.new_sec_open = false end
  else
    if ImGui.Button(ctx, "+ Add Section") then
      ED.new_sec_open = true
      ED.buf_new_sec = ""
      ED.open_btn_idx = -1; ED.open_sec_idx = -1
    end
  end

  -- Execute pending mutations safely at block end
  if pending then
    if pending.op == "btn_del" then
      if ED.open_btn_idx == pending.i then ED.open_btn_idx = -1 end
      table.remove(BUTTONS, pending.i)
      ed_mark_dirty()
    elseif pending.op == "btn_swap" then
      BUTTONS[pending.i], BUTTONS[pending.j] = BUTTONS[pending.j], BUTTONS[pending.i]
      if ED.open_btn_idx == pending.i then ED.open_btn_idx = pending.j
      elseif ED.open_btn_idx == pending.j then ED.open_btn_idx = pending.i end
      ed_mark_dirty()
    elseif pending.op == "btn_move" then
      local moved = table.remove(BUTTONS, pending.src)
      if pending.val then moved.sec = pending.val end
      local target = (pending.dst > pending.src) and (pending.dst - 1) or pending.dst
      table.insert(BUTTONS, target, moved)
      ED.open_btn_idx = -1; ed_mark_dirty()
    elseif pending.op == "btn_add" then
      table.insert(BUTTONS, pending.i, pending.val)
      ED.open_btn_idx = pending.i
      ED.buf_label = "New Button"; ED.buf_tooltip = ""; ED.buf_sec = pending.val.sec
      ED.buf_type = 3; ED.buf_path = ""
      ed_mark_dirty()
    elseif pending.op == "sec_swap" then
      SECTIONS[pending.i], SECTIONS[pending.j] = SECTIONS[pending.j], SECTIONS[pending.i]
      if ED.open_sec_idx == pending.i then ED.open_sec_idx = pending.j
      elseif ED.open_sec_idx == pending.j then ED.open_sec_idx = pending.i end
      ed_mark_dirty()
    elseif pending.op == "sec_del" then
      local has_btns = false
      for _, b in ipairs(BUTTONS) do
        if b.sec == SECTIONS[pending.i].id then has_btns = true; break end
      end
      if not has_btns or reaper.MB("Section contains buttons. Delete everything inside it?", "Delete Section", 4) == 6 then
        local id = SECTIONS[pending.i].id
        table.remove(SECTIONS, pending.i)
        for i = #BUTTONS, 1, -1 do
          if BUTTONS[i].sec == id then table.remove(BUTTONS, i) end
        end
        ED.open_sec_idx = -1; ED.open_btn_idx = -1
        ed_mark_dirty()
      end
    elseif pending.op == "sec_add" then
      table.insert(SECTIONS, pending.val)
      ED.new_sec_open = false
      ed_mark_dirty()
    end
  end
end

-- ============================================================================
-- INFO STRIP
-- ============================================================================
local function draw_info_strip()
  ImGui.Separator(ctx)
  ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, C.bgStrip)
  if ImGui.BeginChild(ctx, "##info_strip", 0, INFO_H, 0,
      ImGui.WindowFlags_NoScrollbar | ImGui.WindowFlags_NoScrollWithMouse) then
    ImGui.Spacing(ctx)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
    ImGui.Text(ctx, S.info_item)
    ImGui.Text(ctx, S.info_tempo)
    ImGui.Text(ctx, S.info_proj)
    ImGui.PopStyleColor(ctx)
    ImGui.EndChild(ctx)
  end
  ImGui.PopStyleColor(ctx)
end

-- ============================================================================
-- SETTINGS TAB CONTENT
-- ============================================================================
local function draw_settings_content()
  local changed = false   -- any persisted value changed this frame

  -- ── Appearance ──────────────────────────────────────────────────────────
  SepText("Appearance")
  ImGui.Spacing(ctx)

  ImGui.SetNextItemWidth(ctx, 180)
  local fc, fv = ImGui.SliderInt(ctx, "Font Size", S.font_size, 10, 24)
  if fc then S.font_size = fv; changed = true end

  ImGui.SetNextItemWidth(ctx, 180)
  local bc, bv = ImGui.SliderInt(ctx, "Button Height", S.btn_h, 30, 80)
  if bc then S.btn_h = bv; changed = true end

  ImGui.SetNextItemWidth(ctx, 180)
  local cc, cv = ImGui.SliderInt(ctx, "Max Columns", S.prefer_cols, 2, 6)
  if cc then S.prefer_cols = math.max(S.min_cols, cv); changed = true end

  ImGui.SetNextItemWidth(ctx, 180)
  local mc, mv = ImGui.SliderInt(ctx, "Min Columns", S.min_cols, 1, 5)
  if mc then S.min_cols = math.min(S.prefer_cols, mv); changed = true end

  ImGui.SetNextItemWidth(ctx, 180)
  local bric, briv = ImGui.SliderInt(ctx, "BG Brightness",
    math.floor(S.bg_brightness * 100 + 0.5), 0, 100, "%d%%")
  if bric then S.bg_brightness = briv / 100; changed = true end

  ImGui.SetNextItemWidth(ctx, 180)
  local brnc, brnv = ImGui.SliderInt(ctx, "Button Rounding", S.btn_rounding, 0, 12)
  if brnc then S.btn_rounding = brnv; changed = true end

  ImGui.SetNextItemWidth(ctx, 180)
  local opc, opv = ImGui.SliderInt(ctx, "Opacity",
    math.floor(S.opacity * 100 + 0.5), 30, 100, "%d%%")
  if opc then S.opacity = opv / 100; changed = true end

  local talc, talv = ImGui.Checkbox(ctx, "Left-align button text", S.btn_text_left)
  if talc then S.btn_text_left = talv; changed = true end

  ImGui.Spacing(ctx)
  ImGui.Text(ctx, "Accent Color")
  ImGui.SetNextItemWidth(ctx, 220)
  local col_packed = S.accent_r * 0x10000 + S.accent_g * 0x100 + S.accent_b
  local ac, new_col = ImGui.ColorEdit3(ctx, "##accent", col_packed)
  if ac then
    S.accent_r = math.floor(new_col / 0x10000) % 256
    S.accent_g = math.floor(new_col / 0x100)   % 256
    S.accent_b = new_col % 256
    changed = true
  end

  -- Recompute theme for appearance changes (cheap: pure math, no I/O)
  if changed then RecomputeTheme() end

  -- ── Window ──────────────────────────────────────────────────────────────
  ImGui.Spacing(ctx)
  SepText("Window")
  ImGui.Spacing(ctx)

  local dc, dv = ImGui.Checkbox(ctx, "Allow docking", S.allow_docking)
  if dc then S.allow_docking = dv; changed = true end

  local tc2, tv2 = ImGui.Checkbox(ctx, "Always on top", S.topmost)
  if tc2 then S.topmost = tv2; changed = true end

  local cof_c, cof_v = ImGui.Checkbox(ctx, "Close when focus is lost", S.close_on_unfocus)
  if cof_c then
    S.close_on_unfocus = cof_v
    if not cof_v then S.had_focus = false end   -- reset guard when disabling
    changed = true
  end

  local esc_c, esc_v = ImGui.Checkbox(ctx, "Close on Escape", S.close_on_escape)
  if esc_c then S.close_on_escape = esc_v; changed = true end

  local oac_c, oac_v = ImGui.Checkbox(ctx, "Open at mouse cursor", S.open_at_cursor)
  if oac_c then S.open_at_cursor = oac_v; changed = true end

  local hm_c, hm_v = ImGui.Checkbox(ctx, "Hide missing scripts", S.hide_missing)
  if hm_c then S.hide_missing = hm_v; changed = true end

  local sis_c, sis_v = ImGui.Checkbox(ctx, "Show info strip", S.show_info_strip)
  if sis_c then S.show_info_strip = sis_v; changed = true end

  local ssh_c, ssh_v = ImGui.Checkbox(ctx, "Show section headers", S.show_section_hdrs)
  if ssh_c then S.show_section_hdrs = ssh_v; changed = true end

  local stt_c, stt_v = ImGui.Checkbox(ctx, "Show tooltips", S.show_tooltips)
  if stt_c then S.show_tooltips = stt_v; changed = true end

  -- Any change in this function marks the state dirty for SaveState
  if changed then S.is_dirty = true end

  -- ── Data ────────────────────────────────────────────────────────────────
  ImGui.Spacing(ctx)
  SepText("Data")
  ImGui.Spacing(ctx)
  ImGui.TextDisabled(ctx, "Project Tags JSON path:")
  ImGui.SetNextItemWidth(ctx, 360)
  local tc, tv = ImGui.InputText(ctx, "##tags_path", S.tags_json_path)
  if tc then
    S.tags_json_path = tv
    S.cached_proj    = ""   -- force re-read on next update
    S.is_dirty       = true
  end

  ImGui.Spacing(ctx)
  if ImGui.Button(ctx, "Reload Buttons from JSON", 200, 0) then
    LoadButtons()
  end

  -- ── Reset ────────────────────────────────────────────────────────────────
  ImGui.Spacing(ctx)
  ImGui.Separator(ctx)
  ImGui.Spacing(ctx)

  if ImGui.Button(ctx, "Reset Defaults", 130, 0) then
    S.font_size         = 14;    S.btn_h = 55;       S.prefer_cols = 4; S.min_cols = 1
    S.bg_brightness     = 0.0;   S.btn_rounding = 4; S.opacity = 1.0
    S.btn_text_left     = false
    S.accent_r          = 74;    S.accent_g = 158;   S.accent_b = 255
    S.allow_docking     = false;  S.topmost = false
    S.close_on_unfocus  = false;  S.close_on_escape = false
    S.open_at_cursor    = false
    S.hide_missing      = false
    S.show_info_strip   = true;   S.show_section_hdrs = true; S.show_tooltips = true
    S.had_focus         = false
    S.is_dirty          = true
    RecomputeTheme()
  end
end

-- ============================================================================
-- DRAW FRAME
-- ============================================================================
local function DrawFrame()
  -- Throttled info update (every 5 frames ~12 Hz at 60 fps)
  S.info_tick = S.info_tick + 1
  if S.info_tick >= 5 then
    S.info_tick = 0
    update_info()
  end

  -- Reserve height for info strip only when it's shown
  local _, avail_h     = ImGui.GetContentRegionAvail(ctx)
  local strip_reserve  = S.show_info_strip and (INFO_H + 6) or 0
  local tabs_h         = avail_h - strip_reserve
  if tabs_h < 10 then tabs_h = 10 end

  local noScroll = ImGui.WindowFlags_NoScrollbar | ImGui.WindowFlags_NoScrollWithMouse
  if ImGui.BeginChild(ctx, "##tabs_area", 0, tabs_h, 0, noScroll) then
    if ImGui.BeginTabBar(ctx, "##main_tabs") then

      if ImGui.BeginTabItem(ctx, "Tools") then
        if ImGui.BeginChild(ctx, "##tools_scroll", 0, 0) then
          if S.edit_mode then draw_editor() else draw_grid() end
          ImGui.EndChild(ctx)
        end
        ImGui.EndTabItem(ctx)
      end

      if ImGui.BeginTabItem(ctx, "Settings") then
        if ImGui.BeginChild(ctx, "##settings_scroll", 0, 0) then
          draw_settings_content()
          ImGui.EndChild(ctx)
        end
        ImGui.EndTabItem(ctx)
      end

      -- Internal pencil tab trigger to toggle Editor mode
      local pencil_lbl = S.editor_dirty and "\226\156\142 \226\151\143##ed" or "\226\156\142##ed"
      if ImGui.TabItemButton(ctx, pencil_lbl, ImGui.TabItemFlags_Trailing) then
        if not S.edit_mode then
          ED.snap_sections = deep_copy_table(SECTIONS)
          ED.snap_buttons  = deep_copy_table(BUTTONS)
        else
          ED.open_btn_idx = -1; ED.open_sec_idx = -1; ED.new_sec_open = false
        end
        S.edit_mode = not S.edit_mode
      end

      ImGui.EndTabBar(ctx)
    end
    ImGui.EndChild(ctx)
  end

  -- Auto-save logic (checks once every DrawFrame interval)
  if S.editor_dirty and S.editor_last_change > 0 then
    if (reaper.time_precise() - S.editor_last_change) >= 5.0 then
      if SaveButtons() then ED.snap_sections = nil; ED.snap_buttons = nil end
    end
  end

  if S.show_info_strip then
    draw_info_strip()
  end
end

-- ============================================================================
-- PERSIST STATE
-- ============================================================================
local function SaveState()
  if not S.is_dirty then return end   -- dirty flag: no-op when nothing changed
  S.is_dirty = false
  local function Set(k, v) reaper.SetExtState(EXT_SECTION, k, tostring(v), true) end
  Set("win_w",             S.win_w)
  Set("win_h",             S.win_h)
  Set("win_x",             S.win_x)
  Set("win_y",             S.win_y)
  Set("font_size",         S.font_size)
  Set("btn_h",             S.btn_h)
  Set("prefer_cols",       S.prefer_cols)
  Set("min_cols",          S.min_cols)
  Set("bg_brightness",     string.format("%.4f", S.bg_brightness))
  Set("btn_rounding",      S.btn_rounding)
  Set("opacity",           string.format("%.4f", S.opacity))
  Set("btn_text_left",     S.btn_text_left)
  Set("accent_r",          S.accent_r)
  Set("accent_g",          S.accent_g)
  Set("accent_b",          S.accent_b)
  Set("allow_docking",     S.allow_docking)
  Set("topmost",           S.topmost)
  Set("close_on_unfocus",  S.close_on_unfocus)
  Set("close_on_escape",   S.close_on_escape)
  Set("open_at_cursor",    S.open_at_cursor)
  Set("hide_missing",      S.hide_missing)
  Set("show_info_strip",   S.show_info_strip)
  Set("show_section_hdrs", S.show_section_hdrs)
  Set("show_tooltips",     S.show_tooltips)
  Set("tags_json_path",    S.tags_json_path)
  Set("last_browse_dir",   S.last_browse_dir)
end

local function LoadState()
  local function N(k, d)
    local v = tonumber(reaper.GetExtState(EXT_SECTION, k))
    return v ~= nil and v or d
  end
  local function B(k, d)
    local v = reaper.GetExtState(EXT_SECTION, k)
    return v ~= "" and (v == "true") or d
  end
  local function Str(k, d)
    local v = reaper.GetExtState(EXT_SECTION, k)
    return v ~= "" and v or d
  end

  S.win_w           = N("win_w",         DEFAULT_W)
  S.win_h           = N("win_h",         DEFAULT_H)
  S.win_x           = N("win_x",         -1)
  S.win_y           = N("win_y",         -1)
  S.font_size       = N("font_size",     14)
  S.btn_h           = N("btn_h",         55)
  S.prefer_cols     = N("prefer_cols",   4)
  S.min_cols        = N("min_cols",      1)
  S.prefer_cols     = math.max(S.min_cols, S.prefer_cols)
  S.bg_brightness   = N("bg_brightness", 0.0)
  S.btn_rounding    = N("btn_rounding",  4)
  S.opacity         = N("opacity",       1.0)
  -- Clamp floats to valid ranges after loading
  S.opacity         = math.max(0.3, math.min(1.0, S.opacity))
  S.bg_brightness   = math.max(0.0, math.min(1.0, S.bg_brightness))
  S.accent_r        = N("accent_r",      74)
  S.accent_g        = N("accent_g",      158)
  S.accent_b        = N("accent_b",      255)
  S.btn_text_left   = B("btn_text_left",    false)
  S.allow_docking   = B("allow_docking",    false)
  S.topmost         = B("topmost",          false)
  S.close_on_unfocus  = B("close_on_unfocus",  false)
  S.close_on_escape   = B("close_on_escape",   false)
  S.open_at_cursor    = B("open_at_cursor",    false)
  S.hide_missing      = B("hide_missing",      false)
  S.show_info_strip   = B("show_info_strip",   true)
  S.show_section_hdrs = B("show_section_hdrs", true)
  S.show_tooltips     = B("show_tooltips",     true)
  S.tags_json_path    = Str("tags_json_path", "G:/GitHub/Personal-Stuff/ReaLauncher/project-tags.json")
  S.last_browse_dir   = Str("last_browse_dir", BASE_DIR)
end

-- ============================================================================
-- MAIN LOOP
-- ============================================================================
local function OnError(err)
  reaper.ShowConsoleMsg(
    "[Command Center Error]\n" .. tostring(err) .. "\n" .. debug.traceback() .. "\n")
end

local Loop   -- forward declaration

local function Tick()
  xpcall(Loop, OnError)
end

Loop = function()
  S.frame_count = S.frame_count + 1

  -- Frame 1: restore geometry. open_at_cursor overrides saved position.
  if S.frame_count == 1 then
    ImGui.SetNextWindowSize(ctx, S.win_w, S.win_h, ImGui.Cond_Always)
    if S.open_at_cursor then
      local mx, my = reaper.GetMousePosition()
      ImGui.SetNextWindowPos(ctx, mx, my, ImGui.Cond_Always)
    elseif S.win_x >= 0 and S.win_y >= 0 then
      ImGui.SetNextWindowPos(ctx, S.win_x, S.win_y, ImGui.Cond_Always)
    end
    update_info()   -- populate info strip immediately (no blank first frame)
  end

  PushTheme()
  ImGui.PushFont(ctx, font, S.font_size)

  local wflags = ImGui.WindowFlags_NoCollapse
                 | ImGui.WindowFlags_NoScrollbar
                 | ImGui.WindowFlags_NoScrollWithMouse
  if not S.allow_docking then wflags = wflags | ImGui.WindowFlags_NoDocking end
  if S.topmost           then wflags = wflags | ImGui.WindowFlags_TopMost   end

  if S.window_open == nil then S.window_open = true end
  local visible, open = ImGui.Begin(ctx, WIN_ID, true, wflags)
  if not open then S.window_open = false end

  if visible then
    -- Geometry tracking: mark dirty only on actual resize, 
    -- and only on actual moves (ignoring teleport jumps).
    local nw, nh = ImGui.GetWindowSize(ctx)
    local nx, ny = ImGui.GetWindowPos(ctx)
    if nw ~= S.win_w or nh ~= S.win_h then
      S.win_w, S.win_h = nw, nh
      S.is_dirty = true
    end
    if nx ~= S.win_x or ny ~= S.win_y then
      S.win_x, S.win_y = nx, ny
      if not S.open_at_cursor then S.is_dirty = true end
    end

    -- Escape key close
    if S.close_on_escape and ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then
      S.window_open = false
    end

    -- Close-on-unfocus: By rendering the final frame normally even if closing, 
    -- we prevent the UI from flickering into a blank empty rectangle for 1 frame.
    if S.close_on_unfocus then
      local focused = ImGui.IsWindowFocused(ctx, ImGui.FocusedFlags_AnyWindow)
      if focused then
        S.had_focus = true
      elseif S.had_focus then
        S.window_open = false
      end
    end

    if not S.window_open and S.editor_dirty then
      ImGui.OpenPopup(ctx, "Unsaved Changes##close")
      S.window_open = true
    end

    -- Always draw the current frame perfectly even if scheduled to close.
    -- This prevents the UI from flickering into a blank rectangle right before vanishing.
    DrawFrame()
    
    if ImGui.BeginPopupModal(ctx, "Unsaved Changes##close", nil, ImGui.WindowFlags_AlwaysAutoResize | ImGui.WindowFlags_NoSavedSettings) then
      ImGui.Text(ctx, "You have unsaved layout modifications.")
      ImGui.Text(ctx, "If you close now, they will be lost.")
      ImGui.Spacing(ctx)
      if ImGui.Button(ctx, "Discard and Close", 140) then
        S.editor_dirty = false
        S.window_open = false
        ImGui.CloseCurrentPopup(ctx)
      end
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "Cancel", 140) then
        ImGui.CloseCurrentPopup(ctx)
      end
      ImGui.EndPopup(ctx)
    end
  end
  ImGui.End(ctx)

  ImGui.PopFont(ctx)
  PopTheme()

  if S.window_open then
    reaper.defer(Tick)
  else
    SaveState()   -- no-op if not dirty; safety net alongside atexit
  end
end

-- ============================================================================
-- INIT
-- ============================================================================
local function Init()
  collectgarbage("incremental", 200, 100, 13)   -- prevent 100ms GC spikes

  -- Capture section + command ID for toolbar toggle highlight
  local _, _, _, sec, cmd = reaper.get_action_context()
  TOOLBAR_SEC = sec
  TOOLBAR_CMD = cmd
  reaper.SetToggleCommandState(sec, cmd, 1)
  reaper.RefreshToolbar2(sec, cmd)

  ctx  = ImGui.CreateContext(SCRIPT_NAME)
  font = ImGui.CreateFont("sans-serif")
  ImGui.Attach(ctx, font)
  LoadState()
  LoadButtons()       -- override SECTIONS/BUTTONS from cc_buttons.json if present
  RecomputeTheme()
end

local function Cleanup()
  SaveState()
  if TOOLBAR_SEC and TOOLBAR_CMD then
    reaper.SetToggleCommandState(TOOLBAR_SEC, TOOLBAR_CMD, 0)
    reaper.RefreshToolbar2(TOOLBAR_SEC, TOOLBAR_CMD)
  end
end

reaper.atexit(Cleanup)

Init()
xpcall(Loop, OnError)   -- direct first call: avoids the 1.2s defer startup penalty
