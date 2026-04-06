--[[
@description Import Moises Stems (Archive or Folder)
@author Anshul
@version 1.0
@about
  Imports all audio stems from a Moises archive or extracted folder into a structured
  folder track in REAPER.

  **Workflow:**
  1. Run this script
  2. Pick EITHER:
     - A Moises archive (.zip, .7z, etc.) — will extract first
     - Any audio stem file (.wav/.mp3/.m4a/.flac) in an already-extracted folder — will scan and import
  3. All stems are imported as child tracks with pre-set volumes
  4. Unrecognized audio files are added in a "Pass 2" sweep (future-proofs for new stems)

  **Supported Formats:** WAV, MP3, M4A, FLAC

  **Supported Archives:** ZIP, 7Z, RAR, tar.gz, tgz, tar.bz2, tar.xz

  **Requirements:**
  - js_ReaScriptAPI extension (install via Extensions > ReaPack)
  - Windows 10/11 (uses built-in tar/bsdtar for archive extraction)
  - Note: RAR archives are NOT supported by Windows built-in tar; use ZIP/7Z instead
@changelog
 v1.0 (2026-03-30)
   + Universal picker: archives OR audio files
   + Support for ZIP, 7Z, RAR, tar variants
   + Added stems: guitars, keys, piano, strings, synth
   + Pass 2 sweep for unknown audio files
]]

------------------------------------------------------------------------
-- Stem definitions
-- key: stem type string as it appears in Moises filenames
-- name: track name to create in REAPER
-- vol: linear volume  (0.50118... = -6 dB,  0.11050... = ~-19 dB)
-- Order defines the folder track layout (top to bottom)
-- Pass 2 handles any files not matched by these keys automatically.
------------------------------------------------------------------------

local STEMS = {
  { key = "vocals",    name = "Vocals",        vol = 0.50118723362727 },
  { key = "bass",      name = "Bass",          vol = 0.50118723362727 },
  { key = "drums",     name = "Drums",         vol = 0.50118723362727 },
  { key = "other",     name = "Others",        vol = 0.50118723362727 },
  { key = "metronome", name = "Metronome",     vol = 0.11050517374163 },
  { key = "rhythm",    name = "Rhythm Guitar", vol = 0.50118723362727 },
  { key = "lead",      name = "Lead Guitar",   vol = 0.50118723362727 },
  { key = "guitar",    name = "Guitar",        vol = 0.50118723362727 },
  { key = "guitars",   name = "Guitar",        vol = 0.50118723362727 },
  { key = "keys",      name = "Keys",          vol = 0.50118723362727 },
  { key = "piano",     name = "Piano",         vol = 0.50118723362727 },
  { key = "strings",   name = "Strings",       vol = 0.50118723362727 },
  { key = "synth",     name = "Synth",         vol = 0.50118723362727 },
}

-- Default directory the file picker opens in
-- Note: reaper.file_exists() returns false for directories; use os.rename() trick instead.
local INITIAL_DIR = "G:\\Moises Stems\\"
if not os.rename(INITIAL_DIR, INITIAL_DIR) then
  INITIAL_DIR = ""
end

-- Audio file extensions recognised as stems
local AUDIO_EXTS = { "%.wav$", "%.mp3$", "%.m4a$", "%.flac$" }

-- Archive file extensions (trigger extraction path)
local ARCHIVE_EXTS = { "%.zip$", "%.7z$", "%.rar$", "%.tgz$", "%.tar$",
                       "%.tar%.gz$", "%.tar%.bz2$", "%.tar%.xz$" }

------------------------------------------------------------------------
-- Guard: js_ReaScriptAPI required for the file picker
------------------------------------------------------------------------

if not reaper.JS_Dialog_BrowseForOpenFiles then
  reaper.MB(
    "This script requires the js_ReaScriptAPI extension.\n"
    .. "Install it via Extensions > ReaPack > Browse packages.",
    "Missing Extension", 0
  )
  return
end

------------------------------------------------------------------------
-- Helper: is a filename an audio file?
------------------------------------------------------------------------

local function is_audio(name)
  local lower = name:lower()
  for _, pat in ipairs(AUDIO_EXTS) do
    if lower:match(pat) then return true end
  end
  return false
end

------------------------------------------------------------------------
-- Helper: is a filename an archive?
------------------------------------------------------------------------

local function is_archive(name)
  local lower = name:lower()
  for _, pat in ipairs(ARCHIVE_EXTS) do
    if lower:match(pat) then return true end
  end
  return false
end

------------------------------------------------------------------------
-- Helper: scan a directory for stem audio files.
--
-- Pass 1: matches files against STEMS definitions by key.
-- Pass 2: collects any remaining audio files not matched by Pass 1
--         into the "extras" list (used to auto-import unknown stems).
--
-- Returns:
--   found   (table: stem_key -> full path)  -- known stems only
--   count   (number)                        -- # of known stems found
--   extras  (table: array of {path, label}) -- unknown audio files
------------------------------------------------------------------------

local function scan_for_stems(dir)
  local found  = {}
  local count  = 0
  local extras = {}
  local path   = dir
  if path:sub(-1) ~= "\\" then path = path .. "\\" end

  -- Collect all audio filenames first
  local all_audio = {}
  local idx = 0
  while true do
    local fname = reaper.EnumerateFiles(path, idx)
    if not fname or fname == "" then break end
    if is_audio(fname) then
      all_audio[#all_audio + 1] = fname
    end
    idx = idx + 1
  end

  -- Pass 1: match against known stem keys
  local matched_files = {}  -- track which files were matched
  for _, fname in ipairs(all_audio) do
    local lower = fname:lower()
    for _, stem in ipairs(STEMS) do
      if lower:find("%-" .. stem.key .. "%-")
      or lower:find("%-" .. stem.key .. "%.") then
        if not found[stem.key] then
          found[stem.key] = path .. fname
          count = count + 1
          matched_files[fname] = true
        end
        break
      end
    end
  end

  -- Pass 2: collect any audio files not matched in Pass 1
  for _, fname in ipairs(all_audio) do
    if not matched_files[fname] then
      -- Derive a human-readable label from the filename.
      -- Strategy: strip the audio extension, then take the last
      -- dash-separated segment before the key-pattern region.
      -- Simplest reliable fallback: use the bare filename without ext.
      local label = fname:match("^(.+)%.[^%.]+$") or fname
      -- If the filename has Moises-style dash-segments, try to extract
      -- the stem-type segment (the segment that isn't key/bpm/hz/key-sig)
      -- by scanning backwards for a segment that looks like a word label.
      -- For now we just clean it a bit: strip trailing " - Key BPM hz" junk.
      label = label:gsub("%-%s*[A-Ga-g][#b]?%s*[a-z]+%-%d+bpm%-%d+hz$", "")
      label = label:gsub("^%d+%.?%s*", "")  -- strip leading track number
      extras[#extras + 1] = { path = path .. fname, label = label }
    end
  end

  return found, count, extras
end

------------------------------------------------------------------------
-- Helper: deep-scan subdirectories (one level) for stems.
-- Used as a fallback when the archive extracts into an inner folder.
-- Returns the best (most stems) result found.
------------------------------------------------------------------------

local function scan_subdirs(dir)
  local best_found, best_count, best_extras = {}, 0, {}
  local si = 0
  while true do
    local subdir = reaper.EnumerateSubdirectories(dir, si)
    if not subdir or subdir == "" then break end
    local sf, sc, se = scan_for_stems(dir .. "\\" .. subdir)
    if sc > best_count then
      best_found, best_count, best_extras = sf, sc, se
    end
    si = si + 1
  end
  return best_found, best_count, best_extras
end

------------------------------------------------------------------------
-- Strip archive extension to get the destination folder name.
-- Handles double extensions (.tar.gz, .tar.bz2, .tar.xz) correctly.
------------------------------------------------------------------------

local function strip_archive_ext(name)
  local base = name:match("^(.+)%.tar%.[^%.]+$")
  if base then return base end
  return name:match("^(.+)%.[^%.]+$") or name
end

------------------------------------------------------------------------
-- File picker: accepts archive files OR any audio stem file
-- extensionList format: "Description\0*.ext\0...\0\0"
------------------------------------------------------------------------

local ok, selected_path = reaper.JS_Dialog_BrowseForOpenFiles(
  "Select Moises archive or any stem audio file",
  INITIAL_DIR,
  "",
  "Archive or Stem\0*.zip;*.7z;*.rar;*.tar;*.tgz;*.tar.gz;*.tar.bz2;*.tar.xz;*.wav;*.mp3;*.m4a;*.flac\0Archive files\0*.zip;*.7z;*.rar;*.tar;*.tgz;*.tar.gz;*.tar.bz2;*.tar.xz\0Audio files\0*.wav;*.mp3;*.m4a;*.flac\0All files\0*.*\0\0",
  false
)

if ok ~= 1 or not selected_path or selected_path == "" then
  return  -- user cancelled
end

------------------------------------------------------------------------
-- Determine mode: archive extraction vs. direct folder import
------------------------------------------------------------------------

local parent_dir, selected_name = selected_path:match("^(.+)[/\\]([^/\\]+)$")
if not parent_dir or not selected_name then
  reaper.MB("Could not parse selected file path:\n" .. selected_path, "Error", 0)
  return
end

local source_label      -- displayed in the summary message
local stem_dir          -- the directory we ultimately scan for stems
local is_zip_mode       -- true = extraction path,  false = direct folder path

if is_archive(selected_name) then
  is_zip_mode  = true
  source_label = selected_name
  local folder_name = strip_archive_ext(selected_name)
  stem_dir = parent_dir .. "\\" .. folder_name
else
  -- User picked an audio file — use its parent directory directly
  is_zip_mode  = false
  source_label = parent_dir:match("[^/\\]+$") or parent_dir
  stem_dir = parent_dir
end

------------------------------------------------------------------------
-- ZIP / Archive path: ensure dest dir exists, pre-check for stems,
-- then conditionally extract.
------------------------------------------------------------------------

local found, match_count, extras

if is_zip_mode then
  -- Ensure the destination directory exists (no-op if already present)
  reaper.RecursiveCreateDirectory(stem_dir, 0)

  -- --- PRE-CHECK (before touching tar) ---
  -- Scan root of dest dir first
  found, match_count, extras = scan_for_stems(stem_dir)

  -- If nothing found in root, check one level of subdirectories.
  -- This covers archives that extract into an inner folder.
  -- Doing this BEFORE extraction means we correctly detect already-
  -- extracted archives that have a nested layout, avoiding a slow
  -- redundant tar call.
  if match_count == 0 then
    found, match_count, extras = scan_subdirs(stem_dir)
  end

  local do_extract = true

  if match_count > 0 then
    local choice = reaper.MB(
      "Stems already exist in:\n"
      .. stem_dir
      .. "\n\nUse the existing extracted files?\n\n"
      .. "(Select 'No' to re-extract from the archive)",
      "Already Extracted",
      4  -- MB_YESNO
    )
    if choice == 6 then
      do_extract = false  -- reuse existing files
    end
  end

  -- --- EXTRACTION (only if needed) ---
  if do_extract then
    local safe_zip = selected_path:gsub('"', '\\"')
    local safe_dst = stem_dir:gsub('"', '\\"')
    local cmd = string.format('tar -xf "%s" -C "%s"', safe_zip, safe_dst)

    local handle     = io.popen(cmd .. " 2>&1")
    local tar_output = handle:read("*a")
    handle:close()

    if tar_output and tar_output:lower():match("error") then
      reaper.MB(
        "Archive extraction reported a problem:\n\n"
        .. tar_output:sub(1, 500)
        .. "\n\nAttempting to import any stems that were extracted.",
        "Extraction Warning", 0
      )
    end

    -- Re-scan after extraction
    found, match_count, extras = scan_for_stems(stem_dir)

    -- Fallback: nested layout inside archive
    if match_count == 0 then
      found, match_count, extras = scan_subdirs(stem_dir)
    end
  end

else
  -- --- DIRECT FOLDER PATH (user picked an audio file) ---
  found, match_count, extras = scan_for_stems(stem_dir)
end

------------------------------------------------------------------------
-- Final guard: nothing found
------------------------------------------------------------------------

if match_count == 0 and #extras == 0 then
  reaper.MB(
    "No Moises audio stems found in:\n" .. stem_dir
    .. "\n\nPossible causes:\n"
    .. "  - Archive extraction failed (check the warning above)\n"
    .. "  - The archive does not contain stems in a recognised format\n"
    .. "  - Filenames do not match the expected Moises pattern",
    "No Stems Found", 0
  )
  return
end

------------------------------------------------------------------------
-- Determine insertion point
-- Insert below the currently selected track; fall back to end-of-project.
------------------------------------------------------------------------

local base
local sel_track = reaper.GetSelectedTrack(0, 0)
if sel_track then
  local sel_idx = reaper.GetMediaTrackInfo_Value(sel_track, "IP_TRACKNUMBER") -- 1-based
  base = math.floor(sel_idx)  -- insert AT this index (0-based) = right after selection
else
  base = reaper.CountTracks(0)  -- fallback: end of project
end

------------------------------------------------------------------------
-- Build final ordered track list:
--   Pass 1: known STEMS (in definition order)
--   Pass 2: any extras not matched by Pass 1
-- The folder close marker goes on the very last child track.
------------------------------------------------------------------------

local track_list = {}

for _, stem in ipairs(STEMS) do
  if found[stem.key] then
    track_list[#track_list + 1] = {
      name = stem.name,
      vol  = stem.vol,
      path = found[stem.key],
    }
  end
end

for _, extra in ipairs(extras) do
  track_list[#track_list + 1] = {
    name = extra.label,
    vol  = 0.50118723362727,
    path = extra.path,
  }
end

local num_tracks = #track_list

------------------------------------------------------------------------
-- Create the folder track + child tracks
------------------------------------------------------------------------

reaper.PreventUIRefresh(1)
reaper.Undo_BeginBlock()

-- Parent folder track
reaper.InsertTrackAtIndex(base, false)
local folder_track = reaper.GetTrack(0, base)
reaper.GetSetMediaTrackInfo_String(folder_track, "P_NAME", "Moises Stems", true)
reaper.SetMediaTrackInfo_Value(folder_track, "I_FOLDERDEPTH", 1)
reaper.SetMediaTrackInfo_Value(folder_track, "D_VOL", 1.0)

for i, t in ipairs(track_list) do
  local track_idx = base + i
  reaper.InsertTrackAtIndex(track_idx, false)
  local track = reaper.GetTrack(0, track_idx)

  reaper.GetSetMediaTrackInfo_String(track, "P_NAME", t.name, true)
  reaper.SetMediaTrackInfo_Value(track, "D_VOL", t.vol)

  -- Close the folder on the last child track
  if i == num_tracks then
    reaper.SetMediaTrackInfo_Value(track, "I_FOLDERDEPTH", -1)
  else
    reaper.SetMediaTrackInfo_Value(track, "I_FOLDERDEPTH", 0)
  end

  reaper.SetEditCurPos(0, false, false)
  reaper.SetOnlyTrackSelected(track)
  reaper.InsertMedia(t.path, 0)
end

-- Deselect all tracks
reaper.Main_OnCommand(40297, 0)

reaper.Undo_EndBlock("Import Moises Stems", -1)
reaper.PreventUIRefresh(-1)
reaper.TrackList_AdjustWindows(false)
reaper.UpdateArrange()

------------------------------------------------------------------------
-- Summary message
------------------------------------------------------------------------

local imported = {}
local missing  = {}

-- Known stems: report which were found and which weren't
local reported_keys = {}
for _, stem in ipairs(STEMS) do
  if not reported_keys[stem.key] then
    reported_keys[stem.key] = true
    if found[stem.key] then
      imported[#imported + 1] = "  [+] " .. stem.name
    else
      -- Only flag as missing if this key has siblings that were found
      -- (avoids flooding the list with every optional stem)
      -- Heuristic: only show 'missing' for the 7 core Moises stems
      local core = { vocals=1, bass=1, drums=1, other=1,
                     metronome=1, rhythm=1, lead=1 }
      if core[stem.key] then
        missing[#missing + 1] = "  [ ] " .. stem.name .. "  (not found)"
      end
    end
  end
end

-- Extra (sweep-up) stems
for _, extra in ipairs(extras) do
  imported[#imported + 1] = "  [+] " .. extra.label .. "  (auto-detected)"
end

local total_imported = match_count + #extras
local msg = string.format(
  "Done! Imported %d stem(s) into 'Moises Stems' folder track.\n\n"
  .. "Source: %s\n\n%s",
  total_imported,
  source_label,
  table.concat(imported, "\n")
    .. (#missing > 0 and "\n" .. table.concat(missing, "\n") or "")
)

reaper.MB(msg, "Moises Stems Importer", 0)
