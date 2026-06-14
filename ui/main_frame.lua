-- ui/main_frame.lua — Settings window skeleton.
--
-- ARCHITECTURE:
--   - One singleton frame, lazy-created on first /dilvl ui call.
--   - 3 horizontal top-tabs (General / Output Channels / Diagnostics).
--   - Tab content fills upper area; persistent preview pane sits below tabs.
--     User sees preview update live as they change settings.
--   - Tab switching = SafePageInit -> page Init(contentFrame), with
--     fault-isolation via ns.ui.safe.
--   - Position + last-active-tab persisted in db.uiState (SavedVar subtable).
--   - UISpecialFrames registration -> Escape key closes the window.
--   - This file deliberately stays minimal (no business logic) because it's
--     the one file whose failure would kill the entire UI.

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

local function SaveWindowSize(f)
    local state = GetDbState()
    if not state then return end
    state.w = f:GetWidth()
    state.h = f:GetHeight()
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
    f:SetResizable(true)
    if f.SetResizeBounds then
        -- 11.0+ API: combined min + max bounds in one call
        f:SetResizeBounds(theme.WINDOW_W_MIN, theme.WINDOW_H_MIN,
                          theme.WINDOW_W_MAX, theme.WINDOW_H_MAX)
    end
    theme.ApplyBackdrop(f, "window")
    f:Hide()

    RestoreWindowPos(f)
    -- Restore custom size if user resized before
    local state = GetDbState()
    if state and state.w and state.h then
        f:SetSize(state.w, state.h)
    end
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

    -- UIPanelCloseButton's default OnClick is `self:GetParent():Hide()`.
    -- We parent it to `f` (NOT titleBar) so the default actually hides the
    -- window. Anchor still aligns to titleBar visually. HookScript adds our
    -- position-persist alongside the default.
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", titleBar, "TOPRIGHT", -2, -2)
    closeBtn:HookScript("OnClick", safe.WrapScript("CloseButton:Hook", function()
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

    -- ── Footer (anchored to window bottom, fixed height) ──
    -- Built BEFORE preview/content so the chain anchors upward cleanly.

    -- ── Preview pane (PERSISTENT, fixed height above footer) ──
    -- BOTTOMLEFT/BOTTOMRIGHT anchoring so it stays glued above the footer
    -- when the window is resized vertically. Height stays fixed.
    local previewContainer = CreateFrame("Frame", nil, f)
    previewContainer:SetPoint("BOTTOMLEFT",  f, "BOTTOMLEFT",  theme.PADDING, theme.FOOTER_H + theme.PADDING)
    previewContainer:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -theme.PADDING, theme.FOOTER_H + theme.PADDING)
    previewContainer:SetHeight(theme.PREVIEW_H)
    f.previewPane = previewContainer

    -- ── Content area (fills between tabBar and previewContainer) ──
    -- TOPLEFT to tabBar bottom + BOTTOMRIGHT to previewContainer top so
    -- content auto-resizes with the window.
    local content = CreateFrame("Frame", nil, f)
    content:SetPoint("TOPLEFT",     tabBar,             "BOTTOMLEFT",   theme.PADDING, -theme.PADDING)
    content:SetPoint("TOPRIGHT",    tabBar,             "BOTTOMRIGHT", -theme.PADDING, -theme.PADDING)
    content:SetPoint("BOTTOMLEFT",  previewContainer,   "TOPLEFT",      0, theme.PADDING)
    content:SetPoint("BOTTOMRIGHT", previewContainer,   "TOPRIGHT",     0, theme.PADDING)
    f.content = content

    -- Left: Damage Meter Preview (Details! / BlizzDM mocks).
    -- Width auto-updates via previewContainer:OnSizeChanged below so the
    -- 50/50 split holds when the user resizes the window.
    local dmPane = CreateFrame("Frame", nil, previewContainer, "BackdropTemplate")
    dmPane:SetPoint("TOPLEFT", previewContainer, "TOPLEFT", 0, 0)
    dmPane:SetPoint("BOTTOMLEFT", previewContainer, "BOTTOMLEFT", 0, 0)
    dmPane:SetWidth((theme.WINDOW_W - theme.PADDING * 3) / 2)
    theme.ApplyBackdrop(dmPane, "panel")
    f.previewDM = dmPane

    -- Re-split 50/50 whenever the preview container changes width
    previewContainer:SetScript("OnSizeChanged", function(self, w, _)
        dmPane:SetWidth((w - theme.PADDING) / 2)
    end)

    local dmTitle = dmPane:CreateFontString(nil, "OVERLAY", theme.FONT_HEADING)
    dmTitle:SetPoint("TOPLEFT", dmPane, "TOPLEFT", 10, -8)
    dmTitle:SetText(L["Damage Meter Preview"])
    theme.SetTextColor(dmTitle, "title")
    dmTitle._titleKeep = true  -- preview.PopulateDamageMeter won't wipe this

    -- Right: Unit Frame Preview (ElvUI / Grid2 / Danders mocks)
    local ufPane = CreateFrame("Frame", nil, previewContainer, "BackdropTemplate")
    ufPane:SetPoint("TOPLEFT",  dmPane, "TOPRIGHT", theme.PADDING, 0)
    ufPane:SetPoint("BOTTOMRIGHT", previewContainer, "BOTTOMRIGHT", 0, 0)
    theme.ApplyBackdrop(ufPane, "panel")
    f.previewUF = ufPane

    local ufTitle = ufPane:CreateFontString(nil, "OVERLAY", theme.FONT_HEADING)
    ufTitle:SetPoint("TOPLEFT", ufPane, "TOPLEFT", 10, -8)
    ufTitle:SetText(L["Unit Frame Preview"])
    theme.SetTextColor(ufTitle, "title")
    ufTitle._titleKeep = true

    -- Populate the live mocks (defer to next frame to ensure layout is resolved)
    C_Timer.After(0, function()
        if ns.ui.preview then
            ns.ui.preview.PopulateDamageMeter(dmPane)
            ns.ui.preview.PopulateUnitFrames(ufPane)
        end
    end)

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

    -- ── Resize handle (DandersFrames-style grip in bottom-right corner) ──
    -- Standard Blizzard ChatFrame size-grabber textures so it looks native.
    -- Anchored AFTER footer so it sits on top of the footer's right edge,
    -- not behind it.
    local grip = CreateFrame("Button", nil, f)
    grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
    grip:SetSize(16, 16)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetFrameLevel(f:GetFrameLevel() + 5)
    grip:SetScript("OnMouseDown", safe.WrapScript("ResizeGrip:Down", function(self, button)
        if button == "LeftButton" then f:StartSizing("BOTTOMRIGHT") end
    end))
    grip:SetScript("OnMouseUp", safe.WrapScript("ResizeGrip:Up", function()
        f:StopMovingOrSizing()
        SaveWindowSize(f)
        SaveWindowPos(f)
    end))

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
    -- Default tab: an explicit pageId wins; otherwise show "What's New" once
    -- after the addon updates (so a new feature never goes unnoticed), then
    -- fall back to the user's last-used tab.
    local target = pageId
    if not target then
        if state and state.lastSeenVersion ~= ns.version and main.pagesByID["whatsnew"] then
            target = "whatsnew"
        else
            target = (state and state.lastTab) or (main.pages[1] and main.pages[1].id)
        end
    end
    if state then state.lastSeenVersion = ns.version end
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

---------------------------------------------------------------
-- PLAYER_LOGIN sanity check. Catches TOC-load-order regressions early:
-- if no pages have registered by login, route a one-shot message via
-- geterrorhandler() (BugSack picks up) so the maintainer notices the
-- regression instead of users hitting a blank-tab-bar window.
---------------------------------------------------------------
local sanityFrame = CreateFrame("Frame")
sanityFrame:RegisterEvent("PLAYER_LOGIN")
sanityFrame:SetScript("OnEvent", function(self)
    if #main.pages == 0 then
        local handler = geterrorhandler()
        if handler then
            pcall(handler, "Details_iLvlDisplay UI: no pages registered at PLAYER_LOGIN "
                .. "(check TOC load order — page files must load AFTER ui/main_frame.lua).")
        end
    end
    self:UnregisterAllEvents()
end)
