local addonName = ...

local defaults = {
    enabled = true,
    colorIlvl = true,
}

local db
local ilvlCache = {} -- guid -> {ilvl = number, time = number}
local nameToIlvl = {} -- "PlayerName" -> ilvl
local CACHE_EXPIRE = 600
local inspectQueue = {}
local isInspecting = false
local detailsReady = false
local hookedFontStrings = {} -- track which FontStrings we already hooked
local isOurSetText = false -- prevent recursion in SetText hook
local mapDirty = false -- rebuild nameToIlvl only when new inspect data arrived

---------------------------------------------------------------
-- iLvl color by gear tier
---------------------------------------------------------------
local function GetIlvlColor(ilvl)
    if ilvl >= 280 then return "|cFFFF8000"
    elseif ilvl >= 268 then return "|cFFA335EE"
    elseif ilvl >= 255 then return "|cFF0070DD"
    elseif ilvl >= 242 then return "|cFF1EFF00"
    else return "|cFF9D9D9D"
    end
end

---------------------------------------------------------------
-- iLvl lookup by GUID
---------------------------------------------------------------
local function GetIlvlForGuid(guid)
    if not guid then return nil end

    local cached = ilvlCache[guid]
    if cached and (time() - cached.time < CACHE_EXPIRE) then
        return cached.ilvl
    end

    if Details and Details.item_level_pool then
        local data = Details.item_level_pool[guid]
        if data and data.ilvl and data.ilvl > 0 then
            local ilvl = math.floor(data.ilvl)
            ilvlCache[guid] = {ilvl = ilvl, time = time()}
            return ilvl
        end
    end

    if Details and Details.ilevel and Details.ilevel.GetIlvl then
        local ok, data = pcall(Details.ilevel.GetIlvl, Details.ilevel, guid)
        if ok and data and data.ilvl and data.ilvl > 0 then
            local ilvl = math.floor(data.ilvl)
            ilvlCache[guid] = {ilvl = ilvl, time = time()}
            return ilvl
        end
    end

    if guid == UnitGUID("player") then
        local _, equipped = GetAverageItemLevel()
        if equipped and equipped > 0 then
            local ilvl = math.floor(equipped)
            ilvlCache[guid] = {ilvl = ilvl, time = time()}
            return ilvl
        end
    end

    return nil
end

---------------------------------------------------------------
-- Build name->ilvl map from combat actors
---------------------------------------------------------------
local function StoreNameIlvl(name, ilvl)
    if not name or not ilvl then return end
    nameToIlvl[name] = ilvl
    -- Also store without realm suffix for cross-realm players ("Name-Server" -> "Name")
    local shortName = name:match("^([^%-]+%-[^%-]+)$") and name:match("^(.+)%-[^%-]+$")
    if shortName and shortName ~= name then
        nameToIlvl[shortName] = ilvl
    end
end

local function RebuildNameIlvlMap()
    wipe(nameToIlvl)
    if not Details then return end

    local ok, combat = pcall(Details.GetCurrentCombat, Details)
    if not ok or not combat then return end

    -- Scan damage + heal actors
    for _, attrId in ipairs({DETAILS_ATTRIBUTE_DAMAGE, DETAILS_ATTRIBUTE_HEAL}) do
        local ok2, container = pcall(combat.GetContainer, combat, attrId)
        if ok2 and container then
            for _, actor in container:ListActors() do
                if actor:IsPlayer() and actor.serial then
                    local ilvl = GetIlvlForGuid(actor.serial)
                    if ilvl then
                        StoreNameIlvl(actor.displayName, ilvl)
                        StoreNameIlvl(actor.nome, ilvl)
                    end
                end
            end
        end
    end
end

---------------------------------------------------------------
-- Extract player name from text like "1. Quinroth"
---------------------------------------------------------------
local function ExtractName(text)
    if not text or type(text) ~= "string" then return nil end
    -- Strip rank prefix "1. " etc
    local name = text:match("^%d+%.%s*(.+)") or text
    -- Strip any existing ilvl tag
    name = name:gsub("%s*|c%x+%[%d+%]|r", "")
    name = name:gsub("%s*%[%d+%]", "")
    -- Strip inline textures (role icons etc)
    name = name:gsub("|T.-|t%s*", "")
    -- Trim
    name = name:match("^%s*(.-)%s*$")
    return name
end

---------------------------------------------------------------
-- Hook a bar's lineText1 SetText to inject iLvl
-- This avoids reading GetText() which returns secret strings
---------------------------------------------------------------
local function HookBarTextIfNeeded(bar)
    if not bar or not bar.lineText1 then return end

    local fontString = bar.lineText1
    if hookedFontStrings[fontString] then return end
    hookedFontStrings[fontString] = true

    hooksecurefunc(fontString, "SetText", function(self, text)
        if isOurSetText then return end
        if not db or not db.enabled then return end
        -- Skip during combat - text is secret/tainted AND we don't need it mid-fight
        if InCombatLockdown() then return end
        if not text or type(text) ~= "string" then return end
        if text:find("%[%d+%]") then return end

        local name = ExtractName(text)
        if name and nameToIlvl[name] then
            local ilvl = nameToIlvl[name]
            local tag
            if db.colorIlvl then
                tag = " " .. GetIlvlColor(ilvl) .. "[" .. ilvl .. "]|r"
            else
                tag = " [" .. ilvl .. "]"
            end
            isOurSetText = true
            self:SetText(text .. tag)
            isOurSetText = false
        end
    end)
end

---------------------------------------------------------------
-- Scan and hook all Details! bars
---------------------------------------------------------------
local function HookAllBars()
    if not Details then return end

    for instanceId = 1, 10 do
        local ok, instance = pcall(Details.GetInstance, Details, instanceId)
        if not ok or not instance then break end

        local bars = instance.barras
        if not bars then break end

        for i = 1, #bars do
            HookBarTextIfNeeded(bars[i])
        end
    end
end

---------------------------------------------------------------
-- Force-update bar texts that are already visible but missing iLvl
-- Needed when inspect data arrives after Details already drew the bars
---------------------------------------------------------------
local function RefreshAllBarTexts()
    if InCombatLockdown() then return end
    if not next(nameToIlvl) then return end

    isOurSetText = true
    for fontString in pairs(hookedFontStrings) do
        if fontString:IsShown() then
            local text = fontString:GetText()
            if text and not text:find("%[%d+%]") then
                local name = ExtractName(text)
                if name then
                    local ilvl = nameToIlvl[name]
                    if not ilvl then
                        -- Fallback: try without realm suffix
                        local shortName = name:match("^(.+)%-[^%-]+$")
                        ilvl = shortName and nameToIlvl[shortName]
                    end
                    if ilvl then
                        local tag = db.colorIlvl and (" " .. GetIlvlColor(ilvl) .. "[" .. ilvl .. "]|r") or (" [" .. ilvl .. "]")
                        fontString:SetText(text .. tag)
                    end
                end
            end
        end
    end
    isOurSetText = false
end

---------------------------------------------------------------
-- Periodic update: hook new bars + rebuild map only if dirty
---------------------------------------------------------------
local function OnTick()
    if not db or not db.enabled then return end
    if not Details then return end

    HookAllBars()

    if mapDirty then
        mapDirty = false
        RebuildNameIlvlMap()
        RefreshAllBarTexts()
    end
end

---------------------------------------------------------------
-- Inspect group
---------------------------------------------------------------
local function ProcessNextInspect()
    if InCombatLockdown() or #inspectQueue == 0 then
        isInspecting = false
        return
    end

    isInspecting = true
    local entry = table.remove(inspectQueue, 1)

    if UnitGUID(entry.unit) == entry.guid and CanInspect(entry.unit, true) then
        NotifyInspect(entry.unit)
    else
        C_Timer.After(0.2, ProcessNextInspect)
    end
end

local function QueueGroupInspect()
    if InCombatLockdown() then return end

    wipe(inspectQueue)
    local numGroup = GetNumGroupMembers()
    if numGroup <= 1 then return end

    local prefix = IsInRaid() and "raid" or "party"
    local count = IsInRaid() and numGroup or (numGroup - 1)

    for i = 1, count do
        local unit = prefix .. i
        if UnitExists(unit) and UnitIsPlayer(unit) and not UnitIsUnit(unit, "player") then
            local guid = UnitGUID(unit)
            if guid then
                local cached = ilvlCache[guid]
                if not cached or (time() - cached.time >= CACHE_EXPIRE) then
                    if CanInspect(unit, true) then
                        table.insert(inspectQueue, {guid = guid, unit = unit})
                    end
                end
            end
        end
    end

    if #inspectQueue > 0 and not isInspecting then
        C_Timer.After(0.5, ProcessNextInspect)
    end
end

---------------------------------------------------------------
-- Events
---------------------------------------------------------------
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("INSPECT_READY")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local loaded = ...
        if loaded == addonName then
            if not Details_iLvlDisplayDB then
                Details_iLvlDisplayDB = {}
            end
            db = Details_iLvlDisplayDB
            for k, v in pairs(defaults) do
                if db[k] == nil then
                    db[k] = v
                end
            end

            local _, equipped = GetAverageItemLevel()
            if equipped and equipped > 0 then
                local guid = UnitGUID("player")
                if guid then
                    ilvlCache[guid] = {ilvl = math.floor(equipped), time = time()}
                end
            end
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        if not detailsReady then
            C_Timer.After(3, function()
                if Details then
                    detailsReady = true
                    RebuildNameIlvlMap()
                    HookAllBars()
                    -- Tick only hooks new bars + rebuilds map when dirty (cheap)
                    C_Timer.NewTicker(2, OnTick)
                    print("|cFF00FF00Details! iLvl Display|r v1.4 loaded. /dilvl")
                    -- Queue inspects early so data is ready before first pull
                    C_Timer.After(5, QueueGroupInspect)
                end
            end)
        end

        local _, equipped = GetAverageItemLevel()
        if equipped and equipped > 0 then
            local guid = UnitGUID("player")
            if guid then
                ilvlCache[guid] = {ilvl = math.floor(equipped), time = time()}
            end
        end

    elseif event == "INSPECT_READY" then
        local guid = ...
        local numGroup = GetNumGroupMembers()
        local prefix = IsInRaid() and "raid" or "party"
        local count = IsInRaid() and numGroup or (numGroup - 1)

        for i = 1, count do
            local u = prefix .. i
            if UnitGUID(u) == guid then
                local ilvl = C_PaperDollInfo.GetInspectItemLevel(u)
                if ilvl and ilvl > 0 then
                    ilvlCache[guid] = {ilvl = math.floor(ilvl), time = time()}
                end
                break
            end
        end

        -- Mark dirty so next OnTick rebuilds the map and refreshes bars
        mapDirty = true
        C_Timer.After(0.3, ProcessNextInspect)

    elseif event == "PLAYER_REGEN_ENABLED" then
        if db and db.enabled then
            mapDirty = true -- rebuild nameToIlvl from cached data after every fight
            C_Timer.After(2, QueueGroupInspect)
        end

    elseif event == "GROUP_ROSTER_UPDATE" then
        if not InCombatLockdown() and db and db.enabled then
            C_Timer.After(3, QueueGroupInspect)
        end
    end
end)

---------------------------------------------------------------
-- Slash command
---------------------------------------------------------------
SLASH_DILVL1 = "/dilvl"
SlashCmdList["DILVL"] = function(msg)
    msg = msg:lower():trim()

    if msg == "on" then
        db.enabled = true
        print("|cFF00FF00Details! iLvl Display:|r Enabled")
    elseif msg == "off" then
        db.enabled = false
        print("|cFF00FF00Details! iLvl Display:|r Disabled")
    elseif msg == "color" then
        db.colorIlvl = not db.colorIlvl
        print("|cFF00FF00Details! iLvl Display:|r Color " .. (db.colorIlvl and "ON" or "OFF"))
    elseif msg == "inspect" then
        print("|cFF00FF00Details! iLvl Display:|r Inspecting group...")
        QueueGroupInspect()
    elseif msg == "cache" then
        local count = 0
        for guid, data in pairs(ilvlCache) do
            local name = "Unknown"
            if Details and Details.item_level_pool and Details.item_level_pool[guid] then
                name = Details.item_level_pool[guid].name or name
            end
            if guid == UnitGUID("player") then
                name = UnitName("player") or name
            end
            print(string.format("  %s: |cFFFFD900%d|r iLvl (cached %ds ago)", name, data.ilvl, time() - data.time))
            count = count + 1
        end
        print(string.format("|cFF00FF00Details! iLvl Display:|r %d cached", count))
    elseif msg == "map" then
        print("|cFF00FF00Details! iLvl Display:|r Name->iLvl map:")
        for name, ilvl in pairs(nameToIlvl) do
            print(string.format("  %s: |cFFFFD900%d|r", name, ilvl))
        end
    elseif msg == "debug" then
        print("|cFF00FF00Details! iLvl Display:|r Debug v1.3:")
        print("  Ticker: " .. tostring(detailsReady))
        print("  Hooked FontStrings: " .. tostring(next(hookedFontStrings) and "yes" or "none"))
        print("  nameToIlvl: " .. tostring(next(nameToIlvl) and "yes" or "empty"))
        local hookCount = 0
        for _ in pairs(hookedFontStrings) do hookCount = hookCount + 1 end
        print("  Total hooks: " .. hookCount)
    else
        print("|cFF00FF00Details! iLvl Display|r v1.3 - /dilvl [on|off|color|inspect|cache|map|debug]")
    end
end
