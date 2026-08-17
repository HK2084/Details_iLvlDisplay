-- Details! Item Level Display — Copyright (c) 2026 HK2084. All rights reserved.
-- Licensed for private use only; see LICENSE. No redistribution of modified copies.
-- init.lua — addon namespace bootstrap
--
-- Every Lua file in this addon receives the same `(addonName, ns)` varargs
-- from WoW. By writing into `ns` here, we get a shared namespace table that
-- all other files can read via `local addonName, ns = ...` at file top.
--
-- This file MUST load before core.lua (TOC order). It only sets up shared
-- data — no behavior, no events, no hooks. Sub-files populate the inner
-- tables (ns.util, ns.secrets, ...) at their own load time.

local addonName, ns = ...

ns.addonName = addonName
ns.version = C_AddOns.GetAddOnMetadata(addonName, "Version") or "?"

-- Sub-module tables. Created here so cross-file references at file-load
-- time don't depend on which integration file loaded first.
ns.util    = {}
ns.secrets = {}

-- SavedVariables defaults. Single source of truth — core.lua copies missing
-- keys onto db at ADDON_LOADED. Add new keys here, not inline in core.lua.
ns.defaults = {
    enabled = true,
    colorIlvl = true,
    showSetBonus = true,
    showInDetails = true,  -- show iLvl on Details! bars (requires Details!)
    elvuiTag = false,      -- show iLvl in ElvUI party frames (opt-in, requires ElvUI)
    grid2Status = false,   -- show iLvl in Grid2 raid frames via "dilvl" status (opt-in, requires Grid2)
    dandersText = false,   -- show iLvl on Danders Frames as overlay FontString (opt-in, requires Danders Frames)
    dandersPos = "topright", -- one of ns.POS_KEYS_SET below; live-set via /dilvl danders pos <opt>
    dandersFontSize = 10,  -- live-set via /dilvl danders size <n>; clamped to [6, 30] at the slash boundary
    layout = "inline",     -- "inline" (append to name) or "columns" (separate right-aligned columns)
    ilvlPosition = "right", -- "right" (after name) or "left" (between rank and name)
    detailsFontSize = 0,   -- iLvl text size on Details! bars; 0 = match Details' font (auto), 6-30 = fixed override (columns layout). Live-set via /dilvl details size <n>
    detailsWindowId = 0,   -- which Details! window shows iLvl; 0 = all windows, 1-10 = only that window. Live-set via /dilvl details window <n|all>
    -- blizzDM: nil = auto (ON when Details! absent, OFF when Details! active)
    --          true/false = user override via /dilvl blizzdm
}

-- Valid Danders position keys. Mirror of POS in danders_integration.lua —
-- duplicated so the slash-command can validate without load-order coupling.
ns.POS_KEYS_SET = {
    -- inside-frame
    top = true, topright = true, topleft = true,
    bottom = true, bottomright = true, bottomleft = true,
    center = true,
    -- off-frame (text floats outside bounding box, useful when inside
    -- overlaps the unit's name/HP at larger font sizes)
    above = true, aboveleft = true, aboveright = true,
    below = true, belowleft = true, belowright = true,
}

-- Login hint registry. Every new user-facing feature must add an entry here
-- so existing users notice it on next login. Each hint fires once per
-- character (flag stored as `seenHint_<key>` in SavedVariables) and is
-- staggered 4s apart starting 8s post-login, so a fresh install with
-- multiple unseen hints doesn't spam the chat frame in one tick.
--
-- Order = newest-first. Add new entries on top.
-- `gate` is optional: when present, the hint is silently skipped (without
-- consuming the seen flag) on clients where the dependency is missing,
-- so a user installing ElvUI later still gets the ElvUI-specific hint.
ns.LOGIN_HINTS = {
    {
        -- No gate, same reasoning as the season colouring below: this changes
        -- what every number on screen MEANS. Someone who sees their own 286 go
        -- from orange to green and is not told why will file it as a bug.
        key  = "seasonilvlcolour",                          -- v1.5.8
        msg  = "Item level colours now follow the current season instead of fixed numbers: gold sits above anything Mythic+ awards, then orange, purple, blue, green, grey. Expect the top colours to be empty early in a season and fill up as people gear.",
    },
    {
        -- No gate: this one is not a command to learn, it is a change to what
        -- the numbers already on screen MEAN, so everyone should see it once.
        key  = "seasoncolour",                              -- v1.5.6
        msg  = "Tier set bonuses are now coloured by season — green is the current season's, grey an older one. While someone is switching over you will see both next to each other, oldest first.",
    },
    {
        key  = "detailswindow",                             -- v1.5.0
        gate = function() return Details ~= nil end,
        msg  = "/dilvl details window <n|all> — show iLvl on only ONE Details! window instead of all of them (e.g. 'window 1'). 'all' restores the default.",
    },
    {
        key  = "detailssize",                               -- v1.5.0
        gate = function() return Details ~= nil end,
        msg  = "/dilvl details size <n> — set a fixed iLvl text size on Details! bars (6-30), or 'size 0' to match Details' own font. Applies to the Columns layout.",
    },
    {
        key  = "dandersposoff",                             -- v1.4.4
        gate = function() return DandersFrames_IsReady ~= nil end,
        msg  = "/dilvl danders pos above|below (also aboveleft/aboveright/belowleft/belowright) — text floats OUTSIDE the frame so it doesn't overlap the unit's name. Inside positions (top/topright/...) still available.",
    },
    {
        key  = "danderssize",                               -- v1.4.4
        gate = function() return DandersFrames_IsReady ~= nil end,
        msg  = "/dilvl danders size <n> — adjust iLvl text size on Danders Frames (default 10, range 6-30). Live update, no /reload.",
    },
    {
        key  = "elvuiplain",                                -- v1.4.3
        gate = function() return ElvUI ~= nil end,
        msg  = "[dilvl:plain] ElvUI tag — bare iLvl number without brackets, e.g. \"Raza 284\" instead of \"Raza [284]\". Use in any ElvUI Custom Text.",
    },
    {
        key = "position",                                   -- v1.3.5
        msg = "/dilvl position — place iLvl before or after player name.",
    },
}
