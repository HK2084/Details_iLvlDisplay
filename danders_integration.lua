-- danders_integration.lua — optional Danders Frames integration
-- Attaches an addon-owned FontString to each Danders Frame and fills
-- it with iLvl (and optional 2P/4P set bonus).
--
-- SAFE TO LOAD WITHOUT DANDERS FRAMES: if the host is missing, this
-- file does nothing — no errors, no prints, no performance cost.
--
-- USAGE: enable via /dilvl danders on  (saved between sessions)
--
-- UPDATE STRATEGY: event-driven, no polling.
--   - DandersFrames "OnFramesSorted" callback re-sweeps when roster sorts
--   - core.lua callback registry pushes refresh on cache changes
-- During 3h farming with no group changes: zero extra work.

if not DandersFrames_IsReady then return end -- host missing -> silent exit

local API = Details_iLvlDisplayAPI
if not API then return end

---------------------------------------------------------------
-- Per-frame FontString cache
-- frames are recycled by Danders for different units — we don't
-- destroy the FontString on unit swap, just re-set its text.
---------------------------------------------------------------
local fontStrings = {} -- frame -> FontString

local function ensureFS(frame)
    local fs = fontStrings[frame]
    if fs then return fs end
    fs = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("TOP", frame, "TOP", 0, -2)
    fs:SetJustifyH("CENTER")
    fontStrings[frame] = fs
    return fs
end

local function clearText(frame)
    local fs = fontStrings[frame]
    if fs then fs:SetText("") end
end

---------------------------------------------------------------
-- Update one frame from cache
---------------------------------------------------------------
local function updateFrame(frame)
    if not frame then return end
    local db = API.GetDb()
    if not db or not db.dandersText then clearText(frame) return end

    local unit = frame.unit
    if not unit then clearText(frame) return end

    local guid = UnitGUID(unit)
    if not guid then clearText(frame) return end

    local cached, setBonus = API.GetCacheData(guid)
    if not cached or not cached.ilvl then clearText(frame) return end

    local text = tostring(cached.ilvl)
    if db.showSetBonus and setBonus then
        text = text .. " " .. setBonus
    end
    if db.colorIlvl then
        text = API.GetIlvlColor(cached.ilvl) .. text .. "|r"
    end
    ensureFS(frame):SetText(text)
end

local function refreshAll()
    if not DandersFrames_IsReady() then return end
    if DandersFrames_IterateFrames then
        DandersFrames_IterateFrames(updateFrame)
    end
end

---------------------------------------------------------------
-- Init: defer until Danders Frames is fully loaded.
-- Even with OptionalDeps in TOC, Danders may finish init after us
-- (its own load logic). Watch PLAYER_LOGIN, fall back to
-- PLAYER_ENTERING_WORLD if not ready yet.
---------------------------------------------------------------
local function tryInit(self)
    if DandersFrames_IsReady() and DandersFrames and DandersFrames.RegisterCallback then
        DandersFrames.RegisterCallback({}, "OnFramesSorted", refreshAll)
        API:RegisterCallback("danders", refreshAll)
        refreshAll()
        self:UnregisterAllEvents()
        return true
    end
    return false
end

local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:SetScript("OnEvent", function(self)
    if not tryInit(self) then
        self:RegisterEvent("PLAYER_ENTERING_WORLD")
    end
end)
