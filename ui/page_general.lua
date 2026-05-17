-- ui/page_general.lua — General settings page.
--
-- LAYOUT (top to bottom):
--   ┌─ Info bar ──────────────────────────────────────────────────────┐
--   │ ⓘ Auto-detects what you have installed. Toggle channels on next tab. │
--   └────────────────────────────────────────────────────────────────┘
--   ┌─ Master Toggles (left) ───────┐  ┌─ Display (right) ────────────┐
--   │ ☑ Enable Details! iLvl        │  │ Layout: ◉ Inline ◯ Columns   │
--   │ ☑ Color by gear tier          │  │ Position: ◉ Right ◯ Left     │
--   │ ☑ Show 2P/4P set bonus        │  │                              │
--   └───────────────────────────────┘  └──────────────────────────────┘
--   ┌─ Auto-detected ───────────────────────────────────────────────────┐
--   │ Surfaces detected: ✓ Details! ✗ ElvUI ✓ Grid2 ✗ Danders ✓ BlizzDM │
--   └───────────────────────────────────────────────────────────────────┘

local addonName, ns = ...
ns.ui = ns.ui or {}
ns.ui.pages = ns.ui.pages or {}

local page = {}
ns.ui.pages.general = page

local theme = ns.ui.theme
local W     = ns.ui.widgets
local L     = ns.L

---------------------------------------------------------------
-- DB accessors — defensive, never assume db is loaded.
-- core.lua sets ns.db at ADDON_LOADED; if it's missing we silently no-op.
---------------------------------------------------------------
local function db()
    return ns.db or _G.Details_iLvlDisplayDB
end

local function getKey(k, default)
    local d = db()
    if not d then return default end
    if d[k] == nil then return default end
    return d[k]
end

local function setKey(k, v)
    local d = db()
    if not d then return end
    d[k] = v
    -- Apply the real in-world refresh (re-render Details! bars, switch
    -- layout mode, re-notify ElvUI/Grid2 callbacks, etc.) via the single
    -- source of truth in core.lua. Without this, the real Details! bars
    -- would render BOTH old + new state simultaneously when layout flips.
    if ns.ApplySettingChange then
        pcall(ns.ApplySettingChange, k)
    end
    -- Update the embedded live-preview pane (throttled 10Hz).
    if ns.ui and ns.ui.preview and ns.ui.preview.MarkDirty then
        ns.ui.preview.MarkDirty()
    end
end

---------------------------------------------------------------
-- Auto-detect helpers — what's installed right now?
---------------------------------------------------------------
local function detected()
    return {
        ["Details!"]    = (Details ~= nil),
        ["ElvUI"]       = (ElvUI ~= nil),
        ["Grid2"]       = (Grid2 ~= nil),
        ["Danders"]     = (DandersFrames_IsReady ~= nil),
        ["Blizzard DM"] = (C_AddOns and C_AddOns.IsAddOnLoaded
            and C_AddOns.IsAddOnLoaded("Blizzard_DamageMeter")) and true or false,
    }
end

---------------------------------------------------------------
-- Init — called by main_frame.lua via SafePageInit when this tab activates.
-- Builds all widgets, anchors them, wires db getters/setters.
---------------------------------------------------------------
function page.Init(parent)
    -- ── Info bar (top of page) ──
    local info = W.CreateInfoBar(parent, L["GENERAL_INFO"], 32)
    info:SetPoint("TOPLEFT",  parent, "TOPLEFT",  0, 0)
    info:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)

    -- ── Master Toggles panel (left column) ──
    local masterPanel = W.CreatePanel(parent, 340, 160, L["Master Toggles"])
    masterPanel:SetPoint("TOPLEFT", info, "BOTTOMLEFT", 0, -theme.SECTION_GAP)

    local cbEnable = W.CreateCheckbox(masterPanel,
        L["Enable Details! iLvl Display"],
        function() return getKey("enabled", true) end,
        function(v) setKey("enabled", v) end,
        L["TOOLTIP_MASTER_ENABLE"])
    cbEnable:SetPoint("TOPLEFT", masterPanel, "TOPLEFT", 12, -32)

    local cbColor = W.CreateCheckbox(masterPanel,
        L["Color by gear tier"],
        function() return getKey("colorIlvl", true) end,
        function(v) setKey("colorIlvl", v) end,
        L["TOOLTIP_COLOR"])
    cbColor:SetPoint("TOPLEFT", cbEnable, "BOTTOMLEFT", 0, -theme.WIDGET_GAP)

    local cbSetBonus = W.CreateCheckbox(masterPanel,
        L["Show 2P/4P set bonus"],
        function() return getKey("showSetBonus", true) end,
        function(v) setKey("showSetBonus", v) end,
        L["TOOLTIP_SETBONUS"])
    cbSetBonus:SetPoint("TOPLEFT", cbColor, "BOTTOMLEFT", 0, -theme.WIDGET_GAP)

    -- ── Display panel (right column) ──
    local displayPanel = W.CreatePanel(parent, 340, 160, L["Display"])
    displayPanel:SetPoint("TOPLEFT", masterPanel, "TOPRIGHT", theme.WIDGET_GAP * 2, 0)

    local layoutRadio = W.CreateRadioGroup(displayPanel,
        L["Layout (Details!)"],
        { {value="inline", label=L["Inline"]}, {value="columns", label=L["Columns"]} },
        function() return getKey("layout", "inline") end,
        function(v) setKey("layout", v) end,
        "horizontal",
        L["TOOLTIP_LAYOUT"])
    layoutRadio:SetPoint("TOPLEFT", displayPanel, "TOPLEFT", 12, -32)
    layoutRadio:SetWidth(300)

    local posRadio = W.CreateRadioGroup(displayPanel,
        L["Position"],
        { {value="right", label=L["Right of name"]}, {value="left", label=L["Left of name"]} },
        function() return getKey("ilvlPosition", "right") end,
        function(v) setKey("ilvlPosition", v) end,
        "vertical",                     -- DE strings too wide for horizontal
        L["TOOLTIP_POSITION"])
    posRadio:SetPoint("TOPLEFT", layoutRadio, "BOTTOMLEFT", 0, -theme.SECTION_GAP)
    posRadio:SetWidth(300)
    posRadio:SetHeight(60)

    -- ── Auto-detect panel (bottom row, full width) ──
    local detectPanel = W.CreatePanel(parent,
        parent:GetWidth() > 0 and parent:GetWidth() or 680,
        70, L["Auto-detected"])
    detectPanel:SetPoint("TOPLEFT",  masterPanel, "BOTTOMLEFT", 0, -theme.SECTION_GAP)
    detectPanel:SetPoint("TOPRIGHT", displayPanel, "BOTTOMRIGHT", 0, -theme.SECTION_GAP)
    detectPanel:SetHeight(70)

    local descFS = W.CreateLabel(detectPanel, L["AUTODETECT_DESCRIPTION"],
        theme.FONT_HELPER, "secondary")
    descFS:SetPoint("TOPLEFT", detectPanel, "TOPLEFT", 12, -28)

    local statusFS = W.CreateLabel(detectPanel, "", theme.FONT_LABEL, "primary")
    statusFS:SetPoint("TOPLEFT", descFS, "BOTTOMLEFT", 0, -4)

    -- Build status string with green ✓ / red ✗ per surface.
    local d = detected()
    local order = {"Details!", "ElvUI", "Grid2", "Danders", "Blizzard DM"}
    local parts = {}
    for _, name in ipairs(order) do
        local ok = d[name]
        local mark = ok and "|cFF73D973✓|r" or "|cFFEE6666✗|r"
        parts[#parts + 1] = mark .. " " .. name
    end
    statusFS:SetText(table.concat(parts, "   "))
end

---------------------------------------------------------------
-- Self-register with main_frame.lua. Done at file-load time; main_frame.lua
-- iterates main.pages when building the tab strip.
---------------------------------------------------------------
if ns.ui and ns.ui.main and ns.ui.main.RegisterPage then
    ns.ui.main.RegisterPage("general", "General", page.Init)
else
    -- main_frame.lua loaded later (shouldn't happen if TOC order is right,
    -- but be defensive). Queue for later registration.
    ns._pendingPages = ns._pendingPages or {}
    table.insert(ns._pendingPages, {"general", "General", page.Init})
end
