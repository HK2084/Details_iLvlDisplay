-- ui/preview_widgets.lua — Live-Preview Mock-Frames + Dirty-Flag Refresh.
--
-- DESIGN:
--   - Two factory funcs: PopulateDamageMeter(parent, db) builds mock Details!/
--     BlizzDM bars; PopulateUnitFrames(parent, db) builds mock Danders/Grid2/
--     ElvUI unit-frame.
--   - Each mock is created ONCE on first populate. Subsequent updates flow
--     through the Refresh() function — only text/anchor/color change, frames
--     are NOT rebuilt. Prevents frame churn on every slider drag.
--   - Dirty-flag pattern (mirrors blizzdm.lua:909-997 throttled refresh):
--     setter calls MarkDirty(); a 10Hz NewTicker coalesces multiple changes
--     into a single Refresh() per 100ms window. Self-cancels when no dirty.
--   - Mock data is constant ("Razul", iLvl 263, etc.) — the iLvl rendering
--     reflects the user's current db settings (color, set-bonus, layout,
--     position, danders pos+size, ElvUI tag format).
--
-- All visual styling pulled from ui/theme.lua so re-theming is single-source.

local addonName, ns = ...
ns.ui = ns.ui or {}
local preview = {}
ns.ui.preview = preview

local theme = ns.ui.theme
local L     = ns.L

---------------------------------------------------------------
-- Mock fixture: same data used across all surfaces so previews look
-- consistent. iLvl + setBonus values chosen to span tier colors.
---------------------------------------------------------------
local MOCK_PLAYERS = {
    { name = "Razul",    ilvl = 263, setBonus = "4P", dmg = "67K", classColor = {0.78, 0.61, 0.43} }, -- Druid
    { name = "Nairah",   ilvl = 261, setBonus = "2P", dmg = "61K", classColor = {0.96, 0.55, 0.73} }, -- Paladin
    { name = "Quinroth", ilvl = 259, setBonus = nil,  dmg = "58K", classColor = {0.41, 0.80, 0.94} }, -- Mage
}

---------------------------------------------------------------
-- iLvl color from current db.colorIlvl. Mirrors core.lua's tier-color
-- bands; pure function for the preview's use only.
---------------------------------------------------------------
local function ilvlColor(ilvl, enabled)
    if not enabled then return "|cFFFFFFFF" end
    if ilvl >= 290 then return "|cFFFF8000" end -- legendary orange (BiS)
    if ilvl >= 270 then return "|cFFA335EE" end -- epic purple (high)
    if ilvl >= 250 then return "|cFF0070DD" end -- rare blue (mid)
    if ilvl >= 230 then return "|cFF1EFF00" end -- uncommon green (low)
    return "|cFF9D9D9D"                          -- common grey (base)
end

---------------------------------------------------------------
-- Format a single iLvl tag string from db state. Used by both DM bars and
-- ElvUI tag preview. Respects color, setBonus, position.
---------------------------------------------------------------
local function formatIlvlTag(ilvl, setBonus, db)
    local colorOn   = db and db.colorIlvl
    local bonusOn   = db and db.showSetBonus
    local c = ilvlColor(ilvl, colorOn)
    local tag = c .. "[" .. ilvl .. "]|r"
    if bonusOn and setBonus then
        tag = tag .. " " .. c .. "[" .. setBonus .. "]|r"
    end
    return tag
end

---------------------------------------------------------------
-- DAMAGE METER PREVIEW — 3 mock Details!-style rows.
-- Each row: small statusbar with class-color fill + rank# + name + iLvl tag
-- + dmg value. Position-of-tag flips with db.ilvlPosition.
---------------------------------------------------------------
local dmRows = {}  -- {[i] = {bar, nameFS, ilvlFS, dmgFS, statusbar}}

local function CreateDMRow(parent, index, mock)
    local row = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    row:SetHeight(22)
    row:SetPoint("TOPLEFT",  parent, "TOPLEFT",  10, -28 - (index - 1) * 26)
    row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -10, -28 - (index - 1) * 26)

    -- Background-fill statusbar (class-colored, fixed 80% width for variety)
    local sb = CreateFrame("StatusBar", nil, row)
    sb:SetAllPoints(row)
    sb:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    sb:SetMinMaxValues(0, 100)
    sb:SetValue(100 - (index - 1) * 12)  -- 100, 88, 76
    sb:SetStatusBarColor(mock.classColor[1], mock.classColor[2], mock.classColor[3], 0.7)
    row.statusbar = sb

    -- Text overlay (rank + name + iLvl + dmg)
    local textFS = row:CreateFontString(nil, "OVERLAY", theme.FONT_LABEL)
    textFS:SetPoint("LEFT",  row, "LEFT",  6, 0)
    textFS:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    textFS:SetJustifyH("LEFT")
    textFS:SetTextColor(1, 1, 1, 1)
    row.textFS = textFS

    -- DPS/dmg on right side
    local dmgFS = row:CreateFontString(nil, "OVERLAY", theme.FONT_LABEL)
    dmgFS:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    dmgFS:SetTextColor(1, 1, 1, 1)
    dmgFS:SetText(mock.dmg)
    row.dmgFS = dmgFS

    return row
end

local function UpdateDMRow(row, index, mock, db)
    local tag = formatIlvlTag(mock.ilvl, mock.setBonus, db)
    local left
    if db and db.ilvlPosition == "left" then
        left = string.format("%d. %s %s", index, tag, mock.name)
    else
        left = string.format("%d. %s %s", index, mock.name, tag)
    end
    row.textFS:SetText(left)
end

---------------------------------------------------------------
-- UNIT FRAME PREVIEW — mock Danders frame + mock Grid2 cell + mock ElvUI tag.
-- Anchored side-by-side inside the Unit Frame Preview pane.
---------------------------------------------------------------
local ufFrames = {}  -- {dandersFrame, grid2Frame, elvuiFrame, ...}

-- POS table mirror from danders_integration.lua — keeps preview anchor
-- behavior in lockstep with the real addon.
local DANDERS_POS = {
    top         = {"TOP",         "TOP",          0, -1},
    topright    = {"TOPRIGHT",    "TOPRIGHT",    -2, -1},
    topleft     = {"TOPLEFT",     "TOPLEFT",      2, -1},
    bottom      = {"BOTTOM",      "BOTTOM",       0,  1},
    bottomright = {"BOTTOMRIGHT", "BOTTOMRIGHT", -2,  1},
    bottomleft  = {"BOTTOMLEFT",  "BOTTOMLEFT",   2,  1},
    center      = {"CENTER",      "CENTER",       0,  0},
    above       = {"BOTTOM",      "TOP",          0,  2},
    aboveleft   = {"BOTTOMLEFT",  "TOPLEFT",      2,  2},
    aboveright  = {"BOTTOMRIGHT", "TOPRIGHT",    -2,  2},
    below       = {"TOP",         "BOTTOM",       0, -2},
    belowleft   = {"TOPLEFT",     "BOTTOMLEFT",   2, -2},
    belowright  = {"TOPRIGHT",    "BOTTOMRIGHT", -2, -2},
}

local function CreateMockDandersFrame(parent)
    -- Outer mock unit-frame (rectangle with class-color background)
    local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    frame:SetSize(120, 60)
    frame:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, -32)
    theme.ApplyBackdrop(frame, "panel")

    -- HP bar (class-colored, fills frame)
    local hpBar = CreateFrame("StatusBar", nil, frame)
    hpBar:SetAllPoints(frame)
    hpBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    hpBar:SetMinMaxValues(0, 100)
    hpBar:SetValue(72)
    hpBar:SetStatusBarColor(0.78, 0.61, 0.43, 0.75)  -- Druid color
    frame.hpBar = hpBar

    -- Name text (centered)
    local nameFS = frame:CreateFontString(nil, "OVERLAY", theme.FONT_LABEL)
    nameFS:SetPoint("CENTER", frame, "CENTER", 0, 4)
    nameFS:SetText("Razul")
    nameFS:SetTextColor(1, 1, 1, 1)
    frame.nameFS = nameFS

    -- HP text below name
    local hpFS = frame:CreateFontString(nil, "OVERLAY", theme.FONT_HELPER)
    hpFS:SetPoint("CENTER", frame, "CENTER", 0, -8)
    hpFS:SetText("427K/427K")
    hpFS:SetTextColor(1, 1, 1, 0.8)
    frame.hpFS = hpFS

    -- Our iLvl-overlay FontString (the addon's actual output, positioned per db)
    local ilvlFS = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ilvlFS:SetText("263")
    frame.ilvlFS = ilvlFS

    -- Frame label (above-left, secondary text)
    local label = parent:CreateFontString(nil, "OVERLAY", theme.FONT_HELPER)
    label:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", 0, 2)
    label:SetText("Danders")
    theme.SetTextColor(label, "secondary")

    return frame
end

local function UpdateMockDandersFrame(frame, db)
    local posKey = (db and db.dandersPos) or "topright"
    local fontSize = (db and db.dandersFontSize) or 10
    local entry = DANDERS_POS[posKey] or DANDERS_POS.topright

    frame.ilvlFS:ClearAllPoints()
    frame.ilvlFS:SetPoint(entry[1], frame, entry[2], entry[3], entry[4])

    -- Apply size + color
    local path, _, flags = frame.ilvlFS:GetFont()
    if path then frame.ilvlFS:SetFont(path, fontSize, flags or "") end

    local ilvl = 263
    local setBonus = "4P"
    local colorOn = db and db.colorIlvl
    local bonusOn = db and db.showSetBonus
    local text = ilvlColor(ilvl, colorOn) .. tostring(ilvl) .. "|r"
    if bonusOn then text = text .. " " .. ilvlColor(ilvl, colorOn) .. setBonus .. "|r" end
    frame.ilvlFS:SetText(text)
end

local function CreateMockGrid2Cell(parent)
    local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    frame:SetSize(60, 60)
    frame:SetPoint("TOPLEFT", parent, "TOPLEFT", 145, -32)
    theme.ApplyBackdrop(frame, "panel")

    local hp = CreateFrame("StatusBar", nil, frame)
    hp:SetAllPoints(frame)
    hp:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    hp:SetMinMaxValues(0, 100); hp:SetValue(72)
    hp:SetStatusBarColor(0.96, 0.55, 0.73, 0.75)  -- Paladin color

    -- Grid2 typically: name in middle, indicator at a corner
    local nameFS = frame:CreateFontString(nil, "OVERLAY", theme.FONT_HELPER)
    nameFS:SetPoint("CENTER", frame, "CENTER", 0, 0)
    nameFS:SetText("Náirah")
    nameFS:SetTextColor(1, 1, 1, 1)

    -- iLvl indicator at TOP-RIGHT (typical Grid2 corner-text spot)
    local ilvlFS = frame:CreateFontString(nil, "OVERLAY", theme.FONT_HELPER)
    ilvlFS:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -2, -2)
    ilvlFS:SetText("261")
    frame.ilvlFS = ilvlFS

    local label = parent:CreateFontString(nil, "OVERLAY", theme.FONT_HELPER)
    label:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", 0, 2)
    label:SetText("Grid2")
    theme.SetTextColor(label, "secondary")

    return frame
end

local function UpdateMockGrid2Cell(frame, db)
    local ilvl = 261
    frame.ilvlFS:SetText(ilvlColor(ilvl, db and db.colorIlvl) .. tostring(ilvl) .. "|r")
end

local function CreateMockElvUITag(parent)
    -- ElvUI shows a tag inline with the unit-frame name. We render a simplified
    -- mock unit-frame (HP bar + name+tag) similar in style to ElvUI's defaults.
    local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    frame:SetSize(160, 30)
    frame:SetPoint("TOPLEFT", parent, "TOPLEFT", 215, -32)
    theme.ApplyBackdrop(frame, "panel")

    local hp = CreateFrame("StatusBar", nil, frame)
    hp:SetAllPoints(frame)
    hp:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    hp:SetMinMaxValues(0, 100); hp:SetValue(72)
    hp:SetStatusBarColor(0.41, 0.80, 0.94, 0.75)  -- Mage color

    local textFS = frame:CreateFontString(nil, "OVERLAY", theme.FONT_LABEL)
    textFS:SetPoint("LEFT",  frame, "LEFT",  6, 0)
    textFS:SetPoint("RIGHT", frame, "RIGHT", -6, 0)
    textFS:SetJustifyH("LEFT")
    textFS:SetTextColor(1, 1, 1, 1)
    frame.textFS = textFS

    local label = parent:CreateFontString(nil, "OVERLAY", theme.FONT_HELPER)
    label:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", 0, 2)
    label:SetText("ElvUI")
    theme.SetTextColor(label, "secondary")

    return frame
end

local function UpdateMockElvUITag(frame, db)
    local ilvl = 259
    local c = ilvlColor(ilvl, db and db.colorIlvl)
    -- Tag format: [dilvl] = bracketed, [dilvl:plain] = bare
    local plain = db and db.elvuiTagPlain
    local tag = plain and (c .. tostring(ilvl) .. "|r")
                       or  (c .. "[" .. ilvl .. "]|r")
    frame.textFS:SetText("Quinroth " .. tag)
end

---------------------------------------------------------------
-- Public: PopulateDamageMeter — build (or re-use) the 3 mock rows in the
-- Damage Meter Preview pane. Wipes any previous body text.
---------------------------------------------------------------
function preview.PopulateDamageMeter(parent)
    if not parent then return end
    -- Clear placeholder children
    for _, child in ipairs({parent:GetChildren()}) do
        if not child._previewKeep then
            child:Hide()
            child:ClearAllPoints()
            child:SetParent(nil)
        end
    end
    -- Also wipe any plain FontStrings from earlier text-only placeholder
    for _, region in ipairs({parent:GetRegions()}) do
        if region:GetObjectType() == "FontString" and not region._titleKeep then
            region:Hide()
        end
    end

    dmRows = {}
    local db = ns.db or _G.Details_iLvlDisplayDB
    for i, mock in ipairs(MOCK_PLAYERS) do
        local row = CreateDMRow(parent, i, mock)
        dmRows[i] = { row = row, mock = mock }
        UpdateDMRow(row, i, mock, db)
    end
end

---------------------------------------------------------------
-- Public: PopulateUnitFrames — build the 3 mock unit-frames (Danders, Grid2,
-- ElvUI) in the Unit Frame Preview pane.
---------------------------------------------------------------
function preview.PopulateUnitFrames(parent)
    if not parent then return end
    for _, child in ipairs({parent:GetChildren()}) do
        if not child._previewKeep then
            child:Hide()
            child:ClearAllPoints()
            child:SetParent(nil)
        end
    end
    for _, region in ipairs({parent:GetRegions()}) do
        if region:GetObjectType() == "FontString" and not region._titleKeep then
            region:Hide()
        end
    end

    local db = ns.db or _G.Details_iLvlDisplayDB
    ufFrames.danders = CreateMockDandersFrame(parent)
    ufFrames.grid2   = CreateMockGrid2Cell(parent)
    ufFrames.elvui   = CreateMockElvUITag(parent)
    UpdateMockDandersFrame(ufFrames.danders, db)
    UpdateMockGrid2Cell(ufFrames.grid2, db)
    UpdateMockElvUITag(ufFrames.elvui, db)
end

---------------------------------------------------------------
-- Refresh: walk all current mock-frames and update them in-place.
-- NEVER re-create frames here — that would churn on every slider drag.
---------------------------------------------------------------
function preview.Refresh()
    local db = ns.db or _G.Details_iLvlDisplayDB
    for i, entry in ipairs(dmRows) do
        if entry.row then UpdateDMRow(entry.row, i, entry.mock, db) end
    end
    if ufFrames.danders then UpdateMockDandersFrame(ufFrames.danders, db) end
    if ufFrames.grid2   then UpdateMockGrid2Cell(ufFrames.grid2, db) end
    if ufFrames.elvui   then UpdateMockElvUITag(ufFrames.elvui, db) end
end

---------------------------------------------------------------
-- Dirty-flag + 10Hz throttled refresh (mirrors blizzdm.lua:909-997 pattern).
-- Coalesces rapid slider drags into ~100ms refresh windows so a wild drag
-- doesn't fire Refresh() 60x per second.
---------------------------------------------------------------
local dirty = false
local ticker = nil

function preview.MarkDirty()
    dirty = true
    if not ticker then
        ticker = C_Timer.NewTicker(0.1, function(self)
            if dirty then
                local ok, err = pcall(preview.Refresh)
                if not ok then
                    local handler = geterrorhandler()
                    if handler then
                        pcall(handler, "Details_iLvlDisplay Preview Refresh: " .. tostring(err))
                    end
                end
                dirty = false
            else
                -- No work for one tick — cancel ticker until next dirty.
                self:Cancel()
                ticker = nil
            end
        end)
    end
end
