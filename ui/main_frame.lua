-- ui/main_frame.lua — Settings window skeleton.
--
-- ARCHITECTURE:
--   - One singleton frame, lazy-created on first /dilvl ui call.
--   - 4 horizontal top-tabs (General / Channels / Live Preview / Diagnostics).
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
-- Tab registry. Pages are added by their own file calling
-- ns.ui.main.RegisterPage(id, labelKey, initFn). This way main_frame.lua
-- doesn't import every page file — pages are responsible for self-registering
-- on file load. Decoupled, page failures don't propagate here.
---------------------------------------------------------------
main.pages = {}      -- ordered list: { {id="general", labelKey="General", initFn=...}, ... }
main.pagesByID = {}  -- pageId -> entry

function main.RegisterPage(id, labelKey, initFn)
    if main.pagesByID[id] then return end -- guard against double-registration
    local entry = {id = id, labelKey = labelKey, initFn = initFn, initialized = false}
    table.insert(main.pages, entry)
    main.pagesByID[id] = entry
end

---------------------------------------------------------------
-- Singleton frame access.
---------------------------------------------------------------
main.frame = nil  -- the actual CreateFrame instance, lazy
main.activeTabId = nil

local function GetDbState()
    -- ns.db is set by core.lua at ADDON_LOADED. uiState lives under it.
    local db = ns.db or _G.Details_iLvlDisplayDB
    if not db then return nil end
    db.uiState = db.uiState or { x = nil, y = nil, lastTab = "general" }
    return db.uiState
end

---------------------------------------------------------------
-- Tab strip — one button per registered page.
---------------------------------------------------------------
local function CreateTabButton(parent, entry, index)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(140, theme.TAB_BAR_H - 4)
    if index == 1 then
        btn:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", theme.PADDING, 0)
    else
        btn:SetPoint("LEFT", parent.tabs[index - 1], "RIGHT", 4, 0)
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

    btn:SetScript("OnEnter", function(self)
        if main.activeTabId ~= entry.id then
            theme.ApplyBackdrop(self, "tab_active")
        end
    end)
    btn:SetScript("OnLeave", function(self)
        if main.activeTabId ~= entry.id then
            theme.ApplyBackdrop(self, "tab_inactive")
        end
    end)

    btn.entry = entry
    return btn
end

---------------------------------------------------------------
-- Tab switching — clears the content area, calls page initFn via
-- SafePageInit, swaps to error placeholder if needed. Persists active tab.
---------------------------------------------------------------
function main.SwitchTab(pageId)
    if not main.frame or not main.frame.content then return end
    local entry = main.pagesByID[pageId]
    if not entry then return end

    -- Update tab visuals (active/inactive)
    for _, b in ipairs(main.frame.tabs) do
        theme.ApplyBackdrop(b, b.entry.id == pageId and "tab_active" or "tab_inactive")
        theme.SetTextColor(b.label, b.entry.id == pageId and "accent" or "primary")
    end
    main.activeTabId = pageId

    -- Clear previous content children (hide; full GC waits for /reload).
    for _, child in ipairs({main.frame.content:GetChildren()}) do
        child:Hide()
        child:SetParent(nil)
    end

    -- Render page (or placeholder if broken).
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

    -- Restore position
    local state = GetDbState()
    if state and state.x and state.y then
        f:SetPoint("CENTER", UIParent, "CENTER", state.x, state.y)
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end

    -- Escape-to-close
    tinsert(UISpecialFrames, "Details_iLvlDisplay_SettingsFrame")

    -- ── Title bar ──
    local titleBar = CreateFrame("Frame", nil, f, "BackdropTemplate")
    titleBar:SetHeight(theme.TITLE_BAR_H)
    titleBar:SetPoint("TOPLEFT",  f, "TOPLEFT",  0, 0)
    titleBar:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function() f:StartMoving() end)
    titleBar:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        local _, _, _, x, y = f:GetPoint(1)
        local s = GetDbState()
        if s then s.x = x; s.y = y end
    end)

    local title = titleBar:CreateFontString(nil, "OVERLAY", theme.FONT_TITLE)
    title:SetPoint("LEFT", titleBar, "LEFT", theme.PADDING, 0)
    title:SetText(L["Details! iLvl Display"] .. "  v" .. (ns.version or "?"))
    theme.SetTextColor(title, "accent")

    local closeBtn = CreateFrame("Button", nil, titleBar, "UIPanelCloseButton")
    closeBtn:SetPoint("RIGHT", titleBar, "RIGHT", -2, 0)
    closeBtn:SetScript("OnClick", safe.WrapScript("CloseButton", function() f:Hide() end))

    f.titleBar = titleBar

    -- ── Tab bar ──
    local tabBar = CreateFrame("Frame", nil, f)
    tabBar:SetHeight(theme.TAB_BAR_H)
    tabBar:SetPoint("TOPLEFT",  titleBar, "BOTTOMLEFT",  0, -2)
    tabBar:SetPoint("TOPRIGHT", titleBar, "BOTTOMRIGHT", 0, -2)
    f.tabBar = tabBar
    f.tabs = {}

    for i, entry in ipairs(main.pages) do
        f.tabs[i] = CreateTabButton(tabBar, entry, i)
    end

    -- ── Content area ──
    local content = CreateFrame("Frame", nil, f)
    content:SetPoint("TOPLEFT",     tabBar,  "BOTTOMLEFT",  theme.PADDING, -theme.PADDING)
    content:SetPoint("BOTTOMRIGHT", f,       "BOTTOMRIGHT", -theme.PADDING, theme.FOOTER_H + theme.PADDING)
    f.content = content

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
-- Public Open / Close / Toggle entry points (called by slash_ui.lua and
-- blizzard_settings.lua).
---------------------------------------------------------------
function main.Open(pageId)
    -- In-combat refusal (Plater pattern): defer to PLAYER_REGEN_ENABLED.
    if InCombatLockdown() then
        ns._uiOpenPending = pageId or true
        return false
    end
    local f = BuildFrame()
    f:Show()

    local state = GetDbState()
    local target = pageId or (state and state.lastTab) or (main.pages[1] and main.pages[1].id)
    if target then main.SwitchTab(target) end
    return true
end

function main.Close()
    if main.frame then main.frame:Hide() end
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
---------------------------------------------------------------
local deferFrame = CreateFrame("Frame")
deferFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
deferFrame:SetScript("OnEvent", function()
    if ns._uiOpenPending then
        local pid = (ns._uiOpenPending ~= true) and ns._uiOpenPending or nil
        ns._uiOpenPending = nil
        main.Open(pid)
    end
end)
