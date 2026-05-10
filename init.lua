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
    dandersFontSize = 10,  -- reserved for future /dilvl danders fontsize cmd; danders_integration reads this
    layout = "inline",     -- "inline" (append to name) or "columns" (separate right-aligned columns)
    ilvlPosition = "right", -- "right" (after name) or "left" (between rank and name)
    -- blizzDM: nil = auto (ON when Details! absent, OFF when Details! active)
    --          true/false = user override via /dilvl blizzdm
}

-- Valid Danders position keys. Mirror of POS in danders_integration.lua —
-- duplicated so the slash-command can validate without load-order coupling.
ns.POS_KEYS_SET = {
    top = true, topright = true, topleft = true,
    bottom = true, bottomright = true, bottomleft = true,
    center = true,
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
        key  = "elvuiplain",                                -- v1.4.3
        gate = function() return ElvUI ~= nil end,
        msg  = "[dilvl:plain] ElvUI tag — bare iLvl number without brackets, e.g. \"Raza 284\" instead of \"Raza [284]\". Use in any ElvUI Custom Text.",
    },
    {
        key = "position",                                   -- v1.3.5
        msg = "/dilvl position — place iLvl before or after player name.",
    },
}
