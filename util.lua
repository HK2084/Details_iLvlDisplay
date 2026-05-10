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
