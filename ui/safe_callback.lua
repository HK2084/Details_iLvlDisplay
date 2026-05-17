-- ui/safe_callback.lua — 3-layer fault isolation for the Settings UI
--
-- Mirrors the per-feature kill-switch pattern from core.lua / blizzdm.lua /
-- danders_integration.lua onto the UI layer. Hasan-rule: a Lua error in
-- one settings page must NEVER take down the entire settings window or
-- the addon proper.
--
-- THREE LAYERS:
--   1. SafeCallback(label, fn, ...) — wraps a single widget callback. Errors
--      route to geterrorhandler() (BugSack picks up), increment the OWNING
--      page's error counter. The user-visible UI keeps working.
--   2. SafePageInit(pageId, initFn) — wraps a page's init/OnShow/OnHide. If
--      init throws, the page swaps to an ERROR PLACEHOLDER (see below).
--   3. Per-page error counter (default cap 5) — when a page accumulates 5
--      errors, it's permanently swapped to a "Settings page broken — use
--      slash commands or /reload" placeholder for the rest of the session.
--      Counter resets on /reload.
--
-- WHY THIS IS NOVEL: deep-dive 2026-05-16 found that DandersFrames (8243 LOC
-- UI, 2 pcalls), Plater (11.932 LOC UI, 0 pcalls), BigWigs, Cell, ElvUI all
-- trust their UI code absolutely. No addon does per-page error counters.
-- This file is direct improvement on the ecosystem.

local addonName, ns = ...
ns.ui = ns.ui or {}
local SC = {}
ns.ui.safe = SC

---------------------------------------------------------------
-- State: per-page error tracking. Page IDs are short strings
-- like "general" / "channels" / "preview" / "diagnostics".
---------------------------------------------------------------
SC.MAX_PAGE_ERRORS = 5
SC.pageErrors      = {}  -- pageId -> error count this session
SC.pageBroken      = {}  -- pageId -> true once disabled
SC.pageLastError   = {}  -- pageId -> last error string (for placeholder display)
SC.currentPage     = nil -- set by main_frame.lua when switching pages

---------------------------------------------------------------
-- Layer 1: SafeCallback — wrap a single widget callback
--
-- Use this in EVERY widget OnClick / OnValueChanged / OnEnterPressed.
-- Cheap (one pcall), defensive, attributes errors to whichever page is
-- currently visible.
---------------------------------------------------------------
function SC.SafeCallback(label, fn, ...)
    if not fn then return end
    local ok, a, b, c = pcall(fn, ...)
    if ok then return a, b, c end
    SC._registerError(SC.currentPage or "unknown", label, a)
    return nil
end

-- Convenience: produce a wrapped script-handler ready for SetScript.
-- frame:SetScript("OnClick", SC.WrapScript("MyButton:OnClick", function(self) ... end))
function SC.WrapScript(label, fn)
    return function(...)
        return SC.SafeCallback(label, fn, ...)
    end
end

---------------------------------------------------------------
-- Layer 2: SafePageInit — wrap a page's init/show/hide
--
-- Caller pattern (in main_frame.lua tab-switch logic):
--   local ok = SC.SafePageInit("general", function() ns.ui.pages.general.Init(contentFrame) end)
--   if not ok then ShowPlaceholder(contentFrame, "general") end
---------------------------------------------------------------
function SC.SafePageInit(pageId, initFn)
    if SC.pageBroken[pageId] then return false end
    SC.currentPage = pageId
    local ok, err = pcall(initFn)
    if not ok then
        SC._registerError(pageId, "init", err)
        return false
    end
    return true
end

---------------------------------------------------------------
-- Layer 3: per-page error tracking + permanent disable
---------------------------------------------------------------
function SC._registerError(pageId, label, err)
    pageId = pageId or "unknown"
    SC.pageErrors[pageId] = (SC.pageErrors[pageId] or 0) + 1
    SC.pageLastError[pageId] = ("[%s] %s"):format(label or "?", tostring(err))
    -- Route through WoW's error handler so BugSack catches it.
    local handler = geterrorhandler()
    if handler then
        pcall(handler, ("Details_iLvlDisplay UI[%s/%s]: %s"):format(
            pageId, label or "?", tostring(err)))
    end
    if SC.pageErrors[pageId] >= SC.MAX_PAGE_ERRORS and not SC.pageBroken[pageId] then
        SC.pageBroken[pageId] = true
        -- One final BugSack message announcing the permanent disable.
        if handler then
            pcall(handler, ("Details_iLvlDisplay UI[%s]: page disabled after %d errors. "
                .. "Last: %s. Use slash commands or /reload to recover."):format(
                pageId, SC.MAX_PAGE_ERRORS, SC.pageLastError[pageId]))
        end
    end
end

---------------------------------------------------------------
-- Placeholder builder — replaces a broken page's content with an
-- error banner. Called by main_frame.lua when SafePageInit returns false
-- or when SC.pageBroken[pageId] is true.
---------------------------------------------------------------
function SC.BuildPlaceholder(parent, pageId)
    if not parent then return end
    -- Clear children (any half-rendered widgets from the broken init).
    -- Cheap version: hide them. Full cleanup happens on /reload.
    for _, child in ipairs({parent:GetChildren()}) do
        child:Hide()
    end
    local theme = ns.ui and ns.ui.theme
    local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    frame:SetAllPoints(parent)
    if theme then theme.ApplyBackdrop(frame, "error") end

    local title = frame:CreateFontString(nil, "OVERLAY",
        theme and theme.FONT_HEADING or "GameFontNormalLarge")
    title:SetPoint("TOP", frame, "TOP", 0, -20)
    title:SetText("Settings page broken")
    if theme then theme.SetTextColor(title, "error") end

    local body = frame:CreateFontString(nil, "OVERLAY",
        theme and theme.FONT_LABEL or "GameFontNormal")
    body:SetPoint("TOP", title, "BOTTOM", 0, -10)
    body:SetWidth(parent:GetWidth() - 40)
    body:SetJustifyH("CENTER")
    body:SetText(("Page '%s' has been disabled after %d errors.\n"
        .. "Other pages still work. Use /dilvl slash commands\n"
        .. "or /reload to recover."):format(
        pageId, SC.MAX_PAGE_ERRORS))
    if theme then theme.SetTextColor(body, "secondary") end

    local errLabel = frame:CreateFontString(nil, "OVERLAY",
        theme and theme.FONT_HELPER or "GameFontHighlightSmall")
    errLabel:SetPoint("BOTTOM", frame, "BOTTOM", 0, 20)
    errLabel:SetWidth(parent:GetWidth() - 40)
    errLabel:SetJustifyH("CENTER")
    errLabel:SetText("Last error: " .. (SC.pageLastError[pageId] or "<unknown>"))
    if theme then theme.SetTextColor(errLabel, "disabled") end

    return frame
end

---------------------------------------------------------------
-- Diagnostics: called by /dilvl debug to surface UI-layer error counts
---------------------------------------------------------------
function SC.GetDiagnostics()
    local lines = { "  --- Settings UI ---" }
    local any = false
    for pageId, count in pairs(SC.pageErrors) do
        any = true
        lines[#lines + 1] = string.format("    page[%s]: %d/%d errors%s%s",
            pageId, count, SC.MAX_PAGE_ERRORS,
            SC.pageBroken[pageId] and "  DISABLED" or "",
            SC.pageLastError[pageId] and ("  last: " .. SC.pageLastError[pageId]) or "")
    end
    if not any then
        lines[#lines + 1] = "    no errors this session"
    end
    return lines
end

---------------------------------------------------------------
-- Reset (manual recovery without /reload — called by a "Reset UI errors"
-- button on the Diagnostics page).
---------------------------------------------------------------
function SC.ResetPage(pageId)
    SC.pageErrors[pageId] = 0
    SC.pageBroken[pageId] = nil
    SC.pageLastError[pageId] = nil
end

function SC.ResetAll()
    SC.pageErrors    = {}
    SC.pageBroken    = {}
    SC.pageLastError = {}
end
