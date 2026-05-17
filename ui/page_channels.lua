-- ui/page_channels.lua — Output Channels page (REAL).
--
-- 5 channels stacked vertically inside a ScrollFrame (so the page survives
-- if we ever add more channels). Each channel is a bordered panel with:
--   - Master toggle checkbox
--   - Channel-specific sub-settings (sliders, dropdowns, radios)
--
-- Per-feature kill-switch isolation: a bug in one channel's widgets can't
-- crash the page (every callback wrapped via ns.ui.safe.WrapScript), and
-- the page itself is wrapped via SafePageInit by the main_frame.

local addonName, ns = ...
ns.ui = ns.ui or {}
ns.ui.pages = ns.ui.pages or {}

local page = {}
ns.ui.pages.channels = page

local theme = ns.ui.theme
local W     = ns.ui.widgets
local L     = ns.L

---------------------------------------------------------------
-- DB accessors — defensive, never assume db is loaded.
-- setKey also pings the live-preview to mark dirty.
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
    -- Apply in-world refresh via core.lua single source of truth
    if ns.ApplySettingChange then
        pcall(ns.ApplySettingChange, k)
    end
    if ns.ui and ns.ui.preview and ns.ui.preview.MarkDirty then
        ns.ui.preview.MarkDirty()
    end
end

---------------------------------------------------------------
-- All 13 Danders anchor positions. Grouped visually by inside vs off-frame.
-- Dropdown entries use isTitle separators between the groups.
---------------------------------------------------------------
local DANDERS_POS_OPTIONS = {
    {value="top",         label="top"},
    {value="topright",    label="topright"},
    {value="topleft",     label="topleft"},
    {value="bottom",      label="bottom"},
    {value="bottomright", label="bottomright"},
    {value="bottomleft",  label="bottomleft"},
    {value="center",      label="center"},
    {value="above",       label="above"},
    {value="aboveleft",   label="aboveleft"},
    {value="aboveright",  label="aboveright"},
    {value="below",       label="below"},
    {value="belowleft",   label="belowleft"},
    {value="belowright",  label="belowright"},
}

---------------------------------------------------------------
-- BlizzDM tristate: nil = auto, true = forced on, false = forced off.
-- Dropdown converts between string keys ("auto"/"on"/"off") and the
-- nil/true/false db value.
---------------------------------------------------------------
local BLIZZDM_OPTIONS = {
    {value="auto", label=L["Auto"]},
    {value="on",   label=L["Forced On"]},
    {value="off",  label=L["Forced Off"]},
}

local function blizzDMGet()
    local v = getKey("blizzDM", nil)
    if v == nil then return "auto" end
    if v then return "on" end
    return "off"
end

local function blizzDMSet(opt)
    if     opt == "auto" then setKey("blizzDM", nil)
    elseif opt == "on"   then setKey("blizzDM", true)
    elseif opt == "off"  then setKey("blizzDM", false)
    end
end

---------------------------------------------------------------
-- Per-channel panel builder. Returns the panel frame so caller can anchor
-- the next channel below it.
---------------------------------------------------------------
local function BuildDetailsPanel(parent)
    local p = W.CreatePanel(parent, 1, 60, L["Details! bars"])
    p:SetPoint("TOPLEFT",  parent, "TOPLEFT",  0, 0)
    p:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -20, 0)

    local cb = W.CreateCheckbox(p, L["Enable Details! iLvl Display"],
        function() return getKey("showInDetails", true) end,
        function(v) setKey("showInDetails", v) end,
        L["TOOLTIP_MASTER_ENABLE"])
    cb:SetPoint("TOPLEFT", p, "TOPLEFT", 12, -28)

    local hint = W.CreateLabel(p,
        "→ " .. L["Layout (Details!)"] .. " / " .. L["Position"]
            .. ": " .. L["General"],
        theme.FONT_HELPER, "secondary")
    hint:SetPoint("LEFT", cb, "RIGHT", 80, 0)
    return p
end

local function BuildElvUIPanel(parent, prev)
    local p = W.CreatePanel(parent, 1, 90, L["ElvUI tags"])
    p:SetPoint("TOPLEFT",  prev, "BOTTOMLEFT",  0, -theme.WIDGET_GAP)
    p:SetPoint("TOPRIGHT", prev, "BOTTOMRIGHT", 0, -theme.WIDGET_GAP)

    local cb = W.CreateCheckbox(p, L["ElvUI tags"],
        function() return getKey("elvuiTag", false) end,
        function(v) setKey("elvuiTag", v) end)
    cb:SetPoint("TOPLEFT", p, "TOPLEFT", 12, -28)

    local fmt = W.CreateRadioGroup(p, L["ElvUI Tag Format"],
        { {value=false, label=L["Brackets: [dilvl]"]},
          {value=true,  label=L["Plain: [dilvl:plain]"]} },
        function() return getKey("elvuiTagPlain", false) end,
        function(v) setKey("elvuiTagPlain", v) end,
        "horizontal")
    fmt:SetPoint("TOPLEFT", cb, "BOTTOMLEFT", 0, -8)
    fmt:SetWidth(400)
    return p
end

local function BuildGrid2Panel(parent, prev)
    local p = W.CreatePanel(parent, 1, 60, L["Grid2 status"])
    p:SetPoint("TOPLEFT",  prev, "BOTTOMLEFT",  0, -theme.WIDGET_GAP)
    p:SetPoint("TOPRIGHT", prev, "BOTTOMRIGHT", 0, -theme.WIDGET_GAP)

    local cb = W.CreateCheckbox(p, L["Grid2 status"],
        function() return getKey("grid2Status", false) end,
        function(v) setKey("grid2Status", v) end)
    cb:SetPoint("TOPLEFT", p, "TOPLEFT", 12, -28)

    local hint = W.CreateLabel(p,
        "→ " .. "Configure indicator placement in Grid2 GUI",
        theme.FONT_HELPER, "secondary")
    hint:SetPoint("LEFT", cb, "RIGHT", 80, 0)
    return p
end

local function BuildDandersPanel(parent, prev)
    local p = W.CreatePanel(parent, 1, 110, L["Danders Frames overlay"])
    p:SetPoint("TOPLEFT",  prev, "BOTTOMLEFT",  0, -theme.WIDGET_GAP)
    p:SetPoint("TOPRIGHT", prev, "BOTTOMRIGHT", 0, -theme.WIDGET_GAP)

    local cb = W.CreateCheckbox(p, L["Danders Frames overlay"],
        function() return getKey("dandersText", false) end,
        function(v) setKey("dandersText", v) end)
    cb:SetPoint("TOPLEFT", p, "TOPLEFT", 12, -28)

    local posDD = W.CreateDropdown(p, L["Danders Anchor Position"],
        DANDERS_POS_OPTIONS,
        function() return getKey("dandersPos", "topright") end,
        function(v) setKey("dandersPos", v) end)
    posDD:SetPoint("TOPLEFT", cb, "BOTTOMLEFT", 0, -4)

    local sizeSlider = W.CreateSlider(p, L["Danders Font Size"],
        6, 30, 1,
        function() return getKey("dandersFontSize", 10) end,
        function(v) setKey("dandersFontSize", v) end,
        L["TOOLTIP_DANDERS_SIZE"])
    sizeSlider:SetPoint("LEFT", posDD, "RIGHT", 30, -2)
    return p
end

local function BuildBlizzDMPanel(parent, prev)
    local p = W.CreatePanel(parent, 1, 80, L["Blizzard DM"])
    p:SetPoint("TOPLEFT",  prev, "BOTTOMLEFT",  0, -theme.WIDGET_GAP)
    p:SetPoint("TOPRIGHT", prev, "BOTTOMRIGHT", 0, -theme.WIDGET_GAP)

    local modeDD = W.CreateDropdown(p, L["Blizzard DM Mode"],
        BLIZZDM_OPTIONS,
        blizzDMGet, blizzDMSet,
        L["TOOLTIP_BLIZZDM_MODE"])
    modeDD:SetPoint("TOPLEFT", p, "TOPLEFT", 12, -28)
    return p
end

---------------------------------------------------------------
-- Page Init
---------------------------------------------------------------
function page.Init(parent)
    local info = W.CreateInfoBar(parent, L["CHANNELS_INFO"], 32)
    info:SetPoint("TOPLEFT",  parent, "TOPLEFT",  0, 0)
    info:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)

    -- ScrollFrame so the page is future-proof if we add more channels.
    -- With current 5 panels (~400 px content), scrollbar usually inactive.
    local sf, content = W.CreateScrollFrame(parent,
        parent:GetWidth() or 680,
        (parent:GetHeight() or 400) - 40)
    sf:SetPoint("TOPLEFT",  info, "BOTTOMLEFT",  0, -theme.WIDGET_GAP)
    sf:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)

    content:SetWidth(sf:GetWidth() - 20)  -- leave room for scrollbar

    local p1 = BuildDetailsPanel(content)
    local p2 = BuildElvUIPanel(content, p1)
    local p3 = BuildGrid2Panel(content, p2)
    local p4 = BuildDandersPanel(content, p3)
    local p5 = BuildBlizzDMPanel(content, p4)

    -- Set content height to fit all panels (gap between each + headroom)
    content:SetHeight(60 + 90 + 60 + 110 + 80 + theme.WIDGET_GAP * 4 + 10)
end

if ns.ui and ns.ui.main and ns.ui.main.RegisterPage then
    ns.ui.main.RegisterPage("channels", "Output Channels", page.Init)
end
