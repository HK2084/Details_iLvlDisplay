-- grid2_status.lua — optional Grid2 raid frame integration
-- Registers a custom Grid2 status "dilvl" that shows iLvl
-- (and optional 2P/4P tier set bonus) in any Grid2 indicator
-- the user assigns it to (corner-text, side-text, center, ...).
--
-- SAFE TO LOAD WITHOUT GRID2: if Grid2 is not installed this file
-- does nothing — no errors, no prints, no performance cost.
--
-- USAGE (after enabling via /dilvl grid2 on):
--   Grid2 GUI -> Indicators -> pick a text indicator
--   -> add status "dilvl" -> assign indicator
--
-- TOGGLE: /dilvl grid2 on|off  (saved between sessions)
--
-- UPDATE STRATEGY: event-driven, no polling timer.
-- core.lua fires registered callbacks after: INSPECT_READY, gear swap,
-- GROUP_ROSTER_UPDATE. Our callback calls status:UpdateAllUnits()
-- which re-renders all visible Grid2 frames immediately.

if not Grid2 or not Grid2.statusPrototype then return end -- no Grid2 -> silent exit

local API = Details_iLvlDisplayAPI
if not API then return end -- core.lua didn't load (shouldn't happen)

local DiLvl = Grid2.statusPrototype:new("dilvl")
-- Fallback colour resolver: returns dbx.color1 / color2 / ... so the user can
-- pick a fixed iLvl text colour in Grid2's status options panel. Used whenever
-- our own tier colouring is switched off.
local libGetColor = Grid2.statusLibrary.GetColor

-- Every entry point gates on db.enabled as well as its own channel switch.
-- db.enabled is the addon-wide master switch; without it here, /dilvl off
-- silenced every other channel and left the Grid2 number on the frames.
local function channelOn(db)
    return db and db.enabled and db.grid2Status
end

function DiLvl:IsActive(unit)
    local db = API.GetDb()
    if not channelOn(db) then return false end
    local guid = API.SafeUnitGUID(unit)  -- secret-safe: nil (not a throw) inside instances
    if not guid then return false end
    local cached = API.GetCacheData(guid)
    return cached ~= nil and cached.ilvl ~= nil
end

function DiLvl:GetText(unit)
    local db = API.GetDb()
    if not channelOn(db) then return "" end
    local guid = API.SafeUnitGUID(unit)  -- secret-safe: nil (not a throw) inside instances
    if not guid then return "" end
    local cached, setBonus = API.GetCacheData(guid)
    if not cached or not cached.ilvl then return "" end
    if db.showSetBonus and setBonus then
        return tostring(cached.ilvl) .. " " .. setBonus
    end
    return tostring(cached.ilvl)
end

-- Honour /dilvl color here too. Grid2's library resolver returns a CONSTANT
-- (dbx.color1, GridUtils.lua:220-223), so it cannot depend on the unit — which
-- meant Details! bars and the ElvUI tag were tier-coloured while Grid2 stayed
-- flat white, and toggling /dilvl color changed nothing on Grid2 frames.
function DiLvl:GetColor(unit)
    local db = API.GetDb()
    if db and db.colorIlvl then
        local guid = API.SafeUnitGUID(unit)
        local cached = guid and API.GetCacheData(guid)
        if cached and cached.ilvl then
            return API.GetIlvlColorRGB(cached.ilvl)
        end
    end
    return libGetColor(self, unit)
end

-- Grid2's statusPrototype:GetCount() returns the NUMBER 0 (GridStatus.lua:29),
-- and the "Show stack" text handler does `if count then SetText(count)`
-- (IndicatorText.lua:191) — 0 is truthy in Lua, so an indicator with that
-- checkbox on would render "0" instead of the item level. Returning nil sends
-- it down the normal text path.
function DiLvl:GetCount()
    return nil
end

-- No own events: core.lua pushes refreshes through the callback registry.
-- Idle = zero CPU.
function DiLvl:OnEnable() end
function DiLvl:OnDisable() end
function DiLvl:UpdateDB() end

local function CreateStatusDilvl(baseKey, dbx)
    Grid2:RegisterStatus(DiLvl, {"text", "color"}, baseKey, dbx)
    return DiLvl
end

Grid2.setupFunc["dilvl"] = CreateStatusDilvl

Grid2:DbSetStatusDefaultValue("dilvl", {
    type = "dilvl",
    color1 = {r=1, g=1, b=1, a=1},
})

API:RegisterCallback("grid2", function()
    if DiLvl.UpdateAllUnits then pcall(DiLvl.UpdateAllUnits, DiLvl) end
end)
