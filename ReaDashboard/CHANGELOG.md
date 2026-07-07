# ReaDashboard Changelog

## v1.1.2 (2026-07-07)
* Fixed: script could crash repeatedly and become unusable if the ImGui window context was invalidated mid-session; it now exits cleanly with a log entry instead

## v1.1.1 (2026-04-23)
+ Added recursive subfolder scanning for artwork with configurable depth (Settings -> Data Sources)
+ Added Tab key shortcut to jump focus from project area back to the search bar
+ Added Ctrl+Down/Up shortcuts to instantly jump focus from the search bar into the project area

## v1.1.0 (2026-04-22)
+ Guitar Mode toggle — hide all guitar-specific fields (strings, tuning, transpose, guitar, amp) via Settings; data untouched
+ Scan staleness indicator — status bar shows when the last hard refresh was run (right-aligned, faint); Refresh button tooltip updated
+ Ctrl+C copies selected project path(s) to clipboard (multi-select copies newline-separated)
+ Added Keyboard Shortcuts section to Actions tab documenting all built-in hotkeys
* Fixed README keyboard shortcuts table (corrected Ctrl+C, added missing Home/End/Ctrl+A/etc.)

## v1.0.9 (2026-04-22)
+ Statuses are now fully editable in Settings (add, remove, rename — same as Genres)
+ 'Browse...' button to open any .rpp file from disk via native OS file dialog
* Fixed: 'All Projects' separator no longer appears redundantly on the All Projects tab
* Fixed: Locate in Explorer / Reveal in Finder crash ('expected 1 arguments maximum')

## v1.0.8 (2026-04-22)
+ Bug fixes (see v1.0.7)

## v1.0.7 (2026-04-14)
+ Bug fixes

## v1.0.6 (2026-04-14)
+ Fixed a critical bug preventing Mac and Linux users from opening any projects due to Windows-specific path formatting.

## v1.0.5 (2026-04-14)
+ Fixed 'Last Opened' sorting order (now properly ordered newest to oldest)
+ Fixed search bar repeatedly losing keyboard focus while typing
+ Fixed massive lag and UI sluggishness when bringing the script back from background persistent mode
+ Improved visual widths for text input fields in the Settings panel

## v1.0.4 (2026-04-10)
+ Persistent mode — keep script running in background for instant re-open (toggle in Settings)
+ Close on unfocus — automatically close/hide when clicking outside the window (toggle in Settings)
+ Close on Escape — make Escape key close/hide behavior configurable (on by default)
+ Toolbar toggle highlighting — toolbar button now reflects script open/closed state

## v1.0.3 (2026-04-09)
+ Last Opened sort mode — native REAPER recent order (last opened project first)
+ Multiple project folder paths — scan additional folders alongside the primary path
+ Configurable image loading budgets — tune first-frame and per-frame budgets in Settings
+ Default artwork path — fallback image when project has no art (configurable in Settings)
+ Full project name on placeholder — show full name instead of initials when art is missing
+ Custom statuses — add your own status presets via Settings (comma-separated)
+ Expanded built-in statuses — added Recording, Mixing, On Hold, Released

## v1.0.2 (2026-04-09)
+ LUA Slot cleanup to free 48 slots by CFG refactor

## v1.0.1 (2026-04-09)
+ Bulk Tag Editor — edit tags across multiple selected projects at once
+ Configurable Primary Genres — customize genre list from Settings
+ Grid Card Tooltip Mode — show metadata fields as hover tooltip instead of on-card
+ Grid Card Fields — added Tuning and Transpose as optional card/tooltip fields
+ Grid Tooltip Delay — configurable hover delay for grid card tooltips
+ Configurable Grid Spacing — adjustable card spacing in Settings

## v1.0.0 (2026-04-06)
+ Initial release
