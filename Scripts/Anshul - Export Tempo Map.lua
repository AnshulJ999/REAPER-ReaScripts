--[[
@description Export Tempo Map to CSV
@author Anshul
@credits Tormy Van Cool (original export structure and CSV format)
@version 2.2
@about
  Exports all tempo and time signature markers from the current project to a CSV file.

  The user chooses the output path via file dialog. Requires the project to be saved.

  **Requirements:**
  - js_ReaScriptAPI extension (install via Extensions > ReaPack)
@changelog
  v2.2 (2026-03-26)
    + File save dialog — user chooses path instead of hardcoded project folder
    + Guard: abort if project not saved
    + Guard: abort if no tempo markers exist
    - Removed TXT and HTML output (see comments below to restore)
  v2.1 (03 august 2022) - Full header + min header
  v2.0 (26 july 2022)  + curveType
  v1.9 (25 july 2022)  # Wrong header in console
  v1.8 (25 july 2022)  + CSV Headers / # Variable names
  v1.7 (24 july 2022)  # Double records on TXT / + CSV Beat field
  v1.6 (24 july 2022)  # HTML Even/Odd lines
  v1.5 (24 july 2022)  # Cleaned HTML
  v1.4 (24 july 2022)  + HTML page + TXT page
  v1.3 (23 july 2022)  # Comma separated
  v1.2 (23 july 2022)  # Exports with predetermined file_name
  v1.1 (23 july 2022)  # Time in format HH:mm:ss
  v1.0 (23 july 2022)  + Initial release
]]

---------------------------------------------
-- GUARD: js_ReaScriptAPI required for file dialogs
---------------------------------------------
if not reaper.JS_Dialog_BrowseForOpenFiles then
  reaper.MB(
    "This script requires the js_ReaScriptAPI extension.\n"
    .. "Install it via Extensions > ReaPack > Browse packages.",
    "Missing Extension", 0
  )
  return
end

---------------------------------------------
-- CONFIG
---------------------------------------------
local LF              = '\n'
local separator       = ','

local nameField_0  = 'Marker N.'
local nameField_1  = 'BPM'
local nameField_2  = 'Time Position'
local nameField_3  = 'Measure Position'
local nameField_4  = 'Beat'
local nameField_5  = 'Beat Position'
local nameField_6  = 'Samples'
local nameField_8  = 'Tempo Numerator'
local nameField_9  = 'Tempo Denominator'
local nameField_10 = 'Tempo Linearity'
local NS = 'Not Set'

---------------------------------------------
-- GUARD: project must be saved
---------------------------------------------
local pj_path = reaper.GetProjectPathEx(0, ''):gsub("\\$", "")
if pj_path == '' then
  reaper.MB(
    "Please save your project before exporting the tempo map.",
    "Export Tempo Map", 0
  )
  return
end

---------------------------------------------
-- GUARD: must have at least one tempo marker
---------------------------------------------
local howmany = reaper.CountTempoTimeSigMarkers(0)
if howmany == 0 then
  reaper.MB("No tempo markers found in this project.", "Export Tempo Map", 0)
  return
end

---------------------------------------------
-- BUILD DEFAULT SAVE PATH (project-named, auto-incremented)
---------------------------------------------
local pj_name = reaper.GetProjectName(0, ""):gsub("%.rpp$", "")
if pj_name == "" then pj_name = "Untitled" end

local function file_exists(path)
  local f = io.open(path, "r")
  if f then f:close() return true end
  return false
end

-- Returns the next available filename (increments suffix if file already exists)
local function suggest_filename(dir, base)
  local name = base .. " - Tempo Map.csv"
  if not file_exists(dir .. "\\" .. name) then return name end
  local i = 2
  while true do
    name = base .. " - Tempo Map (" .. i .. ").csv"
    if not file_exists(dir .. "\\" .. name) then return name end
    i = i + 1
  end
end

---------------------------------------------
-- FILE SAVE DIALOG
---------------------------------------------
local default_name = suggest_filename(pj_path, pj_name)
local ok, filepath = reaper.JS_Dialog_BrowseForSaveFile(
  "Save Tempo Map CSV",
  pj_path,
  default_name,
  "CSV files\0*.csv\0All files\0*.*\0\0"
)
if ok ~= 1 or not filepath or filepath == "" then return end

-- Ensure .csv extension
if not filepath:match("%.csv$") then filepath = filepath .. ".csv" end

---------------------------------------------
-- OPEN CSV FILE
---------------------------------------------
local CSV_file = io.open(filepath, "w")
if not CSV_file then
  reaper.MB(
    "Could not open file for writing:\n" .. filepath,
    "Export Tempo Map - Error", 0
  )
  return
end

-- TXT output removed. To restore, uncomment:
-- local TXT_file = io.open(filepath:gsub("%.csv$", ".txt"), "w")
-- local TXT_header = "TEMPO MAP EXPORT\n\n"
-- TXT_file:write(TXT_header)

-- HTML output removed. To restore, uncomment and add HeaderHTML/FooterHTML strings:
-- local HTML_file = io.open(filepath:gsub("%.csv$", ".html"), "w")
-- HTML_file:write(HeaderHTML)

---------------------------------------------
-- WRITE CSV HEADER
---------------------------------------------
local CSV_header = '"'..nameField_0..'"'  .. separator ..
                   '"'..nameField_1..'"'  .. separator ..
                   '"'..nameField_2..'"'  .. separator ..
                   '"'..nameField_3..'"'  .. separator ..
                   '"'..nameField_4..'"'  .. separator ..
                   '"'..nameField_5..'"'  .. separator ..
                   '"'..nameField_6..'"'  .. separator ..
                   '"'..nameField_8..'"'  .. separator ..
                   '"'..nameField_9..'"'  .. separator ..
                   '"'..nameField_10..'"' .. LF
CSV_file:write(CSV_header)

---------------------------------------------
-- WRITE TEMPO MARKERS
---------------------------------------------
local count = 0
while count < howmany do
  local _, timepos, measurepos, beatpos, bpm, timesig_num, timesig_denom, lineartempo =
    reaper.GetTempoTimeSigMarker(0, count)

  local fractional = (timesig_num < 0 or timesig_denom < 0)
    and NS
    or (timesig_num .. "/" .. timesig_denom)

  local tempoType  = lineartempo and "1" or "0"
  local SampleQTY  = reaper.format_timestr_pos(timepos, "", 4)
  local Beat       = reaper.format_timestr_pos(timepos, "", 2)

  local row = count           .. separator ..
              bpm             .. separator ..
              timepos         .. separator ..
              measurepos      .. separator ..
              Beat            .. separator ..
              beatpos         .. separator ..
              SampleQTY       .. separator ..
              timesig_num     .. separator ..
              timesig_denom   .. separator ..
              tempoType       .. LF

  CSV_file:write(row)

  -- TXT_file:write(...) -- uncomment if restoring TXT output
  -- HTML_file:write(...) -- uncomment if restoring HTML output

  count = count + 1
end

---------------------------------------------
-- CLOSE FILES
---------------------------------------------
CSV_file:close()
-- TXT_file:close()  -- uncomment if restoring TXT output
-- HTML_file:close() -- uncomment if restoring HTML output
-- HTML_file:write(FooterHTML) -- before close, if restoring HTML output

---------------------------------------------
-- DONE
---------------------------------------------
reaper.MB(
  howmany .. " tempo marker(s) exported to:\n\n" .. filepath,
  "Export Tempo Map - Done", 0
)
