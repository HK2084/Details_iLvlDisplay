-- ui/page_channels.lua — Output Channels page (STUB for first ingame test).
--
-- Real implementation: 5 channel toggles + per-channel sub-settings.
-- This stub just shows a placeholder so the tab is visible and switchable
-- during the first round of UI testing.

local addonName, ns = ...
ns.ui = ns.ui or {}
ns.ui.pages = ns.ui.pages or {}

local page = {}
ns.ui.pages.channels = page

local theme = ns.ui.theme
local W     = ns.ui.widgets
local L     = ns.L

function page.Init(parent)
    local info = W.CreateInfoBar(parent, L["CHANNELS_INFO"], 32)
    info:SetPoint("TOPLEFT",  parent, "TOPLEFT",  0, 0)
    info:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)

    -- Width comes from SetPoint anchors; CreatePanel's w arg is ignored
    -- when we anchor both LEFT and RIGHT. Height stays fixed at 200.
    local stub = W.CreatePanel(parent, 1, 200, "Output Channels (WIP)")
    stub:SetPoint("TOPLEFT",  info, "BOTTOMLEFT", 0, -theme.SECTION_GAP)
    stub:SetPoint("TOPRIGHT", info, "BOTTOMRIGHT", 0, -theme.SECTION_GAP)

    local body = W.CreateLabel(stub,
        "Coming next: 5-channel toggles + per-channel sub-settings.\n"
        .. "(Details! / ElvUI / Grid2 / Danders / Blizzard DM)\n\n"
        .. "For now use slash commands:\n"
        .. "/dilvl details, /dilvl elvui on, /dilvl grid2 on, /dilvl danders on, /dilvl blizzdm",
        theme.FONT_LABEL, "secondary", nil)
    body:SetPoint("TOPLEFT",  stub, "TOPLEFT",  20, -36)
    body:SetPoint("TOPRIGHT", stub, "TOPRIGHT", -20, -36)
    body:SetJustifyH("LEFT")
end

if ns.ui and ns.ui.main and ns.ui.main.RegisterPage then
    ns.ui.main.RegisterPage("channels", "Output Channels", page.Init)
end
