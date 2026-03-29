local addonName = ...

local defaults = {
    enabled = true,
    colorIlvl = true,
    showSetBonus = true,
}

local db
local ilvlCache -- points to db.ilvlCache after ADDON_LOADED (persistent SavedVariables)
local setBonusCache = {} -- guid -> "2P" / "4P" / nil
local nameToIlvl = {} -- "PlayerName" -> ilvl
local CACHE_EXPIRE = 7200 -- 2 hours; stale entries purged on new instance or after boss
local lastMapID = nil -- track zone changes to detect new instances
local inspectQueue = {}
local isInspecting = false
local pendingInspectGuid = nil -- GUID we requested via NotifyInspect (nil = we didn't trigger current inspect)
local detailsReady = false
local hookedFontStrings = {} -- track which FontStrings we already hooked
local barCleanText = {}    -- fontString -> last clean text set by Details! (never our injected text)
local isOurSetText = false -- prevent recursion in SetText hook
local mapDirty = false -- rebuild nameToIlvl only when new inspect data arrived
local tickerStarted = false -- guard against multiple tickers on repeated PLAYER_ENTERING_WORLD

---------------------------------------------------------------
-- Group info helper (handles normal party/raid + LFR/LFD)
-- Returns: prefix ("raid"/"party"), count, numGroup
---------------------------------------------------------------
local function GetGroupInfo()
    local isInstance = IsInRaid(LE_PARTY_CATEGORY_INSTANCE) or IsInGroup(LE_PARTY_CATEGORY_INSTANCE)
    local numGroup = isInstance
        and GetNumGroupMembers(LE_PARTY_CATEGORY_INSTANCE)
        or GetNumGroupMembers()
    local isRaid = isInstance and IsInRaid(LE_PARTY_CATEGORY_INSTANCE) or IsInRaid()
    local prefix = isRaid and "raid" or "party"
    local count = isRaid and numGroup or (numGroup - 1)
    return prefix, count, numGroup
end

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
-- Set bonus detection for an inspected unit
-- Reads item links from all equipment slots, counts pieces per setID.
-- Returns "4P", "2P", or nil.
-- Must be called synchronously during INSPECT_READY while data is loaded.
---------------------------------------------------------------
-- Only the 5 slots that can physically hold tier pieces.
-- Checking all 16 slots causes false positives because rings, trinkets,
-- weapons, cloaks etc. can also have non-zero setIDs in TWW (cosmetic sets,
-- crafted item families). Tier bonuses are exclusively Head/Shoulder/Chest/
-- Legs/Hands — restricting to these 5 slots eliminates false positives.
local TIER_SLOTS = {1, 3, 5, 7, 10} -- Head, Shoulder, Chest, Legs, Hands

local function GetSetBonusForUnit(unit)
    local setPieces = {} -- setID -> count

    for _, slotID in ipairs(TIER_SLOTS) do
        -- GetInventoryItemID returns itemID directly as a number — no link
        -- parsing needed, immune to item link format changes (|cnIQ4: etc).
        local itemID = GetInventoryItemID(unit, slotID)
        if itemID and itemID > 0 then
            -- C_Item.GetItemInfo returns 18 values; setID is at position 16.
            -- Synchronous if item is in client cache (it almost always is
            -- during INSPECT_READY). pcall guards the rare async-miss.
            local ok, _, _, _, _, _, _, _, _, _, _, _, _, _, _, setID = pcall(C_Item.GetItemInfo, itemID)
            if ok and setID and setID > 0 then
                setPieces[setID] = (setPieces[setID] or 0) + 1
            end
        end
    end

    local best = 0
    for _, count in pairs(setPieces) do
        if count > best then best = count end
    end

    if best >= 4 then return "4P"
    elseif best >= 2 then return "2P"
    end
    return nil
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
-- Build the iLvl tag string for a given player name
-- Returns e.g. " |cFF0070DD[252]|r |cFF00FF00[2P]|r" or nil
---------------------------------------------------------------
local function BuildTag(name)
    local ilvl = nameToIlvl[name]
    if not ilvl then return nil end

    local tag
    if db.colorIlvl then
        tag = " " .. GetIlvlColor(ilvl) .. "[" .. ilvl .. "]|r"
    else
        tag = " [" .. ilvl .. "]"
    end

    -- Append set bonus if we have it (look up guid via ilvlCache name)
    -- data.name may be "Player-Realm" (cross-realm) while name from the bar
    -- is just "Player" — so compare both full and short name.
    if db.showSetBonus then
        for guid, data in pairs(ilvlCache) do
            local storedShort = data.name and (data.name:match("^(.+)%-[^%-]+$") or data.name)
            if data.name == name or storedShort == name then
                local sb = setBonusCache[guid]
                if sb then
                    tag = tag .. " |cFF00FF00[" .. sb .. "]|r"
                end
                break
            end
        end
    end

    return tag
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

    -- When a new bar gets hooked, trigger a map dirty so the next tick
    -- attempts a refresh — barCleanText will populate on Details!'s next SetText.
    mapDirty = true

    hooksecurefunc(fontString, "SetText", function(self, text)
        if isOurSetText then return end
        if not db or not db.enabled then return end
        -- Skip during combat - text is secret/tainted AND we don't need it mid-fight
        if InCombatLockdown() then return end
        if not text or type(text) ~= "string" then return end
        if text:find("%[%d+%]") then return end

        -- Cache Details!'s clean text before we inject anything.
        -- GetText() later returns our injected (tainted) string, so we must
        -- never call GetText() — use barCleanText instead.
        barCleanText[self] = text

        local name = ExtractName(text)
        if name then
            local tag = BuildTag(name)
            if tag then
                isOurSetText = true
                self:SetText(text .. tag)
                isOurSetText = false
            end
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
        local ok = pcall(function()
            if fontString:IsShown() then
                -- Use our cached clean text — never GetText(), which returns our
                -- injected secret string and causes taint errors on string ops.
                local text = barCleanText[fontString]
                if text then
                    local name = ExtractName(text)
                    if name then
                        local tag = BuildTag(name)
                        if tag then
                            fontString:SetText(text .. tag)
                        end
                    end
                end
            end
        end)
        if not ok then
            -- Restore guard so subsequent iterations still block re-entry
            isOurSetText = true
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
    end

    -- Always run, cheap: early exits if bars already tagged or nameToIlvl empty
    RefreshAllBarTexts()
end

---------------------------------------------------------------
-- Inspect group
---------------------------------------------------------------
local function ProcessNextInspect()
    if InCombatLockdown() or #inspectQueue == 0 then
        isInspecting = false
        return
    end

    -- Don't fire our background inspect while the player has the inspect
    -- window open — NotifyInspect would override their manual inspection.
    if InspectFrame and InspectFrame:IsShown() then
        isInspecting = false
        C_Timer.After(2, ProcessNextInspect) -- retry after player closes it
        return
    end

    isInspecting = true
    local entry = table.remove(inspectQueue, 1)

    if UnitGUID(entry.unit) == entry.guid and CanInspect(entry.unit, false) then
        pendingInspectGuid = entry.guid -- track that WE triggered this inspect
        NotifyInspect(entry.unit)
    else
        -- Can't inspect right now (out of range, throttled, etc.).
        -- Re-queue up to 3 times so we retry after other players are done.
        entry.retries = (entry.retries or 0) + 1
        if entry.retries <= 3 then
            table.insert(inspectQueue, entry)
        end
        C_Timer.After(0.5, ProcessNextInspect)
    end
end

local function QueueGroupInspect()
    if InCombatLockdown() then return end

    wipe(inspectQueue)

    local prefix, count, numGroup = GetGroupInfo()
    if numGroup <= 1 then return end

    for i = 1, count do
        local unit = prefix .. i
        if UnitExists(unit) and UnitIsPlayer(unit) and not UnitIsUnit(unit, "player") then
            local guid = UnitGUID(unit)
            if guid then
                -- Pre-populate nameToIlvl from cache now while we have the unit.
                -- UnitName() is reliable here; at INSPECT_READY the unit token
                -- may already be stale if the player moved or reloaded.
                local cached = ilvlCache[guid]
                if cached and cached.ilvl then
                    local name, realm = UnitName(unit)
                    if name then
                        local fullName = (realm and realm ~= "") and (name .. "-" .. realm) or name
                        StoreNameIlvl(fullName, cached.ilvl)
                        StoreNameIlvl(name, cached.ilvl)
                    end
                end
                if not cached or (time() - cached.time >= CACHE_EXPIRE) then
                    -- Queue unconditionally, range check happens at inspect time
                    table.insert(inspectQueue, {guid = guid, unit = unit})
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
frame:RegisterEvent("ENCOUNTER_END")

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local loaded = ...
        if loaded == addonName then
            if not Details_iLvlDisplayDB then
                Details_iLvlDisplayDB = {}
            end
            db = Details_iLvlDisplayDB
            for k, v in pairs(defaults) do
                if db[k] == nil then db[k] = v end
            end

            -- Persistent cache stored separately (not in defaults to avoid confusion)
            if not db.ilvlCache then db.ilvlCache = {} end
            ilvlCache = db.ilvlCache

            -- Purge entries older than CACHE_EXPIRE on load
            local now = time()
            for guid, data in pairs(ilvlCache) do
                if (now - data.time) >= CACHE_EXPIRE then
                    ilvlCache[guid] = nil
                end
            end

            local _, equipped = GetAverageItemLevel()
            if equipped and equipped > 0 then
                local guid = UnitGUID("player")
                if guid then
                    ilvlCache[guid] = {ilvl = math.floor(equipped), time = now, name = UnitName("player")}
                end
            end
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Guard against multiple tickers: PLAYER_ENTERING_WORLD fires on every
        -- zone transition. Without this flag, rapid zoning within 3s creates
        -- multiple tickers and OnTick runs multiple times per interval.
        if not detailsReady and not tickerStarted then
            tickerStarted = true
            C_Timer.After(3, function()
                if Details then
                    detailsReady = true
                    RebuildNameIlvlMap()
                    HookAllBars()
                    C_Timer.NewTicker(2, OnTick)
                    print("|cFF00FF00Details! iLvl Display|r v1.6 loaded. /dilvl")
                    C_Timer.After(5, QueueGroupInspect)
                else
                    -- Details not loaded yet, allow retry on next zone
                    tickerStarted = false
                end
            end)
        end

        -- Detect new instance: if MapID changed, purge all non-group cache entries
        -- so stale data from previous raid doesn't linger forever.
        if ilvlCache then
            local currentMap = C_Map.GetBestMapForUnit("player")
            if currentMap and currentMap ~= lastMapID then
                if lastMapID then
                    local keepGuids = {}
                    local prefix, count = GetGroupInfo()
                    for i = 1, count do
                        local g = UnitGUID(prefix .. i)
                        if g then keepGuids[g] = true end
                    end
                    keepGuids[UnitGUID("player")] = true
                    for guid in pairs(ilvlCache) do
                        if not keepGuids[guid] then
                            ilvlCache[guid] = nil
                            setBonusCache[guid] = nil
                        end
                    end
                    wipe(nameToIlvl)
                    mapDirty = true
                end
                lastMapID = currentMap
            end
        end

        local _, equipped = GetAverageItemLevel()
        if equipped and equipped > 0 then
            local guid = UnitGUID("player")
            if guid then
                ilvlCache[guid] = {ilvl = math.floor(equipped), time = time(), name = UnitName("player")}
            end
        end

    elseif event == "INSPECT_READY" then
        local guid = ...
        local prefix, count = GetGroupInfo()

        for i = 1, count do
            local u = prefix .. i
            if UnitGUID(u) == guid then
                local ilvl = C_PaperDollInfo.GetInspectItemLevel(u)
                if ilvl and ilvl > 0 then
                    local name, realm = UnitName(u)
                    local ilvlFloor = math.floor(ilvl)
                    local fullName = name and (realm and realm ~= "") and (name .. "-" .. realm) or name
                    local setBonus = GetSetBonusForUnit(u)
                    setBonusCache[guid] = setBonus
                    ilvlCache[guid] = {ilvl = ilvlFloor, time = time(), name = fullName or name}
                    -- Populate nameToIlvl directly — don't rely on Details! combat
                    -- actors (player may not have dealt damage/healed yet).
                    if name then
                        StoreNameIlvl(name, ilvlFloor)
                        if fullName and fullName ~= name then
                            StoreNameIlvl(fullName, ilvlFloor)
                        end
                    end
                end
                break
            end
        end

        -- Only release inspect state and continue the queue if WE triggered
        -- this INSPECT_READY. If the player manually inspects someone (or
        -- inspects the same target we queued), we must not:
        --   a) call ClearInspectPlayer() — wipes their open panel
        --   b) call ProcessNextInspect  — fires NotifyInspect 1s later,
        --      overrides the inspect context, tooltips stop working
        -- Additional guard: never clear while InspectFrame is visible
        -- (race: our queue and manual inspect can target the same player).
        mapDirty = true
        if guid == pendingInspectGuid then
            pendingInspectGuid = nil
            if not (InspectFrame and InspectFrame:IsShown()) then
                ClearInspectPlayer()
            end
            C_Timer.After(1.0, ProcessNextInspect)
        end
        -- Manual inspect: data captured above, nothing else to do.

    elseif event == "PLAYER_REGEN_ENABLED" then
        if db and db.enabled then
            mapDirty = true
            C_Timer.After(2, QueueGroupInspect)
        end

    elseif event == "ENCOUNTER_END" then
        -- ENCOUNTER_END fires on both kills (success=1) AND wipes (success=0).
        -- Only re-inspect on kills — loot (and potential ilvl gains) only drop on kills.
        local _, _, _, _, success = ...
        if db and db.enabled and success == 1 then
            local prefix, count = GetGroupInfo()
            for i = 1, count do
                local guid = UnitGUID(prefix .. i)
                if guid and ilvlCache[guid] then
                    ilvlCache[guid].time = 0 -- force expire → QueueGroupInspect re-queues
                end
            end
            C_Timer.After(5, QueueGroupInspect)
        end

    elseif event == "GROUP_ROSTER_UPDATE" then
        if not InCombatLockdown() and db and db.enabled then
            -- Wipe nameToIlvl immediately — unit tokens reshuffle on roster
            -- changes so old name->iLvl mappings are unreliable until we
            -- re-inspect and re-populate from fresh unit tokens.
            wipe(nameToIlvl)
            mapDirty = true
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
    elseif msg == "setbonus" then
        db.showSetBonus = not db.showSetBonus
        print("|cFF00FF00Details! iLvl Display:|r Set Bonus " .. (db.showSetBonus and "ON" or "OFF"))
    elseif msg == "inspect" then
        print("|cFF00FF00Details! iLvl Display:|r Inspecting group...")
        QueueGroupInspect()
    elseif msg == "cache" then
        local count = 0
        for guid, data in pairs(ilvlCache) do
            local name = data.name or "Unknown"
            if guid == UnitGUID("player") then
                name = UnitName("player") or name
            end
            if name == "Unknown" and Details and Details.item_level_pool and Details.item_level_pool[guid] then
                name = Details.item_level_pool[guid].name or name
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
        local cacheCount, mapCount, hookCount, setBonusCount = 0, 0, 0, 0
        for _ in pairs(ilvlCache) do cacheCount = cacheCount + 1 end
        for _ in pairs(nameToIlvl) do mapCount = mapCount + 1 end
        for _ in pairs(hookedFontStrings) do hookCount = hookCount + 1 end
        for _ in pairs(setBonusCache) do setBonusCount = setBonusCount + 1 end
        print("|cFF00FF00Details! iLvl Display:|r Debug v1.6:")
        print("  Ticker: " .. tostring(detailsReady))
        print("  Hooked bars: " .. hookCount)
        print("  nameToIlvl entries: " .. mapCount)
        print("  Cached GUIDs: " .. cacheCount)
        print("  Set bonus cached: " .. setBonusCount)
        print("  Inspect queue: " .. #inspectQueue)
    else
        print("|cFF00FF00Details! iLvl Display|r v1.6 - /dilvl [on|off|color|setbonus|inspect|cache|map|debug]")
    end
end
