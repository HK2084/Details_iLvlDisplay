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
-- Use for visual grouping of related settings, mirrors DandersFrames
-- "Frame Modes" / "Settings Panel Appearance" boxes from Hasan's screenshot.
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

    -- Re-skin template's Text/Low/High fontstrings to our theme.
    if slider.Text then
        slider.Text:SetText(label or "")
        slider.Text:SetFontObject(theme.FONT_LABEL)
        theme.SetTextColor(slider.Text, "primary")
    end
    if slider.Low  then slider.Low:SetText(tostring(minVal or 0)); theme.SetTextColor(slider.Low, "secondary") end
    if slider.High then slider.High:SetText(tostring(maxVal or 100)); theme.SetTextColor(slider.High, "secondary") end

    -- Current-value readout below the slider thumb.
    local valueFS = slider:CreateFontString(nil, "OVERLAY", theme.FONT_HELPER)
    valueFS:SetPoint("TOP", slider, "BOTTOM", 0, -2)
    theme.SetTextColor(valueFS, "accent")
    slider.valueFS = valueFS

    slider:SetScript("OnShow", safe.WrapScript("Slider:OnShow:" .. (label or "?"), function(self)
        if getter then
            local v = getter() or minVal
            self:SetValue(v)
            self.valueFS:SetText(tostring(v))
        end
    end))
    -- Explicit initial sync (OnShow doesn't fire without state change)
    if getter then
        local ok, v = pcall(getter)
        if ok and v then
            slider:SetValue(v)
            valueFS:SetText(tostring(v))
        end
    end

    slider:SetScript("OnValueChanged", safe.WrapScript("Slider:OnValueChanged:" .. (label or "?"), function(self, v)
        -- Snap to step for visual consistency
        v = math.floor((v / step + 0.5)) * step
        self.valueFS:SetText(tostring(v))
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
function W.CreateRadioGroup(parent, label, choices, getter, setter, orientation)
    orientation = orientation or "horizontal"
    local container = CreateFrame("Frame", nil, parent)
    if label then
        container.label = W.CreateLabel(container, label, theme.FONT_LABEL, "primary")
        container.label:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)
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
-- CreateScrollFrame — themed wrapper around UIPanelScrollFrameTemplate.
-- Returns (scrollFrame, contentFrame) — anchor your content into the
-- contentFrame; it grows independent of the visible scrollFrame height.
---------------------------------------------------------------
function W.CreateScrollFrame(parent, w, h)
    local sf = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    sf:SetSize(w, h)
    local content = CreateFrame("Frame", nil, sf)
    content:SetSize(w - 24, 1) -- -24 for scrollbar gutter; height grows as children added
    sf:SetScrollChild(content)
    return sf, content
end
