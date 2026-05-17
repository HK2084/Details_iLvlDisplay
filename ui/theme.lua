-- ui/theme.lua — central theming for the Settings UI
--
-- DESIGN PHILOSOPHY: schlicht, clean, eigenes Styling (NOT 1:1 DandersFrames).
-- Dark background + minimal accent. Subtle gold/orange accent matches our
-- iLvl-tier-color palette so the UI feels thematically connected to what
-- the addon actually shows.
--
-- All colors here, nowhere else. If we ever want to re-theme, change one file.

local addonName, ns = ...
ns.ui = ns.ui or {}
local theme = {}
ns.ui.theme = theme

---------------------------------------------------------------
-- COLOR PALETTE
---------------------------------------------------------------
-- Backgrounds (dark, neutral, no blue tint like DandersFrames purple)
theme.BG_WINDOW       = {0.08, 0.08, 0.08, 0.94}   -- main window
theme.BG_PANEL        = {0.12, 0.12, 0.12, 0.85}   -- group boxes / panels
theme.BG_PANEL_HOVER  = {0.16, 0.16, 0.16, 0.85}   -- panel hover state
theme.BG_TAB_INACTIVE = {0.10, 0.10, 0.10, 0.80}
theme.BG_TAB_ACTIVE   = {0.18, 0.18, 0.18, 0.95}
theme.BG_INFO_BAR     = {0.15, 0.13, 0.10, 0.85}   -- info banner (subtle warm)
theme.BG_ERROR_BAR    = {0.30, 0.10, 0.10, 0.85}   -- error placeholder

-- Borders
theme.BORDER          = {0.20, 0.20, 0.20, 1.00}
theme.BORDER_ACTIVE   = {0.85, 0.65, 0.20, 1.00}   -- accent on active tab/border

-- Text
theme.TEXT_PRIMARY    = {0.95, 0.95, 0.95, 1.00}   -- main labels
theme.TEXT_SECONDARY  = {0.65, 0.65, 0.65, 1.00}   -- helper text / muted
theme.TEXT_DISABLED   = {0.40, 0.40, 0.40, 1.00}
theme.TEXT_ACCENT     = {0.95, 0.75, 0.30, 1.00}   -- gold accent (matches iLvl BiS color)
theme.TEXT_SUCCESS    = {0.45, 0.85, 0.40, 1.00}   -- green (auto-detect ✓)
theme.TEXT_ERROR      = {0.95, 0.40, 0.40, 1.00}   -- red (auto-detect ✗ / error)

-- Section title (iLvl-tier-color matched gold)
theme.TITLE_COLOR     = theme.TEXT_ACCENT

---------------------------------------------------------------
-- DIMENSIONS
---------------------------------------------------------------
theme.WINDOW_W        = 720
theme.WINDOW_H        = 520
theme.TITLE_BAR_H     = 28
theme.TAB_BAR_H       = 32
theme.FOOTER_H        = 24
theme.PADDING         = 12
theme.PANEL_INSET     = 8
theme.WIDGET_GAP      = 6
theme.SECTION_GAP     = 14

---------------------------------------------------------------
-- FONTS (use Blizzard's standard fonts — guaranteed available, no media-lib dep)
---------------------------------------------------------------
theme.FONT_TITLE      = "GameFontNormalLarge"      -- 14pt, gold-ish
theme.FONT_HEADING    = "GameFontNormalMed3"       -- 13pt
theme.FONT_LABEL      = "GameFontNormal"           -- 12pt white
theme.FONT_HELPER     = "GameFontHighlightSmall"   -- 10pt grey
theme.FONT_BUTTON     = "GameFontNormal"

---------------------------------------------------------------
-- BACKDROP RECIPES
-- These are the actual SetBackdrop tables. Use ApplyBackdrop(frame, kind)
-- below — never SetBackdrop directly in widget code, so re-theming stays
-- single-source.
---------------------------------------------------------------
local BACKDROP_WINDOW = {
    bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    tile     = true,
    tileSize = 64,
    edgeSize = 1,
    insets   = {left=1, right=1, top=1, bottom=1},
}

local BACKDROP_PANEL = {
    bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    tile     = true,
    tileSize = 32,
    edgeSize = 1,
    insets   = {left=1, right=1, top=1, bottom=1},
}

local BACKDROP_TAB = {
    bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    tile     = true,
    tileSize = 32,
    edgeSize = 1,
    insets   = {left=1, right=1, top=1, bottom=1},
}

-- Apply one of: "window" | "panel" | "tab" | "info" | "error"
-- Frame MUST have BackdropTemplate (created via CreateFrame(..., "BackdropTemplate"))
function theme.ApplyBackdrop(frame, kind)
    if not frame.SetBackdrop then return end -- defensive: missing template
    if kind == "window" then
        frame:SetBackdrop(BACKDROP_WINDOW)
        frame:SetBackdropColor(unpack(theme.BG_WINDOW))
        frame:SetBackdropBorderColor(unpack(theme.BORDER))
    elseif kind == "panel" then
        frame:SetBackdrop(BACKDROP_PANEL)
        frame:SetBackdropColor(unpack(theme.BG_PANEL))
        frame:SetBackdropBorderColor(unpack(theme.BORDER))
    elseif kind == "tab_active" then
        frame:SetBackdrop(BACKDROP_TAB)
        frame:SetBackdropColor(unpack(theme.BG_TAB_ACTIVE))
        frame:SetBackdropBorderColor(unpack(theme.BORDER_ACTIVE))
    elseif kind == "tab_inactive" then
        frame:SetBackdrop(BACKDROP_TAB)
        frame:SetBackdropColor(unpack(theme.BG_TAB_INACTIVE))
        frame:SetBackdropBorderColor(unpack(theme.BORDER))
    elseif kind == "info" then
        frame:SetBackdrop(BACKDROP_PANEL)
        frame:SetBackdropColor(unpack(theme.BG_INFO_BAR))
        frame:SetBackdropBorderColor(unpack(theme.BORDER_ACTIVE))
    elseif kind == "error" then
        frame:SetBackdrop(BACKDROP_PANEL)
        frame:SetBackdropColor(unpack(theme.BG_ERROR_BAR))
        frame:SetBackdropBorderColor(unpack(theme.TEXT_ERROR))
    end
end

-- Shortcut for text colors. Pass a FontString + one of:
-- "primary" | "secondary" | "disabled" | "accent" | "success" | "error" | "title"
function theme.SetTextColor(fs, kind)
    if not fs then return end
    local c = ({
        primary   = theme.TEXT_PRIMARY,
        secondary = theme.TEXT_SECONDARY,
        disabled  = theme.TEXT_DISABLED,
        accent    = theme.TEXT_ACCENT,
        success   = theme.TEXT_SUCCESS,
        error     = theme.TEXT_ERROR,
        title     = theme.TITLE_COLOR,
    })[kind] or theme.TEXT_PRIMARY
    fs:SetTextColor(c[1], c[2], c[3], c[4])
end
