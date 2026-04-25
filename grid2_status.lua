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
-- Inherit standard color resolver: returns dbx.color1 / color2 / ... so the
-- user can pick the iLvl text color directly in Grid2's status options panel.
DiLvl.GetColor = Grid2.statusLibrary.GetColor

function DiLvl:IsActive(unit)
    local db = API.GetDb()
    if not db or not db.grid2Status then return false end
    local guid = UnitGUID(unit)
    if not guid then return false end
    local cached = API.GetCacheData(guid)
    return cached ~= nil and cached.ilvl ~= nil
end

function DiLvl:GetText(unit)
    local db = API.GetDb()
    if not db or not db.grid2Status then return "" end
    local guid = UnitGUID(unit)
    if not guid then return "" end
    local cached, setBonus = API.GetCacheData(guid)
    if not cached or not cached.ilvl then return "" end
    if db.showSetBonus and setBonus then
        return tostring(cached.ilvl) .. " " .. setBonus
    end
    return tostring(cached.ilvl)
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
