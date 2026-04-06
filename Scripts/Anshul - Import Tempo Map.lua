--[[
@description Import Tempo Markers from CSV
@author Anshul
@credits Tormy Van Cool (original import structure and CSV format); obikag https://gist.github.com/obikag (CSV parser)
@version 1.3
@about
  Imports tempo and time signature markers into the current project from a CSV file.

  The user chooses the CSV file via file dialog. The imported markers must match the CSV format
  produced by "Export Tempo Map to CSV" (v2.2+).

  **Requirements:**
  - js_ReaScriptAPI extension (install via Extensions > ReaPack)
@changelog
  v1.3 (2026-03-26)
    + File open dialog — user chooses file instead of hardcoded project folder
    + Undo block — entire import is a single Ctrl+Z operation
    + Overwrite / Merge / Cancel dialog when existing markers are present
    + Per-row error tracking (previously only checked the last row's result)
    + Shows count of successfully imported and failed markers
  v1.2 (03 august 2022) + Gradual change support
  v1.1 (03 august 2022) + Avoid header line + version
  v1.0 (27 july 2022)  + Initial release
]]

local version = "Import Tempo Map v1.3"
local LF      = "\n"

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
-- FILE OPEN DIALOG
---------------------------------------------
-- Use project folder as default if project is saved; empty string otherwise
local pj_path = reaper.GetProjectPathEx(0, ''):gsub("\\$", "")

local ok, filepath = reaper.JS_Dialog_BrowseForOpenFiles(
  "Import Tempo Map CSV",
  pj_path,
  "",
  "CSV files\0*.csv\0All files\0*.*\0\0",
  false
)
if ok ~= 1 or not filepath or filepath == "" then return end

---------------------------------------------
-- PARSE CSV FILE
---------------------------------------------
local csv_rows = {}
local file = io.open(filepath, "r")
if not file then
  reaper.MB(
    "Could not open file:\n" .. filepath,
    "Import Tempo Map - Error", 0
  )
  return
end

local linenum = 0
for line in file:lines() do
  linenum = linenum + 1
  if linenum > 1 then  -- row 1 is the header, skip it
    local fields = {}
    -- Split on commas. Note: does not handle quoted fields containing commas,
    -- but all exported values (BPM, timepos, etc.) are numeric, so this is safe.
    for item in string.gmatch(line, "[^,]*") do
      if item ~= "" then
        item = item:gsub("^%s*(.-)%s*$", "%1")  -- trim leading/trailing whitespace
        table.insert(fields, item)
      end
    end
    -- A valid row has exactly 10 columns (skip any malformed/blank rows)
    if #fields >= 10 then
      table.insert(csv_rows, fields)
    end
  end
end
file:close()

if #csv_rows == 0 then
  reaper.MB(
    "No valid data rows found in:\n" .. filepath,
    "Import Tempo Map - Warning", 0
  )
  return
end

---------------------------------------------
-- COMPUTE BPM RANGE (used in conflict dialog)
---------------------------------------------
local minBPM, maxBPM = math.huge, -math.huge
for _, row in ipairs(csv_rows) do
  local bpm = tonumber(row[2])
  if bpm then
    if bpm < minBPM then minBPM = bpm end
    if bpm > maxBPM then maxBPM = bpm end
  end
end

local bpmStr
if math.abs(maxBPM - minBPM) < 0.001 then
  bpmStr = string.format("%.3f BPM (constant)", minBPM)
else
  bpmStr = string.format("%.3f - %.3f BPM", minBPM, maxBPM)
end

---------------------------------------------
-- HANDLE EXISTING TEMPO MARKERS
---------------------------------------------
local existingCount = reaper.CountTempoTimeSigMarkers(0)
local doOverwrite   = false

if existingCount > 0 then
  local msg = string.format(
    "CSV: %d marker(s)  |  %s\n\n"..
    "This project already has %d existing tempo marker(s).\n\n"..
    "Delete ALL existing markers before importing?\n\n"..
    "YES    = Overwrite: delete all existing markers, then import the new map (recommended)\n"..
    "NO     = Merge: add imported markers alongside existing ones (may cause conflicts at overlapping positions)\n"..
    "CANCEL = Abort import",
    #csv_rows, bpmStr, existingCount
  )
  local choice = reaper.MB(msg, "Import Tempo Map", 3)  -- 3 = Yes/No/Cancel dialog
  if choice == 2 then return end        -- Cancel (2)
  doOverwrite = (choice == 6)           -- Yes (6) = Overwrite, No (7) = Merge
end

---------------------------------------------
-- APPLY CHANGES WITH UNDO BLOCK
---------------------------------------------
reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

-- Overwrite mode: delete existing markers from highest index downward
-- (deleting top-down avoids index-shifting errors mid-loop)
if doOverwrite then
  local n = reaper.CountTempoTimeSigMarkers(0)
  for i = n - 1, 0, -1 do
    reaper.DeleteTempoTimeSigMarker(0, i)
  end
end

-- CSV column mapping (1-indexed, matching Export Tempo Map.lua v2.2):
--   1  = Marker N.         (index, not used for import)
--   2  = BPM
--   3  = Time Position     (seconds, raw float)
--   4  = Measure Position  (seconds, raw float)
--   5  = Beat              (formatted string, not used for import)
--   6  = Beat Position     (seconds, raw float)
--   7  = Samples           (formatted string, not used for import)
--   8  = Tempo Numerator   (integer)
--   9  = Tempo Denominator (integer)
--   10 = Tempo Linearity   ("0" = square/jump, "1" = linear/gradual)

local successCount = 0
local failCount    = 0

for _, row in ipairs(csv_rows) do
  local bpm           = tonumber(row[2])
  local timepos       = tonumber(row[3])
  local measurepos    = tonumber(row[4])
  local beatpos       = tonumber(row[6])
  local timesig_num   = tonumber(row[8])
  local timesig_denom = tonumber(row[9])
  local lineartempo   = (row[10] == "1")

  -- Only insert if all required numeric fields parsed successfully
  if bpm and timepos and measurepos and beatpos and timesig_num and timesig_denom then
    local ok = reaper.SetTempoTimeSigMarker(
      0, -1, timepos, measurepos, beatpos,
      bpm, timesig_num, timesig_denom, lineartempo
    )
    if ok then
      successCount = successCount + 1
    else
      failCount = failCount + 1
    end
  else
    failCount = failCount + 1
  end
end

reaper.UpdateTimeline()
reaper.PreventUIRefresh(-1)
reaper.Undo_EndBlock("Import Tempo Map", -1)

---------------------------------------------
-- REPORT RESULT
---------------------------------------------
if failCount == 0 then
  reaper.MB(
    string.format(
      "%d tempo marker(s) imported successfully.\n\n"..
      "Click OK, then click anywhere in the project to see the updated Tempo Envelope.",
      successCount
    ),
    version .. " - OK", 0
  )
else
  reaper.MB(
    string.format(
      "%d marker(s) imported, %d failed.\n\n"..
      "Failed rows may have missing or non-numeric values.\n\n"..
      "Click OK, then click anywhere in the project to see the Tempo Envelope.",
      successCount, failCount
    ),
    version .. " - WARNING", 0
  )
end