-- elvui_tags.lua — optional ElvUI party frame integration
-- Registers a custom ElvUI tag [dilvl] that shows iLvl (and set bonus)
-- in ElvUI unit frames (party, raid, player, etc.).
--
-- SAFE TO LOAD WITHOUT ELVUI: if ElvUI is not installed this file
-- does nothing — no errors, no prints, no performance cost.
--
-- USAGE (after enabling via /dilvl elvui):
--   In ElvUI → Unit Frames → Party/Raid/Player → Name text, add: [dilvl]
--   Example name text: "[name] [dilvl]"
--
-- TOGGLE: /dilvl elvui on|off  (saved between sessions)
--
-- UPDATE STRATEGY: event-driven, no polling timer.
-- core.lua fires registered callbacks after: INSPECT_READY, gear swap,
-- GROUP_ROSTER_UPDATE. Our callback calls Tags:RefreshMethods("dilvl")
-- which re-renders all frames using [dilvl] immediately.
-- During 3h farming with no group changes: zero extra calls.

if not ElvUI then return end -- no ElvUI installed → silent exit

local E = unpack(ElvUI)
if not E then return end

local API = Details_iLvlDisplayAPI
if not API then return end -- core.lua didn't load (shouldn't happen)

---------------------------------------------------------------
-- Tag function: [dilvl]
-- Pure cache lookup — no API calls, runs only when core.lua signals
-- a data change or when the frame is first shown.
---------------------------------------------------------------
E:AddTag("dilvl", "UNIT_INVENTORY_CHANGED", function(unit)
    local db = API.GetDb()
    if not db or not db.elvuiTag then return "" end

    local guid = UnitGUID(unit)
    if not guid then return "" end

    local cached, setBonus = API.GetCacheData(guid)
    if not cached or not cached.ilvl then return "" end

    local tag
    if db.colorIlvl then
        tag = API.GetIlvlColor(cached.ilvl) .. "[" .. cached.ilvl .. "]|r"
    else
        tag = "[" .. cached.ilvl .. "]"
    end

    if db.showSetBonus and setBonus then
        tag = tag .. " |cFF00FF00[" .. setBonus .. "]|r"
    end

    return tag
end)

E:AddTagInfo("dilvl", "Details! iLvl Display",
    "Shows item level and tier set bonus. Enable with /dilvl elvui. " ..
    "Respects your /dilvl color and setbonus settings.")

---------------------------------------------------------------
-- Register callback: core.lua fires all registered callbacks
-- whenever cached iLvl data changes. We respond by calling
-- RefreshMethods which re-renders every visible frame using
-- [dilvl] immediately. This is the official oUF API for
-- forcing a tag re-evaluation.
---------------------------------------------------------------
API:RegisterCallback("elvui", function()
    pcall(E.oUF.Tags.RefreshMethods, E.oUF.Tags, "dilvl")
end)
