-- elvui_tags.lua — optional ElvUI party frame integration
-- Registers two custom ElvUI tags that show iLvl (and set bonus)
-- in ElvUI unit frames (party, raid, player, etc.):
--   [dilvl]       — iLvl wrapped in square brackets, e.g. "[284]"
--   [dilvl:plain] — bare iLvl number, e.g. "284"
--
-- SAFE TO LOAD WITHOUT ELVUI: if ElvUI is not installed this file
-- does nothing — no errors, no prints, no performance cost.
--
-- USAGE (after enabling via /dilvl elvui):
--   In ElvUI → Unit Frames → Party/Raid/Player → Name text, add one of:
--     [name] [dilvl]        → "Raza [284]"
--     [name] [dilvl:plain]  → "Raza 284"
--
-- TOGGLE: /dilvl elvui on|off  (saved between sessions, gates BOTH tags)
--
-- UPDATE STRATEGY: event-driven, no polling timer.
-- core.lua fires registered callbacks after: INSPECT_READY, gear swap,
-- GROUP_ROSTER_UPDATE. Our callback calls Tags:RefreshMethods on both
-- tag names, re-rendering every visible frame using either tag.
-- During 3h farming with no group changes: zero extra calls.

if not ElvUI then return end -- no ElvUI installed → silent exit

local E = unpack(ElvUI)
if not E then return end

local API = Details_iLvlDisplayAPI
if not API then return end -- core.lua didn't load (shouldn't happen)

---------------------------------------------------------------
-- Shared tag body — pure cache lookup, no API calls. Both tag
-- variants delegate here so color/setbonus/master-toggle behaviour
-- stays identical; only the iLvl wrapping differs.
---------------------------------------------------------------
local function buildIlvl(unit, withBrackets)
    local db = API.GetDb()
    if not db or not db.elvuiTag then return "" end

    local guid = UnitGUID(unit)
    if not guid then return "" end

    local cached, setBonus = API.GetCacheData(guid)
    if not cached or not cached.ilvl then return "" end

    local num = cached.ilvl
    local body = withBrackets and ("[" .. num .. "]") or tostring(num)

    local tag
    if db.colorIlvl then
        tag = API.GetIlvlColor(num) .. body .. "|r"
    else
        tag = body
    end

    if db.showSetBonus and setBonus then
        tag = tag .. " |cFF00FF00[" .. setBonus .. "]|r"
    end

    return tag
end

E:AddTag("dilvl", "UNIT_INVENTORY_CHANGED", function(unit)
    return buildIlvl(unit, true)
end)

E:AddTag("dilvl:plain", "UNIT_INVENTORY_CHANGED", function(unit)
    return buildIlvl(unit, false)
end)

E:AddTagInfo("dilvl", "Details! iLvl Display",
    "Shows item level and tier set bonus, wrapped in [brackets]. " ..
    "Enable with /dilvl elvui. Respects your /dilvl color and setbonus settings.")

E:AddTagInfo("dilvl:plain", "Details! iLvl Display",
    "Shows item level and tier set bonus without brackets around the iLvl. " ..
    "Enable with /dilvl elvui. Respects your /dilvl color and setbonus settings.")

---------------------------------------------------------------
-- Register callback: core.lua fires all registered callbacks
-- whenever cached iLvl data changes. We respond by calling
-- RefreshMethods which re-renders every visible frame using
-- either tag immediately. This is the official oUF API for
-- forcing a tag re-evaluation; it accepts multiple tag names
-- in one call so both variants refresh together.
---------------------------------------------------------------
API:RegisterCallback("elvui", function()
    pcall(E.oUF.Tags.RefreshMethods, E.oUF.Tags, "dilvl", "dilvl:plain")
end)
