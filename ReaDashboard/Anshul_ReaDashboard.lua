-- @description ReaDashboard
-- @version 1.0.4
-- @author Anshul
-- @credits solger (for ReaLauncher concept)
-- @about
--   A modern, feature-rich project dashboard for REAPER built with ReaImGui.
--   Browse, search, filter, and manage your projects with metadata, tags, and album art.
--
--   **Requirements:**
--   - ReaImGui
--   - SWS Extensions
-- @changelog
--
--   v1.0.4
--     + Persistent mode — keep script running in background for instant re-open (toggle in Settings)
--     + Close on unfocus — automatically close/hide when clicking outside the window (toggle in Settings)
--     + Close on Escape — make Escape key close/hide behavior configurable (on by default)
--     + Toolbar toggle highlighting — toolbar button now reflects script open/closed state
--
--   v1.0.3
--     + Last Opened sort mode — native REAPER recent order (last opened project first)
--     + Multiple project folder paths — scan additional folders alongside the primary path
--     + Configurable image loading budgets — tune first-frame and per-frame budgets in Settings
--     + Default artwork path — fallback image when project has no art (configurable in Settings)
--     + Full project name on placeholder — show full name instead of initials when art is missing
--     + Custom statuses — add your own status presets via Settings (comma-separated)
--     + Expanded built-in statuses — added Recording, Mixing, On Hold, Released
--
--   v1.0.2
--     + LUA Slot cleanup to free 48 slots by CFG refactor
--
--   v1.0.1 (2026-04-09)
--
--     + Bulk Tag Editor — edit tags across multiple selected projects at once
--     + Configurable Primary Genres — customize genre list from Settings
--     + Grid Card Tooltip Mode — show metadata fields as hover tooltip instead of on-card
--     + Grid Card Fields — added Tuning and Transpose as optional card/tooltip fields
--     + Grid Tooltip Delay — configurable hover delay for grid card tooltips
--     + Configurable Grid Spacing — adjustable card spacing in Settings
--
--   v1.0.0 (2026-04-06)
--
--     + Initial release

-- ============================================================================
-- DEPENDENCY CHECKS
-- ============================================================================

local function CheckDependency(name, testFn, installHint)
  local ok = pcall(testFn)
  if not ok then
    reaper.MB(
      name .. ' is required but not found.\n\n' .. (installHint or 'Please install it via ReaPack.'),
      'ReaDashboard — Missing Dependency', 0
    )
    return false
  end
  return true
end

if not CheckDependency('ReaImGui',
  function() assert(reaper.ImGui_GetBuiltinPath) end,
  'Install ReaImGui from ReaPack:\nExtensions > ReaPack > Browse packages > search "ReaImGui"'
) then return end

if not CheckDependency('SWS Extensions',
  function() assert(reaper.BR_Win32_GetPrivateProfileString) end,
  'Download SWS from https://www.sws-extension.org/'
) then return end

local HAS_JS_API = reaper.JS_File_Stat ~= nil

-- ============================================================================
-- SINGLE-INSTANCE GUARD (before ImGui require — avoids ~1-5ms bootstrap cost on re-trigger)
-- Prevents duplicate windows. If an instance is already running, optionally
-- signal it to toggle visibility (close_on_new_instance) and exit immediately.
-- Always active — there is no use case for multiple ReaDashboard windows.
-- ============================================================================
local RD_EXT = 'ReaDashboard'  -- ExtState section for instance management
do
  local running = reaper.GetExtState(RD_EXT, 'instance_running') == '1'
  if running then
    -- Verify the instance is actually alive via heartbeat (guards against crash-orphaned flag)
    local hb = tonumber(reaper.GetExtState(RD_EXT, 'instance_heartbeat')) or 0
    if reaper.time_precise() - hb < 10 then
      -- Instance is alive — send toggle request if setting allows, then exit
      local coni = reaper.GetExtState(RD_EXT, 'close_on_new_instance')
      if coni ~= '0' then  -- default ON (empty or '1' = ON)
        reaper.SetExtState(RD_EXT, 'toggle_request', '1', false)
      end
      return
    end
    -- Heartbeat stale (>10s) — previous instance is dead, clear all flags and cold start
    reaper.DeleteExtState(RD_EXT, 'instance_running', false)
    reaper.DeleteExtState(RD_EXT, 'instance_heartbeat', false)
    reaper.DeleteExtState(RD_EXT, 'toggle_request', false)
  end
end

-- Register instance IMMEDIATELY after guard succeeds (before anything else)
-- This closes the TOCTOU window where a second launch could bypass the guard
reaper.SetExtState(RD_EXT, 'instance_running', '1', false)
reaper.SetExtState(RD_EXT, 'instance_heartbeat', tostring(reaper.time_precise()), false)
reaper.SetExtState(RD_EXT, 'close_on_new_instance', '1', false)  -- default ON; will be overridden by LoadState

-- ============================================================================
-- IMGUI MODULE
-- ============================================================================

package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.10'

-- ============================================================================
-- SCRIPT CONSTANTS (consolidated into CFG table to stay under Lua's 200-local limit)
-- ============================================================================

local CFG = {
  -- Script identity
  SCRIPT_NAME    = 'ReaDashboard',
  SCRIPT_VERSION = '1.0.4',
  EXT_SECTION    = 'ReaDashboard',

  -- Window defaults
  DEFAULT_W = 1050,
  DEFAULT_H = 650,

  -- Sort modes
  SORT_NEWEST    = 1,
  SORT_OLDEST    = 2,
  SORT_AZ        = 3,
  SORT_ZA        = 4,
  SORT_ARTIST_AZ = 5,
  SORT_TITLE_AZ  = 6,
  SORT_RECENT    = 7,
  SORT_LABELS = { 'Newest', 'Oldest', 'A → Z', 'Z → A', 'Artist A→Z', 'Title A→Z', 'Last Opened' },

  -- Spicetify key mapping: numeric key (0-11) to note name
  KEY_NAMES = {
    [0] = 'C', [1] = 'C#', [2] = 'D', [3] = 'Eb', [4] = 'E', [5] = 'F',
    [6] = 'F#', [7] = 'G', [8] = 'Ab', [9] = 'A', [10] = 'Bb', [11] = 'B',
  },
  MODE_NAMES = { [0] = 'minor', [1] = 'major' },

  -- Tag presets (commonly used tunings first)
  TUNING_PRESETS = {
    'Drop D', 'Drop A', 'E Standard',             -- most used (top)
    'Eb Standard', 'D Standard',                   -- standard variants
    'Drop C#', 'Drop C', 'Drop B', 'Drop Bb',     -- drop tunings (descending)
    'Drop Ab', 'Drop G',
    'Open D', 'Open G', 'DADGAD',                  -- alternate tunings
    'Custom',
  },

  -- Transpose presets (semitones, applied via Neural DSP transpose plugin)
  TRANSPOSE_PRESETS = {
    '0 (none)', '-1', '-2', '-3', '-4', '-5', '-6',
    '+1', '+2',
  },

  -- Guitar presets
  GUITAR_PRESETS = {
    'Gibson', 'Fender', 'PRS', 'Ibanez', 'ESP', 'Schecter', 'Jackson', 'Custom',
  },

  STATUS_PRESETS = {
    'Practicing', 'Learning', 'Need to Learn',
    'WIP', 'Recording', 'Mixing', 'Complete', 'Released',
    'Needs Mixing', 'On Hold', 'Abandoned',
  },
  STATUS_COLORS = {
    Practicing        = 0x6EB5DEFF,
    Learning          = 0x9B8FD6FF,
    ['Need to Learn'] = 0xC49A6CFF,
    WIP               = 0xE8B84DFF,
    Recording         = 0xE85D5DFF,
    Mixing            = 0x5DB8E8FF,
    Complete          = 0x4DB870FF,
    Released          = 0x70C470FF,
    ['Needs Mixing']  = 0x4A8FB8FF,
    ['On Hold']       = 0x8C8C8CFF,
    Abandoned         = 0xB84D4DFF,
  },
  STATUS_DEFAULT_COLOR = 0x9E9E9EFF,  -- neutral gray for custom statuses

  DIFFICULTY_PRESETS = { 'Easy', 'Medium', 'Hard', 'Insane' },

  STRING_FILTER_OPTIONS = { 'All', '6', '7', '8', 'Unset' },
  STATUS_FILTER_OPTIONS = { 'All', 'Practicing', 'Learning', 'Need to Learn', 'WIP', 'Recording', 'Mixing', 'Complete', 'Released', 'Needs Mixing', 'On Hold', 'Abandoned', 'Unset' },
  -- Coverage dropdown removed (2026-03-24) — tri-state buttons (Meta/Art/Tags) fully replace it

  -- External data paths (READ-ONLY)
  ART_FILE_PREFS = { 'Spotify.jpg', 'iTunes.jpg', 'LastFM.png' },

  -- Font & art size defaults
  DEFAULT_FONT_SIZE = 14,
  MIN_FONT_SIZE     = 10,
  MAX_FONT_SIZE     = 24,

  DEFAULT_ART_SIZE  = 36,   -- thumbnail pixels (before scale)
  MIN_ART_SIZE      = 20,
  MAX_ART_SIZE      = 80,

  -- Grid card size defaults
  DEFAULT_GRID_CARD_SIZE = 200,
  MIN_GRID_CARD_SIZE     = 100,
  MAX_GRID_CARD_SIZE     = 500,

  -- Custom album art filenames to look for in project folders (highest priority)
  PROJECT_ART_NAMES = { 'cover.jpg', 'cover.png', 'folder.jpg', 'folder.png', 'art.jpg', 'art.png' },

  -- All-projects browser: scan path, cache, limits (configurable via Settings)
  -- ALL_PROJECTS_PATH and ALL_SCAN_MAX_DEPTH are in S table (see STATE section)
  ALL_SCAN_EXCLUDED = {},  -- folder names to skip (empty for now, configurable later)

  -- Grid card text line height (configurable)
  DEFAULT_GRID_LINE_H = 14,
  MIN_GRID_LINE_H     = 10,
  MAX_GRID_LINE_H     = 24,

  -- Date formatting
  MONTH_NAMES = { 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec' },

  -- Spicetify artist matching
  ARTIST_ABBREVIATIONS = {
    ['bfmv']       = 'bullet for my valentine',
    ['log']        = 'lamb of god',
  },
  ARTIST_VARIANTS = {
    ['tesseract']    = 'tesseract',   -- case matters in filenames: TesseracT
    ['novelistsfr']  = 'novelists',   -- Novelists FR → NOVELISTS in spicetify DB
    ['paulgilbert']  = 'racerx',      -- Paul Gilbert covers are Racer X originals in DB
  },

  -- Suffixes to strip from project song names when matching (lowercase)
  STRIP_SUFFIXES = {
    'practice', 'shorter', 'old', 'copy', 'backup', 'v2', 'v3', 'mix', 'demo', 'new',
    'only solo', 'guitar pro', 'gp midi', 'gp new', 'dark loop', 'tempo map experiment',
    'stephen ndsp', 'nail the mix', 'live', 'imported', 'stems', 'redo',
    'mk slicer test', 'quantize test', 'test', 'tone test',
    'extended intro', 'guitar hero', 'reel', 'midi',
    'full',  -- keep last: strips after inner suffixes (e.g. "Full New" → strip new → strip full)
  },

  -- Primary genre map: first-genre string (lowercase) → short display label
  PRIMARY_GENRE_MAP = {
    ['djent']              = 'Djent',
    ['progressive metal']  = 'Prog',
    ['progressive rock']   = 'Prog',
    ['progressive']        = 'Prog',
    ['guitar instrumental']= 'Prog',
    ['thrash metal']       = 'Metal',
    ['groove metal']       = 'Metal',
    ['heavy metal']        = 'Metal',
    ['death metal']        = 'Metal',
    ['power metal']        = 'Metal',
    ['alternative metal']  = 'Metal',
    ['metalcore']          = 'Metal',
    ['post-hardcore']      = 'Metal',
    ['nu-metal']           = 'Metal',
    ['hard rock']          = 'Rock',
    ['classic rock']       = 'Rock',
    ['blues rock']         = 'Rock',
    ['soft rock']          = 'Rock',
    ['alternative rock']   = 'Indie',
    ['indie rock']         = 'Indie',
    ['indie folk']         = 'Indie',
    ['indie']              = 'Indie',
    ['alternative']        = 'Indie',
    ['post-rock']          = 'Indie',
    ['jazz']               = 'Jazz',
    ['fusion']             = 'Jazz',
    ['pop']                = 'Pop',
    ['synth-pop']          = 'Pop',
    ['electropop']         = 'Pop',
    ['blues']              = 'Blues',
    ['delta blues']        = 'Blues',
    ['chicago blues']      = 'Blues',
    ['country blues']      = 'Blues',
  },

  -- Ordered list of primary genres for dropdowns and quick-set menus
  PRIMARY_GENRES = { 'Djent', 'Prog', 'Metal', 'Rock', 'Pop', 'Blues', 'Indie', 'Jazz' },

  -- Genre filter dropdown options (index 1 = All; rest must match PRIMARY_GENRE_MAP values)
  GENRE_FILTER_OPTIONS = { 'All', 'Djent', 'Prog', 'Metal', 'Rock', 'Pop', 'Blues', 'Indie', 'Jazz', 'Unset' },

  -- Image loading
  DEFER_IMAGES = true,
}

-- Build tuning filter options from presets (All + each tuning preset + Unset)
CFG.TUNING_FILTER_OPTIONS = { 'All' }
for _, t in ipairs(CFG.TUNING_PRESETS) do
  CFG.TUNING_FILTER_OPTIONS[#CFG.TUNING_FILTER_OPTIONS + 1] = t
end
CFG.TUNING_FILTER_OPTIONS[#CFG.TUNING_FILTER_OPTIONS + 1] = 'Unset'

-- ============================================================================
-- COLOR THEME
-- Dark, neutral, minimal. All values are 0xRRGGBBAA.
-- ============================================================================

local C = {
  -- Backgrounds
  windowBg        = 0x1B1B1BFF,
  childBg         = 0x202020FF,
  popupBg         = 0x242424F2,
  titleBg         = 0x151515FF,
  titleBgActive   = 0x1B1B1BFF,

  -- Text
  text            = 0xDCDCDCFF,
  textDim         = 0x808080FF,
  textDisabled    = 0x555555FF,

  -- Borders & separators
  border          = 0x2F2F2FFF,
  separator       = 0x2F2F2FFF,

  -- Buttons
  button          = 0x2A2A2AFF,
  buttonHov       = 0x363636FF,
  buttonAct       = 0x424242FF,

  -- Headers (table headers, collapsing headers)
  header          = 0x282828FF,
  headerHov       = 0x333333FF,
  headerAct       = 0x3E3E3EFF,

  -- Frame (input fields, combos)
  frameBg         = 0x232323FF,
  frameBgHov      = 0x2C2C2CFF,
  frameBgAct      = 0x333333FF,

  -- Scrollbar
  scrollBg        = 0x1B1B1BFF,
  scrollGrab      = 0x3A3A3AFF,
  scrollGrabHov   = 0x4A4A4AFF,
  scrollGrabAct   = 0x555555FF,

  -- Tabs
  tab             = 0x1E1E1EFF,
  tabHov          = 0x333333FF,
  tabAct          = 0x282828FF,

  -- Table
  tableHeaderBg   = 0x252525FF,
  tableBorderH    = 0x2F2F2FFF,
  tableBorderL    = 0x262626FF,
  tableRowBg      = 0x1B1B1B00, -- transparent (RowBg flag handles alternation)
  tableRowBgAlt   = 0x1F1F1F40,

  -- Accent
  accent          = 0x4A8FB8FF,
  accentHov       = 0x5DA3CCFF,
  accentAct       = 0x3D7A9FFF,

  -- Selection highlight
  selection       = 0x2D5F85CC,

  -- Misc
  checkMark       = 0x6EB5DEFF,
  navHighlight    = 0x4A8FB8FF,

  -- Tag indicator colors
  favStar         = 0xE8C84DFF,
}

-- Theme presets (accent RGB values, no alpha)
local THEME_PRESETS = {
  { name = 'Blue',   accent = 0x4A8FB8 },
  { name = 'Teal',   accent = 0x4A9B8F },
  { name = 'Purple', accent = 0x7B68AE },
  { name = 'Orange', accent = 0xB87A4A },
  { name = 'Red',    accent = 0xB85050 },
}

-- Full theme base presets (bg, text, accent, rounding, density)
local THEME_BASE_PRESETS = {
  { name = 'Default',  bg = 0x1B1B1B, text = 0xDCDCDC, accent = 0x4A8FB8, rounding = 4, density = 50 },
  { name = 'Darker',   bg = 0x121212, text = 0xE0E0E0, accent = 0x4A8FB8, rounding = 4, density = 50 },
  { name = 'Midnight', bg = 0x151820, text = 0xD4D8E0, accent = 0x5B8FC9, rounding = 5, density = 50 },
}

-- Density interpolation endpoints: [1]=compact (density=0), [2]=spacious (density=100)
local DENSITY_RANGE = {
  { win_px=8, win_py=6, frm_px=6, frm_py=3, itm_px=6, itm_py=4, cel_px=4, cel_py=2, scroll=10 },
  { win_px=16, win_py=14, frm_px=10, frm_py=7, itm_px=10, itm_py=8, cel_px=8, cel_py=6, scroll=14 },
}

-- Theme color utility functions (consolidated into table to save top-level local slots)
local TU = {}
function TU.rgb(v) -- extract R,G,B from 0xRRGGBB
  return math.floor(v / 0x10000) % 0x100, math.floor(v / 0x100) % 0x100, v % 0x100
end
function TU.cl(v) return math.max(0, math.min(255, math.floor(v))) end
function TU.rgba(r, g, b, a) return r * 0x1000000 + g * 0x10000 + b * 0x100 + a end

function TU.applyAccent(rgb)
  local r, g, b = TU.rgb(rgb)
  local c, mk = TU.cl, TU.rgba
  C.accent       = mk(r, g, b, 0xFF)
  C.accentHov    = mk(c(r*1.2), c(g*1.2), c(b*1.2), 0xFF)
  C.accentAct    = mk(c(r*0.85), c(g*0.85), c(b*0.85), 0xFF)
  C.selection    = mk(c(r*0.6), c(g*0.6), c(b*0.6), 0xCC)
  C.checkMark    = mk(c(r*1.3), c(g*1.3), c(b*1.3), 0xFF)
  C.navHighlight = mk(r, g, b, 0xFF)
end

function TU.applyBg(rgb)
  local r, g, b = TU.rgb(rgb)
  local c, mk = TU.cl, TU.rgba
  local function off(d, a) return mk(c(r+d), c(g+d), c(b+d), a) end
  C.windowBg      = mk(r, g, b, 0xFF)
  C.childBg       = off(5, 0xFF)
  C.popupBg       = off(9, 0xF2)
  C.titleBg       = off(-6, 0xFF)
  C.titleBgActive = mk(r, g, b, 0xFF)
  C.frameBg       = off(8, 0xFF)
  C.frameBgHov    = off(17, 0xFF)
  C.frameBgAct    = off(24, 0xFF)
  C.button        = off(15, 0xFF)
  C.buttonHov     = off(27, 0xFF)
  C.buttonAct     = off(39, 0xFF)
  C.header        = off(13, 0xFF)
  C.headerHov     = off(24, 0xFF)
  C.headerAct     = off(35, 0xFF)
  C.scrollBg      = mk(r, g, b, 0xFF)
  C.scrollGrab    = off(31, 0xFF)
  C.scrollGrabHov = off(47, 0xFF)
  C.scrollGrabAct = off(58, 0xFF)
  C.tab           = off(3, 0xFF)
  C.tabHov        = off(24, 0xFF)
  C.tabAct        = off(13, 0xFF)
  C.tableHeaderBg = off(10, 0xFF)
  C.tableBorderH  = off(20, 0xFF)
  C.tableBorderL  = off(11, 0xFF)
  C.tableRowBg    = mk(r, g, b, 0x00)
  C.tableRowBgAlt = off(4, 0x40)
end

function TU.applyText(rgb, dim_pct)
  local r, g, b = TU.rgb(rgb)
  local c, mk = TU.cl, TU.rgba
  C.text = mk(r, g, b, 0xFF)
  local df = dim_pct / 100
  C.textDim = mk(c(r*df), c(g*df), c(b*df), 0xFF)
  C.textDisabled = mk(c(r*0.35), c(g*0.35), c(b*0.35), 0xFF)
end

function TU.applyBorders(show, bg_rgb)
  if show then
    local r, g, b = TU.rgb(bg_rgb)
    local c, mk = TU.cl, TU.rgba
    C.border       = mk(c(r+20), c(g+20), c(b+20), 0xFF)
    C.separator    = mk(c(r+20), c(g+20), c(b+20), 0xFF)
    C.tableBorderH = mk(c(r+20), c(g+20), c(b+20), 0xFF)
    C.tableBorderL = mk(c(r+11), c(g+11), c(b+11), 0xFF)
  else
    C.border       = 0x00000000
    C.separator    = 0x00000000
    C.tableBorderH = 0x00000000
    C.tableBorderL = 0x00000000
  end
end

function TU.applyAltRow(enabled, bg_rgb)
  if enabled then
    local r, g, b = TU.rgb(bg_rgb)
    C.tableRowBgAlt = TU.rgba(TU.cl(r+8), TU.cl(g+8), TU.cl(b+8), 0x70)
  else
    C.tableRowBgAlt = 0x00000000
  end
end

function TU.applyStar(rgb)
  local r, g, b = TU.rgb(rgb)
  C.favStar = TU.rgba(r, g, b, 0xFF)
end

-- (RecomputeTheme is declared after S table — needs S in scope)

-- ============================================================================
-- STATE
-- ============================================================================

local ctx         = nil
local font        = nil   -- single font object (0.10 API: size set at PushFont time)

-- Consolidated state table (avoids Lua 200-local-variable limit)
local S = {
  -- Paths and Integrations
  enable_spicetify  = false,
  spicetify_db_path = '',
  album_art_db_path = '',
  symlink_src       = '',
  symlink_dest      = '',
  ALL_PROJECTS_PATH = '',

  -- Size settings (persisted via ExtState)
  font_size      = CFG.DEFAULT_FONT_SIZE,
  art_size       = CFG.DEFAULT_ART_SIZE,
  grid_card_size = CFG.DEFAULT_GRID_CARD_SIZE,
  grid_spacing   = 8,

  -- Data lists
  filtered_projects = {},
  selected_idx      = 0,
  recent_projects   = {},   -- from REAPER.ini
  all_projects      = {},   -- from recursive scan
  all_projects_loaded = false,

  -- UI state
  search_buf  = '',
  recent_sort_mode = CFG.SORT_NEWEST,  -- current session sort for Recent tab
  all_sort_mode    = CFG.SORT_AZ,      -- current session sort for All Projects tab
  sort_mode        = CFG.SORT_NEWEST,  -- active sort (set from tab's sort mode)
  default_recent_sort = CFG.SORT_NEWEST, -- default sort applied on script launch (persisted)
  default_all_sort    = CFG.SORT_AZ,     -- default sort applied on script launch (persisted)
  artist_sort_by_album = false,      -- group by album within Artist A→Z sort
  view_mode   = 'list',  -- 'list' or 'grid' (active, set from per-tab view)
  recent_view_mode = 'list',
  all_view_mode    = 'list',
  active_tab  = 'recent',  -- 'recent', 'all', or 'settings'
  universal_search = true,
  auto_focus_search = false,  -- auto-focus search bar on script open
  recent_count_in_filtered = 0,
  keep_open   = true,
  persistent_mode       = false,  -- keep script alive in background when window closed
  close_on_new_instance = true,   -- re-triggering action closes/hides the running instance
  close_on_unfocus      = false,  -- close/hide when window loses focus
  close_on_escape       = true,   -- Escape key can close/hide window (default ON: backward compat)
  is_hidden             = false,  -- runtime: true when persistent mode hid the window
  had_focus             = false,  -- runtime: guard for close_on_unfocus (only trigger after first focus)
  hidden_since          = 0,      -- runtime: reaper.time_precise() timestamp when window was hidden
  force_exit            = false,  -- runtime: bypass persistent hide, force full termination
  _refocus_next_frame   = false,  -- runtime: deferred SetNextWindowFocus after persistent re-show
  _save_pending         = false,  -- runtime: deferred SaveState on next hidden frame
  grid_cols   = 5,
  tab_restored = false,

  -- Grid card display toggles
  grid_show_artist = false,
  grid_show_bpm_key = false,
  grid_show_status = false,
  grid_line_h = CFG.DEFAULT_GRID_LINE_H,
  show_art_placeholder = true,
  needs_load  = true,
  window_open = true,

  -- Filter state (active values — swapped on tab switch from per-tab storage)
  filter_strings  = 1,
  filter_tuning   = 1,
  filter_status   = 1,
  filter_favs     = false,
  filter_genre    = 1,  -- 1=All; index into CFG.GENRE_FILTER_OPTIONS
  filter_tri_meta = 0,  -- 0=neutral, 1=require, 2=exclude
  filter_tri_art  = 0,
  filter_tri_tags = 0,
  filter_exclude_recents = false,  -- All Projects tab: hide projects in recent list
  filter_include_all     = false,  -- Recent tab: append all-projects after recents

  -- Per-tab filter storage
  recent_filter_strings  = 1,
  recent_filter_tuning   = 1,
  recent_filter_status   = 1,
  recent_filter_favs     = false,
  recent_filter_genre    = 1,
  recent_filter_tri_meta = 0,
  recent_filter_tri_art  = 0,
  recent_filter_tri_tags = 0,
  recent_filter_exclude_recents = false,
  recent_filter_include_all     = false,
  all_filter_strings  = 1,
  all_filter_tuning   = 1,
  all_filter_status   = 1,
  all_filter_favs     = false,
  all_filter_genre    = 1,
  all_filter_tri_meta = 0,
  all_filter_tri_art  = 0,
  all_filter_tri_tags = 0,
  all_filter_exclude_recents = false,

  -- Per-tab filtered counts for tab labels
  recent_filtered_count = 0,
  all_filtered_count    = 0,

  -- Bulk tag clear confirmation
  confirm_bulk_clear_tag = nil,  -- { field = 'status'|'strings'|'tuning', projects = {...} }
  bulk_tag_edit_projects = nil,  -- list of projects for bulk tag editor
  bulk_tag_edit_pending = false, -- one-shot flag to open the modal

  -- Universal whitelist: projects here always show regardless of hidden/exclusion/dedupe
  whitelist            = {},  -- path → true
  dedupe_variants      = {},  -- computed by ApplyDedupe for display
  dedupe_mode          = 'standard',  -- 'standard' or 'aggressive'

  -- All-Projects dedup & exclusion
  excluded_projects = {},  -- computed by ApplyExclusions for display in Settings
  all_display_count = 0,
  show_dedupe = 1,  -- tri-state: 0=dedupe active, 1=show all/disabled (default), 2=show only variants
  exclusion_patterns = '',
  hidden_projects = {},
  show_hidden = 0,     -- tri-state: 0=hide hidden (default), 1=show all, 2=show only hidden
  show_excluded = 0,   -- tri-state: 0=hide excluded (default), 1=show all, 2=show only excluded

  -- Tag editor state
  tag_edit_pending = false,
  tag_edit_proj = nil,
  tag_edit_snapshot = '',
  tag_editor_w = 480,
  tag_editor_h = 640,

  -- Confirmation dialog state
  confirm_remove_proj  = nil,       -- single remove from recent
  confirm_remove_bulk  = nil,       -- table of projects for bulk remove from recent
  confirm_remove_invalid = false,
  invalid_count = 0,
  confirm_hide_proj    = nil,       -- single hide
  confirm_hide_bulk    = nil,       -- table of projects for bulk hide
  confirm_unfav_proj   = nil,       -- single remove-from-favorites
  confirm_unfav_bulk   = nil,       -- table of projects for bulk remove-from-favorites

  -- Theme push/pop counters
  pushed_colors = 0,
  pushed_vars   = 0,

  -- Configurable settings (persisted)
  ALL_PROJECTS_PATH  = '',         -- primary path (legacy, for backward compat)
  additional_project_paths = {},   -- additional scan paths (list of strings)
  default_artwork_path = '',  -- fallback art when project has no art
  placeholder_full_name = false,  -- show full project name on placeholder instead of initials
  debug_logging = false,
  ALL_SCAN_MAX_DEPTH = 10,
  IMAGE_BATCH_SIZE   = 5,
  img_first_frame_ms = 32,   -- ms budget for image loading on first frame
  img_per_frame_ms   = 16,   -- ms budget for image loading on subsequent frames

  -- Cache/scan state
  spicetify_scanned = false,
  cache_loaded = false,
  frame_count = 0,

  -- Multi-select
  selected = {},       -- {[idx]=true} selection set
  sel_anchor = 0,      -- anchor index for Shift+Click range select

  -- Grid card field toggles (additional — the 3 originals are above)
  grid_show_favorite   = true,
  grid_show_duration   = false,
  grid_show_strings    = false,
  grid_show_album      = false,
  grid_show_genre      = false,
  grid_show_difficulty = false,
  grid_show_date       = false,
  grid_show_as_tooltip = true,  -- ON: selected fields show in tooltip on hover; OFF: fields render on card
  grid_show_tuning     = false,
  grid_show_transpose  = false,
  grid_tooltip_delay   = 0.0,   -- seconds (0.0 = instant)

  -- Configurable primary genres (comma-separated)
  custom_primary_genres = 'Djent,Prog,Metal,Rock,Pop,Blues,Indie,Jazz',
  custom_statuses = '',  -- comma-separated custom statuses (appended to built-in list)

  -- Color theme
  accent_color  = 0x4A8FB8,  -- RGB (no alpha), default blue
  theme_preset  = 1,         -- index into THEME_PRESETS

  -- Appearance settings (persisted)
  bg_color         = 0x1B1B1B,  -- RGB base background color
  text_color       = 0xDCDCDC,  -- RGB main text color
  fav_star_color   = 0xE8C84D,  -- RGB favorite star color
  dim_text_pct     = 50,        -- dim text brightness as % of text color (50-100)
  window_opacity   = 1.0,       -- window background alpha (0.3-1.0)
  corner_rounding  = 4,         -- base rounding in px (0-12)
  density          = 50,        -- spacing density 0=compact, 50=normal, 100=spacious
  show_borders     = true,      -- show borders and separators
  alt_row_bg       = true,      -- alternating row backgrounds in table
  theme_base_preset = 1,        -- index into THEME_BASE_PRESETS (1=Default, 2=Darker, 3=Midnight)

  -- Fade-in animation
  fade_in_duration = 0.15,  -- seconds (0 = disabled, persisted)
  anim_alpha = 0.0,         -- 0.0 = invisible, 1.0 = fully visible. Ramps up on open. (not persisted)

  -- Follow Actions (REAPER Command IDs triggered after certain operations)
  followaction_load_project = '',      -- after loading a project
  followaction_load_in_tab  = '',      -- after loading a project in a new tab
  followaction_new_tab      = '',      -- after opening a new empty tab

  -- Search history
  search_history = {},         -- circular buffer of recent searches (newest first)
  search_history_max = 8,      -- max entries to keep
  search_history_enabled = true, -- toggle in Settings
  search_history_idx = 0,      -- current Up/Down arrow index (0 = live input, 1+ = history)
  search_buf_live = '',        -- live input before arrow navigation started
  search_history_callback = nil,  -- EEL callback function for InputTextFlags_CallbackHistory

  -- Programmatic tab switching (set by keyboard shortcut, consumed by tab drawing code)
  pending_tab = nil,  -- nil or 'recent'/'all'/'settings'/'actions'
}

--- Recompute all derived theme colors from current S state. Call after any theme setting change.
local function RecomputeTheme()
  TU.applyBg(S.bg_color)
  TU.applyText(S.text_color, S.dim_text_pct)
  TU.applyAccent(S.accent_color)
  TU.applyBorders(S.show_borders, S.bg_color)
  TU.applyAltRow(S.alt_row_bg, S.bg_color)
  TU.applyStar(S.fav_star_color)
end

-- Active source list (set to S.recent_projects or S.all_projects)
local projects = {}

-- Tag editor form fields (complex table, kept standalone)
local tag_edit = {
  strings    = '',
  tuning     = '',
  transpose  = '',
  status     = '',
  difficulty = '',
  guitar     = '',
  amp        = '',
  genre      = '',
  genre_primary   = '',
  genre_secondary = '',
  notes      = '',
  favorite   = false,
  bpmOverride = '',
  keyOverride = '',
  albumOverride    = '',
  artistOverride   = '',
  durationOverride = '',
  timeSigOverride  = '',
  artOverride      = '',
}

-- Bulk tag editor state — mode per field: 0=Skip/Unchanged, 1=Set, 2=Clear
local bulk_edit = {
  strings_mode = 0, strings = '',
  tuning_mode = 0, tuning = '',
  transpose_mode = 0, transpose = '',
  status_mode = 0, status = '',
  difficulty_mode = 0, difficulty = '',
  guitar_mode = 0, guitar = '',
  amp_mode = 0, amp = '',
  genre_mode = 0, genre_primary = '', genre_secondary = '',
  notes_mode = 0, notes = '',
  favorite_mode = 0, favorite = false,
  bpmOverride_mode = 0, bpmOverride = '',
  keyOverride_mode = 0, keyOverride = '',
  albumOverride_mode = 0, albumOverride = '',
  artistOverride_mode = 0, artistOverride = '',
  titleOverride_mode = 0, titleOverride = '',
  durationOverride_mode = 0, durationOverride = '',
  timeSigOverride_mode = 0, timeSigOverride = '',
  artOverride_mode = 0, artOverride = '',
}

local function ResetBulkEdit()
  for k in pairs(bulk_edit) do
    if k:match('_mode$') then bulk_edit[k] = 0
    elseif k == 'favorite' then bulk_edit[k] = false
    else bulk_edit[k] = '' end
  end
end

-- ============================================================================
-- DEBUG LOGGING
-- ============================================================================

-- `S.debug_logging` controls logging (configured via Settings UI)
local SCRIPT_DIR = debug.getinfo(1, 'S').source:match('@?(.*)[/\\]') or '.'
local LOG_FILE = SCRIPT_DIR .. '/readashboard-debug.log'
local SCRIPT_START_TIME = reaper.time_precise()

--- Start/Truncate logging correctly after settings are loaded
local function InitLogFile()
  if not S.debug_logging then return end
  local f = io.open(LOG_FILE, 'w')
  if f then
    f:write('[ReaDashboard] Log restarted: ' .. os.date('%Y-%m-%d %H:%M:%S') .. '\n')
    f:close()
  end
end

local function Log(msg)
  if not S.debug_logging then return end
  local elapsed_ms = (reaper.time_precise() - SCRIPT_START_TIME) * 1000
  local line = string.format('[%8.1fms] %s', elapsed_ms, tostring(msg))
  -- File only (console output disabled to keep REAPER console clean)
  local f = io.open(LOG_FILE, 'a')
  if f then
    f:write(line .. '\n')
    f:close()
  end
end

-- ============================================================================
-- JSON LIBRARY (embedded)
-- Copyright (c) 2020 rxi — MIT License
-- https://github.com/rxi/json.lua
-- Embedded for standalone portability. Also ships as separate json.lua
-- via ReaPack — both approaches coexist fine.
-- ============================================================================

local json = { _version = "0.1.2" }

do
  local encode

  local escape_char_map = {
    [ "\\" ] = "\\",
    [ "\"" ] = "\"",
    [ "\b" ] = "b",
    [ "\f" ] = "f",
    [ "\n" ] = "n",
    [ "\r" ] = "r",
    [ "\t" ] = "t",
  }

  local escape_char_map_inv = { [ "/" ] = "/" }
  for k, v in pairs(escape_char_map) do
    escape_char_map_inv[v] = k
  end

  local function escape_char(c)
    return "\\" .. (escape_char_map[c] or string.format("u%04x", c:byte()))
  end

  local function encode_nil(val)
    return "null"
  end

  local function encode_table(val, stack)
    local res = {}
    stack = stack or {}
    if stack[val] then error("circular reference") end
    stack[val] = true

    if rawget(val, 1) ~= nil or next(val) == nil then
      local n = 0
      for k in pairs(val) do
        if type(k) ~= "number" then
          error("invalid table: mixed or invalid key types")
        end
        n = n + 1
      end
      if n ~= #val then
        error("invalid table: sparse array")
      end
      for i, v in ipairs(val) do
        table.insert(res, encode(v, stack))
      end
      stack[val] = nil
      return "[" .. table.concat(res, ",") .. "]"
    else
      for k, v in pairs(val) do
        if type(k) ~= "string" then
          error("invalid table: mixed or invalid key types")
        end
        table.insert(res, encode(k, stack) .. ":" .. encode(v, stack))
      end
      stack[val] = nil
      return "{" .. table.concat(res, ",") .. "}"
    end
  end

  local function encode_string(val)
    return '"' .. val:gsub('[%z\1-\31\\"]', escape_char) .. '"'
  end

  local function encode_number(val)
    if val ~= val or val <= -math.huge or val >= math.huge then
      error("unexpected number value '" .. tostring(val) .. "'")
    end
    return string.format("%.14g", val)
  end

  local type_func_map = {
    [ "nil"     ] = encode_nil,
    [ "table"   ] = encode_table,
    [ "string"  ] = encode_string,
    [ "number"  ] = encode_number,
    [ "boolean" ] = tostring,
  }

  encode = function(val, stack)
    local t = type(val)
    local f = type_func_map[t]
    if f then
      return f(val, stack)
    end
    error("unexpected type '" .. t .. "'")
  end

  function json.encode(val)
    return ( encode(val) )
  end

  -- Decode

  local parse

  local function create_set(...)
    local res = {}
    for i = 1, select("#", ...) do
      res[ select(i, ...) ] = true
    end
    return res
  end

  local space_chars   = create_set(" ", "\t", "\r", "\n")
  local delim_chars   = create_set(" ", "\t", "\r", "\n", "]", "}", ",")
  local escape_chars  = create_set("\\", "/", '"', "b", "f", "n", "r", "t", "u")
  local literals      = create_set("true", "false", "null")

  local literal_map = {
    [ "true"  ] = true,
    [ "false" ] = false,
    [ "null"  ] = nil,
  }

  local function next_char(str, idx, set, negate)
    for i = idx, #str do
      if set[str:sub(i, i)] ~= negate then
        return i
      end
    end
    return #str + 1
  end

  local function decode_error(str, idx, msg)
    local line_count = 1
    local col_count = 1
    for i = 1, idx - 1 do
      col_count = col_count + 1
      if str:sub(i, i) == "\n" then
        line_count = line_count + 1
        col_count = 1
      end
    end
    error( string.format("%s at line %d col %d", msg, line_count, col_count) )
  end

  local function codepoint_to_utf8(n)
    local f = math.floor
    if n <= 0x7f then
      return string.char(n)
    elseif n <= 0x7ff then
      return string.char(f(n / 64) + 192, n % 64 + 128)
    elseif n <= 0xffff then
      return string.char(f(n / 4096) + 224, f(n % 4096 / 64) + 128, n % 64 + 128)
    elseif n <= 0x10ffff then
      return string.char(f(n / 262144) + 240, f(n % 262144 / 4096) + 128,
                         f(n % 4096 / 64) + 128, n % 64 + 128)
    end
    error( string.format("invalid unicode codepoint '%x'", n) )
  end

  local function parse_unicode_escape(s)
    local n1 = tonumber( s:sub(1, 4),  16 )
    local n2 = tonumber( s:sub(7, 10), 16 )
    if n2 then
      return codepoint_to_utf8((n1 - 0xd800) * 0x400 + (n2 - 0xdc00) + 0x10000)
    else
      return codepoint_to_utf8(n1)
    end
  end

  local function parse_string(str, i)
    local res = ""
    local j = i + 1
    local k = j
    while j <= #str do
      local x = str:byte(j)
      if x < 32 then
        decode_error(str, j, "control character in string")
      elseif x == 92 then -- `\`: Escape
        res = res .. str:sub(k, j - 1)
        j = j + 1
        local c = str:sub(j, j)
        if c == "u" then
          local hex = str:match("^[dD][89aAbB]%x%x\\u%x%x%x%x", j + 1)
                   or str:match("^%x%x%x%x", j + 1)
                   or decode_error(str, j - 1, "invalid unicode escape in string")
          res = res .. parse_unicode_escape(hex)
          j = j + #hex
        else
          if not escape_chars[c] then
            decode_error(str, j - 1, "invalid escape char '" .. c .. "' in string")
          end
          res = res .. escape_char_map_inv[c]
        end
        k = j + 1
      elseif x == 34 then -- `"`: End of string
        res = res .. str:sub(k, j - 1)
        return res, j + 1
      end
      j = j + 1
    end
    decode_error(str, i, "expected closing quote for string")
  end

  local function parse_number(str, i)
    local x = next_char(str, i, delim_chars)
    local s = str:sub(i, x - 1)
    local n = tonumber(s)
    if not n then
      decode_error(str, i, "invalid number '" .. s .. "'")
    end
    return n, x
  end

  local function parse_literal(str, i)
    local x = next_char(str, i, delim_chars)
    local word = str:sub(i, x - 1)
    if not literals[word] then
      decode_error(str, i, "invalid literal '" .. word .. "'")
    end
    return literal_map[word], x
  end

  local function parse_array(str, i)
    local res = {}
    local n = 1
    i = i + 1
    while 1 do
      local x
      i = next_char(str, i, space_chars, true)
      if str:sub(i, i) == "]" then
        i = i + 1
        break
      end
      x, i = parse(str, i)
      res[n] = x
      n = n + 1
      i = next_char(str, i, space_chars, true)
      local chr = str:sub(i, i)
      i = i + 1
      if chr == "]" then break end
      if chr ~= "," then decode_error(str, i, "expected ']' or ','") end
    end
    return res, i
  end

  local function parse_object(str, i)
    local res = {}
    i = i + 1
    while 1 do
      local key, val
      i = next_char(str, i, space_chars, true)
      if str:sub(i, i) == "}" then
        i = i + 1
        break
      end
      if str:sub(i, i) ~= '"' then
        decode_error(str, i, "expected string for key")
      end
      key, i = parse(str, i)
      i = next_char(str, i, space_chars, true)
      if str:sub(i, i) ~= ":" then
        decode_error(str, i, "expected ':' after key")
      end
      i = next_char(str, i + 1, space_chars, true)
      val, i = parse(str, i)
      res[key] = val
      i = next_char(str, i, space_chars, true)
      local chr = str:sub(i, i)
      i = i + 1
      if chr == "}" then break end
      if chr ~= "," then decode_error(str, i, "expected '}' or ','") end
    end
    return res, i
  end

  local char_func_map = {
    [ '"' ] = parse_string,
    [ "0" ] = parse_number,  [ "1" ] = parse_number,
    [ "2" ] = parse_number,  [ "3" ] = parse_number,
    [ "4" ] = parse_number,  [ "5" ] = parse_number,
    [ "6" ] = parse_number,  [ "7" ] = parse_number,
    [ "8" ] = parse_number,  [ "9" ] = parse_number,
    [ "-" ] = parse_number,
    [ "t" ] = parse_literal,
    [ "f" ] = parse_literal,
    [ "n" ] = parse_literal,
    [ "[" ] = parse_array,
    [ "{" ] = parse_object,
  }

  parse = function(str, idx)
    local chr = str:sub(idx, idx)
    local f = char_func_map[chr]
    if f then
      return f(str, idx)
    end
    decode_error(str, idx, "unexpected character '" .. chr .. "'")
  end

  function json.decode(str)
    if type(str) ~= "string" then
      error("expected argument of type string, got " .. type(str))
    end
    local res, idx = parse(str, next_char(str, 1, space_chars, true))
    idx = next_char(str, idx, space_chars, true)
    if idx <= #str then
      decode_error(str, idx, "trailing garbage")
    end
    return res
  end
end -- do block

Log('JSON library loaded (embedded)')

-- Tags file path
local TAGS_FILE = SCRIPT_DIR .. '/project-tags.json'

-- Metadata cache file (auto-generated from spicetify DB + RPP scanning)
-- Rebuilt on hard refresh (Shift+F5). Normal refresh uses cached data.
local CACHE_FILE = SCRIPT_DIR .. '/metadata-cache.json'

-- All-projects scan cache: file listing only (paths + basic info).
-- Rebuilt on hard refresh. Metadata comes from shared metadata-cache.json.
local ALL_SCAN_FILE = SCRIPT_DIR .. '/all-projects-scan.json'
local HIDDEN_FILE    = SCRIPT_DIR .. '/hidden-projects.json'
local WHITELIST_FILE = SCRIPT_DIR .. '/whitelist.json'

-- Tags data: keyed by project path
local project_tags = {}

-- Spicetify lookup cache: key -> metadata table or false
local spicetify_cache = {}
-- spicetify_scanned is in S table



-- Rebuild CFG.PRIMARY_GENRES and CFG.GENRE_FILTER_OPTIONS from S.custom_primary_genres string
local function RebuildGenreLists()
  -- Parse comma-separated, trim whitespace
  local genres = {}
  for g in S.custom_primary_genres:gmatch('[^,]+') do
    local trimmed = g:match('^%s*(.-)%s*$')
    if trimmed ~= '' then genres[#genres + 1] = trimmed end
  end
  -- Repopulate CFG.PRIMARY_GENRES in-place
  for i = #CFG.PRIMARY_GENRES, 1, -1 do CFG.PRIMARY_GENRES[i] = nil end
  for i, g in ipairs(genres) do CFG.PRIMARY_GENRES[i] = g end
  -- Repopulate CFG.GENRE_FILTER_OPTIONS: All + genres + Unset
  for i = #CFG.GENRE_FILTER_OPTIONS, 1, -1 do CFG.GENRE_FILTER_OPTIONS[i] = nil end
  CFG.GENRE_FILTER_OPTIONS[1] = 'All'
  for i, g in ipairs(genres) do CFG.GENRE_FILTER_OPTIONS[i + 1] = g end
  CFG.GENRE_FILTER_OPTIONS[#CFG.GENRE_FILTER_OPTIONS + 1] = 'Unset'
end

-- Rebuild CFG.STATUS_PRESETS and CFG.STATUS_FILTER_OPTIONS from custom_statuses string
local function RebuildStatusLists()
  -- Start with built-in statuses
  local builtins = {
    'Practicing', 'Learning', 'Need to Learn',
    'WIP', 'Recording', 'Mixing', 'Complete', 'Released',
    'Needs Mixing', 'On Hold', 'Abandoned',
  }
  local builtin_set = {}
  for _, s in ipairs(builtins) do builtin_set[s:lower()] = true end

  -- Parse custom statuses (comma-separated)
  local customs = {}
  if S.custom_statuses ~= '' then
    for s in S.custom_statuses:gmatch('[^,]+') do
      local trimmed = s:match('^%s*(.-)%s*$')
      if trimmed ~= '' and not builtin_set[trimmed:lower()] then
        customs[#customs + 1] = trimmed
      end
    end
  end

  -- Rebuild CFG.STATUS_PRESETS in-place: builtins + customs
  for i = #CFG.STATUS_PRESETS, 1, -1 do CFG.STATUS_PRESETS[i] = nil end
  for i, s in ipairs(builtins) do CFG.STATUS_PRESETS[i] = s end
  for _, s in ipairs(customs) do CFG.STATUS_PRESETS[#CFG.STATUS_PRESETS + 1] = s end

  -- Rebuild CFG.STATUS_FILTER_OPTIONS: All + all statuses + Unset
  for i = #CFG.STATUS_FILTER_OPTIONS, 1, -1 do CFG.STATUS_FILTER_OPTIONS[i] = nil end
  CFG.STATUS_FILTER_OPTIONS[1] = 'All'
  for _, s in ipairs(CFG.STATUS_PRESETS) do
    CFG.STATUS_FILTER_OPTIONS[#CFG.STATUS_FILTER_OPTIONS + 1] = s
  end
  CFG.STATUS_FILTER_OPTIONS[#CFG.STATUS_FILTER_OPTIONS + 1] = 'Unset'
end

-- Image cache: path -> ImGui image handle or false
local image_cache = {}

-- Progressive image loading: load images across frames to avoid startup stall
local image_load_queue = {}  -- list of paths still to be loaded
-- IMAGE_BATCH_SIZE is in S table
-- fade_in_duration is in S table (persisted, adjustable in Settings)

-- ============================================================================
-- UTILITIES
-- ============================================================================

--- Extract filename from a full path.
local function GetFilename(path)
  return path:match('[/\\]([^/\\]+)$') or path
end

--- Extract directory from a full path.
local function GetDirectory(path)
  return path:match('^(.*)[/\\]') or ''
end

--- Parse "Artist - Song" from an RPP filename (without extension).
local function ParseProjectName(filename)
  local base = filename:match('(.+)%.[Rr][Pp][Pp]$') or filename
  local artist, song = base:match('^(.-)%s+%-%s+(.+)$')
  if artist and artist ~= '' then
    return base, artist, song
  end
  return base, nil, base
end

--- Convert JS_File_Stat date string to human-readable "22 Mar 2026".
--- Handles both slash-separated ("YYYY/MM/DD") and dot-separated ("YYYY.MM.DD") formats.
local function FormatDateHuman(dateStr)
  if not dateStr or dateStr == '' then return '' end
  local y, m, d = dateStr:match('^(%d+)[/.](%d+)[/.](%d+)')
  if not y then return dateStr end
  local mi = tonumber(m)
  local di = tonumber(d)
  local monthName = CFG.MONTH_NAMES[mi] or m
  return string.format('%d %s %s', di, monthName, y)
end

--- Get file info via js_ReaScriptAPI (non-blocking, unlike io.open).
--- Returns (exists, dateString) where dateString is a formatted date from JS_File_Stat.
--- JS_File_Stat returns retval=0 on success (C stat() convention).
--- modifiedTime is returned as an already-formatted date STRING, not a Unix timestamp.
local function GetFileInfo(path)
  if HAS_JS_API then
    local retval, _, _, modifiedTime = reaper.JS_File_Stat(path)
    if retval == 0 then
      return true, modifiedTime or ''
    end
    return false, ''
  end
  -- Fallback without JS_API: io.open can block on disconnected drives,
  -- so we just assume the file exists and skip date info.
  -- This path should rarely trigger since JS_API is installed.
  return true, ''
end

--- Quick file existence check using io.open.
local function FileExists(path)
  local f = io.open(path, 'r')
  if f then f:close() return true end
  return false
end

--- Normalize a file path to forward slashes, lowercase drive letter.
local function NormalizePath(p)
  if not p then return '' end
  return p:gsub('\\', '/')
end

--- Get the equivalent symlink path for tag lookup.
--- REAPER.ini uses C:/Users/.../Documents/REAPER Media paths,
--- all-projects scan uses G:/REAPER Media paths.
local function GetAlternatePath(p)
  if not p or S.symlink_src == '' or S.symlink_dest == '' then return nil end
  local np = NormalizePath(p)
  -- Try C: → G:
  local srcNorm = NormalizePath(S.symlink_src)
  local destNorm = NormalizePath(S.symlink_dest)
  if np:sub(1, #srcNorm):lower() == srcNorm:lower() then
    return destNorm .. np:sub(#srcNorm + 1)
  end
  -- Try G: → C:
  if np:sub(1, #destNorm):lower() == destNorm:lower() then
    return srcNorm .. np:sub(#destNorm + 1)
  end
  return nil
end

--- Ensure a path uses the canonical Documents form (C:/Users/.../REAPER Media).
--- If the path is a G: variant, converts to C:. Otherwise returns as-is.
local function CanonicalPath(p)
  if not p or S.symlink_src == '' or S.symlink_dest == '' then return p end
  local np = NormalizePath(p)
  local destNorm = NormalizePath(S.symlink_dest)
  if np:sub(1, #destNorm):lower() == destNorm:lower() then
    return NormalizePath(S.symlink_src) .. np:sub(#destNorm + 1)
  end
  return np
end

--- Convert an internal (forward-slash) path to Windows backslash format for
--- handing off to REAPER APIs that write to REAPER.ini.
--- Only needed at the exact boundary where a path leaves the script and enters REAPER.
local function ReaperPath(p)
  if not p then return p end
  return CanonicalPath(p):gsub('/', '\\')
end

-- ============================================================================
-- METADATA ENGINE
-- ============================================================================

--- Parse BPM and time signature from an RPP file.
--- Time sig uses the most-common signature from TEMPOENVEX markers (if present),
--- falling back to the initial TEMPO line. This handles songs where bar 1 differs
--- from the dominant time sig (e.g., 4/4 intro → 13/8 body).
local function ParseRPP(path)
  local f = io.open(path, 'r')
  if not f then return nil, nil end

  local bpm, timesig
  local in_env = false
  local sig_counts = {}  -- { ['13/8'] = 2, ['4/4'] = 1 }
  local lineNum = 0

  for line in f:lines() do
    lineNum = lineNum + 1
    -- Parse initial TEMPO line (BPM + fallback time sig)
    if not bpm then
      local t, n, d = line:match('TEMPO%s+([%d%.]+)%s+(%d+)%s+(%d+)')
      if t then
        bpm = tonumber(t)
        if n and d then timesig = n .. '/' .. d end
      end
    end
    -- Parse TEMPOENVEX markers for accurate time sig
    if line:find('<TEMPOENVEX') then
      in_env = true
    elseif in_env then
      local stripped = line:match('^%s*(.-)%s*$')
      if stripped == '>' then break end  -- end of TEMPOENVEX block
      if stripped:sub(1, 3) == 'PT ' then
        local encoded = stripped:match('^PT%s+[%d%.%-]+%s+[%d%.%-]+%s+%d+%s+(%d+)')
        if encoded then
          local enc = tonumber(encoded)
          local num = enc & 0xFFFF       -- lower 16 bits = numerator
          local den = (enc >> 16) & 0xFFFF  -- upper 16 bits = denominator
          if num > 0 and den > 0 then
            local sig = num .. '/' .. den
            sig_counts[sig] = (sig_counts[sig] or 0) + 1
          end
        end
      end
    end
    if lineNum >= 300 then break end
  end

  f:close()

  -- Use most-common time sig from TEMPOENVEX if available
  -- Tiebreaker: prefer the TEMPO line default when counts are equal
  if next(sig_counts) then
    local best_sig, best_count = nil, 0
    for sig, count in pairs(sig_counts) do
      if count > best_count then
        best_sig = sig
        best_count = count
      end
    end
    -- Only override TEMPO line default if a TEMPOENVEX sig is strictly more common
    if best_sig and (not timesig or best_count > (sig_counts[timesig] or 0)) then
      timesig = best_sig
    end
  end

  return bpm, timesig
end

--- Format key number + mode into readable string (e.g. "F# major").
local function FormatKey(keyNum, mode)
  if keyNum == nil then return nil end
  local name = CFG.KEY_NAMES[keyNum]
  if not name then return nil end
  local modeName = CFG.MODE_NAMES[mode]
  if modeName then
    return name .. ' ' .. modeName
  end
  return name
end

--- Normalize a string for matching: lowercase, keep only alphanumeric chars.
--- Matches the SyncLyrics normalization strategy for consistent cross-app matching.
local function NormalizeStr(s)
  if not s then return '' end
  s = s:lower()
  s = s:gsub('[^%a%d]', '')  -- strip everything except letters and digits
  return s
end

--- Parse "Artist - Song" into normalized artist, normalized song.
--- Returns normArtist, normSong or nil, normFullName if no separator found.
local function ParseArtistSong(name)
  if not name then return nil, '' end
  local artist, song = name:match('^(.-)%s+%-%s+(.+)$')
  if artist and artist ~= '' then
    return NormalizeStr(artist), NormalizeStr(song)
  end
  return nil, NormalizeStr(name)
end

-- Spicetify normalized lookup: { normArtist = { normSong = originalKey, ... }, ... }
-- Plus a flat index for title-only lookups: { normSong = originalKey, ... }
local spicetify_by_artist = {}   -- [normArtist][normSong] = originalKey
local spicetify_songs_flat = {}  -- [normSong] = { origKey1, origKey2, ... }

--- Scan spicetify database directory once to build filename lookup + normalized indices.
local function ScanSpicetifyDB()
  if S.spicetify_scanned then return end
  S.spicetify_scanned = true
  
  if not S.enable_spicetify or S.spicetify_db_path == '' then return end
  if not json then return end

  Log('Scanning Spicetify database')
  local t0 = reaper.time_precise()
  local count = 0
  local idx = 0
  while true do
    local fname = reaper.EnumerateFiles(S.spicetify_db_path, idx)
    if not fname then break end
    if fname:match('%.json$') then
      local key = fname:match('^(.+)%.json$')
      if key then
        spicetify_cache[key] = true
        count = count + 1

        -- Build normalized indices
        local normArtist, normSong = ParseArtistSong(key)
        if normArtist then
          if not spicetify_by_artist[normArtist] then
            spicetify_by_artist[normArtist] = {}
          end
          spicetify_by_artist[normArtist][normSong] = key
        end
        -- Flat song index (for title-only and substring matching)
        if not spicetify_songs_flat[normSong] then
          spicetify_songs_flat[normSong] = {}
        end
        spicetify_songs_flat[normSong][#spicetify_songs_flat[normSong] + 1] = key
      end
    end
    idx = idx + 1
  end

  Log('Spicetify DB: ' .. count .. ' entries found')
end

--- Look up a song in spicetify_by_artist, trying multiple artist name variants.
--- Returns original spicetify key or nil.
local function LookupByArtist(normArtist, normSong)
  -- Direct artist match
  local songs = spicetify_by_artist[normArtist]
  if songs and songs[normSong] then return songs[normSong] end

  -- Abbreviation expansion (e.g., bfmv → bullet for my valentine)
  local expanded = CFG.ARTIST_ABBREVIATIONS[normArtist]
  if expanded then
    songs = spicetify_by_artist[NormalizeStr(expanded)]
    if songs and songs[normSong] then return songs[normSong] end
  end

  -- Artist variant (e.g., tesseract → tesseract with different casing in original)
  local variant = CFG.ARTIST_VARIANTS[normArtist]
  if variant then
    songs = spicetify_by_artist[NormalizeStr(variant)]
    if songs and songs[normSong] then return songs[normSong] end
  end

  return nil
end

--- Get all artist name variants (normalized) for a given normalized artist name.
local function GetArtistVariants(normArtist)
  local variants = { normArtist }
  local expanded = CFG.ARTIST_ABBREVIATIONS[normArtist]
  if expanded then variants[#variants + 1] = NormalizeStr(expanded) end
  local variant = CFG.ARTIST_VARIANTS[normArtist]
  if variant then variants[#variants + 1] = NormalizeStr(variant) end
  return variants
end

--- Strip known suffixes from a raw (pre-normalization) song title.
--- Operates on the original string with spaces, then returns the stripped version.
--- e.g., "Marigold Shorter" → "Marigold", "Jetpacks Was Yes Practice" → "Jetpacks Was Yes"
local function StripSuffixes(rawSong)
  local stripped = rawSong
  for pass = 1, 3 do
    local changed = false
    for _, suffix in ipairs(CFG.STRIP_SUFFIXES) do
      -- Case-insensitive suffix match at end of string (after a space)
      local pattern = '%s+' .. suffix .. '$'
      local result = stripped:lower():gsub(pattern, '')
      if result ~= stripped:lower() then
        -- Trim the same number of chars from the original
        stripped = stripped:sub(1, #result)
        changed = true
        break
      end
    end
    if not changed then break end
  end
  return stripped
end

--- Try to find a matching spicetify DB key for a project name.
--- Uses multiple strategies: exact → normalized → abbreviation → suffix-stripped → compound-split → substring.
--- Returns the original spicetify key (filename) or nil.
local function FindSpicetifyMatch(projName)
  if not projName or projName == '' then return nil end

  -- Strategy 1: Exact match (fastest path)
  if spicetify_cache[projName] then return projName end

  -- Parse raw "Artist - Song" before normalization
  local rawArtist, rawSong = projName:match('^(.-)%s+%-%s+(.+)$')
  local normArtist = rawArtist and NormalizeStr(rawArtist) or nil
  local normSong = rawSong and NormalizeStr(rawSong) or NormalizeStr(projName)

  -- Strategy 2: Normalized match (case + punctuation insensitive)
  if normArtist then
    local match = LookupByArtist(normArtist, normSong)
    if match then return match end
  end

  -- Strategy 3: Suffix stripping on raw song title, then normalize
  if normArtist and rawSong then
    local strippedRaw = StripSuffixes(rawSong)
    if strippedRaw ~= rawSong then
      local strippedNorm = NormalizeStr(strippedRaw)
      if strippedNorm ~= '' then
        local match = LookupByArtist(normArtist, strippedNorm)
        if match then return match end
      end
    end
  end

  -- Strategy 4: Compound title splitting (e.g., "Wish-Glimpse" → try "Wish", "Glimpse")
  -- Split on hyphens and spaces in raw song title, try each part
  if normArtist and rawSong then
    for part in rawSong:gmatch('[^%-%s]+') do
      if #part >= 4 then
        local normPart = NormalizeStr(part)
        if normPart ~= '' then
          local match = LookupByArtist(normArtist, normPart)
          if match then return match end
        end
      end
    end
  end

  -- Strategy 5: Substring matching — project song title within a spicetify song title
  -- e.g., "Nocturne" matches "ofmindnocturne", "Resist" matches "ofmatterresist"
  if normArtist and #normSong >= 4 then
    local artistVariants = GetArtistVariants(normArtist)
    for _, av in ipairs(artistVariants) do
      local songs = spicetify_by_artist[av]
      if songs then
        for dbSong, origKey in pairs(songs) do
          if dbSong:find(normSong, 1, true) then
            return origKey
          end
        end
      end
    end
  end

  -- Strategy 6: Suffix strip + substring
  if normArtist and rawSong then
    local strippedRaw = StripSuffixes(rawSong)
    if strippedRaw ~= rawSong then
      local strippedNorm = NormalizeStr(strippedRaw)
      if strippedNorm ~= '' and #strippedNorm >= 4 then
        local artistVariants = GetArtistVariants(normArtist)
        for _, av in ipairs(artistVariants) do
          local songs = spicetify_by_artist[av]
          if songs then
            for dbSong, origKey in pairs(songs) do
              if dbSong:find(strippedNorm, 1, true) then
                return origKey
              end
            end
          end
        end
      end
    end
  end

  -- Strategy 7: Title-only search (no artist in project name, e.g., "Follow Your Ghost")
  if not normArtist and normSong and #normSong >= 5 then
    -- Direct title match
    local entries = spicetify_songs_flat[normSong]
    if entries and #entries == 1 then
      return entries[1]
    end
    -- Try with suffix stripping on raw name
    local strippedRaw = StripSuffixes(projName)
    if strippedRaw ~= projName then
      local strippedNorm = NormalizeStr(strippedRaw)
      if strippedNorm ~= '' then
        entries = spicetify_songs_flat[strippedNorm]
        if entries and #entries == 1 then
          return entries[1]
        end
      end
    end
  end

  return nil
end

--- Load spicetify metadata for a given "Artist - Song" key.
--- Uses fuzzy matching to find the best match in the spicetify DB.
--- Returns metadata table or nil.
local function LoadSpicetifyMeta(key)
  if not json then return nil end
  if not S.enable_spicetify or S.spicetify_db_path == '' then return nil end

  -- Try fuzzy matching to find the actual spicetify DB key
  local matchedKey = FindSpicetifyMatch(key)
  if not matchedKey then return nil end

  -- Already loaded (cached as table)
  if type(spicetify_cache[matchedKey]) == 'table' then
    return spicetify_cache[matchedKey]
  end

  local path = S.spicetify_db_path .. '/' .. matchedKey .. '.json'
  local f = io.open(path, 'r')
  if not f then
    spicetify_cache[matchedKey] = false
    return nil
  end

  local content = f:read('*a')
  f:close()

  local ok, data = pcall(json.decode, content)
  if not ok or type(data) ~= 'table' then
    spicetify_cache[matchedKey] = false
    return nil
  end

  -- Extract metadata from spicetify JSON
  local meta = {}

  -- Top-level fields
  meta.matchedArtist = data.artist    -- original artist name from DB (for art resolution)
  meta.matchedTitle = data.title      -- original title from DB

  -- Track metadata
  if data.track_metadata then
    meta.album = data.track_metadata.album
    meta.albumArtUrl = data.track_metadata.album_art_url
    meta.spotifyURI = data.track_metadata.url
    meta.discNumber = data.track_metadata.disc_number
    meta.trackNumber = data.track_metadata.track_number
    meta.totalTracks = data.track_metadata.total_tracks
    meta.isExplicit = data.track_metadata.is_explicit
    meta.hasLyrics = data.track_metadata.has_lyrics
  end

  -- Audio analysis
  if data.audio_analysis then
    meta.songBPM = data.audio_analysis.tempo
    meta.songKey = data.audio_analysis.key
    meta.songMode = data.audio_analysis.mode
    meta.timeSig = data.audio_analysis.time_signature
    meta.duration = data.audio_analysis.duration
    meta.loudness = data.audio_analysis.loudness
  end

  -- Cache under both the matched key AND the original project name for fast future lookups
  spicetify_cache[matchedKey] = meta
  if key ~= matchedKey then
    spicetify_cache[key] = meta
    Log('Spicetify fuzzy match: "' .. key .. '" → "' .. matchedKey .. '"')
  end
  return meta
end

-- ============================================================================
-- ALBUM ART
-- ============================================================================

--- Resolve album art path for a project. Returns file path or nil.
--- Try to find album art in the art DB folder for a given "Artist - Album" combination.
--- Tries multiple folder name variants to handle filesystem-safe encoding differences.
local function TryArtFolder(folderName)
  if not S.enable_spicetify or S.album_art_db_path == '' then return nil end
  for _, artFile in ipairs(CFG.ART_FILE_PREFS) do
    local path = S.album_art_db_path .. '/' .. folderName .. '/' .. artFile
    if FileExists(path) then return path end
  end
  return nil
end

local function ResolveAlbumArt(artist, album)
  if not artist then return nil end

  -- Try album-specific folder: "Artist - Album/"
  if album then
    local base = artist .. ' - ' .. album
    local found = TryArtFolder(base)
    if found then return found end

    -- Filesystem-safe substitutions: characters that SyncLyrics encodes differently
    -- Try each variant cumulatively
    local variants = {}
    local alt = album
    -- : → _ (common)
    alt = alt:gsub(':', '_')
    if alt ~= album then variants[#variants + 1] = artist .. ' - ' .. alt end
    -- / → _ (Either/Or → Either_Or)
    alt = alt:gsub('/', '_')
    variants[#variants + 1] = artist .. ' - ' .. alt
    -- … (ellipsis char) → strip or replace (…And Justice → And Justice)
    alt = alt:gsub('\226\128\166', '')  -- UTF-8 for …
    variants[#variants + 1] = artist .. ' - ' .. alt
    -- Parenthesized suffixes: try with _X_ encoding (Special Edition) → _Special Edition_
    local paren_content = album:match('%s*%((.-)%)%s*$')
    if paren_content then
      local without_paren = album:gsub('%s*%(.-%)%s*$', '')
      variants[#variants + 1] = artist .. ' - ' .. without_paren .. ' _' .. paren_content .. '_'
      variants[#variants + 1] = artist .. ' - ' .. without_paren  -- also try without suffix entirely
    end

    -- Deduplicate and try each variant
    local tried = { [base] = true }
    for _, v in ipairs(variants) do
      if not tried[v] then
        tried[v] = true
        found = TryArtFolder(v)
        if found then return found end
      end
    end
  end

  -- Fallback: artist folder
  return TryArtFolder(artist)
end

--- Get or create a cached ImGui image handle.
--- When CFG.DEFER_IMAGES is true and images are still loading, returns nil (shows placeholder)
--- instead of decoding on-demand. This makes the first frame render near-instantly.
local function GetImage(path)
  if not path then return nil end
  if image_cache[path] ~= nil then
    if image_cache[path] == false then return nil end
    return image_cache[path]
  end

  -- During progressive loading, don't decode on-demand — show placeholder instead
  if CFG.DEFER_IMAGES and #image_load_queue > 0 then
    return nil
  end

  local ok, img = pcall(ImGui.CreateImage, path)
  if ok and img then
    ImGui.Attach(ctx, img)
    image_cache[path] = img
    return img
  else
    image_cache[path] = false
    return nil
  end
end

--- Build image load queue from current filtered projects' art paths.
--- Call after data load to prepare progressive loading.
local function BuildImageQueue()
  image_load_queue = {}
  local queued = {}
  for _, proj in ipairs(S.filtered_projects) do
    if proj.albumArtPath and image_cache[proj.albumArtPath] == nil and FileExists(proj.albumArtPath) then
      if not queued[proj.albumArtPath] then
        image_load_queue[#image_load_queue + 1] = proj.albumArtPath
        queued[proj.albumArtPath] = true
      end
    elseif proj.albumArtPath and not FileExists(proj.albumArtPath) then
      -- File was moved/deleted since cache was built — clear stale path
      proj.albumArtPath = nil
    end
  end
  Log('Image queue built: ' .. #image_load_queue .. ' images to load')
end

--- Pre-load a batch of images from the queue. Returns number loaded.
--- Called from DrawFrame to spread image loading across frames.
--- Pre-load images from the queue, yielding if time exceeds budget to prevent UI stutter.
--- @param time_budget_ms number  Max milliseconds to spend loading (default 4ms for 60fps headroom)
local function ProcessImageQueue(time_budget_ms)
  if #image_load_queue == 0 then return 0 end
  local budget = (time_budget_ms or 8) / 1000  -- convert ms to seconds
  local loaded = 0
  local t_start = reaper.time_precise()

  while #image_load_queue > 0 do
    local path = table.remove(image_load_queue, 1)
    if image_cache[path] == nil then  -- not yet loaded
      local ok, img = pcall(ImGui.CreateImage, path)
      if ok and img then
        ImGui.Attach(ctx, img)
        image_cache[path] = img
      else
        image_cache[path] = false
      end
      loaded = loaded + 1
    end
    -- Time budget check: yield to next frame if we've exceeded our budget
    if (reaper.time_precise() - t_start) > budget then break end
  end
  return loaded
end

--- Draw a placeholder rectangle for missing album art.
local function DrawArtPlaceholder(proj, size)
  local label = ''
  if S.show_art_placeholder then
    if S.placeholder_full_name then
      -- Full project name (wrapped by button width)
      label = proj.name or proj.song or '?'
    else
      -- 2-character initials
      label = ((proj.artist or proj.name) or '?'):sub(1, 2):upper()
    end
  end
  ImGui.PushStyleColor(ctx, ImGui.Col_Button, 0x333333FF)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, 0x333333FF)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive, 0x333333FF)
  if S.placeholder_full_name and S.show_art_placeholder then
    -- Use text wrapping for long names on grid cards
    ImGui.PushTextWrapPos(ctx, ImGui.GetCursorPosX(ctx) + size)
  end
  ImGui.Button(ctx, label .. '##ph' .. tostring(proj.path or ''), size, size)
  if S.placeholder_full_name and S.show_art_placeholder then
    ImGui.PopTextWrapPos(ctx)
  end
  ImGui.PopStyleColor(ctx, 3)
end

-- ============================================================================
-- TAGS SYSTEM
-- ============================================================================

--- Load tags from project-tags.json.
local function LoadTags()
  if not json then return end
  local f = io.open(TAGS_FILE, 'r')
  if not f then
    Log('No tags file found, starting fresh')
    return
  end
  local content = f:read('*a')
  f:close()

  local ok, data = pcall(json.decode, content)
  if ok and type(data) == 'table' then
    project_tags = data
    local count = 0
    for _ in pairs(project_tags) do count = count + 1 end
    Log('Loaded tags for ' .. count .. ' projects')
  else
    Log('WARNING: Could not parse tags file')
  end
end

--- Pretty-print a Lua value as indented JSON string.
--- Handles strings, numbers, booleans, nil, and tables (objects/arrays).
local function JsonPretty(val, indent)
  indent = indent or 0
  local pad = string.rep('  ', indent)
  local pad1 = string.rep('  ', indent + 1)
  local t = type(val)

  if val == nil then
    return 'null'
  elseif t == 'boolean' then
    return val and 'true' or 'false'
  elseif t == 'number' then
    return tostring(val)
  elseif t == 'string' then
    -- Escape special chars for JSON string
    local s = val:gsub('\\', '\\\\'):gsub('"', '\\"')
                 :gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
    return '"' .. s .. '"'
  elseif t == 'table' then
    -- Check if array (sequential integer keys starting at 1)
    local is_array = (#val > 0)
    if is_array then
      local parts = {}
      for i = 1, #val do
        parts[i] = pad1 .. JsonPretty(val[i], indent + 1)
      end
      return '[\n' .. table.concat(parts, ',\n') .. '\n' .. pad .. ']'
    else
      -- Object: sort keys for consistent output
      local keys = {}
      for k in pairs(val) do keys[#keys + 1] = k end
      table.sort(keys)
      if #keys == 0 then return '{}' end
      local parts = {}
      for _, k in ipairs(keys) do
        parts[#parts + 1] = pad1 .. JsonPretty(tostring(k), 0) .. ': ' .. JsonPretty(val[k], indent + 1)
      end
      return '{\n' .. table.concat(parts, ',\n') .. '\n' .. pad .. '}'
    end
  end
  return 'null'
end

--- Save tags to project-tags.json (pretty-printed for human readability).
local function SaveTags()
  if not json then return end
  local output = JsonPretty(project_tags)
  local f = io.open(TAGS_FILE, 'w')
  if not f then
    Log('ERROR: Could not write tags file')
    return
  end
  f:write(output .. '\n')
  f:close()
  Log('Tags saved')
end

--- Save hidden projects to hidden-projects.json (array of paths).
local function SaveHidden()
  if not json then return end
  local paths = {}
  for path, _ in pairs(S.hidden_projects) do paths[#paths + 1] = path end
  table.sort(paths)  -- consistent ordering
  local output = JsonPretty(paths)
  local f = io.open(HIDDEN_FILE, 'w')
  if not f then
    Log('ERROR: Could not write hidden projects file')
    return
  end
  f:write(output .. '\n')
  f:close()
  Log('Hidden projects saved (' .. #paths .. ' entries)')
end

--- Load hidden projects from hidden-projects.json.
local function LoadHidden()
  if not json then return end
  local f = io.open(HIDDEN_FILE, 'r')
  if not f then
    -- Migration: check ExtState for legacy newline/pipe-separated data
    local hp = reaper.GetExtState(CFG.EXT_SECTION, 'hidden_projects')
    if hp ~= '' then
      S.hidden_projects = {}
      for path in hp:gmatch('[^\n|]+') do
        S.hidden_projects[path] = true
      end
      Log('Migrated ' .. (function() local n=0; for _ in pairs(S.hidden_projects) do n=n+1 end; return n end)() .. ' hidden projects from ExtState')
      -- Save to new JSON file and clear ExtState key
      SaveHidden()
      reaper.DeleteExtState(CFG.EXT_SECTION, 'hidden_projects', true)
    end
    return
  end
  local content = f:read('*a')
  f:close()

  local ok, data = pcall(json.decode, content)
  if ok and type(data) == 'table' then
    S.hidden_projects = {}
    for _, path in ipairs(data) do
      S.hidden_projects[path] = true
    end
    local count = 0
    for _ in pairs(S.hidden_projects) do count = count + 1 end
    Log('Loaded ' .. count .. ' hidden projects')
  else
    Log('WARNING: Could not parse hidden projects file')
  end
end

--- Save universal whitelist to whitelist.json.
local function SaveWhitelist()
  if not json then return end
  local paths = {}
  for path, _ in pairs(S.whitelist) do paths[#paths + 1] = path end
  table.sort(paths)
  local output = JsonPretty(paths)
  local f = io.open(WHITELIST_FILE, 'w')
  if not f then
    Log('ERROR: Could not write whitelist file')
    return
  end
  f:write(output .. '\n')
  f:close()
  Log('Whitelist saved (' .. #paths .. ' entries)')
end

--- Load universal whitelist from whitelist.json (migrates from ExtState if needed).
local function LoadWhitelist()
  if not json then return end
  local f = io.open(WHITELIST_FILE, 'r')
  if not f then
    -- Migration: check ExtState for legacy main_only_whitelist (pipe-separated)
    local wl = reaper.GetExtState(CFG.EXT_SECTION, 'main_only_whitelist')
    if wl ~= '' then
      S.whitelist = {}
      for path in wl:gmatch('[^|]+') do
        S.whitelist[path] = true
      end
      Log('Migrated ' .. (function() local n=0; for _ in pairs(S.whitelist) do n=n+1 end; return n end)() .. ' whitelist entries from ExtState')
      SaveWhitelist()
      reaper.DeleteExtState(CFG.EXT_SECTION, 'main_only_whitelist', true)
    end
    return
  end
  local content = f:read('*a')
  f:close()
  local ok, data = pcall(json.decode, content)
  if ok and type(data) == 'table' then
    S.whitelist = {}
    for _, path in ipairs(data) do
      S.whitelist[path] = true
    end
    local count = 0
    for _ in pairs(S.whitelist) do count = count + 1 end
    Log('Loaded ' .. count .. ' whitelist entries')
  else
    Log('WARNING: Could not parse whitelist file')
  end
end

--- Check if a project is in the universal whitelist (checks both path variants).
local function IsWhitelisted(proj)
  if S.whitelist[proj.path] then return true end
  local alt = GetAlternatePath(proj.path)
  if alt and S.whitelist[alt] then return true end
  return false
end

--- Convert genre field (may be a table/array from JSON) to a display string.
local function GenreStr(g)
  if type(g) == 'table' then return table.concat(g, ', ') end
  return g or ''
end

--- Extract primary genre label for display and filtering.
--- Takes the first item from array or first comma-split value, then maps it via CFG.PRIMARY_GENRE_MAP.
--- Returns the mapped short label (e.g. 'Djent'), the raw value if unmapped, or nil if no genre.
local function GetPrimaryGenre(tags)
  if not tags then return nil end
  local g = tags.genre
  if not g then return nil end
  local first
  if type(g) == 'table' then
    first = g[1]
  else
    first = g:match('^([^,]+)')
  end
  if not first or first == '' then return nil end
  first = first:match('^%s*(.-)%s*$')  -- trim surrounding whitespace
  if first == '' then return nil end
  return CFG.PRIMARY_GENRE_MAP[first:lower()] or first
end

--- Get tags table for a project path.
--- Checks both the given path and its symlink equivalent (C: ↔ G:).
local function GetTags(projPath)
  local tags = project_tags[projPath]
  if tags then return tags end
  -- Try symlink-equivalent path (handles C:\...\REAPER Media ↔ G:\REAPER Media)
  local alt = GetAlternatePath(projPath)
  if alt then
    tags = project_tags[alt]
    if tags then return tags end
    -- Also try with backslashes (tags keyed from REAPER.ini use backslashes)
    tags = project_tags[alt:gsub('/', '\\')]
    if tags then return tags end
  end
  -- Try backslash variant of original
  local bs = projPath:gsub('/', '\\')
  if bs ~= projPath then
    tags = project_tags[bs]
    if tags then return tags end
  end
  return {}
end

--- Find the canonical key in project_tags for a given path.
--- Returns the existing key if found (checking all path variants), else the original path.
local function FindTagKey(projPath)
  if project_tags[projPath] then return projPath end
  local alt = GetAlternatePath(projPath)
  if alt then
    if project_tags[alt] then return alt end
    local altBs = alt:gsub('/', '\\')
    if project_tags[altBs] then return altBs end
  end
  local bs = projPath:gsub('/', '\\')
  if bs ~= projPath and project_tags[bs] then return bs end
  return projPath  -- no existing entry found, use original
end

--- Set a single tag for a project.
--- Uses path equivalence to avoid duplicate entries for symlinked paths.
local function SetTag(projPath, key, value)
  local actualKey = FindTagKey(projPath)
  if not project_tags[actualKey] then
    project_tags[actualKey] = {}
  end
  project_tags[actualKey][key] = value
end

-- ============================================================================
-- METADATA CACHE
-- Stores per-project metadata (BPM, key, album, art path) from spicetify DB
-- and RPP parsing. Rebuilt on hard refresh. Normal startup uses cache for speed.
-- project-tags.json overrides always take priority over cached data.
-- ============================================================================

local metadata_cache = {}
-- cache_loaded is in S table

--- Save metadata cache to metadata-cache.json.
--- Called after a full scan (hard refresh) to persist results.
local function SaveMetadataCache(projectList)
  if not json then return end
  local cache = {}
  for _, proj in ipairs(projectList) do
    local entry = {}
    if proj.songBPM then entry.songBPM = proj.songBPM end
    if proj.songKey then entry.songKey = proj.songKey end
    if proj.album then entry.album = proj.album end
    if proj.duration then entry.duration = proj.duration end
    if proj.projectBPM then entry.projectBPM = proj.projectBPM end
    if proj.projectTimeSig then entry.projectTimeSig = proj.projectTimeSig end
    if proj.albumArtPath then entry.albumArtPath = proj.albumArtPath end
    if proj.timeSig then entry.timeSig = proj.timeSig end
    if proj.matchedArtist then entry.matchedArtist = proj.matchedArtist end
    if proj.matchedTitle then entry.matchedTitle = proj.matchedTitle end
    -- Only store if we have any metadata worth caching
    local has_data = false
    for _ in pairs(entry) do has_data = true; break end
    if has_data then
      cache[proj.name] = entry
    end
  end
  local output = JsonPretty(cache)
  local f = io.open(CACHE_FILE, 'w')
  if not f then
    Log('ERROR: Could not write metadata cache')
    return
  end
  f:write(output .. '\n')
  f:close()
  metadata_cache = cache
  S.cache_loaded = true
  local count = 0
  for _ in pairs(cache) do count = count + 1 end
  Log('Metadata cache saved: ' .. count .. ' entries')
end

--- Load metadata cache from metadata-cache.json.
local function LoadMetadataCache()
  if not json then return false end
  local f = io.open(CACHE_FILE, 'r')
  if not f then
    Log('No metadata cache found')
    return false
  end
  local content = f:read('*a')
  f:close()
  local ok, data = pcall(json.decode, content)
  if ok and type(data) == 'table' then
    metadata_cache = data
    S.cache_loaded = true
    local count = 0
    for _ in pairs(metadata_cache) do count = count + 1 end
    Log('Metadata cache loaded: ' .. count .. ' entries')
    return true
  else
    Log('WARNING: Could not parse metadata cache')
    return false
  end
end

-- ============================================================================
-- ALL-PROJECTS SCAN (recursive directory scanner)
-- ============================================================================

--- Recursively scan a directory for .rpp files.
--- Returns a flat list of full file paths.
local function ScanDirectoryRecursive(basePath, depth, maxDepth, excludedSet)
  local results = {}
  if depth > maxDepth then return results end

  -- Enumerate files in this directory
  local fidx = 0
  while true do
    local fname = reaper.EnumerateFiles(basePath, fidx)
    if not fname then break end
    if fname:match('%.[Rr][Pp][Pp]$') and not fname:match('%.[Rr][Pp][Pp]%-bak$') then
      results[#results + 1] = basePath .. '/' .. fname
    end
    fidx = fidx + 1
  end

  -- Recurse into subdirectories
  local didx = 0
  while true do
    local dname = reaper.EnumerateSubdirectories(basePath, didx)
    if not dname then break end
    -- Skip excluded folders
    if not excludedSet[dname:lower()] then
      local subResults = ScanDirectoryRecursive(basePath .. '/' .. dname, depth + 1, maxDepth, excludedSet)
      for _, path in ipairs(subResults) do
        results[#results + 1] = path
      end
    end
    didx = didx + 1
  end

  return results
end

--- Scan all configured project paths for .rpp files. Returns project list (same format as LoadRecentProjects).
local function ScanAllProjectFiles()
  local t0 = reaper.time_precise()

  -- Build excluded set for fast lookup
  local excludedSet = {}
  for _, name in ipairs(CFG.ALL_SCAN_EXCLUDED) do
    excludedSet[name:lower()] = true
  end

  -- Collect all scan paths: primary + additional
  local scan_paths = {}
  if S.ALL_PROJECTS_PATH ~= '' then scan_paths[#scan_paths + 1] = S.ALL_PROJECTS_PATH end
  for _, p in ipairs(S.additional_project_paths) do
    if p ~= '' then scan_paths[#scan_paths + 1] = p end
  end

  local paths = {}
  for _, scan_path in ipairs(scan_paths) do
    Log('Scanning all projects from: ' .. scan_path)
    local sub_paths = ScanDirectoryRecursive(scan_path, 0, S.ALL_SCAN_MAX_DEPTH, excludedSet)
    for _, sp in ipairs(sub_paths) do paths[#paths + 1] = sp end
  end
  Log('  Directory scan: ' .. #paths .. ' .rpp files in ' .. string.format('%.1fms', (reaper.time_precise() - t0) * 1000))

  -- Deduplicate by filename (same logic as LoadRecentProjects)
  local result = {}
  local seen_filenames = {}
  local dupes = 0
  local stat_time = 0

  for _, fullPath in ipairs(paths) do
    local filename = GetFilename(fullPath)
    if not seen_filenames[filename] then
      seen_filenames[filename] = true
      local name, artist, song = ParseProjectName(filename)
      local t_stat = reaper.time_precise()
      local exists, dateStr = GetFileInfo(fullPath)
      stat_time = stat_time + (reaper.time_precise() - t_stat)

      result[#result + 1] = {
        name     = name,
        path     = fullPath,
        dir      = GetDirectory(fullPath),
        artist   = artist or '',
        song     = song or name,
        filename = filename,
        exists   = exists,
        dateStr  = dateStr,
        isRecent = false,  -- will be set during merge/dedup
      }
    else
      dupes = dupes + 1
    end
  end

  Log('  All projects: ' .. #result .. ' unique (' .. dupes .. ' filename dupes skipped)')
  Log('  JS_File_Stat total: ' .. string.format('%.1fms', stat_time * 1000))
  return result
end

--- Save all-projects scan listing to all-projects-scan.json.
--- Only stores paths + basic info (NOT metadata — that's in metadata-cache.json).
local function SaveAllProjectsScan(projectList)
  if not json then return end
  local entries = {}
  for _, proj in ipairs(projectList) do
    entries[#entries + 1] = {
      path     = proj.path,
      name     = proj.name,
      artist   = proj.artist ~= '' and proj.artist or nil,
      song     = proj.song ~= proj.name and proj.song or nil,
      filename = proj.filename,
      dateStr  = proj.dateStr ~= '' and proj.dateStr or nil,
    }
  end
  local output = JsonPretty(entries)
  local f = io.open(ALL_SCAN_FILE, 'w')
  if not f then
    Log('ERROR: Could not write all-projects scan cache')
    return
  end
  f:write(output .. '\n')
  f:close()
  Log('All-projects scan saved: ' .. #entries .. ' entries')
end

--- Load all-projects scan listing from cache.
--- Returns project list or nil if no cache.
local function LoadAllProjectsScan()
  if not json then return nil end
  local f = io.open(ALL_SCAN_FILE, 'r')
  if not f then
    Log('No all-projects scan cache found')
    return nil
  end
  local content = f:read('*a')
  f:close()
  local ok, data = pcall(json.decode, content)
  if not ok or type(data) ~= 'table' then
    Log('WARNING: Could not parse all-projects scan cache')
    return nil
  end

  -- Rebuild project list from cached entries
  local result = {}
  for _, entry in ipairs(data) do
    local filename = entry.filename or GetFilename(entry.path)
    local name = entry.name or ParseProjectName(filename)
    local exists, dateStr
    -- Re-check existence + date (fast, since files are local)
    if HAS_JS_API then
      exists, dateStr = GetFileInfo(entry.path)
    else
      exists = true
      dateStr = entry.dateStr or ''
    end

    result[#result + 1] = {
      name     = name,
      path     = entry.path,
      dir      = GetDirectory(entry.path),
      artist   = entry.artist or '',
      song     = entry.song or name,
      filename = filename,
      exists   = exists,
      dateStr  = dateStr,
      isRecent = false,
    }
  end
  Log('All-projects scan loaded from cache: ' .. #result .. ' entries')
  return result
end

--- Apply cached metadata to a project list (fast path — no DB scanning).
--- Art paths come from cache; artOverride from tags always takes priority.
--- Tags from project-tags.json are applied fresh and take priority over cache.
--- Build a pre-lowered search haystack string for a project.
--- Called once after metadata enrichment; FilterList reads this instead of rebuilding per-keystroke.
local function BuildSearchHaystack(proj)
  local tags = proj.tags or GetTags(proj.path)
  local stringsHay = ''
  if tags.strings and tags.strings ~= '' and tags.strings ~= 'Unset' then
    stringsHay = tags.strings .. '-string'
  end
  proj.search_haystack = (
    proj.name .. ' ' .. (proj.artist or '') .. ' ' .. (proj.song or '') .. ' ' .. proj.dir
    .. ' ' .. (proj.matchedArtist or '')
    .. ' ' .. (proj.matchedTitle or '')
    .. ' ' .. (proj.album or '')
    .. ' ' .. (proj.displayKey or '')
    .. ' ' .. (tags.tuning or '')
    .. ' ' .. GenreStr(tags.genre)
    .. ' ' .. (tags.guitar or '')
    .. ' ' .. (tags.amp or '')
    .. ' ' .. stringsHay
    .. ' ' .. (tags.status or '')
    .. ' ' .. (tags.difficulty or '')
    .. ' ' .. (tags.notes or '')
  ):lower()
end

--- Parse a search query string into a structured form supporting OR, AND, NOT, and "quoted phrases".
--- Returns { or_groups = { { and_terms = {}, not_terms = {} }, ... } }
--- Syntax: terms are AND by default. `OR` splits into alternative groups. `-term` excludes.
---   `"exact phrase"` matches literally. Explicit `AND` is a no-op (stripped).
--- Splits by OR first, then parses each segment for AND/NOT/quoted. NOT is per-group.
--- Example: `periphery -practice OR erra "drop a"` →
---   group1: and={"periphery"}, not={"practice"}  OR  group2: and={"erra", "drop a"}, not={}
local function ParseSearchQuery(query)
  if not query or query == '' then return nil end
  local q = query  -- keep original case for quoted phrases; we'll lower later

  -- Extract quoted phrases first, replace with placeholders
  local placeholders = {}
  q = q:gsub('"([^"]+)"', function(phrase)
    local idx = #placeholders + 1
    placeholders[idx] = phrase:lower()
    return '\0PH' .. idx .. '\0'
  end)

  -- Split by OR (case-sensitive, must be surrounded by spaces or start/end)
  local or_segments = {}
  for seg in (q .. ' OR '):gmatch('(.-)%s+OR%s+') do
    if seg ~= '' then or_segments[#or_segments + 1] = seg end
  end
  if #or_segments == 0 then or_segments[1] = q end

  local or_groups = {}
  for _, seg in ipairs(or_segments) do
    local and_terms = {}
    local not_terms = {}
    for token in seg:gmatch('%S+') do
      -- Skip explicit AND (no-op connector)
      if token:upper() == 'AND' then
        -- skip
      elseif token:match('^\0PH(%d+)\0$') then
        -- Restore quoted placeholder
        local idx = tonumber(token:match('^\0PH(%d+)\0$'))
        and_terms[#and_terms + 1] = placeholders[idx]
      elseif token:sub(1, 1) == '-' and #token > 1 then
        -- NOT term (exclude)
        local term = token:sub(2):lower()
        -- Check if it's a placeholder reference
        local ph_idx = term:match('^\0ph(%d+)\0$')
        if ph_idx then
          not_terms[#not_terms + 1] = placeholders[tonumber(ph_idx)]
        else
          not_terms[#not_terms + 1] = term
        end
      else
        and_terms[#and_terms + 1] = token:lower()
      end
    end
    if #and_terms > 0 or #not_terms > 0 then
      or_groups[#or_groups + 1] = { and_terms = and_terms, not_terms = not_terms }
    end
  end

  if #or_groups == 0 then return nil end
  return { or_groups = or_groups }
end

--- Match a parsed search query against a project's search haystack.
--- Returns true if any OR group matches (all AND terms found, no NOT terms found).
local function MatchSearchQuery(parsed, haystack)
  for _, group in ipairs(parsed.or_groups) do
    local match = true
    -- All AND terms must be present
    for _, term in ipairs(group.and_terms) do
      if not haystack:find(term, 1, true) then match = false; break end
    end
    -- No NOT terms may be present
    if match then
      for _, term in ipairs(group.not_terms) do
        if haystack:find(term, 1, true) then match = false; break end
      end
    end
    if match then return true end  -- any OR group matching = pass
  end
  return false
end

local function ApplyCachedMetadata(projectList)
  local cache_hits = 0
  local art_hits = 0

  for _, proj in ipairs(projectList) do
    -- Apply cached metadata
    local cached = metadata_cache[proj.name]
    if cached then
      cache_hits = cache_hits + 1
      proj.songBPM = cached.songBPM
      proj.songKey = cached.songKey
      proj.album = cached.album
      proj.duration = cached.duration
      proj.projectBPM = cached.projectBPM
      proj.projectTimeSig = cached.projectTimeSig
      proj.albumArtPath = (cached.albumArtPath and FileExists(cached.albumArtPath)) and cached.albumArtPath or nil
      proj.timeSig = cached.timeSig
      proj.matchedArtist = cached.matchedArtist
      proj.matchedTitle = cached.matchedTitle
    end

    -- Custom folder art and artOverride are cached in metadata-cache.json now.
    -- They are only re-checked on hard refresh (EnrichProjects).

    -- User art override from tags (takes priority over everything, always fresh from tags)
    -- Validate file exists to prevent stale override from suppressing valid auto art
    local tags_check = GetTags(proj.path)
    if tags_check.artOverride and tags_check.artOverride ~= '' and FileExists(tags_check.artOverride) then
      proj.albumArtPath = tags_check.artOverride
    end

    -- Default artwork fallback (user-configured in Settings)
    if not proj.albumArtPath and S.default_artwork_path ~= '' and FileExists(S.default_artwork_path) then
      proj.albumArtPath = S.default_artwork_path
    end

    if proj.albumArtPath then art_hits = art_hits + 1 end

    -- Load tags
    proj.tags = GetTags(proj.path)

    -- Resolve display BPM (user override > project BPM > song BPM)
    local tags = proj.tags
    if tags.bpmOverride and tags.bpmOverride ~= '' then
      proj.displayBPM = tags.bpmOverride
    elseif proj.projectBPM then
      proj.displayBPM = math.floor(proj.projectBPM + 0.5)
    elseif proj.songBPM then
      proj.displayBPM = math.floor(proj.songBPM + 0.5)
    end

    -- Resolve display key (user override > song key)
    if tags.keyOverride and tags.keyOverride ~= '' then
      proj.displayKey = tags.keyOverride
    else
      proj.displayKey = proj.songKey
    end

    -- Apply full metadata overrides from tags (empty = revert to auto-detected)
    if tags.albumOverride and tags.albumOverride ~= '' then proj.album = tags.albumOverride end
    if tags.artistOverride and tags.artistOverride ~= '' then proj.matchedArtist = tags.artistOverride end
    if tags.titleOverride and tags.titleOverride ~= '' then proj.matchedTitle = tags.titleOverride end
    if tags.durationOverride and tags.durationOverride ~= '' then proj.duration = tags.durationOverride end
    if tags.timeSigOverride and tags.timeSigOverride ~= '' then proj.projectTimeSig = tags.timeSigOverride end

    -- Build cached search haystack (avoids per-keystroke string concatenation)
    BuildSearchHaystack(proj)
  end

  Log('Cache applied: ' .. cache_hits .. ' hits, ' .. art_hits .. ' art')
end

-- ============================================================================
-- DATA LOADING
-- ============================================================================

--- Read recent project list from REAPER.ini via SWS.
local function LoadRecentProjects()
  local ini = reaper.get_ini_file()
  if not ini then
    Log('ERROR: Could not get REAPER ini path')
    return {}
  end
  Log('Loading recent projects from: ' .. ini)

  -- Count entries using "noEntry" sentinel (same as original ReaLauncher)
  local t_ini = reaper.time_precise()
  local count = 0
  while true do
    count = count + 1
    local _, val = reaper.BR_Win32_GetPrivateProfileString(
      'recent', 'recent' .. string.format('%02d', count), 'noEntry', ini
    )
    if val == 'noEntry' then
      count = count - 1
      break
    end
    -- Safety cap: REAPER typically stores up to 512 recent entries
    if count >= 512 then break end
  end
  Log('  INI count (' .. count .. ' entries): ' .. string.format('%.1fms', (reaper.time_precise() - t_ini) * 1000))

  local result = {}
  local seen_filenames = {}  -- deduplicate by filename (handles symlink duplicates)
  local dupes = 0
  local t_read = reaper.time_precise()
  local stat_time = 0
  for i = 1, count do
    local _, fullPath = reaper.BR_Win32_GetPrivateProfileString(
      'recent', 'recent' .. string.format('%02d', i), 'noEntry', ini
    )
    if fullPath and fullPath ~= '' and fullPath ~= 'noEntry' then
      local filename = GetFilename(fullPath)

      -- Skip duplicates (REAPER may store both symlink and real path)
      if not seen_filenames[filename] then
        seen_filenames[filename] = true
        local name, artist, song = ParseProjectName(filename)
        local t_stat = reaper.time_precise()
        local exists, dateStr = GetFileInfo(fullPath)
        stat_time = stat_time + (reaper.time_precise() - t_stat)

        result[#result + 1] = {
          name     = name,
          path     = fullPath,
          dir      = GetDirectory(fullPath),
          artist   = artist or '',
          song     = song or name,
          filename = filename,
          exists   = exists,
          dateStr  = dateStr,
          recent_index = #result + 1,  -- REAPER.ini order = last-opened order
        }
      else
        dupes = dupes + 1
      end
    end
  end

  Log('  INI read+parse: ' .. string.format('%.1fms', (reaper.time_precise() - t_read) * 1000)
    .. ' (JS_File_Stat total: ' .. string.format('%.1fms', stat_time * 1000) .. ')')
  if dupes > 0 then Log('Skipped ' .. dupes .. ' duplicate entries') end
  Log('Loaded ' .. #result .. ' valid projects')
  return result
end

--- Enrich projects with metadata from spicetify DB, RPP parsing, album art, and tags.
local function EnrichProjects(projectList)
  ScanSpicetifyDB()

  local spicetify_hits = 0
  local art_hits = 0
  local rpp_hits = 0

  for _, proj in ipairs(projectList) do
    -- RPP parsing (BPM, time signature)
    if proj.exists then
      local bpm, timesig = ParseRPP(proj.path)
      if bpm then
        proj.projectBPM = bpm
        proj.projectTimeSig = timesig
        rpp_hits = rpp_hits + 1
      end
    end

    -- Spicetify metadata
    local meta = LoadSpicetifyMeta(proj.name)
    if meta then
      spicetify_hits = spicetify_hits + 1
      proj.songBPM = meta.songBPM
      proj.songKey = FormatKey(meta.songKey, meta.songMode)
      proj.album = meta.album
      proj.duration = meta.duration
      proj.timeSig = meta.timeSig              -- spicetify time signature (numeric, e.g. 4)
      proj.matchedArtist = meta.matchedArtist  -- for art resolution & cache
      proj.matchedTitle = meta.matchedTitle    -- original title from spicetify DB
    end

    -- Album art resolution chain:
    -- 1. Custom art in project folder (cover.jpg, cover.png, etc.)
    -- 2. User override in project-tags.json (artOverride path)
    -- 3. Spicetify → album art DB (Artist - Album folder)
    -- 4. Artist image fallback (Artist folder)
    -- 5. Placeholder (drawn at render time)
    local artFound = false

    -- 1. Check project folder for custom art (relaxed matching chain)
    if proj.exists and proj.dir ~= '' then
      -- 1a. Exact name match (cover.jpg, folder.png, art.jpg, etc.)
      for _, artName in ipairs(CFG.PROJECT_ART_NAMES) do
        local path = proj.dir .. '/' .. artName
        if FileExists(path) then
          proj.albumArtPath = path
          artFound = true
          break
        end
      end

      -- 1b-1d. Relaxed matching: enumerate all images in folder
      if not artFound then
        local images = {}
        local fidx = 0
        while true do
          local fname = reaper.EnumerateFiles(proj.dir, fidx)
          if not fname then break end
          local ext = fname:lower():match('%.([^%.]+)$')
          if ext == 'jpg' or ext == 'jpeg' or ext == 'png' then
            images[#images + 1] = fname
          end
          fidx = fidx + 1
        end

        if #images == 1 then
          -- 1b. Single image rule: only one image in folder → use it
          proj.albumArtPath = proj.dir .. '/' .. images[1]
          artFound = true
        elseif #images > 1 then
          -- 1c. Project-name match: image filename contains the project name
          local projNameLower = proj.name:lower()
          for _, img in ipairs(images) do
            if img:lower():find(projNameLower, 1, true) then
              proj.albumArtPath = proj.dir .. '/' .. img
              artFound = true
              break
            end
          end

          -- 1d. Most-recently-modified fallback
          if not artFound then
            local bestImg, bestDate = nil, ''
            for _, img in ipairs(images) do
              local imgPath = proj.dir .. '/' .. img
              local imgExists, imgDate = GetFileInfo(imgPath)
              if imgExists and imgDate > bestDate then
                bestDate = imgDate
                bestImg = imgPath
              end
            end
            if bestImg then
              proj.albumArtPath = bestImg
              artFound = true
            end
          end
        end
      end
    end

    -- 2. User art override from tags
    if not artFound then
      local tags_check = GetTags(proj.path)
      if tags_check.artOverride and FileExists(tags_check.artOverride) then
        proj.albumArtPath = tags_check.artOverride
        artFound = true
      end
    end

    -- 3. Spicetify → album art DB (use matchedArtist from spicetify for correct folder lookup)
    if not artFound and meta and meta.album then
      local artArtist = meta.matchedArtist or proj.artist
      proj.albumArtPath = ResolveAlbumArt(artArtist, meta.album)
      if proj.albumArtPath then artFound = true end
    end

    -- 4. Try "Artist - SongTitle" as album folder (catches album-named songs, e.g. TesseracT - Polaris)
    if not artFound and proj.artist and proj.song then
      proj.albumArtPath = ResolveAlbumArt(proj.artist, proj.song)
      if proj.albumArtPath then artFound = true end
    end

    -- 5. Artist image fallback (try matched artist first, then project artist)
    if not artFound then
      local artArtist = (meta and meta.matchedArtist) or proj.artist
      if artArtist and artArtist ~= '' then
        proj.albumArtPath = ResolveAlbumArt(artArtist, nil)
        if proj.albumArtPath then artFound = true end
      end
    end

    -- Default artwork fallback is NOT applied here — it's applied at runtime in
    -- ApplyCachedMetadata() so changing the setting takes effect immediately without
    -- a hard refresh. Applying here would bake the path into metadata-cache.json.

    if artFound then art_hits = art_hits + 1 end

    -- Load tags
    proj.tags = GetTags(proj.path)

    -- Resolve display BPM (user override > project BPM > song BPM)
    -- Project BPM (from RPP TEMPO) is preferred as it reflects actual REAPER tempo.
    -- Song BPM (from Spotify) is shown in tooltip for reference.
    local tags = proj.tags
    if tags.bpmOverride then
      proj.displayBPM = tags.bpmOverride
    elseif proj.projectBPM then
      proj.displayBPM = math.floor(proj.projectBPM + 0.5)
    elseif proj.songBPM then
      proj.displayBPM = math.floor(proj.songBPM + 0.5)
    end

    -- Resolve display key (user override > song key)
    if tags.keyOverride and tags.keyOverride ~= '' then
      proj.displayKey = tags.keyOverride
    else
      proj.displayKey = proj.songKey
    end

    -- Apply full metadata overrides from tags (same as ApplyCachedMetadata)
    if tags.albumOverride and tags.albumOverride ~= '' then proj.album = tags.albumOverride end
    if tags.artistOverride and tags.artistOverride ~= '' then proj.matchedArtist = tags.artistOverride end
    if tags.titleOverride and tags.titleOverride ~= '' then proj.matchedTitle = tags.titleOverride end
    if tags.durationOverride and tags.durationOverride ~= '' then proj.duration = tags.durationOverride end
    if tags.timeSigOverride and tags.timeSigOverride ~= '' then proj.projectTimeSig = tags.timeSigOverride end

    -- Build cached search haystack (avoids per-keystroke string concatenation)
    BuildSearchHaystack(proj)
  end

  Log('Metadata: ' .. spicetify_hits .. ' spicetify, ' .. rpp_hits .. ' RPP, ' .. art_hits .. ' art')
end

-- ============================================================================
-- SORTING & FILTERING
-- ============================================================================

--- Create a shallow copy of a list, sorted by the given mode.
--- Date strings from JS_File_Stat are "YYYY/MM/DD HH:MM:SS" format,
--- which sorts correctly via lexicographic string comparison.
local function SortList(list, mode)
  local out = {}
  for i = 1, #list do out[i] = list[i] end

  if mode == CFG.SORT_NEWEST then
    table.sort(out, function(a, b) return (a.dateStr or '') > (b.dateStr or '') end)
  elseif mode == CFG.SORT_OLDEST then
    table.sort(out, function(a, b) return (a.dateStr or '') < (b.dateStr or '') end)
  elseif mode == CFG.SORT_AZ then
    table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
  elseif mode == CFG.SORT_ZA then
    table.sort(out, function(a, b) return a.name:lower() > b.name:lower() end)
  elseif mode == CFG.SORT_ARTIST_AZ then
    -- Sort by confirmed artist only (spicetify match or user override), not filename guess
    -- Optional album grouping: artist → album → title (toggle in Settings)
    table.sort(out, function(a, b)
      local aa = (a.matchedArtist or ''):lower()
      local ba = (b.matchedArtist or ''):lower()
      if aa == '' and ba ~= '' then return false end  -- empty artist goes last
      if aa ~= '' and ba == '' then return true end
      if aa ~= ba then return aa < ba end
      if S.artist_sort_by_album then
        local a_alb = (a.album or ''):lower()
        local b_alb = (b.album or ''):lower()
        if a_alb == '' and b_alb ~= '' then return false end  -- no album goes last within artist
        if a_alb ~= '' and b_alb == '' then return true end
        if a_alb ~= b_alb then return a_alb < b_alb end
      end
      local at = (a.matchedTitle or a.name):lower()
      local bt = (b.matchedTitle or b.name):lower()
      return at < bt
    end)
  elseif mode == CFG.SORT_TITLE_AZ then
    -- Sort by matchedTitle; projects WITH a title come first, then by title A→Z
    table.sort(out, function(a, b)
      local at = (a.matchedTitle or ''):lower()
      local bt = (b.matchedTitle or ''):lower()
      if at == '' and bt ~= '' then return false end  -- no title goes last
      if at ~= '' and bt == '' then return true end
      if at ~= bt then return at < bt end
      return a.name:lower() < b.name:lower()
    end)
  elseif mode == CFG.SORT_RECENT then
    -- REAPER.ini order = last-opened order (recent01 = most recently opened)
    table.sort(out, function(a, b)
      return (a.recent_index or 9999) < (b.recent_index or 9999)
    end)
  end

  return out
end

--- Filter a list by tag filters + multi-word search query.
local function FilterList(list, query)
  local out = {}
  -- Parse query once for all projects (supports OR, AND, NOT, "quoted phrases")
  local parsed_query = ParseSearchQuery(query)
  for _, p in ipairs(list) do
    local tags = p.tags or {}
    local pass = true

    -- String count filter (All=1, 6=2, 7=3, 8=4, None=5)
    -- tonumber() handles both integer 6 and string "6" from project-tags.json
    if pass and S.filter_strings > 1 then
      local str_n = tonumber(tags.strings)
      if CFG.STRING_FILTER_OPTIONS[S.filter_strings] == 'Unset' then
        if str_n ~= nil then pass = false end  -- 'Unset' = missing strings tag
      else
        if S.filter_strings == 2 and str_n ~= 6 then pass = false end
        if S.filter_strings == 3 and str_n ~= 7 then pass = false end
        if S.filter_strings == 4 and str_n ~= 8 then pass = false end
      end
    end

    -- Tuning filter (last option = 'Unset')
    if pass and S.filter_tuning > 1 then
      local wanted = CFG.TUNING_FILTER_OPTIONS[S.filter_tuning]
      if wanted == 'Unset' then
        if (tags.tuning or '') ~= '' then pass = false end
      else
        if (tags.tuning or '') ~= wanted then pass = false end
      end
    end

    -- Status filter (last option = 'Unset')
    if pass and S.filter_status > 1 then
      local wanted = CFG.STATUS_FILTER_OPTIONS[S.filter_status]
      if wanted == 'Unset' then
        if (tags.status or '') ~= '' then pass = false end
      else
        if (tags.status or '') ~= wanted then pass = false end
      end
    end

    -- Genre filter (matches against primary genre only; last option = 'Unset')
    if pass and S.filter_genre > 1 then
      local wanted = CFG.GENRE_FILTER_OPTIONS[S.filter_genre]
      if wanted == 'Unset' then
        if (GetPrimaryGenre(tags) or '') ~= '' then pass = false end
      else
        if GetPrimaryGenre(tags) ~= wanted then pass = false end
      end
    end

    -- Favorites filter
    if pass and S.filter_favs and not tags.favorite then pass = false end

    -- Tri-state coverage buttons
    if pass and S.filter_tri_meta ~= 0 then
      local has_m = (p.matchedArtist ~= nil and p.matchedArtist ~= '')
                 or (p.album ~= nil and p.album ~= '')
                 or (tags.artistOverride and tags.artistOverride ~= '')
                 or (tags.albumOverride and tags.albumOverride ~= '')
      if S.filter_tri_meta == 1 and not has_m then pass = false end  -- require
      if S.filter_tri_meta == 2 and has_m then pass = false end      -- exclude
    end
    if pass and S.filter_tri_art ~= 0 then
      local has_a = (p.albumArtPath ~= nil and p.albumArtPath ~= '')
      if S.filter_tri_art == 1 and not has_a then pass = false end
      if S.filter_tri_art == 2 and has_a then pass = false end
    end
    if pass and S.filter_tri_tags ~= 0 then
      local has_t = false
      for k, v in pairs(tags) do
        if v and v ~= '' and v ~= false then has_t = true; break end
      end
      if S.filter_tri_tags == 1 and not has_t then pass = false end
      if S.filter_tri_tags == 2 and has_t then pass = false end
    end

    -- Text search using parsed query (supports OR, AND, NOT, "quoted phrases")
    if pass and parsed_query then
      -- Use pre-built haystack (built during enrichment/tag edit), fallback to on-the-fly
      local hay = p.search_haystack
      if not hay then
        BuildSearchHaystack(p)
        hay = p.search_haystack
      end
      if not MatchSearchQuery(parsed_query, hay) then pass = false end
    end

    if pass then out[#out + 1] = p end
  end
  return out
end

--- Check if a project should be excluded based on exclusion patterns (whitelist overrides).
--- Check if a project matches any exclusion pattern (case-insensitive substring or glob).
local function IsExcluded(proj)
  if IsWhitelisted(proj) then return false end
  if S.exclusion_patterns == '' then return false end
  local pathLower = proj.path:lower():gsub('\\', '/')
  for pattern in S.exclusion_patterns:gmatch('[^\n]+') do
    local pat = pattern:match('^%s*(.-)%s*$')  -- trim whitespace
    if pat ~= '' then
      local patLower = pat:lower()
      if patLower:find('[%*%?]') then
        -- Glob pattern: convert to Lua pattern (implicit *...* wrapping)
        -- Escape Lua magic chars first, then convert glob wildcards
        local luaPat = patLower:gsub('([%(%)%.%%%+%-%[%]%^%$])', '%%%1')
        luaPat = luaPat:gsub('%*', '.*')
        luaPat = luaPat:gsub('%?', '.')
        if pathLower:find(luaPat) then
          return true
        end
      else
        -- Plain substring match (backward compatible)
        if pathLower:find(patLower, 1, true) then
          return true
        end
      end
    end
  end
  return false
end

--- Apply dedupe filter to a project list.
--- Standard mode: groups by folder + base name (only _N/_NNN suffix stripped). Most recent wins.
--- Aggressive mode: groups by folder only. Most recent wins.
--- Tri-state: 0=dedupe active (hide variants), 1=disabled (show all), 2=show only variants.
local function ApplyDedupe(list)
  if S.show_dedupe == 1 then return list end  -- disabled, show all

  -- Group projects
  local groups = {}  -- key → list of projects
  local order = {}   -- preserve first-seen order of groups

  for _, p in ipairs(list) do
    local dir = (p.dir or ''):lower():gsub('\\', '/')
    local groupKey
    if S.dedupe_mode == 'aggressive' then
      -- Aggressive: group by folder only
      groupKey = dir
    else
      -- Standard: group by folder + base name (only strip REAPER auto-copy _N/_NNN suffixes)
      local baseName = p.name:lower()
      baseName = baseName:gsub('_+%d+$', '')
      groupKey = dir .. '||' .. baseName
    end

    if not groups[groupKey] then
      groups[groupKey] = {}
      order[#order + 1] = groupKey
    end
    groups[groupKey][#groups[groupKey] + 1] = p
  end

  -- Pick winner from each group, track variants
  local result = {}
  local only_variants = {}  -- for mode 2 (show only variants)
  S.dedupe_variants = {}  -- reset variant tracking
  for _, key in ipairs(order) do
    local group = groups[key]
    if #group == 1 then
      result[#result + 1] = group[1]
    else
      -- Winner: most recently modified. Tiebreak: shortest name.
      table.sort(group, function(a, b)
        local da, db = (a.dateStr or ''), (b.dateStr or '')
        if da ~= db then return da > db end
        return #a.name < #b.name
      end)
      local winner = group[1]
      result[#result + 1] = winner

      -- Track filtered-out variants for display in Settings
      local winner_name = winner.name
      local variants = {}
      for vi = 2, #group do
        local vp = group[vi]
        if IsWhitelisted(vp) then
          result[#result + 1] = vp
        else
          variants[#variants + 1] = { name = vp.name, path = vp.path }
          only_variants[#only_variants + 1] = vp
        end
      end
      if #variants > 0 then
        S.dedupe_variants[#S.dedupe_variants + 1] = {
          main = winner_name,
          filtered = variants,
        }
      end
    end
  end

  -- Mode 2: show only the variants (audit mode)
  if S.show_dedupe == 2 then return only_variants end

  return result
end

--- Apply exclusion patterns to filter projects (tri-state: 0=hide excluded, 1=show all, 2=show only excluded).
--- Tracks excluded projects in S.excluded_projects regardless of mode.
local function ApplyExclusions(list)
  S.excluded_projects = {}
  if S.exclusion_patterns == '' then
    -- No patterns: mode 2 returns empty, others return all
    return S.show_excluded == 2 and {} or list
  end
  -- Always compute the excluded set for display in Settings
  local included, excluded = {}, {}
  for _, p in ipairs(list) do
    if not IsExcluded(p) then
      included[#included + 1] = p
    else
      excluded[#excluded + 1] = p
      S.excluded_projects[#S.excluded_projects + 1] = { name = p.name, path = p.path }
    end
  end
  if S.show_excluded == 0 then return included end      -- default: hide excluded
  if S.show_excluded == 1 then return list end           -- show all (including excluded)
  return excluded                                         -- show only excluded
end

--- Check if a project is manually hidden (whitelist overrides).
local function IsHidden(proj)
  if IsWhitelisted(proj) then return false end
  if S.hidden_projects[proj.path] then return true end
  -- Check alternate path too (symlink handling)
  local alt = GetAlternatePath(proj.path)
  if alt and S.hidden_projects[alt] then return true end
  return false
end

--- Filter projects by hidden status (tri-state: 0=hide hidden, 1=show all, 2=show only hidden).
local function ApplyHiddenFilter(list)
  if S.show_hidden == 1 then return list end  -- show everything
  if not next(S.hidden_projects) then
    -- No hidden projects: mode 0 returns all, mode 2 returns empty
    return S.show_hidden == 2 and {} or list
  end
  local out = {}
  for _, p in ipairs(list) do
    local hidden = IsHidden(p)
    if S.show_hidden == 0 and not hidden then
      out[#out + 1] = p
    elseif S.show_hidden == 2 and hidden then
      out[#out + 1] = p
    end
  end
  return out
end

--- Save active filter values into the specified tab's per-tab storage.
local function SaveFiltersToTab(tab)
  local p = tab .. '_filter_'
  S[p .. 'strings']  = S.filter_strings
  S[p .. 'tuning']   = S.filter_tuning
  S[p .. 'status']   = S.filter_status
  S[p .. 'favs']     = S.filter_favs
  S[p .. 'genre']    = S.filter_genre
  S[p .. 'tri_meta'] = S.filter_tri_meta
  S[p .. 'tri_art']  = S.filter_tri_art
  S[p .. 'tri_tags'] = S.filter_tri_tags
  S[p .. 'exclude_recents'] = S.filter_exclude_recents
  S[p .. 'include_all']     = S.filter_include_all
end

--- Load filter values from the specified tab's per-tab storage into active state.
local function LoadFiltersFromTab(tab)
  local p = tab .. '_filter_'
  S.filter_strings  = S[p .. 'strings']
  S.filter_tuning   = S[p .. 'tuning']
  S.filter_status   = S[p .. 'status']
  S.filter_favs     = S[p .. 'favs']
  S.filter_genre    = S[p .. 'genre'] or 1
  S.filter_tri_meta = S[p .. 'tri_meta']
  S.filter_tri_art  = S[p .. 'tri_art']
  S.filter_tri_tags = S[p .. 'tri_tags']
  S.filter_exclude_recents = S[p .. 'exclude_recents'] or false
  S.filter_include_all     = S[p .. 'include_all'] or false
end

--- Rebuild S.filtered_projects from the active source.
--- When universal search is on and there's a search query, merges recent + all results
--- with recent first, then non-recent (deduplicated by filename), separated by S.recent_count_in_filtered.
local function RefreshFiltered()
  S.recent_count_in_filtered = 0

  -- Apply hidden filter to recent projects too (needed early for exclude-recents set)
  local recent_source = ApplyHiddenFilter(S.recent_projects)

  -- Prepare all-projects source with dedup + exclusion + hidden applied (if loaded)
  local all_source = S.all_projects
  if S.all_projects_loaded and #S.all_projects > 0 then
    all_source = ApplyExclusions(all_source)
    all_source = ApplyHiddenFilter(all_source)
    all_source = ApplyDedupe(all_source)
    -- Exclude Recents: remove projects already in the Recent tab
    if S.filter_exclude_recents then
      local recent_fnames = {}
      for _, rp in ipairs(S.recent_projects) do recent_fnames[rp.filename] = true end
      local filtered = {}
      for _, p in ipairs(all_source) do
        if not recent_fnames[p.filename] then filtered[#filtered + 1] = p end
      end
      all_source = filtered
    end
  end
  -- Cache filtered count for tab label (avoids per-frame recomputation)
  S.all_display_count = #all_source

  -- Universal search: merge both sources when searching
  if S.universal_search and S.search_buf ~= '' and S.all_projects_loaded and #all_source > 0 then
    -- Filter recent first
    local recent_filtered = SortList(FilterList(recent_source, S.search_buf), S.sort_mode)
    S.recent_count_in_filtered = #recent_filtered

    -- Build set of recent filenames for dedup
    local recent_filenames = {}
    for _, p in ipairs(recent_source) do
      recent_filenames[p.filename] = true
    end

    -- Filter all-projects, excluding those already in recent
    local all_non_recent = {}
    for _, p in ipairs(all_source) do
      if not recent_filenames[p.filename] then
        all_non_recent[#all_non_recent + 1] = p
      end
    end
    local all_filtered = SortList(FilterList(all_non_recent, S.search_buf), S.sort_mode)

    -- Merge: recent matches first, then all-projects matches
    S.filtered_projects = {}
    for _, p in ipairs(recent_filtered) do
      S.filtered_projects[#S.filtered_projects + 1] = p
    end
    for _, p in ipairs(all_filtered) do
      S.filtered_projects[#S.filtered_projects + 1] = p
    end
  elseif S.active_tab == 'recent' and S.filter_include_all and S.all_projects_loaded and #all_source > 0 then
    -- Combined view: recents first, then all remaining projects (excluding recents)
    local recent_filtered = SortList(FilterList(recent_source, S.search_buf), S.sort_mode)
    S.recent_count_in_filtered = #recent_filtered

    -- Build set of recent filenames for dedup
    local recent_filenames = {}
    for _, p in ipairs(S.recent_projects) do
      recent_filenames[p.filename] = true
    end

    -- Filter all-projects, excluding those already in recent
    local all_non_recent = {}
    for _, p in ipairs(all_source) do
      if not recent_filenames[p.filename] then
        all_non_recent[#all_non_recent + 1] = p
      end
    end
    local all_filtered = SortList(FilterList(all_non_recent, S.search_buf), S.sort_mode)

    -- Merge: recent first, then all-projects
    S.filtered_projects = {}
    for _, p in ipairs(recent_filtered) do
      S.filtered_projects[#S.filtered_projects + 1] = p
    end
    for _, p in ipairs(all_filtered) do
      S.filtered_projects[#S.filtered_projects + 1] = p
    end
  else
    -- Normal: filter active tab's source
    if S.active_tab == 'all' and S.all_projects_loaded then
      projects = all_source
    else
      projects = recent_source
    end
    S.filtered_projects = SortList(FilterList(projects, S.search_buf), S.sort_mode)
  end

  -- Sync active filters to per-tab storage and update filtered count for tab labels
  SaveFiltersToTab(S.active_tab)
  if S.active_tab == 'recent' then
    S.recent_filtered_count = #S.filtered_projects
  elseif S.active_tab == 'all' then
    S.all_filtered_count = #S.filtered_projects
  end

  -- Clear multi-selection on filter change; clamp primary index
  S.selected = {}
  if S.selected_idx > #S.filtered_projects then S.selected_idx = #S.filtered_projects end
  if S.selected_idx < 1 and #S.filtered_projects > 0 then S.selected_idx = 1 end
  if S.selected_idx > 0 then 
    S.selected[S.selected_idx] = true 
    S.pending_focus_idx = S.selected_idx
  end
end

-- ============================================================================
-- ACTIONS
-- ============================================================================

local function SelectedProject()
  if S.selected_idx >= 1 and S.selected_idx <= #S.filtered_projects then
    return S.filtered_projects[S.selected_idx]
  end
  return nil
end

-- Multi-select helpers
local function IsSelected(i) return S.selected[i] == true end

local function SelectOnly(i)
  S.selected = { [i] = true }
  S.selected_idx = i
  S.sel_anchor = i
  S.pending_focus_idx = i
end

local function ToggleSelect(i)
  if S.selected[i] then S.selected[i] = nil else S.selected[i] = true end
  S.selected_idx = i
  S.sel_anchor = i
  S.pending_focus_idx = i
end

local function SelectRange(from, to)
  local lo, hi = math.min(from, to), math.max(from, to)
  for idx = lo, hi do S.selected[idx] = true end
  S.selected_idx = to
  S.pending_focus_idx = to
end

local function ClearSelection()
  S.selected = {}
  S.selected_idx = 0
  S.sel_anchor = 0
end

local function SelectionCount()
  local n = 0
  for _ in pairs(S.selected) do n = n + 1 end
  return n
end

local function GetSelectedProjects()
  local result = {}
  for i = 1, #S.filtered_projects do
    if S.selected[i] then result[#result + 1] = S.filtered_projects[i] end
  end
  return result
end

--- Trigger a Follow Action by firing a REAPER command ID (numeric or named).
--- Silently does nothing if the command ID is empty or invalid (same as solger's behavior).
local function TriggerFollowAction(commandID)
  if not commandID or commandID == '' then return end
  local id = tonumber(commandID)
  if id then
    reaper.Main_OnCommand(id, 0)
  else
    -- Named command (e.g. "_RS..." custom action identifier)
    local resolved = reaper.NamedCommandLookup(commandID)
    if resolved and resolved ~= 0 then
      reaper.Main_OnCommand(resolved, 0)
    end
  end
end

local function ActionOpenProject(proj)
  if not proj or not proj.exists then return end
  reaper.Main_openProject(ReaperPath(proj.path))
  
  -- Compare active project path after load to detect if user hit 'Cancel' in the save dialog.
  local _, path_after = reaper.EnumProjects(-1, "")
  local t_norm = ReaperPath(proj.path):gsub('\\', '/'):lower()
  local a_norm = (path_after or ""):gsub('\\', '/'):lower()
  if t_norm ~= a_norm then return end  -- Cancelled or failed to load
  
  TriggerFollowAction(S.followaction_load_project)
  if not S.keep_open then S.window_open = false end
end

local function ActionLoadInTab(proj)
  if not proj or not proj.exists then return end
  reaper.Main_OnCommand(41929, 0) -- New project tab (ignore default template)
  reaper.Main_openProject(ReaperPath(proj.path))
  
  local _, path_after = reaper.EnumProjects(-1, "")
  local t_norm = ReaperPath(proj.path):gsub('\\', '/'):lower()
  local a_norm = (path_after or ""):gsub('\\', '/'):lower()
  if t_norm ~= a_norm then return end  -- Cancelled or failed to load
  
  TriggerFollowAction(S.followaction_load_in_tab)
  if not S.keep_open then S.window_open = false end
end

--- Open multiple selected projects: first in current tab, rest in new tabs.
local function ActionOpenSelected()
  local sel = GetSelectedProjects()
  if #sel == 0 then return end
  
  -- First project opens in current tab
  if sel[1].exists then
    reaper.Main_openProject(ReaperPath(sel[1].path))
    local _, path_after = reaper.EnumProjects(-1, "")
    local t_norm = ReaperPath(sel[1].path):gsub('\\', '/'):lower()
    local a_norm = (path_after or ""):gsub('\\', '/'):lower()
    if t_norm == a_norm then
      TriggerFollowAction(S.followaction_load_project)
    end
  end
  
  -- Remaining projects each open in a new tab
  for i = 2, #sel do
    if sel[i].exists then
      reaper.Main_OnCommand(41929, 0) -- New project tab
      reaper.Main_openProject(ReaperPath(sel[i].path))
      local _, path_after = reaper.EnumProjects(-1, "")
      local t_norm = ReaperPath(sel[i].path):gsub('\\', '/'):lower()
      local a_norm = (path_after or ""):gsub('\\', '/'):lower()
      if t_norm == a_norm then
        TriggerFollowAction(S.followaction_load_in_tab)
      end
    end
  end
  if not S.keep_open then S.window_open = false end
end

local function ActionNewTab()
  reaper.Main_OnCommand(41929, 0) -- New project tab (ignore default template)
  TriggerFollowAction(S.followaction_new_tab)
end

local function ActionLocateInExplorer(proj)
  if not proj or not proj.exists then return end
  local os_name = reaper.GetOS()
  if os_name:match('OSX') or os_name:match('macOS') then
    -- macOS: CF_LocateInExplorer works natively with forward-slash paths
    reaper.CF_LocateInExplorer(proj.path)
  else
    -- Windows/Linux: CF_LocateInExplorer needs backslash paths on Windows
    local winpath = proj.path:gsub('/', '\\')
    reaper.CF_LocateInExplorer(winpath)
  end
end

local function ActionCopyPath(proj)
  if not proj then return end
  reaper.CF_SetClipboard(proj.path)
end

local function ActionCopyName(proj)
  if not proj then return end
  reaper.CF_SetClipboard(proj.name)
end

--- Copy names/paths/markdown for multiple projects (or single).
local function ActionCopyBulk(mode)
  local sel = GetSelectedProjects()
  if #sel == 0 then return end
  local parts = {}
  for _, p in ipairs(sel) do
    if mode == 'names' then
      parts[#parts + 1] = p.name
    elseif mode == 'paths' then
      parts[#parts + 1] = p.path
    elseif mode == 'markdown' then
      local line = '- ' .. p.name
      -- Append album in brackets if available
      if p.album then line = line .. ' [' .. p.album .. ']' end
      local meta = {}
      if p.displayBPM then meta[#meta + 1] = tostring(p.displayBPM) .. ' BPM' end
      if p.displayKey then meta[#meta + 1] = p.displayKey end
      local tags = p.tags or {}
      -- Strings + tuning combined (e.g. "7-string Drop A")
      local str_tuning = ''
      if tags.strings then str_tuning = tostring(tags.strings) .. '-string' end
      if tags.tuning then
        if str_tuning ~= '' then str_tuning = str_tuning .. ' ' .. tags.tuning
        else str_tuning = tags.tuning end
      end
      if str_tuning ~= '' then meta[#meta + 1] = str_tuning end
      -- First genre only
      local genre = tags.genre
      if genre then
        if type(genre) == 'table' then
          if genre[1] then meta[#meta + 1] = genre[1] end
        else
          meta[#meta + 1] = genre
        end
      end
      if tags.status then meta[#meta + 1] = tags.status end
      if #meta > 0 then line = line .. ' (' .. table.concat(meta, ', ') .. ')' end
      parts[#parts + 1] = line
    end
  end
  reaper.CF_SetClipboard(table.concat(parts, '\n'))
end

--- Helper: format duration seconds to M:SS string.
local function FormatDurationStr(secs)
  if not secs then return '' end
  local s = tonumber(secs)
  if not s or s <= 0 then return '' end
  return string.format('%d:%02d', math.floor(s / 60), math.floor(s) % 60)
end

--- Helper: safe CSV field — quote if contains comma, quote, or newline.
local function CsvField(val)
  if not val then return '' end
  local s = tostring(val)
  if s:find('[,"\n\r]') then
    return '"' .. s:gsub('"', '""') .. '"'
  end
  return s
end

--- Export the given project list to a file.
--- format: 'csv', 'markdown', or 'json'
local function ActionExportList(projects, format)
  if not projects or #projects == 0 then return end

  local ext_map = { csv = 'csv', markdown = 'md', json = 'json' }
  local ext = ext_map[format] or 'txt'
  local default_name = 'readashboard-export.' .. ext
  local filter = ext == 'csv' and 'CSV files (*.csv)\0*.csv\0'
              or ext == 'md'  and 'Markdown files (*.md)\0*.md\0'
              or ext == 'json' and 'JSON files (*.json)\0*.json\0'
              or 'All files (*.*)\0*.*\0'

  local retval, save_path = reaper.JS_Dialog_BrowseForSaveFile(
    'Export Project List', SCRIPT_DIR, default_name, filter)
  if retval ~= 1 or not save_path or save_path == '' then return end

  -- Ensure correct extension
  if not save_path:lower():match('%.' .. ext .. '$') then
    save_path = save_path .. '.' .. ext
  end

  local lines = {}

  if format == 'csv' then
    -- CSV header
    lines[1] = 'Name,Artist,Song,Album,BPM,Key,Time Sig,Duration,Strings,Tuning,Status,Difficulty,Genre,Guitar,Amp,Favorite,Notes,Path,Last Modified'
    for _, p in ipairs(projects) do
      local tags = p.tags or {}
      local row = table.concat({
        CsvField(p.name),
        CsvField(p.artist),
        CsvField(p.song),
        CsvField(p.album),
        CsvField(p.displayBPM),
        CsvField(p.displayKey),
        CsvField(p.projectTimeSig),
        CsvField(FormatDurationStr(p.duration)),
        CsvField(tags.strings),
        CsvField(tags.tuning),
        CsvField(tags.status),
        CsvField(tags.difficulty),
        CsvField(GenreStr(tags.genre)),
        CsvField(tags.guitar),
        CsvField(tags.amp),
        CsvField(tags.favorite and 'Yes' or ''),
        CsvField(tags.notes),
        CsvField(p.path),
        CsvField(p.lastModified),
      }, ',')
      lines[#lines + 1] = row
    end

  elseif format == 'markdown' then
    -- Markdown table header
    lines[1] = '| Name | Artist | Album | BPM | Key | Strings | Tuning | Genre | Status | Duration | Notes |'
    lines[2] = '|------|--------|-------|-----|-----|---------|--------|-------|--------|----------|-------|'
    for _, p in ipairs(projects) do
      local tags = p.tags or {}
      local row = '| ' .. table.concat({
        p.name or '',
        p.artist or '',
        p.album or '',
        p.displayBPM and tostring(p.displayBPM) or '',
        p.displayKey or '',
        tags.strings and tostring(tags.strings) or '',
        tags.tuning or '',
        GenreStr(tags.genre),
        tags.status or '',
        FormatDurationStr(p.duration),
        tags.notes or '',
      }, ' | ') .. ' |'
      lines[#lines + 1] = row
    end

  elseif format == 'json' then
    -- Build a Lua table and serialize with JsonPretty
    local arr = {}
    for _, p in ipairs(projects) do
      local tags = p.tags or {}
      arr[#arr + 1] = {
        name          = p.name,
        artist        = p.artist,
        song          = p.song,
        album         = p.album,
        bpm           = p.displayBPM,
        key           = p.displayKey,
        timeSig       = p.projectTimeSig,
        duration      = p.duration,
        durationStr   = FormatDurationStr(p.duration),
        strings       = tags.strings,
        tuning        = tags.tuning,
        status        = tags.status,
        difficulty    = tags.difficulty,
        genre         = tags.genre,
        guitar        = tags.guitar,
        amp           = tags.amp,
        favorite      = tags.favorite or false,
        notes         = tags.notes,
        path          = p.path,
        lastModified  = p.lastModified,
      }
    end
    lines[1] = JsonPretty(arr, 0)
  end

  local content = table.concat(lines, '\n')
  local f = io.open(save_path, 'w')
  if f then
    f:write(content)
    f:close()
    Log('Exported ' .. #projects .. ' projects to: ' .. save_path)
    -- Brief status message via reaper
    reaper.ShowMessageBox(
      'Exported ' .. #projects .. ' projects to:\n' .. save_path,
      'Export Complete', 0)
  else
    reaper.ShowMessageBox('Could not write to:\n' .. save_path, 'Export Error', 0)
  end
end

--- Remove a single project from REAPER's recent projects list.
--- Writes a space character to blank the entry in REAPER.ini (same as original ReaLauncher).
local function ActionRemoveFromRecent(proj)
  if not proj then return end
  local ini = reaper.get_ini_file()

  -- Find the entry by matching path
  local count = 0
  while true do
    count = count + 1
    local _, val = reaper.BR_Win32_GetPrivateProfileString(
      'recent', 'recent' .. string.format('%02d', count), 'noEntry', ini
    )
    if val == 'noEntry' then break end
    if count >= 512 then break end

    -- Normalize both paths for comparison (forward slashes, case-insensitive)
    local valNorm = NormalizePath(val):lower()
    local projNorm = NormalizePath(proj.path):lower()
    local altPath = GetAlternatePath(proj.path)
    local altNorm = altPath and NormalizePath(altPath):lower() or ''

    if valNorm == projNorm or valNorm == altNorm then
      -- Blank the entry (space character, same as original ReaLauncher)
      reaper.BR_Win32_WritePrivateProfileString(
        'recent', 'recent' .. string.format('%02d', count), ' ', ini
      )
      Log('Removed from recent: ' .. proj.name .. ' (entry ' .. count .. ')')
      break
    end
  end

  -- Reload the list
  S.recent_projects = LoadRecentProjects()
  for _, p in ipairs(S.recent_projects) do p.isRecent = true end
  if S.cache_loaded then ApplyCachedMetadata(S.recent_projects) end
  RefreshFiltered()
  BuildImageQueue()
end

--- Count invalid (non-existent) entries in REAPER.ini recent list.
local function CountInvalidRecentEntries()
  local ini = reaper.get_ini_file()
  local invalid = 0
  local count = 0
  while true do
    count = count + 1
    local _, val = reaper.BR_Win32_GetPrivateProfileString(
      'recent', 'recent' .. string.format('%02d', count), 'noEntry', ini
    )
    if val == 'noEntry' then break end
    if count >= 512 then break end
    if val and val ~= '' and val ~= ' ' then
      if not reaper.file_exists(val) then
        invalid = invalid + 1
      end
    end
  end
  return invalid
end

--- Remove all invalid (non-existent) entries from REAPER.ini recent list.
local function ActionRemoveInvalidEntries()
  local ini = reaper.get_ini_file()
  local removed = 0
  local count = 0
  while true do
    count = count + 1
    local _, val = reaper.BR_Win32_GetPrivateProfileString(
      'recent', 'recent' .. string.format('%02d', count), 'noEntry', ini
    )
    if val == 'noEntry' then break end
    if count >= 512 then break end
    if val and val ~= '' and val ~= ' ' then
      if not reaper.file_exists(val) then
        reaper.BR_Win32_WritePrivateProfileString(
          'recent', 'recent' .. string.format('%02d', count), ' ', ini
        )
        removed = removed + 1
      end
    end
  end
  Log('Removed ' .. removed .. ' invalid entries from recent list')

  -- Reload the list
  S.recent_projects = LoadRecentProjects()
  for _, p in ipairs(S.recent_projects) do p.isRecent = true end
  if S.cache_loaded then ApplyCachedMetadata(S.recent_projects) end
  RefreshFiltered()
  BuildImageQueue()
end

--- Normal refresh: reload project lists, apply cached metadata.
--- Fast (<0.5s) — does not re-scan spicetify DB or RPP files.
local function ActionRefresh()
  local t0 = reaper.time_precise()
  S.recent_projects = LoadRecentProjects()
  -- Mark recent projects
  for _, p in ipairs(S.recent_projects) do p.isRecent = true end
  Log('    LoadRecentProjects: ' .. string.format('%.1fms', (reaper.time_precise() - t0) * 1000))

  -- Load all-projects from scan cache (if available and not already loaded)
  if not S.all_projects_loaded then
    t0 = reaper.time_precise()
    local cached_all = LoadAllProjectsScan()
    if cached_all then
      S.all_projects = cached_all
      S.all_projects_loaded = true
      Log('    LoadAllProjectsScan (cache): ' .. string.format('%.1fms', (reaper.time_precise() - t0) * 1000))
    end
  end

  -- Apply metadata to recent projects
  t0 = reaper.time_precise()
  if S.cache_loaded then
    ApplyCachedMetadata(S.recent_projects)
    Log('    ApplyCachedMetadata (recent): ' .. string.format('%.1fms', (reaper.time_precise() - t0) * 1000))
  else
    -- No cache yet — must do full scan
    EnrichProjects(S.recent_projects)
    Log('    EnrichProjects (recent, full): ' .. string.format('%.1fms', (reaper.time_precise() - t0) * 1000))
  end

  -- Apply metadata to all-projects (if loaded)
  if S.all_projects_loaded and #S.all_projects > 0 then
    t0 = reaper.time_precise()
    if S.cache_loaded then
      ApplyCachedMetadata(S.all_projects)
      Log('    ApplyCachedMetadata (all): ' .. string.format('%.1fms', (reaper.time_precise() - t0) * 1000))
    else
      -- Cache-miss: scan cache exists but metadata cache doesn't — enrich all-projects too
      EnrichProjects(S.all_projects)
      Log('    EnrichProjects (all, full): ' .. string.format('%.1fms', (reaper.time_precise() - t0) * 1000))
    end
  end

  -- Save cache if first-time full scan happened (include all-projects if loaded)
  if not S.cache_loaded then
    t0 = reaper.time_precise()
    local combined = {}
    for _, p in ipairs(S.recent_projects) do combined[#combined + 1] = p end
    if S.all_projects_loaded then
      for _, p in ipairs(S.all_projects) do combined[#combined + 1] = p end
    end
    SaveMetadataCache(combined)
    Log('    SaveMetadataCache: ' .. string.format('%.1fms', (reaper.time_precise() - t0) * 1000))
  end

  -- Set active source
  projects = (S.active_tab == 'all' and S.all_projects_loaded) and S.all_projects or S.recent_projects

  t0 = reaper.time_precise()
  RefreshFiltered()
  Log('    RefreshFiltered: ' .. string.format('%.1fms', (reaper.time_precise() - t0) * 1000))

  BuildImageQueue()  -- queue any new images for progressive loading
end

--- Hard refresh: full re-scan of everything — spicetify DB, RPP files, all-projects directory.
--- Slower but picks up new metadata and new project files.
--- Triggered by Shift+F5 or right-clicking the Refresh button.
local function ActionHardRefresh()
  Log('Hard refresh: re-scanning all metadata sources...')
  local t0

  S.spicetify_scanned = false  -- force spicetify DB re-scan
  spicetify_cache = {}
  spicetify_by_artist = {}
  spicetify_songs_flat = {}
  LoadTags()  -- reload tags from disk (picks up manual edits to project-tags.json)

  -- Reload recent projects
  t0 = reaper.time_precise()
  S.recent_projects = LoadRecentProjects()
  for _, p in ipairs(S.recent_projects) do p.isRecent = true end
  Log('  LoadRecentProjects: ' .. string.format('%.1fms', (reaper.time_precise() - t0) * 1000))

  -- Full re-scan of all projects directory
  t0 = reaper.time_precise()
  S.all_projects = ScanAllProjectFiles()
  S.all_projects_loaded = true
  Log('  ScanAllProjectFiles: ' .. string.format('%.1fms', (reaper.time_precise() - t0) * 1000))

  -- Save all-projects scan listing
  t0 = reaper.time_precise()
  SaveAllProjectsScan(S.all_projects)
  Log('  SaveAllProjectsScan: ' .. string.format('%.1fms', (reaper.time_precise() - t0) * 1000))

  -- Enrich both lists with full metadata
  t0 = reaper.time_precise()
  EnrichProjects(S.recent_projects)
  Log('  EnrichProjects (recent): ' .. string.format('%.1fms', (reaper.time_precise() - t0) * 1000))

  t0 = reaper.time_precise()
  EnrichProjects(S.all_projects)
  Log('  EnrichProjects (all): ' .. string.format('%.1fms', (reaper.time_precise() - t0) * 1000))

  -- Save unified metadata cache (merge both lists by name)
  t0 = reaper.time_precise()
  local combined = {}
  -- Add all-projects first, then recent (recent overwrites = more accurate dates)
  for _, p in ipairs(S.all_projects) do combined[#combined + 1] = p end
  for _, p in ipairs(S.recent_projects) do combined[#combined + 1] = p end
  SaveMetadataCache(combined)
  Log('  SaveMetadataCache (combined): ' .. string.format('%.1fms', (reaper.time_precise() - t0) * 1000))

  -- Set active source
  projects = (S.active_tab == 'all' and S.all_projects_loaded) and S.all_projects or S.recent_projects

  RefreshFiltered()
  BuildImageQueue()
  Log('Hard refresh complete.')
end

local function ActionToggleFavorite(proj)
  if not proj then return end
  local tags = proj.tags or {}
  local newVal = not tags.favorite
  SetTag(proj.path, 'favorite', newVal)
  proj.tags = GetTags(proj.path)
  BuildSearchHaystack(proj)
  SaveTags()
  RefreshFiltered()
end

-- ============================================================================
-- WINDOW STATE PERSISTENCE (via ExtState)
-- ============================================================================

local function SaveState()
  local function Set(key, val) reaper.SetExtState(CFG.EXT_SECTION, key, tostring(val), true) end
  Set('default_recent_sort', S.default_recent_sort)
  Set('default_all_sort',    S.default_all_sort)
  Set('artist_sort_by_album', S.artist_sort_by_album and '1' or '0')
  Set('keep_open',         S.keep_open and '1' or '0')
  Set('persistent_mode',       S.persistent_mode and '1' or '0')
  Set('close_on_new_instance', S.close_on_new_instance and '1' or '0')
  Set('close_on_unfocus',      S.close_on_unfocus and '1' or '0')
  Set('close_on_escape',       S.close_on_escape and '1' or '0')
  Set('recent_view_mode',  S.recent_view_mode)
  Set('all_view_mode',     S.all_view_mode)
  Set('active_tab',        S.active_tab)
  Set('universal_search',  S.universal_search and '1' or '0')
  Set('auto_focus_search', S.auto_focus_search and '1' or '0')
  Set('font_size',         S.font_size)
  Set('art_size',          S.art_size)
  Set('grid_cols',          S.grid_cols)
  -- Set('grid_card_size',    S.grid_card_size)  -- hidden: replaced by grid_cols
  Set('grid_spacing',      S.grid_spacing)
  Set('grid_line_h',       S.grid_line_h)
  Set('grid_show_artist',     S.grid_show_artist and '1' or '0')
  Set('grid_show_bpm_key',   S.grid_show_bpm_key and '1' or '0')
  Set('grid_show_status',    S.grid_show_status and '1' or '0')
  Set('grid_show_favorite',  S.grid_show_favorite and '1' or '0')
  Set('grid_show_duration',  S.grid_show_duration and '1' or '0')
  Set('grid_show_strings',   S.grid_show_strings and '1' or '0')
  Set('grid_show_album',     S.grid_show_album and '1' or '0')
  Set('grid_show_genre',     S.grid_show_genre and '1' or '0')
  Set('grid_show_difficulty', S.grid_show_difficulty and '1' or '0')
  Set('grid_show_date',      S.grid_show_date and '1' or '0')
  Set('grid_show_as_tooltip', S.grid_show_as_tooltip and '1' or '0')
  Set('grid_show_tuning',     S.grid_show_tuning and '1' or '0')
  Set('grid_show_transpose',  S.grid_show_transpose and '1' or '0')
  Set('grid_tooltip_delay',   tostring(S.grid_tooltip_delay))
  Set('custom_primary_genres', S.custom_primary_genres)
  Set('custom_statuses', S.custom_statuses)
  Set('accent_color',       S.accent_color)
  Set('theme_preset',       S.theme_preset)
  -- Appearance settings
  Set('bg_color',           S.bg_color)
  Set('text_color',         S.text_color)
  Set('fav_star_color',     S.fav_star_color)
  Set('dim_text_pct',       S.dim_text_pct)
  Set('window_opacity',     string.format('%.2f', S.window_opacity))
  Set('corner_rounding',    S.corner_rounding)
  Set('density',            S.density)
  Set('show_borders',       S.show_borders and '1' or '0')
  Set('alt_row_bg',         S.alt_row_bg and '1' or '0')
  Set('theme_base_preset',  S.theme_base_preset)
  Set('fade_in_duration',   string.format('%.2f', S.fade_in_duration))
  Set('tag_editor_w',       S.tag_editor_w)
  Set('tag_editor_h',      S.tag_editor_h)
  Set('show_dedupe',       tostring(S.show_dedupe))
  Set('dedupe_mode',       S.dedupe_mode)
  Set('exclusion_patterns', S.exclusion_patterns:gsub('\n', '|'))
  Set('show_hidden',       tostring(S.show_hidden))
  Set('show_excluded',     tostring(S.show_excluded))
  Set('show_art_placeholder', S.show_art_placeholder and '1' or '0')
  
  Set('enable_spicetify',  S.enable_spicetify and '1' or '0')
  Set('spicetify_db_path', S.spicetify_db_path)
  Set('album_art_db_path', S.album_art_db_path)
  Set('symlink_src',       S.symlink_src)
  Set('symlink_dest',      S.symlink_dest)

  Set('default_artwork_path', S.default_artwork_path)
  Set('placeholder_full_name', S.placeholder_full_name and '1' or '0')
  Set('all_projects_path', S.ALL_PROJECTS_PATH)
  Set('additional_project_paths', table.concat(S.additional_project_paths, '|'))
  Set('all_scan_max_depth', S.ALL_SCAN_MAX_DEPTH)
  Set('image_batch_size',  S.IMAGE_BATCH_SIZE)
  Set('img_first_frame_ms', S.img_first_frame_ms)
  Set('img_per_frame_ms',   S.img_per_frame_ms)
  Set('debug_logging',     S.debug_logging and '1' or '0')
  -- Follow Actions
  Set('followaction_load_project', S.followaction_load_project)
  Set('followaction_load_in_tab',  S.followaction_load_in_tab)
  Set('followaction_new_tab',      S.followaction_new_tab)
  -- Search history
  Set('search_history_enabled', S.search_history_enabled and '1' or '0')
  Set('search_history', table.concat(S.search_history, '|'))
  -- NOTE: SaveHidden() and SaveWhitelist() are NOT called here.
  -- They write to disk (JSON files) and would cause I/O on every slider drag / UI change.
  -- Instead, they are called only at the exact points where hidden/whitelist data changes.
  -- Sync active filters back to per-tab storage before persisting
  SaveFiltersToTab(S.active_tab)
  -- Persist tri-state filters per-tab (survive restart)
  Set('recent_filter_tri_meta',  S.recent_filter_tri_meta)
  Set('recent_filter_tri_art',   S.recent_filter_tri_art)
  Set('recent_filter_tri_tags',  S.recent_filter_tri_tags)
  Set('all_filter_tri_meta',     S.all_filter_tri_meta)
  Set('all_filter_tri_art',      S.all_filter_tri_art)
  Set('all_filter_tri_tags',     S.all_filter_tri_tags)
  -- Include All Projects filter (persisted permanently)
  Set('recent_filter_include_all', S.recent_filter_include_all and '1' or '0')
  -- Session-scoped state (persist=false: lives only while REAPER is running)
  local function SetSession(key, val) reaper.SetExtState(CFG.EXT_SECTION, 's_' .. key, tostring(val), false) end
  SetSession('recent_sort_mode', S.recent_sort_mode)
  SetSession('all_sort_mode',    S.all_sort_mode)
  SetSession('search_buf',       S.search_buf)
  SetSession('active_tab',       S.active_tab)

  SetSession('recent_filter_strings', S.recent_filter_strings)
  SetSession('recent_filter_tuning',  S.recent_filter_tuning)
  SetSession('recent_filter_status',  S.recent_filter_status)
  SetSession('recent_filter_favs',    S.recent_filter_favs and '1' or '0')
  SetSession('recent_filter_genre',   S.recent_filter_genre)

  SetSession('all_filter_strings',    S.all_filter_strings)
  SetSession('all_filter_tuning',     S.all_filter_tuning)
  SetSession('all_filter_status',     S.all_filter_status)
  SetSession('all_filter_favs',       S.all_filter_favs and '1' or '0')
  SetSession('all_filter_genre',      S.all_filter_genre)
  
  SetSession('all_filter_exclude_recents', S.all_filter_exclude_recents and '1' or '0')
end

local function LoadState()
  local function G(key) return reaper.GetExtState(CFG.EXT_SECTION, key) end

  -- Default sort modes (persisted permanently, applied on script launch)
  local drs = G('default_recent_sort')
  if drs ~= '' then S.default_recent_sort = tonumber(drs) or CFG.SORT_NEWEST end
  local das = G('default_all_sort')
  if das ~= '' then S.default_all_sort = tonumber(das) or CFG.SORT_AZ end
  -- Apply defaults as the active sort (session persistence will override later if same session)
  S.recent_sort_mode = S.default_recent_sort
  S.all_sort_mode = S.default_all_sort

  -- Artist sort album grouping
  local asba = G('artist_sort_by_album')
  if asba ~= '' then S.artist_sort_by_album = (asba == '1') end

  local ko = G('keep_open')
  if ko ~= '' then S.keep_open = (ko == '1') end
  local pm = G('persistent_mode')
  if pm ~= '' then S.persistent_mode = (pm == '1') end
  local coni = G('close_on_new_instance')
  if coni ~= '' then S.close_on_new_instance = (coni == '1') end
  local cou = G('close_on_unfocus')
  if cou ~= '' then S.close_on_unfocus = (cou == '1') end
  local coe = G('close_on_escape')
  if coe ~= '' then S.close_on_escape = (coe == '1') end

  -- Per-tab view modes (migrate from old single S.view_mode if present)
  local rvm = G('recent_view_mode')
  if rvm ~= '' then S.recent_view_mode = rvm end
  local avm = G('all_view_mode')
  if avm ~= '' then S.all_view_mode = avm end
  -- Legacy migration: old single S.view_mode → apply to both tabs
  if rvm == '' and avm == '' then
    local vm = G('view_mode')
    if vm == 'grid' then S.recent_view_mode = 'grid'; S.all_view_mode = 'grid' end
  end

  local at = G('active_tab')
  if at == 'all' then S.active_tab = 'all'
  elseif at == 'settings' then S.active_tab = 'settings'
  elseif at == 'actions' then S.active_tab = 'actions' end

  local us = G('universal_search')
  if us ~= '' then S.universal_search = (us == '1') end

  local afs = G('auto_focus_search')
  if afs ~= '' then S.auto_focus_search = (afs == '1') end

  local fs = G('font_size')
  if fs ~= '' then S.font_size = tonumber(fs) or CFG.DEFAULT_FONT_SIZE end
  S.font_size = math.max(CFG.MIN_FONT_SIZE, math.min(CFG.MAX_FONT_SIZE, S.font_size))

  local as = G('art_size')
  if as ~= '' then S.art_size = tonumber(as) or CFG.DEFAULT_ART_SIZE end
  S.art_size = math.max(CFG.MIN_ART_SIZE, math.min(CFG.MAX_ART_SIZE, S.art_size))

  local gcols = G('grid_cols')
  if gcols ~= '' then S.grid_cols = tonumber(gcols) or 5 end
  S.grid_cols = math.max(2, math.min(10, S.grid_cols))
  local gsp = G('grid_spacing')
  if gsp ~= '' then S.grid_spacing = tonumber(gsp) or 8 end
  S.grid_spacing = math.max(0, math.min(32, S.grid_spacing))
  -- Legacy: grid_card_size still loaded for potential future use
  local gcs = G('grid_card_size')
  if gcs ~= '' then S.grid_card_size = tonumber(gcs) or CFG.DEFAULT_GRID_CARD_SIZE end
  S.grid_card_size = math.max(CFG.MIN_GRID_CARD_SIZE, math.min(CFG.MAX_GRID_CARD_SIZE, S.grid_card_size))

  local glh = G('grid_line_h')
  if glh ~= '' then S.grid_line_h = tonumber(glh) or CFG.DEFAULT_GRID_LINE_H end
  S.grid_line_h = math.max(CFG.MIN_GRID_LINE_H, math.min(CFG.MAX_GRID_LINE_H, S.grid_line_h))

  local sap = G('show_art_placeholder')
  if sap ~= '' then S.show_art_placeholder = (sap == '1') end

  -- Grid card display toggles
  local gsa = G('grid_show_artist')
  if gsa ~= '' then S.grid_show_artist = (gsa == '1') end
  local gsbk = G('grid_show_bpm_key')
  if gsbk ~= '' then S.grid_show_bpm_key = (gsbk == '1') end
  local gss = G('grid_show_status')
  if gss ~= '' then S.grid_show_status = (gss == '1') end
  local gsf = G('grid_show_favorite')
  if gsf ~= '' then S.grid_show_favorite = (gsf == '1') end
  local gsd = G('grid_show_duration')
  if gsd ~= '' then S.grid_show_duration = (gsd == '1') end
  local gstr = G('grid_show_strings')
  if gstr ~= '' then S.grid_show_strings = (gstr == '1') end
  local gsal = G('grid_show_album')
  if gsal ~= '' then S.grid_show_album = (gsal == '1') end
  local gsge = G('grid_show_genre')
  if gsge ~= '' then S.grid_show_genre = (gsge == '1') end
  local gsdi = G('grid_show_difficulty')
  if gsdi ~= '' then S.grid_show_difficulty = (gsdi == '1') end
  local gsdt = G('grid_show_date')
  if gsdt ~= '' then S.grid_show_date = (gsdt == '1') end
  local gstt = G('grid_show_as_tooltip')
  if gstt ~= '' then S.grid_show_as_tooltip = (gstt == '1') end
  local gstn = G('grid_show_tuning')
  if gstn ~= '' then S.grid_show_tuning = (gstn == '1') end
  local gstp = G('grid_show_transpose')
  if gstp ~= '' then S.grid_show_transpose = (gstp == '1') end
  local gtd = G('grid_tooltip_delay')
  if gtd ~= '' then S.grid_tooltip_delay = tonumber(gtd) or 0.0 end
  local cpg = G('custom_primary_genres')
  if cpg ~= '' then S.custom_primary_genres = cpg end
  RebuildGenreLists()
  local cst = G('custom_statuses')
  if cst ~= '' then S.custom_statuses = cst end
  RebuildStatusLists()

  -- Accent color / theme preset
  local ac = G('accent_color')
  if ac ~= '' then S.accent_color = tonumber(ac) or 0x4A8FB8 end
  local tp = G('theme_preset')
  if tp ~= '' then S.theme_preset = tonumber(tp) or 1 end

  -- Appearance settings
  local bgc = G('bg_color')
  if bgc ~= '' then S.bg_color = tonumber(bgc) or 0x1B1B1B end
  local txc = G('text_color')
  if txc ~= '' then S.text_color = tonumber(txc) or 0xDCDCDC end
  local fsc = G('fav_star_color')
  if fsc ~= '' then S.fav_star_color = tonumber(fsc) or 0xE8C84D end
  local dtp = G('dim_text_pct')
  if dtp ~= '' then S.dim_text_pct = tonumber(dtp) or 50 end
  S.dim_text_pct = math.max(50, math.min(100, S.dim_text_pct))
  local wop = G('window_opacity')
  if wop ~= '' then S.window_opacity = tonumber(wop) or 1.0 end
  S.window_opacity = math.max(0.3, math.min(1.0, S.window_opacity))
  local crn = G('corner_rounding')
  if crn ~= '' then S.corner_rounding = tonumber(crn) or 4 end
  S.corner_rounding = math.max(0, math.min(12, S.corner_rounding))
  local dns = G('density')
  if dns ~= '' then S.density = tonumber(dns) or 50 end
  S.density = math.max(0, math.min(100, S.density))
  local sbr = G('show_borders')
  if sbr ~= '' then S.show_borders = (sbr == '1') end
  local arb = G('alt_row_bg')
  if arb ~= '' then S.alt_row_bg = (arb == '1') end
  local tbp = G('theme_base_preset')
  if tbp ~= '' then S.theme_base_preset = tonumber(tbp) or 1 end
  local fid = G('fade_in_duration')
  if fid ~= '' then S.fade_in_duration = tonumber(fid) or 0.15 end
  S.fade_in_duration = math.max(0, math.min(0.5, S.fade_in_duration))
  -- Note: RecomputeTheme() is called after LoadState() in Init()

  local app = G('all_projects_path')
  if app ~= '' then
    -- Basic migration check
    if app:lower():gsub('\\', '/') == 'g:/reaper media' then
      S.ALL_PROJECTS_PATH = ''
    else
      S.ALL_PROJECTS_PATH = app
    end
  end

  local appaths = G('additional_project_paths')
  if appaths ~= '' then
    S.additional_project_paths = {}
    for p in appaths:gmatch('[^|]+') do
      if p ~= '' then S.additional_project_paths[#S.additional_project_paths + 1] = p end
    end
  end

  local dap = G('default_artwork_path')
  if dap ~= '' then S.default_artwork_path = dap end
  local pfn = G('placeholder_full_name')
  if pfn ~= '' then S.placeholder_full_name = (pfn == '1') end

  local es = G('enable_spicetify')
  if es ~= '' then S.enable_spicetify = (es == '1') end
  local sdp = G('spicetify_db_path')
  if sdp ~= '' then S.spicetify_db_path = sdp end
  local aadp = G('album_art_db_path')
  if aadp ~= '' then S.album_art_db_path = aadp end
  local ssrc = G('symlink_src')
  if ssrc ~= '' then S.symlink_src = ssrc end
  local sdest = G('symlink_dest')
  if sdest ~= '' then S.symlink_dest = sdest end

  local asd = G('all_scan_max_depth')
  if asd ~= '' then S.ALL_SCAN_MAX_DEPTH = tonumber(asd) or 10 end
  S.ALL_SCAN_MAX_DEPTH = math.max(1, math.min(20, S.ALL_SCAN_MAX_DEPTH))

  local ibs = G('image_batch_size')
  if ibs ~= '' then S.IMAGE_BATCH_SIZE = tonumber(ibs) or 5 end
  S.IMAGE_BATCH_SIZE = math.max(1, math.min(20, S.IMAGE_BATCH_SIZE))

  local iffm = G('img_first_frame_ms')
  if iffm ~= '' then S.img_first_frame_ms = tonumber(iffm) or 32 end
  S.img_first_frame_ms = math.max(4, math.min(500, S.img_first_frame_ms))
  local ipfm = G('img_per_frame_ms')
  if ipfm ~= '' then S.img_per_frame_ms = tonumber(ipfm) or 16 end
  S.img_per_frame_ms = math.max(4, math.min(200, S.img_per_frame_ms))

  local dbg = G('debug_logging')
  if dbg ~= '' then S.debug_logging = (dbg == '1') end
  InitLogFile() -- Now that settings are loaded, initialize log file truncation if enabled

  local tew = G('tag_editor_w')
  if tew ~= '' then S.tag_editor_w = tonumber(tew) or 480 end
  S.tag_editor_w = math.max(400, math.min(800, S.tag_editor_w))
  local teh = G('tag_editor_h')
  if teh ~= '' then S.tag_editor_h = tonumber(teh) or 640 end
  S.tag_editor_h = math.max(400, math.min(1000, S.tag_editor_h))

  -- Dedupe: load new key, fall back to old 'show_main_only' for migration
  local sd = G('show_dedupe')
  if sd ~= '' then
    S.show_dedupe = tonumber(sd) or 0
  else
    -- Migration from old boolean show_main_only
    local smo = G('show_main_only')
    if smo ~= '' then S.show_dedupe = (smo == '1') and 0 or 1 end
  end
  local dm = G('dedupe_mode')
  if dm ~= '' then S.dedupe_mode = dm end

  local ep = G('exclusion_patterns')
  if ep ~= '' then S.exclusion_patterns = ep:gsub('|', '\n') end

  local sh = G('show_hidden')
  if sh ~= '' then S.show_hidden = tonumber(sh) or 0 end
  local se = G('show_excluded')
  if se ~= '' then S.show_excluded = tonumber(se) or 0 end

  -- Hidden projects loaded from JSON file (see LoadHidden(), called separately in Init)

  -- Whitelist loaded from JSON file (see LoadWhitelist(), called separately in Init)

  -- Restore persisted per-tab filters (tri-state survive restart)
  local rftm = G('recent_filter_tri_meta')
  if rftm ~= '' then S.recent_filter_tri_meta = tonumber(rftm) or 0 end
  local rfta = G('recent_filter_tri_art')
  if rfta ~= '' then S.recent_filter_tri_art = tonumber(rfta) or 0 end
  local rftt = G('recent_filter_tri_tags')
  if rftt ~= '' then S.recent_filter_tri_tags = tonumber(rftt) or 0 end
  local aftm = G('all_filter_tri_meta')
  if aftm ~= '' then S.all_filter_tri_meta = tonumber(aftm) or 0 end
  local afta = G('all_filter_tri_art')
  if afta ~= '' then S.all_filter_tri_art = tonumber(afta) or 0 end
  local aftt = G('all_filter_tri_tags')
  if aftt ~= '' then S.all_filter_tri_tags = tonumber(aftt) or 0 end
  -- Include All Projects filter
  local rfia = G('recent_filter_include_all')
  if rfia ~= '' then S.recent_filter_include_all = (rfia == '1') end

  -- Follow Actions
  local fa_lp = G('followaction_load_project')
  if fa_lp ~= '' then S.followaction_load_project = fa_lp end
  local fa_lt = G('followaction_load_in_tab')
  if fa_lt ~= '' then S.followaction_load_in_tab = fa_lt end
  local fa_nt = G('followaction_new_tab')
  if fa_nt ~= '' then S.followaction_new_tab = fa_nt end

  -- Search history
  local she = G('search_history_enabled')
  if she ~= '' then S.search_history_enabled = (she == '1') end
  local sh_raw = G('search_history')
  if sh_raw ~= '' then
    S.search_history = {}
    for entry in sh_raw:gmatch('[^|]+') do
      S.search_history[#S.search_history + 1] = entry
    end
  end

  -- Session state restoration (persist=false: only exists within same REAPER session)
  -- These override defaults when re-opening the script within the same REAPER session
  local function GS(key) return reaper.GetExtState(CFG.EXT_SECTION, 's_' .. key) end
  local s_rsm = GS('recent_sort_mode')
  if s_rsm ~= '' then S.recent_sort_mode = tonumber(s_rsm) or S.default_recent_sort end
  local s_asm = GS('all_sort_mode')
  if s_asm ~= '' then S.all_sort_mode = tonumber(s_asm) or S.default_all_sort end
  local s_sb = GS('search_buf')
  if s_sb ~= '' then S.search_buf = s_sb end
  local s_at = GS('active_tab')
  if s_at ~= '' then S.active_tab = s_at end

  local s_rfs = GS('recent_filter_strings')
  if s_rfs ~= '' then S.recent_filter_strings = tonumber(s_rfs) or 1 end
  local s_rft = GS('recent_filter_tuning')
  if s_rft ~= '' then S.recent_filter_tuning = tonumber(s_rft) or 1 end
  local s_rfs2 = GS('recent_filter_status')
  if s_rfs2 ~= '' then S.recent_filter_status = tonumber(s_rfs2) or 1 end
  local s_rff = GS('recent_filter_favs')
  if s_rff ~= '' then S.recent_filter_favs = (s_rff == '1') end
  local s_rfg = GS('recent_filter_genre')
  if s_rfg ~= '' then S.recent_filter_genre = tonumber(s_rfg) or 1 end

  local s_afs = GS('all_filter_strings')
  if s_afs ~= '' then S.all_filter_strings = tonumber(s_afs) or 1 end
  local s_aft = GS('all_filter_tuning')
  if s_aft ~= '' then S.all_filter_tuning = tonumber(s_aft) or 1 end
  local s_afs2 = GS('all_filter_status')
  if s_afs2 ~= '' then S.all_filter_status = tonumber(s_afs2) or 1 end
  local s_aff = GS('all_filter_favs')
  if s_aff ~= '' then S.all_filter_favs = (s_aff == '1') end
  local s_afg = GS('all_filter_genre')
  if s_afg ~= '' then S.all_filter_genre = tonumber(s_afg) or 1 end

  local s_afer = GS('all_filter_exclude_recents')
  if s_afer ~= '' then S.all_filter_exclude_recents = (s_afer == '1') end

  -- Set active S.sort_mode and S.view_mode from the persisted active tab
  S.sort_mode = (S.active_tab == 'all') and S.all_sort_mode or S.recent_sort_mode
  S.view_mode = (S.active_tab == 'all') and S.all_view_mode or S.recent_view_mode
  -- Load active tab's filters into active filter state
  LoadFiltersFromTab(S.active_tab == 'all' and 'all' or 'recent')
end

-- ============================================================================
-- THEME
-- ============================================================================

-- pushed_colors and pushed_vars are in S table

local function PushColor(id, col, skip_opacity)
  -- Apply window opacity + fade-in: scale the alpha channel of surface colors (not text)
  local eff_opacity = S.window_opacity * S.anim_alpha  -- combined opacity
  if not skip_opacity and eff_opacity < 1.0 then
    local alpha = col % 0x100  -- extract low byte (alpha)
    if alpha > 0 then
      local rgb_part = col - alpha  -- 0xRRGGBB00
      alpha = math.max(1, math.floor(alpha * eff_opacity + 0.5))
      col = rgb_part + alpha
    end
  -- Fade-in also affects text (everything fades in together)
  elseif skip_opacity and S.anim_alpha < 1.0 then
    local alpha = col % 0x100
    if alpha > 0 then
      local rgb_part = col - alpha
      alpha = math.max(1, math.floor(alpha * S.anim_alpha + 0.5))
      col = rgb_part + alpha
    end
  end
  ImGui.PushStyleColor(ctx, id, col)
  S.pushed_colors = S.pushed_colors + 1
end

local function PushVar(id, ...)
  ImGui.PushStyleVar(ctx, id, ...)
  S.pushed_vars = S.pushed_vars + 1
end

local function PushTheme()
  S.pushed_colors = 0
  S.pushed_vars   = 0

  -- Backgrounds
  PushColor(ImGui.Col_WindowBg,        C.windowBg)
  PushColor(ImGui.Col_ChildBg,         C.childBg)
  PushColor(ImGui.Col_PopupBg,         C.popupBg)
  PushColor(ImGui.Col_TitleBg,         C.titleBg)
  PushColor(ImGui.Col_TitleBgActive,   C.titleBgActive)

  -- Text (skip opacity — text must stay readable)
  PushColor(ImGui.Col_Text,            C.text, true)
  PushColor(ImGui.Col_TextDisabled,    C.textDisabled, true)  -- for placeholders/disabled items (fixed dim)

  -- Borders
  PushColor(ImGui.Col_Border,          C.border)
  PushColor(ImGui.Col_Separator,       C.separator)

  -- Buttons
  PushColor(ImGui.Col_Button,          C.button)
  PushColor(ImGui.Col_ButtonHovered,   C.buttonHov)
  PushColor(ImGui.Col_ButtonActive,    C.buttonAct)

  -- Headers
  PushColor(ImGui.Col_Header,          C.header)
  PushColor(ImGui.Col_HeaderHovered,   C.headerHov)
  PushColor(ImGui.Col_HeaderActive,    C.headerAct)

  -- Frames
  PushColor(ImGui.Col_FrameBg,         C.frameBg)
  PushColor(ImGui.Col_FrameBgHovered,  C.frameBgHov)
  PushColor(ImGui.Col_FrameBgActive,   C.frameBgAct)

  -- Scrollbar
  PushColor(ImGui.Col_ScrollbarBg,          C.scrollBg)
  PushColor(ImGui.Col_ScrollbarGrab,        C.scrollGrab)
  PushColor(ImGui.Col_ScrollbarGrabHovered, C.scrollGrabHov)
  PushColor(ImGui.Col_ScrollbarGrabActive,  C.scrollGrabAct)

  -- Tabs
  PushColor(ImGui.Col_Tab,             C.tab)
  PushColor(ImGui.Col_TabHovered,      C.tabHov)
  PushColor(ImGui.Col_TabSelected,     C.tabAct)

  -- Table
  PushColor(ImGui.Col_TableHeaderBg,     C.tableHeaderBg)
  PushColor(ImGui.Col_TableBorderStrong, C.tableBorderH)
  PushColor(ImGui.Col_TableBorderLight,  C.tableBorderL)
  PushColor(ImGui.Col_TableRowBg,        C.tableRowBg)
  PushColor(ImGui.Col_TableRowBgAlt,     C.tableRowBgAlt)

  -- Check marks & nav (skip opacity — UI indicators must stay visible)
  PushColor(ImGui.Col_CheckMark,       C.checkMark, true)
  PushColor(ImGui.Col_NavCursor,       C.navHighlight, true)

  -- Rounding (derived from S.corner_rounding)
  local rnd = S.corner_rounding
  PushVar(ImGui.StyleVar_WindowRounding,    math.floor(rnd * 1.5))
  PushVar(ImGui.StyleVar_FrameRounding,     rnd * 1.0)
  PushVar(ImGui.StyleVar_GrabRounding,      math.floor(rnd * 0.75))
  PushVar(ImGui.StyleVar_TabRounding,       rnd * 1.0)
  PushVar(ImGui.StyleVar_ScrollbarRounding, rnd * 1.0)
  PushVar(ImGui.StyleVar_PopupRounding,     rnd * 1.0)

  -- Spacing (interpolated from density slider: 0=compact, 50=normal, 100=spacious)
  local d = S.density / 100  -- 0.0 to 1.0
  local DC, DS = DENSITY_RANGE[1], DENSITY_RANGE[2]
  local function lerp(a, b) return math.floor(a + (b - a) * d) end
  PushVar(ImGui.StyleVar_WindowPadding, lerp(DC.win_px, DS.win_px), lerp(DC.win_py, DS.win_py))
  PushVar(ImGui.StyleVar_FramePadding,  lerp(DC.frm_px, DS.frm_px), lerp(DC.frm_py, DS.frm_py))
  PushVar(ImGui.StyleVar_ItemSpacing,   lerp(DC.itm_px, DS.itm_px), lerp(DC.itm_py, DS.itm_py))
  PushVar(ImGui.StyleVar_ScrollbarSize, lerp(DC.scroll, DS.scroll))
  PushVar(ImGui.StyleVar_CellPadding,   lerp(DC.cel_px, DS.cel_px), lerp(DC.cel_py, DS.cel_py))
end

local function PopTheme()
  ImGui.PopStyleColor(ctx, S.pushed_colors)
  ImGui.PopStyleVar(ctx, S.pushed_vars)
end

-- ============================================================================
-- UI — TOP BAR (search + sort + refresh)
-- ============================================================================

--- Push a search query into history (newest first, deduplicates, caps at max).
local function PushSearchHistory(query)
  if not S.search_history_enabled then return end
  if not query or query == '' then return end
  -- Remove duplicate if already in history
  for i = #S.search_history, 1, -1 do
    if S.search_history[i] == query then
      table.remove(S.search_history, i)
    end
  end
  -- Insert at front (newest first)
  table.insert(S.search_history, 1, query)
  -- Trim to max
  while #S.search_history > S.search_history_max do
    table.remove(S.search_history)
  end
  -- Reset navigation index
  S.search_history_idx = 0
  S.search_buf_live = ''
end

local function DrawTopBar()
  -- Auto-focus search bar on script open (first frame only)
  if S.auto_focus_search and S.frame_count <= 2 then
    ImGui.SetKeyboardFocusHere(ctx)
  end

  -- Before rendering InputText: reset callback signals and pre-compute both
  -- possible history buffers so the EEL callback can pick the right one.
  -- Direction: Down = older history, Up = newer/live (reversed from typical shell).
  if S.search_history_callback and S.search_history_enabled and #S.search_history > 0 then
    ImGui.Function_SetValue(S.search_history_callback, 'hist_direction', 0)
    -- Save live input before any history navigation from idx 0
    if S.search_history_idx == 0 then
      S.search_buf_live = S.search_buf
    end
    -- Can go older? (Down arrow → deeper into history)
    local can_older = S.search_history_idx < #S.search_history
    ImGui.Function_SetValue(S.search_history_callback, 'can_go_older', can_older and 1 or 0)
    if can_older then
      local older_idx = S.search_history_idx + 1
      ImGui.Function_SetValue_String(S.search_history_callback, '#older_buf', S.search_history[older_idx])
    end
    -- Can go newer? (Up arrow → back toward live input)
    local can_newer = S.search_history_idx > 0
    ImGui.Function_SetValue(S.search_history_callback, 'can_go_newer', can_newer and 1 or 0)
    if can_newer then
      local newer_idx = S.search_history_idx - 1
      local newer_buf = newer_idx == 0 and S.search_buf_live or S.search_history[newer_idx]
      ImGui.Function_SetValue_String(S.search_history_callback, '#newer_buf', newer_buf)
    end
  elseif S.search_history_callback then
    ImGui.Function_SetValue(S.search_history_callback, 'hist_direction', 0)
    ImGui.Function_SetValue(S.search_history_callback, 'can_go_older', 0)
    ImGui.Function_SetValue(S.search_history_callback, 'can_go_newer', 0)
  end

  -- Search box: takes all space minus history button + clear button + sort combo + refresh button
  local history_btn_w = (S.search_history_enabled and #S.search_history > 0) and 22 or 0
  ImGui.SetNextItemWidth(ctx, -255 - history_btn_w)
  local changed
  -- Use CallbackHistory flag when history is available — routes Up/Down to EEL callback
  local use_history_cb = S.search_history_enabled and S.search_history_callback and #S.search_history > 0
  local search_flags = use_history_cb and ImGui.InputTextFlags_CallbackHistory or 0
  local search_cb = use_history_cb and S.search_history_callback or nil
  changed, S.search_buf = ImGui.InputTextWithHint(ctx, '##search', 'Search projects, artists, tags...', S.search_buf, search_flags, search_cb)
  local search_deactivated = ImGui.IsItemDeactivated(ctx)

  -- Auto-save to history when search bar loses focus with non-empty text
  if search_deactivated and S.search_buf ~= '' then
    PushSearchHistory(S.search_buf)
  end

  -- Check if EEL callback signaled a history navigation (Up/Down arrow in search bar).
  -- Must check BEFORE the `changed` handler, because the EEL callback modifying the
  -- buffer also causes `changed` to be true — we need to distinguish typing from navigation.
  local history_navigated = false
  if S.search_history_callback and S.search_history_enabled and #S.search_history > 0 then
    local dir = ImGui.Function_GetValue(S.search_history_callback, 'hist_direction')
    if dir > 0 then
      -- Up arrow fired: EEL already replaced InputText buffer in-place
      S.search_history_idx = S.search_history_idx + 1
      S.search_buf = S.search_history[S.search_history_idx]
      RefreshFiltered()
      history_navigated = true
    elseif dir < 0 then
      -- Down arrow fired: EEL already replaced InputText buffer in-place
      S.search_history_idx = S.search_history_idx - 1
      if S.search_history_idx == 0 then
        S.search_buf = S.search_buf_live
      else
        S.search_buf = S.search_history[S.search_history_idx]
      end
      RefreshFiltered()
      history_navigated = true
    end
  end

  -- Typing resets history navigation and filters live (skip if this was a history nav)
  if changed and not history_navigated then
    S.search_history_idx = 0
    S.search_buf_live = S.search_buf
    RefreshFiltered()
  end

  -- Search history dropdown button (small clock icon)
  if S.search_history_enabled and #S.search_history > 0 then
    ImGui.SameLine(ctx, 0, 2)
    if ImGui.SmallButton(ctx, 'H##search_history') then
      ImGui.OpenPopup(ctx, 'search_history_popup')
    end
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, 'Recent searches\n(use Up/Down arrows when search bar is focused)\nRight-click a search to remove it')
    end
    if ImGui.BeginPopup(ctx, 'search_history_popup') then
      local delete_idx = nil
      for i, entry in ipairs(S.search_history) do
        if ImGui.Selectable(ctx, entry .. '##sh' .. i, false) then
          S.search_buf = entry
          S.search_history_idx = 0
          RefreshFiltered()
        end
        if ImGui.IsItemClicked(ctx, ImGui.MouseButton_Right) then
          delete_idx = i
        end
      end
      -- Remove the marked entry after the loop to avoid mid-iteration mutation
      if delete_idx then
        table.remove(S.search_history, delete_idx)
        -- If we were navigating history and the deleted entry was at or before current idx,
        -- pull the idx back by one to keep it valid. Clamp to 0 (live input) at minimum.
        if S.search_history_idx >= delete_idx then
          S.search_history_idx = math.max(0, S.search_history_idx - 1)
        end
        SaveState()
      end
      ImGui.EndPopup(ctx)
    end
  end

  -- Clear search button (only visible when search has text)
  ImGui.SameLine(ctx, 0, 2)
  if S.search_buf ~= '' then
    if ImGui.SmallButton(ctx, 'x##clear_search') then
      S.search_buf = ''
      S.search_history_idx = 0
      RefreshFiltered()
    end
  else
    -- Invisible placeholder to keep layout stable
    ImGui.Dummy(ctx, 16, 1)
  end

  ImGui.SameLine(ctx)

  -- Sort combo
  ImGui.SetNextItemWidth(ctx, 120)
  if ImGui.BeginCombo(ctx, '##sort', CFG.SORT_LABELS[S.sort_mode]) then
    for i = 1, #CFG.SORT_LABELS do
      if ImGui.Selectable(ctx, CFG.SORT_LABELS[i], S.sort_mode == i) then
        S.sort_mode = i
        -- Persist to the active tab's sort mode
        if S.active_tab == 'all' then
          S.all_sort_mode = i
        else
          S.recent_sort_mode = i
        end
        RefreshFiltered()
        SaveState()
      end
    end
    ImGui.EndCombo(ctx)
  end

  ImGui.SameLine(ctx)

  -- Refresh (left-click = normal, right-click = hard refresh)
  if ImGui.Button(ctx, 'Refresh') then
    ActionRefresh()
  end
  if ImGui.IsItemClicked(ctx, ImGui.MouseButton_Right) then
    ActionHardRefresh()
  end
  if ImGui.IsItemHovered(ctx) then
    ImGui.SetTooltip(ctx, 'F5 = Refresh (cached)\nShift+F5 = Hard refresh (re-scan metadata + all projects)')
  end

end

-- ============================================================================
-- UI — FILTER BAR
-- ============================================================================

local function DrawFilterBar()
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Filter:')
  ImGui.PopStyleColor(ctx, 1)

  ImGui.SameLine(ctx)

  -- String count filter
  ImGui.SetNextItemWidth(ctx, 80)
  if ImGui.BeginCombo(ctx, '##flt_strings', CFG.STRING_FILTER_OPTIONS[S.filter_strings]) then
    for i, label in ipairs(CFG.STRING_FILTER_OPTIONS) do
      if ImGui.Selectable(ctx, label .. '##sf' .. i, S.filter_strings == i) then
        S.filter_strings = i
        RefreshFiltered()
      end
    end
    ImGui.EndCombo(ctx)
  end
  if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, 'Filter by string count') end

  ImGui.SameLine(ctx)

  -- Tuning filter
  ImGui.SetNextItemWidth(ctx, 100)
  if ImGui.BeginCombo(ctx, '##flt_tuning', CFG.TUNING_FILTER_OPTIONS[S.filter_tuning]) then
    for i, label in ipairs(CFG.TUNING_FILTER_OPTIONS) do
      if ImGui.Selectable(ctx, label .. '##tf' .. i, S.filter_tuning == i) then
        S.filter_tuning = i
        RefreshFiltered()
      end
    end
    ImGui.EndCombo(ctx)
  end
  if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, 'Filter by tuning') end

  ImGui.SameLine(ctx)

  -- Status filter
  ImGui.SetNextItemWidth(ctx, 120)
  if ImGui.BeginCombo(ctx, '##flt_status', CFG.STATUS_FILTER_OPTIONS[S.filter_status]) then
    for i, label in ipairs(CFG.STATUS_FILTER_OPTIONS) do
      if ImGui.Selectable(ctx, label .. '##stf' .. i, S.filter_status == i) then
        S.filter_status = i
        RefreshFiltered()
      end
    end
    ImGui.EndCombo(ctx)
  end
  if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, 'Filter by status') end

  ImGui.SameLine(ctx)

  -- Genre filter
  local genre_label = CFG.GENRE_FILTER_OPTIONS[S.filter_genre] or 'All'
  ImGui.SetNextItemWidth(ctx, 100)
  if ImGui.BeginCombo(ctx, '##flt_genre', genre_label) then
    for i, label in ipairs(CFG.GENRE_FILTER_OPTIONS) do
      if ImGui.Selectable(ctx, label .. '##gf' .. i, S.filter_genre == i) then
        S.filter_genre = i
        RefreshFiltered()
      end
    end
    ImGui.EndCombo(ctx)
  end
  if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, 'Filter by primary genre') end

  ImGui.SameLine(ctx)

  -- Tri-state coverage quick buttons (◻ neutral, ✓ require, ✗ exclude)
  local tri_icons = { [0] = '\u{25FB}', [1] = '\u{2713}', [2] = '\u{2717}' }
  local tri_colors = { [0] = C.textDim, [1] = 0x4DB870FF, [2] = 0xB84D4DFF }
  local tri_tooltips = { [0] = 'Neutral (no filter)', [1] = 'Require (must have)', [2] = 'Exclude (must not have)' }

  local function DrawTriButton(label, state_key)
    local st = S[state_key]
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, tri_colors[st])
    if ImGui.SmallButton(ctx, tri_icons[st] .. ' ' .. label .. '##tri_' .. state_key) then
      S[state_key] = (st + 1) % 3
      RefreshFiltered()
    end
    ImGui.PopStyleColor(ctx, 1)
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, label .. ': ' .. tri_tooltips[st] .. '\nClick to cycle')
    end
  end

  DrawTriButton('Meta', 'filter_tri_meta')
  ImGui.SameLine(ctx, 0, 4)
  DrawTriButton('Art', 'filter_tri_art')
  ImGui.SameLine(ctx, 0, 4)
  DrawTriButton('Tags', 'filter_tri_tags')

  -- All-Projects-only tri-state buttons: Dedupe, Hidden, Excluded (grouped with Meta/Art/Tags)
  if S.active_tab == 'all' then
    ImGui.SameLine(ctx, 0, 4)
    -- Dedupe tri-state: 0=ON (green ✓), 1=OFF (dim ◻), 2=only variants (red ✗)
    local dedupe_icons = { [0] = '\u{2713}', [1] = '\u{25FB}', [2] = '\u{2717}' }
    local dedupe_tips = { [0] = 'Dedupe ON — hiding variant projects', [1] = 'Dedupe OFF — showing all projects', [2] = 'Showing ONLY deduped variants (audit mode)' }
    -- Reuse shared tri_colors for consistent look (0=dim, but dedupe maps: 0→✓green, 1→◻dim, 2→✗red)
    local dedupe_clr = { [0] = tri_colors[1], [1] = tri_colors[0], [2] = tri_colors[2] }
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, dedupe_clr[S.show_dedupe])
    if ImGui.SmallButton(ctx, dedupe_icons[S.show_dedupe] .. ' Dedupe##dedupe_tri') then
      S.show_dedupe = (S.show_dedupe + 1) % 3
      RefreshFiltered()
      SaveState()
    end
    ImGui.PopStyleColor(ctx, 1)
    if ImGui.IsItemHovered(ctx) then
      local mode_label = S.dedupe_mode == 'aggressive' and 'Aggressive' or 'Standard'
      ImGui.SetTooltip(ctx, dedupe_tips[S.show_dedupe] .. '\nMode: ' .. mode_label .. '\n\nClick to cycle: Hide variants → Show all → Show only variants')
    end

    -- Hidden tri-state (only when hidden projects exist)
    local vis_icons = { [0] = '\u{25FB}', [1] = '\u{2713}', [2] = '\u{2717}' }
    local vis_tooltips = { [0] = 'Hide (default)', [1] = 'Show All', [2] = 'Show Only' }

    if next(S.hidden_projects) then
      local hidden_count = 0
      for _ in pairs(S.hidden_projects) do hidden_count = hidden_count + 1 end
      ImGui.SameLine(ctx, 0, 4)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, tri_colors[S.show_hidden])
      if ImGui.SmallButton(ctx, vis_icons[S.show_hidden] .. ' Hidden##tri_hidden') then
        S.show_hidden = (S.show_hidden + 1) % 3
        RefreshFiltered()
        SaveState()
      end
      ImGui.PopStyleColor(ctx, 1)
      if ImGui.IsItemHovered(ctx) then
        ImGui.SetTooltip(ctx, 'Hidden (' .. hidden_count .. '): ' .. vis_tooltips[S.show_hidden] .. '\nClick to cycle')
      end
    end

    -- Excluded tri-state (only when exclusion patterns exist)
    if S.exclusion_patterns ~= '' then
      ImGui.SameLine(ctx, 0, 4)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, tri_colors[S.show_excluded])
      if ImGui.SmallButton(ctx, vis_icons[S.show_excluded] .. ' Excluded##tri_excluded') then
        S.show_excluded = (S.show_excluded + 1) % 3
        RefreshFiltered()
        SaveState()
      end
      ImGui.PopStyleColor(ctx, 1)
      if ImGui.IsItemHovered(ctx) then
        ImGui.SetTooltip(ctx, 'Excluded (' .. #S.excluded_projects .. '): ' .. vis_tooltips[S.show_excluded] .. '\nClick to cycle')
      end
    end
  end

  ImGui.SameLine(ctx)

  -- Favorites toggle (both tabs)
  local chg
  chg, S.filter_favs = ImGui.Checkbox(ctx, 'Favs', S.filter_favs)
  if chg then RefreshFiltered() end

  -- "Include All Projects" toggle (Recent tab only)
  if S.active_tab == 'recent' then
    ImGui.SameLine(ctx)
    local ia_chg, ia_new = ImGui.Checkbox(ctx, 'Include All', S.filter_include_all)
    if ia_chg then
      S.filter_include_all = ia_new
      -- Trigger lazy-load of all-projects if not yet loaded
      if ia_new and not S.all_projects_loaded then
        local cached_all = LoadAllProjectsScan()
        if cached_all then
          S.all_projects = cached_all
          S.all_projects_loaded = true
          if S.cache_loaded then
            ApplyCachedMetadata(S.all_projects)
          else
            EnrichProjects(S.all_projects)
            local combined = {}
            for _, p in ipairs(S.all_projects) do combined[#combined + 1] = p end
            for _, p in ipairs(S.recent_projects) do combined[#combined + 1] = p end
            SaveMetadataCache(combined)
          end
        else
          S.all_projects = ScanAllProjectFiles()
          S.all_projects_loaded = true
          SaveAllProjectsScan(S.all_projects)
          EnrichProjects(S.all_projects)
          local combined = {}
          for _, p in ipairs(S.all_projects) do combined[#combined + 1] = p end
          for _, p in ipairs(S.recent_projects) do combined[#combined + 1] = p end
          SaveMetadataCache(combined)
        end
      end
      RefreshFiltered()
      BuildImageQueue()
      SaveState()
    end
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, 'Append all remaining projects after recents,\nsorted by the current sort mode')
    end
  end

  -- "Excl. Recents" checkbox (All Projects tab only, after Favs)
  if S.active_tab == 'all' then
    ImGui.SameLine(ctx)
    local er_chg, er_new = ImGui.Checkbox(ctx, 'Excl. Recents', S.filter_exclude_recents)
    if er_chg then S.filter_exclude_recents = er_new; RefreshFiltered() end
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, 'Hide projects that are already in the Recent tab')
    end
  end

  -- Export button (right-aligned)
  local flt_region = ImGui.GetContentRegionAvail(ctx)
  local flt_cx     = ImGui.GetCursorPosX(ctx)
  local exp_offset = flt_cx + flt_region - 70
  if exp_offset > flt_cx + 20 then
    ImGui.SameLine(ctx, exp_offset)
  else
    ImGui.SameLine(ctx)
  end
  if ImGui.SmallButton(ctx, 'Export...') then
    ImGui.OpenPopup(ctx, '##export_menu')
  end
  if ImGui.IsItemHovered(ctx) then
    ImGui.SetTooltip(ctx, 'Export visible project list')
  end
  if ImGui.BeginPopup(ctx, '##export_menu') then
    local proj_list = S.filtered_projects
    local count_label = #proj_list .. ' projects'
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
    ImGui.Text(ctx, count_label)
    ImGui.PopStyleColor(ctx, 1)
    ImGui.Separator(ctx)
    if ImGui.Selectable(ctx, 'Export as CSV', false) then
      ActionExportList(proj_list, 'csv')
    end
    if ImGui.Selectable(ctx, 'Export as Markdown', false) then
      ActionExportList(proj_list, 'markdown')
    end
    if ImGui.Selectable(ctx, 'Export as JSON', false) then
      ActionExportList(proj_list, 'json')
    end
    ImGui.EndPopup(ctx)
  end

end

--- Serialize tag_edit fields into a string for dirty detection.
local function SerializeTagEdit()
  return table.concat({
    tag_edit.strings, tag_edit.tuning, tag_edit.transpose, tag_edit.status,
    tag_edit.difficulty, tag_edit.guitar, tag_edit.amp, tag_edit.genre,
    tag_edit.genre_primary or '', tag_edit.genre_secondary or '',
    tag_edit.notes, tostring(tag_edit.favorite), tag_edit.bpmOverride,
    tag_edit.keyOverride, tag_edit.albumOverride, tag_edit.artistOverride,
    tag_edit.titleOverride, tag_edit.durationOverride, tag_edit.timeSigOverride,
    tag_edit.artOverride,
  }, '|')
end

-- ============================================================================
-- UI — CONTEXT MENU (right-click)
-- ============================================================================

local function DrawContextMenu(proj, idx)
  if ImGui.BeginPopupContextItem(ctx, 'ctx##' .. idx) then
    local sel_count = SelectionCount()
    local is_bulk = sel_count > 1

    if is_bulk then
      -- Bulk actions header
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.accent)
      ImGui.Text(ctx, sel_count .. ' projects selected')
      ImGui.PopStyleColor(ctx, 1)
      ImGui.Separator(ctx)

      -- Bulk favorite toggle
      if ImGui.Selectable(ctx, 'Add to Favorites', false) then
        for _, p in ipairs(GetSelectedProjects()) do
          if not (p.tags or {}).favorite then ActionToggleFavorite(p) end
        end
      end
      if ImGui.Selectable(ctx, 'Remove from Favorites', false) then
        S.confirm_unfav_bulk = GetSelectedProjects()
      end

      -- Bulk tag assignment
      ImGui.Separator(ctx)
      if ImGui.BeginMenu(ctx, 'Set Status') then
        for _, s in ipairs(CFG.STATUS_PRESETS) do
          if ImGui.Selectable(ctx, s .. '##bst', false) then
            for _, p in ipairs(GetSelectedProjects()) do
              SetTag(p.path, 'status', s)
              p.tags = GetTags(p.path)
            end
            SaveTags()
          end
        end
        ImGui.Separator(ctx)
        if ImGui.Selectable(ctx, 'Clear##bst_clr', false) then
          S.confirm_bulk_clear_tag = { field = 'status', projects = GetSelectedProjects() }
        end
        ImGui.EndMenu(ctx)
      end
      if ImGui.BeginMenu(ctx, 'Set Strings') then
        for _, n in ipairs({6, 7, 8}) do
          if ImGui.Selectable(ctx, n .. '-string##bstr', false) then
            for _, p in ipairs(GetSelectedProjects()) do
              SetTag(p.path, 'strings', n)
              p.tags = GetTags(p.path)
            end
            SaveTags()
          end
        end
        ImGui.Separator(ctx)
        if ImGui.Selectable(ctx, 'Clear##bstr_clr', false) then
          S.confirm_bulk_clear_tag = { field = 'strings', projects = GetSelectedProjects() }
        end
        ImGui.EndMenu(ctx)
      end
      if ImGui.BeginMenu(ctx, 'Set Tuning') then
        for _, t in ipairs(CFG.TUNING_PRESETS) do
          if ImGui.Selectable(ctx, t .. '##btn', false) then
            for _, p in ipairs(GetSelectedProjects()) do
              SetTag(p.path, 'tuning', t)
              p.tags = GetTags(p.path)
            end
            SaveTags()
          end
        end
        ImGui.Separator(ctx)
        if ImGui.Selectable(ctx, 'Clear##btn_clr', false) then
          S.confirm_bulk_clear_tag = { field = 'tuning', projects = GetSelectedProjects() }
        end
        ImGui.EndMenu(ctx)
      end
      if ImGui.BeginMenu(ctx, 'Set Transpose') then
        for _, t in ipairs(CFG.TRANSPOSE_PRESETS) do
          if ImGui.Selectable(ctx, t .. '##btp', false) then
            for _, p in ipairs(GetSelectedProjects()) do
              SetTag(p.path, 'transpose', t)
              p.tags = GetTags(p.path)
            end
            SaveTags()
          end
        end
        ImGui.Separator(ctx)
        if ImGui.Selectable(ctx, 'Clear##btp_clr', false) then
          S.confirm_bulk_clear_tag = { field = 'transpose', projects = GetSelectedProjects() }
        end
        ImGui.EndMenu(ctx)
      end
      if ImGui.BeginMenu(ctx, 'Set Genre') then
        for _, g in ipairs(CFG.PRIMARY_GENRES) do
          if ImGui.Selectable(ctx, g .. '##bgn', false) then
            for _, p in ipairs(GetSelectedProjects()) do
              local t = GetTags(p.path)
              -- Set as primary genre (index 1), preserve secondary genres
              local existing = t.genre
              local secondary = {}
              if type(existing) == 'table' then
                for j = 2, #existing do secondary[#secondary + 1] = existing[j] end
              elseif type(existing) == 'string' and existing ~= '' then
                -- Legacy comma-separated string: extract secondary parts
                local first = true
                for part in existing:gmatch('[^,]+') do
                  if first then first = false
                  else
                    local trimmed = part:match('^%s*(.-)%s*$')
                    if trimmed ~= '' then secondary[#secondary + 1] = trimmed end
                  end
                end
              end
              local new_genre = { g }
              for _, s in ipairs(secondary) do new_genre[#new_genre + 1] = s end
              SetTag(p.path, 'genre', #new_genre == 1 and g or new_genre)
              p.tags = GetTags(p.path)
              if p.search_haystack then p.search_haystack = nil end
            end
            SaveTags()
          end
        end
        ImGui.Separator(ctx)
        if ImGui.Selectable(ctx, 'Clear##bgn_clr', false) then
          S.confirm_bulk_clear_tag = { field = 'genre', projects = GetSelectedProjects() }
        end
        ImGui.EndMenu(ctx)
      end

      -- Bulk tag editor
      ImGui.Separator(ctx)
      if ImGui.Selectable(ctx, 'Bulk Edit Tags...', false) then
        S.bulk_tag_edit_projects = GetSelectedProjects()
        ResetBulkEdit()
        S.bulk_tag_edit_pending = true
      end

      -- Bulk copy
      ImGui.Separator(ctx)
      if ImGui.Selectable(ctx, 'Copy Names', false) then ActionCopyBulk('names') end
      if ImGui.Selectable(ctx, 'Copy Paths', false) then ActionCopyBulk('paths') end
      if ImGui.Selectable(ctx, 'Copy as Markdown', false) then ActionCopyBulk('markdown') end

      -- Bulk hide (confirmation gated)
      ImGui.Separator(ctx)
      if ImGui.Selectable(ctx, 'Hide Selected', false) then
        S.confirm_hide_bulk = GetSelectedProjects()
      end

      -- Bulk remove from recent (confirmation gated)
      if S.active_tab == 'recent' then
        ImGui.Separator(ctx)
        if ImGui.Selectable(ctx, 'Remove Selected from Recent', false) then
          S.confirm_remove_bulk = GetSelectedProjects()
        end
      end
    else
      -- Single-item context menu (original)
      if proj.exists then
        if ImGui.Selectable(ctx, 'Open Project', false) then ActionOpenProject(proj) end
        if ImGui.Selectable(ctx, 'Load in Tab',  false) then ActionLoadInTab(proj) end
        ImGui.Separator(ctx)
        local locate_label = (reaper.GetOS():match('OSX') or reaper.GetOS():match('macOS')) and 'Reveal in Finder' or 'Locate in Explorer'
        if ImGui.Selectable(ctx, locate_label, false) then ActionLocateInExplorer(proj) end
      end

      ImGui.Separator(ctx)

      -- Favorites toggle
      local tags = proj.tags or {}
      if not tags.favorite then
        if ImGui.Selectable(ctx, 'Add to Favorites', false) then
          ActionToggleFavorite(proj)
        end
      else
        if ImGui.Selectable(ctx, 'Remove from Favorites', false) then
          S.confirm_unfav_proj = proj
        end
      end

      -- Edit Tags
      if ImGui.Selectable(ctx, 'Edit Tags...', false) then
        S.tag_edit_proj = proj
        local t = proj.tags or {}
        tag_edit.strings    = t.strings and tostring(t.strings) or ''
        tag_edit.tuning     = t.tuning or ''
        tag_edit.transpose  = t.transpose or ''
        tag_edit.status     = t.status or ''
        tag_edit.difficulty  = t.difficulty or ''
        tag_edit.guitar     = t.guitar or ''
        tag_edit.amp        = t.amp or ''
        -- Split genre into primary (first item) and secondary (rest, comma-separated)
        if type(t.genre) == 'table' then
          tag_edit.genre_primary = t.genre[1] or ''
          local sec = {}
          for j = 2, #t.genre do sec[#sec + 1] = t.genre[j] end
          tag_edit.genre_secondary = table.concat(sec, ', ')
        elseif type(t.genre) == 'string' and t.genre ~= '' then
          local first = t.genre:match('^([^,]+)')
          tag_edit.genre_primary = first and first:match('^%s*(.-)%s*$') or t.genre
          local rest = t.genre:match(',(.+)$')
          tag_edit.genre_secondary = rest and rest:match('^%s*(.-)%s*$') or ''
        else
          tag_edit.genre_primary = ''
          tag_edit.genre_secondary = ''
        end
        tag_edit.genre      = GenreStr(t.genre)
        tag_edit.notes      = t.notes or ''
        tag_edit.favorite   = t.favorite or false
        tag_edit.bpmOverride = t.bpmOverride and tostring(t.bpmOverride) or ''
        tag_edit.keyOverride = t.keyOverride or ''
        tag_edit.albumOverride    = t.albumOverride or ''
        tag_edit.artistOverride   = t.artistOverride or ''
        tag_edit.titleOverride    = t.titleOverride or ''
        tag_edit.durationOverride = t.durationOverride and tostring(t.durationOverride) or ''
        tag_edit.timeSigOverride  = t.timeSigOverride or ''
        tag_edit.artOverride      = t.artOverride or ''
        S.tag_edit_snapshot = SerializeTagEdit()
        S.tag_edit_pending = true
      end

      -- Quick tag assignment submenus (single project)
      if ImGui.BeginMenu(ctx, 'Set Status##single') then
        local cur_status = tags.status or ''
        for _, s in ipairs(CFG.STATUS_PRESETS) do
          local is_current = (cur_status == s)
          if ImGui.Selectable(ctx, (is_current and '> ' or '') .. s .. '##sst', is_current) then
            SetTag(proj.path, 'status', s)
            proj.tags = GetTags(proj.path)
            SaveTags()
          end
        end
        if cur_status ~= '' then
          ImGui.Separator(ctx)
          if ImGui.Selectable(ctx, 'Clear##sst_clr', false) then
            SetTag(proj.path, 'status', nil)
            proj.tags = GetTags(proj.path)
            SaveTags()
          end
        end
        ImGui.EndMenu(ctx)
      end
      if ImGui.BeginMenu(ctx, 'Set Strings##single') then
        local cur_n = tonumber(tags.strings)
        for _, n in ipairs({6, 7, 8}) do
          local is_current = (cur_n == n)
          if ImGui.Selectable(ctx, (is_current and '> ' or '') .. n .. '-string##sstr', is_current) then
            SetTag(proj.path, 'strings', n)
            proj.tags = GetTags(proj.path)
            SaveTags()
          end
        end
        if cur_n then
          ImGui.Separator(ctx)
          if ImGui.Selectable(ctx, 'Clear##sstr_clr', false) then
            SetTag(proj.path, 'strings', nil)
            proj.tags = GetTags(proj.path)
            SaveTags()
          end
        end
        ImGui.EndMenu(ctx)
      end
      if ImGui.BeginMenu(ctx, 'Set Tuning##single') then
        local cur_tuning = tags.tuning or ''
        for _, t in ipairs(CFG.TUNING_PRESETS) do
          local is_current = (cur_tuning == t)
          if ImGui.Selectable(ctx, (is_current and '> ' or '') .. t .. '##stn', is_current) then
            SetTag(proj.path, 'tuning', t)
            proj.tags = GetTags(proj.path)
            SaveTags()
          end
        end
        if cur_tuning ~= '' then
          ImGui.Separator(ctx)
          if ImGui.Selectable(ctx, 'Clear##stn_clr', false) then
            SetTag(proj.path, 'tuning', nil)
            proj.tags = GetTags(proj.path)
            SaveTags()
          end
        end
        ImGui.EndMenu(ctx)
      end
      if ImGui.BeginMenu(ctx, 'Set Transpose##single') then
        local cur_tp = tags.transpose or ''
        for _, t in ipairs(CFG.TRANSPOSE_PRESETS) do
          local is_current = (cur_tp == t)
          if ImGui.Selectable(ctx, (is_current and '> ' or '') .. t .. '##stp', is_current) then
            SetTag(proj.path, 'transpose', t)
            proj.tags = GetTags(proj.path)
            SaveTags()
          end
        end
        if cur_tp ~= '' then
          ImGui.Separator(ctx)
          if ImGui.Selectable(ctx, 'Clear##stp_clr', false) then
            SetTag(proj.path, 'transpose', nil)
            proj.tags = GetTags(proj.path)
            SaveTags()
          end
        end
        ImGui.EndMenu(ctx)
      end
      if ImGui.BeginMenu(ctx, 'Set Genre##single') then
        local cur_genre = GetPrimaryGenre(tags) or ''
        for _, g in ipairs(CFG.PRIMARY_GENRES) do
          local is_current = (cur_genre == g)
          if ImGui.Selectable(ctx, (is_current and '> ' or '') .. g .. '##sgn', is_current) then
            -- Set as primary genre, preserve secondary genres
            local existing = tags.genre
            local secondary = {}
            if type(existing) == 'table' then
              for j = 2, #existing do secondary[#secondary + 1] = existing[j] end
            elseif type(existing) == 'string' and existing ~= '' then
              local first = true
              for part in existing:gmatch('[^,]+') do
                if first then first = false
                else
                  local trimmed = part:match('^%s*(.-)%s*$')
                  if trimmed ~= '' then secondary[#secondary + 1] = trimmed end
                end
              end
            end
            local new_genre = { g }
            for _, s in ipairs(secondary) do new_genre[#new_genre + 1] = s end
            SetTag(proj.path, 'genre', #new_genre == 1 and g or new_genre)
            proj.tags = GetTags(proj.path)
            if proj.search_haystack then proj.search_haystack = nil end
            SaveTags()
          end
        end
        if cur_genre ~= '' then
          ImGui.Separator(ctx)
          if ImGui.Selectable(ctx, 'Clear##sgn_clr', false) then
            SetTag(proj.path, 'genre', nil)
            proj.tags = GetTags(proj.path)
            if proj.search_haystack then proj.search_haystack = nil end
            SaveTags()
          end
        end
        ImGui.EndMenu(ctx)
      end

      ImGui.Separator(ctx)
      if ImGui.Selectable(ctx, 'Copy Name', false) then ActionCopyName(proj) end
      if ImGui.Selectable(ctx, 'Copy Path', false) then ActionCopyPath(proj) end
      if ImGui.Selectable(ctx, 'Copy as Markdown', false) then ActionCopyBulk('markdown') end

      -- Remove from Recent
      if S.active_tab == 'recent' or proj.isRecent then
        ImGui.Separator(ctx)
        if ImGui.Selectable(ctx, 'Remove from Recent', false) then
          S.confirm_remove_proj = proj
        end
      end

      -- Remove Invalid Entries
      if S.active_tab == 'recent' then
        if ImGui.Selectable(ctx, 'Remove Invalid Entries', false) then
          S.invalid_count = CountInvalidRecentEntries()
          S.confirm_remove_invalid = true
        end
      end

      -- Hide/Unhide
      ImGui.Separator(ctx)
      if IsHidden(proj) then
        if ImGui.Selectable(ctx, 'Unhide Project', false) then
          S.hidden_projects[proj.path] = nil
          local alt = GetAlternatePath(proj.path)
          if alt then S.hidden_projects[alt] = nil end
          SaveHidden()
          SaveState()
          RefreshFiltered()
        end
      else
        if ImGui.Selectable(ctx, 'Hide Project', false) then
          S.confirm_hide_proj = proj
        end
      end

      -- Whitelist / Remove from Whitelist
      if IsWhitelisted(proj) then
        if ImGui.Selectable(ctx, 'Remove from Whitelist', false) then
          S.whitelist[proj.path] = nil
          local alt = GetAlternatePath(proj.path)
          if alt then S.whitelist[alt] = nil end
          SaveWhitelist()
          RefreshFiltered()
        end
      else
        if ImGui.Selectable(ctx, 'Whitelist Project', false) then
          S.whitelist[proj.path] = true
          SaveWhitelist()
          RefreshFiltered()
        end
        if ImGui.IsItemHovered(ctx) then
          ImGui.SetTooltip(ctx, 'Whitelisted projects always show,\nregardless of hidden/exclusion/dedupe filters')
        end
      end
    end

    ImGui.EndPopup(ctx)
  end
end

-- ============================================================================
-- UI — TAG EDITOR (modal popup)
-- ============================================================================

local function DrawTagEditor()
  ImGui.SetNextWindowSize(ctx, S.tag_editor_w, S.tag_editor_h, ImGui.Cond_Appearing)
  -- Resizable modal (no NoResize flag)
  local flags = 0

  local visible, open = ImGui.BeginPopupModal(ctx, 'Edit Tags##modal', true, flags)
  if not visible then return end

  if not S.tag_edit_proj then
    ImGui.EndPopup(ctx)
    return
  end

  -- Persist window size when user resizes
  local cur_w, cur_h = ImGui.GetWindowSize(ctx)
  if cur_w ~= S.tag_editor_w or cur_h ~= S.tag_editor_h then
    S.tag_editor_w = cur_w
    S.tag_editor_h = cur_h
    SaveState()
  end

  -- Title (project name in accent color)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.accent)
  ImGui.Text(ctx, S.tag_edit_proj.name)
  ImGui.PopStyleColor(ctx, 1)

  -- Album display
  if S.tag_edit_proj.album then
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
    ImGui.Text(ctx, 'Album: ' .. S.tag_edit_proj.album)
    ImGui.PopStyleColor(ctx, 1)
  end

  -- Favorite checkbox (near top for easy access)
  _, tag_edit.favorite = ImGui.Checkbox(ctx, 'Favorite', tag_edit.favorite)

  ImGui.Separator(ctx)
  ImGui.Spacing(ctx)

  local lbl_w = 110

  -- Calculate space: reserve 130px at bottom for Notes + Save/Cancel
  local _, te_avail_y = ImGui.GetContentRegionAvail(ctx)
  local bottom_reserve = 130  -- Notes label + notes box + spacing + buttons
  local fields_h = math.max(100, te_avail_y - bottom_reserve)

  if ImGui.BeginChild(ctx, 'tag_fields_scroll', -1, fields_h) then

  -- String count (radio buttons)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Strings:')
  ImGui.SameLine(ctx, lbl_w)
  local s6 = (tag_edit.strings == '6')
  local s7 = (tag_edit.strings == '7')
  local s8 = (tag_edit.strings == '8')
  if ImGui.RadioButton(ctx, '6##str', s6) then tag_edit.strings = '6' end
  ImGui.SameLine(ctx)
  if ImGui.RadioButton(ctx, '7##str', s7) then tag_edit.strings = '7' end
  ImGui.SameLine(ctx)
  if ImGui.RadioButton(ctx, '8##str', s8) then tag_edit.strings = '8' end
  ImGui.SameLine(ctx)
  if ImGui.RadioButton(ctx, 'N/A##str', not s6 and not s7 and not s8) then tag_edit.strings = '' end

  -- Status
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Status:')
  ImGui.SameLine(ctx, lbl_w)
  ImGui.SetNextItemWidth(ctx, -1)
  local status_label = tag_edit.status ~= '' and tag_edit.status or '(none)'
  if ImGui.BeginCombo(ctx, '##ed_status', status_label) then
    if ImGui.Selectable(ctx, '(none)##st', tag_edit.status == '') then tag_edit.status = '' end
    for _, s in ipairs(CFG.STATUS_PRESETS) do
      if ImGui.Selectable(ctx, s .. '##st', tag_edit.status == s) then tag_edit.status = s end
    end
    ImGui.EndCombo(ctx)
  end

  -- Tuning
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Tuning:')
  ImGui.SameLine(ctx, lbl_w)
  ImGui.SetNextItemWidth(ctx, -1)
  local tuning_label = tag_edit.tuning ~= '' and tag_edit.tuning or '(none)'
  if ImGui.BeginCombo(ctx, '##ed_tuning', tuning_label) then
    if ImGui.Selectable(ctx, '(none)##tn', tag_edit.tuning == '') then tag_edit.tuning = '' end
    for _, t in ipairs(CFG.TUNING_PRESETS) do
      if ImGui.Selectable(ctx, t .. '##tn', tag_edit.tuning == t) then tag_edit.tuning = t end
    end
    ImGui.EndCombo(ctx)
  end

  -- Transpose
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Transpose:')
  ImGui.SameLine(ctx, lbl_w)
  ImGui.SetNextItemWidth(ctx, -1)
  local tp_label = tag_edit.transpose ~= '' and tag_edit.transpose or '(none)'
  if ImGui.BeginCombo(ctx, '##ed_transpose', tp_label) then
    if ImGui.Selectable(ctx, '(none)##tp', tag_edit.transpose == '') then tag_edit.transpose = '' end
    for _, t in ipairs(CFG.TRANSPOSE_PRESETS) do
      if ImGui.Selectable(ctx, t .. '##tp', tag_edit.transpose == t) then tag_edit.transpose = t end
    end
    ImGui.EndCombo(ctx)
  end

  -- Guitar (combo with presets + free text)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Guitar:')
  ImGui.SameLine(ctx, lbl_w)
  ImGui.SetNextItemWidth(ctx, -1)
  local guitar_label = tag_edit.guitar ~= '' and tag_edit.guitar or '(none)'
  if ImGui.BeginCombo(ctx, '##ed_guitar', guitar_label) then
    if ImGui.Selectable(ctx, '(none)##gt', tag_edit.guitar == '') then tag_edit.guitar = '' end
    for _, g in ipairs(CFG.GUITAR_PRESETS) do
      if g == 'Custom' then
        ImGui.Separator(ctx)
        if ImGui.Selectable(ctx, 'Custom...##gt', false) then tag_edit.guitar = 'Custom' end
      else
        if ImGui.Selectable(ctx, g .. '##gt', tag_edit.guitar == g) then tag_edit.guitar = g end
      end
    end
    ImGui.EndCombo(ctx)
  end
  -- Show text input below if Custom is selected (or value doesn't match any preset)
  local is_guitar_preset = false
  for _, g in ipairs(CFG.GUITAR_PRESETS) do
    if g ~= 'Custom' and tag_edit.guitar == g then is_guitar_preset = true; break end
  end
  if tag_edit.guitar ~= '' and not is_guitar_preset then
    ImGui.Text(ctx, '')  -- spacer for label column
    ImGui.SameLine(ctx, lbl_w)
    ImGui.SetNextItemWidth(ctx, -1)
    _, tag_edit.guitar = ImGui.InputText(ctx, '##ed_guitar_custom', tag_edit.guitar)
  end

  -- Amp/Plugin (text)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Amp/Plugin:')
  ImGui.SameLine(ctx, lbl_w)
  ImGui.SetNextItemWidth(ctx, -1)
  _, tag_edit.amp = ImGui.InputText(ctx, '##ed_amp', tag_edit.amp)

  -- Genre (primary dropdown + secondary freeform)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Genre:')
  ImGui.SameLine(ctx, lbl_w)
  ImGui.SetNextItemWidth(ctx, -1)
  local genre_label = tag_edit.genre_primary ~= '' and tag_edit.genre_primary or '(none)'
  if ImGui.BeginCombo(ctx, '##ed_genre_primary', genre_label) then
    if ImGui.Selectable(ctx, '(none)##gp', tag_edit.genre_primary == '') then tag_edit.genre_primary = '' end
    for _, g in ipairs(CFG.PRIMARY_GENRES) do
      if ImGui.Selectable(ctx, g .. '##gp', tag_edit.genre_primary == g) then tag_edit.genre_primary = g end
    end
    ImGui.EndCombo(ctx)
  end
  if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, 'Primary genre') end
  -- Secondary genres (freeform, comma-separated)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Sub-Genre:')
  ImGui.SameLine(ctx, lbl_w)
  ImGui.SetNextItemWidth(ctx, -1)
  _, tag_edit.genre_secondary = ImGui.InputText(ctx, '##ed_genre_secondary', tag_edit.genre_secondary)
  if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, 'Additional genres, comma-separated (optional)') end

  -- Difficulty
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Difficulty:')
  ImGui.SameLine(ctx, lbl_w)
  ImGui.SetNextItemWidth(ctx, -1)
  local diff_label = tag_edit.difficulty ~= '' and tag_edit.difficulty or '(none)'
  if ImGui.BeginCombo(ctx, '##ed_diff', diff_label) then
    if ImGui.Selectable(ctx, '(none)##df', tag_edit.difficulty == '') then tag_edit.difficulty = '' end
    for _, d in ipairs(CFG.DIFFICULTY_PRESETS) do
      if ImGui.Selectable(ctx, d .. '##df', tag_edit.difficulty == d) then tag_edit.difficulty = d end
    end
    ImGui.EndCombo(ctx)
  end

  ImGui.Spacing(ctx)
  ImGui.Separator(ctx)
  ImGui.Spacing(ctx)

  -- Metadata overrides section
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
  ImGui.Text(ctx, 'Metadata Overrides')
  ImGui.PopStyleColor(ctx, 1)
  ImGui.Spacing(ctx)

  -- BPM Override
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'BPM:')
  ImGui.SameLine(ctx, lbl_w)
  ImGui.SetNextItemWidth(ctx, -1)
  _, tag_edit.bpmOverride = ImGui.InputText(ctx, '##ed_bpm', tag_edit.bpmOverride)
  if ImGui.IsItemHovered(ctx) then
    local hint = 'Override auto-detected BPM'
    if S.tag_edit_proj.songBPM then
      hint = hint .. ' (Spotify: ' .. math.floor(S.tag_edit_proj.songBPM + 0.5) .. ')'
    end
    if S.tag_edit_proj.projectBPM then
      hint = hint .. ' (RPP: ' .. math.floor(S.tag_edit_proj.projectBPM + 0.5) .. ')'
    end
    ImGui.SetTooltip(ctx, hint)
  end

  -- Key Override
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Key:')
  ImGui.SameLine(ctx, lbl_w)
  ImGui.SetNextItemWidth(ctx, -1)
  _, tag_edit.keyOverride = ImGui.InputText(ctx, '##ed_key', tag_edit.keyOverride)
  if ImGui.IsItemHovered(ctx) and S.tag_edit_proj.songKey then
    ImGui.SetTooltip(ctx, 'Override Spotify key: ' .. S.tag_edit_proj.songKey)
  end

  -- Album Override
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Album:')
  ImGui.SameLine(ctx, lbl_w)
  ImGui.SetNextItemWidth(ctx, -1)
  _, tag_edit.albumOverride = ImGui.InputText(ctx, '##ed_album_ovr', tag_edit.albumOverride)
  if ImGui.IsItemHovered(ctx) and S.tag_edit_proj.album then
    ImGui.SetTooltip(ctx, 'Override auto-detected: ' .. S.tag_edit_proj.album)
  end

  -- Artist Override
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Artist:')
  ImGui.SameLine(ctx, lbl_w)
  ImGui.SetNextItemWidth(ctx, -1)
  _, tag_edit.artistOverride = ImGui.InputText(ctx, '##ed_artist_ovr', tag_edit.artistOverride)
  if ImGui.IsItemHovered(ctx) and S.tag_edit_proj.matchedArtist then
    ImGui.SetTooltip(ctx, 'Override auto-detected: ' .. S.tag_edit_proj.matchedArtist)
  end

  -- Title Override
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Title:')
  ImGui.SameLine(ctx, lbl_w)
  ImGui.SetNextItemWidth(ctx, -1)
  _, tag_edit.titleOverride = ImGui.InputText(ctx, '##ed_title_ovr', tag_edit.titleOverride)
  if ImGui.IsItemHovered(ctx) and (S.tag_edit_proj.matchedTitle or S.tag_edit_proj.song) then
    ImGui.SetTooltip(ctx, 'Override auto-detected: ' .. (S.tag_edit_proj.matchedTitle or S.tag_edit_proj.song or ''))
  end

  -- Duration Override
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Duration (s):')
  ImGui.SameLine(ctx, lbl_w)
  ImGui.SetNextItemWidth(ctx, -1)
  _, tag_edit.durationOverride = ImGui.InputText(ctx, '##ed_duration_ovr', tag_edit.durationOverride)
  if ImGui.IsItemHovered(ctx) then
    ImGui.SetTooltip(ctx, 'Override duration in seconds')
  end

  -- Time Sig Override
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Time Sig:')
  ImGui.SameLine(ctx, lbl_w)
  ImGui.SetNextItemWidth(ctx, -1)
  _, tag_edit.timeSigOverride = ImGui.InputText(ctx, '##ed_timesig_ovr', tag_edit.timeSigOverride)
  if ImGui.IsItemHovered(ctx) and S.tag_edit_proj.projectTimeSig then
    ImGui.SetTooltip(ctx, 'Override auto-detected: ' .. S.tag_edit_proj.projectTimeSig)
  end

  -- Art Override (path)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Art path:')
  ImGui.SameLine(ctx, lbl_w)
  ImGui.SetNextItemWidth(ctx, -1)
  _, tag_edit.artOverride = ImGui.InputText(ctx, '##ed_art_ovr', tag_edit.artOverride)
  if ImGui.IsItemHovered(ctx) then
    ImGui.SetTooltip(ctx, 'Path to custom album art image')
  end

  ImGui.EndChild(ctx)  -- tag_fields_scroll
  end -- if BeginChild tag_fields_scroll

  ImGui.Separator(ctx)
  ImGui.Spacing(ctx)

  -- Notes (multi-line, fixed height at bottom)
  ImGui.Text(ctx, 'Notes:')
  local _, notes_avail = ImGui.GetContentRegionAvail(ctx)
  local notes_h = math.max(40, notes_avail - 30)  -- leave room for buttons
  ImGui.SetNextItemWidth(ctx, -1)
  _, tag_edit.notes = ImGui.InputTextMultiline(ctx, '##ed_notes', tag_edit.notes, -1, notes_h)

  -- Save / Cancel
  if ImGui.Button(ctx, 'Save', 80, 0) then
    local path = S.tag_edit_proj.path
    -- Merge into existing tags to preserve keys not in the editor
    -- Use path-equivalence lookup to find existing tags under any path variant
    local tags = GetTags(path)
    if next(tags) == nil then tags = {} end
    -- Set editor fields (clear to nil when empty, so they don't linger as '')
    tags.strings    = tag_edit.strings ~= '' and tonumber(tag_edit.strings) or nil
    tags.tuning     = tag_edit.tuning ~= '' and tag_edit.tuning or nil
    tags.transpose  = tag_edit.transpose ~= '' and tag_edit.transpose or nil
    tags.status     = tag_edit.status ~= '' and tag_edit.status or nil
    tags.difficulty  = tag_edit.difficulty ~= '' and tag_edit.difficulty or nil
    tags.guitar     = tag_edit.guitar ~= '' and tag_edit.guitar or nil
    tags.amp        = tag_edit.amp ~= '' and tag_edit.amp or nil
    -- Reconstruct genre from primary + secondary
    local save_genre = nil
    if tag_edit.genre_primary ~= '' then
      local genre_arr = { tag_edit.genre_primary }
      if tag_edit.genre_secondary ~= '' then
        for part in tag_edit.genre_secondary:gmatch('[^,]+') do
          local trimmed = part:match('^%s*(.-)%s*$')
          if trimmed ~= '' then genre_arr[#genre_arr + 1] = trimmed end
        end
      end
      save_genre = #genre_arr == 1 and genre_arr[1] or genre_arr
    end
    tags.genre      = save_genre
    tags.notes      = tag_edit.notes ~= '' and tag_edit.notes or nil
    tags.bpmOverride = tag_edit.bpmOverride ~= '' and tonumber(tag_edit.bpmOverride) or nil
    tags.keyOverride = tag_edit.keyOverride ~= '' and tag_edit.keyOverride or nil
    tags.albumOverride    = tag_edit.albumOverride ~= '' and tag_edit.albumOverride or nil
    tags.artistOverride   = tag_edit.artistOverride ~= '' and tag_edit.artistOverride or nil
    tags.titleOverride    = tag_edit.titleOverride ~= '' and tag_edit.titleOverride or nil
    tags.durationOverride = tag_edit.durationOverride ~= '' and tonumber(tag_edit.durationOverride) or nil
    tags.timeSigOverride  = tag_edit.timeSigOverride ~= '' and tag_edit.timeSigOverride or nil
    tags.artOverride      = tag_edit.artOverride ~= '' and tag_edit.artOverride or nil
    tags.favorite   = tag_edit.favorite

    local tagKey = FindTagKey(path)
    project_tags[tagKey] = tags
    S.tag_edit_proj.tags = tags

    -- Re-resolve display fields (same priority: override > auto-detected)
    if tags.bpmOverride then
      S.tag_edit_proj.displayBPM = tags.bpmOverride
    elseif S.tag_edit_proj.projectBPM then
      S.tag_edit_proj.displayBPM = math.floor(S.tag_edit_proj.projectBPM + 0.5)
    elseif S.tag_edit_proj.songBPM then
      S.tag_edit_proj.displayBPM = math.floor(S.tag_edit_proj.songBPM + 0.5)
    end
    if tags.keyOverride then
      S.tag_edit_proj.displayKey = tags.keyOverride
    else
      S.tag_edit_proj.displayKey = S.tag_edit_proj.songKey
    end
    if tags.albumOverride then
      S.tag_edit_proj.album = tags.albumOverride
    end
    if tags.artistOverride then
      S.tag_edit_proj.matchedArtist = tags.artistOverride
    end
    if tags.titleOverride then
      S.tag_edit_proj.matchedTitle = tags.titleOverride
    end
    if tags.durationOverride then
      S.tag_edit_proj.duration = tags.durationOverride
    end
    if tags.timeSigOverride then
      S.tag_edit_proj.projectTimeSig = tags.timeSigOverride
    end

    SaveTags()
    BuildSearchHaystack(S.tag_edit_proj)
    ImGui.CloseCurrentPopup(ctx)
  end

  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, 'Cancel', 80, 0) then
    ImGui.CloseCurrentPopup(ctx)
  end

  -- Unsaved changes indicator
  local is_dirty = (SerializeTagEdit() ~= S.tag_edit_snapshot)
  if is_dirty then
    ImGui.SameLine(ctx)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xFFAA44FF)
    ImGui.Text(ctx, '  Unsaved changes')
    ImGui.PopStyleColor(ctx, 1)
  end

  if not open then
    ImGui.CloseCurrentPopup(ctx)
  end

  ImGui.EndPopup(ctx)
end

-- ============================================================================
-- UI — BULK TAG EDITOR (modal popup)
-- ============================================================================

-- Helper: draw a tri-state mode selector (Unchanged / Set / Clear) and return new mode
local function BulkModeSelector(field_id, mode)
  ImGui.PushID(ctx, field_id)
  local new_mode = mode
  if ImGui.RadioButton(ctx, 'Skip', mode == 0) then new_mode = 0 end
  ImGui.SameLine(ctx)
  if ImGui.RadioButton(ctx, 'Set', mode == 1) then new_mode = 1 end
  ImGui.SameLine(ctx)
  if ImGui.RadioButton(ctx, 'Clear', mode == 2) then new_mode = 2 end
  ImGui.PopID(ctx)
  return new_mode
end

local function DrawBulkTagEditor()
  ImGui.SetNextWindowSize(ctx, 520, 620, ImGui.Cond_Appearing)
  local visible, open = ImGui.BeginPopupModal(ctx, 'Bulk Edit Tags##bulk_modal', true, 0)
  if not visible then return end

  if not S.bulk_tag_edit_projects or #S.bulk_tag_edit_projects == 0 then
    ImGui.EndPopup(ctx)
    return
  end

  local count = #S.bulk_tag_edit_projects
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.accent)
  ImGui.Text(ctx, 'Editing ' .. count .. ' projects')
  ImGui.PopStyleColor(ctx, 1)

  ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
  ImGui.TextWrapped(ctx, 'Skip = leave unchanged, Set = apply value, Clear = remove field')
  ImGui.PopStyleColor(ctx, 1)
  ImGui.Separator(ctx)
  ImGui.Spacing(ctx)

  local lbl_w = 110
  local mode_w = 200  -- approximate width for mode radio buttons

  -- Scrollable field area
  local _, avail_y = ImGui.GetContentRegionAvail(ctx)
  local fields_h = math.max(200, avail_y - 50)  -- reserve for buttons

  if ImGui.BeginChild(ctx, 'bulk_fields_scroll', -1, fields_h) then

  -- === Strings ===
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Strings:')
  ImGui.SameLine(ctx, lbl_w)
  bulk_edit.strings_mode = BulkModeSelector('bk_strings', bulk_edit.strings_mode)
  if bulk_edit.strings_mode == 1 then
    ImGui.Text(ctx, '')
    ImGui.SameLine(ctx, lbl_w)
    local s6 = (bulk_edit.strings == '6')
    local s7 = (bulk_edit.strings == '7')
    local s8 = (bulk_edit.strings == '8')
    if ImGui.RadioButton(ctx, '6##bstr', s6) then bulk_edit.strings = '6' end
    ImGui.SameLine(ctx)
    if ImGui.RadioButton(ctx, '7##bstr', s7) then bulk_edit.strings = '7' end
    ImGui.SameLine(ctx)
    if ImGui.RadioButton(ctx, '8##bstr', s8) then bulk_edit.strings = '8' end
  end
  ImGui.Spacing(ctx)

  -- === Status ===
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Status:')
  ImGui.SameLine(ctx, lbl_w)
  bulk_edit.status_mode = BulkModeSelector('bk_status', bulk_edit.status_mode)
  if bulk_edit.status_mode == 1 then
    ImGui.Text(ctx, '')
    ImGui.SameLine(ctx, lbl_w)
    ImGui.SetNextItemWidth(ctx, -1)
    local st_label = bulk_edit.status ~= '' and bulk_edit.status or '(select)'
    if ImGui.BeginCombo(ctx, '##bk_status_val', st_label) then
      for _, s in ipairs(CFG.STATUS_PRESETS) do
        if ImGui.Selectable(ctx, s .. '##bkst', bulk_edit.status == s) then bulk_edit.status = s end
      end
      ImGui.EndCombo(ctx)
    end
  end
  ImGui.Spacing(ctx)

  -- === Tuning ===
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Tuning:')
  ImGui.SameLine(ctx, lbl_w)
  bulk_edit.tuning_mode = BulkModeSelector('bk_tuning', bulk_edit.tuning_mode)
  if bulk_edit.tuning_mode == 1 then
    ImGui.Text(ctx, '')
    ImGui.SameLine(ctx, lbl_w)
    ImGui.SetNextItemWidth(ctx, -1)
    local tn_label = bulk_edit.tuning ~= '' and bulk_edit.tuning or '(select)'
    if ImGui.BeginCombo(ctx, '##bk_tuning_val', tn_label) then
      for _, t in ipairs(CFG.TUNING_PRESETS) do
        if ImGui.Selectable(ctx, t .. '##bktn', bulk_edit.tuning == t) then bulk_edit.tuning = t end
      end
      ImGui.EndCombo(ctx)
    end
  end
  ImGui.Spacing(ctx)

  -- === Transpose ===
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Transpose:')
  ImGui.SameLine(ctx, lbl_w)
  bulk_edit.transpose_mode = BulkModeSelector('bk_transpose', bulk_edit.transpose_mode)
  if bulk_edit.transpose_mode == 1 then
    ImGui.Text(ctx, '')
    ImGui.SameLine(ctx, lbl_w)
    ImGui.SetNextItemWidth(ctx, -1)
    local tp_label = bulk_edit.transpose ~= '' and bulk_edit.transpose or '(select)'
    if ImGui.BeginCombo(ctx, '##bk_transpose_val', tp_label) then
      for _, t in ipairs(CFG.TRANSPOSE_PRESETS) do
        if ImGui.Selectable(ctx, t .. '##bktp', bulk_edit.transpose == t) then bulk_edit.transpose = t end
      end
      ImGui.EndCombo(ctx)
    end
  end
  ImGui.Spacing(ctx)

  -- === Difficulty ===
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Difficulty:')
  ImGui.SameLine(ctx, lbl_w)
  bulk_edit.difficulty_mode = BulkModeSelector('bk_difficulty', bulk_edit.difficulty_mode)
  if bulk_edit.difficulty_mode == 1 then
    ImGui.Text(ctx, '')
    ImGui.SameLine(ctx, lbl_w)
    ImGui.SetNextItemWidth(ctx, -1)
    local df_label = bulk_edit.difficulty ~= '' and bulk_edit.difficulty or '(select)'
    if ImGui.BeginCombo(ctx, '##bk_diff_val', df_label) then
      for _, d in ipairs(CFG.DIFFICULTY_PRESETS) do
        if ImGui.Selectable(ctx, d .. '##bkdf', bulk_edit.difficulty == d) then bulk_edit.difficulty = d end
      end
      ImGui.EndCombo(ctx)
    end
  end
  ImGui.Spacing(ctx)

  -- === Guitar ===
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Guitar:')
  ImGui.SameLine(ctx, lbl_w)
  bulk_edit.guitar_mode = BulkModeSelector('bk_guitar', bulk_edit.guitar_mode)
  if bulk_edit.guitar_mode == 1 then
    ImGui.Text(ctx, '')
    ImGui.SameLine(ctx, lbl_w)
    ImGui.SetNextItemWidth(ctx, -1)
    local gt_label = bulk_edit.guitar ~= '' and bulk_edit.guitar or '(select)'
    if ImGui.BeginCombo(ctx, '##bk_guitar_val', gt_label) then
      for _, g in ipairs(CFG.GUITAR_PRESETS) do
        if g == 'Custom' then
          ImGui.Separator(ctx)
          if ImGui.Selectable(ctx, 'Custom...##bkgt', false) then bulk_edit.guitar = 'Custom' end
        else
          if ImGui.Selectable(ctx, g .. '##bkgt', bulk_edit.guitar == g) then bulk_edit.guitar = g end
        end
      end
      ImGui.EndCombo(ctx)
    end
    -- Custom guitar input
    local is_preset = false
    for _, g in ipairs(CFG.GUITAR_PRESETS) do
      if g ~= 'Custom' and bulk_edit.guitar == g then is_preset = true; break end
    end
    if bulk_edit.guitar ~= '' and not is_preset then
      ImGui.Text(ctx, '')
      ImGui.SameLine(ctx, lbl_w)
      ImGui.SetNextItemWidth(ctx, -1)
      _, bulk_edit.guitar = ImGui.InputText(ctx, '##bk_guitar_custom', bulk_edit.guitar)
    end
  end
  ImGui.Spacing(ctx)

  -- === Amp/Plugin ===
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Amp/Plugin:')
  ImGui.SameLine(ctx, lbl_w)
  bulk_edit.amp_mode = BulkModeSelector('bk_amp', bulk_edit.amp_mode)
  if bulk_edit.amp_mode == 1 then
    ImGui.Text(ctx, '')
    ImGui.SameLine(ctx, lbl_w)
    ImGui.SetNextItemWidth(ctx, -1)
    _, bulk_edit.amp = ImGui.InputText(ctx, '##bk_amp_val', bulk_edit.amp)
  end
  ImGui.Spacing(ctx)

  -- === Genre ===
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Genre:')
  ImGui.SameLine(ctx, lbl_w)
  bulk_edit.genre_mode = BulkModeSelector('bk_genre', bulk_edit.genre_mode)
  if bulk_edit.genre_mode == 1 then
    ImGui.Text(ctx, '')
    ImGui.SameLine(ctx, lbl_w)
    ImGui.SetNextItemWidth(ctx, -1)
    local gp_label = bulk_edit.genre_primary ~= '' and bulk_edit.genre_primary or '(select)'
    if ImGui.BeginCombo(ctx, '##bk_genre_primary', gp_label) then
      for _, g in ipairs(CFG.PRIMARY_GENRES) do
        if ImGui.Selectable(ctx, g .. '##bkgp', bulk_edit.genre_primary == g) then bulk_edit.genre_primary = g end
      end
      ImGui.EndCombo(ctx)
    end
    ImGui.Text(ctx, 'Sub-Genre:')
    ImGui.SameLine(ctx, lbl_w)
    ImGui.SetNextItemWidth(ctx, -1)
    _, bulk_edit.genre_secondary = ImGui.InputText(ctx, '##bk_genre_secondary', bulk_edit.genre_secondary)
  end
  ImGui.Spacing(ctx)

  -- === Favorite ===
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Favorite:')
  ImGui.SameLine(ctx, lbl_w)
  bulk_edit.favorite_mode = BulkModeSelector('bk_fav', bulk_edit.favorite_mode)
  if bulk_edit.favorite_mode == 1 then
    ImGui.Text(ctx, '')
    ImGui.SameLine(ctx, lbl_w)
    _, bulk_edit.favorite = ImGui.Checkbox(ctx, 'Mark as favorite##bk_fav', bulk_edit.favorite)
  end

  ImGui.Spacing(ctx)
  ImGui.Separator(ctx)
  ImGui.Spacing(ctx)

  -- Metadata overrides section
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
  ImGui.Text(ctx, 'Metadata Overrides')
  ImGui.PopStyleColor(ctx, 1)
  ImGui.Spacing(ctx)

  -- === BPM Override ===
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'BPM:')
  ImGui.SameLine(ctx, lbl_w)
  bulk_edit.bpmOverride_mode = BulkModeSelector('bk_bpm', bulk_edit.bpmOverride_mode)
  if bulk_edit.bpmOverride_mode == 1 then
    ImGui.Text(ctx, '')
    ImGui.SameLine(ctx, lbl_w)
    ImGui.SetNextItemWidth(ctx, -1)
    _, bulk_edit.bpmOverride = ImGui.InputText(ctx, '##bk_bpm_val', bulk_edit.bpmOverride)
  end
  ImGui.Spacing(ctx)

  -- === Key Override ===
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Key:')
  ImGui.SameLine(ctx, lbl_w)
  bulk_edit.keyOverride_mode = BulkModeSelector('bk_key', bulk_edit.keyOverride_mode)
  if bulk_edit.keyOverride_mode == 1 then
    ImGui.Text(ctx, '')
    ImGui.SameLine(ctx, lbl_w)
    ImGui.SetNextItemWidth(ctx, -1)
    _, bulk_edit.keyOverride = ImGui.InputText(ctx, '##bk_key_val', bulk_edit.keyOverride)
  end
  ImGui.Spacing(ctx)

  -- === Album Override ===
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Album:')
  ImGui.SameLine(ctx, lbl_w)
  bulk_edit.albumOverride_mode = BulkModeSelector('bk_album', bulk_edit.albumOverride_mode)
  if bulk_edit.albumOverride_mode == 1 then
    ImGui.Text(ctx, '')
    ImGui.SameLine(ctx, lbl_w)
    ImGui.SetNextItemWidth(ctx, -1)
    _, bulk_edit.albumOverride = ImGui.InputText(ctx, '##bk_album_val', bulk_edit.albumOverride)
  end
  ImGui.Spacing(ctx)

  -- === Artist Override ===
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Artist:')
  ImGui.SameLine(ctx, lbl_w)
  bulk_edit.artistOverride_mode = BulkModeSelector('bk_artist', bulk_edit.artistOverride_mode)
  if bulk_edit.artistOverride_mode == 1 then
    ImGui.Text(ctx, '')
    ImGui.SameLine(ctx, lbl_w)
    ImGui.SetNextItemWidth(ctx, -1)
    _, bulk_edit.artistOverride = ImGui.InputText(ctx, '##bk_artist_val', bulk_edit.artistOverride)
  end
  ImGui.Spacing(ctx)

  -- === Title Override ===
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Title:')
  ImGui.SameLine(ctx, lbl_w)
  bulk_edit.titleOverride_mode = BulkModeSelector('bk_title', bulk_edit.titleOverride_mode)
  if bulk_edit.titleOverride_mode == 1 then
    ImGui.Text(ctx, '')
    ImGui.SameLine(ctx, lbl_w)
    ImGui.SetNextItemWidth(ctx, -1)
    _, bulk_edit.titleOverride = ImGui.InputText(ctx, '##bk_title_val', bulk_edit.titleOverride)
  end
  ImGui.Spacing(ctx)

  -- === Duration Override ===
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Duration (s):')
  ImGui.SameLine(ctx, lbl_w)
  bulk_edit.durationOverride_mode = BulkModeSelector('bk_dur', bulk_edit.durationOverride_mode)
  if bulk_edit.durationOverride_mode == 1 then
    ImGui.Text(ctx, '')
    ImGui.SameLine(ctx, lbl_w)
    ImGui.SetNextItemWidth(ctx, -1)
    _, bulk_edit.durationOverride = ImGui.InputText(ctx, '##bk_dur_val', bulk_edit.durationOverride)
  end
  ImGui.Spacing(ctx)

  -- === Time Sig Override ===
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Time Sig:')
  ImGui.SameLine(ctx, lbl_w)
  bulk_edit.timeSigOverride_mode = BulkModeSelector('bk_tsig', bulk_edit.timeSigOverride_mode)
  if bulk_edit.timeSigOverride_mode == 1 then
    ImGui.Text(ctx, '')
    ImGui.SameLine(ctx, lbl_w)
    ImGui.SetNextItemWidth(ctx, -1)
    _, bulk_edit.timeSigOverride = ImGui.InputText(ctx, '##bk_tsig_val', bulk_edit.timeSigOverride)
  end
  ImGui.Spacing(ctx)

  -- === Art Override ===
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Art path:')
  ImGui.SameLine(ctx, lbl_w)
  bulk_edit.artOverride_mode = BulkModeSelector('bk_art', bulk_edit.artOverride_mode)
  if bulk_edit.artOverride_mode == 1 then
    ImGui.Text(ctx, '')
    ImGui.SameLine(ctx, lbl_w)
    ImGui.SetNextItemWidth(ctx, -1)
    _, bulk_edit.artOverride = ImGui.InputText(ctx, '##bk_art_val', bulk_edit.artOverride)
  end

  ImGui.Spacing(ctx)
  ImGui.Separator(ctx)
  ImGui.Spacing(ctx)

  -- === Notes ===
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Notes:')
  ImGui.SameLine(ctx, lbl_w)
  bulk_edit.notes_mode = BulkModeSelector('bk_notes', bulk_edit.notes_mode)
  if bulk_edit.notes_mode == 1 then
    ImGui.SetNextItemWidth(ctx, -1)
    _, bulk_edit.notes = ImGui.InputTextMultiline(ctx, '##bk_notes_val', bulk_edit.notes, -1, 60)
  end

  ImGui.EndChild(ctx)
  end -- if BeginChild

  -- Count how many fields are being changed
  local change_count = 0
  for k in pairs(bulk_edit) do
    if k:match('_mode$') and bulk_edit[k] ~= 0 then change_count = change_count + 1 end
  end

  -- Apply / Cancel buttons
  local can_apply = change_count > 0
  if not can_apply then ImGui.BeginDisabled(ctx) end
  if ImGui.Button(ctx, 'Apply to ' .. count .. ' projects', 0, 0) then
    -- Apply changes to all selected projects
    for _, proj in ipairs(S.bulk_tag_edit_projects) do
      local tags = GetTags(proj.path)
      if next(tags) == nil then tags = {} end

      -- Simple fields: set or clear
      local simple_fields = {
        { mode = 'strings_mode',   key = 'strings',    val = bulk_edit.strings ~= '' and tonumber(bulk_edit.strings) or nil },
        { mode = 'status_mode',    key = 'status',     val = bulk_edit.status ~= '' and bulk_edit.status or nil },
        { mode = 'tuning_mode',    key = 'tuning',     val = bulk_edit.tuning ~= '' and bulk_edit.tuning or nil },
        { mode = 'transpose_mode', key = 'transpose',  val = bulk_edit.transpose ~= '' and bulk_edit.transpose or nil },
        { mode = 'difficulty_mode', key = 'difficulty', val = bulk_edit.difficulty ~= '' and bulk_edit.difficulty or nil },
        { mode = 'guitar_mode',    key = 'guitar',     val = bulk_edit.guitar ~= '' and bulk_edit.guitar or nil },
        { mode = 'amp_mode',       key = 'amp',        val = bulk_edit.amp ~= '' and bulk_edit.amp or nil },
        { mode = 'notes_mode',     key = 'notes',      val = bulk_edit.notes ~= '' and bulk_edit.notes or nil },
        { mode = 'bpmOverride_mode',  key = 'bpmOverride',  val = bulk_edit.bpmOverride ~= '' and tonumber(bulk_edit.bpmOverride) or nil },
        { mode = 'keyOverride_mode',  key = 'keyOverride',  val = bulk_edit.keyOverride ~= '' and bulk_edit.keyOverride or nil },
        { mode = 'albumOverride_mode', key = 'albumOverride', val = bulk_edit.albumOverride ~= '' and bulk_edit.albumOverride or nil },
        { mode = 'artistOverride_mode', key = 'artistOverride', val = bulk_edit.artistOverride ~= '' and bulk_edit.artistOverride or nil },
        { mode = 'titleOverride_mode',  key = 'titleOverride',  val = bulk_edit.titleOverride ~= '' and bulk_edit.titleOverride or nil },
        { mode = 'durationOverride_mode', key = 'durationOverride', val = bulk_edit.durationOverride ~= '' and tonumber(bulk_edit.durationOverride) or nil },
        { mode = 'timeSigOverride_mode', key = 'timeSigOverride', val = bulk_edit.timeSigOverride ~= '' and bulk_edit.timeSigOverride or nil },
        { mode = 'artOverride_mode',     key = 'artOverride',     val = bulk_edit.artOverride ~= '' and bulk_edit.artOverride or nil },
      }
      for _, f in ipairs(simple_fields) do
        if bulk_edit[f.mode] == 1 then tags[f.key] = f.val
        elseif bulk_edit[f.mode] == 2 then tags[f.key] = nil end
      end

      -- Genre (compound field)
      if bulk_edit.genre_mode == 1 then
        if bulk_edit.genre_primary ~= '' then
          local genre_arr = { bulk_edit.genre_primary }
          if bulk_edit.genre_secondary ~= '' then
            for part in bulk_edit.genre_secondary:gmatch('[^,]+') do
              local trimmed = part:match('^%s*(.-)%s*$')
              if trimmed ~= '' then genre_arr[#genre_arr + 1] = trimmed end
            end
          end
          tags.genre = #genre_arr == 1 and genre_arr[1] or genre_arr
        end
      elseif bulk_edit.genre_mode == 2 then
        tags.genre = nil
      end

      -- Favorite
      if bulk_edit.favorite_mode == 1 then tags.favorite = bulk_edit.favorite
      elseif bulk_edit.favorite_mode == 2 then tags.favorite = nil end

      local tagKey = FindTagKey(proj.path)
      project_tags[tagKey] = tags
      proj.tags = tags
      BuildSearchHaystack(proj)
    end

    SaveTags()
    S.bulk_tag_edit_projects = nil
    ImGui.CloseCurrentPopup(ctx)
  end
  if not can_apply then ImGui.EndDisabled(ctx) end

  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, 'Cancel', 80, 0) then
    S.bulk_tag_edit_projects = nil
    ImGui.CloseCurrentPopup(ctx)
  end

  if change_count > 0 then
    ImGui.SameLine(ctx)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
    ImGui.Text(ctx, '  ' .. change_count .. ' field(s) will be modified')
    ImGui.PopStyleColor(ctx, 1)
  end

  if not open then
    S.bulk_tag_edit_projects = nil
    ImGui.CloseCurrentPopup(ctx)
  end

  ImGui.EndPopup(ctx)
end

-- ============================================================================
-- UI — PROJECT LIST TABLE
-- ============================================================================

local function DrawProjectList()
  -- Reserve height for action bar + status bar below
  local _, avail_y = ImGui.GetContentRegionAvail(ctx)
  local list_h = avail_y - 72

  -- All columns always defined — user can show/hide via right-click header
  local ncols = 14  -- #, Art, Project, Artist, Title, Album, Genre, BPM, Key, Duration, Time, Info, Modified, Path

  local tflags = ImGui.TableFlags_RowBg
               | ImGui.TableFlags_BordersInnerH
               | ImGui.TableFlags_ScrollY
               | ImGui.TableFlags_Resizable
               | ImGui.TableFlags_Reorderable
               | ImGui.TableFlags_Hideable
               | ImGui.TableFlags_SizingFixedFit  -- columns auto-fit content; "Resize all to default" = fit
               | ImGui.TableFlags_PadOuterX

  -- Per-tab table ID gives each tab independent column visibility/order/widths
  local tbl_id = (S.active_tab == 'all') and 'proj_tbl_all' or 'proj_tbl_recent'
  if not ImGui.BeginTable(ctx, tbl_id, ncols, tflags, 0, list_h) then return end

  -- Setup columns — all always present; hideable via right-click on header row
  -- NoHide = always visible; DefaultHide = hidden by default (user can show)
  -- SizingFixedFit: columns auto-fit content. Project uses WidthStretch to fill remaining space.
  local dhide = ImGui.TableColumnFlags_DefaultHide
  ImGui.TableSetupColumn(ctx, '#',         ImGui.TableColumnFlags_WidthFixed | ImGui.TableColumnFlags_NoReorder, 28)
  ImGui.TableSetupColumn(ctx, 'Art',       ImGui.TableColumnFlags_WidthFixed, S.art_size + 8)
  ImGui.TableSetupColumn(ctx, 'Project',   ImGui.TableColumnFlags_NoHide | ImGui.TableColumnFlags_WidthStretch, 0)
  ImGui.TableSetupColumn(ctx, 'Artist',    dhide, 0)
  ImGui.TableSetupColumn(ctx, 'Title',     dhide, 0)
  ImGui.TableSetupColumn(ctx, 'Album',     dhide, 0)
  ImGui.TableSetupColumn(ctx, 'Genre',     dhide, 0)
  ImGui.TableSetupColumn(ctx, 'BPM',       0, 0)
  ImGui.TableSetupColumn(ctx, 'Key',       0, 0)
  ImGui.TableSetupColumn(ctx, 'Duration',  dhide, 0)
  ImGui.TableSetupColumn(ctx, 'Time',      dhide, 0)
  ImGui.TableSetupColumn(ctx, 'Info',      0, 0)
  ImGui.TableSetupColumn(ctx, 'Modified',  0, 0)
  ImGui.TableSetupColumn(ctx, 'Path',      dhide, 0)
  ImGui.TableSetupScrollFreeze(ctx, 0, 1)
  ImGui.TableHeadersRow(ctx)

  -- Column indices (fixed — matches TableSetupColumn order above)
  local COL_NUM     = 0
  local COL_ART     = 1
  local COL_PROJECT = 2
  local COL_ARTIST  = 3
  local COL_TITLE   = 4
  local COL_ALBUM   = 5
  local COL_GENRE   = 6
  local COL_BPM     = 7
  local COL_KEY     = 8
  local COL_DUR     = 9
  local COL_TSIG    = 10
  local COL_INFO    = 11
  local COL_DATE    = 12
  local COL_PATH    = 13

  -- Empty state
  if #S.filtered_projects == 0 then
    ImGui.TableNextRow(ctx)
    ImGui.TableSetColumnIndex(ctx, COL_PROJECT)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
    if S.search_buf ~= '' or S.filter_strings > 1 or S.filter_tuning > 1 or S.filter_status > 1 or S.filter_favs
       or S.filter_tri_meta ~= 0 or S.filter_tri_art ~= 0 or S.filter_tri_tags ~= 0 or S.filter_genre > 1
       or S.filter_exclude_recents or S.filter_include_all or S.show_dedupe ~= 1 then
      ImGui.Text(ctx, 'No projects match your filters.')
    else
      if S.active_tab == 'all' and S.ALL_PROJECTS_PATH == '' and #S.additional_project_paths == 0 then
        ImGui.Text(ctx, 'Scan path not configured — set it in Settings → All Projects')
      else
        ImGui.Text(ctx, S.active_tab == 'all' and 'No projects found.' or 'No recent projects found.')
      end
    end
    ImGui.PopStyleColor(ctx, 1)
    ImGui.EndTable(ctx)
    return
  end

  -- Render rows
  for i, proj in ipairs(S.filtered_projects) do
    -- Separator: draw a visual divider between recent and all-projects results
    -- Used by both universal search and combined view ("Include All")
    if S.recent_count_in_filtered > 0 and i == S.recent_count_in_filtered + 1 then
      local sep_label = S.filter_include_all and '  Remaining Projects' or '  All Projects'
      ImGui.TableNextRow(ctx)
      ImGui.TableSetColumnIndex(ctx, COL_PROJECT)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
      ImGui.Separator(ctx)
      ImGui.Text(ctx, sep_label)
      ImGui.Separator(ctx)
      ImGui.PopStyleColor(ctx, 1)
    end

    local row_h = S.art_size + 4
    ImGui.TableNextRow(ctx, 0, row_h)

    local dimmed = not proj.exists
    if dimmed then ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim) end

    -- Serial number
    ImGui.TableSetColumnIndex(ctx, COL_NUM)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
    ImGui.Text(ctx, tostring(i))
    ImGui.PopStyleColor(ctx, 1)

    -- Album art thumbnail (skip if column is hidden to avoid loading unnecessary images)
    if ImGui.TableSetColumnIndex(ctx, COL_ART) then
      if proj.albumArtPath then
        local img = GetImage(proj.albumArtPath)
        if img then
          ImGui.Image(ctx, img, S.art_size, S.art_size)
        else
          DrawArtPlaceholder(proj, S.art_size)
        end
      else
        DrawArtPlaceholder(proj, S.art_size)
      end
    end

    -- Project name
    ImGui.TableSetColumnIndex(ctx, COL_PROJECT)

    local label = proj.name
    if dimmed then label = label .. '  [missing]' end

    -- Favorite star prefix
    local tags = proj.tags or {}
    if tags.favorite then
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.favStar)
      ImGui.Text(ctx, '*')
      ImGui.PopStyleColor(ctx, 1)
      ImGui.SameLine(ctx, 0, 4)
    end

    local sel_flags = ImGui.SelectableFlags_SpanAllColumns
                    | ImGui.SelectableFlags_AllowDoubleClick

    if S.pending_focus_idx == i then
      ImGui.SetKeyboardFocusHere(ctx, 0)
      S.pending_focus_idx = nil
    end

    if ImGui.Selectable(ctx, label .. '##row' .. i, IsSelected(i), sel_flags, 0, S.art_size) then
      if ImGui.IsMouseDoubleClicked(ctx, 0) then
        ActionOpenProject(proj)
      elseif ImGui.IsKeyDown(ctx, ImGui.Key_LeftCtrl) or ImGui.IsKeyDown(ctx, ImGui.Key_RightCtrl) then
        ToggleSelect(i)
      elseif ImGui.IsKeyDown(ctx, ImGui.Key_LeftShift) or ImGui.IsKeyDown(ctx, ImGui.Key_RightShift) then
        local anchor = S.sel_anchor > 0 and S.sel_anchor or 1
        S.selected = {}
        SelectRange(anchor, i)
      else
        SelectOnly(i)
      end
    end

    -- Tooltip on hover: show path, album, duration (commented out per user preference)
    -- if ImGui.IsItemHovered(ctx) then
    --   local tip = proj.path
    --   if proj.album then tip = tip .. '\nAlbum: ' .. proj.album end
    --   if proj.duration then
    --     local mins = math.floor(proj.duration / 60)
    --     local secs = math.floor(proj.duration % 60)
    --     tip = tip .. string.format('\nDuration: %d:%02d', mins, secs)
    --   end
    --   ImGui.SetTooltip(ctx, tip)
    -- end
    -- Right-click: auto-select if this row is not already part of the selection
    if ImGui.IsItemClicked(ctx, ImGui.MouseButton_Right) and not IsSelected(i) then
      SelectOnly(i)
    end

    -- Right-click context menu
    DrawContextMenu(proj, i)

    if dimmed then ImGui.PopStyleColor(ctx, 1) end

    -- Artist column (spicetify matched artist, fallback to filename artist)
    ImGui.TableSetColumnIndex(ctx, COL_ARTIST)
    local displayArtist = proj.matchedArtist or proj.artist
    if displayArtist and displayArtist ~= '' then
      ImGui.Text(ctx, displayArtist)
    end

    -- Title column (spicetify matched title, fallback to filename song)
    ImGui.TableSetColumnIndex(ctx, COL_TITLE)
    local displayTitle = proj.matchedTitle or proj.song
    if displayTitle and displayTitle ~= '' then
      ImGui.Text(ctx, displayTitle)
    end

    -- Album column
    ImGui.TableSetColumnIndex(ctx, COL_ALBUM)
    if proj.album then
      ImGui.Text(ctx, proj.album)
    end

    -- Genre column (shows primary genre; full genre in tooltip when it differs)
    ImGui.TableSetColumnIndex(ctx, COL_GENRE)
    local primaryGenre = GetPrimaryGenre(tags)
    if primaryGenre then
      ImGui.Text(ctx, primaryGenre)
      if ImGui.IsItemHovered(ctx) then
        local fullGenre = GenreStr(tags.genre)
        if fullGenre ~= primaryGenre then
          ImGui.SetTooltip(ctx, fullGenre)
        end
      end
    end

    -- BPM column (shows project BPM from RPP, tooltip shows Spotify BPM)
    ImGui.TableSetColumnIndex(ctx, COL_BPM)
    if proj.displayBPM then
      ImGui.Text(ctx, tostring(proj.displayBPM))
      if ImGui.IsItemHovered(ctx) then
        local tip_parts = {}
        if proj.projectBPM then
          tip_parts[#tip_parts + 1] = 'Project: ' .. math.floor(proj.projectBPM + 0.5)
        end
        if proj.songBPM then
          tip_parts[#tip_parts + 1] = 'Spotify: ' .. math.floor(proj.songBPM + 0.5)
        end
        if proj.projectTimeSig then
          tip_parts[#tip_parts + 1] = 'Time sig: ' .. proj.projectTimeSig
        end
        if #tip_parts > 0 then
          ImGui.SetTooltip(ctx, table.concat(tip_parts, '\n'))
        end
      end
    end

    -- Key column
    ImGui.TableSetColumnIndex(ctx, COL_KEY)
    if proj.displayKey then
      ImGui.Text(ctx, proj.displayKey)
      if ImGui.IsItemHovered(ctx) then
        local src = (proj.tags or {}).keyOverride and 'Custom override' or 'Spotify'
        ImGui.SetTooltip(ctx, 'Source: ' .. src)
      end
    end

    -- Duration column (from spicetify audio_analysis, formatted as M:SS)
    ImGui.TableSetColumnIndex(ctx, COL_DUR)
    if proj.duration then
      local mins = math.floor(proj.duration / 60)
      local secs = math.floor(proj.duration % 60)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
      ImGui.Text(ctx, string.format('%d:%02d', mins, secs))
      ImGui.PopStyleColor(ctx, 1)
    end

    -- Time Signature column (project RPP time sig, fallback to spicetify)
    ImGui.TableSetColumnIndex(ctx, COL_TSIG)
    local tsig = proj.projectTimeSig or (proj.timeSig and (tostring(proj.timeSig) .. '/4'))
    if tsig then
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
      ImGui.Text(ctx, tsig)
      ImGui.PopStyleColor(ctx, 1)
    end

    -- Info column (tags summary)
    ImGui.TableSetColumnIndex(ctx, COL_INFO)
    local info_parts = {}
    if tags.strings then info_parts[#info_parts + 1] = tags.strings .. '-string' end
    if tags.tuning then
      local tuning_str = tags.tuning
      if tags.transpose and tags.transpose ~= '' and tags.transpose ~= '0 (none)' then
        tuning_str = tuning_str .. ' (' .. tags.transpose .. ')'
      end
      info_parts[#info_parts + 1] = tuning_str
    end
    if tags.status then
      info_parts[#info_parts + 1] = tags.status
    end
    if #info_parts > 0 then
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
      ImGui.Text(ctx, table.concat(info_parts, ' | '))
      ImGui.PopStyleColor(ctx, 1)
    end

    -- Date column (human-readable, tooltip shows full timestamp)
    ImGui.TableSetColumnIndex(ctx, COL_DATE)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
    ImGui.Text(ctx, FormatDateHuman(proj.dateStr))
    ImGui.PopStyleColor(ctx, 1)
    if ImGui.IsItemHovered(ctx) and proj.dateStr ~= '' then
      ImGui.SetTooltip(ctx, proj.dateStr)
    end

    -- Path column
    ImGui.TableSetColumnIndex(ctx, COL_PATH)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
    ImGui.Text(ctx, proj.dir)
    ImGui.PopStyleColor(ctx, 1)
  end

  ImGui.EndTable(ctx)
end

-- ============================================================================
-- UI — GRID / CARD VIEW
-- ============================================================================

local function DrawGridView()
  -- Reserve height for action bar + status bar below
  local avail_w_parent, avail_y = ImGui.GetContentRegionAvail(ctx)
  local list_h = avail_y - 72

  if not ImGui.BeginChild(ctx, 'grid_view', 0, list_h, ImGui.ChildFlags_None, ImGui.WindowFlags_None) then
    return
  end

  local avail_w = ImGui.GetContentRegionAvail(ctx) -- Child's true width (accounts for vertical scrollbar)
  local spacing = S.grid_spacing or 8
  -- Compute card width dynamically from column count to fill available width
  local card_w = math.floor((avail_w - (S.grid_cols - 1) * spacing) / S.grid_cols)
  if card_w < 50 then card_w = 50 end  -- safety minimum
  -- Dynamic text height: count active lines (name always shown)
  local line_h = S.grid_line_h  -- configurable in Settings
  local text_lines = 2  -- project name (2 lines to accommodate wrapping)
  if not S.grid_show_as_tooltip then
    -- Only add field lines when rendering on card (not tooltip mode)
    if S.grid_show_artist then text_lines = text_lines + 1 end
    if S.grid_show_bpm_key then text_lines = text_lines + 1 end
    if S.grid_show_status then text_lines = text_lines + 1 end
    if S.grid_show_album then text_lines = text_lines + 1 end
    if S.grid_show_genre then text_lines = text_lines + 1 end
    if S.grid_show_duration then text_lines = text_lines + 1 end
    if S.grid_show_strings then text_lines = text_lines + 1 end
    if S.grid_show_difficulty then text_lines = text_lines + 1 end
    if S.grid_show_date then text_lines = text_lines + 1 end
    if S.grid_show_tuning then text_lines = text_lines + 1 end
    if S.grid_show_transpose then text_lines = text_lines + 1 end
  end
  local card_text_h = text_lines * line_h + 8  -- lines + padding
  local card_h = card_w + card_text_h

  -- Empty state
  if #S.filtered_projects == 0 then
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
    if S.search_buf ~= '' or S.filter_strings > 1 or S.filter_tuning > 1 or S.filter_status > 1 or S.filter_favs
       or S.filter_tri_meta ~= 0 or S.filter_tri_art ~= 0 or S.filter_tri_tags ~= 0 or S.filter_genre > 1
       or S.filter_exclude_recents or S.filter_include_all or S.show_dedupe ~= 1 then
      ImGui.Text(ctx, 'No projects match your filters.')
    else
      if S.active_tab == 'all' and S.ALL_PROJECTS_PATH == '' and #S.additional_project_paths == 0 then
        ImGui.Text(ctx, 'Scan path not configured — set it in Settings → All Projects')
      else
        ImGui.Text(ctx, S.active_tab == 'all' and 'No projects found.' or 'No recent projects found.')
      end
    end
    ImGui.PopStyleColor(ctx, 1)
    ImGui.EndChild(ctx)
    return
  end

  -- Render cards
  local grid_card_index = 0  -- separate counter for grid column layout (resets after separator)
  for i, proj in ipairs(S.filtered_projects) do
    -- Separator in grid view (universal search or combined view)
    if S.recent_count_in_filtered > 0 and i == S.recent_count_in_filtered + 1 then
      local sep_label = S.filter_include_all and '  Remaining Projects' or '  All Projects'
      -- Force new row for separator
      ImGui.Spacing(ctx)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
      ImGui.Separator(ctx)
      ImGui.Text(ctx, sep_label)
      ImGui.Separator(ctx)
      ImGui.PopStyleColor(ctx, 1)
      ImGui.Spacing(ctx)
      grid_card_index = 0  -- reset column counter after separator
    end

    local col = grid_card_index % S.grid_cols
    grid_card_index = grid_card_index + 1

    if col > 0 then
      ImGui.SameLine(ctx, 0, spacing)
    end

    local is_selected = IsSelected(i)

    ImGui.BeginGroup(ctx)

    -- Selection highlight background
    if is_selected then
      ImGui.PushStyleColor(ctx, ImGui.Col_Button, C.selection)
      ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, C.selection)
      ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive, C.selection)
    else
      ImGui.PushStyleColor(ctx, ImGui.Col_Button, 0x00000000)        -- transparent
      ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, 0x333333AA)
      ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive, C.selection)
    end

    if S.pending_focus_idx == i then
      ImGui.SetKeyboardFocusHere(ctx, 0)
      S.pending_focus_idx = nil
    end

    -- Invisible button covering full card area for click/double-click
    if ImGui.Button(ctx, '##card' .. i, card_w, card_h) then
      if ImGui.IsKeyDown(ctx, ImGui.Key_LeftCtrl) or ImGui.IsKeyDown(ctx, ImGui.Key_RightCtrl) then
        ToggleSelect(i)
      elseif ImGui.IsKeyDown(ctx, ImGui.Key_LeftShift) or ImGui.IsKeyDown(ctx, ImGui.Key_RightShift) then
        local anchor = S.sel_anchor > 0 and S.sel_anchor or 1
        S.selected = {}
        SelectRange(anchor, i)
      else
        SelectOnly(i)
      end
    end
    local card_clicked = ImGui.IsItemHovered(ctx) and ImGui.IsMouseDoubleClicked(ctx, 0)
    if card_clicked then
      ActionOpenProject(proj)
    end
    -- Right-click: auto-select if this card is not already part of the selection
    if ImGui.IsItemClicked(ctx, ImGui.MouseButton_Right) and not IsSelected(i) then
      SelectOnly(i)
    end
    ImGui.PopStyleColor(ctx, 3)

    -- Right-click context menu
    DrawContextMenu(proj, i)

    -- Overlay content on top of the button
    -- Go back to the button's start position
    local item_x, item_y = ImGui.GetItemRectMin(ctx)

    -- Album art (centered within card_w)
    ImGui.SetCursorScreenPos(ctx, item_x, item_y)
    if proj.albumArtPath then
      local img = GetImage(proj.albumArtPath)
      if img then
        ImGui.Image(ctx, img, card_w, card_w)
      else
        DrawArtPlaceholder(proj, card_w)
      end
    else
      DrawArtPlaceholder(proj, card_w)
    end

    -- Favorite star overlay (top-right of art, toggleable via Settings)
    local tags = proj.tags or {}
    if tags.favorite and S.grid_show_favorite then
      ImGui.SetCursorScreenPos(ctx, item_x + card_w - 16, item_y + 2)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.favStar)
      ImGui.Text(ctx, '*')
      ImGui.PopStyleColor(ctx, 1)
    end

    -- Text area below art (dynamic positioning based on active toggles)
    local cur_y = item_y + card_w + 2
    local pad_x = item_x + 4
    local win_x, _ = ImGui.GetWindowPos(ctx)
    local wrap_x = (item_x + card_w - 4) - win_x

    -- Project name (always shown, 2 lines allocated)
    ImGui.SetCursorScreenPos(ctx, pad_x, cur_y)
    ImGui.PushTextWrapPos(ctx, wrap_x)
    local displayName = proj.name
    if not proj.exists then displayName = displayName .. ' [!]' end
    ImGui.Text(ctx, displayName)
    ImGui.PopTextWrapPos(ctx)
    -- Advance by actual rendered height (handles text wrapping properly)
    local _, name_max_y = ImGui.GetItemRectMax(ctx)
    cur_y = name_max_y + 1

    -- Card fields: rendered on card (tooltip OFF) or as hover tooltip (tooltip ON)
    if not S.grid_show_as_tooltip then
      -- Artist (optional)
      if S.grid_show_artist then
        local artist_display = proj.matchedArtist or proj.artist
        if artist_display and artist_display ~= '' then
          ImGui.SetCursorScreenPos(ctx, pad_x, cur_y)
          ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
          ImGui.PushTextWrapPos(ctx, wrap_x)
          ImGui.Text(ctx, artist_display)
          ImGui.PopTextWrapPos(ctx)
          ImGui.PopStyleColor(ctx, 1)
        end
        cur_y = cur_y + line_h
      end

      -- BPM / Key (optional)
      if S.grid_show_bpm_key then
        local meta_parts = {}
        if proj.displayBPM then meta_parts[#meta_parts + 1] = tostring(proj.displayBPM) end
        if proj.displayKey then meta_parts[#meta_parts + 1] = proj.displayKey end
        if #meta_parts > 0 then
          ImGui.SetCursorScreenPos(ctx, pad_x, cur_y)
          ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
          ImGui.Text(ctx, table.concat(meta_parts, ' | '))
          ImGui.PopStyleColor(ctx, 1)
        end
        cur_y = cur_y + line_h
      end

      -- Status badge (optional)
      if S.grid_show_status and tags.status then
        local sc = CFG.STATUS_COLORS[tags.status] or CFG.STATUS_DEFAULT_COLOR
        ImGui.SetCursorScreenPos(ctx, pad_x, cur_y)
        ImGui.PushStyleColor(ctx, ImGui.Col_Text, sc)
        ImGui.Text(ctx, tags.status)
        ImGui.PopStyleColor(ctx, 1)
        cur_y = cur_y + line_h
      end

      -- Album (optional)
      if S.grid_show_album and proj.album then
        ImGui.SetCursorScreenPos(ctx, pad_x, cur_y)
        ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
        ImGui.PushTextWrapPos(ctx, wrap_x)
        ImGui.Text(ctx, proj.album)
        ImGui.PopTextWrapPos(ctx)
        ImGui.PopStyleColor(ctx, 1)
        cur_y = cur_y + line_h
      end

      -- Genre (optional)
      if S.grid_show_genre and tags.genre then
        ImGui.SetCursorScreenPos(ctx, pad_x, cur_y)
        ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
        ImGui.Text(ctx, GenreStr(tags.genre))
        ImGui.PopStyleColor(ctx, 1)
        cur_y = cur_y + line_h
      end

      -- Duration (optional)
      if S.grid_show_duration and proj.duration then
        local mins = math.floor(proj.duration / 60)
        local secs = math.floor(proj.duration % 60)
        ImGui.SetCursorScreenPos(ctx, pad_x, cur_y)
        ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
        ImGui.Text(ctx, string.format('%d:%02d', mins, secs))
        ImGui.PopStyleColor(ctx, 1)
        cur_y = cur_y + line_h
      end

      -- Strings (optional)
      if S.grid_show_strings and tags.strings then
        ImGui.SetCursorScreenPos(ctx, pad_x, cur_y)
        ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
        ImGui.Text(ctx, tags.strings .. '-string')
        ImGui.PopStyleColor(ctx, 1)
        cur_y = cur_y + line_h
      end

      -- Difficulty (optional)
      if S.grid_show_difficulty and tags.difficulty then
        ImGui.SetCursorScreenPos(ctx, pad_x, cur_y)
        ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
        ImGui.Text(ctx, tags.difficulty)
        ImGui.PopStyleColor(ctx, 1)
        cur_y = cur_y + line_h
      end

      -- Date (optional)
      if S.grid_show_date and proj.dateStr and proj.dateStr ~= '' then
        ImGui.SetCursorScreenPos(ctx, pad_x, cur_y)
        ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
        ImGui.Text(ctx, FormatDateHuman(proj.dateStr))
        ImGui.PopStyleColor(ctx, 1)
        cur_y = cur_y + line_h
      end

      -- Tuning (optional)
      if S.grid_show_tuning and tags.tuning and tags.tuning ~= '' then
        ImGui.SetCursorScreenPos(ctx, pad_x, cur_y)
        ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
        ImGui.Text(ctx, tags.tuning)
        ImGui.PopStyleColor(ctx, 1)
        cur_y = cur_y + line_h
      end

      -- Transpose (optional)
      if S.grid_show_transpose and tags.transpose and tags.transpose ~= '' then
        ImGui.SetCursorScreenPos(ctx, pad_x, cur_y)
        ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
        ImGui.Text(ctx, 'T:' .. tags.transpose)
        ImGui.PopStyleColor(ctx, 1)
        cur_y = cur_y + line_h
      end
    end -- not grid_show_as_tooltip

    ImGui.EndGroup(ctx)

    -- Tooltip mode: show selected fields in compact tooltip on hover
    -- Tooltip delay: use HoveredFlags_DelayNormal if delay > 0
    local tooltip_hover_flags = 0
    if S.grid_tooltip_delay > 0 then
      tooltip_hover_flags = ImGui.HoveredFlags_DelayNormal
    end
    if S.grid_show_as_tooltip and ImGui.IsItemHovered(ctx, tooltip_hover_flags) then
      local tip_parts = {}
      -- Row 1: BPM, Key, Strings+Tuning (compact metadata line)
      local meta = {}
      if S.grid_show_bpm_key then
        if proj.displayBPM then meta[#meta + 1] = tostring(proj.displayBPM) .. ' BPM' end
        if proj.displayKey then meta[#meta + 1] = proj.displayKey end
      end
      if S.grid_show_strings and tags.strings then
        local str_txt = tags.strings .. '-string'
        -- Combine tuning with strings when both enabled
        if S.grid_show_tuning and tags.tuning and tags.tuning ~= '' then str_txt = str_txt .. ' ' .. tags.tuning end
        meta[#meta + 1] = str_txt
      elseif S.grid_show_tuning and tags.tuning and tags.tuning ~= '' then
        meta[#meta + 1] = tags.tuning
      end
      if S.grid_show_transpose and tags.transpose and tags.transpose ~= '' then
        meta[#meta + 1] = 'T:' .. tags.transpose
      end
      if #meta > 0 then tip_parts[#tip_parts + 1] = table.concat(meta, '  |  ') end
      -- Row 2: Artist, Album
      local info = {}
      if S.grid_show_artist then
        local a = proj.matchedArtist or proj.artist
        if a and a ~= '' then info[#info + 1] = a end
      end
      if S.grid_show_album and proj.album then info[#info + 1] = proj.album end
      if #info > 0 then tip_parts[#tip_parts + 1] = table.concat(info, '  |  ') end
      -- Row 3: Status, Genre, Difficulty
      local tags_line = {}
      if S.grid_show_status and tags.status then tags_line[#tags_line + 1] = tags.status end
      if S.grid_show_genre and tags.genre then tags_line[#tags_line + 1] = GenreStr(tags.genre) end
      if S.grid_show_difficulty and tags.difficulty then tags_line[#tags_line + 1] = tags.difficulty end
      if #tags_line > 0 then tip_parts[#tip_parts + 1] = table.concat(tags_line, '  |  ') end
      -- Row 4: Duration, Date
      local extra = {}
      if S.grid_show_duration and proj.duration then
        extra[#extra + 1] = string.format('%d:%02d', math.floor(proj.duration / 60), math.floor(proj.duration % 60))
      end
      if S.grid_show_date and proj.dateStr and proj.dateStr ~= '' then
        extra[#extra + 1] = FormatDateHuman(proj.dateStr)
      end
      if #extra > 0 then tip_parts[#tip_parts + 1] = table.concat(extra, '  |  ') end
      if #tip_parts > 0 then
        ImGui.SetTooltip(ctx, table.concat(tip_parts, '\n'))
      end
    end

    -- Scroll to selected card (keyboard navigation)
    if is_selected and (ImGui.IsKeyPressed(ctx, ImGui.Key_UpArrow) or ImGui.IsKeyPressed(ctx, ImGui.Key_DownArrow)
        or ImGui.IsKeyPressed(ctx, ImGui.Key_LeftArrow) or ImGui.IsKeyPressed(ctx, ImGui.Key_RightArrow)) then
      ImGui.SetScrollHereY(ctx)
    end
  end

  ImGui.EndChild(ctx)
end

-- ============================================================================
-- UI — ACTION BAR (buttons + options)
-- ============================================================================

local function DrawActionBar()
  ImGui.Separator(ctx)
  ImGui.Spacing(ctx)

  local proj    = SelectedProject()
  local can_act = proj ~= nil and proj.exists

  -- Left side: action buttons
  if not can_act then ImGui.BeginDisabled(ctx) end

  if ImGui.Button(ctx, 'Open Project', 110, 0) then
    if SelectionCount() > 1 then ActionOpenSelected() else ActionOpenProject(proj) end
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, 'Load in Tab', 100, 0) then ActionLoadInTab(proj) end
  ImGui.SameLine(ctx)

  if not can_act then ImGui.EndDisabled(ctx) end

  if ImGui.Button(ctx, 'New Tab', 75, 0) then ActionNewTab() end
  ImGui.SameLine(ctx)

  if not can_act then ImGui.BeginDisabled(ctx) end
  if ImGui.Button(ctx, 'Explorer', 75, 0) then ActionLocateInExplorer(proj) end
  if not can_act then ImGui.EndDisabled(ctx) end

  -- Font & art size sliders (compact style: reduced height, wider track)
  ImGui.SameLine(ctx, 0, 16)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 4.0, 2.0)   -- shorter height
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_GrabMinSize, 10.0)         -- smaller grab handle
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, 'Font:')
  ImGui.PopStyleColor(ctx, 1)
  ImGui.SameLine(ctx, 0, 4)
  ImGui.SetNextItemWidth(ctx, 100)
  local fs_chg, fs_val = ImGui.SliderInt(ctx, '##font_slider', S.font_size, CFG.MIN_FONT_SIZE, CFG.MAX_FONT_SIZE, '%dpx')
  if fs_chg then
    S.font_size = fs_val
    SaveState()
  end

  ImGui.SameLine(ctx, 0, 12)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
  ImGui.AlignTextToFramePadding(ctx)
  if S.view_mode == 'grid' then
    ImGui.Text(ctx, 'Cols:')
    ImGui.PopStyleColor(ctx, 1)
    ImGui.SameLine(ctx, 0, 4)
    ImGui.SetNextItemWidth(ctx, 100)
    local gc_chg, gc_val = ImGui.SliderInt(ctx, '##cols_slider', S.grid_cols, 2, 10, '%d')
    if gc_chg then
      S.grid_cols = gc_val
      SaveState()
    end
  else
    ImGui.Text(ctx, 'Art:')
    ImGui.PopStyleColor(ctx, 1)
    ImGui.SameLine(ctx, 0, 4)
    ImGui.SetNextItemWidth(ctx, 100)
    local as_chg, as_val = ImGui.SliderInt(ctx, '##art_slider', S.art_size, CFG.MIN_ART_SIZE, CFG.MAX_ART_SIZE, '%dpx')
    if as_chg then
      S.art_size = as_val
      SaveState()
    end
  end
  ImGui.PopStyleVar(ctx, 2)  -- restore FramePadding + GrabMinSize

  -- List/Grid toggle buttons (next to the Art/Card slider)
  ImGui.SameLine(ctx, 0, 12)
  local is_list = (S.view_mode == 'list')
  local is_grid = (S.view_mode == 'grid')
  if is_list then ImGui.PushStyleColor(ctx, ImGui.Col_Button, C.accent) end
  if ImGui.SmallButton(ctx, 'List') then
    S.view_mode = 'list'
    if S.active_tab == 'recent' then S.recent_view_mode = 'list' else S.all_view_mode = 'list' end
    SaveState()
  end
  if is_list then ImGui.PopStyleColor(ctx, 1) end
  ImGui.SameLine(ctx, 0, 2)
  if is_grid then ImGui.PushStyleColor(ctx, ImGui.Col_Button, C.accent) end
  if ImGui.SmallButton(ctx, 'Grid') then
    S.view_mode = 'grid'
    if S.active_tab == 'recent' then S.recent_view_mode = 'grid' else S.all_view_mode = 'grid' end
    SaveState()
  end
  if is_grid then ImGui.PopStyleColor(ctx, 1) end

  -- Right side: Keep open checkbox
  local region_w = ImGui.GetContentRegionAvail(ctx)
  local cursor_x = ImGui.GetCursorPosX(ctx)
  local right_offset = cursor_x + region_w - 150
  if right_offset > cursor_x + 30 then
    ImGui.SameLine(ctx, right_offset)
  else
    ImGui.SameLine(ctx)
  end

  local chg
  chg, S.keep_open  = ImGui.Checkbox(ctx, 'Keep open', S.keep_open)
  if chg then SaveState() end
  if ImGui.IsItemHovered(ctx) then
    ImGui.SetTooltip(ctx, 'Keep window open after opening a project')
  end

end

-- ============================================================================
-- UI — STATUS BAR
-- ============================================================================

local function DrawStatusBar()
  ImGui.Spacing(ctx)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)

  local parts = {}
  parts[#parts + 1] = #S.filtered_projects .. ' projects'
  if S.search_buf ~= '' or S.filter_strings > 1 or S.filter_tuning > 1 or S.filter_status > 1 or S.filter_favs
     or S.filter_tri_meta ~= 0 or S.filter_tri_art ~= 0 or S.filter_tri_tags ~= 0 or S.filter_genre > 1
     or S.filter_exclude_recents or S.filter_include_all or S.show_dedupe ~= 1 then
    local total = (S.active_tab == 'all' and S.all_projects_loaded) and #S.all_projects or #S.recent_projects
    parts[#parts + 1] = '(filtered from ' .. total .. ')'
  end
  if S.recent_count_in_filtered > 0 and #S.filtered_projects > S.recent_count_in_filtered then
    parts[#parts + 1] = '(' .. S.recent_count_in_filtered .. ' recent + ' .. (#S.filtered_projects - S.recent_count_in_filtered) .. ' all)'
  end

  local sel_count = SelectionCount()
  if sel_count > 1 then
    parts[#parts + 1] = '|  ' .. sel_count .. ' selected'
  else
    local proj = SelectedProject()
    if proj then
      parts[#parts + 1] = '|  ' .. proj.name
      if proj.displayBPM then parts[#parts + 1] = tostring(proj.displayBPM) .. ' BPM' end
      if proj.displayKey then parts[#parts + 1] = proj.displayKey end
      local tags = proj.tags or {}
      if tags.tuning then parts[#parts + 1] = tags.tuning end
      if tags.status then parts[#parts + 1] = '[' .. tags.status .. ']' end
    end
  end

  ImGui.Text(ctx, table.concat(parts, ' '))
  ImGui.PopStyleColor(ctx, 1)
end

-- ============================================================================
-- KEYBOARD SHORTCUTS
-- ============================================================================

local function HandleKeys()
  local ctrl_down = ImGui.IsKeyDown(ctx, ImGui.Key_LeftCtrl) or ImGui.IsKeyDown(ctx, ImGui.Key_RightCtrl)

  -- Ctrl+B = close window (works even when search bar has focus)
  if ctrl_down and ImGui.IsKeyPressed(ctx, ImGui.Key_B) then
    S.window_open = false
    return
  end

  -- Ctrl+1/2/3/4 = switch to tab (Recent/All/Settings/Actions)
  if ctrl_down then
    local tab_targets = { 'recent', 'all', 'settings', 'actions' }
    local tab_keys = { ImGui.Key_1, ImGui.Key_2, ImGui.Key_3, ImGui.Key_4 }
    for i = 1, 4 do
      if ImGui.IsKeyPressed(ctx, tab_keys[i]) then
        local target = tab_targets[i]
        if S.active_tab ~= target then
          S.pending_tab = target
        end
        break
      end
    end
  end

  -- Ctrl+Tab = cycle between Recent and All Projects tabs
  if ctrl_down and ImGui.IsKeyPressed(ctx, ImGui.Key_Tab) then
    if S.active_tab == 'recent' then
      S.pending_tab = 'all'
    elseif S.active_tab == 'all' then
      S.pending_tab = 'recent'
    end
  end

  -- F5 = normal refresh (cached), Shift+F5 = hard refresh (re-scan all)
  if ImGui.IsKeyPressed(ctx, ImGui.Key_F5) then
    if ImGui.IsKeyDown(ctx, ImGui.Key_LeftShift) or ImGui.IsKeyDown(ctx, ImGui.Key_RightShift) then
      ActionHardRefresh()
    else
      ActionRefresh()
    end
  end

  -- Shift+Escape or Ctrl+Q: force exit (bypasses persistent mode)
  local shift_held = ImGui.IsKeyDown(ctx, ImGui.Key_LeftShift) or ImGui.IsKeyDown(ctx, ImGui.Key_RightShift)
  local ctrl_held = ImGui.IsKeyDown(ctx, ImGui.Key_LeftCtrl) or ImGui.IsKeyDown(ctx, ImGui.Key_RightCtrl)
  if (shift_held and ImGui.IsKeyPressed(ctx, ImGui.Key_Escape))
  or (ctrl_held and ImGui.IsKeyPressed(ctx, ImGui.Key_Q)) then
    S.force_exit = true
    S.window_open = false
  end

  -- Escape: clear selection first, then close/hide window if setting allows
  if ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) and not shift_held then
    if SelectionCount() > 1 then
      -- Reduce to single selection on primary idx
      S.selected = {}
      if S.selected_idx > 0 then S.selected[S.selected_idx] = true end
    elseif S.close_on_escape then
      S.window_open = false
    end
  end

  -- Enter = open selected (only on project tabs, with a selection, no input active, no popup open)
  local is_project_tab = (S.active_tab == 'recent' or S.active_tab == 'all' or S.active_tab == 'favorites')
  if is_project_tab
     and not ImGui.IsAnyItemActive(ctx)
     and S.selected_idx > 0
     and not ImGui.IsPopupOpen(ctx, '', ImGui.PopupFlags_AnyPopup)
     and ImGui.IsKeyPressed(ctx, ImGui.Key_Enter)
  then
    if SelectionCount() > 1 then ActionOpenSelected()
    else
      local proj = SelectedProject()
      if proj and proj.exists then ActionOpenProject(proj) end
    end
  end

  -- Arrow key navigation (only when no input is active)
  if not ImGui.IsAnyItemActive(ctx) then
    -- Ctrl+A = select all
    if ctrl_down and ImGui.IsKeyPressed(ctx, ImGui.Key_A) then
      S.selected = {}
      for idx = 1, #S.filtered_projects do S.selected[idx] = true end
      if S.selected_idx < 1 and #S.filtered_projects > 0 then S.selected_idx = 1 end
    end

    local new_idx = S.selected_idx
    if S.view_mode == 'grid' then
      -- Grid: left/right = prev/next, up/down = jump by row
      if ImGui.IsKeyPressed(ctx, ImGui.Key_RightArrow) then
        if new_idx < #S.filtered_projects then new_idx = new_idx + 1 end
      end
      if ImGui.IsKeyPressed(ctx, ImGui.Key_LeftArrow) then
        if new_idx > 1 then new_idx = new_idx - 1 end
      end
      if ImGui.IsKeyPressed(ctx, ImGui.Key_DownArrow) then
        new_idx = math.min(new_idx + S.grid_cols, #S.filtered_projects)
      end
      if ImGui.IsKeyPressed(ctx, ImGui.Key_UpArrow) then
        new_idx = math.max(new_idx - S.grid_cols, 1)
      end
    else
      -- List: up/down = prev/next
      if ImGui.IsKeyPressed(ctx, ImGui.Key_DownArrow) then
        if new_idx < #S.filtered_projects then new_idx = new_idx + 1 end
      end
      if ImGui.IsKeyPressed(ctx, ImGui.Key_UpArrow) then
        if new_idx > 1 then new_idx = new_idx - 1 end
      end
    end
    -- Home / End (both modes)
    if ImGui.IsKeyPressed(ctx, ImGui.Key_Home) then new_idx = 1 end
    if ImGui.IsKeyPressed(ctx, ImGui.Key_End) then new_idx = #S.filtered_projects end

    -- Apply arrow-key movement as single select
    if new_idx ~= S.selected_idx then
      SelectOnly(new_idx)
    end

    -- Action-Hold Lock: Force sync Native Nav to script selection during continuous scrolling
    -- This physically chokes ImGui's 60fps engine from drifting ahead of REAPER's 30fps script ticks
    if ImGui.IsKeyDown(ctx, ImGui.Key_DownArrow) or ImGui.IsKeyDown(ctx, ImGui.Key_UpArrow) or
       ImGui.IsKeyDown(ctx, ImGui.Key_LeftArrow) or ImGui.IsKeyDown(ctx, ImGui.Key_RightArrow) then
      S.pending_focus_idx = S.selected_idx
    end

    -- Delete key: remove from recent (with confirmation) — supports bulk
    if ImGui.IsKeyPressed(ctx, ImGui.Key_Delete) then
      if SelectionCount() > 1 then
        -- For bulk: only if on Recent tab
        if S.active_tab == 'recent' then
          S.confirm_remove_proj = S.filtered_projects[S.selected_idx]  -- triggers dialog
        end
      elseif S.selected_idx >= 1 and S.selected_idx <= #S.filtered_projects then
        local proj = S.filtered_projects[S.selected_idx]
        if S.active_tab == 'recent' or proj.isRecent then
          S.confirm_remove_proj = proj
        end
      end
    end
  end
end

-- ============================================================================
-- UI — SETTINGS TAB
-- ============================================================================

local function DrawSettingsTab()
  local _, avail_y = ImGui.GetContentRegionAvail(ctx)

  if ImGui.BeginChild(ctx, 'settings_scroll', -1, avail_y, ImGui.ChildFlags_None) then
    local lbl_w = 200
    local changed = false

    -- == Projects ==
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.accent)
    ImGui.Text(ctx, 'Projects')
    ImGui.PopStyleColor(ctx, 1)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- Scan path (the most important setting for new users)
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Projects Folder:')
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, 'Root folder containing your REAPER projects (.rpp files).\nThe All Projects tab scans this folder recursively.\nLeave blank to use only the Recent tab.')
    end
    ImGui.SameLine(ctx, lbl_w)
    ImGui.SetNextItemWidth(ctx, -1)
    local sp_changed, sp_new = ImGui.InputText(ctx, '##scan_path', S.ALL_PROJECTS_PATH)
    if sp_changed then S.ALL_PROJECTS_PATH = sp_new; changed = true end

    -- Additional project paths
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Additional Paths:')
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, 'Additional folders to scan for projects.\nAll folders are scanned recursively and merged.\nRequires Hard Refresh (Shift+F5) to take effect.')
    end
    ImGui.SameLine(ctx, lbl_w)
    if ImGui.SmallButton(ctx, '+ Add Path##add_path') then
      local rv, folder = reaper.JS_Dialog_BrowseForFolder('Select additional projects folder', '')
      if rv == 1 and folder and folder ~= '' then
        S.additional_project_paths[#S.additional_project_paths + 1] = folder
        changed = true
      end
    end

    -- Display existing additional paths with remove buttons
    local remove_idx = nil
    for i, p in ipairs(S.additional_project_paths) do
      ImGui.SetCursorPosX(ctx, lbl_w)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
      ImGui.Text(ctx, p)
      ImGui.PopStyleColor(ctx, 1)
      ImGui.SameLine(ctx)
      if ImGui.SmallButton(ctx, 'X##rm_path_' .. i) then
        remove_idx = i
      end
    end
    if remove_idx then
      table.remove(S.additional_project_paths, remove_idx)
      changed = true
    end

    ImGui.Spacing(ctx)

    -- Max scan depth
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Max Scan Depth:')
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, 'How many folder levels deep to scan for projects.\nHigher values find more projects but take longer.\nRequires Hard Refresh (Shift+F5) to take effect.')
    end
    ImGui.SameLine(ctx, lbl_w)
    ImGui.SetNextItemWidth(ctx, 200)
    local sd_changed, sd_new = ImGui.SliderInt(ctx, '##scan_depth', S.ALL_SCAN_MAX_DEPTH, 1, 20)
    if sd_changed then S.ALL_SCAN_MAX_DEPTH = sd_new; changed = true end

    ImGui.Spacing(ctx)
    ImGui.Spacing(ctx)

    -- == Display Settings ==
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.accent)
    ImGui.Text(ctx, 'Display Settings')
    ImGui.PopStyleColor(ctx, 1)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- Font size
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Font Size:')
    ImGui.SameLine(ctx, lbl_w)
    ImGui.SetNextItemWidth(ctx, 200)
    local fs_changed, fs_new = ImGui.SliderInt(ctx, '##font_size', S.font_size, CFG.MIN_FONT_SIZE, CFG.MAX_FONT_SIZE)
    if fs_changed then S.font_size = fs_new; changed = true end

    -- Art thumbnail size
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Art Thumbnail Size:')
    ImGui.SameLine(ctx, lbl_w)
    ImGui.SetNextItemWidth(ctx, 200)
    local as_changed, as_new = ImGui.SliderInt(ctx, '##art_size', S.art_size, CFG.MIN_ART_SIZE, CFG.MAX_ART_SIZE)
    if as_changed then S.art_size = as_new; changed = true end

    -- Grid column count
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Grid Columns:')
    ImGui.SameLine(ctx, lbl_w)
    ImGui.SetNextItemWidth(ctx, 200)
    local gcol_changed, gcol_new = ImGui.SliderInt(ctx, '##grid_cols_setting', S.grid_cols, 2, 10)
    if gcol_changed then S.grid_cols = gcol_new; changed = true end
    -- Hidden: grid card size (kept for potential future backend use)
    -- local gcs_changed, gcs_new = ImGui.SliderInt(ctx, '##grid_card_size', S.grid_card_size, CFG.MIN_GRID_CARD_SIZE, CFG.MAX_GRID_CARD_SIZE)
    -- if gcs_changed then S.grid_card_size = gcs_new; changed = true end

    ImGui.Spacing(ctx)

    -- Art placeholder toggle
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Art Placeholders:')
    ImGui.SameLine(ctx, lbl_w)
    local ap_changed, ap_new = ImGui.Checkbox(ctx, 'Show initials for missing art##ap', S.show_art_placeholder)
    if ap_changed then S.show_art_placeholder = ap_new; changed = true end

    if S.show_art_placeholder then
      ImGui.SameLine(ctx)
      local pfn_chg, pfn_new = ImGui.Checkbox(ctx, 'Full name instead of initials##pfn', S.placeholder_full_name)
      if pfn_chg then S.placeholder_full_name = pfn_new; changed = true end
    end

    -- Default artwork
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Default Artwork:')
    if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, 'Fallback image shown when a project has no album art.\nLeave empty to use placeholder initials/name instead.') end
    ImGui.SameLine(ctx, lbl_w)
    ImGui.SetNextItemWidth(ctx, -60)
    local da_chg, da_new = ImGui.InputText(ctx, '##default_artwork_path', S.default_artwork_path)
    if da_chg then S.default_artwork_path = da_new; changed = true end
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, 'Browse##dart') then
      local rv, path = reaper.JS_Dialog_BrowseForOpenFiles('Select Default Artwork', '', '', 'Image files\0*.jpg;*.jpeg;*.png\0All files\0*.*\0', false)
      if rv == 1 and path and path ~= '' then
        S.default_artwork_path = path
        changed = true
      end
    end

    ImGui.Spacing(ctx)

    -- Grid card tooltip mode
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Grid Card Fields:')
    ImGui.SameLine(ctx, lbl_w)
    local gtt_chg, gtt_new = ImGui.Checkbox(ctx, 'Show as Tooltips on Hover##grid_tt', S.grid_show_as_tooltip)
    if gtt_chg then S.grid_show_as_tooltip = gtt_new; changed = true end
    if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, 'ON: selected fields appear in tooltip on hover\nOFF: fields render directly on the card') end

    -- Grid card text fields (row 1)
    ImGui.Text(ctx, '')  -- spacer for alignment
    ImGui.SameLine(ctx, lbl_w)
    local ga_changed, ga_new = ImGui.Checkbox(ctx, 'Artist##grid', S.grid_show_artist)
    if ga_changed then S.grid_show_artist = ga_new; changed = true end
    ImGui.SameLine(ctx)
    local gbk_changed, gbk_new = ImGui.Checkbox(ctx, 'BPM/Key##grid', S.grid_show_bpm_key)
    if gbk_changed then S.grid_show_bpm_key = gbk_new; changed = true end
    ImGui.SameLine(ctx)
    local gs_changed, gs_new = ImGui.Checkbox(ctx, 'Status##grid', S.grid_show_status)
    if gs_changed then S.grid_show_status = gs_new; changed = true end
    ImGui.SameLine(ctx)
    local gfav_chg, gfav_new = ImGui.Checkbox(ctx, 'Fav Star##grid', S.grid_show_favorite)
    if gfav_chg then S.grid_show_favorite = gfav_new; changed = true end
    -- Grid card fields (row 2)
    ImGui.Text(ctx, '')  -- spacer for alignment
    ImGui.SameLine(ctx, lbl_w)
    local gdur_chg, gdur_new = ImGui.Checkbox(ctx, 'Duration##grid', S.grid_show_duration)
    if gdur_chg then S.grid_show_duration = gdur_new; changed = true end
    ImGui.SameLine(ctx)
    local gstr_chg, gstr_new = ImGui.Checkbox(ctx, 'Strings##grid', S.grid_show_strings)
    if gstr_chg then S.grid_show_strings = gstr_new; changed = true end
    ImGui.SameLine(ctx)
    local galb_chg, galb_new = ImGui.Checkbox(ctx, 'Album##grid', S.grid_show_album)
    if galb_chg then S.grid_show_album = galb_new; changed = true end
    ImGui.SameLine(ctx)
    local ggen_chg, ggen_new = ImGui.Checkbox(ctx, 'Genre##grid', S.grid_show_genre)
    if ggen_chg then S.grid_show_genre = ggen_new; changed = true end
    -- Grid card fields (row 3)
    ImGui.Text(ctx, '')
    ImGui.SameLine(ctx, lbl_w)
    local gdif_chg, gdif_new = ImGui.Checkbox(ctx, 'Difficulty##grid', S.grid_show_difficulty)
    if gdif_chg then S.grid_show_difficulty = gdif_new; changed = true end
    ImGui.SameLine(ctx)
    local gdat_chg, gdat_new = ImGui.Checkbox(ctx, 'Date##grid', S.grid_show_date)
    if gdat_chg then S.grid_show_date = gdat_new; changed = true end
    ImGui.SameLine(ctx)
    local gtun_chg, gtun_new = ImGui.Checkbox(ctx, 'Tuning##grid', S.grid_show_tuning)
    if gtun_chg then S.grid_show_tuning = gtun_new; changed = true end
    ImGui.SameLine(ctx)
    local gtp_chg, gtp_new = ImGui.Checkbox(ctx, 'Transpose##grid', S.grid_show_transpose)
    if gtp_chg then S.grid_show_transpose = gtp_new; changed = true end

    -- Grid card spacing
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Grid Card Spacing:')
    ImGui.SameLine(ctx, lbl_w)
    ImGui.SetNextItemWidth(ctx, 200)
    local gsp_changed, gsp_new = ImGui.SliderInt(ctx, '##grid_spacing', S.grid_spacing, 0, 32)
    if gsp_changed then S.grid_spacing = gsp_new; changed = true end
    if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, 'Padding between grid cards (px)') end

    -- Grid tooltip delay
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Grid Tooltip Delay:')
    ImGui.SameLine(ctx, lbl_w)
    ImGui.SetNextItemWidth(ctx, 200)
    local gtd_chg, gtd_new = ImGui.SliderDouble(ctx, '##grid_tooltip_delay', S.grid_tooltip_delay, 0.0, 2.0, '%.1f sec')
    if gtd_chg then S.grid_tooltip_delay = gtd_new; changed = true end
    if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, 'Delay before grid card tooltips appear (0 = instant).\nOnly affects grid card hover tooltips; other tooltips stay instant.') end

    -- Grid card line height
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Grid Text Height:')
    ImGui.SameLine(ctx, lbl_w)
    ImGui.SetNextItemWidth(ctx, 200)
    local glh_changed, glh_new = ImGui.SliderInt(ctx, '##grid_line_h', S.grid_line_h, CFG.MIN_GRID_LINE_H, CFG.MAX_GRID_LINE_H)
    if glh_changed then S.grid_line_h = glh_new; changed = true end
    if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, 'Line height for text under grid cards (px)') end

    -- Primary genres (configurable)
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Primary Genres:')
    ImGui.SameLine(ctx, lbl_w)
    ImGui.SetNextItemWidth(ctx, 350)
    local cpg_chg, cpg_new = ImGui.InputText(ctx, '##custom_primary_genres', S.custom_primary_genres)
    if cpg_chg then S.custom_primary_genres = cpg_new end
    if ImGui.IsItemDeactivatedAfterEdit(ctx) then
      RebuildGenreLists()
      changed = true
    end
    if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, 'Comma-separated list of primary genres.\nUsed in dropdowns, quick-set menus, and genre filter.\nChanges take effect when you leave this field.') end

    -- Custom statuses
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Custom Statuses:')
    ImGui.SameLine(ctx, lbl_w)
    ImGui.SetNextItemWidth(ctx, 350)
    local cst_chg, cst_new = ImGui.InputText(ctx, '##custom_statuses', S.custom_statuses)
    if cst_chg then S.custom_statuses = cst_new end
    if ImGui.IsItemDeactivatedAfterEdit(ctx) then
      RebuildStatusLists()
      changed = true
    end
    if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, 'Comma-separated list of additional custom statuses.\nAppended to the built-in status list.\nLeave empty for built-in statuses only.') end

    ImGui.Spacing(ctx)

    -- Default sort order per tab
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Default Sort (Recent):')
    ImGui.SameLine(ctx, lbl_w)
    ImGui.SetNextItemWidth(ctx, 200)
    if ImGui.BeginCombo(ctx, '##default_sort_recent', CFG.SORT_LABELS[S.default_recent_sort]) then
      for i = 1, #CFG.SORT_LABELS do
        if ImGui.Selectable(ctx, CFG.SORT_LABELS[i], S.default_recent_sort == i) then
          S.default_recent_sort = i
          changed = true
        end
      end
      ImGui.EndCombo(ctx)
    end
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Default Sort (All):')
    ImGui.SameLine(ctx, lbl_w)
    ImGui.SetNextItemWidth(ctx, 200)
    if ImGui.BeginCombo(ctx, '##default_sort_all', CFG.SORT_LABELS[S.default_all_sort]) then
      for i = 1, #CFG.SORT_LABELS do
        if ImGui.Selectable(ctx, CFG.SORT_LABELS[i], S.default_all_sort == i) then
          S.default_all_sort = i
          changed = true
        end
      end
      ImGui.EndCombo(ctx)
    end
    if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, 'Sort order applied on script launch. You can re-sort during a session.') end

    -- Artist sort: group by album
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Artist Sort:')
    ImGui.SameLine(ctx, lbl_w)
    local asa_chg, asa_new = ImGui.Checkbox(ctx, 'Group by album within artist##artist_album', S.artist_sort_by_album)
    if asa_chg then S.artist_sort_by_album = asa_new; changed = true; RefreshFiltered() end

    ImGui.Spacing(ctx)
    ImGui.Spacing(ctx)

    -- == Color Theme ==
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.accent)
    ImGui.Text(ctx, 'Color Theme')
    ImGui.PopStyleColor(ctx, 1)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- Accent color picker (ColorEdit3 uses 0xXXRRGGBB — XX ignored, our S values are 0x00RRGGBB)
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Accent Color:')
    ImGui.SameLine(ctx, lbl_w)
    local ac_changed, ac_new = ImGui.ColorEdit3(ctx, '##accent_color', S.accent_color, ImGui.ColorEditFlags_NoInputs)
    if ac_changed then
      S.accent_color = ac_new
      S.theme_preset = 0  -- custom
      RecomputeTheme()
      changed = true
    end

    -- Theme accent preset buttons
    ImGui.SameLine(ctx, 0, 16)
    for pi, preset in ipairs(THEME_PRESETS) do
      if pi > 1 then ImGui.SameLine(ctx, 0, 4) end
      local is_active = (S.theme_preset == pi)
      if is_active then ImGui.PushStyleColor(ctx, ImGui.Col_Button, C.accent) end
      if ImGui.SmallButton(ctx, preset.name .. '##theme') then
        S.accent_color = preset.accent
        S.theme_preset = pi
        RecomputeTheme()
        changed = true
      end
      if is_active then ImGui.PopStyleColor(ctx, 1) end
    end

    -- Background color picker
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Background:')
    ImGui.SameLine(ctx, lbl_w)
    local bg_changed, bg_new = ImGui.ColorEdit3(ctx, '##bg_color', S.bg_color, ImGui.ColorEditFlags_NoInputs)
    if bg_changed then
      S.bg_color = bg_new
      S.theme_base_preset = 0  -- custom
      RecomputeTheme()
      changed = true
    end
    if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, 'Base background color. All UI surfaces derive from this.') end

    -- Text color picker
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Text Color:')
    ImGui.SameLine(ctx, lbl_w)
    local tx_changed, tx_new = ImGui.ColorEdit3(ctx, '##text_color', S.text_color, ImGui.ColorEditFlags_NoInputs)
    if tx_changed then
      S.text_color = tx_new
      S.theme_base_preset = 0  -- custom
      RecomputeTheme()
      changed = true
    end

    -- Dim text brightness slider
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Dim Text:')
    ImGui.SameLine(ctx, lbl_w)
    ImGui.SetNextItemWidth(ctx, 200)
    local dt_changed, dt_new = ImGui.SliderInt(ctx, '##dim_text_pct', S.dim_text_pct, 50, 100, '%d%%')
    if dt_changed then
      S.dim_text_pct = dt_new
      RecomputeTheme()
      changed = true
    end
    if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, 'Brightness of secondary/dim text as % of main text color.\n50%% = current default, 100%% = same as normal text.') end

    -- Favorite star color picker
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Star Color:')
    ImGui.SameLine(ctx, lbl_w)
    local fsc_changed, fsc_new = ImGui.ColorEdit3(ctx, '##fav_star_color', S.fav_star_color, ImGui.ColorEditFlags_NoInputs)
    if fsc_changed then
      S.fav_star_color = fsc_new
      RecomputeTheme()
      changed = true
    end

    -- Reset Colors button
    ImGui.SameLine(ctx, 0, 24)
    if ImGui.SmallButton(ctx, 'Reset Colors') then
      S.accent_color = 0x4A8FB8; S.theme_preset = 1
      S.bg_color = 0x1B1B1B; S.text_color = 0xDCDCDC
      S.fav_star_color = 0xE8C84D; S.dim_text_pct = 50
      S.theme_base_preset = 1
      RecomputeTheme()
      changed = true
    end

    ImGui.Spacing(ctx)
    ImGui.Spacing(ctx)

    -- == Appearance ==
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.accent)
    ImGui.Text(ctx, 'Appearance')
    ImGui.PopStyleColor(ctx, 1)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- Window opacity slider (stored as float 0.3-1.0, displayed as int 30-100%)
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Window Opacity:')
    ImGui.SameLine(ctx, lbl_w)
    ImGui.SetNextItemWidth(ctx, 200)
    local wo_int = math.floor(S.window_opacity * 100 + 0.5)
    local wo_changed, wo_new = ImGui.SliderInt(ctx, '##window_opacity', wo_int, 30, 100, '%d%%')
    if wo_changed then S.window_opacity = wo_new / 100; changed = true end
    if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, 'Window background transparency.\n100%% = fully opaque, lower = see through to REAPER.') end

    -- Corner rounding slider
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Corner Rounding:')
    ImGui.SameLine(ctx, lbl_w)
    ImGui.SetNextItemWidth(ctx, 200)
    local cr_changed, cr_new = ImGui.SliderInt(ctx, '##corner_rounding', S.corner_rounding, 0, 12, '%dpx')
    if cr_changed then S.corner_rounding = cr_new; changed = true end
    if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, '0 = sharp corners, 12 = very rounded.') end

    -- Density slider
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Density:')
    ImGui.SameLine(ctx, lbl_w)
    ImGui.SetNextItemWidth(ctx, 200)
    local dn_changed, dn_new = ImGui.SliderInt(ctx, '##density', S.density, 0, 100)
    if dn_changed then S.density = dn_new; changed = true end
    if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, 'UI spacing density.\n0 = compact (tighter), 50 = normal, 100 = spacious.') end

    -- Fade-in duration slider
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Fade-in:')
    ImGui.SameLine(ctx, lbl_w)
    ImGui.SetNextItemWidth(ctx, 200)
    local fi_changed, fi_new = ImGui.SliderDouble(ctx, '##fade_in_duration', S.fade_in_duration, 0.0, 0.5, '%.2fs')
    if fi_changed then S.fade_in_duration = fi_new; changed = true end
    if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, 'Window fade-in animation duration.\n0 = instant (no animation), 0.15 = subtle, 0.5 = slow.') end

    -- Border visibility toggle
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Borders:')
    ImGui.SameLine(ctx, lbl_w)
    local brd_changed, brd_new = ImGui.Checkbox(ctx, 'Show borders and separators##borders', S.show_borders)
    if brd_changed then
      S.show_borders = brd_new
      RecomputeTheme()
      changed = true
    end

    -- Alternating row bg toggle
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Row Stripes:')
    ImGui.SameLine(ctx, lbl_w)
    local arb_changed, arb_new = ImGui.Checkbox(ctx, 'Alternating row backgrounds##alt_row', S.alt_row_bg)
    if arb_changed then
      S.alt_row_bg = arb_new
      RecomputeTheme()
      changed = true
    end

    -- Theme base presets
    ImGui.Spacing(ctx)
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Theme Presets:')
    ImGui.SameLine(ctx, lbl_w)
    for tpi, tpreset in ipairs(THEME_BASE_PRESETS) do
      if tpi > 1 then ImGui.SameLine(ctx, 0, 4) end
      local is_tp_active = (S.theme_base_preset == tpi)
      if is_tp_active then ImGui.PushStyleColor(ctx, ImGui.Col_Button, C.accent) end
      if ImGui.SmallButton(ctx, tpreset.name .. '##tbase') then
        S.bg_color = tpreset.bg
        S.text_color = tpreset.text
        S.accent_color = tpreset.accent
        S.corner_rounding = tpreset.rounding
        S.density = tpreset.density
        S.theme_base_preset = tpi
        S.theme_preset = 0  -- reset accent preset label
        RecomputeTheme()
        changed = true
      end
      if is_tp_active then ImGui.PopStyleColor(ctx, 1) end
    end

    -- Reset Appearance button
    ImGui.SameLine(ctx, 0, 16)
    if ImGui.SmallButton(ctx, 'Reset Appearance') then
      S.window_opacity = 1.0; S.corner_rounding = 4; S.density = 50
      S.show_borders = true; S.alt_row_bg = true
      RecomputeTheme()
      changed = true
    end

    -- Custom theme slots (Save/Load up to 3)
    ImGui.Spacing(ctx)
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Custom Themes:')
    ImGui.SameLine(ctx, lbl_w)
    for slot = 1, 3 do
      if slot > 1 then ImGui.SameLine(ctx, 0, 4) end
      local slot_key = 'custom_theme_' .. slot
      local has_saved = (reaper.GetExtState(CFG.EXT_SECTION, slot_key) ~= '')
      -- Load button
      if not has_saved then ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDisabled) end
      if ImGui.SmallButton(ctx, slot .. '##load_theme') and has_saved then
        local data = reaper.GetExtState(CFG.EXT_SECTION, slot_key)
        local vals = {}
        for v in data:gmatch('[^|]+') do vals[#vals+1] = v end
        if #vals >= 10 then
          S.bg_color = tonumber(vals[1]) or S.bg_color
          S.text_color = tonumber(vals[2]) or S.text_color
          S.accent_color = tonumber(vals[3]) or S.accent_color
          S.fav_star_color = tonumber(vals[4]) or S.fav_star_color
          S.dim_text_pct = tonumber(vals[5]) or S.dim_text_pct
          S.window_opacity = tonumber(vals[6]) or S.window_opacity
          S.corner_rounding = tonumber(vals[7]) or S.corner_rounding
          S.density = tonumber(vals[8]) or S.density
          S.show_borders = (vals[9] == '1')
          S.alt_row_bg = (vals[10] == '1')
          S.theme_preset = 0; S.theme_base_preset = 0
          RecomputeTheme()
          changed = true
        end
      end
      if not has_saved then ImGui.PopStyleColor(ctx, 1) end
      if ImGui.IsItemHovered(ctx) then
        ImGui.SetTooltip(ctx, has_saved and ('Load Custom Theme ' .. slot .. '\nRight-click to overwrite') or ('Slot ' .. slot .. ' (empty)\nRight-click to save current theme'))
      end
      -- Save on right-click
      if ImGui.IsItemClicked(ctx, ImGui.MouseButton_Right) then
        local data = table.concat({
          S.bg_color, S.text_color, S.accent_color, S.fav_star_color,
          S.dim_text_pct, string.format('%.2f', S.window_opacity),
          S.corner_rounding, S.density,
          S.show_borders and '1' or '0', S.alt_row_bg and '1' or '0'
        }, '|')
        reaper.SetExtState(CFG.EXT_SECTION, slot_key, data, true)
      end
    end
    if ImGui.IsItemHovered(ctx) then end  -- tooltip handled above per-button
    ImGui.SameLine(ctx, 0, 8)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
    ImGui.Text(ctx, '(click=load, right-click=save)')
    ImGui.PopStyleColor(ctx, 1)

    ImGui.Spacing(ctx)
    ImGui.Spacing(ctx)

    -- == Behavior ==
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.accent)
    ImGui.Text(ctx, 'Behavior')
    ImGui.PopStyleColor(ctx, 1)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- Keep window open after launch
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Keep Open:')
    ImGui.SameLine(ctx, lbl_w)
    local kop_changed, kop_new = ImGui.Checkbox(ctx, 'Keep window open after launching project##kop', S.keep_open)
    if kop_changed then S.keep_open = kop_new; changed = true end

    -- Persistent mode
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Persistent Mode:')
    ImGui.SameLine(ctx, lbl_w)
    local pm_chg, pm_new = ImGui.Checkbox(ctx, 'Keep running in background for instant re-open##pm', S.persistent_mode)
    if pm_chg then S.persistent_mode = pm_new; changed = true end

    -- Close on new instance
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Close on New Instance:')
    ImGui.SameLine(ctx, lbl_w)
    local coni_chg, coni_new = ImGui.Checkbox(ctx, 'Re-triggering action closes/hides the window##coni', S.close_on_new_instance)
    if coni_chg then
      S.close_on_new_instance = coni_new
      -- Update session ExtState so the guard can read it immediately
      reaper.SetExtState(RD_EXT, 'close_on_new_instance', coni_new and '1' or '0', false)
      changed = true
    end

    -- Close on unfocus
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Close on Unfocus:')
    ImGui.SameLine(ctx, lbl_w)
    local cou_chg, cou_new = ImGui.Checkbox(ctx, 'Close/hide when clicking outside the window##cou', S.close_on_unfocus)
    if cou_chg then
      S.close_on_unfocus = cou_new
      if not cou_new then S.had_focus = false end  -- reset guard when disabling
      changed = true
    end

    -- Close on Escape
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Close on Escape:')
    ImGui.SameLine(ctx, lbl_w)
    local coe_chg, coe_new = ImGui.Checkbox(ctx, 'Escape key closes/hides the window##coe', S.close_on_escape)
    if coe_chg then S.close_on_escape = coe_new; changed = true end

    -- Auto-focus search bar
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Auto-Focus Search:')
    ImGui.SameLine(ctx, lbl_w)
    local afs_chg, afs_new = ImGui.Checkbox(ctx, 'Focus search bar on script open##afs', S.auto_focus_search)
    if afs_chg then S.auto_focus_search = afs_new; changed = true end

    ImGui.Spacing(ctx)
    ImGui.Spacing(ctx)

    -- == Search & Filter ==
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.accent)
    ImGui.Text(ctx, 'Search & Filter')
    ImGui.PopStyleColor(ctx, 1)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- Universal search toggle
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Universal Search:')
    ImGui.SameLine(ctx, lbl_w)
    local us_changed, us_new = ImGui.Checkbox(ctx, 'Search across all tabs##us', S.universal_search)
    if us_changed then S.universal_search = us_new; RefreshFiltered(); changed = true end

    -- Search history toggle
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Search History:')
    ImGui.SameLine(ctx, lbl_w)
    local she_changed, she_new = ImGui.Checkbox(ctx, 'Remember recent searches##she', S.search_history_enabled)
    if she_changed then S.search_history_enabled = she_new; changed = true end
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, 'Shows last 3 searches via dropdown button (H) next to search bar.\nUp/Down arrows in search bar cycle through history.')
    end

    -- Default sort for Recent
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Default Sort (Recent):')
    ImGui.SameLine(ctx, lbl_w)
    ImGui.SetNextItemWidth(ctx, 150)
    if ImGui.BeginCombo(ctx, '##def_sort_recent', CFG.SORT_LABELS[S.recent_sort_mode]) then
      for i = 1, #CFG.SORT_LABELS do
        if ImGui.Selectable(ctx, CFG.SORT_LABELS[i] .. '##dsr' .. i, S.recent_sort_mode == i) then
          S.recent_sort_mode = i
          if S.active_tab == 'recent' then S.sort_mode = i; RefreshFiltered() end
          changed = true
        end
      end
      ImGui.EndCombo(ctx)
    end

    -- Default sort for All Projects
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Default Sort (All):')
    ImGui.SameLine(ctx, lbl_w)
    ImGui.SetNextItemWidth(ctx, 150)
    if ImGui.BeginCombo(ctx, '##def_sort_all', CFG.SORT_LABELS[S.all_sort_mode]) then
      for i = 1, #CFG.SORT_LABELS do
        if ImGui.Selectable(ctx, CFG.SORT_LABELS[i] .. '##dsa' .. i, S.all_sort_mode == i) then
          S.all_sort_mode = i
          if S.active_tab == 'all' then S.sort_mode = i; RefreshFiltered() end
          changed = true
        end
      end
      ImGui.EndCombo(ctx)
    end

    ImGui.Spacing(ctx)
    ImGui.Spacing(ctx)

    -- == Filtering ==
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.accent)
    ImGui.Text(ctx, 'Filtering')
    ImGui.PopStyleColor(ctx, 1)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- Show Main Project Only (Dedupe)
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Dedupe:')
    ImGui.SameLine(ctx, lbl_w)
    -- Tri-state button matching filter bar style
    local dedupe_s_icons = { [0] = '\u{2713}', [1] = '\u{25FB}', [2] = '\u{2717}' }
    local dedupe_s_labels = { [0] = 'ON — hiding variants', [1] = 'OFF — showing all', [2] = 'Showing only variants' }
    local dedupe_s_clr = { [0] = 0x4DB870FF, [1] = C.textDim, [2] = 0xB84D4DFF }
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, dedupe_s_clr[S.show_dedupe])
    if ImGui.SmallButton(ctx, dedupe_s_icons[S.show_dedupe] .. ' ' .. dedupe_s_labels[S.show_dedupe] .. '##dedupe_settings_tri') then
      S.show_dedupe = (S.show_dedupe + 1) % 3
      RefreshFiltered()
      changed = true
    end
    ImGui.PopStyleColor(ctx, 1)
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, 'Show Main Project Only (Dedupe)\n\nHides duplicate/variant projects per folder.\nClick to cycle: Hide variants → Show all → Show only variants')
    end

    -- Dedupe mode selector (Standard / Aggressive)
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Dedupe Mode:')
    ImGui.SameLine(ctx, lbl_w)
    local is_standard = (S.dedupe_mode == 'standard')
    if ImGui.RadioButton(ctx, 'Standard', is_standard) then
      if not is_standard then S.dedupe_mode = 'standard'; RefreshFiltered(); changed = true end
    end
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, 'Standard: Collapse only REAPER auto-copies (_1, _2, _001, etc.)\nwithin the same folder. Predictable, no guessing.\nMost recently modified file wins per group.')
    end
    ImGui.SameLine(ctx)
    if ImGui.RadioButton(ctx, 'Aggressive', not is_standard) then
      if is_standard then S.dedupe_mode = 'aggressive'; RefreshFiltered(); changed = true end
    end
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, 'Aggressive: Per folder, only the most recently modified\n.rpp file is shown. Maximum deduplication.\nFlat/collection folders may collapse to 1 entry — use whitelist.')
    end

    -- Dedupe: variant list (only show when dedupe is active and variants exist)
    if S.show_dedupe ~= 1 and #S.dedupe_variants > 0 then
      local total_filtered = 0
      for _, vg in ipairs(S.dedupe_variants) do
        total_filtered = total_filtered + #vg.filtered
      end

      -- Copy Variants button
      ImGui.Text(ctx, '')
      ImGui.SameLine(ctx, lbl_w)
      if ImGui.SmallButton(ctx, 'Copy Variants (' .. total_filtered .. ')') then
        local lines = {}
        for _, vg in ipairs(S.dedupe_variants) do
          lines[#lines + 1] = '## ' .. vg.main
          for _, v in ipairs(vg.filtered) do
            lines[#lines + 1] = '  - ' .. v.name
          end
        end
        local text = table.concat(lines, '\n')
        if reaper.CF_SetClipboard then
          reaper.CF_SetClipboard(text)
        end
      end
      if ImGui.IsItemHovered(ctx) then
        ImGui.SetTooltip(ctx, 'Copy list of all filtered-out variant projects to clipboard')
      end

      -- Collapsible variant list with per-item Keep button
      if ImGui.TreeNode(ctx, 'Filtered Variants (' .. total_filtered .. ')##variant_list') then
        for _, vg in ipairs(S.dedupe_variants) do
          ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.accent)
          ImGui.Text(ctx, vg.main)
          ImGui.PopStyleColor(ctx, 1)
          for _, v in ipairs(vg.filtered) do
            ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
            ImGui.Text(ctx, '  ' .. v.name)
            ImGui.PopStyleColor(ctx, 1)
            if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, v.path) end
            ImGui.SameLine(ctx)
            if ImGui.SmallButton(ctx, 'Keep##' .. v.path) then
              S.whitelist[v.path] = true
              SaveWhitelist()
              RefreshFiltered()
              changed = true
            end
            if ImGui.IsItemHovered(ctx) then
              ImGui.SetTooltip(ctx, 'Whitelist this variant so it always shows')
            end
          end
        end
        ImGui.TreePop(ctx)
      end

      -- Whitelisted projects list with Remove button
      local wl_count = 0
      for _ in pairs(S.whitelist) do wl_count = wl_count + 1 end
      if wl_count > 0 then
        if ImGui.TreeNode(ctx, 'Whitelisted Projects (' .. wl_count .. ')##whitelist_list') then
          local paths_to_remove = {}
          for path, _ in pairs(S.whitelist) do
            local name = path:match('[/\\]([^/\\]+)$') or path
            ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
            ImGui.Text(ctx, name)
            ImGui.PopStyleColor(ctx, 1)
            if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, path) end
            ImGui.SameLine(ctx)
            if ImGui.SmallButton(ctx, 'Remove##wl_' .. path) then
              paths_to_remove[#paths_to_remove + 1] = path
            end
          end
          if #paths_to_remove > 0 then
            for _, path in ipairs(paths_to_remove) do
              S.whitelist[path] = nil
            end
            SaveWhitelist()
            RefreshFiltered()
            changed = true
          end
          ImGui.TreePop(ctx)
        end
      end
    end

    -- Exclusion patterns
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Exclusion Patterns:')
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, 'One pattern per line. Case-insensitive match against full path.\n\nPlain text = substring match (matches anywhere in path).\nUse * (any chars) and ? (one char) for glob patterns.\n\nTip: Use a leading space for word suffixes to avoid\nfalse matches (e.g. " old" won\'t match "gold").\n\nExamples:\n  demo         — hides any path containing "demo"\n  " old"       — hides paths with " old" (not "bold")\n  */drafts/*   — hides projects in "drafts" folders\n  *.bak        — hides .bak files')
    end
    ImGui.SetNextItemWidth(ctx, -1)
    local ep_changed, ep_new = ImGui.InputTextMultiline(ctx, '##exclusion_patterns', S.exclusion_patterns, -1, 80)
    if ep_changed then S.exclusion_patterns = ep_new; RefreshFiltered(); changed = true end

    -- Excluded projects list (only show when patterns are active and projects were excluded)
    if #S.excluded_projects > 0 then
      if ImGui.TreeNode(ctx, 'Excluded Projects (' .. #S.excluded_projects .. ')##excluded_list') then
        for _, ep in ipairs(S.excluded_projects) do
          ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
          ImGui.Text(ctx, ep.name)
          ImGui.PopStyleColor(ctx, 1)
          if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, ep.path) end
          ImGui.SameLine(ctx)
          if ImGui.SmallButton(ctx, 'Keep##excl_' .. ep.path) then
            S.whitelist[ep.path] = true
            SaveWhitelist()
            RefreshFiltered()
            changed = true
          end
          if ImGui.IsItemHovered(ctx) then
            ImGui.SetTooltip(ctx, 'Whitelist this project so it always shows')
          end
        end
        ImGui.TreePop(ctx)
      end
    end

    ImGui.Spacing(ctx)

    -- Hidden projects
    local hidden_count = 0
    for _ in pairs(S.hidden_projects) do hidden_count = hidden_count + 1 end
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Hidden Projects:')
    ImGui.SameLine(ctx, lbl_w)
    local shv_labels = { [0] = 'Hidden (default)', [1] = 'Show All', [2] = 'Only Hidden' }
    if ImGui.SmallButton(ctx, shv_labels[S.show_hidden] .. ' (' .. hidden_count .. ')##shv') then
      S.show_hidden = (S.show_hidden + 1) % 3
      RefreshFiltered(); changed = true
    end
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, 'Cycle: Hide Hidden -> Show All -> Show Only Hidden\nCurrently: ' .. shv_labels[S.show_hidden])
    end
    if hidden_count > 0 then
      ImGui.SameLine(ctx)
      if ImGui.SmallButton(ctx, 'Clear All Hidden') then
        S.hidden_projects = {}
        RefreshFiltered()
        changed = true
      end
    end

    -- Collapsible list of hidden projects with per-item Unhide buttons
    if hidden_count > 0 then
      if ImGui.TreeNode(ctx, 'View Hidden Projects (' .. hidden_count .. ')##hidden_list') then
        local paths_to_unhide = {}
        for path, _ in pairs(S.hidden_projects) do
          -- Extract just the filename for display
          local name = path:match('[/\\]([^/\\]+)$') or path
          ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
          ImGui.Text(ctx, name)
          ImGui.PopStyleColor(ctx, 1)
          if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, path) end
          ImGui.SameLine(ctx)
          if ImGui.SmallButton(ctx, 'Unhide##' .. path) then
            paths_to_unhide[#paths_to_unhide + 1] = path
          end
        end
        -- Apply unhides after iteration (avoid modifying table during iteration)
        if #paths_to_unhide > 0 then
          for _, path in ipairs(paths_to_unhide) do
            S.hidden_projects[path] = nil
            local alt = GetAlternatePath(path)
            if alt then S.hidden_projects[alt] = nil end
          end
          SaveHidden()
          RefreshFiltered()
          changed = true
        end
        ImGui.TreePop(ctx)
      end
    end

    ImGui.Spacing(ctx)
    ImGui.Spacing(ctx)

    -- == Performance & Debug ==
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.accent)
    ImGui.Text(ctx, 'Performance & Debug')
    ImGui.PopStyleColor(ctx, 1)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- Image batch size (hidden: now using time-budgeted loading instead)
    -- ImGui.AlignTextToFramePadding(ctx)
    -- ImGui.Text(ctx, 'Image Batch Size:')
    -- ImGui.SameLine(ctx, lbl_w)
    -- ImGui.SetNextItemWidth(ctx, 200)
    -- local ib_changed, ib_new = ImGui.SliderInt(ctx, '##img_batch', S.IMAGE_BATCH_SIZE, 1, 20)
    -- if ib_changed then S.IMAGE_BATCH_SIZE = ib_new; changed = true end
    -- if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, 'Images loaded per frame during startup.\nHigher = faster loading, lower = smoother UI.') end

    -- Image loading budgets (text inputs)
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'First Frame Budget:')
    if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, 'Time budget (ms) for image loading on first frame.\nHigher = more images loaded before window shows, but slower startup.\nDefault: 32') end
    ImGui.SameLine(ctx, lbl_w)
    ImGui.SetNextItemWidth(ctx, 80)
    local iff_chg, iff_new = ImGui.InputText(ctx, '##img_first_frame_ms', tostring(S.img_first_frame_ms))
    if ImGui.IsItemDeactivatedAfterEdit(ctx) then
      local v = tonumber(iff_new)
      if v then S.img_first_frame_ms = math.max(4, math.min(500, math.floor(v))) end
      changed = true
    end
    ImGui.SameLine(ctx)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
    ImGui.Text(ctx, 'ms')
    ImGui.PopStyleColor(ctx, 1)

    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Per Frame Budget:')
    if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, 'Time budget (ms) for image loading on each subsequent frame.\nHigher = faster image pop-in, but may cause micro-stutters.\nDefault: 16') end
    ImGui.SameLine(ctx, lbl_w)
    ImGui.SetNextItemWidth(ctx, 80)
    local ipf_chg, ipf_new = ImGui.InputText(ctx, '##img_per_frame_ms', tostring(S.img_per_frame_ms))
    if ImGui.IsItemDeactivatedAfterEdit(ctx) then
      local v = tonumber(ipf_new)
      if v then S.img_per_frame_ms = math.max(4, math.min(200, math.floor(v))) end
      changed = true
    end
    ImGui.SameLine(ctx)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
    ImGui.Text(ctx, 'ms')
    ImGui.PopStyleColor(ctx, 1)

    ImGui.Spacing(ctx)

    -- Debug logging
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Debug Logging:')
    ImGui.SameLine(ctx, lbl_w)
    local dl_changed, dl_new = ImGui.Checkbox(ctx, 'Write to ReaDashboard-debug.log##dbg', S.debug_logging)
    if dl_changed then S.debug_logging = dl_new; changed = true end

    ImGui.Spacing(ctx)
    ImGui.Spacing(ctx)

    -- == Advanced (Integrations) ==
    -- Collapsed by default - only power users need these settings.
    if ImGui.TreeNode(ctx, 'Advanced (Integrations)##adv_integrations') then
      ImGui.Spacing(ctx)

      ImGui.AlignTextToFramePadding(ctx)
      ImGui.Text(ctx, 'Enable Spicetify:')
      if ImGui.IsItemHovered(ctx) then
        ImGui.SetTooltip(ctx, 'Enable Spicetify metadata and album art lookup.\nRequires a local Spicetify database (from SyncLyrics or similar).\nMost users do not need this.')
      end
      ImGui.SameLine(ctx, lbl_w)
      local es_chg, es_new = ImGui.Checkbox(ctx, '##enable_spicetify', S.enable_spicetify)
      if es_chg then S.enable_spicetify = es_new; changed = true end

      if S.enable_spicetify then
        ImGui.AlignTextToFramePadding(ctx)
        ImGui.Text(ctx, 'Spicetify DB Path:')
        if ImGui.IsItemHovered(ctx) then
          ImGui.SetTooltip(ctx, 'Path to the Spicetify metadata database folder.\nContains JSON files with song metadata (BPM, key, etc.).')
        end
        ImGui.SameLine(ctx, lbl_w)
        ImGui.SetNextItemWidth(ctx, -1)
        local sdb_changed, sdb_new = ImGui.InputText(ctx, '##spicetify_db_path', S.spicetify_db_path)
        if sdb_changed then S.spicetify_db_path = sdb_new; changed = true end

        ImGui.AlignTextToFramePadding(ctx)
        ImGui.Text(ctx, 'Album Art DB Path:')
        if ImGui.IsItemHovered(ctx) then
          ImGui.SetTooltip(ctx, 'Path to the album art database folder.\nContains artist/album subfolders with cover images.')
        end
        ImGui.SameLine(ctx, lbl_w)
        ImGui.SetNextItemWidth(ctx, -1)
        local adb_changed, adb_new = ImGui.InputText(ctx, '##album_art_db_path', S.album_art_db_path)
        if adb_changed then S.album_art_db_path = adb_new; changed = true end
      end

      ImGui.Spacing(ctx)

      ImGui.AlignTextToFramePadding(ctx)
      ImGui.Text(ctx, 'Path Alias A:')
      if ImGui.IsItemHovered(ctx) then
        ImGui.SetTooltip(ctx, 'Canonical path for path deduplication only.\nIf your projects folder is accessible via two different paths\n(e.g., a symlink, junction, or mapped drive),\nenter the primary path here and the alternate path below.\nLeave both blank if you don\'t use symlinks.')
      end
      ImGui.SameLine(ctx, lbl_w)
      ImGui.SetNextItemWidth(ctx, -1)
      local src_changed, src_new = ImGui.InputText(ctx, '##symlink_src', S.symlink_src)
      if src_changed then S.symlink_src = src_new; changed = true end

      ImGui.AlignTextToFramePadding(ctx)
      ImGui.Text(ctx, 'Path Alias B:')
      if ImGui.IsItemHovered(ctx) then
        ImGui.SetTooltip(ctx, 'The alternate path pointing to the same physical folder.\nProjects found under either path will be treated as the same\nto prevent duplicate entries.')
      end
      ImGui.SameLine(ctx, lbl_w)
      ImGui.SetNextItemWidth(ctx, -1)
      local dst_changed, dst_new = ImGui.InputText(ctx, '##symlink_dest', S.symlink_dest)
      if dst_changed then S.symlink_dest = dst_new; changed = true end

      ImGui.TreePop(ctx)
    end

    ImGui.Spacing(ctx)
    ImGui.Spacing(ctx)

    -- == Project Statistics ==
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.accent)
    ImGui.Text(ctx, 'Project Statistics')
    ImGui.PopStyleColor(ctx, 1)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- Gather stats from whichever source is most complete
    local stat_list = (S.all_projects_loaded and #S.all_projects > 0) and S.all_projects or S.recent_projects
    local total = #stat_list
    if total > 0 and ImGui.TreeNode(ctx, 'Statistics (' .. total .. ' projects)##stats') then
      -- Count coverage
      local n_meta, n_art, n_tags, n_fav = 0, 0, 0, 0
      -- Distribution tables
      local tuning_dist, status_dist, strings_dist, genre_dist = {}, {}, {}, {}
      local bpm_sum, bpm_count = 0, 0

      for _, p in ipairs(stat_list) do
        local tags = p.tags or {}
        -- Coverage
        local has_meta = (p.matchedArtist and p.matchedArtist ~= '')
                      or (p.album and p.album ~= '')
                      or (tags.artistOverride and tags.artistOverride ~= '')
                      or (tags.albumOverride and tags.albumOverride ~= '')
        local has_art = (p.albumArtPath and p.albumArtPath ~= '')
        local has_tags = false
        for k, v in pairs(tags) do
          if v and v ~= '' and v ~= false then has_tags = true; break end
        end
        if has_meta then n_meta = n_meta + 1 end
        if has_art then n_art = n_art + 1 end
        if has_tags then n_tags = n_tags + 1 end
        if tags.favorite then n_fav = n_fav + 1 end

        -- BPM average
        if p.displayBPM then bpm_sum = bpm_sum + p.displayBPM; bpm_count = bpm_count + 1 end

        -- Distributions
        local str_n = tonumber(tags.strings)
        if str_n then strings_dist[str_n] = (strings_dist[str_n] or 0) + 1 end
        if tags.tuning and tags.tuning ~= '' then tuning_dist[tags.tuning] = (tuning_dist[tags.tuning] or 0) + 1 end
        if tags.status and tags.status ~= '' then status_dist[tags.status] = (status_dist[tags.status] or 0) + 1 end
        local g = tags.genre
        if g then
          if type(g) == 'table' then
            for _, genre in ipairs(g) do genre_dist[genre] = (genre_dist[genre] or 0) + 1 end
          elseif g ~= '' then
            genre_dist[g] = (genre_dist[g] or 0) + 1
          end
        end
      end

      -- Coverage bars
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
      ImGui.Text(ctx, 'Coverage')
      ImGui.PopStyleColor(ctx, 1)

      local bar_w = 200
      local function CoverageBar(label, count)
        local frac = count / total
        ImGui.Text(ctx, string.format('  %-12s', label))
        ImGui.SameLine(ctx, 120)
        ImGui.ProgressBar(ctx, frac, bar_w, 0, string.format('%d / %d  (%.0f%%)', count, total, frac * 100))
      end
      CoverageBar('Metadata', n_meta)
      CoverageBar('Album Art', n_art)
      CoverageBar('Tags', n_tags)
      CoverageBar('Favorites', n_fav)
      ImGui.Spacing(ctx)

      -- Summary line
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
      if bpm_count > 0 then
        ImGui.Text(ctx, string.format('  Average BPM: %.0f  (%d projects with BPM)', bpm_sum / bpm_count, bpm_count))
      end
      ImGui.PopStyleColor(ctx, 1)
      ImGui.Spacing(ctx)

      -- Helper to draw distribution sections
      local function DrawDist(title, dist, color_map)
        -- Sort by count descending
        local sorted = {}
        for k, v in pairs(dist) do sorted[#sorted + 1] = { key = k, count = v } end
        if #sorted == 0 then return end
        table.sort(sorted, function(a, b) return a.count > b.count end)

        ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
        ImGui.Text(ctx, title)
        ImGui.PopStyleColor(ctx, 1)
        for _, item in ipairs(sorted) do
          local col = color_map and color_map[item.key]
          if col then ImGui.PushStyleColor(ctx, ImGui.Col_Text, col) end
          ImGui.Text(ctx, string.format('  %-20s', item.key))
          if col then ImGui.PopStyleColor(ctx, 1) end
          ImGui.SameLine(ctx, 180)
          ImGui.ProgressBar(ctx, item.count / total, 140, 0, tostring(item.count))
        end
        ImGui.Spacing(ctx)
      end

      -- Strings distribution
      local strings_named = {}
      for n, c in pairs(strings_dist) do strings_named[n .. '-string'] = c end
      DrawDist('Strings', strings_named, nil)

      -- Tuning distribution
      DrawDist('Tuning', tuning_dist, nil)

      -- Status distribution
      DrawDist('Status', status_dist, CFG.STATUS_COLORS)

      -- Genre distribution (top 15)
      local genre_sorted = {}
      for k, v in pairs(genre_dist) do genre_sorted[#genre_sorted + 1] = { key = k, count = v } end
      table.sort(genre_sorted, function(a, b) return a.count > b.count end)
      if #genre_sorted > 0 then
        ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
        ImGui.Text(ctx, 'Genre (top 15)')
        ImGui.PopStyleColor(ctx, 1)
        for gi = 1, math.min(15, #genre_sorted) do
          local item = genre_sorted[gi]
          ImGui.Text(ctx, string.format('  %-20s', item.key))
          ImGui.SameLine(ctx, 180)
          ImGui.ProgressBar(ctx, item.count / total, 140, 0, tostring(item.count))
        end
        ImGui.Spacing(ctx)
      end

      ImGui.TreePop(ctx)
    end

    ImGui.Spacing(ctx)
    ImGui.Spacing(ctx)

    -- == About ==
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.accent)
    ImGui.Text(ctx, 'About')
    ImGui.PopStyleColor(ctx, 1)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    ImGui.Text(ctx, 'ReaDashboard v' .. CFG.SCRIPT_VERSION)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
    ImGui.Text(ctx, 'Recent Projects: ' .. #S.recent_projects)
    if S.all_projects_loaded then
      ImGui.Text(ctx, 'All Projects: ' .. #S.all_projects)
    end
    ImGui.Text(ctx, 'Tags: ' .. (function()
      local n = 0
      for _ in pairs(project_tags) do n = n + 1 end
      return n
    end)())
    ImGui.PopStyleColor(ctx, 1)

    ImGui.Spacing(ctx)
    ImGui.Spacing(ctx)

    -- Hard Refresh button
    if ImGui.Button(ctx, 'Hard Refresh Now') then
      ActionHardRefresh()
    end
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, 'Re-scan spicetify DB, re-parse all RPP files,\nre-scan all project directories')
    end

    -- Debounce: save only when no widget is actively being dragged/edited.
    -- S values update every frame (live preview), but disk I/O waits for release.
    if changed and not ImGui.IsAnyItemActive(ctx) then SaveState() end

    ImGui.EndChild(ctx)
  end
end

-- ============================================================================
-- ACTIONS TAB (Follow Actions — fire REAPER commands after operations)
-- ============================================================================

--- Resolve a command ID to its display name. Returns name or empty string.
local function GetFollowActionName(commandID)
  if not commandID or commandID == '' then return '' end
  local id = tonumber(commandID)
  if not id then
    id = reaper.NamedCommandLookup(commandID)
  end
  if id and id ~= 0 then
    -- CF_GetCommandText is SWS (reliable); fallback to empty
    if reaper.CF_GetCommandText then
      local name = reaper.CF_GetCommandText(0, id)
      if name and name ~= '' then return name end
    end
  end
  return ''
end

local function DrawActionsTab()
  local _, avail_y = ImGui.GetContentRegionAvail(ctx)

  if ImGui.BeginChild(ctx, 'actions_scroll', -1, avail_y, ImGui.ChildFlags_None) then
    local lbl_w = 180
    local changed = false

    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.accent)
    ImGui.Text(ctx, 'Follow Actions')
    ImGui.PopStyleColor(ctx, 1)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
    ImGui.TextWrapped(ctx, 'Set REAPER Command IDs to trigger after certain operations.\nAccepts numeric IDs (e.g. 40021) or named IDs (e.g. _RS...).\nLeave empty to disable.')
    ImGui.PopStyleColor(ctx, 1)
    ImGui.Spacing(ctx)
    ImGui.Spacing(ctx)

    -- Load Project
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Load Project:')
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, 'Triggered after opening a project in the current tab')
    end
    ImGui.SameLine(ctx, lbl_w)
    ImGui.SetNextItemWidth(ctx, 260)
    local lp_chg, lp_new = ImGui.InputText(ctx, '##fa_load_project', S.followaction_load_project)
    if lp_chg then S.followaction_load_project = lp_new; changed = true end
    local lp_name = GetFollowActionName(S.followaction_load_project)
    if lp_name ~= '' then
      ImGui.SameLine(ctx)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
      ImGui.Text(ctx, lp_name)
      ImGui.PopStyleColor(ctx, 1)
    end

    -- Load in Tab
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Load in Tab:')
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, 'Triggered after opening a project in a new tab')
    end
    ImGui.SameLine(ctx, lbl_w)
    ImGui.SetNextItemWidth(ctx, 260)
    local lt_chg, lt_new = ImGui.InputText(ctx, '##fa_load_in_tab', S.followaction_load_in_tab)
    if lt_chg then S.followaction_load_in_tab = lt_new; changed = true end
    local lt_name = GetFollowActionName(S.followaction_load_in_tab)
    if lt_name ~= '' then
      ImGui.SameLine(ctx)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
      ImGui.Text(ctx, lt_name)
      ImGui.PopStyleColor(ctx, 1)
    end

    -- New Tab
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'New Tab:')
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, 'Triggered after opening an empty new project tab')
    end
    ImGui.SameLine(ctx, lbl_w)
    ImGui.SetNextItemWidth(ctx, 260)
    local nt_chg, nt_new = ImGui.InputText(ctx, '##fa_new_tab', S.followaction_new_tab)
    if nt_chg then S.followaction_new_tab = nt_new; changed = true end
    local nt_name = GetFollowActionName(S.followaction_new_tab)
    if nt_name ~= '' then
      ImGui.SameLine(ctx)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
      ImGui.Text(ctx, nt_name)
      ImGui.PopStyleColor(ctx, 1)
    end

    ImGui.Spacing(ctx)
    ImGui.Spacing(ctx)

    -- Help text
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
    ImGui.TextWrapped(ctx, 'Tip: To find a Command ID, open REAPER\'s Actions list\n(? key or Actions > Show action list), find the action,\nand note the Command ID shown at the bottom.')
    ImGui.PopStyleColor(ctx, 1)

    if changed and not ImGui.IsAnyItemActive(ctx) then SaveState() end

    ImGui.Spacing(ctx)
    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- Exit Script button (always available — force-quits regardless of persistent mode)
    ImGui.PushStyleColor(ctx, ImGui.Col_Button, 0x8B2020FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, 0xA52828FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive, 0xC03030FF)
    if ImGui.Button(ctx, 'Exit Script', 120, 0) then
      S.force_exit = true
      S.window_open = false
    end
    ImGui.PopStyleColor(ctx, 3)
    ImGui.SameLine(ctx)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
    ImGui.Text(ctx, 'Fully close the script (Shift+Esc or Ctrl+Q)')
    ImGui.PopStyleColor(ctx, 1)

    ImGui.EndChild(ctx)
  end
end

-- ============================================================================
-- MAIN FRAME
-- ============================================================================

local function DrawFrame()
  -- First-time data load (tries cache for fast startup, falls back to full scan)
  if S.needs_load then
    Log('--- FIRST FRAME: loading data ---')
    local t0

    t0 = reaper.time_precise()
    LoadMetadataCache()
    Log('  LoadMetadataCache: ' .. string.format('%.1fms', (reaper.time_precise() - t0) * 1000))

    t0 = reaper.time_precise()
    ActionRefresh()
    Log('  ActionRefresh: ' .. string.format('%.1fms', (reaper.time_precise() - t0) * 1000))

    S.needs_load = false

    t0 = reaper.time_precise()
    BuildImageQueue()
    Log('  BuildImageQueue: ' .. string.format('%.1fms', (reaper.time_precise() - t0) * 1000))

    t0 = reaper.time_precise()
    ProcessImageQueue(S.img_first_frame_ms)  -- first frame: configurable budget
    Log('  Pre-load images (' .. S.img_first_frame_ms .. 'ms budget): ' .. string.format('%.1fms', (reaper.time_precise() - t0) * 1000))

    Log('--- FIRST FRAME DONE: ' .. #image_load_queue .. ' images queued for background loading ---')
  end

  -- Progressive image loading: process remaining images across frames (time-budgeted)
  if #image_load_queue > 0 then
    local loaded = ProcessImageQueue(S.img_per_frame_ms)  -- configurable budget per frame
    if loaded > 0 and #image_load_queue == 0 then
      Log('All images loaded.')
    end
  end

  DrawTopBar()
  ImGui.Spacing(ctx)

  -- Tab bar: Recent | All Projects | Settings
  -- Use one-shot SetSelected flag to restore persisted tab on first frame only
  if ImGui.BeginTabBar(ctx, 'main_tabs') then
    -- Consume pending_tab (from Ctrl+1/2/3/4 keyboard shortcut)
    local pending = S.pending_tab
    S.pending_tab = nil

    -- Recent tab
    local recent_flags = 0
    if (not S.tab_restored and S.active_tab == 'recent') or pending == 'recent' then
      recent_flags = ImGui.TabItemFlags_SetSelected
    end
    -- Active tab: live filtered count. Inactive: cached filtered count (fallback to total if never visited)
    local recent_count = (S.active_tab == 'recent') and #S.filtered_projects
      or (S.recent_filtered_count > 0 and S.recent_filtered_count or #S.recent_projects)
    if ImGui.BeginTabItem(ctx, 'Recent (' .. recent_count .. ')###tab_recent', nil, recent_flags) then
      if S.active_tab ~= 'recent' then
        SaveFiltersToTab(S.active_tab)  -- save outgoing tab's filters
        S.active_tab = 'recent'
        S.sort_mode = S.recent_sort_mode
        S.view_mode = S.recent_view_mode
        LoadFiltersFromTab('recent')    -- load incoming tab's filters
        projects = S.recent_projects
        ClearSelection()
        RefreshFiltered()
        BuildImageQueue()
        SaveState()
      end
      ImGui.EndTabItem(ctx)
    end

    -- All Projects tab — shows per-tab filtered count (fallback to display count if never visited)
    local all_count = (S.active_tab == 'all') and #S.filtered_projects
      or (S.all_filtered_count > 0 and S.all_filtered_count or S.all_display_count)
    local all_label = S.all_projects_loaded
      and ('All Projects (' .. all_count .. ')###tab_all')
      or ('All Projects###tab_all')
    local all_flags = 0
    if (not S.tab_restored and S.active_tab == 'all') or pending == 'all' then
      all_flags = ImGui.TabItemFlags_SetSelected
    end
    if ImGui.BeginTabItem(ctx, all_label, nil, all_flags) then
      if S.active_tab ~= 'all' then
        SaveFiltersToTab(S.active_tab)  -- save outgoing tab's filters
        S.active_tab = 'all'
        S.sort_mode = S.all_sort_mode
        S.view_mode = S.all_view_mode
        LoadFiltersFromTab('all')       -- load incoming tab's filters
        -- Load all-projects on first switch if not yet loaded
        if not S.all_projects_loaded then
          Log('All-projects tab activated: loading...')
          local t0 = reaper.time_precise()
          local cached_all = LoadAllProjectsScan()
          if cached_all then
            S.all_projects = cached_all
            S.all_projects_loaded = true
            if S.cache_loaded then
              ApplyCachedMetadata(S.all_projects)
            else
              EnrichProjects(S.all_projects)
              -- Save combined cache
              local combined = {}
              for _, p in ipairs(S.all_projects) do combined[#combined + 1] = p end
              for _, p in ipairs(S.recent_projects) do combined[#combined + 1] = p end
              SaveMetadataCache(combined)
            end
            Log('  All-projects loaded from cache: ' .. string.format('%.1fms', (reaper.time_precise() - t0) * 1000))
          else
            -- No cache — do full scan
            S.all_projects = ScanAllProjectFiles()
            S.all_projects_loaded = true
            SaveAllProjectsScan(S.all_projects)
            EnrichProjects(S.all_projects)
            local combined = {}
            for _, p in ipairs(S.all_projects) do combined[#combined + 1] = p end
            for _, p in ipairs(S.recent_projects) do combined[#combined + 1] = p end
            SaveMetadataCache(combined)
            Log('  All-projects full scan: ' .. string.format('%.1fms', (reaper.time_precise() - t0) * 1000))
          end
        end
        projects = S.all_projects
        ClearSelection()
        RefreshFiltered()
        BuildImageQueue()
        SaveState()
      end
      ImGui.EndTabItem(ctx)
    end

    -- Settings tab
    local settings_flags = 0
    if (not S.tab_restored and S.active_tab == 'settings') or pending == 'settings' then
      settings_flags = ImGui.TabItemFlags_SetSelected
    end
    if ImGui.BeginTabItem(ctx, 'Settings###tab_settings', nil, settings_flags) then
      if S.active_tab ~= 'settings' then
        S.active_tab = 'settings'
        SaveState()
      end
      ImGui.EndTabItem(ctx)
    end

    -- Actions tab
    local actions_flags = 0
    if (not S.tab_restored and S.active_tab == 'actions') or pending == 'actions' then
      actions_flags = ImGui.TabItemFlags_SetSelected
    end
    if ImGui.BeginTabItem(ctx, 'Actions###tab_actions', nil, actions_flags) then
      if S.active_tab ~= 'actions' then
        S.active_tab = 'actions'
        SaveState()
      end
      ImGui.EndTabItem(ctx)
    end

    ImGui.EndTabBar(ctx)
    if not S.tab_restored then S.tab_restored = true end
  end

  -- Settings / Actions tab content
  if S.active_tab == 'settings' then
    DrawSettingsTab()
  elseif S.active_tab == 'actions' then
    DrawActionsTab()
  else
    -- Normal project browsing UI
    DrawFilterBar()
    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    if S.view_mode == 'grid' then
      DrawGridView()
    else
      DrawProjectList()
    end
    DrawActionBar()
    DrawStatusBar()
  end
  HandleKeys()

  -- Tag editor modal (OpenPopup deferred from context menu to root scope)
  if S.tag_edit_pending then
    ImGui.OpenPopup(ctx, 'Edit Tags##modal')
    S.tag_edit_pending = false
  end
  DrawTagEditor()

  -- Bulk tag editor (opened from bulk context menu)
  if S.bulk_tag_edit_pending then
    ImGui.OpenPopup(ctx, 'Bulk Edit Tags##bulk_modal')
    S.bulk_tag_edit_pending = false
  end
  DrawBulkTagEditor()

  -- Confirmation dialog: Remove from Recent
  if S.confirm_remove_proj then
    ImGui.OpenPopup(ctx, 'Confirm Remove##remove_recent')
  end
  local rm_visible, rm_open = ImGui.BeginPopupModal(ctx, 'Confirm Remove##remove_recent', true, ImGui.WindowFlags_AlwaysAutoResize)
  if rm_visible then
    if S.confirm_remove_proj then
      ImGui.Text(ctx, 'Remove from recent projects?')
      ImGui.Spacing(ctx)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.accent)
      ImGui.TextWrapped(ctx, S.confirm_remove_proj.name)
      ImGui.PopStyleColor(ctx, 1)
      ImGui.Spacing(ctx)
      ImGui.Separator(ctx)
      ImGui.Spacing(ctx)
      if ImGui.Button(ctx, 'Remove', 80, 0) then
        ActionRemoveFromRecent(S.confirm_remove_proj)
        S.confirm_remove_proj = nil
        ImGui.CloseCurrentPopup(ctx)
      end
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, 'Cancel', 80, 0) then
        S.confirm_remove_proj = nil
        ImGui.CloseCurrentPopup(ctx)
      end
    end
    if not rm_open then
      S.confirm_remove_proj = nil
      ImGui.CloseCurrentPopup(ctx)
    end
    ImGui.EndPopup(ctx)
  end

  -- Confirmation dialog: Remove Invalid Entries
  if S.confirm_remove_invalid then
    ImGui.OpenPopup(ctx, 'Confirm Remove Invalid##remove_invalid')
    S.confirm_remove_invalid = false  -- only open once
  end
  local inv_visible, inv_open = ImGui.BeginPopupModal(ctx, 'Confirm Remove Invalid##remove_invalid', true, ImGui.WindowFlags_AlwaysAutoResize)
  if inv_visible then
    if S.invalid_count > 0 then
      ImGui.Text(ctx, 'Remove ' .. S.invalid_count .. ' invalid (non-existent) entries')
      ImGui.Text(ctx, 'from recent projects?')
      ImGui.Spacing(ctx)
      ImGui.Separator(ctx)
      ImGui.Spacing(ctx)
      if ImGui.Button(ctx, 'Remove', 80, 0) then
        ActionRemoveInvalidEntries()
        ImGui.CloseCurrentPopup(ctx)
      end
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, 'Cancel##inv', 80, 0) then
        ImGui.CloseCurrentPopup(ctx)
      end
    else
      ImGui.Text(ctx, 'No invalid entries found.')
      ImGui.Spacing(ctx)
      if ImGui.Button(ctx, 'OK', 80, 0) then
        ImGui.CloseCurrentPopup(ctx)
      end
    end
    if not inv_open then
      ImGui.CloseCurrentPopup(ctx)
    end
    ImGui.EndPopup(ctx)
  end

  -- Confirmation dialog: Hide project(s)
  if S.confirm_hide_proj then
    ImGui.OpenPopup(ctx, 'Confirm Hide##hide')
  end
  if S.confirm_hide_bulk then
    ImGui.OpenPopup(ctx, 'Confirm Hide##hide_bulk')
  end

  local hv, ho = ImGui.BeginPopupModal(ctx, 'Confirm Hide##hide', true, ImGui.WindowFlags_AlwaysAutoResize)
  if hv then
    if S.confirm_hide_proj then
      ImGui.Text(ctx, 'Hide this project?')
      ImGui.Spacing(ctx)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.accent)
      ImGui.TextWrapped(ctx, S.confirm_hide_proj.name)
      ImGui.PopStyleColor(ctx, 1)
      ImGui.Spacing(ctx)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
      ImGui.TextWrapped(ctx, 'Hidden projects can be restored from Settings.')
      ImGui.PopStyleColor(ctx, 1)
      ImGui.Spacing(ctx)
      ImGui.Separator(ctx)
      ImGui.Spacing(ctx)
      if ImGui.Button(ctx, 'Hide', 80, 0) then
        S.hidden_projects[S.confirm_hide_proj.path] = true
        SaveHidden()
        SaveState()
        RefreshFiltered()
        S.confirm_hide_proj = nil
        ImGui.CloseCurrentPopup(ctx)
      end
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, 'Cancel##hide', 80, 0) then
        S.confirm_hide_proj = nil
        ImGui.CloseCurrentPopup(ctx)
      end
    end
    if not ho then
      S.confirm_hide_proj = nil
      ImGui.CloseCurrentPopup(ctx)
    end
    ImGui.EndPopup(ctx)
  end

  local hbv, hbo = ImGui.BeginPopupModal(ctx, 'Confirm Hide##hide_bulk', true, ImGui.WindowFlags_AlwaysAutoResize)
  if hbv then
    local bulk = S.confirm_hide_bulk
    if bulk and #bulk > 0 then
      ImGui.Text(ctx, 'Hide ' .. #bulk .. ' projects?')
      ImGui.Spacing(ctx)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.accent)
      local show_max = math.min(#bulk, 5)
      for i = 1, show_max do
        ImGui.Text(ctx, '  ' .. bulk[i].name)
      end
      if #bulk > show_max then
        ImGui.Text(ctx, '  ...and ' .. (#bulk - show_max) .. ' more')
      end
      ImGui.PopStyleColor(ctx, 1)
      ImGui.Spacing(ctx)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
      ImGui.TextWrapped(ctx, 'Hidden projects can be restored from Settings.')
      ImGui.PopStyleColor(ctx, 1)
      ImGui.Spacing(ctx)
      ImGui.Separator(ctx)
      ImGui.Spacing(ctx)
      if ImGui.Button(ctx, 'Hide All', 80, 0) then
        for _, p in ipairs(bulk) do
          S.hidden_projects[p.path] = true
        end
        SaveHidden()
        SaveState()
        RefreshFiltered()
        S.confirm_hide_bulk = nil
        ImGui.CloseCurrentPopup(ctx)
      end
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, 'Cancel##hidebulk', 80, 0) then
        S.confirm_hide_bulk = nil
        ImGui.CloseCurrentPopup(ctx)
      end
    end
    if not hbo then
      S.confirm_hide_bulk = nil
      ImGui.CloseCurrentPopup(ctx)
    end
    ImGui.EndPopup(ctx)
  end

  -- Confirmation dialog: Remove from Favorites
  if S.confirm_unfav_proj then
    ImGui.OpenPopup(ctx, 'Confirm Unfav##unfav')
  end
  if S.confirm_unfav_bulk then
    ImGui.OpenPopup(ctx, 'Confirm Unfav##unfav_bulk')
  end

  local ufv, ufo = ImGui.BeginPopupModal(ctx, 'Confirm Unfav##unfav', true, ImGui.WindowFlags_AlwaysAutoResize)
  if ufv then
    if S.confirm_unfav_proj then
      ImGui.Text(ctx, 'Remove from favorites?')
      ImGui.Spacing(ctx)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.accent)
      ImGui.TextWrapped(ctx, S.confirm_unfav_proj.name)
      ImGui.PopStyleColor(ctx, 1)
      ImGui.Spacing(ctx)
      ImGui.Separator(ctx)
      ImGui.Spacing(ctx)
      if ImGui.Button(ctx, 'Remove##unfav', 80, 0) then
        ActionToggleFavorite(S.confirm_unfav_proj)
        S.confirm_unfav_proj = nil
        ImGui.CloseCurrentPopup(ctx)
      end
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, 'Cancel##unfav', 80, 0) then
        S.confirm_unfav_proj = nil
        ImGui.CloseCurrentPopup(ctx)
      end
    end
    if not ufo then
      S.confirm_unfav_proj = nil
      ImGui.CloseCurrentPopup(ctx)
    end
    ImGui.EndPopup(ctx)
  end

  local ubv, ubo = ImGui.BeginPopupModal(ctx, 'Confirm Unfav##unfav_bulk', true, ImGui.WindowFlags_AlwaysAutoResize)
  if ubv then
    local bulk = S.confirm_unfav_bulk
    if bulk and #bulk > 0 then
      -- Count how many are actually favorited
      local fav_count = 0
      for _, p in ipairs(bulk) do
        if (p.tags or {}).favorite then fav_count = fav_count + 1 end
      end
      ImGui.Text(ctx, 'Remove ' .. fav_count .. ' projects from favorites?')
      ImGui.Spacing(ctx)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.accent)
      local shown = 0
      for _, p in ipairs(bulk) do
        if (p.tags or {}).favorite and shown < 5 then
          ImGui.Text(ctx, '  ' .. p.name)
          shown = shown + 1
        end
      end
      if fav_count > 5 then
        ImGui.Text(ctx, '  ...and ' .. (fav_count - 5) .. ' more')
      end
      ImGui.PopStyleColor(ctx, 1)
      ImGui.Spacing(ctx)
      ImGui.Separator(ctx)
      ImGui.Spacing(ctx)
      if ImGui.Button(ctx, 'Remove##unfavbulk', 80, 0) then
        for _, p in ipairs(bulk) do
          if (p.tags or {}).favorite then ActionToggleFavorite(p) end
        end
        S.confirm_unfav_bulk = nil
        ImGui.CloseCurrentPopup(ctx)
      end
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, 'Cancel##unfavbulk', 80, 0) then
        S.confirm_unfav_bulk = nil
        ImGui.CloseCurrentPopup(ctx)
      end
    end
    if not ubo then
      S.confirm_unfav_bulk = nil
      ImGui.CloseCurrentPopup(ctx)
    end
    ImGui.EndPopup(ctx)
  end

  -- Confirmation dialog: Bulk Remove from Recent
  if S.confirm_remove_bulk then
    ImGui.OpenPopup(ctx, 'Confirm Remove##remove_bulk')
  end
  local rbv, rbo = ImGui.BeginPopupModal(ctx, 'Confirm Remove##remove_bulk', true, ImGui.WindowFlags_AlwaysAutoResize)
  if rbv then
    local bulk = S.confirm_remove_bulk
    if bulk and #bulk > 0 then
      ImGui.Text(ctx, 'Remove ' .. #bulk .. ' projects from recent?')
      ImGui.Spacing(ctx)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.accent)
      local show_max = math.min(#bulk, 5)
      for i = 1, show_max do
        ImGui.Text(ctx, '  ' .. bulk[i].name)
      end
      if #bulk > show_max then
        ImGui.Text(ctx, '  ...and ' .. (#bulk - show_max) .. ' more')
      end
      ImGui.PopStyleColor(ctx, 1)
      ImGui.Spacing(ctx)
      ImGui.Separator(ctx)
      ImGui.Spacing(ctx)
      if ImGui.Button(ctx, 'Remove##rmbulk', 80, 0) then
        for _, p in ipairs(bulk) do
          ActionRemoveFromRecent(p)
        end
        S.confirm_remove_bulk = nil
        ImGui.CloseCurrentPopup(ctx)
      end
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, 'Cancel##rmbulk', 80, 0) then
        S.confirm_remove_bulk = nil
        ImGui.CloseCurrentPopup(ctx)
      end
    end
    if not rbo then
      S.confirm_remove_bulk = nil
      ImGui.CloseCurrentPopup(ctx)
    end
    ImGui.EndPopup(ctx)
  end

  -- Bulk clear tag confirmation
  if S.confirm_bulk_clear_tag then
    ImGui.OpenPopup(ctx, 'Confirm Clear Tag##clear_tag')
  end
  local ctv, cto = ImGui.BeginPopupModal(ctx, 'Confirm Clear Tag##clear_tag', true, ImGui.WindowFlags_AlwaysAutoResize)
  if ctv then
    if S.confirm_bulk_clear_tag then
      local info = S.confirm_bulk_clear_tag
      ImGui.Text(ctx, 'Clear "' .. info.field .. '" from ' .. #info.projects .. ' projects?')
      ImGui.Spacing(ctx)
      -- Show up to 5 names
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.textDim)
      for ni = 1, math.min(5, #info.projects) do
        ImGui.Text(ctx, '  ' .. info.projects[ni].name)
      end
      if #info.projects > 5 then
        ImGui.Text(ctx, '  ...and ' .. (#info.projects - 5) .. ' more')
      end
      ImGui.PopStyleColor(ctx, 1)
      ImGui.Spacing(ctx)
      if ImGui.Button(ctx, 'Clear##ct_yes', 80, 0) then
        for _, p in ipairs(info.projects) do
          SetTag(p.path, info.field, nil)
          p.tags = GetTags(p.path)
        end
        SaveTags()
        S.confirm_bulk_clear_tag = nil
        ImGui.CloseCurrentPopup(ctx)
      end
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, 'Cancel##ct_no', 80, 0) then
        S.confirm_bulk_clear_tag = nil
        ImGui.CloseCurrentPopup(ctx)
      end
    end
    if not cto then
      S.confirm_bulk_clear_tag = nil
      ImGui.CloseCurrentPopup(ctx)
    end
    ImGui.EndPopup(ctx)
  end
end

-- ============================================================================
-- INITIALISATION
-- ============================================================================

local function Init()
  -- GC tuning: use incremental mode with smaller step multiplier to avoid large GC spikes
  -- Default Lua GC can cause 100ms+ pauses; incremental reduces per-frame cost
  pcall(collectgarbage, 'incremental', 200, 100, 13)

  -- Toolbar toggle highlight: button shows active while script is open
  local _, _, sec, cmd = reaper.get_action_context()
  S.toolbar_sec = sec
  S.toolbar_cmd = cmd
  reaper.SetToggleCommandState(sec, cmd, 1)
  reaper.RefreshToolbar2(sec, cmd)

  Log('=== ReaDashboard v' .. CFG.SCRIPT_VERSION .. ' starting ===')
  Log('JS_ReaScriptAPI: ' .. (HAS_JS_API and 'YES' or 'NO'))
  Log('JSON library: ' .. (json and 'YES' or 'NO'))

  local t0 = reaper.time_precise()
  ctx = ImGui.CreateContext(CFG.SCRIPT_NAME)
  Log('CreateContext: ' .. string.format('%.1fms', (reaper.time_precise() - t0) * 1000))

  t0 = reaper.time_precise()
  font = ImGui.CreateFont('sans-serif')  -- 0.10 API: size set at PushFont time
  ImGui.Attach(ctx, font)
  Log('Fonts: ' .. string.format('%.1fms', (reaper.time_precise() - t0) * 1000))

  -- Create EEL callback for InputText history navigation (Up/Down arrows in search bar).
  -- When InputTextFlags_CallbackHistory is set, ImGui routes Up/Down to this callback
  -- instead of consuming them internally. The callback replaces the buffer in-place
  -- and signals the direction back to Lua so it can update state.
  -- Arrow key mapping: Down = older history (direction 1), Up = newer/live (direction -1).
  -- This feels natural: "scroll down through past searches, up to return to current".
  S.search_history_callback = ImGui.CreateFunctionFromEEL([[
    EventFlag == InputTextFlags_CallbackHistory ? (
      EventKey == Key_DownArrow ? (
        can_go_older ? (
          hist_direction = 1;
          InputTextCallback_DeleteChars(0, strlen(#Buf));
          InputTextCallback_InsertChars(0, #older_buf);
          InputTextCallback_SelectAll();
        );
      ) : EventKey == Key_UpArrow ? (
        can_go_newer ? (
          hist_direction = -1;
          InputTextCallback_DeleteChars(0, strlen(#Buf));
          InputTextCallback_InsertChars(0, #newer_buf);
          InputTextCallback_SelectAll();
        );
      );
    );
  ]])
  ImGui.Attach(ctx, S.search_history_callback)
  -- Set constant values the EEL code references
  ImGui.Function_SetValue(S.search_history_callback, 'InputTextFlags_CallbackHistory', ImGui.InputTextFlags_CallbackHistory)
  ImGui.Function_SetValue(S.search_history_callback, 'Key_UpArrow', ImGui.Key_UpArrow)
  ImGui.Function_SetValue(S.search_history_callback, 'Key_DownArrow', ImGui.Key_DownArrow)
  ImGui.Function_SetValue(S.search_history_callback, 'hist_direction', 0)
  ImGui.Function_SetValue(S.search_history_callback, 'can_go_older', 0)
  ImGui.Function_SetValue(S.search_history_callback, 'can_go_newer', 0)
  ImGui.Function_SetValue_String(S.search_history_callback, '#older_buf', '')
  ImGui.Function_SetValue_String(S.search_history_callback, '#newer_buf', '')
  Log('Search history callback: created')

  t0 = reaper.time_precise()
  LoadState()
  RecomputeTheme()  -- derive all C table colors from loaded S settings
  Log('LoadState: ' .. string.format('%.1fms', (reaper.time_precise() - t0) * 1000))

  t0 = reaper.time_precise()
  LoadTags()
  Log('LoadTags: ' .. string.format('%.1fms', (reaper.time_precise() - t0) * 1000))

  t0 = reaper.time_precise()
  LoadHidden()
  Log('LoadHidden: ' .. string.format('%.1fms', (reaper.time_precise() - t0) * 1000))

  t0 = reaper.time_precise()
  LoadWhitelist()
  Log('LoadWhitelist: ' .. string.format('%.1fms', (reaper.time_precise() - t0) * 1000))

  -- Update close_on_new_instance in ExtState from S table (previously set to default at guard)
  reaper.SetExtState(RD_EXT, 'close_on_new_instance', S.close_on_new_instance and '1' or '0', false)
  S._last_heartbeat = reaper.time_precise()
  Log('Instance registered (persistent=' .. tostring(S.persistent_mode) .. ')')

  Log('Init complete.')
end

-- ============================================================================
-- MAIN LOOP
-- ============================================================================

-- frame_count is in S table

-- Static defer closure: avoids creating a new anonymous function every frame (~30fps)
-- Forward-declared here, assigned after OnError is defined
local DeferredLoop

local function Loop()
  local frame_start = reaper.time_precise()
  S.frame_count = S.frame_count + 1

  -- Heartbeat: throttled to once per 3 seconds (negligible overhead)
  local now_tp = reaper.time_precise()
  if now_tp - (S._last_heartbeat or 0) >= 3 then
    reaper.SetExtState(RD_EXT, 'instance_heartbeat', tostring(now_tp), false)
    S._last_heartbeat = now_tp
  end

  -- Toggle request: handle show/hide/close from second instance re-trigger
  if reaper.GetExtState(RD_EXT, 'toggle_request') == '1' then
    reaper.DeleteExtState(RD_EXT, 'toggle_request', false)
    if S.is_hidden then
      -- SHOW: unhide the window
      S.is_hidden = false
      S.window_open = true
      S.had_focus = false
      S._refocus_next_frame = true  -- defer SetNextWindowFocus to after Begin/End
      -- Toolbar: re-light button on show
      if S.toolbar_sec and S.toolbar_cmd then
        reaper.SetToggleCommandState(S.toolbar_sec, S.toolbar_cmd, 1)
        reaper.RefreshToolbar2(S.toolbar_sec, S.toolbar_cmd)
      end
      if S.fade_in_duration > 0 then S.anim_alpha = 0.0 end
      local hidden_dur = now_tp - S.hidden_since
      if hidden_dur > 30 then
        S.needs_load = true
        Log('Toggle: show (data refresh, hidden ' .. string.format('%.0f', hidden_dur) .. 's)')
      else
        Log('Toggle: show (instant, hidden ' .. string.format('%.1f', hidden_dur) .. 's)')
      end
    elseif S.persistent_mode then
      -- HIDE: enter background immediately (no extra rendered frame)
      S.is_hidden = true
      S.hidden_since = now_tp
      S.window_open = false
      S.had_focus = false
      -- Toolbar: dim button while hidden (re-lit on SHOW)
      if S.toolbar_sec and S.toolbar_cmd then
        reaper.SetToggleCommandState(S.toolbar_sec, S.toolbar_cmd, 0)
        reaper.RefreshToolbar2(S.toolbar_sec, S.toolbar_cmd)
      end
      S._save_pending = true  -- defer SaveState to next hidden frame (instant hide)
      Log('Toggle: hide (persistent)')
    else
      -- CLOSE: terminate script
      S.window_open = false
      Log('Toggle: close (non-persistent)')
    end
  end

  -- Hidden mode: script is alive but window is not shown
  -- IMPORTANT: Must call Begin/End to keep ImGui context valid.
  -- ReaImGui docs: "The context will remain valid as long as it is used in each defer cycle."
  -- GetFrameCount alone does NOT count as "used" — a proper Begin/End frame is required.
  if S.is_hidden then
    -- Safety net: validate context is still alive (NVK uses this pattern)
    if not ImGui.ValidatePtr(ctx, 'ImGui_Context*') then
      Log('CRITICAL: ImGui context invalidated during hidden mode, exiting')
      return  -- context dead, let script terminate via atexit
    end
    -- Deferred SaveState from hide transition (runs on first hidden frame, not the hide frame)
    if S._save_pending then
      S._save_pending = false
      SaveState()
    end
    ImGui.PushFont(ctx, font, S.font_size)
    ImGui.SetNextWindowPos(ctx, -32000, -32000, ImGui.Cond_Always)
    ImGui.SetNextWindowSize(ctx, 1, 1, ImGui.Cond_Always)
    ImGui.Begin(ctx, '###readashboard_keepalive', true,
        ImGui.WindowFlags_NoDecoration
      | ImGui.WindowFlags_NoInputs
      | ImGui.WindowFlags_NoFocusOnAppearing
      | ImGui.WindowFlags_NoNav
      | ImGui.WindowFlags_NoSavedSettings)
    ImGui.End(ctx)
    ImGui.PopFont(ctx)
    reaper.defer(DeferredLoop)
    return
  end

  if S.frame_count == 1 then
    Log('Loop() entered (first call). Defer delay: ' .. string.format('%.1fms', (frame_start - SCRIPT_START_TIME) * 1000 - 3.4))
  end

  ImGui.SetNextWindowSize(ctx, CFG.DEFAULT_W, CFG.DEFAULT_H, ImGui.Cond_FirstUseEver)

  -- Fade-in animation: ramp anim_alpha from 0→1 over fade_in_duration seconds
  if S.fade_in_duration > 0 and S.anim_alpha < 1.0 then
    local dt = ImGui.GetDeltaTime(ctx)
    S.anim_alpha = math.min(1.0, S.anim_alpha + dt / S.fade_in_duration)
  elseif S.fade_in_duration <= 0 then
    S.anim_alpha = 1.0  -- disabled: instantly visible
  end

  local t0
  if S.frame_count == 1 then t0 = reaper.time_precise() end
  PushTheme()
  if S.frame_count == 1 then Log('  PushTheme: ' .. string.format('%.1fms', (reaper.time_precise() - t0) * 1000)) end

  -- Set grid tooltip hover delay (only affects IsItemHovered with HoveredFlags_DelayNormal)
  if S.grid_tooltip_delay > 0 then
    ImGui.SetConfigVar(ctx, ImGui.ConfigVar_HoverDelayNormal, S.grid_tooltip_delay)
  else
    ImGui.SetConfigVar(ctx, ImGui.ConfigVar_HoverDelayNormal, 0.0)
  end

  if S.frame_count == 1 then t0 = reaper.time_precise() end
  ImGui.PushFont(ctx, font, S.font_size)
  if S.frame_count == 1 then Log('  PushFont: ' .. string.format('%.1fms', (reaper.time_precise() - t0) * 1000)) end

  local wflags = ImGui.WindowFlags_NoCollapse
               | ImGui.WindowFlags_NoScrollbar
               | ImGui.WindowFlags_NoScrollWithMouse

  -- Re-focus window after persistent mode re-show (deferred from toggle handler)
  if S._refocus_next_frame then
    ImGui.SetNextWindowFocus(ctx)
    S._refocus_next_frame = false
  end

  if S.frame_count == 1 then t0 = reaper.time_precise() end
  local visible, open = ImGui.Begin(
    ctx,
    CFG.SCRIPT_NAME .. ' v' .. CFG.SCRIPT_VERSION .. '###readashboard_main',
    true,
    wflags
  )
  if S.frame_count == 1 then Log('  ImGui.Begin: ' .. string.format('%.1fms', (reaper.time_precise() - t0) * 1000)) end

  if visible then
    -- Close-on-unfocus: detect focus loss and schedule close/hide
    if S.close_on_unfocus then
      local focused = ImGui.IsWindowFocused(ctx, ImGui.FocusedFlags_AnyWindow)
      if focused then
        S.had_focus = true
      elseif S.had_focus then
        S.window_open = false
      end
    end

    DrawFrame()
  end
  -- End() must always be called after Begin(), even when window is collapsed/clipped
  ImGui.End(ctx)

  ImGui.PopFont(ctx)
  PopTheme()

  -- Log first 5 frame times and then every 100th frame
  if S.frame_count <= 5 or S.frame_count % 100 == 0 then
    local frame_ms = (reaper.time_precise() - frame_start) * 1000
    Log('Frame ' .. S.frame_count .. ': ' .. string.format('%.1fms', frame_ms))
  end

  if open and S.window_open then
    reaper.defer(DeferredLoop)
  elseif S.persistent_mode and not S.force_exit then
    -- Window closed but persistent mode: hide instead of dying
    S.is_hidden = true
    S.hidden_since = reaper.time_precise()
    S.had_focus = false
    -- Toolbar: dim button while hidden
    if S.toolbar_sec and S.toolbar_cmd then
      reaper.SetToggleCommandState(S.toolbar_sec, S.toolbar_cmd, 0)
      reaper.RefreshToolbar2(S.toolbar_sec, S.toolbar_cmd)
    end
    S._save_pending = true  -- defer SaveState to next hidden frame (instant hide)
    Log('Persistent mode: window hidden (frame ' .. S.frame_count .. ')')
    reaper.defer(DeferredLoop)
  else
    Log('Window closing (frame ' .. S.frame_count .. '). open=' .. tostring(open) .. ' window_open=' .. tostring(S.window_open))
    SaveState()
    SaveHidden()
    SaveWhitelist()
    Log('SaveState done. Script ending.')
  end
end

function OnError(err)
  local msg = '[ReaDashboard Error]\n' .. tostring(err) .. '\n' .. debug.traceback()
  -- Console output kept for crash errors (these are rare and need to be visible)
  reaper.ShowConsoleMsg('\n' .. msg .. '\n')
  -- Also log to file
  local f = io.open(LOG_FILE, 'a')
  if f then
    f:write('\n' .. msg .. '\n')
    f:close()
  end
end

-- Assign the static defer closure (forward-declared before Loop)
DeferredLoop = function() xpcall(Loop, OnError) end

reaper.atexit(function()
  -- Wrapped in pcall: during "terminate on new instance", REAPER may kill the script
  -- mid-frame, leaving state inconsistent. pcall prevents cascade crashes in atexit.
  pcall(function()
    Log('atexit called (frame ' .. S.frame_count .. ')')
    SaveState()
    SaveHidden()
    SaveWhitelist()
  end)
  -- Always clear instance flags (even if SaveState failed)
  pcall(reaper.DeleteExtState, RD_EXT, 'instance_running', false)
  pcall(reaper.DeleteExtState, RD_EXT, 'instance_heartbeat', false)
  pcall(reaper.DeleteExtState, RD_EXT, 'toggle_request', false)
  -- Toolbar toggle: mark as inactive
  pcall(function()
    if S.toolbar_sec and S.toolbar_cmd then
      reaper.SetToggleCommandState(S.toolbar_sec, S.toolbar_cmd, 0)
      reaper.RefreshToolbar2(S.toolbar_sec, S.toolbar_cmd)
    end
  end)
  pcall(Log, 'atexit done. Total script lifetime: ' .. string.format('%.0fms', (reaper.time_precise() - SCRIPT_START_TIME) * 1000))
end)

-- GO
Log('Script file loaded, calling Init...')
Init()
Log('Init done, calling first Loop directly (avoids ~1.2s defer delay)...')
xpcall(Loop, OnError)  -- direct call for first frame; Loop defers itself for subsequent frames
