-- Details! Item Level Display — Copyright (c) 2026 HK2084. All rights reserved.
-- Licensed for private use only; see LICENSE. No redistribution of modified copies.
-- NO AI/ML USE. Permission is expressly withheld for training, embedding, indexing,
-- retrieval, code generation or any comparable use. See LICENSE clause 6.
-- util.lua — pure helpers (no addon state, no Blizzard side effects)
--
-- Functions in here read from arguments only and either return values
-- or call read-only Blizzard APIs. Anything that touches caches, db,
-- hooks, or events stays in core.lua.
--
-- LOAD ORDER: must load AFTER init.lua and BEFORE core.lua. core.lua
-- shadow-locals these so call sites stay short.

local _, ns = ...
local U = ns.util
-- secrets.lua loads before this file (see the TOC), so the guard is already
-- built. Needed by ilvlColorRow below: type() cannot see a secret, only this
-- can. (StripRealm further down still calls issecretvalue raw — routing
-- that one through here too is a separate, unrelated tidy-up.)
local isSecretValue = ns.secrets.isSecretValue

----------------------------------------------------------------
-- Shorten a name FOR DISPLAY ONLY. Unlike StripRealm this one is allowed to
-- hand back a secret: Ambiguate and FontString:SetText both carry the same
-- AllowedWhenTainted grant, so the secret never leaves the C boundary. It
-- exists because Details! shortens sealed names itself -- rebuilding a row
-- without doing the same would show "Name-Realm" where Details! showed "Name".
--
-- THE RESULT MUST NOT BE STORED, COMPARED OR USED AS A KEY by any caller.
-- If you need a name to look something up, you want StripRealm.
-- Why: dev-docs/CODE_NOTES.md#shortenfordisplay
----------------------------------------------------------------
function U.ShortenForDisplay(name)
    if name == nil then return nil end
    if not Ambiguate then return name end
    local ok, short = pcall(Ambiguate, name, "short")
    if ok and short ~= nil then return short end
    return name
end

----------------------------------------------------------------
-- Strip a realm suffix: "Fhina-Thrall" -> "Fhina".
--
-- Ambiguate's second argument is the CONTEXT to ambiguate FOR: "short" drops
-- the realm, "none" hands the full name back untouched. We asked for "none"
-- for months and wondered why nothing ever matched.
--
-- SECRET SAFETY: check with issecretvalue, NEVER type() -- a secret string
-- still reports "string", and this result feeds a table key in core.lua.
-- Ambiguate is AllowedWhenTainted, so a secret in means a secret out.
-- Why: dev-docs/CODE_NOTES.md#striprealm
----------------------------------------------------------------
function U.StripRealm(name)
    if not name or type(name) ~= "string" then return name end
    if issecretvalue and issecretvalue(name) then return name end
    if Ambiguate then
        local short = Ambiguate(name, "short")
        -- Secret check BEFORE the comparison: Lua evaluates `and` left to
        -- right, so `short ~= name` ran first and would have thrown on a
        -- secret — the guard sat behind the operation it was meant to protect.
        if short and type(short) == "string"
           and not (issecretvalue and issecretvalue(short))
           and short ~= name then
            return short
        end
    end
    return name:match("^([^%-]+)") or name
end

----------------------------------------------------------------
-- iLvl colour by gear tier, DERIVED from Blizzard's mythic+ reward curve:
-- those numbers ARE the season and Blizzard keeps them current, so we inherit
-- that for free. A fixed table cannot survive a season change -- the old one
-- put 43 % of everyone into the top band. Three boundaries come straight from
-- the curve; the three above it are upgrade-rank offsets on its ceiling.
-- Why: dev-docs/CODE_NOTES.md#ilvl-colors
--
-- U.ILVL_COLORS below is the FALLBACK for when the API says nothing, and it is
-- A SNAPSHOT THAT WILL ROT. Refresh it at every season start:
--   /run for _,k in ipairs({2,6,10}) do print(k, C_MythicPlus.GetRewardLevelFromKeystoneLevel(k)) end
--   /run for i=1,17 do local l=GetInventoryItemLink("player",i) local u=l and C_Item.GetItemUpgradeInfo(l) if u and u.trackString then print(u.trackString,u.currentLevel.."/"..u.maxLevel,(C_Item.GetDetailedItemLevelInfo(l))) end end
--
-- One table, two readers: text channels need the escape sequence, Grid2 needs
-- numbers. Keep the thresholds in ONE place -- typing them twice is how the
-- Grid2 channel ended up permanently white. High to low, last row catches all.
----------------------------------------------------------------
U.ILVL_COLORS = {
    {328, "00CCFF", 0.000, 0.800, 1.000}, -- heirloom cyan    (ceiling +10, myth 4/6)
    {324, "E6CC80", 0.902, 0.800, 0.502}, -- artifact gold    (ceiling +6,  myth 3/6)
    {321, "FF8000", 1.000, 0.502, 0.000}, -- legendary orange (ceiling +3,  hero 6/6)
    {318, "A335EE", 0.639, 0.208, 0.933}, -- epic purple      (key +10, the ceiling)
    {311, "0070DD", 0.000, 0.439, 0.867}, -- rare blue        (key +6)
    {300, "1EFF00", 0.118, 1.000, 0.000}, -- uncommon green   (floor - 5)
    {0,   "9D9D9D", 0.616, 0.616, 0.616}, -- poor grey
}

-- Key levels the boundaries hang on, highest first, and the quality each maps
-- to. Never pick these freely: the reward table has holes -- measured
-- 2026-09-17, key 8 returns 305, BELOW both key 7 and key 6.
local BAND_KEYS = {10, 6}
local BAND_QUALITY = {4, 3}         -- epic, rare

-- THE CURVE ONLY COVERS THE BOTTOM HALF. Keys 11..20 all return the same 318 as
-- key 10, so everything above the ceiling has to be placed by upgrade rank.
-- Measured 2026-09-20 off equipped gear via C_Item.GetItemUpgradeInfo (it needs
-- an itemLink; an item ID returns zeroes): hero 6/6 = 321 = ceiling + 3, and
-- myth 6/6 = 334 = ceiling + 16. The reward curve itself IS the hero track --
-- 305/308/311/315/318 are hero 1..5 -- so the rungs run +3,+3,+4 repeating.
--
-- That is why the old top band was wrong rather than merely generous: it sat at
-- the ceiling and called itself "beyond mythic+", but hero 6/6 is 321 and comes
-- out of mythic+ alone. Measured against 184 real cache entries it held 58.7 %.
-- Offsets, highest first, each paired with its quality.
local ABOVE_CEILING = {
    {10, 7},    -- myth 4/6  -> heirloom, the aspirational band
    { 6, 6},    -- myth 3/6  -> artifact, first rung above a full hero set
    { 3, 5},    -- hero 6/6  -> legendary, the real mythic+ ceiling
}

local FLOOR_KEY = 2                 -- the season floor, hero 1/6
local UNCOMMON_BELOW_FLOOR = 5      -- the only invented number left
local PLAUSIBLE_MIN = 200           -- see validation below

-- Nil until first use, then a table in U.ILVL_COLORS' shape, or `false`
-- meaning "asked, got nothing usable, using the fallback".
--
-- `false` used to be final until the next loading screen. It cannot be: on a
-- cold login the reward levels are NOT loaded yet when we first ask, so the
-- very first attempt always fails and the whole session then runs on the
-- fallback scale. That shipped in 1.5.8 and hit live on season 2 launch day --
-- everyone above 280 painted orange, which is the exact rot the derived scale
-- exists to prevent. See U.RetryIlvlBands below.
local derivedBands = nil

-- Bounded, because the retry is driven by an event that our own request
-- provokes. Without a cap a client that never gets reward data would ping-pong
-- request -> event -> request forever.
local MAX_RETRIES = 4
local retries = 0
local requested = false

local function qualityColor(quality)
    if not (C_Item and C_Item.GetItemQualityColor) then return nil end
    local ok, r, g, b = pcall(C_Item.GetItemQualityColor, quality)
    -- isSecretValue BEFORE the arithmetic below: pcall covers the call, not the
    -- multiplication, and a secret number reports type "number" (see the same
    -- rule spelled out at ilvlColorRow).
    if not ok or type(r) ~= "number" or type(g) ~= "number" or type(b) ~= "number"
       or isSecretValue(r) or isSecretValue(g) or isSecretValue(b) then
        return nil
    end
    return r, g, b, format("%02X%02X%02X", r * 255 + 0.5, g * 255 + 0.5, b * 255 + 0.5)
end

local function rewardFor(keyLevel)
    if not (C_MythicPlus and C_MythicPlus.GetRewardLevelFromKeystoneLevel) then return nil end
    local ok, lvl = pcall(C_MythicPlus.GetRewardLevelFromKeystoneLevel, keyLevel)
    -- A ZERO IS MORE DANGEROUS THAN A NIL HERE, which is why this tests the
    -- value and not just its presence. Measured 2026-08-17:
    -- GetRewardLevelForDifficultyLevel(10) returned endOfRunRewardLevel = 0.
    -- A zero ceiling would make every threshold negative and paint EVERY player
    -- artifact — the exact inverse of what this feature is for. An API that
    -- goes quiet must disable the feature, never flip it.
    -- isSecretValue BEFORE the comparison, same reason as in qualityColor: the
    -- pcall guards the call, `lvl < PLAUSIBLE_MIN` sits outside it.
    if not ok or type(lvl) ~= "number" or isSecretValue(lvl)
       or lvl < PLAUSIBLE_MIN then return nil end
    return lvl
end

local function buildBands()
    local rows, prev = {}, nil
    for i = 1, #BAND_KEYS do
        local lvl = rewardFor(BAND_KEYS[i])
        if not lvl then return false end
        -- Strictly descending, or the curve is not a curve and we do not
        -- understand it well enough to colour by it.
        if prev and lvl >= prev then return false end
        prev = lvl
        local r, g, b, hex = qualityColor(BAND_QUALITY[i])
        if not hex then return false end
        rows[i] = {lvl, hex, r, g, b}
    end

    -- The floor hangs on its own key rather than on the band above it: the
    -- season floor is a number Blizzard sets, not an offset from our lowest band.
    local floorLvl = rewardFor(FLOOR_KEY)
    if not floorLvl or floorLvl >= prev then return false end
    local floor = floorLvl - UNCOMMON_BELOW_FLOOR
    if floor <= 0 then return false end
    local r, g, b, hex = qualityColor(2)   -- uncommon
    if not hex then return false end
    rows[#rows + 1] = {floor, hex, r, g, b}

    r, g, b, hex = qualityColor(0)         -- poor, catch-all
    if not hex then return false end
    rows[#rows + 1] = {0, hex, r, g, b}

    -- The above-ceiling bands, and DELIBERATELY NOT FATAL: they are refinements,
    -- the curve-derived ones are the feature. A `return false` here would drop
    -- the whole derived scale back to the rotting fallback over a missing colour.
    -- Walked back to front so each insert at 1 leaves them descending.
    local ceiling = rows[1][1]
    for i = #ABOVE_CEILING, 1, -1 do
        local offset, quality = ABOVE_CEILING[i][1], ABOVE_CEILING[i][2]
        local ar, ag, ab, ahex = qualityColor(quality)
        if ahex then
            table.insert(rows, 1, {ceiling + offset, ahex, ar, ag, ab})
        end
    end

    return rows
end

-- Nothing asks the server for the season reward levels on its own. Blizzard's
-- own UI does not assume they are there either -- Blizzard_WeeklyRewards.lua
-- says so in as many words ("we might not have reward data available") -- and
-- both ChallengesUI:OnShow and WeeklyRewards:FullRefresh call RequestMapInfo()
-- and then wait for CHALLENGE_MODE_MAPS_UPDATE. We ask exactly once per reset,
-- which is what turns a permanent fallback into a fallback that lasts a second.
local function requestSeasonData()
    if requested then return end
    requested = true
    if C_MythicPlus and C_MythicPlus.RequestMapInfo then
        pcall(C_MythicPlus.RequestMapInfo)
    end
end

-- Called by core.lua on login. Deliberately NOT cached across sessions: a
-- stored ceiling that a patch has moved would be wrong in the one direction
-- nobody checks, and this costs ten API calls once per loading screen.
function U.ResetIlvlBands()
    derivedBands = nil
    retries = 0
    requested = false
end

local function ilvlBands()
    if derivedBands == nil then
        derivedBands = buildBands()
        if not derivedBands then requestSeasonData() end
    end
    return derivedBands or U.ILVL_COLORS
end

-- Called by core.lua when CHALLENGE_MODE_MAPS_UPDATE reports that the season
-- data arrived. Returns true only when the scale actually changed from
-- fallback to derived, so the caller repaints once and not on every event.
function U.RetryIlvlBands()
    if derivedBands then return false end        -- already derived, nothing to do
    if retries >= MAX_RETRIES then return false end
    retries = retries + 1
    derivedBands = nil
    return ilvlBands() ~= U.ILVL_COLORS
end

-- Exposed for /dilvl debug so the dump can show which scale is in force.
function U.GetIlvlBands()
    local b = ilvlBands()
    return b, (b ~= U.ILVL_COLORS)
end

local function ilvlColorRow(ilvl)
    local bands = ilvlBands()
    -- PUBLIC entry point: GetIlvlColor and GetIlvlColorRGB below are re-exported
    -- on Details_iLvlDisplayAPI, so this runs on values we did not produce.
    -- `ilvl >= row[1]` throws for nil AND for a string, and cached.ilvl comes
    -- straight out of SavedVariables. type() alone is not enough either: a
    -- SECRET number reports "number" and the comparison would still throw.
    -- Grey, never nil — every caller concatenates or unpacks the return
    -- value, so nil would only move the throw one line down into the caller.
    if type(ilvl) ~= "number" or isSecretValue(ilvl) then
        return bands[#bands]
    end
    for i = 1, #bands do
        local row = bands[i]
        if ilvl >= row[1] then return row end
    end
    return bands[#bands]
end

function U.GetIlvlColor(ilvl)
    return "|cFF" .. ilvlColorRow(ilvl)[2]
end

-- r, g, b, a for widget APIs that take numbers (Grid2 SetTextColor).
function U.GetIlvlColorRGB(ilvl)
    local row = ilvlColorRow(ilvl)
    return row[3], row[4], row[5], 1
end

----------------------------------------------------------------
-- Tier-set detection.
--
-- Only the 5 slots that can physically hold tier pieces. Checking all
-- 16 slots causes false positives because rings, trinkets, weapons,
-- cloaks etc. can also have non-zero setIDs in Midnight (cosmetic
-- sets, crafted item families). Tier bonuses are exclusively Head/
-- Shoulder/Chest/Legs/Hands — restricting to these 5 slots eliminates
-- false positives.
----------------------------------------------------------------
U.TIER_SLOTS = {1, 3, 5, 7, 10} -- Head, Shoulder, Chest, Legs, Hands

-- Tier setIDs per class, confirmed in-game via item tooltip.
-- GetSetBonusText() was removed in 12.0, so this whitelist replaces it: PvP
-- sets sit outside the range and are ignored for free. Extend it per tier.
--
-- CURRENT_TIER_SEASON is which season is RUNNING -- not what people are
-- wearing. A raid full of season-1 tier says nothing about that; lagging
-- behind is exactly the transition this colouring exists to show. Hand-set on
-- purpose, not distrust: the set IDs are hand-kept anyway, and getting this
-- wrong mislabels every set in the raid at once. /dilvl debug prints both this
-- and the client's own answer, and flags a mismatch.
-- Why: dev-docs/CODE_NOTES.md#tier-season
U.CURRENT_TIER_SEASON = 2

U.MIDNIGHT_TIER_SETS = {
    [1978] = 1, -- Death Knight   (Relentless Rider's Lament)
    [1979] = 1, -- Demon Hunter   (Devouring Reaver's Sheathe)
    [1980] = 1, -- Druid          (Sprouts of the Luminous Bloom)
    [1981] = 1, -- Evoker         (Livery of the Black Talon)
    [1982] = 1, -- Hunter         (Primal Sentry's Camouflage)
    [1983] = 1, -- Mage           (Voidbreaker's Accordance)
    [1984] = 1, -- Monk           (Way of Ra-den's Chosen)
    [1985] = 1, -- Paladin        (Luminant Verdict's Vestments)
    [1986] = 1, -- Priest         (Blind Oath's Burden)
    [1987] = 1, -- Rogue          (Motley of the Grim Jest)
    [1988] = 1, -- Shaman         (Mantle of the Primal Core) ← confirmed
    [1989] = 1, -- Warlock        (Reign of the Abyssal Immolator)
    [1990] = 1, -- Warrior        (Rage of the Night Ender)

    -- Season 2 (patch 12.1). Read straight out of the live client with
    -- /dilvl sets 2054 2454 on 2026-08-13, before the season opened: Blizzard
    -- ships the item-set table with the patch, so the IDs exist as soon as the
    -- patch does — a season gates when items DROP, not when they exist.
    -- 2055-2067 is contiguous and 13 wide, mirroring season 1's 1978-1990, and
    -- the names line up with the same alphabetical class order. The class
    -- comments are therefore inferred from position + name, not from an
    -- official list — they are documentation only. Detection matches on the ID,
    -- so a mislabelled comment cannot cause a wrong tag.
    -- Deliberately NOT included: 2070 ("Biss von Zul'jan"). The gap at
    -- 2068-2069 puts it outside the tier run.
    [2055] = 2, -- Death Knight   (Tiegel des unheilvollen Grabritters)
    [2056] = 2, -- Demon Hunter   (Jagd des abyssischen Verdammnishundes)
    [2057] = 2, -- Druid          (Borke des geheimnisvollen Traumbehüters)
    [2058] = 2, -- Evoker         (Echo des Unheils)
    [2059] = 2, -- Hunter         (Hinterhalt der lauernden Viper)
    [2060] = 2, -- Mage           (Gewand des urweltlichen Leyhüters)
    [2061] = 2, -- Monk           (List des Affenkönigs)
    [2062] = 2, -- Paladin        (Strahlen der geweihten Flamme)
    [2063] = 2, -- Priest         (Gewandung des kosmischen Büßers)
    [2064] = 2, -- Rogue          (Hexgeflecht des auserkorenen Blutschlächters)
    [2065] = 2, -- Shaman         (Prophezeiung des Schlangenorakels)
    [2066] = 2, -- Warlock        (Gesprengte Fesseln des verdammten Nekrolythen)
    [2067] = 2, -- Warrior        (Herrschaft des Jadekriegsfürsten)
}

----------------------------------------------------------------
-- Set bonus for an inspected unit: reads the 5 tier slots, counts per setID.
-- Returns: bonus ("4P" / "2P" / nil), complete (boolean).
-- Must be called synchronously during INSPECT_READY while data is loaded.
--
-- `complete` is the important half. GetItemInfo is ASYNCHRONOUS, so a bare nil
-- cannot tell "wears no tier" from "could not read it yet" -- and writing that
-- nil to the cache erased correct 4P readings after a loading screen.
-- complete = false means: keep what you had, try again later.
-- Why: dev-docs/CODE_NOTES.md#setbonus-complete
----------------------------------------------------------------
function U.GetSetBonusForUnit(unit)
    local setPieces = {} -- setID -> count
    local complete = true
    local slotsWithItem = 0

    for _, slotID in ipairs(U.TIER_SLOTS) do
        -- GetInventoryItemID returns itemID directly as a number — no link
        -- parsing needed, immune to item link format changes.
        local itemID = GetInventoryItemID(unit, slotID)
        if itemID and itemID > 0 then
            slotsWithItem = slotsWithItem + 1
            -- Ask the client whether it HAS the data, instead of guessing from
            -- the result. Neither a nil setID nor a present name can answer it:
            -- an item genuinely without a set returns setID = nil legitimately
            -- (the player's legs do exactly that), and an item can hand back its
            -- name while setID is still missing. A first attempt tested `name`
            -- and was wrong in precisely that way — live on 2026-08-15 the dump
            -- read "live: 4P (complete=true) stored: false", i.e. a read that
            -- called itself complete had written the wrong answer moments before.
            -- C_Item.GetItemInfo returns 18 values; setID is at position 16.
            local ok, name, _, _, _, _, _, _, _, _, _, _, _, _, _, _, setID = pcall(C_Item.GetItemInfo, itemID)

            -- Decide whether this slot was READABLE, before trusting its answer.
            -- If IsItemDataCachedByID is unavailable for any reason, fall back to
            -- the name heuristic rather than reporting permanent incompleteness —
            -- a hard "never complete" would freeze the set bonus forever, which
            -- is a worse failure than the one being fixed.
            local readable
            if C_Item.IsItemDataCachedByID then
                local cachedOk, isCached = pcall(C_Item.IsItemDataCachedByID, itemID)
                readable = cachedOk and isCached or false
            else
                readable = (name ~= nil)
            end

            if not ok or not readable then
                complete = false
            elseif setID and U.MIDNIGHT_TIER_SETS[setID] then
                setPieces[setID] = (setPieces[setID] or 0) + 1
            end
        end
    end

    -- Not a single tier slot reported an item. For a unit whose gear we are
    -- reading at all this means the inventory is not populated yet, not that
    -- the player is naked — GetInventoryItemID answers nil for both. Observed
    -- live on 2026-08-15 when LEAVING an instance: every slot came back nil,
    -- the loop found nothing, called itself complete and wrote false over a
    -- correct 4P. Same confusion as the two attempts above, one level lower:
    -- "no data" read as "no item".
    --
    -- Deliberately "none at all" rather than "any missing": unequipping a
    -- single tier piece must still be detected and must still be able to move
    -- 4P down to 2P. Only the all-nil case is unambiguous.
    if slotsWithItem == 0 then
        complete = false
    end

    -- Compare the BONUS, never the piece count: three pieces and two pieces
    -- both grant 2P, so counting pieces let one set "beat" another it had in
    -- fact tied with. The strongest single set wins and counts are never summed
    -- across sets (2 old + 2 new is 2P, not 4P); on a tie the current season
    -- wins. Every set granting a bonus is reported, not just the best -- a tier
    -- change can carry two live bonuses at once.
    -- Why: dev-docs/CODE_NOTES.md#setbonus-auswahl
    local function bonusTier(count)
        if count >= 4 then return 4 elseif count >= 2 then return 2 end
        return 0
    end

    local granting = {}
    for setID, count in pairs(setPieces) do
        local tier = bonusTier(count)
        if tier > 0 then
            granting[#granting + 1] = {
                bonus  = (tier >= 4) and "4P" or "2P",
                season = U.MIDNIGHT_TIER_SETS[setID],
            }
        end
    end
    if #granting == 0 then return nil, complete end

    -- Oldest season first, so the display reads as a progression: what the
    -- player is leaving behind, then what they are building.
    table.sort(granting, function(a, b)
        return (a.season or 0) < (b.season or 0)
    end)

    -- Season rides INSIDE the value ("2P#1,2P#2") so all the plumbing in between
    -- stays untouched — two cache writes, a dozen StoreNameBonus calls, the
    -- persisted SavedVariables. Nothing anywhere compares this string by value;
    -- it is only ever concatenated, and every render site goes through the
    -- helpers below. Comma, not "|": that character starts a WoW colour escape.
    local parts = {}
    for _, entry in ipairs(granting) do
        parts[#parts + 1] = entry.bonus .. (entry.season and ("#" .. entry.season) or "")
    end
    return table.concat(parts, ","), complete
end

----------------------------------------------------------------
-- Set bonus display helpers.
--
-- Stored form is "4P#2", or "2P#1,2P#2" while two sets both grant a bonus.
-- Values written before seasons were tracked carry no suffix and are treated as
-- unknown season. The persisted cache still needs no migration, but it does NOT
-- render as it used to: on the coloured surfaces such an entry now shows no mark
-- at all until the next inspect rewrites it. See seasonColor below for why.
----------------------------------------------------------------
local function parseSetBonus(sb)
    if type(sb) ~= "string" or sb == "" then return nil end
    local out = {}
    for part in sb:gmatch("[^,]+") do
        local bonus, season = part:match("^(%dP)#(%d+)$")
        out[#out + 1] = { bonus = bonus or part, season = season and tonumber(season) or nil }
    end
    if #out == 0 then return nil end
    return out
end

-- Green = current season, grey = older, and NOTHING when the season is
-- unknown. Green stopped being neutral the moment grey arrived: it became a
-- claim, and pre-v1.5.6 cache entries carry no season to back it. Grey would be
-- the same unfounded claim inverted. The uncoloured surfaces (Danders, Grid2)
-- still show the bonus -- there the colour claim never arises.
-- Why: dev-docs/CODE_NOTES.md#season-color
local function seasonColor(season)
    if not season then return nil end
    if season ~= U.CURRENT_TIER_SEASON then return "|cFF9D9D9D" end
    return "|cFF00FF00"
end

-- Coloured, ready to print. Two bonuses render as two marks, oldest first:
-- "|cFF9D9D9D[2P]|r |cFF00FF00[2P]|r".
--
--   bracket     = false  drops the brackets; the columns layout has its own field.
--   primaryOnly = true   emits a single mark, for width-limited surfaces.
--
-- Returns nil when there is nothing we may show — no bonus at all, or only
-- bonuses whose season is unknown. CALLERS MUST CHECK: four of them build their
-- text by concatenation and would throw on a nil.
function U.SetBonusTag(sb, bracket, primaryOnly)
    local list = parseSetBonus(sb)
    if not list then return nil end
    if bracket == nil then bracket = true end

    if primaryOnly then
        local pick = list[1]
        for _, entry in ipairs(list) do
            if entry.season == U.CURRENT_TIER_SEASON then pick = entry break end
        end
        list = { pick }
    end

    local parts = {}
    for _, entry in ipairs(list) do
        -- A mark whose season we cannot name is skipped, not guessed. See
        -- seasonColor above for why neither colour would be honest.
        local colour = seasonColor(entry.season)
        if colour then
            local body = bracket and ("[" .. entry.bonus .. "]") or entry.bonus
            parts[#parts + 1] = colour .. body .. "|r"
        end
    end
    if #parts == 0 then return nil end
    return table.concat(parts, " ")
end

-- One bonus, no colour — for surfaces that are text-only and tight (Danders
-- overlay, Grid2 indicator), where two uncoloured marks would be unreadable.
-- Prefers the current season, since that is the one that keeps growing.
function U.SetBonusPlain(sb)
    local list = parseSetBonus(sb)
    if not list then return nil end
    for _, entry in ipairs(list) do
        if entry.season == U.CURRENT_TIER_SEASON then return entry.bonus end
    end
    return list[1].bonus
end

-- Human-readable for /dilvl output: "4P", or "2P/S1+2P/S2" when it is worth
-- spelling out. The season is shown only where it is not the current one, so
-- the ordinary line stays as short as it was.
function U.SetBonusDebug(sb)
    local list = parseSetBonus(sb)
    if not list then return nil end
    local parts = {}
    for _, entry in ipairs(list) do
        parts[#parts + 1] = entry.bonus
            .. ((entry.season and entry.season ~= U.CURRENT_TIER_SEASON)
                and ("/S" .. entry.season) or "")
    end
    return table.concat(parts, "+")
end

----------------------------------------------------------------
-- Extract a clean player name from a Details!-bar text fragment.
-- Strips: rank prefix ("1. "), existing ilvl tags, inline textures.
----------------------------------------------------------------
function U.ExtractName(text)
    if not text or type(text) ~= "string" then return nil end
    -- type() cannot detect a secret, and everything below is :match and :gsub,
    -- both of which throw on one. Today every caller filters secrets before
    -- getting here, but this is a public helper on the util table and the next
    -- channel that uses it should not have to know that.
    if issecretvalue and issecretvalue(text) then return nil end
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
