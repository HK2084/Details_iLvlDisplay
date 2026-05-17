-- ui/page_diagnostics.lua — Diagnostics page.
--
-- Comprehensive debug dump in a scrollable, selectable EditBox so users
-- can copy-paste the full state into CurseForge / GitHub bug reports.
-- Shows:
--   - Addon version + build
--   - DB state (settings + feature toggles)
--   - Auto-detect status (which host addons are loaded)
--   - UI-layer error counts (from safe_callback.lua)
--   - Feature counters (Details!-hook errors, BlizzDM resolve fails, Danders
--     errors, ElvUI/Grid2 callback errors, UnitNameRejected counter)
--   - Last-error strings per surface
--   - Window state (position, last tab)

local addonName, ns = ...
ns.ui = ns.ui or {}
ns.ui.pages = ns.ui.pages or {}

local page = {}
ns.ui.pages.diagnostics = page

local theme = ns.ui.theme
local W     = ns.ui.widgets
local safe  = ns.ui.safe
local L     = ns.L

---------------------------------------------------------------
-- Collect all debug data into an array of lines. Pure function — no side
-- effects. Both the slash handler (/dilvl debug) and this page call it.
---------------------------------------------------------------
local function collectDebugLines()
    local lines = {}
    local function add(s) lines[#lines + 1] = s or "" end
    local function addKV(k, v) lines[#lines + 1] = "  " .. k .. ": " .. tostring(v) end

    add("=== Details! iLvl Display v" .. (ns.version or "?") .. " ===")
    add("Locale: " .. (GetLocale() or "?"))
    add("Build: " .. (select(1, GetBuildInfo()) or "?") .. " (" .. (select(2, GetBuildInfo()) or "?") .. ")")
    add("")

    -- Settings DB
    add("--- Settings (db) ---")
    local db = ns.db or _G.Details_iLvlDisplayDB
    if db then
        for _, k in ipairs({"enabled", "colorIlvl", "showSetBonus", "showInDetails",
            "elvuiTag", "grid2Status", "dandersText", "dandersPos", "dandersFontSize",
            "blizzDM", "layout", "ilvlPosition"}) do
            if db[k] ~= nil then addKV(k, db[k]) end
        end
    else
        add("  (db not loaded)")
    end
    add("")

    -- Auto-detect
    add("--- Auto-detected hosts ---")
    addKV("Details!",      Details ~= nil)
    addKV("ElvUI",         ElvUI ~= nil)
    addKV("Grid2",         Grid2 ~= nil)
    addKV("DandersFrames", DandersFrames_IsReady ~= nil)
    addKV("Blizzard DM",   C_AddOns and C_AddOns.IsAddOnLoaded
        and C_AddOns.IsAddOnLoaded("Blizzard_DamageMeter") and true or false)
    addKV("LibOpenRaid",   LibStub and LibStub:GetLibrary("LibOpenRaid-1.0", true) ~= nil)
    add("")

    -- Secret API status (relevant since 12.0+)
    add("--- Secret-API status ---")
    addKV("C_Secrets.CanCompareUnitTokens",
        C_Secrets and C_Secrets.CanCompareUnitTokens ~= nil)
    addKV("issecretvalue",  issecretvalue ~= nil)
    add("")

    -- BlizzDM integration state. The global is a FUNCTION that returns the
    -- state table (not the table directly), so we call it first then iterate.
    if type(Details_iLvlDisplay_BlizzDMState) == "function" then
        local ok, state = pcall(Details_iLvlDisplay_BlizzDMState)
        if ok and type(state) == "table" then
            add("--- Blizzard DM Integration ---")
            for k, v in pairs(state) do
                if type(v) ~= "table" and type(v) ~= "function" then
                    addKV(k, v)
                end
            end
            add("")
        end
    end

    -- Danders integration state
    if Details_iLvlDisplay_DandersState then
        add("--- Danders Integration ---")
        local d = Details_iLvlDisplay_DandersState
        addKV("disabled",        d.disabled)
        addKV("errors",          tostring(d.dandersErrors) .. "/5")
        addKV("lastError",       d.lastError or "(none)")
        addKV("refreshCount",    d.refreshCount)
        addKV("lastFrameCount",  d.lastFrameCount)
        add("")
    end

    -- UI layer errors (safe_callback)
    local uiLines = safe.GetDiagnostics()
    for _, ln in ipairs(uiLines) do add(ln) end
    add("")

    -- Window state
    local s = (db or {}).uiState
    if s then
        add("--- UI Window State ---")
        addKV("position", string.format("%s -> UIParent %s @ (%s, %s)",
            tostring(s.point), tostring(s.relPoint), tostring(s.x), tostring(s.y)))
        addKV("lastTab", s.lastTab or "(none)")
        add("")
    end

    add("--- End of report ---")
    return lines
end

-- Export so the slash handler can reuse it as a single source of truth.
ns.GetDebugLines = collectDebugLines

---------------------------------------------------------------
-- Page Init
---------------------------------------------------------------
function page.Init(parent)
    local info = W.CreateInfoBar(parent, L["DIAGNOSTICS_INFO"], 32)
    info:SetPoint("TOPLEFT",  parent, "TOPLEFT",  0, 0)
    info:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)

    -- Action bar (Refresh + Reset UI errors)
    local actionBar = CreateFrame("Frame", nil, parent)
    actionBar:SetHeight(28)
    actionBar:SetPoint("TOPLEFT",  info, "BOTTOMLEFT",  0, -theme.WIDGET_GAP)
    actionBar:SetPoint("TOPRIGHT", info, "BOTTOMRIGHT", 0, -theme.WIDGET_GAP)

    local refreshBtn -- forward-declared so onclicks can reference
    local resetBtn

    -- The scrollable + selectable debug-dump area
    local panel = W.CreatePanel(parent, 1, 1, nil)
    panel:SetPoint("TOPLEFT",  actionBar, "BOTTOMLEFT",  0, -theme.WIDGET_GAP)
    panel:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)

    local scrollFrame, scrollContent = W.CreateScrollFrame(panel,
        panel:GetWidth() - 20, panel:GetHeight() - 16)
    scrollFrame:SetPoint("TOPLEFT",     panel, "TOPLEFT",     8, -8)
    scrollFrame:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -8, 8)

    -- Read-only EditBox (selectable for copy-paste). EditBox is the standard
    -- WoW pattern for "selectable text region" — there's no native text widget
    -- with selection support.
    local edit = CreateFrame("EditBox", nil, scrollContent)
    edit:SetMultiLine(true)
    edit:SetMaxLetters(0)
    edit:SetFontObject("ChatFontNormal")
    edit:SetAutoFocus(false)
    edit:SetWidth(scrollContent:GetWidth() - 10)
    edit:SetPoint("TOPLEFT", scrollContent, "TOPLEFT", 4, 0)
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    -- Suppress text-input (read-only effect): force focus loss on any keystroke
    edit:SetScript("OnTextChanged", function(self, userInput)
        if userInput then self:ClearFocus() end
    end)

    local function refresh()
        local lines = collectDebugLines()
        local text = table.concat(lines, "\n")
        edit:SetText(text)
        -- Resize content to fit text height. EditBox:GetStringHeight is
        -- not reliably present on multi-line EditBox across 12.0+ builds,
        -- so calculate from line count + font height instead.
        local _, fontHeight = edit:GetFont()
        local lineH = (fontHeight or 12) * 1.25
        local lineCount = #lines + 1  -- +1 for any trailing newline
        local totalH = lineCount * lineH + 16
        edit:SetHeight(totalH)
        scrollContent:SetHeight(totalH)
    end

    refreshBtn = W.CreateButton(actionBar, L["Refresh"], 110, 24, refresh)
    refreshBtn:SetPoint("LEFT", actionBar, "LEFT", 0, 0)

    resetBtn = W.CreateButton(actionBar, L["Reset UI Error Counters"], 220, 24,
        function()
            safe.ResetAll()
            refresh()
        end)
    resetBtn:SetPoint("LEFT", refreshBtn, "RIGHT", theme.WIDGET_GAP, 0)

    -- Reset-to-Defaults button — destructive, gated by StaticPopup confirmation.
    -- Registers the popup once at module load (idempotent) so the button click
    -- can just StaticPopup_Show.
    StaticPopupDialogs["DILVL_RESET_DEFAULTS"] = StaticPopupDialogs["DILVL_RESET_DEFAULTS"] or {
        text         = L["RESET_DEFAULTS_CONFIRM"],
        button1      = ACCEPT,
        button2      = CANCEL,
        OnAccept     = function()
            if ns.ResetToDefaults then ns.ResetToDefaults() end
            -- After reset, re-render this page so the diagnostics dump reflects
            -- the fresh defaults
            if ns.ui.main then ns.ui.main.SwitchTab("diagnostics") end
        end,
        timeout      = 0,
        whichInstance = 1,
        hideOnEscape = true,
    }

    local resetDefaultsBtn = W.CreateButton(actionBar, L["Reset to Defaults"], 200, 24,
        function() StaticPopup_Show("DILVL_RESET_DEFAULTS") end)
    resetDefaultsBtn:SetPoint("LEFT", resetBtn, "RIGHT", theme.WIDGET_GAP, 0)

    -- Initial population
    refresh()
end

if ns.ui and ns.ui.main and ns.ui.main.RegisterPage then
    ns.ui.main.RegisterPage("diagnostics", "Diagnostics", page.Init)
end
