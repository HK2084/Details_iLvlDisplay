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
-- iLvl color by gear tier (legendary / epic / rare / uncommon / poor).
-- Returns a WoW color escape (no |r — caller appends).
----------------------------------------------------------------
-- One table, two readers. Channels that write coloured TEXT need the escape
-- sequence; Grid2 hands its colours to SetTextColor and needs numbers. Keeping
-- the thresholds in one place is the point — typing them twice is how the
-- Grid2 channel ended up permanently white while everything else was coloured.
-- Ordered high to low; the last row is the catch-all.
U.ILVL_COLORS = {
    {280, "FF8000", 1.000, 0.502, 0.000}, -- legendary orange
    {268, "A335EE", 0.639, 0.208, 0.933}, -- epic purple
    {255, "0070DD", 0.000, 0.439, 0.867}, -- rare blue
    {242, "1EFF00", 0.118, 1.000, 0.000}, -- uncommon green
    {0,   "9D9D9D", 0.616, 0.616, 0.616}, -- poor grey
}

local function ilvlColorRow(ilvl)
    for i = 1, #U.ILVL_COLORS do
        local row = U.ILVL_COLORS[i]
        if ilvl >= row[1] then return row end
    end
    return U.ILVL_COLORS[#U.ILVL_COLORS]
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

-- Midnight Season 1 tier setIDs per class (confirmed in-game via item
-- tooltip). GetSetBonusText() was removed in 12.0 — hardcoded whitelist
-- replaces it. Update this table when a new raid tier is added.
-- PvP gear (honor/conquest) has its own setIDs outside this range — the
-- whitelist approach means they are automatically ignored regardless of
-- their setID values.
-- Which raid season is CURRENTLY running. Season 2 opened with patch 12.1; the
-- pre-season is already part of it, so season-1 tier is the OLD set even while
-- most players are still wearing it.
--
-- That last sentence is the whole trap, and I walked into it on 2026-08-16:
-- seeing a raid full of season-1 tier, I concluded season 1 must still be
-- current and that C_MythicPlus.GetCurrentUIDisplaySeason() (which answered 2)
-- was running ahead of reality. It was not. What people are WEARING says
-- nothing about which season is running — lagging behind is precisely the
-- transition this colouring exists to show.
--
-- Still a hand-set constant rather than that API call, but for control, not
-- distrust: the set IDs below are maintained per season by hand anyway, a
-- season without a new tier would leave the two legitimately out of step, and
-- getting this wrong mislabels every set in the raid at once. /dilvl debug
-- prints both and flags a mismatch, so the API stays a cross-check.
--
-- Not derived from the set IDs either: the highest ID is not reliably the
-- current season (2070 "Biss von Zul'jan" sits outside the tier run entirely).
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
-- Set bonus detection for an inspected unit.
-- Reads item IDs from the 5 tier slots, counts pieces per setID.
-- Returns "4P", "2P", or nil.
-- Must be called synchronously during INSPECT_READY while data is loaded.
----------------------------------------------------------------
-- Returns: bonus ("4P" / "2P" / nil), complete (boolean)
--
-- `complete` is the important half. C_Item.GetItemInfo is ASYNCHRONOUS: for an
-- item the client has not cached yet it returns nothing at all, and then this
-- function cannot tell "wears no tier" apart from "could not read it yet".
-- Both used to come back as a bare nil, and every caller wrote that straight
-- into the cache — so one unlucky read right after a loading screen erased a
-- correct 4P and nothing ever put it back (reported live 2026-08-15: own [4P]
-- gone after zoning into a raid, restored only by re-equipping a piece).
--
-- complete = false means "at least one occupied tier slot did not resolve".
-- Callers must keep whatever they already had and try again later.
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

    -- The strongest SINGLE set wins — counts are never summed across sets, so
    -- 2 old + 2 new correctly reads 2P rather than 4P.
    --
    -- On a tie the current season wins. Someone wearing 2 old and 2 new pieces
    -- has both 2-piece bonuses, and the current one is the stronger of the two
    -- and the one they are moving towards, so it is the more useful of the two
    -- to show. The reverse case matters just as much and is why the strongest
    -- bonus still wins outright: 4 old + 2 new is a real 4-piece, and showing
    -- 2P there would understate the player.
    -- Every set that actually grants a bonus is reported, not just the best
    -- one. During a tier change a player can carry TWO live bonuses — 2 old
    -- pieces and 2 new ones, for instance — and showing only one of them hides
    -- exactly the state this colouring was built to make visible.
    --
    -- Compare the BONUS, never the piece count: three pieces and two pieces both
    -- grant 2P, so counting pieces made one set "beat" another it had in fact
    -- tied. Five tier slots means at most two sets can reach a bonus at once
    -- (2+2 fits, 2+2+2 does not), but nothing below assumes that.
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
-- Values written before seasons were tracked carry no suffix; they are treated
-- as unknown season and render exactly as they always did, so the persisted
-- cache needs no migration.
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

-- Green for the current season, grey for an older one, and NOTHING for a value
-- whose season we do not know.
--
-- That last case is the one that matters and it nearly shipped wrong. Before
-- seasons existed green was simply "the colour of a set bonus" — neutral, the
-- only one there was. The moment grey arrived, green stopped being neutral and
-- became a claim: "current season". Every entry already sitting in a user's
-- SavedVariables from v1.5.5 carries no season, and painting those green would
-- have asserted that claim for data that cannot support it — on the whole cache
-- at once, on the first login after the update, at exactly the moment when in
-- practice they are all last season's sets.
--
-- Nor may they be painted grey: v1.5.5 already detected season-2 sets too, so a
-- suffix-less value is season-UNKNOWN, not season-1. Grey would be the same
-- unfounded claim in the other direction.
--
-- So the coloured surfaces show nothing until the next inspect rewrites the
-- entry with a season — a missing tag is fine, a wrong one is not. The
-- uncoloured surfaces (Danders, Grid2) keep showing the bonus, because there
-- the colour claim does not arise.
--
-- 9D9D9D is already the bottom of our item-level scale and reads as dated.
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
