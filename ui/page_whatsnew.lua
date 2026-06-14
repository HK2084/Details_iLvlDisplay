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

    -- Scrollable feature list between the info bar and the link row.
    local sf, content = W.CreateScrollFrame(parent, 660, 320)
    sf:SetPoint("TOPLEFT",     info,      "BOTTOMLEFT", 0, -theme.WIDGET_GAP)
    sf:SetPoint("BOTTOMRIGHT", linkLabel, "TOPRIGHT",   0, theme.WIDGET_GAP)
    content:SetPoint("TOPLEFT", sf, "TOPLEFT", 0, 0)

    local PAD_X = 12
    local y = -4
    for _, block in ipairs(buildEntries()) do
        local vh = W.CreateLabel(content, "v" .. block.ver, theme.FONT_HEADING, "accent")
        vh:SetPoint("TOPLEFT", content, "TOPLEFT", PAD_X, y)
        y = y - 24
        for _, it in ipairs(block.items) do
            local title = W.CreateLabel(content, "• " .. (it.t or "?"), theme.FONT_LABEL, "primary")
            title:SetPoint("TOPLEFT", content, "TOPLEFT", PAD_X + 6, y)
            y = y - 18
            local desc = W.CreateLabel(content, it.d or "", theme.FONT_HELPER, "secondary")
            desc:SetPoint("TOPLEFT", content, "TOPLEFT", PAD_X + 18, y)
            desc:SetPoint("RIGHT",   content, "RIGHT", -PAD_X, 0)
            desc:SetJustifyH("LEFT")
            y = y - 22
        end
        y = y - 10
    end
    content:SetHeight(-y + 8)
end

if ns.ui and ns.ui.main and ns.ui.main.RegisterPage then
    ns.ui.main.RegisterPage("whatsnew", "What's New", page.Init)
end
