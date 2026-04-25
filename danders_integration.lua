-- danders_integration.lua — optional Danders Frames integration (v2)
-- Attaches an addon-owned FontString to each Danders Frame and fills it
-- with iLvl (and optional 2P/4P set bonus). Inside-frame anchor avoids
-- collisions in stacked raid layouts.
--
-- SAFE TO LOAD WITHOUT DANDERS FRAMES: silent exit if the host is missing.
--
-- ANCHOR: parented to frame.contentOverlay (Danders' dedicated overlay
-- layer at frame-level base+25, non-interactive, lifetime-stable). Falls
-- back to the frame itself if Danders ever renames the field — visual
-- quality drops slightly but no errors.
--
-- POSITIONS (slash: /dilvl danders pos <opt>):
--   top, topright (default), topleft,
--   bottom, bottomright, bottomleft,
--   center
--
-- AUTO-DISABLE: a local SafeCall counter wraps every host-API call. After
-- 5 errors the integration silently auto-disables (db.dandersText=false),
-- routes a one-shot message via geterrorhandler() (BugSack picks it up),
-- and unregisters its callback. The rest of Details_iLvlDisplay
-- (Details!-bars, ElvUI tag, Grid2 status, Blizzard DM) keeps working.
-- Counter resets to 0 on /reload — gives Danders a fresh chance after a
-- host update.
--
-- TOGGLE: /dilvl danders on|off  (saved in SavedVariables)
--
-- UPDATE STRATEGY: event-driven, no polling.
--   - DandersFrames "OnFramesSorted" callback re-sweeps on roster sort
--   - core.lua callback registry pushes refresh on cache changes

if not DandersFrames_IsReady then return end -- host missing -> silent exit

local API = Details_iLvlDisplayAPI
if not API then return end

---------------------------------------------------------------
-- Persistent state. Stored on a global so /dilvl debug can read it.
-- callbackToken must persist (anonymous {} would get GC'd and the
-- callback silently detaches).
---------------------------------------------------------------
Details_iLvlDisplay_DandersState = Details_iLvlDisplay_DandersState or {
    callbackToken = {},
    lastRefreshAt = 0,
    refreshCount = 0,
    lastFrameCount = 0,
    dandersErrors = 0,
    lastError = nil,
    disabled = false,
}
local STATE = Details_iLvlDisplay_DandersState

local fontStrings = {} -- frame -> our FontString

---------------------------------------------------------------
-- Local kill-switch. NOT shared with core.lua's hookErrors — if Danders
-- breaks, we want the rest of the addon to keep working. Mirrors the
-- pattern at core.lua:45-60 but writes to db.dandersText (not db.enabled).
---------------------------------------------------------------
local MAX_DANDERS_ERRORS = 5
local disableSelf -- forward-declared

local function SafeCall(label, fn, ...)
    if STATE.disabled then return nil end
    if STATE.dandersErrors >= MAX_DANDERS_ERRORS then return nil end
    local ok, a, b, c = pcall(fn, ...)
    if ok then return a, b, c end
    STATE.dandersErrors = STATE.dandersErrors + 1
    STATE.lastError = ("[%s] %s"):format(label, tostring(a))
    if STATE.dandersErrors >= MAX_DANDERS_ERRORS then
        if disableSelf then disableSelf(STATE.lastError) end
    end
    return nil
end

---------------------------------------------------------------
-- Position system. Each entry: { fsPoint, framePoint, x, y }
-- Anchor parent is frame.contentOverlay (or frame itself as fallback).
---------------------------------------------------------------
local POS = {
    top         = {"TOP",         "TOP",          0, -1},
    topright    = {"TOPRIGHT",    "TOPRIGHT",    -2, -1},
    topleft     = {"TOPLEFT",     "TOPLEFT",      2, -1},
    bottom      = {"BOTTOM",      "BOTTOM",       0,  1},
    bottomright = {"BOTTOMRIGHT", "BOTTOMRIGHT", -2,  1},
    bottomleft  = {"BOTTOMLEFT",  "BOTTOMLEFT",   2,  1},
    center      = {"CENTER",      "CENTER",       0,  0},
}
local DEFAULT_POS = "topright"

local function applyAnchor(fs, frame, posKey)
    local entry = POS[posKey] or POS[DEFAULT_POS]
    -- Tolerate Danders layout changes: fall back to the frame itself if
    -- contentOverlay ever disappears (no error, just slightly worse visual).
    local parent = frame.contentOverlay or frame
    fs:ClearAllPoints()
    fs:SetParent(parent)
    fs:SetPoint(entry[1], parent, entry[2], entry[3], entry[4])
    fs:SetDrawLayer("OVERLAY", 7)
end

---------------------------------------------------------------
-- FontString management. Frames are recycled by Danders for different
-- units — we keep the FS alive and just re-set its text.
---------------------------------------------------------------
local function ensureFS(frame)
    local fs = fontStrings[frame]
    if fs then return fs end
    local parent = frame.contentOverlay or frame
    fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetJustifyH("CENTER")
    fs:SetTextColor(1, 1, 1, 1)
    fontStrings[frame] = fs
    local db = API.GetDb()
    applyAnchor(fs, frame, db and db.dandersPos or DEFAULT_POS)
    return fs
end

local function clearText(frame)
    local fs = fontStrings[frame]
    if fs then fs:SetText("") end
end

---------------------------------------------------------------
-- Per-frame update. Wraps every external API call in SafeCall so a
-- single broken frame can't poison the whole refresh.
---------------------------------------------------------------
local function updateFrame(frame)
    if not frame or STATE.disabled then return end
    local db = API.GetDb()
    if not db then return end
    -- Lazy default: existing users with db.dandersText=true but no pos.
    if not db.dandersPos then db.dandersPos = DEFAULT_POS end
    if not db.dandersText then clearText(frame) return end

    local unit = SafeCall("frame.unit", function() return frame.unit end)
    if not unit then clearText(frame) return end
    local guid = SafeCall("UnitGUID", UnitGUID, unit)
    if not guid then clearText(frame) return end

    local cached, setBonus = API.GetCacheData(guid)
    if not cached or not cached.ilvl then clearText(frame) return end

    local text = tostring(cached.ilvl)
    if db.showSetBonus and setBonus then text = text .. " " .. setBonus end
    if db.colorIlvl then text = API.GetIlvlColor(cached.ilvl) .. text .. "|r" end

    local fs = SafeCall("ensureFS", ensureFS, frame)
    if fs then SafeCall("SetText", fs.SetText, fs, text) end
end

local function refreshAll()
    if STATE.disabled then return end
    if not SafeCall("IsReady", DandersFrames_IsReady) then return end
    if not DandersFrames_IterateFrames then return end
    local count = 0
    SafeCall("IterateFrames", DandersFrames_IterateFrames, function(frame)
        count = count + 1
        updateFrame(frame)
    end)
    STATE.lastRefreshAt = GetTime()
    STATE.refreshCount = STATE.refreshCount + 1
    STATE.lastFrameCount = count
end

---------------------------------------------------------------
-- Live position change without /reload. Walks existing FontStrings
-- and re-anchors them. Called by /dilvl danders pos <opt>.
---------------------------------------------------------------
local function applyPositionToAll(posKey)
    if STATE.disabled then return end
    if not POS[posKey] then return end
    for frame, fs in pairs(fontStrings) do
        if frame and fs then
            SafeCall("applyAnchor", applyAnchor, fs, frame, posKey)
        end
    end
end

Details_iLvlDisplay_DandersApplyPos = applyPositionToAll

---------------------------------------------------------------
-- Auto-disable path. Triggered when SafeCall hits MAX_DANDERS_ERRORS.
-- Clears all text, unregisters callback, flips db.dandersText off,
-- routes message via geterrorhandler() (BugSack-compatible).
---------------------------------------------------------------
disableSelf = function(reason)
    if STATE.disabled then return end
    STATE.disabled = true
    local db = API.GetDb()
    if db then db.dandersText = false end
    for frame, fs in pairs(fontStrings) do
        if fs then pcall(fs.SetText, fs, "") end
    end
    if DandersFrames and DandersFrames.UnregisterCallback then
        pcall(DandersFrames.UnregisterCallback, DandersFrames,
            STATE.callbackToken, "OnFramesSorted")
    end
    local msg = "Details! iLvl Display: Danders integration auto-disabled after "
        .. MAX_DANDERS_ERRORS .. " errors. Last: " .. tostring(reason)
    pcall(geterrorhandler(), msg)
end

---------------------------------------------------------------
-- Diagnostics for /dilvl debug — extends the --- Danders Frames ---
-- section with position, error counter, disabled state, last error.
---------------------------------------------------------------
Details_iLvlDisplay_DandersDebug = function()
    local lines = { "  --- Danders Frames ---" }
    if not DandersFrames_IsReady or not DandersFrames_IsReady() then
        lines[#lines + 1] = "    host: not ready"
        return lines
    end
    local db = API.GetDb()
    lines[#lines + 1] = string.format("    position: %s   fontSize: %d",
        (db and db.dandersPos) or DEFAULT_POS,
        (db and db.dandersFontSize) or 10)
    lines[#lines + 1] = string.format("    errors: %d/%d   disabled: %s",
        STATE.dandersErrors, MAX_DANDERS_ERRORS, tostring(STATE.disabled))
    if STATE.lastError then
        lines[#lines + 1] = "    lastError: " .. STATE.lastError
    end
    lines[#lines + 1] = string.format("    refreshes: %d  last %.1fs ago  lastCount: %d",
        STATE.refreshCount,
        STATE.lastRefreshAt > 0 and (GetTime() - STATE.lastRefreshAt) or 0,
        STATE.lastFrameCount)
    if STATE.disabled then return lines end
    if not DandersFrames_IterateFrames then
        lines[#lines + 1] = "    DandersFrames_IterateFrames: missing"
        return lines
    end
    local idx = 0
    DandersFrames_IterateFrames(function(frame)
        idx = idx + 1
        if idx > 8 then return end
        local unit = frame.unit
        local guid = unit and UnitGUID(unit) or nil
        local cached = guid and select(1, API.GetCacheData(guid)) or nil
        local fs = fontStrings[frame]
        local fsText = fs and fs:GetText() or "<no FS>"
        lines[#lines + 1] = string.format("    [%d] unit:%s  guid:%s  cache:%s  fs:%s",
            idx,
            tostring(unit),
            guid and "yes" or "no",
            cached and tostring(cached.ilvl) or "no",
            (fsText == "" or fsText == nil) and "<empty>" or fsText)
    end)
    if idx == 0 then
        lines[#lines + 1] = "    no frames returned by IterateFrames"
    end
    return lines
end

---------------------------------------------------------------
-- Init: defer until Danders is fully loaded. PLAYER_LOGIN is usually
-- enough; PLAYER_ENTERING_WORLD is the safety-net retry.
---------------------------------------------------------------
local function tryInit(self)
    if not DandersFrames_IsReady() then return false end
    if not DandersFrames or not DandersFrames.RegisterCallback then return false end
    SafeCall("RegisterCallback", DandersFrames.RegisterCallback,
        DandersFrames, STATE.callbackToken, "OnFramesSorted", refreshAll)
    API:RegisterCallback("danders", refreshAll)
    refreshAll()
    self:UnregisterAllEvents()
    return true
end

local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:SetScript("OnEvent", function(self)
    if not tryInit(self) then
        self:RegisterEvent("PLAYER_ENTERING_WORLD")
    end
end)
