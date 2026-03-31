-- elvui_tags.lua — optional ElvUI party frame integration
-- Registers a custom ElvUI tag [dilvl] that shows iLvl (and set bonus)
-- in ElvUI unit frames (party, raid, player, etc.).
--
-- SAFE TO LOAD WITHOUT ELVUI: if ElvUI is not installed this file
-- does nothing — no errors, no prints, no performance cost.
--
-- USAGE (after enabling via /dilvl elvui):
--   In ElvUI → Unit Frames → Party → Name/Health text, add: [dilvl]
--   Example name text: "[name]  [dilvl]"
--
-- TOGGLE: /dilvl elvui on|off  (saved between sessions)

if not ElvUI then return end -- no ElvUI installed → silent exit

local E = unpack(ElvUI)
if not E then return end

local API = Details_iLvlDisplayAPI
if not API then return end -- core.lua didn't load (shouldn't happen)

---------------------------------------------------------------
-- Tag: [dilvl]
-- Shows colored iLvl + set bonus for the unit, e.g. "|cFF0070DD[252]|r [2P]"
-- Returns "" (empty string) if: ElvUI tag is disabled, unit has no cached data.
-- Update events: fires on gear changes and after inspect completes.
---------------------------------------------------------------
-- Throttle-based update (3 seconds) rather than event-based.
-- oUF routes unit events only when frame.unit == the fired unit, so
-- UNIT_INVENTORY_CHANGED would miss party members after our background
-- inspect completes (inspect fires no unit event we can hook here).
-- A 3s poll is a plain cache lookup — negligible cost even in 40-man.
E:AddTag("dilvl", 3, function(unit)
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
