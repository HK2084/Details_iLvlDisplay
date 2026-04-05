local addonName = ...
local addonVersion = C_AddOns.GetAddOnMetadata(addonName, "Version") or "?"

local defaults = {
    enabled = true,
    colorIlvl = true,
    showSetBonus = true,
    showInDetails = true,  -- show iLvl on Details! bars (requires Details!)
    elvuiTag = false,      -- show iLvl in ElvUI party frames (opt-in, requires ElvUI)
    layout = "inline",     -- "inline" (append to name) or "columns" (separate right-aligned columns)
    -- blizzDM: nil = auto (ON when Details! absent, OFF when Details! active)
    --          true/false = user override via /dilvl blizzdm
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
local lastInspectInfo = nil -- {name, ilvl, source, time} last completed inspect for debug
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
local barColumns = {}       -- bar -> {ilvlFS, tierFS} (custom column FontStrings for layout="columns")
local columnRefreshPending = false -- debounce flag for next-frame column refresh
local perfStats = {calls = 0, totalMs = 0, lastMs = 0, peak = 0} -- column refresh perf tracking
local cachedColLayout = nil -- cached {leftA, leftW, secA, secW, gap, yOff} from last good measurement

-- Column layout constants
local COL_ILVL_WIDTH = 36   -- px max text width for iLvl column (truncation threshold)
local COL_TIER_WIDTH = 28   -- px max text width for tier column (truncation threshold)
local MIN_NAME_WIDTH = 50   -- px minimum for player name before hiding columns

---------------------------------------------------------------
-- Secret value guard (WoW 12.0+)
-- issecretvalue() / issecrettable() are Blizzard globals that
-- return true for tainted values that crash on string ops.
-- Check BEFORE touching the value — avoids the pcall entirely.
---------------------------------------------------------------
local function isSecretValue(val)
    if issecretvalue and issecretvalue(val) then return true end
    if issecrettable and issecrettable(val) then return true end
    return false
end

---------------------------------------------------------------
-- Safe InCombatLockdown wrapper (WoW 12.0+)
-- Inside instances, InCombatLockdown() can return a secret value.
-- A secret-wrapped false is truthy in Lua (userdata, not nil/false),
-- so raw `if InCombatLockdown() then` is ALWAYS true when secret.
-- This wrapper treats secret returns as "not in combat" — safe for
-- addon logic (inspect queue, refresh, measurement). For protected
-- frame operations (lineText1:SetSize), use MayBeInCombat() instead.
---------------------------------------------------------------
local function IsInCombatSafe()
    local v = InCombatLockdown()
    if isSecretValue(v) then return false end
    return v
end

-- Strict version: treats secret as "in combat" — use for protected frames only
local function MayBeInCombat()
    local v = InCombatLockdown()
    if isSecretValue(v) then return true end
    return v
end

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

    -- Player's own GUID: always use GetAverageItemLevel (most accurate, no inspect needed)
    -- Skip Details API for self — it can return stale values during combat
    if guid == UnitGUID("player") then
        local _, equipped = GetAverageItemLevel()
        if equipped and equipped > 0 then
            local ilvl = math.floor(equipped)
            ilvlCache[guid] = {ilvl = ilvl, time = time(), source = "self"}
            return ilvl
        end
    end

    local cached = ilvlCache[guid]
    if cached and (time() - cached.time < CACHE_EXPIRE) then
        return cached.ilvl
    end

    -- Details public API (fallback for other players)
    if Details and Details.ilevel and Details.ilevel.GetIlvl then
        local ok, data = pcall(Details.ilevel.GetIlvl, Details.ilevel, guid)
        if ok and data and data.ilvl and data.ilvl > 0 then
            local ilvl = math.floor(data.ilvl)
            ilvlCache[guid] = {ilvl = ilvl, time = time(), source = "details"}
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
    -- Also store short name via Ambiguate for cross-realm players
    local shortName = Ambiguate(name, "short")
    if shortName ~= name then
        nameToIlvl[shortName] = ilvl
    end
end

-- Mirror of StoreNameIlvl for set bonus. sb may be nil (clears entry).
local function StoreNameBonus(name, sb)
    if not name then return end
    nameToSetBonus[name] = sb
    local shortName = Ambiguate(name, "short")
    if shortName ~= name then
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
                -- Cross-realm: cached.name may be "Name-Realm". Also store short
                -- name so Details! bars (which show only "Name") still match.
                local shortName = Ambiguate(cached.name, "short")
                if shortName ~= cached.name then
                    StoreNameIlvl(shortName, cached.ilvl)
                    StoreNameBonus(shortName, setBonusCache[guid])
                end
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
-- Column layout helpers (layout = "columns")
-- Creates dedicated FontStrings per bar for iLvl + tier display,
-- anchored as separate right-aligned columns left of Details!'
-- own right-side text (DPS, total, percent).
---------------------------------------------------------------
local function CopyBarFont(bar, targetFS)
    local source = bar.lineText4
    if not source then return end
    local font, size, flags = source:GetFont()
    if font then
        targetFS:SetFont(font, size, flags)
        targetFS:SetShadowColor(source:GetShadowColor())
        targetFS:SetShadowOffset(source:GetShadowOffset())
    end
end

local function CreateBarColumns(bar)
    if barColumns[bar] then return end
    if not bar.border or not bar.statusbar then return end

    local ilvlFS = bar.border:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    ilvlFS:SetJustifyH("RIGHT")
    ilvlFS:SetWordWrap(false)
    ilvlFS:SetMaxLines(1)
    ilvlFS:SetWidth(COL_ILVL_WIDTH)
    ilvlFS:Hide()

    local tierFS = bar.border:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    tierFS:SetJustifyH("RIGHT")
    tierFS:SetWordWrap(false)
    tierFS:SetMaxLines(1)
    tierFS:SetWidth(COL_TIER_WIDTH)
    tierFS:Hide()

    -- Copy font once at creation (updated on resize via UpdateAllColumnFonts)
    CopyBarFont(bar, ilvlFS)
    CopyBarFont(bar, tierFS)

    barColumns[bar] = {ilvlFS = ilvlFS, tierFS = tierFS}
end

-- Re-copy fonts for all columns (called on resize / config change, NOT per refresh)
local function UpdateAllColumnFonts()
    for bar, cols in pairs(barColumns) do
        CopyBarFont(bar, cols.ilvlFS)
        CopyBarFont(bar, cols.tierFS)
    end
end

---------------------------------------------------------------
-- RefreshAllColumns — lean two-pass auto-align (mirrors Details!)
--
-- Details! AutoAlignInLineFontStrings computes global max text
-- widths across ALL bars, then positions every column uniformly.
-- We continue the same pattern: measure the leftmost Details!
-- column, compute a dynamic gap from adjacent columns, and
-- chain our columns from there. Zero table allocation.
---------------------------------------------------------------
local function RefreshAllColumns()
    -- No InCombatLockdown guard here: our column FontStrings are addon-created
    -- overlays, not protected UI. Only lineText1:SetSize is guarded (pass 2).
    if not db or db.layout ~= "columns" then return end
    if not db.showInDetails then return end
    if not next(nameToIlvl) then return end
    local _perfStart = debugprofilestop()

    -- === PASS 1: Set text + measure all columns (zero allocation) ===
    local key2a, key2w = 0, 0 -- lineText2: maxAnchor, maxWidth
    local key3a, key3w = 0, 0 -- lineText3
    local key4a, key4w = 0, 0 -- lineText4
    local maxWidthIlvl = 0
    local yOff = 0

    for bar, cols in pairs(barColumns) do
        if not bar:IsShown() then
            cols.ilvlFS:Hide()
            cols.tierFS:Hide()
        else
            -- Primary: Details! actor reference (always current, even during SECRET text reshuffles)
            -- Fallback: barCleanText (may be stale when SetText receives secret values)
            local ilvl, sb
            local actor = bar.minha_tabela
            if actor and actor.serial then
                ilvl = GetIlvlForGuid(actor.serial)
                sb = db.showSetBonus and setBonusCache[actor.serial]
            end
            if not ilvl then
                local text = barCleanText[bar.lineText1]
                local name = text and ExtractName(text)
                ilvl = name and nameToIlvl[name]
                sb = name and db.showSetBonus and nameToSetBonus[name]
            end

            if not ilvl then
                cols.ilvlFS:SetText("")
                cols.ilvlFS:Hide()
                cols.tierFS:SetText("")
                cols.tierFS:Hide()
            else
                -- Set ilvl text
                if db.colorIlvl then
                    cols.ilvlFS:SetText(GetIlvlColor(ilvl) .. ilvl .. "|r")
                else
                    cols.ilvlFS:SetText(tostring(ilvl))
                end
                -- Set tier text
                cols.tierFS:SetText(sb and ("|cFF00FF00" .. sb .. "|r") or "")

                -- Measure our ilvl column
                local iw = cols.ilvlFS:GetStringWidth() or 0
                if iw > maxWidthIlvl then maxWidthIlvl = iw end

                -- yOffset (once)
                if yOff == 0 and bar.instance_id and Details then
                    local ok, inst = pcall(Details.GetInstance, Details, bar.instance_id)
                    if ok and inst and inst.row_info then
                        yOff = inst.row_info.text_yoffset or 0
                    end
                end

                -- Measure Details! right columns (skip during combat when cached)
                if not cachedColLayout or not IsInCombatSafe() then
                    local fs = bar.lineText4
                    if fs and fs:IsShown() and fs:GetNumPoints() > 0 then
                        local _, _, _, ox = fs:GetPoint(1)
                        if ox and not isSecretValue(ox) then
                            local a = math.abs(ox)
                            if a > key4a then key4a = a end
                            local t = fs:GetText()
                            if t and not isSecretValue(t) and t ~= "" then
                                local w = fs:GetStringWidth() or 0
                                if w > key4w then key4w = w end
                            end
                        end
                    end
                    fs = bar.lineText3
                    if fs and fs:IsShown() and fs:GetNumPoints() > 0 then
                        local _, _, _, ox = fs:GetPoint(1)
                        if ox and not isSecretValue(ox) then
                            local a = math.abs(ox)
                            if a > key3a then key3a = a end
                            local t = fs:GetText()
                            if t and not isSecretValue(t) and t ~= "" then
                                local w = fs:GetStringWidth() or 0
                                if w > key3w then key3w = w end
                            end
                        end
                    end
                    fs = bar.lineText2
                    if fs and fs:IsShown() and fs:GetNumPoints() > 0 then
                        local _, _, _, ox = fs:GetPoint(1)
                        if ox and not isSecretValue(ox) then
                            local a = math.abs(ox)
                            if a > key2a then key2a = a end
                            local t = fs:GetText()
                            if t and not isSecretValue(t) and t ~= "" then
                                local w = fs:GetStringWidth() or 0
                                if w > key2w then key2w = w end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Compute gap from two adjacent Details! columns that BOTH have visible text.
    -- This mirrors Details!' own visual spacing between data columns.
    -- text4 is always at anchor 0, so key4a=0 — use key4w>0 to detect presence.
    local detailsGap = 5 -- default (Details!' min structural gap)
    if key3a > 0 and key3w > 0 and key4w > 0 then
        local measured = key3a - key4w -- visual gap at max-width between text4 and text3
        if measured >= 3 then detailsGap = measured end
    end

    -- Find the leftmost Details! column edge WITH actual text content.
    -- Empty columns (text2 with no text) are skipped — anchoring from them
    -- creates a huge visual gap between our columns and the nearest visible data.
    local contentEdge = 0
    if key2a > 0 and key2w > 0 then
        contentEdge = key2a + key2w     -- text2 has text: use its left edge
    elseif key3a > 0 and key3w > 0 then
        contentEdge = key3a + key3w     -- text2 empty: anchor from text3's left edge
    elseif key4w > 0 then
        contentEdge = key4w             -- only text4 visible (at anchor 0)
    end

    -- Cache management: store good measurements for combat fallback
    local hasGoodData = (key3a > 0 or key4w > 0)
    if hasGoodData then
        if contentEdge == 0 then contentEdge = 73 end
        cachedColLayout = {contentEdge = contentEdge, detailsGap = detailsGap, yOff = yOff}
        if db then db.cachedColLayout = cachedColLayout end
    elseif cachedColLayout then
        contentEdge = cachedColLayout.contentEdge
        detailsGap  = cachedColLayout.detailsGap
        yOff        = cachedColLayout.yOff
    else
        contentEdge = 73 -- no cache yet, Details default
    end

    local gap = cachedColLayout and cachedColLayout.detailsGap or 5
    local ilvlAnchor = contentEdge + gap          -- matches Details!' own column spacing
    local tierAnchor = ilvlAnchor + maxWidthIlvl + gap + 4  -- +4px padding between our own columns

    -- === PASS 2: Position all columns ===
    for bar, cols in pairs(barColumns) do
        if bar:IsShown() then
            -- Check if this bar has data (text set in pass 1; empty = no data)
            local ilvlText = cols.ilvlFS:GetText()
            if not ilvlText or ilvlText == "" then
                -- already hidden in pass 1
            else
                local barWidth = bar.statusbar and bar.statusbar:GetWidth() or 0

                -- Dynamic hide: ilvl (last to hide)
                if barWidth - (ilvlAnchor + maxWidthIlvl) < MIN_NAME_WIDTH then
                    cols.ilvlFS:Hide()
                    cols.tierFS:Hide()
                else
                    cols.ilvlFS:ClearAllPoints()
                    cols.ilvlFS:SetPoint("RIGHT", bar.statusbar, "RIGHT", -ilvlAnchor, yOff)
                    cols.ilvlFS:Show()

                    -- Tier (first to hide)
                    local tierText = cols.tierFS:GetText()
                    if tierText and tierText ~= "" and barWidth - (tierAnchor + COL_TIER_WIDTH) >= MIN_NAME_WIDTH then
                        cols.tierFS:ClearAllPoints()
                        cols.tierFS:SetPoint("RIGHT", bar.statusbar, "RIGHT", -tierAnchor, yOff)
                        cols.tierFS:Show()
                    else
                        cols.tierFS:Hide()
                    end
                end

                -- Constrain name width to prevent overlap (skip during combat — taint)
                if not MayBeInCombat() then
                    local rightEdge = ilvlAnchor + maxWidthIlvl
                    if cols.tierFS:IsShown() then rightEdge = tierAnchor + COL_TIER_WIDTH end
                    if not cols.ilvlFS:IsShown() then rightEdge = 0 end
                    local nameMaxW = barWidth - rightEdge - gap
                    if nameMaxW < MIN_NAME_WIDTH then nameMaxW = MIN_NAME_WIDTH end
                    bar.lineText1:SetSize(nameMaxW, 15)
                end
            end
        end
    end

    -- Perf tracking
    local elapsed = debugprofilestop() - _perfStart
    perfStats.calls = perfStats.calls + 1
    perfStats.totalMs = perfStats.totalMs + elapsed
    perfStats.lastMs = elapsed
    if elapsed > perfStats.peak then perfStats.peak = elapsed end
end

local function ClearAllColumns()
    for bar, cols in pairs(barColumns) do
        cols.ilvlFS:Hide()
        cols.ilvlFS:SetText("")
        cols.tierFS:Hide()
        cols.tierFS:SetText("")
        -- Reset lineText1 width constraint (Details! re-applies its own on next refresh)
        if bar.lineText1 then
            bar.lineText1:SetWidth(0)
        end
    end
end

-- Debounced next-frame column refresh.
-- Called from SetText hook; runs AFTER Details! finishes sizing for this frame.
local function ScheduleColumnRefresh()
    if columnRefreshPending then return end
    columnRefreshPending = true
    C_Timer.After(0, function()
        columnRefreshPending = false
        -- No combat guard: column FontStrings are addon-created, not protected.
        -- RefreshAllColumns guards lineText1:SetSize internally.
        if not db or not db.enabled or not db.showInDetails then return end
        if db.layout ~= "columns" then return end
        if mapDirty then
            mapDirty = false
            RebuildNameIlvlMap()
        end
        RefreshAllColumns()
    end)
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

    -- Create column FontStrings for this bar (no-op if already created)
    CreateBarColumns(bar)

    -- Seed barCleanText immediately with the current text — safe because we
    -- haven't injected into this FontString yet, so GetText() is clean.
    -- Without this, RefreshAllBarTexts has nothing to work with until Details!
    -- calls SetText again (e.g. never, if the window was just resized).
    -- GetText() can return a secret string (Details! Itemlevelfinder).
    -- Per-field guard: check the value, skip if tainted. No pcall needed.
    local currentText = fontString:GetText()
    if not isSecretValue(currentText)
       and currentText and type(currentText) == "string"
       and not currentText:find("%[%d+%]") then
        barCleanText[fontString] = currentText
    end
    mapDirty = true

    hooksecurefunc(fontString, "SetText", function(self, text)
        if isOurSetText then return end
        if not db or not db.enabled then return end
        -- Details! Itemlevelfinder passes "secret string" values to SetText.
        -- Per-field guard: check the value, skip if tainted. No pcall needed.
        if isSecretValue(text) then
            -- Invalidate stale text and hide this bar's columns immediately.
            -- During bar reshuffles, minha_tabela may still reference the old
            -- actor when a scheduled refresh fires — showing wrong data.
            -- Columns reappear when Details! sets the real (non-secret) text.
            barCleanText[self] = nil
            if db.layout == "columns" then
                local cols = barColumns[bar]
                if cols then
                    cols.ilvlFS:SetText("")
                    cols.ilvlFS:Hide()
                    cols.tierFS:SetText("")
                    cols.tierFS:Hide()
                end
            end
            return
        end
        if not text or type(text) ~= "string" or text:match("^%s*$") then return end
        if text:find("%[%d+%]") then return end

        -- Cache Details!'s clean text before we inject anything.
        -- Only store text with a rank prefix ("1. Name") — real player bars.
        -- Details! may call SetText with placeholders like "warte Aktualisierung ab ..."
        -- during data loading; those must NOT overwrite a stored player name.
        if text:match("^%d+%.%s") or not barCleanText[self] then
            barCleanText[self] = text
        end

        if not db.showInDetails then return end

        -- Column mode: schedule next-frame refresh (after Details! finishes sizing).
        -- No combat guard needed — we only write to our own FontStrings, not Details!'.
        if db.layout == "columns" then
            ScheduleColumnRefresh()
            return
        end

        -- Don't inject during combat (taint with secure UI elements)
        if MayBeInCombat() then return end

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
    if not db or not db.showInDetails then return end
    if not next(nameToIlvl) then return end

    -- Column mode: no combat guard needed (writes to our own FontStrings only)
    if db.layout == "columns" then
        RefreshAllColumns()
        return
    end

    -- Inline mode: skip during combat (modifies Details!' FontStrings → taint)
    if MayBeInCombat() then return end

    isOurSetText = true
    for fontString in pairs(hookedFontStrings) do
        -- barCleanText values are pre-validated on insert (isSecretValue checked
        -- in SetText hook and GetText seed). No pcall needed here.
        if fontString:IsShown() then
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
    -- Immediate next-frame column refresh (cheap, 0.09ms) for responsive resize
    if db and db.layout == "columns" then
        ScheduleColumnRefresh()
    end
    -- Full re-hook + rebuild after drag ends (0.3s debounce)
    if resizeDebounce then
        resizeDebounce:Cancel()
    end
    resizeDebounce = C_Timer.NewTimer(0.3, function()
        resizeDebounce = nil
        if not db or not db.enabled then return end
        mapDirty = true
        cachedColLayout = nil -- force re-measure after resize
        if db then db.cachedColLayout = nil end
        HookAllBars()         -- pick up any new bar FontStrings created on resize
        UpdateAllColumnFonts() -- re-copy fonts (Details! font may have changed)
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

    -- Details-specific work (skip in ElvUI-only mode)
    if Details then
        HookAllBars()

        if mapDirty then
            mapDirty = false
            RebuildNameIlvlMap()
        end

        -- Always run, cheap: early exits if bars already tagged or nameToIlvl empty
        RefreshAllBarTexts()
    end
end

---------------------------------------------------------------
-- Inspect group
---------------------------------------------------------------
local function ProcessNextInspect()
    if IsInCombatSafe() or #inspectQueue == 0 then
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
    if IsInCombatSafe() then return end

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
        -- UnitGUID compare instead of UnitIsUnit(unit, "player"):
        -- Blizzard is hotfixing UnitIsUnit to return secret values (April 2026,
        -- Race to World First L'ura — used by interrupt anchor addons on nameplates).
        -- Secret values are truthy, so `not UnitIsUnit(...)` would always be false
        -- and skip ALL units, breaking our inspect queue entirely.
        -- UnitGUID is fundamental infrastructure — safe from secret restrictions.
        if UnitExists(unit) and UnitIsPlayer(unit) and UnitGUID(unit) ~= UnitGUID("player") then
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
    local ilvl = math.floor(equipped)
    ilvlCache[guid] = {ilvl = ilvl, time = time(), name = pname, source = "self"}
    setBonusCache[guid] = sb or false
    if pname then
        StoreNameIlvl(pname, ilvl)
        StoreNameBonus(pname, sb)
    end
    mapDirty = true
    NotifyElvUI()
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("INSPECT_READY")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
frame:RegisterEvent("UNIT_INVENTORY_CHANGED")
frame:RegisterEvent("ENCOUNTER_END")
frame:RegisterEvent("GET_ITEM_INFO_RECEIVED")

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

            -- Restore column layout cache from SavedVariables (survives /reload in instances
            -- where Details! columns are SECRET and can't be re-measured)
            if db.cachedColLayout then
                cachedColLayout = db.cachedColLayout
            end

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
                                    -- Skip own GUID — GetAverageItemLevel is always more accurate for self
                                    if guid == UnitGUID("player") then break end
                                    if guid then
                                        local ilvl = math.floor(gearInfo.ilevel)
                                        -- Only update if newer than what we have
                                        local existing = ilvlCache[guid]
                                        if not existing or ilvl ~= existing.ilvl or (time() - existing.time) > 300 then
                                            local name, realm = UnitName(unit)
                                            local storedName = (realm and realm ~= "") and (name.."-"..realm) or name
                                            ilvlCache[guid] = {ilvl = ilvl, time = time(), name = storedName, source = "lor"}
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
                detailsReady = true
                if Details then
                    RebuildNameIlvlMap()
                    HookAllBars()
                end
                C_Timer.NewTicker(2, OnTick)

                -- Build mode string for login message
                local modes = {}
                if Details then modes[#modes + 1] = "Details!" end
                if db.blizzDM == true or (db.blizzDM == nil and not Details) then
                    modes[#modes + 1] = "Blizzard DM"
                end
                if db.elvuiTag and ElvUI then modes[#modes + 1] = "ElvUI" end
                local modeStr = #modes > 0 and table.concat(modes, " + ") or "cache-only"
                print("|cFF00FF00Details! iLvl Display|r v" .. addonVersion .. " loaded (" .. modeStr .. "). /dilvl")
                -- Inspect in both modes (Details + ElvUI-only)
                C_Timer.After(5, QueueGroupInspect)
                -- LFR: unit tokens for all 25 players may not exist yet after 5s.
                -- Retry at 15s and 30s to catch late-appearing group members.
                C_Timer.After(15, QueueGroupInspect)
                C_Timer.After(30, QueueGroupInspect)
            end)
        end

        -- Rebuild name maps on zone change (unit tokens may have changed).
        -- Cache entries are kept — the 2h TTL handles staleness, and players
        -- viewing old Details! segments still see iLvl from previous groups.
        if ilvlCache then
            local currentMap = C_Map.GetBestMapForUnit("player")
            if currentMap and currentMap ~= lastMapID then
                wipe(nameToIlvl)
                wipe(nameToSetBonus)
                mapDirty = true
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
                -- Skip own GUID — GetAverageItemLevel is always more accurate for self
                if guid == UnitGUID("player") then break end
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
                    ilvlCache[guid] = {ilvl = ilvlFloor, time = time(), name = fullName or name or cachedName, source = "inspect"}
                    lastInspectInfo = {name = fullName or name or cachedName, ilvl = ilvlFloor, time = GetTime()}
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

    elseif event == "GET_ITEM_INFO_RECEIVED" then
        -- C_Item.GetItemInfo is async — on fresh login, tier slot items may
        -- not be cached yet, causing GetSetBonusForUnit to undercount.
        -- Re-check only when a tier slot item finishes loading.
        local itemID = ...
        if itemID then
            for _, slotID in ipairs(TIER_SLOTS) do
                if GetInventoryItemID("player", slotID) == itemID then
                    UpdatePlayerCache()
                    break
                end
            end
        end

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
            -- Don't force-expire ALL entries: players out of inspect range (common
            -- in LFR) would lose their tags and never get them back this session.
            -- Instead set cache age to just-under-expiry so QueueGroupInspect will
            -- re-queue them when in range, but existing data stays visible until then.
            local softExpire = time() - (CACHE_EXPIRE - 60) -- 60s left before real expiry
            local prefix, count = GetGroupInfo()
            for i = 1, count do
                local guid = UnitGUID(prefix .. i)
                if guid and ilvlCache[guid] then
                    ilvlCache[guid].time = softExpire
                end
            end
            C_Timer.After(5, QueueGroupInspect)
        end

    elseif event == "GROUP_ROSTER_UPDATE" then
        if not IsInCombatSafe() and db and db.enabled then
            -- Wipe name maps immediately — unit tokens reshuffle on roster
            -- changes so old name->iLvl mappings are unreliable until we
            -- re-inspect and re-populate from fresh unit tokens.
            wipe(nameToIlvl)
            wipe(nameToSetBonus)
            mapDirty = true
            NotifyElvUI()
            C_Timer.After(3, QueueGroupInspect)
        end

    elseif event == "UNIT_INVENTORY_CHANGED" then
        -- Re-inspect group member when they equip new gear.
        -- Fires per unit token ("party1", "raid5", etc.)
        local unit = ...
        if unit and UnitIsPlayer(unit) and not UnitIsUnit(unit, "player") and not IsInCombatSafe() then
            local guid = UnitGUID(unit)
            if guid and ilvlCache[guid] then
                -- Invalidate stale cache so QueueGroupInspect picks them up
                ilvlCache[guid].time = 0
                C_Timer.After(2, QueueGroupInspect)
            end
        end
    end
end)

---------------------------------------------------------------
-- Remove injected iLvl tags from all visible bars
---------------------------------------------------------------
local function ClearAllBarTags()
    isOurSetText = true
    for fontString, cleanText in pairs(barCleanText) do
        -- cleanText is pre-validated (isSecretValue checked on insert).
        if fontString:IsShown() and cleanText then
            fontString:SetText(cleanText)
        end
    end
    isOurSetText = false
    ClearAllColumns()
end

---------------------------------------------------------------
-- Debug popup — scrollable, copy-pasteable output window
---------------------------------------------------------------
local function ShowDebugWindow(text)
    if not DILvlDebugFrame then
        local f = CreateFrame("Frame", "DILvlDebugFrame", UIParent, "BackdropTemplate")
        f:SetSize(700, 500)
        f:SetPoint("CENTER")
        f:SetBackdrop({
            bgFile = "Interface/Tooltips/UI-Tooltip-Background",
            edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
            edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        f:SetBackdropColor(0, 0, 0, 0.9)
        f:SetMovable(true)
        f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        f:SetFrameStrata("DIALOG")
        local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("TOP", 0, -8)
        title:SetText("Details! iLvl Display — Debug")
        local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", -2, -2)
        local scroll = CreateFrame("ScrollFrame", "DILvlDebugScroll", f, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 10, -30)
        scroll:SetPoint("BOTTOMRIGHT", -30, 10)
        local eb = CreateFrame("EditBox", nil, scroll)
        eb:SetMultiLine(true)
        eb:SetFontObject(GameFontHighlightSmall)
        eb:SetWidth(650)
        eb:SetAutoFocus(false)
        eb:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
        scroll:SetScrollChild(eb)
        f.editBox = eb
    end
    DILvlDebugFrame.editBox:SetText(text)
    DILvlDebugFrame.editBox:HighlightText()
    DILvlDebugFrame:Show()
end
-- Expose for blizzdm.lua trace output
Details_iLvlDisplay_ShowDebugWindow = ShowDebugWindow

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
        -- Full bug-report output — also shown in scrollable popup for easy copy-paste.
        -- Temporarily wrap print() to capture all output into a buffer.
        local debugBuf = {}
        local origPrint = print
        print = function(m)
            origPrint(m)
            local s = tostring(m)
            if isSecretValue(s) then s = "(secret)" end
            debugBuf[#debugBuf + 1] = s
        end

        local cacheCount, mapCount, hookCount, setBonusCount, bonusMapCount, colCount = 0, 0, 0, 0, 0, 0
        for _ in pairs(ilvlCache) do cacheCount = cacheCount + 1 end
        for _ in pairs(nameToIlvl) do mapCount = mapCount + 1 end
        for _ in pairs(hookedFontStrings) do hookCount = hookCount + 1 end
        for _ in pairs(setBonusCache) do setBonusCount = setBonusCount + 1 end
        for _ in pairs(nameToSetBonus) do bonusMapCount = bonusMapCount + 1 end
        for _ in pairs(barColumns) do colCount = colCount + 1 end

        local prefix, count, numGroup = GetGroupInfo()
        local rawCombat = InCombatLockdown()
        local inCombat = isSecretValue(rawCombat) and "SECRET(safe=no)" or (rawCombat and "yes" or "no")
        local manualPause = (GetTime() - lastManualInspectTime) < 60 and "yes" or "no"
        local pending = pendingInspectGuid and pendingInspectGuid:sub(1,8) .. ".." or "none"
        local wowBuild = select(4, GetBuildInfo())
        local detailsVer = Details and (Details.userversion or Details.version) or "n/a"

        print("=== Details! iLvl Display v" .. addonVersion .. " — Bug Report ===")
        print(string.format("  WoW build: %s  Details: %s", wowBuild, tostring(detailsVer)))
        local blizzDMState = db.blizzDM == nil and ("AUTO(" .. (Details and "off" or "on") .. ")") or (db.blizzDM and "ON" or "OFF")
        print(string.format("  Addon: %s  Details-bars: %s  ElvUI-tag: %s  BlizzDM: %s  Layout: %s",
            db.enabled and "ON" or "OFF",
            db.showInDetails and "ON" or "OFF",
            db.elvuiTag and "ON" or "OFF",
            blizzDMState,
            db.layout or "inline"))
        print(string.format("  Color: %s  SetBonus: %s",
            db.colorIlvl and "ON" or "OFF",
            db.showSetBonus and "ON" or "OFF"))
        print(string.format("  Group: %s (%d members)  InCombat: %s",
            prefix, numGroup, inCombat))
        print(string.format("  Cache: %d iLvl  %d setBonus  %d nameMap  %d bonusMap  %d hooks  %d columns",
            cacheCount, setBonusCount, mapCount, bonusMapCount, hookCount, colCount))
        print(string.format("  Queue: %d pending  inspecting: %s  manualPause: %s  pending: %s",
            #inspectQueue, tostring(isInspecting), manualPause, pending))
        -- Queue contents (who is waiting)
        if #inspectQueue > 0 then
            local qNames = {}
            for i, qItem in ipairs(inspectQueue) do
                local qGuid = type(qItem) == "table" and qItem.guid or qItem
                local qEntry = ilvlCache[qGuid]
                local qName = qEntry and qEntry.name or (qGuid and qGuid:sub(1,8) .. ".." or "?")
                qNames[#qNames + 1] = qName
                if i >= 10 then
                    qNames[#qNames + 1] = string.format("+%d more", #inspectQueue - 10)
                    break
                end
            end
            print("  Queue names: " .. table.concat(qNames, ", "))
        end
        -- Last completed inspect
        if lastInspectInfo then
            local ago = string.format("%.0fs ago", GetTime() - lastInspectInfo.time)
            print(string.format("  Last inspect: %s → %d iLvl (%s)", lastInspectInfo.name, lastInspectInfo.ilvl, ago))
        end
        print(string.format("  Details ready: %s  Ticker: %s  MapDirty: %s  LibOpenRaid: %s",
            tostring(detailsReady), tostring(tickerStarted), tostring(mapDirty),
            openRaidLib and "active" or "n/a"))

        -- BlizzDM diagnostics
        if Details_iLvlDisplayAPI.GetBlizzDMDebug then
            local windows, frames, hasGuid, hasTag, secretName, entries, ci = Details_iLvlDisplayAPI.GetBlizzDMDebug()
            print("  --- Blizzard Damage Meter ---")
            if type(ci) == "table" then
                print(string.format("    windows: %d  frames: %d  GUID: %d  tagged: %d  secret: %d",
                    windows, frames, hasGuid, hasTag, secretName))
                print(string.format("    combat: group=%s  self=%s  encounter=%s%s  unitFlags=%s  members=%d",
                    ci.groupCombat and "YES" or "no",
                    ci.inCombat and "YES" or "no",
                    ci.encounter and "YES" or "no",
                    ci.encounterSecret and "(SECRET)" or "",
                    ci.unitFlags and "YES" or "no",
                    ci.members or 0))
            else
                -- Fallback for old format
                print(string.format("    windows: %d  frames: %d  GUID: %d  tagged: %d  secret: %d  inCombat: %s",
                    windows, frames, hasGuid, hasTag, secretName, tostring(ci)))
            end
            if entries then
                for i, e in ipairs(entries) do
                    local flags = ""
                    if e.secret then flags = flags .. " SECRET" end
                    if e.alphaHidden then flags = flags .. " ALPHA0" end
                    if e.overlay then flags = flags .. " OVR" end
                    flags = flags .. " [" .. (e.path or "?") .. "]"
                    if e.nameFSType then flags = flags .. " fs:" .. e.nameFSType end
                    print(string.format("    [%d] %s%s  guid:%s  cache:%s  tag:%s%s",
                        i, e.name,
                        e.isLocal and " (YOU)" or "",
                        e.guid and "yes" or "NO",
                        e.cached and "yes" or "no",
                        e.tagged and "yes" or "no",
                        flags))
                    -- Extended debug: show native text, overlay text, cache name
                    local extra = "        "
                    if e.nativeTxt then extra = extra .. "native:" .. e.nativeTxt end
                    if e.ovrTxt then extra = extra .. "  ovr:" .. e.ovrTxt end
                    if e.cacheName then extra = extra .. "  cName:" .. e.cacheName end
                    print(extra)
                end
            end
            if frames == 0 then
                print("    (open Blizzard DM window to see entries)")
            end
        else
            print("  --- Blizzard Damage Meter: not loaded ---")
        end

        -- Column diagnostics
        if db.layout == "columns" then
            print("  --- Column Diagnostics ---")
            local shown, hasText, hasIlvl = 0, 0, 0
            -- Simulate pass 1 measurement for debug output
            local dk2a, dk2w, dk3a, dk3w, dk4a, dk4w = 0, 0, 0, 0, 0, 0
            local dMaxIlvl = 0
            for bar, cols in pairs(barColumns) do
                if bar:IsShown() then
                    shown = shown + 1
                    local ct = barCleanText[bar.lineText1]
                    local n = ct and ExtractName(ct)
                    local iv = n and nameToIlvl[n]
                    if ct then hasText = hasText + 1 end
                    if iv then hasIlvl = hasIlvl + 1 end

                    -- Per-bar detail (first 2 visible bars)
                    if shown <= 2 then
                        print(string.format("    [bar %d] cleanText=%s", shown, ct and ct:sub(1,30) or "nil"))
                        print(string.format("      name=%s  ilvl=%s", tostring(n), tostring(iv)))
                        print(string.format("      barWidth=%.1f  shown=%s",
                            bar.statusbar and bar.statusbar:GetWidth() or 0,
                            tostring(bar:IsShown())))
                        print(string.format("      ilvlFS: text=%s shown=%s  tierFS: text=%s shown=%s",
                            tostring(cols.ilvlFS:GetText()), tostring(cols.ilvlFS:IsShown()),
                            tostring(cols.tierFS:GetText()), tostring(cols.tierFS:IsShown())))
                        -- Details! columns
                        for _, k in ipairs({"lineText2","lineText3","lineText4"}) do
                            local fs = bar[k]
                            if fs then
                                local vis = fs:IsShown() and "vis" or "hid"
                                local pts = fs:GetNumPoints()
                                local ox, sw = "?", "?"
                                if pts > 0 then
                                    local _,_,_,x = fs:GetPoint(1)
                                    ox = x and (isSecretValue(x) and "SECRET" or string.format("%.1f", x)) or "nil"
                                end
                                local txt = fs:GetText()
                                if txt then
                                    if isSecretValue(txt) then sw = "SECRET"
                                    else sw = string.format("%.1f", fs:GetStringWidth() or 0) end
                                else sw = "0" end
                                local ts = txt and (isSecretValue(txt) and "SECRET" or txt:sub(1,10)) or "nil"
                                print(string.format("      %s: %s ox=%s sw=%s text=%s", k, vis, ox, sw, ts))
                            end
                        end
                    end

                    -- Accumulate measurements (same logic as RefreshAllColumns pass 1)
                    local fs = bar.lineText4
                    if fs and fs:IsShown() and fs:GetNumPoints() > 0 then
                        local _,_,_,ox = fs:GetPoint(1)
                        if ox and not isSecretValue(ox) then
                            local a = math.abs(ox)
                            if a > dk4a then dk4a = a end
                            local t = fs:GetText()
                            if t and not isSecretValue(t) and t ~= "" then
                                local w = fs:GetStringWidth() or 0
                                if w > dk4w then dk4w = w end
                            end
                        end
                    end
                    fs = bar.lineText3
                    if fs and fs:IsShown() and fs:GetNumPoints() > 0 then
                        local _,_,_,ox = fs:GetPoint(1)
                        if ox and not isSecretValue(ox) then
                            local a = math.abs(ox)
                            if a > dk3a then dk3a = a end
                            local t = fs:GetText()
                            if t and not isSecretValue(t) and t ~= "" then
                                local w = fs:GetStringWidth() or 0
                                if w > dk3w then dk3w = w end
                            end
                        end
                    end
                    fs = bar.lineText2
                    if fs and fs:IsShown() and fs:GetNumPoints() > 0 then
                        local _,_,_,ox = fs:GetPoint(1)
                        if ox and not isSecretValue(ox) then
                            local a = math.abs(ox)
                            if a > dk2a then dk2a = a end
                            local t = fs:GetText()
                            if t and not isSecretValue(t) and t ~= "" then
                                local w = fs:GetStringWidth() or 0
                                if w > dk2w then dk2w = w end
                            end
                        end
                    end
                    -- Our ilvl width
                    if iv then
                        local iw = cols.ilvlFS:GetStringWidth() or 0
                        if iw > dMaxIlvl then dMaxIlvl = iw end
                    end
                end
            end

            -- Compute anchors (mirror RefreshAllColumns logic)
            local dGap = 5
            if dk3a > 0 and dk3w > 0 and dk4w > 0 then
                local m = dk3a - dk4w
                if m >= 3 then dGap = m end
            end
            local cEdge = 0
            if dk2a > 0 and dk2w > 0 then cEdge = dk2a + dk2w
            elseif dk3a > 0 and dk3w > 0 then cEdge = dk3a + dk3w
            elseif dk4w > 0 then cEdge = dk4w
            else cEdge = 73 end
            local ilvlAnc = cEdge + dGap
            local tierAnc = ilvlAnc + dMaxIlvl + dGap

            print("  --- Spacing ---")
            print(string.format("    Details! cols: text4(a=%.1f w=%.1f) text3(a=%.1f w=%.1f) text2(a=%.1f w=%.1f)",
                dk4a, dk4w, dk3a, dk3w, dk2a, dk2w))
            local cacheStr = cachedColLayout and string.format("YES(gap=%.1f)", cachedColLayout.detailsGap) or "NO"
            print(string.format("    contentEdge=%.1f  detailsGap=%.1f  cache=%s",
                cEdge, dGap, cacheStr))
            print(string.format("    ilvlAnchor=%.1f  tierAnchor=%.1f  maxWidthIlvl=%.1f",
                ilvlAnc, tierAnc, dMaxIlvl))
            -- Hide thresholds
            local sampleWidth = 0
            for bar in pairs(barColumns) do
                if bar:IsShown() and bar.statusbar then
                    sampleWidth = bar.statusbar:GetWidth()
                    break
                end
            end
            print(string.format("    barWidth=%.1f  nameLeft=%.1f  hideIlvl@<%.1f  hideTier@<%.1f",
                sampleWidth,
                sampleWidth - (tierAnc + COL_TIER_WIDTH) - dGap,
                ilvlAnc + dMaxIlvl + MIN_NAME_WIDTH,
                tierAnc + COL_TIER_WIDTH + MIN_NAME_WIDTH))

            print(string.format("    bars: %d shown, %d cleanText, %d ilvlMatch", shown, hasText, hasIlvl))
            if perfStats.calls > 0 then
                print(string.format("    perf: %d calls, avg=%.2fms, last=%.2fms, peak=%.2fms",
                    perfStats.calls, perfStats.totalMs / perfStats.calls, perfStats.lastMs, perfStats.peak))
            else
                print("    perf: no calls yet")
            end
        end

        -- Cache: show all entries with iLvl + set bonus
        if cacheCount > 0 then
            print("  --- iLvl Cache ---")
            local now = time()
            for guid, data in pairs(ilvlCache) do
                local name = data.name or "?"
                local age = data.time == 0 and "force-exp" or (now - data.time) .. "s"
                local sb = setBonusCache[guid] and ("[" .. setBonusCache[guid] .. "] ") or ""
                local src = data.source and string.upper(data.source) or "?"
                print(string.format("    %s: %s%d iLvl [%s] (%s)", name, sb, data.ilvl, src, age))
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

        -- Restore original print and show copy-paste popup
        print = origPrint
        ShowDebugWindow(table.concat(debugBuf, "\n"))

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

    elseif msg == "blizzdm" then
        -- nil (auto) → force ON; true → OFF; false → ON
        if db.blizzDM == nil then
            db.blizzDM = true
        else
            db.blizzDM = not db.blizzDM
        end
        NotifyElvUI()
        print("|cFF00FF00Details! iLvl Display:|r Blizzard Damage Meter " .. (db.blizzDM and "ON" or "OFF"))
        if db.blizzDM then
            print("|cFFFFFF00  Note:|r Blizzard DM overlay is experimental. It hooks into Blizzard's")
            print("|cFFFFFF00  built-in damage meter which may change without notice. Only active")
            print("|cFFFFFF00  outside of combat. Report issues: /dilvl debug")
        end

    elseif msg == "blizztrace" then
        -- Toggle event trace for post-combat debugging in blizzdm.lua
        if Details_iLvlDisplay_BlizzTrace then
            Details_iLvlDisplay_BlizzTrace(true)  -- toggle + print
        else
            print("|cFF00FF00Details! iLvl Display:|r Blizz DM trace not available (blizzdm.lua not loaded)")
        end

    elseif msg == "layout" or msg == "layout inline" or msg == "layout columns" then
        if msg == "layout inline" then
            db.layout = "inline"
        elseif msg == "layout columns" then
            db.layout = "columns"
        else
            db.layout = (db.layout == "columns") and "inline" or "columns"
        end
        if db.layout == "columns" then
            ClearAllBarTags()   -- remove inline tags
            HookAllBars()       -- ensure all bars have column FontStrings
            RebuildNameIlvlMap()
            RefreshAllColumns()
        else
            ClearAllColumns()
            RebuildNameIlvlMap()
            RefreshAllBarTexts()
        end
        print("|cFF00FF00Details! iLvl Display:|r Layout: " .. db.layout)

    else
        print("|cFF00FF00Details! iLvl Display|r v" .. addonVersion)
        print("  /dilvl on|off          — Enable / disable")
        print("  /dilvl details         — Toggle iLvl on Details! bars")
        print("  /dilvl elvui on|off    — Toggle iLvl in ElvUI party frames")
        print("  /dilvl blizzdm         — Toggle iLvl on Blizzard Damage Meter")
        print("  /dilvl color           — Toggle color-coded iLvl")
        print("  /dilvl setbonus        — Toggle 2P/4P display")
        print("  /dilvl layout          — Toggle inline/columns layout")
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
    -- Resolve a player name to GUID via group roster, with ilvlCache fallback.
    -- Iterates party/raid units — O(n) but n ≤ 40, called by blizzdm.lua on
    -- UpdateName hook and event-driven refresh (not a per-frame hot-path).
    -- Handles cross-realm names: sourceName may be "Name-Realm" while
    -- UnitName() returns just "Name". Ambiguate() strips the realm suffix.
    -- Fallback: if player left the group, reverse-lookup from ilvlCache
    -- so Blizz DM can still show iLvl for past sessions.
    ResolveGUIDByName = function(name)
        if not name then return nil end
        local shortName = Ambiguate(name, "short")
        local pName = UnitName("player")
        if pName == shortName then return UnitGUID("player") end
        -- Try roster first
        local prefix, count
        if IsInRaid() then
            prefix, count = "raid", GetNumGroupMembers()
        elseif IsInGroup() then
            prefix, count = "party", GetNumGroupMembers() - 1
        end
        if prefix then
            for i = 1, count do
                local unit = prefix .. i
                if UnitName(unit) == shortName then
                    return UnitGUID(unit)
                end
            end
        end
        -- Fallback: reverse lookup from ilvlCache (players who left group)
        if ilvlCache then
            for guid, cached in pairs(ilvlCache) do
                if cached.name and Ambiguate(cached.name, "short") == shortName then
                    return guid
                end
            end
        end
        return nil
    end,
    -- Shared color function so ElvUI tag uses the same tier colors.
    GetIlvlColor = GetIlvlColor,
    -- Live db reference — elvui_tags.lua checks db.elvuiTag at call time.
    GetDb = function() return db end,
    -- Callback registry — multiple consumers (elvui_tags, blizzdm) register here.
    -- Fires on: INSPECT_READY, UpdatePlayerCache, GROUP_ROSTER_UPDATE.
    _callbacks = {},
    RegisterCallback = function(self, name, fn)
        self._callbacks[name] = fn
    end,
    UnregisterCallback = function(self, name)
        self._callbacks[name] = nil
    end,
}

-- Internal helper — call once after any cache write that should update UI.
-- Forward-declared at top of file so event handlers can reference it.
NotifyElvUI = function()
    for _, cb in pairs(Details_iLvlDisplayAPI._callbacks) do
        pcall(cb)
    end
end
