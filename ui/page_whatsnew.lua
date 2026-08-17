-- Details! Item Level Display — Copyright (c) 2026 HK2084. All rights reserved.
-- Licensed for private use only; see LICENSE. No redistribution of modified copies.
-- ui/page_whatsnew.lua — "What's New" overview tab.
--
-- Surfaces recent FEATURES (not bugfixes — those live in the linked version
-- history) so users notice what the addon can now do. main_frame defaults to
-- this tab once after the addon version changes (see main.Open), then goes
-- back to remembering the user's last tab.
--
-- MAINTENANCE: add new feature entries on top of buildEntries() each release.
-- Keep each description to one line (~110 chars) so it doesn't wrap at the
-- minimum window width — the layout below advances by fixed steps.

local addonName, ns = ...
ns.ui = ns.ui or {}
ns.ui.pages = ns.ui.pages or {}

local page = {}
ns.ui.pages.whatsnew = page

local theme = ns.ui.theme
local W     = ns.ui.widgets
local L     = ns.L

local HISTORY_URL = "https://www.curseforge.com/wow/addons/details-item-level-plugin"

-- Curated feature log, newest first. FEATURES ONLY — bugfixes belong in the
-- version history, not here.
local function buildEntries()
    return {
        { ver = "1.5.8", items = {
            { t = L["WN_158_ILVLCOLOUR"], d = L["WN_158_ILVLCOLOUR_D"] },
        }},
        { ver = "1.5.6", items = {
            { t = L["WN_156_SEASON"], d = L["WN_156_SEASON_D"] },
        }},
        { ver = "1.5.0", items = {
            { t = L["WN_150_UI"],     d = L["WN_150_UI_D"] },
            { t = L["WN_150_SIZE"],   d = L["WN_150_SIZE_D"] },
            { t = L["WN_150_WINDOW"], d = L["WN_150_WINDOW_D"] },
        }},
        { ver = "1.4.4", items = {
            { t = L["WN_144_DANDERS"], d = L["WN_144_DANDERS_D"] },
        }},
        { ver = "1.4.3", items = {
            { t = L["WN_143_ELVUI"], d = L["WN_143_ELVUI_D"] },
        }},
    }
end

function page.Init(parent)
    local info = W.CreateInfoBar(parent, L["WHATSNEW_INFO"], 32)
    info:SetPoint("TOPLEFT",  parent, "TOPLEFT",  0, 0)
    info:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)

    -- Version-history link pinned to the bottom. Read-only EditBox so it's
    -- selectable for copy (the client can't open URLs directly).
    local linkLabel = W.CreateLabel(parent, L["WHATSNEW_HISTORY"], theme.FONT_HELPER, "secondary")
    linkLabel:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 12, 6)

    local urlBox = CreateFrame("EditBox", nil, parent)
    urlBox:SetAutoFocus(false)
    urlBox:SetFontObject(theme.FONT_HELPER)
    urlBox:SetText(HISTORY_URL)
    urlBox:SetCursorPosition(0)
    urlBox:SetPoint("LEFT",  linkLabel, "RIGHT", 6, 0)
    urlBox:SetPoint("RIGHT", parent,    "RIGHT", -12, 0)
    urlBox:SetHeight(16)
    urlBox:SetScript("OnEscapePressed",    function(self) self:ClearFocus() end)
    urlBox:SetScript("OnEditFocusGained",  function(self) self:HighlightText() end)
    urlBox:SetScript("OnTextChanged",      function(self, userInput)
        if userInput then self:SetText(HISTORY_URL); self:SetCursorPosition(0) end
    end)

    -- Scrollable feature list — FULL WIDTH, between the info bar and the link
    -- row. (Earlier bug: BOTTOMRIGHT was anchored to the short link label, so
    -- the column got pinched to ~180px and every description wrapped into a
    -- tower that overlapped the next entry.)
    local sf, content = W.CreateScrollFrame(parent, 660, 320)
    sf:SetPoint("TOPLEFT",     info,   "BOTTOMLEFT",  0, -theme.WIDGET_GAP)
    sf:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 26)
    content:SetPoint("TOPLEFT", sf, "TOPLEFT", 0, 0)

    -- Flow layout: each element anchors below the previous one, so a
    -- description that wraps to several lines pushes the next entry down
    -- instead of landing on top of it. prevX tracks the previous indent so we
    -- can shift left/right between header / title / description levels.
    local PAD_X = 14
    local prev, prevX = nil, 0
    local function place(fs, x, gap, wrap)
        if prev then
            fs:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", x - prevX, -gap)
        else
            fs:SetPoint("TOPLEFT", content, "TOPLEFT", x, -gap)
        end
        if wrap then
            fs:SetPoint("RIGHT", content, "RIGHT", -PAD_X, 0)
            fs:SetJustifyH("LEFT")
        end
        prev, prevX = fs, x
    end

    for _, block in ipairs(buildEntries()) do
        local vh = W.CreateLabel(content, "v" .. block.ver, theme.FONT_HEADING, "accent")
        place(vh, PAD_X, prev and 14 or 2)
        for _, it in ipairs(block.items) do
            local title = W.CreateLabel(content, "• " .. (it.t or "?"), theme.FONT_LABEL, "primary")
            place(title, PAD_X + 10, 8)
            local desc = W.CreateLabel(content, it.d or "", theme.FONT_HELPER, "secondary")
            place(desc, PAD_X + 20, 3, true)
        end
    end

    -- Size the scroll child to the laid-out content once frame rects resolve,
    -- so the scroll range is correct no matter how the descriptions wrapped.
    content:SetHeight(440)
    C_Timer.After(0, function()
        local top, bottom = content:GetTop(), prev and prev:GetBottom()
        if top and bottom then
            content:SetHeight(math.max(1, top - bottom + 14))
            if sf.RefreshScrollbar then sf.RefreshScrollbar() end
        end
    end)
end

if ns.ui and ns.ui.main and ns.ui.main.RegisterPage then
    ns.ui.main.RegisterPage("whatsnew", "What's New", page.Init)
end
