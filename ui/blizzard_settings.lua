-- Details! Item Level Display — Copyright (c) 2026 HK2084. All rights reserved.
-- Licensed for private use only; see LICENSE. No redistribution of modified copies.
-- ui/blizzard_settings.lua — register addon in Blizzard's native Settings panel.
--
-- Per deep-dive (04_blizzard_settings_api.md): InterfaceOptions_AddCategory is
-- removed in 12.0+. We use Settings.RegisterCanvasLayoutCategory + an embedded
-- UIPanelButtonTemplate that opens our standalone window. The native panel
-- itself stays minimal — single button + brief explanation — because the real
-- UI lives in main_frame.lua.

local addonName, ns = ...
ns.ui = ns.ui or {}
local blizz = {}
ns.ui.blizz = blizz

local theme = ns.ui.theme
local W     = ns.ui.widgets
local safe  = ns.ui.safe
local L     = ns.L

blizz.categoryID = nil  -- stash for Settings.OpenToCategory()

local function BuildCanvas()
    local panel = CreateFrame("Frame")
    panel.name = L["Details! iLvl Display"]
    panel:SetSize(800, 600)

    local title = panel:CreateFontString(nil, "OVERLAY", theme.FONT_TITLE)
    title:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -16)
    title:SetText(L["Details! iLvl Display"])
    theme.SetTextColor(title, "accent")

    local body = panel:CreateFontString(nil, "OVERLAY", theme.FONT_LABEL)
    body:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12)
    body:SetWidth(700)
    body:SetJustifyH("LEFT")
    body:SetText(L["GENERAL_INFO"])
    theme.SetTextColor(body, "secondary")

    local btn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    btn:SetSize(220, 28)
    btn:SetPoint("TOPLEFT", body, "BOTTOMLEFT", 0, -20)
    btn:SetText(L["Open Settings"])
    btn:SetScript("OnClick", safe.WrapScript("Blizz:OpenSettings", function()
        if ns.ui and ns.ui.main then ns.ui.main.Open() end
    end))

    local hint = panel:CreateFontString(nil, "OVERLAY", theme.FONT_HELPER)
    hint:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -16)
    hint:SetText(L["BLIZZ_PANEL_SLASH_HINT"])
    theme.SetTextColor(hint, "disabled")

    return panel
end

---------------------------------------------------------------
-- Registration. Called once after ADDON_LOADED (init.lua wires this).
-- Settings API is stable since 10.0 and present in all 12.0.x.
---------------------------------------------------------------
function blizz.Register()
    if blizz.registered then return end
    if not (Settings and Settings.RegisterCanvasLayoutCategory) then
        -- defensive: somehow the API is missing (very unlikely on 12.0+)
        return
    end

    local panel = BuildCanvas()
    local category = Settings.RegisterCanvasLayoutCategory(panel, L["Details! iLvl Display"])
    Settings.RegisterAddOnCategory(category)
    blizz.categoryID = category:GetID()
    blizz.registered = true
end

-- Programmatic open (used by /dilvl ui when user wants the native panel).
-- Note: our standalone Open() is usually preferred; this is the fallback.
function blizz.OpenNative()
    if blizz.categoryID and Settings and Settings.OpenToCategory then
        Settings.OpenToCategory(blizz.categoryID)
    end
end

---------------------------------------------------------------
-- Self-register at PLAYER_LOGIN. Wrapped in pcall — if Settings API throws
-- for any reason (very unlikely on 12.0+), the standalone window via
-- /dilvl ui still works.
---------------------------------------------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function(self)
    local ok, err = pcall(blizz.Register)
    if not ok then
        local handler = geterrorhandler()
        if handler then
            pcall(handler, "Details_iLvlDisplay Blizzard Settings register failed: " .. tostring(err))
        end
    end
    self:UnregisterAllEvents()
end)
