-- Details! Item Level Display — Copyright (c) 2026 HK2084. All rights reserved.
-- Licensed for private use only; see LICENSE. No redistribution of modified copies.
-- locales/enUS.lua — default English strings + identity-fallback metatable.
--
-- PATTERN: every user-facing string in the UI goes through `L["..."]`.
-- This file declares every string ONCE. Other locale files (deDE.lua etc.)
-- override individual entries when the client language matches; missing
-- translations fall back through the metatable to the key itself, so an
-- untranslated string just appears in English instead of crashing.
--
-- ADDING A NEW STRING: add it here in EN, then optionally in each other
-- locale file. The metatable means it's never an error to skip a locale.

local addonName, ns = ...
local L = {}
ns.L = L

---------------------------------------------------------------
-- Window chrome
---------------------------------------------------------------
L["Details! iLvl Display"]      = "Details! iLvl Display"
L["Open Settings"]              = "Open Settings"

---------------------------------------------------------------
-- Tabs
---------------------------------------------------------------
L["General"]                    = "General"
L["Output Channels"]            = "Output Channels"
L["Diagnostics"]                = "Diagnostics"

---------------------------------------------------------------
-- Page: General
---------------------------------------------------------------
L["GENERAL_INFO"]               = "Auto-detects what you have installed. Toggle individual surfaces on the Output Channels tab."
L["Master Toggles"]             = "Master Toggles"
L["Enable Details! iLvl Display"] = "Enable Details! iLvl Display"
L["TOOLTIP_MASTER_ENABLE"]      = "Master switch for the entire addon. Disable to silence every output channel without uninstalling."
L["Color by gear tier"]         = "Color by gear tier"
L["TOOLTIP_COLOR"]              = "Color the iLvl number by how far into the current season's gear the player is. Gold sits above anything Mythic+ awards, then orange, purple, blue, green, grey. The boundaries come from this season's Mythic+ reward levels, so they move with the season instead of going stale."
L["Show 2P/4P set bonus"]       = "Show 2P/4P set bonus"
L["TOOLTIP_SETBONUS"]           = "Show the tier set bonus next to the iLvl, e.g. 'Razul [263] [4P]'."

L["Display"]                    = "Display"
L["Layout (Details!)"]          = "Layout (Details!)"
L["Inline"]                     = "Inline"
L["Columns"]                    = "Columns"
L["TOOLTIP_LAYOUT"]             = "Inline: appended to player name. Columns: separate right-aligned columns (Details! only, visible during combat)."

L["Position"]                   = "Position"
L["Left of name"]               = "Left of name"
L["Right of name"]              = "Right of name"
L["TOOLTIP_POSITION"]           = "Where the iLvl tag sits relative to the player name. Applies to Details! and Blizzard DM."

L["Auto-detected"]              = "Auto-detected"
L["AUTODETECT_DESCRIPTION"]     = "Surfaces detected in your installed addons:"

---------------------------------------------------------------
-- Page: Output Channels
---------------------------------------------------------------
L["CHANNELS_INFO"]              = "Toggle each output channel independently. Each channel auto-disables after 5 errors without affecting the others."
L["Details! bars"]              = "Details! bars"
L["ElvUI tags"]                 = "ElvUI tags"
L["Grid2 status"]               = "Grid2 status"
L["Danders Frames overlay"]     = "Danders Frames overlay"
L["Blizzard DM"]                = "Blizzard DM"

L["ELVUI_TAGS_HINT"]            = "Pick [dilvl] (brackets: Razul [263]) or [dilvl:plain] (bare: Razul 263) inside any ElvUI Custom Text. Both tags are listed in ElvUI's tag browser."
L["GRID2_HINT"]                 = "Configure the indicator placement in Grid2's GUI (Status -> dilvl)."

L["Danders Anchor Position"]    = "Danders Anchor Position"
L["Danders Font Size"]          = "Danders Font Size"
L["TOOLTIP_DANDERS_SIZE"]       = "Size of the iLvl text on Danders Frames. Range 6-30, live update without /reload."

L["Details Window"]             = "Details! Window"
L["All windows"]                = "All windows"
L["Window 1"]                   = "Window 1"
L["Window 2"]                   = "Window 2"
L["Window 3"]                   = "Window 3"
L["Window 4"]                   = "Window 4"
L["Window 5"]                   = "Window 5"
L["TOOLTIP_DETAILS_WINDOW"]     = "Show iLvl on only one Details! window instead of all of them. 'All windows' is the default. Slash: /dilvl details window <all|1-10>."
L["Details Font Size"]          = "Details! Font Size"
L["TOOLTIP_DETAILS_SIZE"]       = "Fixed iLvl text size on Details! bars (Columns layout only). Drag to set 6-30; use '/dilvl details size 0' to match Details' own font."
L["DETAILS_SIZE_INLINE_NOTE"]   = "ⓘ Font size applies to the Columns layout — switch layout on the General tab."

L["Blizzard DM Mode"]           = "Blizzard DM Mode"
L["Auto"]                       = "Auto"
L["Forced On"]                  = "Forced On"
L["Forced Off"]                 = "Forced Off"
L["TOOLTIP_BLIZZDM_MODE"]       = "Auto: enabled when Details! is missing. Forced On/Off override the auto-detection."

---------------------------------------------------------------
-- Page: Live Preview
---------------------------------------------------------------
L["Damage Meter Preview"]       = "Damage Meter Preview"
L["Unit Frame Preview"]         = "Unit Frame Preview"
L["PREVIEW_UF_CAPTION"]         = "Sample frame — Grid2 / ElvUI render analogously"

---------------------------------------------------------------
-- Page: Diagnostics
---------------------------------------------------------------
L["DIAGNOSTICS_INFO"]           = "If you hit a bug, copy the output below and paste it into a CurseForge comment or GitHub issue."
L["Refresh"]                    = "Refresh"
L["Reset UI Error Counters"]    = "Reset UI Error Counters"
L["Reset to Defaults"]          = "Reset to Defaults"
L["RESET_DEFAULTS_CONFIRM"]     = "Reset ALL settings to their default values?\n\nYour iLvl cache and window position will be preserved."

---------------------------------------------------------------
-- Footer
---------------------------------------------------------------
L["FOOTER_HINT"]                = "/dilvl debug for bug reports"
L["BLIZZ_PANEL_SLASH_HINT"]     = "Slash: /dilvl   |   /dilvl debug for diagnostics"

---------------------------------------------------------------
-- Error placeholders
---------------------------------------------------------------
L["PAGE_BROKEN_TITLE"]          = "Settings page broken"
L["PAGE_BROKEN_BODY"]           = "Page '%s' has been disabled after %d errors.\nOther pages still work. Use /dilvl slash commands\nor /reload to recover."
L["PAGE_BROKEN_LAST"]           = "Last error: %s"

---------------------------------------------------------------
-- Page: What's New
---------------------------------------------------------------
L["What's New"]                 = "What's New"
L["WHATSNEW_INFO"]              = "The newest features, newest first. Bugfixes live in the full version history linked below."
L["WHATSNEW_HISTORY"]           = "Full version history:"
L["WN_158_ILVLCOLOUR"]          = "Item level colours follow the season"
L["WN_158_ILVLCOLOUR_D"]        = "The boundaries come from this season's Mythic+ reward levels instead of fixed numbers, so they move with the season. Gold is new and sits above anything Mythic+ awards."
L["WN_156_SEASON"]              = "Tier sets by season"
L["WN_156_SEASON_D"]            = "The current season's set bonus is green, an older season's is grey. While someone is swapping tier you see both side by side, oldest first."
L["WN_150_UI"]                  = "Settings window"
L["WN_150_UI_D"]                = "This window — every option in one place, no more remembering slash commands."
L["WN_150_SIZE"]                = "Details! text size"
L["WN_150_SIZE_D"]              = "Set a fixed iLvl text size on Details! bars (Columns layout)."
L["WN_150_WINDOW"]              = "Per-window display"
L["WN_150_WINDOW_D"]            = "Show iLvl on only one Details! window instead of all of them."
L["WN_144_DANDERS"]             = "Danders Frames text size"
L["WN_144_DANDERS_D"]           = "Adjustable iLvl text size plus off-frame anchor positions."
L["WN_143_ELVUI"]               = "ElvUI plain tag"
L["WN_143_ELVUI_D"]             = "[dilvl:plain] — the bare iLvl number without brackets."

---------------------------------------------------------------
-- ElvUI tag browser (elvui_tags.lua registers these with E:AddTagInfo)
---------------------------------------------------------------
L["ELVUI_TAG_DILVL_D"]         = "Shows item level and tier set bonus, wrapped in [brackets]. Enable with /dilvl elvui. Respects your /dilvl color and setbonus settings."
L["ELVUI_TAG_PLAIN_D"]         = "Shows item level and tier set bonus without brackets around the iLvl. Enable with /dilvl elvui. Respects your /dilvl color and setbonus settings."

---------------------------------------------------------------
-- Magic: missing keys return their own name as fallback so an untranslated
-- string just shows in English (or the key itself) instead of nil/error.
-- This is the ecosystem-standard pattern (AceLocale silent=true does the same).
---------------------------------------------------------------
setmetatable(L, {__index = function(_, k) return k end})
