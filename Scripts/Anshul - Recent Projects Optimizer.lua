-- @description Recent Projects Optimizer
-- @author Anshul
-- @version 1.0.0
-- @about
--   Scans REAPER's recent projects list (via REAPER.ini) and safely removes duplicates 
--   (keeping the newest version) and missing/invalid project paths.
--   Compacts the remaining list so no blank gaps are left taking up the 100-slot budget.
--   Presents a confirmation dialog detailing exactly what will be removed.

local ini = reaper.get_ini_file()

local function GetFilename(path)
  return path:match('[/\\]([^/\\]+)$') or path
end

local function Main()
  -- 1. Read all recent projects sequentially from REAPER.ini
  local entries = {}
  local i = 1
  while true do
    local key = 'recent' .. string.format('%02d', i)
    local _, val = reaper.BR_Win32_GetPrivateProfileString('recent', key, 'noEntry', ini)
    if val == 'noEntry' or i > 200 then break end
    if val ~= '' and val ~= ' ' then
      table.insert(entries, { key = key, path = val })
    end
    i = i + 1
  end

  if #entries == 0 then return end

  -- 2. Process backwards from newest to oldest
  local seen_names = {}
  local keepers = {}
  local deleted_dupes = {}
  local deleted_invalids = {}

  for j = #entries, 1, -1 do
    local path = entries[j].path
    local filename = GetFilename(path):lower()

    if not reaper.file_exists(path) then
      table.insert(deleted_invalids, path)
    elseif seen_names[filename] then
      -- Duplicate filename found. Because we iterate backwards, we already
      -- kept the NEWEST one. This is an older path/duplicate to be removed.
      table.insert(deleted_dupes, path)
    else
      seen_names[filename] = true
      -- prepend to keepers so oldest stays at index 1
      table.insert(keepers, 1, path)
    end
  end

  local total_removed = #deleted_dupes + #deleted_invalids
  if total_removed == 0 then
    -- Nothing to do, silently exit
    return
  end

  -- 3. Prepare the confirmation prompt
  local msg = "ReaDashboard / Recent List Optimizer found dead weight eating your 100 slots:\n\n"
  
  if #deleted_invalids > 0 then
    msg = msg .. "--- Missing / Invalid Files ---\n"
    for _, p in ipairs(deleted_invalids) do
      msg = msg .. "- " .. GetFilename(p) .. "\n"
    end
    msg = msg .. "\n"
  end

  if #deleted_dupes > 0 then
    msg = msg .. "--- Duplicates (Older versions) ---\n"
    for _, p in ipairs(deleted_dupes) do
      -- Show full path for duplicates so user sees exactly which drive/symlink is dropped
      msg = msg .. "- " .. p .. "\n"
    end
    msg = msg .. "\n"
  end

  msg = msg .. "Proceed with safely packaging and optimizing the list?"

  -- 4. Prompt user
  local response = reaper.MB(msg, "Optimize Recent Projects", 4)
  if response ~= 6 then
    -- User clicked 'No'
    return
  end

  -- 5. Rewrite REAPER.ini securely
  -- First write the compacted 'keepers' sequentially starting at recent01
  for k = 1, #keepers do
    local key = 'recent' .. string.format('%02d', k)
    reaper.BR_Win32_WritePrivateProfileString('recent', key, keepers[k], ini)
  end

  -- Wipe the remaining keys at the tail end to prevent ghost duplicates
  for k = #keepers + 1, #entries do
    local key = 'recent' .. string.format('%02d', k)
    reaper.BR_Win32_WritePrivateProfileString('recent', key, ' ', ini)
  end

  -- Reload the recent list natively in REAPER UI if possible
  reaper.TrackList_AdjustWindows(false)
end

reaper.defer(Main)
