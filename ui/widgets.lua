-- ui/widgets.lua — self-contained widget toolkit
--
-- DESIGN: prefer Blizzard native templates (UICheckButtonTemplate,
-- OptionsSliderTemplate, UIDropDownMenuTemplate, UIPanelButtonTemplate,
-- UIPanelScrollFrameTemplate) — battle-tested, zero LOC, free upgrades from
-- Blizzard UI patches. Custom code only for what doesn't exist natively:
-- themed Panel, themed Sidebar/Tabs, themed Label.
--
-- Every widget factory takes (parent, ...) and returns the widget. SavedVar
-- binding is done by the caller via db setters / getters passed in.
--
-- Every interactive widget's callback is wrapped through ns.ui.safe.WrapScript
-- so a single broken handler can never propagate.

local addonName, ns = ...
ns.ui = ns.ui or {}
local W = {}
ns.ui.widgets = W

local theme = ns.ui.theme
local safe  = ns.ui.safe

-- Monotonic counter for globally-named widgets (Blizzard's UIDropDownMenuTemplate
-- needs a global frame name for OnEnter/OnLeave hooking). Avoids birthday-paradox
-- collisions of math.random — guaranteed unique within session.
local _widgetSeq = 0
local function uniqueName(prefix)
    _widgetSeq = _widgetSeq + 1
    return prefix .. _widgetSeq
end

---------------------------------------------------------------
-- CreatePanel — boxed group with optional title FontString.
-- Use for visual grouping of related settings.
---------------------------------------------------------------
function W.CreatePanel(parent, w, h, title)
    local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    frame:SetSize(w, h)
    theme.ApplyBackdrop(frame, "panel")

    if title and title ~= "" then
        local fs = frame:CreateFontString(nil, "OVERLAY", theme.FONT_HEADING)
        fs:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -8)
        fs:SetText(title)
        theme.SetTextColor(fs, "title")
        frame.title = fs
    end
    return frame
end

---------------------------------------------------------------
-- CreateLabel — text fontstring with theme color + optional wrap-width.
---------------------------------------------------------------
function W.CreateLabel(parent, text, font, colorKind, wrapWidth)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or theme.FONT_LABEL)
    fs:SetText(text or "")
    theme.SetTextColor(fs, colorKind or "primary")
    if wrapWidth then
        fs:SetWidth(wrapWidth)
        fs:SetJustifyH("LEFT")
    end
    return fs
end

---------------------------------------------------------------
-- CreateCheckbox — Blizzard UICheckButtonTemplate, themed label, db binding.
--
-- Usage:
--   local cb = W.CreateCheckbox(parent, "Enable Foo",
--       function() return db.foo end,             -- getter
--       function(v) db.foo = v; SomeRefresh() end -- setter
--   )
--   cb:SetPoint(...)
---------------------------------------------------------------
function W.CreateCheckbox(parent, label, getter, setter, tooltip)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    -- The template ships with a FontString at cb.Text — re-style it to our theme.
    if cb.Text then
        cb.Text:SetText(label or "")
        cb.Text:SetFontObject(theme.FONT_LABEL)
        theme.SetTextColor(cb.Text, "primary")
        cb.Text:ClearAllPoints()
        cb.Text:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    end

    -- Initial state from getter. OnShow handles future re-syncs; explicit
    -- call here covers the common case (widget created when parent already
    -- visible — OnShow doesn't fire without a state change).
    cb:SetScript("OnShow", safe.WrapScript("Checkbox:OnShow:" .. (label or "?"), function(self)
        if getter then self:SetChecked(getter() and true or false) end
    end))
    if getter then
        local ok, v = pcall(getter)
        if ok then cb:SetChecked(v and true or false) end
    end

    cb:SetScript("OnClick", safe.WrapScript("Checkbox:OnClick:" .. (label or "?"), function(self)
        if setter then setter(self:GetChecked() and true or false) end
    end))

    if tooltip then
        cb:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(label or "", 1, 1, 1)
            GameTooltip:AddLine(tooltip, nil, nil, nil, true)
            GameTooltip:Show()
        end)
        cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    return cb
end

---------------------------------------------------------------
-- CreateSlider — Blizzard OptionsSliderTemplate with themed label.
--
-- Usage:
--   local sl = W.CreateSlider(parent, "Font Size", 6, 30, 1,
--       function() return db.size end,
--       function(v) db.size = v; LiveUpdate(v) end
--   )
---------------------------------------------------------------
function W.CreateSlider(parent, label, minVal, maxVal, step, getter, setter, tooltip)
    local slider = CreateFrame("Slider", nil, parent, "OptionsSliderTemplate")
    slider:SetWidth(180)
    slider:SetMinMaxValues(minVal or 0, maxVal or 100)
    slider:SetValueStep(step or 1)
    slider:SetObeyStepOnDrag(true)

    -- The current value lives IN the label ("<label>:  <n>") at the top of the
    -- slider, not as a readout below the thumb — a below-thumb readout spills
    -- past the panel's bottom edge when the slider sits low in a panel.
    local baseLabel = label or ""
    if slider.Text then
        slider.Text:SetFontObject(theme.FONT_LABEL)
        theme.SetTextColor(slider.Text, "primary")
    end
    local function setLabel(v)
        if slider.Text then slider.Text:SetText(baseLabel .. ":  " .. tostring(v)) end
    end
    if slider.Low  then slider.Low:SetText(tostring(minVal or 0)); theme.SetTextColor(slider.Low, "secondary") end
    if slider.High then slider.High:SetText(tostring(maxVal or 100)); theme.SetTextColor(slider.High, "secondary") end

    slider:SetScript("OnShow", safe.WrapScript("Slider:OnShow:" .. (label or "?"), function(self)
        if getter then
            local v = getter() or minVal
            self:SetValue(v)
            setLabel(v)
        end
    end))
    -- Explicit initial sync (OnShow doesn't fire without state change)
    if getter then
        local ok, v = pcall(getter)
        if ok and v then
            slider:SetValue(v)
            setLabel(v)
        end
    end

    slider:SetScript("OnValueChanged", safe.WrapScript("Slider:OnValueChanged:" .. (label or "?"), function(self, v)
        -- Snap to step for visual consistency
        v = math.floor((v / step + 0.5)) * step
        setLabel(v)
        if setter then setter(v) end
    end))

    if tooltip then
        slider:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(label or "", 1, 1, 1)
            GameTooltip:AddLine(tooltip, nil, nil, nil, true)
            GameTooltip:Show()
        end)
        slider:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    return slider
end

---------------------------------------------------------------
-- CreateDropdown — Blizzard UIDropDownMenuTemplate with themed label.
--
-- choices = { {value="a", label="Option A"}, {value="b", label="Option B"} }
---------------------------------------------------------------
function W.CreateDropdown(parent, label, choices, getter, setter, tooltip)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(200, 50)

    if label then
        container.label = W.CreateLabel(container, label, theme.FONT_LABEL, "primary")
        container.label:SetPoint("TOPLEFT", container, "TOPLEFT", 6, 0)
    end

    local dd = CreateFrame("Frame", uniqueName("DilvlDropdown_"),
        container, "UIDropDownMenuTemplate")
    dd:SetPoint("TOPLEFT", container, "TOPLEFT", -10, -16)
    container.dropdown = dd

    UIDropDownMenu_SetWidth(dd, 160)

    UIDropDownMenu_Initialize(dd, function(self, level)
        local current = getter and getter() or nil
        for _, choice in ipairs(choices) do
            local info = UIDropDownMenu_CreateInfo()
            info.text  = choice.label
            info.value = choice.value
            info.checked = (current == choice.value)
            info.func = safe.WrapScript("Dropdown:Select:" .. (label or "?"), function()
                UIDropDownMenu_SetSelectedValue(dd, choice.value)
                UIDropDownMenu_SetText(dd, choice.label)
                if setter then setter(choice.value) end
            end)
            UIDropDownMenu_AddButton(info, level)
        end
    end)

    local function syncDropdown()
        local v = getter and getter() or nil
        if v then
            UIDropDownMenu_SetSelectedValue(dd, v)
            for _, choice in ipairs(choices) do
                if choice.value == v then
                    UIDropDownMenu_SetText(dd, choice.label)
                    break
                end
            end
        end
    end
    container:SetScript("OnShow", safe.WrapScript("Dropdown:OnShow:" .. (label or "?"), syncDropdown))
    -- Explicit initial sync (OnShow doesn't fire without state change)
    pcall(syncDropdown)

    if tooltip then
        dd:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(label or "", 1, 1, 1)
            GameTooltip:AddLine(tooltip, nil, nil, nil, true)
            GameTooltip:Show()
        end)
        dd:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    return container  -- caller anchors the CONTAINER, not the inner dropdown
end

---------------------------------------------------------------
-- CreateButton — Blizzard UIPanelButtonTemplate, themed label, safe-wrapped click.
---------------------------------------------------------------
function W.CreateButton(parent, label, width, height, onClick)
    local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btn:SetSize(width or 110, height or 22)
    btn:SetText(label or "")
    if onClick then
        btn:SetScript("OnClick", safe.WrapScript("Button:OnClick:" .. (label or "?"), onClick))
    end
    return btn
end

---------------------------------------------------------------
-- CreateRadioGroup — N radio buttons with shared db value.
--
-- choices = { {value="left", label="Left"}, {value="right", label="Right"} }
-- Returns container; arrange as horizontal row by default.
---------------------------------------------------------------
function W.CreateRadioGroup(parent, label, choices, getter, setter, orientation, tooltip)
    orientation = orientation or "horizontal"
    local container = CreateFrame("Frame", nil, parent)
    if label then
        container.label = W.CreateLabel(container, label, theme.FONT_LABEL, "primary")
        container.label:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)
        if tooltip then
            -- Need a mouse-receiving frame for tooltip; FontString itself doesn't get mouse.
            local hover = CreateFrame("Frame", nil, container)
            hover:SetAllPoints(container.label)
            hover:EnableMouse(true)
            hover:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(label, 1, 1, 1)
                GameTooltip:AddLine(tooltip, nil, nil, nil, true)
                GameTooltip:Show()
            end)
            hover:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end
    end

    container.radios = {}
    local prev = nil
    for i, choice in ipairs(choices) do
        local rb = CreateFrame("CheckButton", nil, container, "UIRadioButtonTemplate")
        if rb.text then
            rb.text:SetText(choice.label)
            theme.SetTextColor(rb.text, "primary")
        end
        if orientation == "horizontal" then
            if prev then
                rb:SetPoint("LEFT", prev, "RIGHT", 80, 0)
            else
                rb:SetPoint("TOPLEFT", container, "TOPLEFT", 0, label and -20 or 0)
            end
        else -- vertical
            if prev then
                rb:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -6)
            else
                rb:SetPoint("TOPLEFT", container, "TOPLEFT", 0, label and -20 or 0)
            end
        end
        rb.value = choice.value
        rb:SetScript("OnClick", safe.WrapScript("Radio:OnClick:" .. (label or "?") .. ":" .. tostring(choice.value), function(self)
            -- Uncheck siblings, check self
            for _, other in ipairs(container.radios) do
                other:SetChecked(other == self)
            end
            if setter then setter(self.value) end
        end))
        container.radios[i] = rb
        prev = rb
    end

    local function syncRadios()
        local v = getter and getter() or nil
        for _, rb in ipairs(container.radios) do
            rb:SetChecked(rb.value == v)
        end
    end
    container:SetScript("OnShow", safe.WrapScript("RadioGroup:OnShow:" .. (label or "?"), syncRadios))
    -- Explicit initial sync
    pcall(syncRadios)

    container:SetHeight(label and 44 or 24)
    return container
end

---------------------------------------------------------------
-- CreateInfoBar — banner with text, warm-tinted background. Use at top of
-- pages for context hints ("Auto-detected what you have installed. ...")
---------------------------------------------------------------
function W.CreateInfoBar(parent, text, height)
    local bar = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    bar:SetHeight(height or 30)
    theme.ApplyBackdrop(bar, "info")

    local icon = bar:CreateFontString(nil, "OVERLAY", theme.FONT_LABEL)
    icon:SetPoint("LEFT", bar, "LEFT", 10, 0)
    icon:SetText("ⓘ")
    theme.SetTextColor(icon, "accent")

    local fs = bar:CreateFontString(nil, "OVERLAY", theme.FONT_LABEL)
    fs:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    fs:SetPoint("RIGHT", bar, "RIGHT", -10, 0)
    fs:SetJustifyH("LEFT")
    fs:SetText(text or "")
    theme.SetTextColor(fs, "secondary")
    bar.text = fs

    return bar
end

---------------------------------------------------------------
-- CreateScrollFrame — minimal, themed scroll area.
--
-- Deliberately NOT UIPanelScrollFrameTemplate: that template ships chunky
-- Blizzard arrow buttons + a bright scrollbar that clash with the dark theme.
-- Instead: a bare ScrollFrame driven by the mouse wheel, plus a thin gold
-- position indicator on the right edge that auto-hides when everything fits.
-- The content width is kept in sync with the scroll frame so child panels
-- always fill the width (no manual gutter math at the call site).
--
-- Returns (scrollFrame, contentFrame) — anchor content into contentFrame;
-- its height drives the scroll range.
---------------------------------------------------------------
function W.CreateScrollFrame(parent, w, h)
    local sf = CreateFrame("ScrollFrame", nil, parent)
    sf:SetSize(w, h)
    local content = CreateFrame("Frame", nil, sf)
    content:SetSize(w, 1) -- height grows as children are added
    sf:SetScrollChild(content)

    -- Thin position indicator (wheel does the scrolling — this is just a hint).
    -- Lives on a high-level overlay frame so it always draws above the scroll
    -- child, and ignores the mouse so it never steals wheel/click from panels.
    local sb = CreateFrame("Frame", nil, sf)
    sb:SetAllPoints(sf)
    sb:SetFrameLevel(sf:GetFrameLevel() + 20)
    sb:EnableMouse(false)
    local thumb = sb:CreateTexture(nil, "OVERLAY")
    thumb:SetWidth(3)
    thumb:SetColorTexture(theme.BORDER_ACTIVE[1], theme.BORDER_ACTIVE[2], theme.BORDER_ACTIVE[3], 0.6)
    thumb:Hide()

    local function refresh()
        local range   = sf:GetVerticalScrollRange() or 0
        local visible = sf:GetHeight()
        if range <= 1 or visible <= 0 then thumb:Hide(); return end
        local thumbH = math.max(24, visible * visible / (visible + range))
        local frac   = (sf:GetVerticalScroll() or 0) / range
        thumb:ClearAllPoints()
        thumb:SetPoint("TOPRIGHT", sf, "TOPRIGHT", -1, -frac * (visible - thumbH))
        thumb:SetHeight(thumbH)
        thumb:Show()
    end
    sf.RefreshScrollbar = refresh

    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", function(self, delta)
        local range = self:GetVerticalScrollRange() or 0
        self:SetVerticalScroll(math.max(0, math.min(range, (self:GetVerticalScroll() or 0) - delta * 40)))
    end)
    sf:SetScript("OnVerticalScroll", refresh)
    sf:SetScript("OnScrollRangeChanged", refresh)
    sf:SetScript("OnSizeChanged", function(self, sw)
        if sw and sw > 0 then content:SetWidth(sw) end
        refresh()
    end)
    C_Timer.After(0, function()
        local sw = sf:GetWidth()
        if sw and sw > 0 then content:SetWidth(sw) end
        refresh()
    end)

    return sf, content
end
