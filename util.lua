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

----------------------------------------------------------------
-- Strip a realm suffix: "Fhina-Thrall" -> "Fhina".
--
-- WHY THIS EXISTS: we used to call Ambiguate(name, "none") directly and
-- rely on it stripping the realm. In 12.1 it returns the string UNCHANGED.
-- Proven in-game 2026-08-13: /dilvl map held 51 entries, every one a full
-- "Name-Realm" string and not a single short name, because the usual guard
--     local short = Ambiguate(name, "none"); if short ~= name then ...
-- never fired. Details! bars show only "Fhina", so nothing matched and no
-- item level appeared — while Blizzard's meter (which shows "Fhina-Thrall")
-- kept working. Nothing in Blizzard_APIDocumentationGenerated changed for
-- Ambiguate between 12.0.7 and 12.1; only the behaviour did.
--
-- Ambiguate is still TRIED FIRST on purpose: it is the sanctioned API, it
-- handles cases a plain match may not, and if Blizzard restores the old
-- behaviour this silently goes back to using it. The match is the fallback.
-- Realm names cannot contain "-", so the first segment is the character name.
----------------------------------------------------------------
-- SECRET SAFETY: type() cannot detect a secret — a secret string still reports
-- "string" (see the note in secrets.lua). Ambiguate accepts secret arguments
-- (PlayerScriptDocumentation: SecretArguments = "AllowedWhenTainted", and
-- `fullName` carries no NeverSecret flag), so a secret in means a secret out.
-- Both the input and Ambiguate's result are therefore checked with
-- issecretvalue, not type(): returning a secret here would hand it straight to
-- `nameToIlvl[shortName] = ilvl` in core.lua, and a secret table key throws.
-- Returning the input unchanged is the safe answer — callers already treat "no
-- short form" as normal.
function U.StripRealm(name)
    if not name or type(name) ~= "string" then return name end
    if issecretvalue and issecretvalue(name) then return name end
    if Ambiguate then
        local short = Ambiguate(name, "none")
        if short and type(short) == "string" and short ~= name
           and not (issecretvalue and issecretvalue(short)) then
            return short
        end
    end
    return name:match("^([^%-]+)") or name
end

----------------------------------------------------------------
-- iLvl color by gear tier (legendary / epic / rare / uncommon / poor).
-- Returns a WoW color escape (no |r — caller appends).
----------------------------------------------------------------
function U.GetIlvlColor(ilvl)
    if ilvl >= 280 then return "|cFFFF8000"
    elseif ilvl >= 268 then return "|cFFA335EE"
    elseif ilvl >= 255 then return "|cFF0070DD"
    elseif ilvl >= 242 then return "|cFF1EFF00"
    else return "|cFF9D9D9D"
    end
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

-- Midnight Season 1 tier setIDs per class (confirmed in-game via item
-- tooltip). GetSetBonusText() was removed in 12.0 — hardcoded whitelist
-- replaces it. Update this table when a new raid tier is added.
-- PvP gear (honor/conquest) has its own setIDs outside this range — the
-- whitelist approach means they are automatically ignored regardless of
-- their setID values.
U.MIDNIGHT_TIER_SETS = {
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
    [2055] = true, -- Death Knight   (Tiegel des unheilvollen Grabritters)
    [2056] = true, -- Demon Hunter   (Jagd des abyssischen Verdammnishundes)
    [2057] = true, -- Druid          (Borke des geheimnisvollen Traumbehüters)
    [2058] = true, -- Evoker         (Echo des Unheils)
    [2059] = true, -- Hunter         (Hinterhalt der lauernden Viper)
    [2060] = true, -- Mage           (Gewand des urweltlichen Leyhüters)
    [2061] = true, -- Monk           (List des Affenkönigs)
    [2062] = true, -- Paladin        (Strahlen der geweihten Flamme)
    [2063] = true, -- Priest         (Gewandung des kosmischen Büßers)
    [2064] = true, -- Rogue          (Hexgeflecht des auserkorenen Blutschlächters)
    [2065] = true, -- Shaman         (Prophezeiung des Schlangenorakels)
    [2066] = true, -- Warlock        (Gesprengte Fesseln des verdammten Nekrolythen)
    [2067] = true, -- Warrior        (Herrschaft des Jadekriegsfürsten)
}

----------------------------------------------------------------
-- Set bonus detection for an inspected unit.
-- Reads item IDs from the 5 tier slots, counts pieces per setID.
-- Returns "4P", "2P", or nil.
-- Must be called synchronously during INSPECT_READY while data is loaded.
----------------------------------------------------------------
function U.GetSetBonusForUnit(unit)
    local setPieces = {} -- setID -> count

    for _, slotID in ipairs(U.TIER_SLOTS) do
        -- GetInventoryItemID returns itemID directly as a number — no link
        -- parsing needed, immune to item link format changes.
        local itemID = GetInventoryItemID(unit, slotID)
        if itemID and itemID > 0 then
            -- C_Item.GetItemInfo returns 18 values; setID is at position 16.
            local ok, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, setID = pcall(C_Item.GetItemInfo, itemID)
            if ok and setID and U.MIDNIGHT_TIER_SETS[setID] then
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

----------------------------------------------------------------
-- Extract a clean player name from a Details!-bar text fragment.
-- Strips: rank prefix ("1. "), existing ilvl tags, inline textures.
----------------------------------------------------------------
function U.ExtractName(text)
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
