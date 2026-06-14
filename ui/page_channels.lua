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
-- Details! window picker. 0 = all windows (default), 1-5 cover the
-- realistic multi-window setups; slash `/dilvl details window <n>`
-- reaches 6-10 for the rare power user.
---------------------------------------------------------------
local DETAILS_WINDOW_OPTIONS = {
    {value=0, label=L["All windows"]},
    {value=1, label=L["Window 1"]},
    {value=2, label=L["Window 2"]},
    {value=3, label=L["Window 3"]},
    {value=4, label=L["Window 4"]},
    {value=5, label=L["Window 5"]},
}

---------------------------------------------------------------
-- Per-channel panel builder. Returns the panel frame so caller can anchor
-- the next channel below it.
---------------------------------------------------------------
local function BuildDetailsPanel(parent)
    -- 140h fits checkbox + hint + (window dropdown | size slider) row.
    local p = W.CreatePanel(parent, 1, 140, L["Details! bars"])
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
    hint:SetPoint("TOPLEFT", cb, "BOTTOMLEFT", 24, -4)
    hint:SetJustifyH("LEFT")

    -- Restrict iLvl to a single Details! window (404Missingno request).
    local windowDD = W.CreateDropdown(p, L["Details Window"],
        DETAILS_WINDOW_OPTIONS,
        function() return getKey("detailsWindowId", 0) end,
        function(v) setKey("detailsWindowId", v) end,
        L["TOOLTIP_DETAILS_WINDOW"])
    windowDD:SetPoint("TOPLEFT", cb, "BOTTOMLEFT", 0, -26)

    -- Fixed iLvl text size for the Columns layout (404Missingno request).
    -- Slider sets a concrete 6-30; "/dilvl details size 0" restores auto
    -- (match Details' own font). Getter shows 12 while in auto so the thumb
    -- isn't pinned to the min.
    local sizeSlider = W.CreateSlider(p, L["Details Font Size"],
        6, 30, 1,
        function() local v = getKey("detailsFontSize", 0); return (v and v > 0) and v or 12 end,
        function(v) setKey("detailsFontSize", v) end,
        L["TOOLTIP_DETAILS_SIZE"])
    sizeSlider:SetPoint("LEFT", windowDD, "RIGHT", 30, -2)
    return p
end

local function BuildElvUIPanel(parent, prev)
    -- ElvUI exposes TWO independent tags ([dilvl] always-brackets and
    -- [dilvl:plain] always-plain). User picks behavior by choosing which
    -- tag to drop into their ElvUI Custom Text — there's no setting to
    -- toggle.
    -- 105h fits checkbox + 2-line wrapped hint. Hint width anchored to
    -- panel.RIGHT - margin so it wraps based on panel width (resizable).
    local p = W.CreatePanel(parent, 1, 105, L["ElvUI tags"])
    p:SetPoint("TOPLEFT",  prev, "BOTTOMLEFT",  0, -theme.WIDGET_GAP)
    p:SetPoint("TOPRIGHT", prev, "BOTTOMRIGHT", 0, -theme.WIDGET_GAP)

    local cb = W.CreateCheckbox(p, L["ElvUI tags"],
        function() return getKey("elvuiTag", false) end,
        function(v) setKey("elvuiTag", v) end)
    cb:SetPoint("TOPLEFT", p, "TOPLEFT", 12, -28)

    local hint = W.CreateLabel(p,
        "→ " .. L["ELVUI_TAGS_HINT"],
        theme.FONT_HELPER, "secondary")
    hint:SetPoint("TOPLEFT",  cb, "BOTTOMLEFT", 24, -4)
    hint:SetPoint("TOPRIGHT", p,  "TOPRIGHT", -16, -52)
    hint:SetJustifyH("LEFT")
    return p
end

local function BuildGrid2Panel(parent, prev)
    local p = W.CreatePanel(parent, 1, 80, L["Grid2 status"])
    p:SetPoint("TOPLEFT",  prev, "BOTTOMLEFT",  0, -theme.WIDGET_GAP)
    p:SetPoint("TOPRIGHT", prev, "BOTTOMRIGHT", 0, -theme.WIDGET_GAP)

    local cb = W.CreateCheckbox(p, L["Grid2 status"],
        function() return getKey("grid2Status", false) end,
        function(v) setKey("grid2Status", v) end)
    cb:SetPoint("TOPLEFT", p, "TOPLEFT", 12, -28)

    local hint = W.CreateLabel(p,
        "→ " .. L["GRID2_HINT"],
        theme.FONT_HELPER, "secondary")
    hint:SetPoint("TOPLEFT", cb, "BOTTOMLEFT", 24, -4)
    hint:SetJustifyH("LEFT")
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

    -- ScrollFrame as safety net — at default window size the 5 channel
    -- panels exceed the tab content area. Resizing the window via the
    -- bottom-right grip eliminates the scroll.
    local sf, content = W.CreateScrollFrame(parent,
        parent:GetWidth() > 0 and (parent:GetWidth() - 20) or 660,
        parent:GetHeight() > 0 and (parent:GetHeight() - 40) or 350)
    sf:SetPoint("TOPLEFT",     info,   "BOTTOMLEFT",  0, -theme.WIDGET_GAP)
    sf:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)

    -- Anchor scroll content full width minus scrollbar gutter
    content:SetPoint("TOPLEFT", sf, "TOPLEFT", 0, 0)
    content:SetWidth(sf:GetWidth() - 20)

    local p1 = BuildDetailsPanel(content)
    local p2 = BuildElvUIPanel(content, p1)
    local p3 = BuildGrid2Panel(content, p2)
    local p4 = BuildDandersPanel(content, p3)
    local p5 = BuildBlizzDMPanel(content, p4)

    -- Total stacked panel height: 140(Details!) + 105(ElvUI) + 80(Grid2) +
    -- 110(Danders) + 80(BlizzDM) = 515 + 4 gaps × WIDGET_GAP + headroom
    content:SetHeight(140 + 105 + 80 + 110 + 80 + theme.WIDGET_GAP * 4 + 10)
end

if ns.ui and ns.ui.main and ns.ui.main.RegisterPage then
    ns.ui.main.RegisterPage("channels", "Output Channels", page.Init)
end
