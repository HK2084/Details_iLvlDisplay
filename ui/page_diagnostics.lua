-- ui/page_diagnostics.lua — Diagnostics page.
--
-- Shows UI-layer error counts (from safe_callback.lua state) + a button to
-- reset them without /reload. Real /dilvl debug output is shipped via slash
-- (we don't duplicate it here yet — that's Phase 4 polish).

local addonName, ns = ...
ns.ui = ns.ui or {}
ns.ui.pages = ns.ui.pages or {}

local page = {}
ns.ui.pages.diagnostics = page

local theme = ns.ui.theme
local W     = ns.ui.widgets
local safe  = ns.ui.safe
local L     = ns.L

function page.Init(parent)
    local info = W.CreateInfoBar(parent, L["DIAGNOSTICS_INFO"], 32)
    info:SetPoint("TOPLEFT",  parent, "TOPLEFT",  0, 0)
    info:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)

    local panel = W.CreatePanel(parent, 1, 300, "UI Layer Errors")
    panel:SetPoint("TOPLEFT",  info, "BOTTOMLEFT", 0, -theme.SECTION_GAP)
    panel:SetPoint("TOPRIGHT", info, "BOTTOMRIGHT", 0, -theme.SECTION_GAP)

    -- Status text — rebuilt each Init so it's fresh on tab-switch.
    local lines = safe.GetDiagnostics()
    local text = table.concat(lines, "\n")
    local body = W.CreateLabel(panel, text, theme.FONT_LABEL, "primary", nil)
    body:SetPoint("TOPLEFT",  panel, "TOPLEFT",  20, -36)
    body:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -20, -36)
    body:SetJustifyV("TOP")
    body:SetJustifyH("LEFT")

    -- Reset button. C_Timer.After(0, ...) defers the SwitchTab so we're not
    -- re-entering tab logic while still inside this button's OnClick handler
    -- (which would SetParent(nil) the button mid-execution).
    local resetBtn = W.CreateButton(panel, L["Reset UI Error Counters"], 200, 24,
        function()
            safe.ResetAll()
            C_Timer.After(0, function()
                if ns.ui.main then ns.ui.main.SwitchTab("diagnostics") end
            end)
        end)
    resetBtn:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 20, 20)

    -- Hint about full /dilvl debug
    local hint = W.CreateLabel(panel,
        "For full diagnostics (cache state, hook errors, feature counters)\n"
        .. "use the slash command: /dilvl debug",
        theme.FONT_HELPER, "secondary", nil)
    hint:SetPoint("BOTTOMLEFT", resetBtn, "TOPLEFT", 0, 16)
    hint:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -20, 50)
    hint:SetJustifyH("LEFT")
end

if ns.ui and ns.ui.main and ns.ui.main.RegisterPage then
    ns.ui.main.RegisterPage("diagnostics", "Diagnostics", page.Init)
end
