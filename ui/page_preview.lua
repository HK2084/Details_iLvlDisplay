-- ui/page_preview.lua — Live Preview page (STUB for first ingame test).

local addonName, ns = ...
ns.ui = ns.ui or {}
ns.ui.pages = ns.ui.pages or {}

local page = {}
ns.ui.pages.preview = page

local theme = ns.ui.theme
local W     = ns.ui.widgets
local L     = ns.L

function page.Init(parent)
    local info = W.CreateInfoBar(parent, L["PREVIEW_INFO"], 32)
    info:SetPoint("TOPLEFT",  parent, "TOPLEFT",  0, 0)
    info:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)

    local stub = W.CreatePanel(parent, parent:GetWidth(), 300, "Live Preview (WIP)")
    stub:SetPoint("TOPLEFT",  info, "BOTTOMLEFT", 0, -theme.SECTION_GAP)
    stub:SetPoint("TOPRIGHT", info, "BOTTOMRIGHT", 0, -theme.SECTION_GAP)

    local body = W.CreateLabel(stub,
        "Coming next: mock Details!-bars, mock unit frames, mock nameplate.\n"
        .. "All update live as you change settings on other tabs.",
        theme.FONT_LABEL, "secondary", stub:GetWidth() - 40)
    body:SetPoint("TOPLEFT", stub, "TOPLEFT", 20, -36)
end

if ns.ui and ns.ui.main and ns.ui.main.RegisterPage then
    ns.ui.main.RegisterPage("preview", "Live Preview", page.Init)
end
