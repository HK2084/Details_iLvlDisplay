local addonName = ...

local defaults = {
    enabled = true,
    colorIlvl = true,
    showSetBonus = true,
    showInDetails = true,  -- show iLvl on Details! bars (requires Details!)
    elvuiTag = false,      -- show iLvl in ElvUI party frames (opt-in, requires ElvUI)
}

local db
local ilvlCache -- points to db.ilvlCache after ADDON_LOADED (persistent SavedVariables)
local setBonusCache = {} -- guid -> "2P" / "4P" / false (no bonus) / nil (never inspected); persisted after ADDON_LOADED
local nameToIlvl = {}    -- "PlayerName" -> ilvl
local nameToSetBonus = {} -- "PlayerName" -> "2P" / "4P" / nil (mirrors nameToIlvl, O(1) BuildTag lookup)
local CACHE_EXPIRE = 7200 -- 2 hours; stale entries purged on new instance or after boss
local lastMapID = nil -- track zone changes to detect new instances
local inspectQueue = {}
local isInspecting = false
local pendingInspectGuid = nil -- GUID we requested via NotifyInspect (nil = we didn't trigger current inspect)
local lastManualInspectTime = 0 -- GetTime() of last INSPECT_READY we didn't trigger (ElvUI-safe guard)
local detailsReady = false
local hookedFontStrings = {} -- track which FontStrings we already hooked
local hookedInstances = {}   -- track which Details! instance frames have OnSizeChanged hooked
local HookInstanceResize     -- forward declaration (assigned after OnDetailsResize is defined)
local barCleanText = {}    -- fontString -> last clean text set by Details! (never our injected text)
local isOurSetText = false -- prevent recursion in SetText hook
local mapDirty = false -- rebuild nameToIlvl only when new inspect data arrived
local tickerStarted = false -- guard against multiple tickers on repeated PLAYER_ENTERING_WORLD
local NotifyElvUI -- forward declaration; assigned after Details_iLvlDisplayAPI is built
local openRaidLib = nil -- LibOpenRaid-1.0 handle; assigned after ADDON_LOADED if available

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
-- weapons, cloaks etc. can also have non-zero setIDs in Midnight (cosmetic
-- sets, crafted item families). Tier bonuses are exclusively Head/Shoulder/
-- Chest/Legs/Hands — restricting to these 5 slots eliminates false positives.
local TIER_SLOTS = {1, 3, 5, 7, 10} -- Head, Shoulder, Chest, Legs, Hands

-- Midnight Season 1 tier setIDs per class (confirmed in-game via item tooltip).
-- GetSetBonusText() was removed in 12.0 — hardcoded whitelist replaces it.
-- Update this table when a new raid tier is added.
-- PvP gear (honor/conquest) has its own setIDs outside this range — whitelist
-- approach means they are automatically ignored regardless of their setID values.
local MIDNIGHT_TIER_SETS = {
    [1978] = true, -- Death Knight   (Relentless Rider's Lament)
    [1979] = true, -- Demon Hunter   (Devouring Reaver's Sheathe)
    [1980] = true, -- Druid          (Sprouts of the Luminous Bloom)
    [1981] = true, -- Evoker         (Livery of the Black Talon)
    [1982] = true, -- Hunter         (Primal Sentry's Camouflage)
    [1983] = true, -- Mage           (Voidbreaker's Accordance)
    [1984] = true, -- Monk           (Way of Ra-den's Chosen)
    [1985] = true, -- Paladin        (Luminant Verdict's Vestments)
    [1986] = true, -- Priest         (Blind Oath's Burden)
    [1987] = true, -- Rogue          (Motley of the Grim Jest)
    [1988] = true, -- Shaman         (Mantle of the Primal Core) ← confirmed
    [1989] = true, -- Warlock        (Reign of the Abyssal Immolator)
    [1990] = true, -- Warrior        (Rage of the Night Ender)
}

local function GetSetBonusForUnit(unit)
    local setPieces = {} -- setID -> count

    for _, slotID in ipairs(TIER_SLOTS) do
        -- GetInventoryItemID returns itemID directly as a number — no link
        -- parsing needed, immune to item link format changes.
        local itemID = GetInventoryItemID(unit, slotID)
        if itemID and itemID > 0 then
            -- C_Item.GetItemInfo returns 18 values; setID is at position 16.
            local ok, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, setID = pcall(C_Item.GetItemInfo, itemID)
            if ok and setID and MIDNIGHT_TIER_SETS[setID] then
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

    -- Details public API (preferred over internal item_level_pool)
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

-- Mirror of StoreNameIlvl for set bonus. sb may be nil (clears entry).
local function StoreNameBonus(name, sb)
    if not name then return end
    nameToSetBonus[name] = sb
    local shortName = name:match("^([^%-]+%-[^%-]+)$") and name:match("^(.+)%-[^%-]+$")
    if shortName and shortName ~= name then
        nameToSetBonus[shortName] = sb
    end
end

local function RebuildNameIlvlMap()
    wipe(nameToIlvl)
    wipe(nameToSetBonus)
    if not Details then return end

    -- Populate from ilvlCache.
    -- Primary: use live unit tokens (reliable names + realms).
    -- Fallback: iterate cache directly for players no longer in group
    -- (e.g. left after dungeon, or solo viewing old segment) — name
    -- field was stored at inspect time so it's still valid.
    if ilvlCache then
        local seenGuids = {}

        -- Live unit tokens first (most reliable)
        local prefix, count = GetGroupInfo()
        for i = 1, count do
            local unit = prefix .. i
            if UnitExists(unit) and UnitIsPlayer(unit) then
                local guid = UnitGUID(unit)
                local cached = guid and ilvlCache[guid]
                if cached and cached.ilvl then
                    seenGuids[guid] = true
                    local name, realm = UnitName(unit)
                    if name then
                        local fullName = (realm and realm ~= "") and (name .. "-" .. realm) or name
                        StoreNameIlvl(name, cached.ilvl)
                        StoreNameBonus(name, setBonusCache[guid])
                        if fullName ~= name then
                            StoreNameIlvl(fullName, cached.ilvl)
                            StoreNameBonus(fullName, setBonusCache[guid])
                        end
                    end
                end
            end
        end

        -- Fallback: cache entries whose unit token is gone (left group, solo, etc.)
        for guid, cached in pairs(ilvlCache) do
            if not seenGuids[guid] and cached.ilvl and cached.name then
                StoreNameIlvl(cached.name, cached.ilvl)
                StoreNameBonus(cached.name, setBonusCache[guid])
            end
        end

        -- Own player
        local pguid = UnitGUID("player")
        local pcached = pguid and ilvlCache[pguid]
        if pcached and pcached.ilvl then
            local pname = UnitName("player")
            StoreNameIlvl(pname, pcached.ilvl)
            StoreNameBonus(pname, setBonusCache[pguid])
        end
    end

    -- Also scan Details! combat actors (picks up players no longer in group)
    local ok, combat = pcall(Details.GetCurrentCombat, Details)
    if not ok or not combat then return end

    for _, attrId in ipairs({DETAILS_ATTRIBUTE_DAMAGE, DETAILS_ATTRIBUTE_HEAL}) do
        local ok2, container = pcall(combat.GetContainer, combat, attrId)
        if ok2 and container then
            for _, actor in container:ListActors() do
                if actor:IsPlayer() and actor.serial then
                    local ilvl = GetIlvlForGuid(actor.serial)
                    if ilvl then
                        -- Patch name into cache entry if Details! API wrote it without one
                        local entry = ilvlCache[actor.serial]
                        if entry and not entry.name then
                            entry.name = actor.displayName or actor.nome
                        end
                        StoreNameIlvl(actor.displayName, ilvl)
                        StoreNameIlvl(actor.nome, ilvl)
                        StoreNameBonus(actor.displayName, setBonusCache[actor.serial])
                        StoreNameBonus(actor.nome, setBonusCache[actor.serial])
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

    -- O(1) set bonus lookup — nameToSetBonus is kept in sync with nameToIlvl.
    -- Previously this iterated the full ilvlCache (O(N) per bar, O(N²) in 40-man raids).
    if db.showSetBonus then
        local sb = nameToSetBonus[name]
        if sb then
            tag = tag .. " |cFF00FF00[" .. sb .. "]|r"
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

    -- Seed barCleanText immediately with the current text — safe because we
    -- haven't injected into this FontString yet, so GetText() is clean.
    -- Without this, RefreshAllBarTexts has nothing to work with until Details!
    -- calls SetText again (e.g. never, if the window was just resized).
    local currentText = fontString:GetText()
    if currentText and type(currentText) == "string" and not currentText:find("%[%d+%]") then
        barCleanText[fontString] = currentText
    end
    mapDirty = true

    hooksecurefunc(fontString, "SetText", function(self, text)
        if isOurSetText then return end
        if not db or not db.enabled then return end
        -- Details! Itemlevelfinder passes "secret string" values to SetText.
        -- type() returns "string" for them but :match()/:find() error on line 325.
        -- Wrap everything in pcall to silently skip secret values.
        pcall(function()
            if not text or type(text) ~= "string" or text:match("^%s*$") then return end
            if text:find("%[%d+%]") then return end

            -- Cache Details!'s clean text before we inject anything.
            -- GetText() later returns our injected (tainted) string, so we must
            -- never call GetText() — use barCleanText instead.
            -- IMPORTANT: update even during combat so post-combat RefreshAllBarTexts
            -- sees the CURRENT player names, not pre-fight stale data.
            barCleanText[self] = text

            if not db.showInDetails then return end

            -- Don't inject during combat (taint with secure UI elements)
            if InCombatLockdown() then return end

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
        -- Safety: reset guard in case pcall swallowed an error mid-injection
        isOurSetText = false
    end)

    -- 12.0.1 added FontString:ClearText() — hook it so barCleanText doesn't
    -- keep a stale player name after Details! empties a bar for reuse.
    if fontString.ClearText then
        hooksecurefunc(fontString, "ClearText", function(self)
            barCleanText[self] = nil
        end)
    end
end

---------------------------------------------------------------
-- Scan and hook all Details! bars
---------------------------------------------------------------
local function HookAllBars()
    if not Details then return end

    for instanceId = 1, 10 do
        local ok, instance = pcall(Details.GetInstance, Details, instanceId)
        if not ok or not instance then break end

        HookInstanceResize(instance) -- hook resize event on the Details! window

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
    if not db or not db.showInDetails then return end
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
-- React to Details! window resize: re-hook bars + refresh immediately.
-- Debounced so drag-resize doesn't spam rebuilds while dragging.
-- This is the "permanent hook" for resize: fires whenever Details! resizes
-- its window, regardless of whether it calls SetText again.
---------------------------------------------------------------
local resizeDebounce = nil
local function OnDetailsResize()
    if resizeDebounce then
        resizeDebounce:Cancel()
    end
    resizeDebounce = C_Timer.NewTimer(0.3, function()
        resizeDebounce = nil
        if not db or not db.enabled then return end
        mapDirty = true
        HookAllBars()         -- pick up any new bar FontStrings created on resize
        RebuildNameIlvlMap()  -- re-populate name->ilvl from cache (cache is intact)
        RefreshAllBarTexts()  -- inject tags immediately, don't wait for next ticker
    end)
end

-- Details! instance frames expose their main window as baseFrame (preferred) or frame.
-- We hook OnSizeChanged once per instance so resize triggers an immediate refresh.
HookInstanceResize = function(instance)
    local frame = instance.baseFrame or instance.frame
    if not frame or hookedInstances[frame] then return end
    hookedInstances[frame] = true
    pcall(frame.HookScript, frame, "OnSizeChanged", OnDetailsResize)
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

    -- Don't fire our background inspect while the player is manually inspecting.
    -- InspectFrame:IsShown() is unreliable with ElvUI (replaces the Blizzard frame).
    -- Instead: if we received an INSPECT_READY we didn't trigger within the last 30s,
    -- assume the player is still using the inspect window and wait.
    if (GetTime() - lastManualInspectTime) < 60 then
        isInspecting = false
        C_Timer.After(5, ProcessNextInspect)
        return
    end

    isInspecting = true
    local entry = table.remove(inspectQueue, 1)

    if UnitGUID(entry.unit) == entry.guid and CanInspect(entry.unit, false) then
        pendingInspectGuid = entry.guid -- track that WE triggered this inspect
        NotifyInspect(entry.unit)
        -- Safety timeout: if INSPECT_READY never fires (server throttle, player
        -- LoS'd mid-inspect, disconnect), unblock the queue after 15s.
        C_Timer.After(15, function()
            if isInspecting and pendingInspectGuid == entry.guid then
                isInspecting = false
                pendingInspectGuid = nil
                C_Timer.After(0.5, ProcessNextInspect)
            end
        end)
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

    -- Reset inspect state: if a previous NotifyInspect was throttled and
    -- INSPECT_READY never fired, isInspecting stays true and the queue
    -- would never start. Always reset here since we're rebuilding from scratch.
    isInspecting = false
    pendingInspectGuid = nil
    wipe(inspectQueue)

    local prefix, count, numGroup = GetGroupInfo()
    if numGroup <= 1 then return end

    for i = 1, count do
        local unit = prefix .. i
        if UnitExists(unit) and UnitIsPlayer(unit) and not UnitIsUnit(unit, "player") then
            local guid = UnitGUID(unit)
            if guid then
                -- Pre-populate nameToIlvl/nameToSetBonus from cache now while we have the unit.
                -- UnitName() is reliable here; at INSPECT_READY the unit token
                -- may already be stale if the player moved or reloaded.
                local cached = ilvlCache[guid]
                if cached and cached.ilvl then
                    local name, realm = UnitName(unit)
                    if name then
                        local fullName = (realm and realm ~= "") and (name .. "-" .. realm) or name
                        StoreNameIlvl(fullName, cached.ilvl)
                        StoreNameIlvl(name, cached.ilvl)
                        StoreNameBonus(fullName, setBonusCache[guid])
                        StoreNameBonus(name, setBonusCache[guid])
                    end
                end
                -- Queue only if iLvl is stale; setBonusCache is now persisted so
                -- no need to re-inspect just because it's absent after a reload.
                if not cached or (time() - cached.time >= CACHE_EXPIRE) then
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
-- Cache own iLvl + set bonus (no inspect needed for "player")
---------------------------------------------------------------
local function UpdatePlayerCache()
    if not ilvlCache then return end
    local _, equipped = GetAverageItemLevel()
    if not equipped or equipped <= 0 then return end
    local guid = UnitGUID("player")
    if not guid then return end
    local pname = UnitName("player")
    local sb = GetSetBonusForUnit("player")
    ilvlCache[guid] = {ilvl = math.floor(equipped), time = time(), name = pname}
    setBonusCache[guid] = sb or false
    if pname then StoreNameBonus(pname, sb) end
    NotifyElvUI()
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("INSPECT_READY")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
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

            -- Persistent caches stored separately (not in defaults to avoid confusion)
            if not db.ilvlCache then db.ilvlCache = {} end
            ilvlCache = db.ilvlCache
            if not db.setBonusCache then db.setBonusCache = {} end
            setBonusCache = db.setBonusCache

            -- Purge entries older than CACHE_EXPIRE on load; keep setBonusCache in sync
            local now = time()
            for guid, data in pairs(ilvlCache) do
                if (now - data.time) >= CACHE_EXPIRE then
                    ilvlCache[guid] = nil
                    setBonusCache[guid] = nil
                end
            end

            UpdatePlayerCache()

            -- LibOpenRaid-1.0: optional data source, bundled with Details!
            -- Provides iLvl via addon-comm (no inspect needed when both players have Details!).
            -- We use it as a first source; our own inspect queue is the fallback.
            if LibStub then
                local ok, lib = pcall(LibStub, "LibOpenRaid-1.0")
                if ok and lib then
                    openRaidLib = lib
                    -- GearUpdate fires with (unitName) after Details! broadcasts gear info.
                    -- unitName is the full "Name-Realm" string.
                    lib.RegisterCallback({}, "GearUpdate", function(_, unitName)
                        if not unitName or not ilvlCache then return end
                        local gearInfo = lib.GetUnitGear(unitName)
                        if not gearInfo or not gearInfo.ilevel or gearInfo.ilevel <= 0 then return end
                        -- Resolve GUID from live group tokens for cache keying
                        local prefix, count = GetGroupInfo()
                        for i = 1, count do
                            local unit = prefix .. i
                            if UnitExists(unit) then
                                local fullName = GetUnitName(unit, true)
                                if fullName == unitName then
                                    local guid = UnitGUID(unit)
                                    if guid then
                                        local ilvl = math.floor(gearInfo.ilevel)
                                        -- Only update if newer than what we have
                                        local existing = ilvlCache[guid]
                                        if not existing or ilvl ~= existing.ilvl or (time() - existing.time) > 300 then
                                            local name, realm = UnitName(unit)
                                            local storedName = (realm and realm ~= "") and (name.."-"..realm) or name
                                            ilvlCache[guid] = {ilvl = ilvl, time = time(), name = storedName}
                                            StoreNameIlvl(storedName, ilvl)
                                            StoreNameIlvl(name, ilvl)
                                            mapDirty = true
                                            NotifyElvUI()
                                        end
                                    end
                                    break
                                end
                            end
                        end
                    end)
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
                    print("|cFF00FF00Details! iLvl Display|r v1.0.2.1 loaded. /dilvl")
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
                    wipe(nameToSetBonus)
                    mapDirty = true
                end
                lastMapID = currentMap
            end
        end

        UpdatePlayerCache()

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
                    -- Store false (not nil) for "inspected, no bonus" so persistence
                    -- can distinguish from "never inspected" (nil = not in table).
                    setBonusCache[guid] = setBonus or false
                    -- Fallback to existing cached name if UnitName() returned nil
                    -- (unit token can go stale between queue and INSPECT_READY)
                    local cachedName = ilvlCache[guid] and ilvlCache[guid].name
                    ilvlCache[guid] = {ilvl = ilvlFloor, time = time(), name = fullName or name or cachedName}
                    -- Populate nameToIlvl directly — don't rely on Details! combat
                    -- actors (player may not have dealt damage/healed yet).
                    if name then
                        StoreNameIlvl(name, ilvlFloor)
                        StoreNameBonus(name, setBonus)
                        if fullName and fullName ~= name then
                            StoreNameIlvl(fullName, ilvlFloor)
                            StoreNameBonus(fullName, setBonus)
                        end
                    end
                end
                break
            end
        end

        -- Only advance the queue if WE triggered this INSPECT_READY.
        -- If the player manually inspects someone, set a 60s pause so our
        -- background queue doesn't override their inspection.
        mapDirty = true
        NotifyElvUI()
        if guid == pendingInspectGuid then
            pendingInspectGuid = nil
            ClearInspectPlayer()
            C_Timer.After(1.0, ProcessNextInspect)
        else
            -- Manual inspect by the player — pause our queue for 30s.
            lastManualInspectTime = GetTime()
        end

    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        UpdatePlayerCache()

    elseif event == "PLAYER_REGEN_ENABLED" then
        if db and db.enabled then
            mapDirty = true
            -- Give Details! ~0.5s to update its own bars after combat ends,
            -- then immediately inject iLvl without waiting for the next ticker.
            -- barCleanText is now always current (updated even during combat),
            -- so the refresh sees correct player names for ALL bar positions.
            C_Timer.After(0.5, function()
                if db and db.enabled then
                    RebuildNameIlvlMap()
                    RefreshAllBarTexts()
                end
            end)
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
            -- Wipe name maps immediately — unit tokens reshuffle on roster
            -- changes so old name->iLvl mappings are unreliable until we
            -- re-inspect and re-populate from fresh unit tokens.
            wipe(nameToIlvl)
            wipe(nameToSetBonus)
            mapDirty = true
            NotifyElvUI()
            C_Timer.After(3, QueueGroupInspect)
        end
    end
end)

---------------------------------------------------------------
-- Remove injected iLvl tags from all visible bars
---------------------------------------------------------------
local function ClearAllBarTags()
    isOurSetText = true
    for fontString, cleanText in pairs(barCleanText) do
        pcall(function()
            if fontString:IsShown() and cleanText then
                fontString:SetText(cleanText)
            end
        end)
    end
    isOurSetText = false
end

---------------------------------------------------------------
-- Slash command
---------------------------------------------------------------
SLASH_DILVL1 = "/dilvl"
SlashCmdList["DILVL"] = function(msg)
    msg = msg:lower():trim()

    if msg == "on" then
        db.enabled = true
        RefreshAllBarTexts()
        NotifyElvUI()
        print("|cFF00FF00Details! iLvl Display:|r Enabled")
    elseif msg == "off" then
        db.enabled = false
        ClearAllBarTags()
        NotifyElvUI()
        print("|cFF00FF00Details! iLvl Display:|r Disabled")
    elseif msg == "color" then
        db.colorIlvl = not db.colorIlvl
        RefreshAllBarTexts()
        NotifyElvUI()
        print("|cFF00FF00Details! iLvl Display:|r Color " .. (db.colorIlvl and "ON" or "OFF"))
    elseif msg == "setbonus" then
        db.showSetBonus = not db.showSetBonus
        RefreshAllBarTexts()
        NotifyElvUI()
        print("|cFF00FF00Details! iLvl Display:|r Set Bonus " .. (db.showSetBonus and "ON" or "OFF"))
    elseif msg == "details" then
        db.showInDetails = not db.showInDetails
        if not db.showInDetails then
            ClearAllBarTags()
        else
            RefreshAllBarTexts()
        end
        print("|cFF00FF00Details! iLvl Display:|r Details bars " .. (db.showInDetails and "ON" or "OFF"))
    elseif msg == "inspect" then
        print("|cFF00FF00Details! iLvl Display:|r Inspecting group...")
        QueueGroupInspect()
    elseif msg == "cache" then
        local count, expired = 0, 0
        local now = time()
        for guid, data in pairs(ilvlCache) do
            local name = data.name or "Unknown"
            if guid == UnitGUID("player") then
                name = UnitName("player") or name
            end
            if name == "Unknown" and Details and Details.item_level_pool and Details.item_level_pool[guid] then
                name = Details.item_level_pool[guid].name or name
            end
            local age = now - data.time
            local sb = setBonusCache[guid] and ("|cFF00FF00[" .. setBonusCache[guid] .. "]|r ") or ""
            -- time=0 means force-expired (set by ENCOUNTER_END to trigger re-inspect)
            local ageStr = data.time == 0 and "force-expired" or (age .. "s ago")
            local isExpired = data.time == 0 or age > CACHE_EXPIRE
            local ageColor = isExpired and "|cFFFF4444" or "|cFF888888"
            local expiredNote = isExpired and " |cFFFF4444[EXPIRED]|r" or ""
            print(string.format("  %s: %s|cFFFFD900%d|r iLvl %s(%s)%s",
                name, sb, data.ilvl, ageColor, ageStr, expiredNote))
            count = count + 1
            if age > CACHE_EXPIRE then expired = expired + 1 end
        end
        print(string.format("|cFF00FF00Details! iLvl Display:|r %d cached, %d expired", count, expired))

    elseif msg == "map" then
        print("|cFF00FF00Details! iLvl Display:|r Name->iLvl map (" .. (next(nameToIlvl) and "" or "empty") .. "):")
        for name, ilvl in pairs(nameToIlvl) do
            print(string.format("  %s: |cFFFFD900%d|r", name, ilvl))
        end

    elseif msg == "debug" then
        -- Full bug-report output — user can paste this entire block
        local cacheCount, mapCount, hookCount, setBonusCount, bonusMapCount = 0, 0, 0, 0, 0
        for _ in pairs(ilvlCache) do cacheCount = cacheCount + 1 end
        for _ in pairs(nameToIlvl) do mapCount = mapCount + 1 end
        for _ in pairs(hookedFontStrings) do hookCount = hookCount + 1 end
        for _ in pairs(setBonusCache) do setBonusCount = setBonusCount + 1 end
        for _ in pairs(nameToSetBonus) do bonusMapCount = bonusMapCount + 1 end

        local prefix, count, numGroup = GetGroupInfo()
        local inCombat = InCombatLockdown() and "yes" or "no"
        local manualPause = (GetTime() - lastManualInspectTime) < 60 and "yes" or "no"
        local pending = pendingInspectGuid and pendingInspectGuid:sub(1,8) .. ".." or "none"
        local wowBuild = select(4, GetBuildInfo())
        local detailsVer = Details and (Details.userversion or Details.version) or "n/a"

        print("=== Details! iLvl Display v1.0.2.1 — Bug Report ===")
        print(string.format("  WoW build: %s  Details: %s", wowBuild, tostring(detailsVer)))
        print(string.format("  Addon: %s  Details-bars: %s  ElvUI-tag: %s",
            db.enabled and "ON" or "OFF",
            db.showInDetails and "ON" or "OFF",
            db.elvuiTag and "ON" or "OFF"))
        print(string.format("  Color: %s  SetBonus: %s",
            db.colorIlvl and "ON" or "OFF",
            db.showSetBonus and "ON" or "OFF"))
        print(string.format("  Group: %s (%d members)  InCombat: %s",
            prefix, numGroup, inCombat))
        print(string.format("  Cache: %d iLvl  %d setBonus  %d nameMap  %d bonusMap  %d hooks",
            cacheCount, setBonusCount, mapCount, bonusMapCount, hookCount))
        print(string.format("  Queue: %d pending  inspecting: %s  manualPause: %s  pending: %s",
            #inspectQueue, tostring(isInspecting), manualPause, pending))
        print(string.format("  Details ready: %s  Ticker: %s  MapDirty: %s",
            tostring(detailsReady), tostring(tickerStarted), tostring(mapDirty)))

        -- Cache: show all entries with iLvl + set bonus
        if cacheCount > 0 then
            print("  --- iLvl Cache ---")
            local now = time()
            for guid, data in pairs(ilvlCache) do
                local name = data.name or "?"
                local age = data.time == 0 and "force-exp" or (now - data.time) .. "s"
                local sb = setBonusCache[guid] and ("[" .. setBonusCache[guid] .. "] ") or ""
                print(string.format("    %s: %s%d iLvl (%s)", name, sb, data.ilvl, age))
            end
        end

        -- Tier slots: own gear
        print("  --- Own Tier Slots ---")
        local slotNames = {[1]="Head",[3]="Shoulder",[5]="Chest",[7]="Legs",[10]="Hands"}
        for _, slotID in ipairs(TIER_SLOTS) do
            local itemID = GetInventoryItemID("player", slotID)
            if itemID and itemID > 0 then
                local ok, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, setID = pcall(C_Item.GetItemInfo, itemID)
                local setStr = (ok and setID and setID > 0) and tostring(setID) or "nil"
                local inList = (ok and setID and MIDNIGHT_TIER_SETS[setID]) and "YES" or "no"
                print(string.format("    %s: itemID=%d setID=%s whitelist=%s",
                    slotNames[slotID], itemID, setStr, inList))
            else
                print(string.format("    %s: empty", slotNames[slotID]))
            end
        end
        print("=== end ===")


    elseif msg == "auras" then
        print("|cFF00FF00Details! iLvl Display:|r Player auras (looking for tier bonus):")
        local found = 0
        for i = 1, 60 do
            local aura = C_UnitAuras.GetBuffDataByIndex("player", i)
            if not aura then break end
            local sid = aura.spellId
            local name = aura.name or "?"
            if sid then
                print(string.format("  [%d] %s (spellID=%d)", i, name, sid))
                found = found + 1
            end
        end
        if found == 0 then print("  (none found or spellIds are secret)") end

    elseif msg == "tier" then
        local slotNames = {[1]="Head",[3]="Shoulder",[5]="Chest",[7]="Legs",[10]="Hands"}
        print("|cFF00FF00Details! iLvl Display:|r Tier slot scan (player):")
        for _, slotID in ipairs(TIER_SLOTS) do
            local itemID = GetInventoryItemID("player", slotID)
            if itemID and itemID > 0 then
                local ok, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, setID = pcall(C_Item.GetItemInfo, itemID)
                local setStr = (ok and setID and setID > 0) and tostring(setID) or "nil"
                local inList = (ok and setID and MIDNIGHT_TIER_SETS[setID]) and "|cFF00FF00YES|r" or "|cFFFF4444no|r"
                print(string.format("  %s (slot %d): itemID=%d  setID=%s  inWhitelist=%s",
                    slotNames[slotID], slotID, itemID, setStr, inList))
            else
                print(string.format("  %s (slot %d): empty", slotNames[slotID], slotID))
            end
        end

    elseif msg == "elvui" or msg == "elvui on" then
        db.elvuiTag = true
        NotifyElvUI()
        print("|cFF00FF00Details! iLvl Display:|r ElvUI tag |cFFFFD900[dilvl]|r enabled. Add it to your ElvUI name/health tag.")
    elseif msg == "elvui off" then
        db.elvuiTag = false
        NotifyElvUI()
        print("|cFF00FF00Details! iLvl Display:|r ElvUI tag |cFFFFD900[dilvl]|r disabled.")
    else
        print("|cFF00FF00Details! iLvl Display|r v1.0.2.1")
        print("  /dilvl on|off          — Enable / disable")
        print("  /dilvl details         — Toggle iLvl on Details! bars")
        print("  /dilvl elvui on|off    — Toggle iLvl in ElvUI party frames")
        print("  /dilvl color           — Toggle color-coded iLvl")
        print("  /dilvl setbonus        — Toggle 2P/4P display")
        print("  /dilvl inspect         — Manually trigger group inspect")
        print("  /dilvl debug           — Full status report (paste when reporting a bug)")
        print("  /dilvl cache           — Show cached iLvl entries")
        print("  /dilvl map             — Show name→iLvl map")
        print("  /dilvl tier            — Scan own tier slots")
        print("  /dilvl auras           — Show own auras (spellID debug)")
    end
end

---------------------------------------------------------------
-- Public API — used by elvui_tags.lua (and future integrations)
-- Keeps inter-file coupling minimal: only expose what's needed.
---------------------------------------------------------------
Details_iLvlDisplayAPI = {
    -- Returns cached iLvl entry + set bonus string for a GUID.
    -- Both may be nil if the player hasn't been inspected yet.
    GetCacheData = function(guid)
        if not guid or not ilvlCache then return nil, nil end
        return ilvlCache[guid], setBonusCache[guid]
    end,
    -- Shared color function so ElvUI tag uses the same tier colors.
    GetIlvlColor = GetIlvlColor,
    -- Live db reference — elvui_tags.lua checks db.elvuiTag at call time.
    GetDb = function() return db end,
    -- Callback set by elvui_tags.lua — called whenever cached data changes.
    -- Fires on: INSPECT_READY, UpdatePlayerCache, GROUP_ROSTER_UPDATE.
    -- elvui_tags.lua uses this to call Tags:RefreshMethods("dilvl") so
    -- frames update immediately instead of waiting for a poll timer.
    OnDataChanged = nil,
}

-- Internal helper — call once after any cache write that should update UI.
-- Forward-declared at top of file so event handlers can reference it.
NotifyElvUI = function()
    local cb = Details_iLvlDisplayAPI.OnDataChanged
    if cb then pcall(cb) end
end
