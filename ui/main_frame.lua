-- ui/main_frame.lua — Settings window skeleton.
--
-- ARCHITECTURE (after Hasan's restructure 2026-05-16):
--   - One singleton frame, lazy-created on first /dilvl ui call.
--   - 3 horizontal top-tabs (General / Output Channels / Diagnostics).
--   - Tab content fills upper area; PERSISTENT PREVIEW PANE sits below tabs.
--     User sees preview update live as they change settings — no tab-switching.
--   - Tab switching = SafePageInit -> page Init(contentFrame), with
--     fault-isolation via ns.ui.safe.
--   - Position + last-active-tab persisted in db.uiState (SavedVar subtable).
--   - UISpecialFrames registration -> Escape key closes the window.
--   - This file deliberately stays minimal (no business logic) because it's
--     the one file whose failure WOULD kill the entire UI.

local addonName, ns = ...
ns.ui = ns.ui or {}
local main = {}
ns.ui.main = main

local theme = ns.ui.theme
local safe  = ns.ui.safe
local W     = ns.ui.widgets
local L     = ns.L

---------------------------------------------------------------
-- Tab registry. Pages add themselves via main.RegisterPage(id, labelKey, initFn)
-- so main_frame.lua doesn't import every page file. Decoupled.
---------------------------------------------------------------
main.pages = {}      -- ordered list
main.pagesByID = {}  -- pageId -> entry

function main.RegisterPage(id, labelKey, initFn)
    if main.pagesByID[id] then return end
    local entry = {id = id, labelKey = labelKey, initFn = initFn}
    table.insert(main.pages, entry)
    main.pagesByID[id] = entry
end

---------------------------------------------------------------
-- Singleton + state
---------------------------------------------------------------
main.frame = nil
main.activeTabId = nil

local function GetDbState()
    local db = ns.db or _G.Details_iLvlDisplayDB
    if not db then return nil end
    db.uiState = db.uiState or { point = nil, relPoint = nil, x = nil, y = nil, lastTab = "general" }
    return db.uiState
end

---------------------------------------------------------------
-- Children-cleanup helper. Hide AND SetParent(nil) AND ClearAllPoints so
-- orphaned frames don't leak event scripts / OnUpdate ticks.
---------------------------------------------------------------
local function ClearChildren(parent)
    if not parent then return end
    for _, child in ipairs({parent:GetChildren()}) do
        child:Hide()
        child:ClearAllPoints()
        child:SetParent(nil)
    end
end

---------------------------------------------------------------
-- Tab strip — one button per registered page.
---------------------------------------------------------------
local function CreateTabButton(parent, tabsArr, entry, index)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(160, theme.TAB_BAR_H - 4)
    if index == 1 then
        btn:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", theme.PADDING, 0)
    else
        btn:SetPoint("LEFT", tabsArr[index - 1], "RIGHT", 4, 0)
    end
    theme.ApplyBackdrop(btn, "tab_inactive")

    local fs = btn:CreateFontString(nil, "OVERLAY", theme.FONT_LABEL)
    fs:SetPoint("CENTER", btn, "CENTER", 0, 0)
    fs:SetText(L[entry.labelKey] or entry.labelKey)
    theme.SetTextColor(fs, "primary")
    btn.label = fs

    btn:SetScript("OnClick", safe.WrapScript("Tab:" .. entry.id, function()
        main.SwitchTab(entry.id)
    end))

    btn:SetScript("OnEnter", safe.WrapScript("Tab:OnEnter:" .. entry.id, function(self)
        if main.activeTabId ~= entry.id then
            theme.ApplyBackdrop(self, "tab_active")
        end
    end))
    btn:SetScript("OnLeave", safe.WrapScript("Tab:OnLeave:" .. entry.id, function(self)
        if main.activeTabId ~= entry.id then
            theme.ApplyBackdrop(self, "tab_inactive")
        end
    end))

    btn.entry = entry
    return btn
end

---------------------------------------------------------------
-- Tab switching — set currentPage UPFRONT so any error during cleanup or
-- init gets attributed correctly. Then clean previous tab content, call
-- page init via SafePageInit (or show placeholder if broken).
---------------------------------------------------------------
function main.SwitchTab(pageId)
    if not main.frame or not main.frame.content then return end
    local entry = main.pagesByID[pageId]
    if not entry then return end

    -- Set currentPage BEFORE cleanup so cleanup errors are attributed here.
    safe.currentPage = pageId

    -- Tab visuals
    for _, b in ipairs(main.frame.tabs) do
        theme.ApplyBackdrop(b, b.entry.id == pageId and "tab_active" or "tab_inactive")
        theme.SetTextColor(b.label, b.entry.id == pageId and "accent" or "primary")
    end
    main.activeTabId = pageId

    -- Cleanup previous content children (Hide + Unparent + ClearAllPoints)
    ClearChildren(main.frame.content)
    -- Dismiss any stuck GameTooltip from previous tab
    if GameTooltip and GameTooltip:IsShown() then GameTooltip:Hide() end

    -- Render page (or placeholder if broken)
    if safe.pageBroken[pageId] then
        safe.BuildPlaceholder(main.frame.content, pageId)
    else
        local ok = safe.SafePageInit(pageId, function()
            entry.initFn(main.frame.content)
        end)
        if not ok then
            safe.BuildPlaceholder(main.frame.content, pageId)
        end
    end

    -- Persist
    local state = GetDbState()
    if state then state.lastTab = pageId end
end

---------------------------------------------------------------
-- Position helpers — save point+relPoint+x+y so symmetric restore avoids
-- the "window jumps on every reopen" drift bug.
---------------------------------------------------------------
local function SaveWindowPos(f)
    local point, _, relPoint, x, y = f:GetPoint(1)
    if not point then return end
    local state = GetDbState()
    if not state then return end
    state.point    = point
    state.relPoint = relPoint
    state.x        = x
    state.y        = y
end

local function RestoreWindowPos(f)
    local state = GetDbState()
    f:ClearAllPoints()
    if state and state.point and state.relPoint and state.x and state.y then
        f:SetPoint(state.point, UIParent, state.relPoint, state.x, state.y)
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
end

---------------------------------------------------------------
-- Build the window. Lazy — called on first Open.
---------------------------------------------------------------
local function BuildFrame()
    if main.frame then return main.frame end

    local f = CreateFrame("Frame", "Details_iLvlDisplay_SettingsFrame",
        UIParent, "BackdropTemplate")
    f:SetSize(theme.WINDOW_W, theme.WINDOW_H)
    f:SetFrameStrata("HIGH")
    f:SetFrameLevel(100)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    theme.ApplyBackdrop(f, "window")
    f:Hide()

    RestoreWindowPos(f)
    tinsert(UISpecialFrames, "Details_iLvlDisplay_SettingsFrame")

    -- ── Title bar (drag, title, close button) ──
    local titleBar = CreateFrame("Frame", nil, f, "BackdropTemplate")
    titleBar:SetHeight(theme.TITLE_BAR_H)
    titleBar:SetPoint("TOPLEFT",  f, "TOPLEFT",  0, 0)
    titleBar:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", safe.WrapScript("TitleBar:OnDragStart",
        function() f:StartMoving() end))
    titleBar:SetScript("OnDragStop", safe.WrapScript("TitleBar:OnDragStop",
        function() f:StopMovingOrSizing(); SaveWindowPos(f) end))

    local title = titleBar:CreateFontString(nil, "OVERLAY", theme.FONT_TITLE)
    title:SetPoint("LEFT", titleBar, "LEFT", theme.PADDING, 0)
    title:SetText(L["Details! iLvl Display"] .. "  v" .. (ns.version or "?"))
    theme.SetTextColor(title, "accent")

    -- UIPanelCloseButton has a default OnClick that hides its parent.
    -- HookScript adds our handler without clobbering Blizzard's default.
    local closeBtn = CreateFrame("Button", nil, titleBar, "UIPanelCloseButton")
    closeBtn:SetPoint("RIGHT", titleBar, "RIGHT", -2, 0)
    closeBtn:HookScript("OnClick", safe.WrapScript("CloseButton:Hook", function()
        -- Persist on close in addition to the default Hide-parent action.
        SaveWindowPos(f)
    end))

    f.titleBar = titleBar

    -- ── Tab bar ──
    local tabBar = CreateFrame("Frame", nil, f)
    tabBar:SetHeight(theme.TAB_BAR_H)
    tabBar:SetPoint("TOPLEFT",  titleBar, "BOTTOMLEFT",  0, -2)
    tabBar:SetPoint("TOPRIGHT", titleBar, "BOTTOMRIGHT", 0, -2)
    f.tabBar = tabBar
    f.tabs = {}

    for i, entry in ipairs(main.pages) do
        f.tabs[i] = CreateTabButton(tabBar, f.tabs, entry, i)
    end

    -- ── Content area (above preview pane) ──
    local content = CreateFrame("Frame", nil, f)
    content:SetPoint("TOPLEFT",     tabBar,  "BOTTOMLEFT",  theme.PADDING, -theme.PADDING)
    content:SetPoint("TOPRIGHT",    tabBar,  "BOTTOMRIGHT", -theme.PADDING, -theme.PADDING)
    -- Bottom edge sits above the preview pane (with footer below preview).
    content:SetHeight(theme.WINDOW_H
        - theme.TITLE_BAR_H - theme.TAB_BAR_H
        - theme.PREVIEW_H - theme.FOOTER_H
        - theme.PADDING * 3 - 2)
    f.content = content

    -- ── Preview pane (PERSISTENT — visible across all tabs) ──
    local previewPane = CreateFrame("Frame", nil, f, "BackdropTemplate")
    previewPane:SetPoint("TOPLEFT",  content, "BOTTOMLEFT",  0, -theme.PADDING)
    previewPane:SetPoint("TOPRIGHT", content, "BOTTOMRIGHT", 0, -theme.PADDING)
    previewPane:SetHeight(theme.PREVIEW_H)
    theme.ApplyBackdrop(previewPane, "panel")
    f.previewPane = previewPane

    local previewTitle = previewPane:CreateFontString(nil, "OVERLAY", theme.FONT_HEADING)
    previewTitle:SetPoint("TOPLEFT", previewPane, "TOPLEFT", 10, -8)
    previewTitle:SetText(L["Live Preview"])
    theme.SetTextColor(previewTitle, "title")

    -- Placeholder body — Phase 4 will populate with mock Details!-bars + mock
    -- unit-frame + mock Danders-overlay that update live on db change.
    local previewBody = previewPane:CreateFontString(nil, "OVERLAY", theme.FONT_LABEL)
    previewBody:SetPoint("TOPLEFT",  previewPane, "TOPLEFT",  20, -36)
    previewBody:SetPoint("BOTTOMRIGHT", previewPane, "BOTTOMRIGHT", -20, 12)
    previewBody:SetJustifyH("LEFT")
    previewBody:SetJustifyV("TOP")
    previewBody:SetText(
        "Live Preview Pane\n\n"
        .. "Coming in Phase 4: mock Details!-bars + mock unit-frame +\n"
        .. "mock Danders-overlay that update live as you change settings\n"
        .. "on the tabs above. No tab-switching needed.")
    theme.SetTextColor(previewBody, "secondary")

    -- ── Footer ──
    local footer = CreateFrame("Frame", nil, f, "BackdropTemplate")
    footer:SetHeight(theme.FOOTER_H)
    footer:SetPoint("BOTTOMLEFT",  f, "BOTTOMLEFT",  0, 0)
    footer:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
    theme.ApplyBackdrop(footer, "panel")

    local hintFS = footer:CreateFontString(nil, "OVERLAY", theme.FONT_HELPER)
    hintFS:SetPoint("LEFT", footer, "LEFT", theme.PADDING, 0)
    hintFS:SetText(L["FOOTER_HINT"])
    theme.SetTextColor(hintFS, "secondary")

    local versionFS = footer:CreateFontString(nil, "OVERLAY", theme.FONT_HELPER)
    versionFS:SetPoint("RIGHT", footer, "RIGHT", -theme.PADDING, 0)
    versionFS:SetText("v" .. (ns.version or "?"))
    theme.SetTextColor(versionFS, "secondary")

    main.frame = f
    return f
end

---------------------------------------------------------------
-- Public Open / Close / Toggle
---------------------------------------------------------------
function main.Open(pageId)
    if InCombatLockdown() then
        ns._uiOpenPending = pageId or true
        return false
    end
    local f = BuildFrame()
    f:Show()

    local state = GetDbState()
    local target = pageId or (state and state.lastTab) or (main.pages[1] and main.pages[1].id)
    if target and main.pagesByID[target] then
        main.SwitchTab(target)
    elseif main.pages[1] then
        main.SwitchTab(main.pages[1].id)
    end
    return true
end

function main.Close()
    if main.frame and main.frame:IsShown() then
        SaveWindowPos(main.frame)
        main.frame:Hide()
    end
end

function main.Toggle(pageId)
    if main.frame and main.frame:IsShown() then
        main.Close()
    else
        main.Open(pageId)
    end
end

---------------------------------------------------------------
-- Deferred-open event handler — fires the pending open after combat ends.
-- Wrapped in SafeCallback so a bad Open() doesn't leave the handler stuck
-- firing on every combat-end forever.
---------------------------------------------------------------
local deferFrame = CreateFrame("Frame")
deferFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
deferFrame:SetScript("OnEvent", safe.WrapScript("DeferredOpen", function()
    if ns._uiOpenPending then
        local pid = (ns._uiOpenPending ~= true) and ns._uiOpenPending or nil
        ns._uiOpenPending = nil
        main.Open(pid)
    end
end))
