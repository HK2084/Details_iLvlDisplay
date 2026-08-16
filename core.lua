-- Details! Item Level Display — Copyright (c) 2026 HK2084. All rights reserved.
-- Licensed for private use only; see LICENSE. No redistribution of modified copies.
local addonName, ns = ...
local addonVersion = ns.version

-- Defaults, position-key allowlist, and login-hint registry live in init.lua
-- (ns.* tables). Core reads them via locals so existing references stay
-- unchanged. Add new defaults / hints / position keys in init.lua.
local defaults      = ns.defaults
local POS_KEYS_SET  = ns.POS_KEYS_SET
local LOGIN_HINTS   = ns.LOGIN_HINTS

local db

local function ShowLoginHints()
    local delay = 8
    for _, hint in ipairs(LOGIN_HINTS) do
        if not db["seenHint_" .. hint.key] and (not hint.gate or hint.gate()) then
            db["seenHint_" .. hint.key] = true
            local msg = hint.msg
            C_Timer.After(delay, function()
                print("|cFF00FF00Details! iLvl Display|r |cFFFFD100New:|r " .. msg)
            end)
            delay = delay + 4
        end
    end
end
local ilvlCache -- points to db.ilvlCache after ADDON_LOADED (persistent SavedVariables)
local setBonusCache = {} -- guid -> "2P" / "4P" / false (no bonus) / nil (never inspected); persisted after ADDON_LOADED
local nameToIlvl = {}    -- "PlayerName" -> ilvl
local nameToSetBonus = {} -- "PlayerName" -> "2P" / "4P" / nil (mirrors nameToIlvl, O(1) BuildTag lookup)
-- TWO different decisions, so two different numbers. They used to be one
-- constant, which meant an entry was never merely "worth refreshing" — the
-- moment it qualified for a refresh it also qualified for deletion.
--
-- CACHE_REFRESH  when to ask for fresh data if the player is reachable.
-- CACHE_DISCARD  when to actually throw data away. Deliberately huge.
--
-- Why discarding is nearly always wrong: RebuildNameIlvlMap renders a tag from
-- `cached.ilvl and cached.name` and never looks at the timestamp, so age is
-- invisible to the display — deletion is the ONLY thing that makes a tag
-- disappear. And the entries that age out first are the players who already
-- left the group, which is exactly the case the cache-fallback exists for.
-- Those cannot be re-inspected either: QueueGroupInspect requires
-- UnitExists(unit) in the live roster. So the old code applied a
-- "re-inspect soon" TTL to data that was not re-inspectable, and every purge
-- permanently destroyed tags it could never rebuild. Measured on 2026-08-13:
-- 51 -> 21 -> 9 entries in one evening, all still well inside the old TTL.
local CACHE_REFRESH = 7200        -- 2h: re-inspect if we can reach them
local CACHE_DISCARD = 7 * 24 * 3600 -- 7 days: only then is it really junk
local lastMapID = nil -- track zone changes to detect new instances
local inspectQueue = {}
local isInspecting = false
local pendingInspect = {}      -- guid -> true for every NotifyInspect WE fired (a set, not a scalar: sweeps overlap)
local inspectGeneration  = 0   -- bumped by QueueGroupInspect; invalidates in-flight safety-timeout closures from a prior sweep
local lastManualInspectTime = 0 -- GetTime() of last INSPECT_READY we didn't trigger (ElvUI-safe guard)
local lastInspectInfo = nil -- {name, ilvl, source, time} last completed inspect for debug
local detailsReady = false
-- Weak keys, same pattern as danders_integration.lua: Details! throws its bar
-- FontStrings away on window close/reopen. With strong keys this table pinned
-- every dead FontString for the session, and the "hooks" count in /dilvl debug
-- only ever grew -- so it measured history, not live hooks.
local hookedFontStrings = setmetatable({}, {__mode = "k"}) -- FontString -> true
local hookedInstances = {}   -- track which Details! instance frames have OnSizeChanged hooked
local HookInstanceResize     -- forward declaration (assigned after OnDetailsResize is defined)

-- Resize-hook diagnostics (surfaced in /dilvl debug). Added in v1.5.3 because the
-- hook silently never installed for ~4 months: we read `instance.baseFrame`, but
-- Details! spells the field `instance.baseframe` (lowercase f, classes/class_instance.lua:2508).
-- Lua field lookup is case-sensitive, so the guard below always took the early return.
-- These counters make "did the hook actually install / fire?" observable instead of
-- something you can only discover by reading Details' source.
local resizeStats = {
    attempts = 0,       -- HookInstanceResize() calls
    installed = 0,      -- OnSizeChanged hooks actually attached
    noFrame = 0,        -- instance exposed no usable frame field (the old silent failure)
    fired = 0,          -- OnSizeChanged callbacks received from Details!
    refreshed = 0,      -- debounced full refreshes completed
    field = nil,        -- which field resolved last: "baseframe" / "baseFrame" / "frame"
}
local barCleanText = {}    -- fontString -> last clean text set by Details! (never our injected text)
local isOurSetText = false -- prevent recursion in SetText hook
local mapDirty = false -- rebuild nameToIlvl only when new inspect data arrived
local tickerStarted = false -- true only once C_Timer.NewTicker actually returned (what /dilvl debug reports)
local bootstrapArmed = false -- guard against scheduling the 3s login setup twice on rapid zoning
local selfBonusRetries = 0 -- bounded re-reads when our own tier items are not in the item cache yet
local NotifyElvUI -- forward declaration; assigned after Details_iLvlDisplayAPI is built
-- Defaults-merge / schema-migration / validators are defined further down
-- but referenced inside the ADDON_LOADED OnEvent closure, so they need
-- upvalue forward-declarations here (else Lua binds the names as globals
-- at closure-compile time and the calls silently no-op).
local CURRENT_SCHEMA_VERSION
local VALIDATORS
local RecursiveDefaultsMerge, MigrateSchema, ValidateDb
local openRaidLib = nil -- LibOpenRaid-1.0 handle; assigned after ADDON_LOADED if available
local barColumns = {}       -- bar -> {ilvlFS, tierFS} (custom column FontStrings for layout="columns")
local fsBar = {}            -- lineText1 fontString -> owning bar (for per-window gating in the FontString-only refresh path)
local columnRefreshPending = false -- debounce flag for next-frame column refresh
local perfStats = {calls = 0, totalMs = 0, lastMs = 0, peak = 0} -- column refresh perf tracking
local cachedColLayout = nil -- cached {leftA, leftW, secA, secW, gap, yOff} from last good measurement

-- Safety kill-switch: if our Details!-bar hooks error too many times,
-- disable JUST the Details!-bar feature (db.showInDetails = false). The
-- master switch (db.enabled) and other integrations (BlizzDM, ElvUI,
-- Grid2, Danders) are NOT affected — a Details! hook bug must not take
-- down the user's working overlays elsewhere.
--
-- Per-feature isolation: this counter is SCOPED to Details!-bar hooks
-- only. Other integrations carry their own per-feature counters and
-- never share state with this one:
--   - blizzdm.lua          BlizzDM:* error counter         → db.blizzDM
--   - danders_integration  STATE.dandersErrors             → db.dandersText
--   - ElvUI / Grid2        _callbackErrors[name] below     → per-callback unregister
-- A bug in one feature can never auto-disable another.
local detailsBarErrors     = 0
local DETAILS_BAR_ERROR_LIMIT = 5

-- Per-callback fault isolation (forward-declared so /dilvl debug at
-- line ~1561 can read them). Used by NotifyElvUI further down.
local CALLBACK_ERROR_LIMIT = 5
local _callbackErrors = {}      -- name -> consecutive error count
local _callbackErrorLogged = {} -- name -> bool (logged-once flag)
local _callbackParked = {}      -- name -> fn, set aside on auto-unregister so it can be restored
local function SafeCall(fn, ...)
    if detailsBarErrors >= DETAILS_BAR_ERROR_LIMIT then return end
    local ok, err = pcall(fn, ...)
    if not ok then
        detailsBarErrors = detailsBarErrors + 1
        if detailsBarErrors >= DETAILS_BAR_ERROR_LIMIT then
            if db then db.showInDetails = false end
            -- Route through WoW's error handler → BugSack picks it up (#13)
            geterrorhandler()("Details! iLvl Display: too many Details!-bar hook errors — Details!-bars auto-disabled. Recovery: /dilvl details. Other integrations still active. Last error: " .. tostring(err))
        end
    end
end

-- Column layout constants
local COL_ILVL_WIDTH = 36   -- px max text width for iLvl column (truncation threshold)
local COL_TIER_WIDTH = 28   -- px max text width for tier column (truncation threshold)
local MIN_NAME_WIDTH = 50   -- px minimum for player name before hiding columns

-- Danders font-size bounds. Clamped at the slash boundary so the
-- integration's applyFontSizeToAll always gets a sane value.
local DANDERS_FONT_MIN = 6
local DANDERS_FONT_MAX = 30
local DETAILS_FONT_MIN = 6   -- /dilvl details size lower bound (0 = "auto, match Details' font")
local DETAILS_FONT_MAX = 30  -- upper bound

---------------------------------------------------------------
-- Secret-value defense layer (WoW 12.0+) lives in secrets.lua.
-- Shadow-locals so the call sites below don't need to know about ns.
-- Add new guards to ns.secrets in secrets.lua — not inline here.
---------------------------------------------------------------
local secrets             = ns.secrets
local isSecretValue       = secrets.isSecretValue
local _hasanysecretvalues = secrets._hasanysecretvalues
local SafeUnitIsUnit      = secrets.SafeUnitIsUnit
local SafeUnitName        = secrets.SafeUnitName
local SafeUnitGUID        = secrets.SafeUnitGUID
local IsInCombatSafe      = secrets.IsInCombatSafe
local MayBeInCombat       = secrets.MayBeInCombat
local InCombatRaw         = secrets.InCombatRaw
local secretStats         = secrets.stats

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
-- Resolve a GUID to its "Name-Realm" form via the current group
-- roster (or self). Returns nil when the GUID is not in the
-- group — caller decides the fallback.
--
-- Why this exists: the [DETAILS]-source cache write path
-- (GetIlvlForGuid → Details.ilevel.GetIlvl) and the
-- RebuildNameIlvlMap actor-scan path historically stored
-- cached.name as the bare Details! actor.displayName/nome,
-- which for cross-realm players often arrives without realm.
-- Inspect/LoR paths store full Name-Realm. Asymmetric cache.
-- After group disband, BlizzDM frames carry the full
-- "Name-Realm" sourceName, so the strict-equality reverse-
-- lookup in ResolveGUIDByName couldn't match the bare cached
-- entries → false GAVE-UP for historical cross-realm frames.
--
-- This helper enriches new writes with the full Name-Realm
-- form when the player is in the current roster.
-- O(n) over n ≤ 40 — only on event-driven cache writes,
-- never on the per-frame Details!-bar hot path.
---------------------------------------------------------------
local function ResolveFullNameByGuid(guid)
    if not guid then return nil end
    if guid == SafeUnitGUID("player") then
        local n, r = SafeUnitName("player")
        if not n then return nil end
        return (r and r ~= "") and (n .. "-" .. r) or n
    end
    local prefix, count = GetGroupInfo()
    for i = 1, count do
        local unit = prefix .. i
        if SafeUnitGUID(unit) == guid then
            local n, r = SafeUnitName(unit)
            if not n then return nil end
            return (r and r ~= "") and (n .. "-" .. r) or n
        end
    end
    return nil
end

---------------------------------------------------------------
-- Pure helpers (color/tier/extract) live in util.lua.
-- Shadow-locals so call sites stay short. Add new helpers to ns.util
-- in util.lua — not inline here.
---------------------------------------------------------------
local util               = ns.util
local GetIlvlColor       = util.GetIlvlColor
local GetSetBonusForUnit = util.GetSetBonusForUnit
local TIER_SLOTS         = util.TIER_SLOTS
local MIDNIGHT_TIER_SETS = util.MIDNIGHT_TIER_SETS
local SetBonusTag        = util.SetBonusTag
-- Realm stripper. Never Ambiguate directly — see util.StripRealm.
local StripRealm         = util.StripRealm

---------------------------------------------------------------
-- iLvl lookup by GUID
---------------------------------------------------------------
local function GetIlvlForGuid(guid)
    if not guid then return nil end

    -- Player's own GUID: GetAverageItemLevel is the most accurate source (no
    -- inspect needed) and we skip the Details API for self (it can be stale in
    -- combat). But honor a fresh cached self entry instead of recomputing AND
    -- allocating a new table on every column refresh — that was the only real
    -- per-refresh allocation on the hot path. Equipment-change events
    -- (PLAYER_EQUIPMENT_CHANGED / UNIT_INVENTORY_CHANGED -> UpdatePlayerCache)
    -- refresh it instantly; this short TTL is just a backstop re-sync.
    if guid == SafeUnitGUID("player") then
        local cachedSelf = ilvlCache[guid]
        if cachedSelf and cachedSelf.source == "self" and (time() - cachedSelf.time) < 30 then
            return cachedSelf.ilvl
        end
        local _, equipped = GetAverageItemLevel()
        if equipped and equipped > 0 then
            local ilvl = math.floor(equipped)
            ilvlCache[guid] = {ilvl = ilvl, time = time(), source = "self"}
            return ilvl
        end
    end

    local cached = ilvlCache[guid]
    if cached and (time() - cached.time < CACHE_REFRESH) then
        return cached.ilvl
    end

    -- Details public API (fallback for other players)
    if Details and Details.ilevel and Details.ilevel.GetIlvl then
        local ok, data = pcall(Details.ilevel.GetIlvl, Details.ilevel, guid)
        if ok and data and data.ilvl and data.ilvl > 0 then
            -- Adopt Details' OWN timestamp, and refuse anything already stale.
            -- GetIlvl hands back the raw pool entry with no age filter at all
            -- (Details-Damage-Meter/core/inspect.lua:560-562 is a bare table
            -- read), and that pool is persisted across sessions. We used to
            -- stamp time() on it, i.e. relabel a value from days ago as brand
            -- new -- which then out-survived a fresh inspect for another full
            -- CACHE_REFRESH and kept showing the gear someone wore last week.
            -- Returning nil instead lets the inspect pipeline fetch real data;
            -- no tag for a moment beats a confidently wrong one.
            local poolTime = (type(data.time) == "number" and data.time > 0)
                             and data.time or nil
            if poolTime and (time() - poolTime) >= CACHE_REFRESH then
                return nil
            end
            local ilvl = math.floor(data.ilvl)
            -- Enrich with Name-Realm via roster lookup so the post-disband
            -- reverse-lookup in ResolveGUIDByName can match cross-realm
            -- BlizzDM frames. Falls back to nil when player is not in
            -- the current roster — RebuildNameIlvlMap will retry the
            -- enrichment on the next actor scan.
            -- Never overwrite a known name with nil: ResolveFullNameByGuid returns
            -- nil once the player leaves the roster, and RebuildNameIlvlMap's
            -- cache-fallback skips entries that have no name — which dropped a
            -- departed player's Details!-bar tag until /reload. Keep the prior name.
            local prev = ilvlCache[guid]
            ilvlCache[guid] = {
                ilvl = ilvl,
                -- Details' timestamp when it has one, so the entry ages from
                -- when the data was actually gathered, not from when we read it.
                time = poolTime or time(),
                name = ResolveFullNameByGuid(guid) or (prev and prev.name),
                source = "details",
            }
            return ilvl
        end
    end

    return nil
end

---------------------------------------------------------------
-- Build name->ilvl map from combat actors
---------------------------------------------------------------
-- Short names are NOT unique. "Torvi-Onyxia" and "Torvi-Draenor" both reduce to
-- "Torvi", and Details! bars print only the short form — so a plain overwrite
-- would show one player the other's item level, with no way to notice.
--
-- Ownership is therefore tracked: the first full name to claim a short form
-- keeps it. A second, different claimant makes the short form AMBIGUOUS, and an
-- ambiguous short form is removed and never served again for that map. The full
-- "Name-Realm" key is unaffected and stays exact.
--
-- Same rule as the Blizzard-meter identity fix: rather no number than a number
-- we cannot attribute.
local shortNameOwner = {}     -- short -> GUID of the player that owns it
local shortNameAmbiguous = {} -- short -> true once two different players claimed it

-- Ownership is keyed by GUID, NOT by the name string. The same player reaches
-- this function under both spellings — callers store "Torvi" and
-- "Torvi-Onyxia" for one person — so comparing strings made every single
-- player look like two claimants and blocked 105 of 118 short names on the
-- first live test. The GUID is the identity; the spellings are just labels.
--
-- Without a GUID (Details! actor names, LibOpenRaid) we cannot prove identity,
-- so we do not claim: the short form is served only if some GUID-backed caller
-- already claimed it for that same player, and is never marked ambiguous from
-- an unidentified source.
-- mayInvalidate: may this claimant DECLARE the short form ambiguous, i.e. take
-- it away from whoever holds it? Only subjects that can actually appear on a
-- bar right now may. The persisted cache keeps everyone inspected in the last
-- seven days (CACHE_DISCARD), and RebuildNameIlvlMap walks it AFTER the live
-- roster — so without this a "Torvi-Draenor" you pugged three days ago, who is
-- in no group and on no bar, would strike the tag off the "Torvi" standing next
-- to you, and every later rebuild would reproduce it. Those claimants may still
-- FILL an unclaimed short form; they just may not take one away.
local function ClaimShortName(short, guid, mayInvalidate)
    if shortNameAmbiguous[short] then return false end
    if not guid then return shortNameOwner[short] ~= nil end
    local owner = shortNameOwner[short]
    if owner == nil then
        shortNameOwner[short] = guid
        return true
    end
    if owner == guid then return true end
    if not mayInvalidate then
        -- Someone else owns it and we are not on screen: leave their entry
        -- alone and keep only our exact "Name-Realm" key.
        return false
    end
    -- A second, genuinely different player that IS on screen: drop what is
    -- there, refuse from now on.
    shortNameAmbiguous[short] = true
    nameToIlvl[short] = nil
    nameToSetBonus[short] = nil
    return false
end

-- Both maps and both ownership tables are keyed by the NAME. Using a secret
-- value as a table key throws — the crash class behind v1.5.1 and v1.5.2 — and
-- StripRealm deliberately returns a secret unchanged (util.lua:42), so the
-- short form inherits it. The callers are believed to pass only readable names
-- (SafeUnitName returns nil for a secret, cached names were stored through it),
-- but "believed" is not a guard for something that hard-errors, and the write
-- path is cheap. A secret name simply carries no data we could use anyway.
local function StoreNameIlvl(name, ilvl, guid, mayInvalidate)
    if not name or not ilvl then return end
    if isSecretValue(name) then return end
    local shortName = StripRealm(name)
    if isSecretValue(shortName) then return end
    -- The full "Name-Realm" key is always exact and always safe to write.
    if shortName ~= name then
        nameToIlvl[name] = ilvl
    end
    if ClaimShortName(shortName, guid, mayInvalidate ~= false) then
        nameToIlvl[shortName] = ilvl
    end
end

-- Mirror of StoreNameIlvl for set bonus. sb may be nil (clears entry).
local function StoreNameBonus(name, sb, guid, mayInvalidate)
    if not name then return end
    if isSecretValue(name) then return end
    local shortName = StripRealm(name)
    if isSecretValue(shortName) then return end
    if shortName ~= name then
        nameToSetBonus[name] = sb
    end
    if ClaimShortName(shortName, guid, mayInvalidate ~= false) then
        nameToSetBonus[shortName] = sb
    end
end

local function RebuildNameIlvlMap()
    wipe(nameToIlvl)
    wipe(nameToSetBonus)
    -- Must be wiped together with the maps they describe. Keeping them would
    -- make an ambiguity from an old group permanent: the short name would stay
    -- blocked even after the second claimant is long gone.
    wipe(shortNameOwner)
    wipe(shortNameAmbiguous)
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
                local guid = SafeUnitGUID(unit)
                local cached = guid and ilvlCache[guid]
                if cached and cached.ilvl then
                    seenGuids[guid] = true
                    local name, realm = SafeUnitName(unit)
                    if name then
                        local fullName = (realm and realm ~= "") and (name .. "-" .. realm) or name
                        StoreNameIlvl(name, cached.ilvl, guid)
                        StoreNameBonus(name, setBonusCache[guid], guid)
                        if fullName ~= name then
                            StoreNameIlvl(fullName, cached.ilvl, guid)
                            StoreNameBonus(fullName, setBonusCache[guid], guid)
                        end
                    end
                end
            end
        end

        -- Fallback: cache entries whose unit token is gone (left group, solo, etc.)
        for guid, cached in pairs(ilvlCache) do
            if not seenGuids[guid] and cached.ilvl and cached.name then
                -- false: this player is not in the group and not on any bar
                -- right now, so they may fill an unclaimed short name but never
                -- take one away from someone who is.
                StoreNameIlvl(cached.name, cached.ilvl, guid, false)
                StoreNameBonus(cached.name, setBonusCache[guid], guid, false)
                -- Cross-realm: cached.name may be "Name-Realm". Also store short
                -- name so Details! bars (which show only "Name") still match.
                local shortName = StripRealm(cached.name)
                if shortName ~= cached.name then
                    StoreNameIlvl(shortName, cached.ilvl, guid, false)
                    StoreNameBonus(shortName, setBonusCache[guid], guid, false)
                end
            end
        end

        -- Own player
        local pguid = SafeUnitGUID("player")
        local pcached = pguid and ilvlCache[pguid]
        if pcached and pcached.ilvl then
            local pname = SafeUnitName("player")
            if pname then
                StoreNameIlvl(pname, pcached.ilvl, pguid)
                StoreNameBonus(pname, setBonusCache[pguid], pguid)
            end
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
                        -- Patch name into cache entry if Details! API wrote it without one.
                        -- Prefer Name-Realm form via roster (cross-realm asymmetry fix);
                        -- fall back to actor.displayName / nome which Details! often gives
                        -- without realm suffix. The reverse-lookup nameOnly fallback in
                        -- ResolveGUIDByName covers any leftover bare entries.
                        local entry = ilvlCache[actor.serial]
                        if entry and not entry.name then
                            entry.name = ResolveFullNameByGuid(actor.serial)
                                      or actor.displayName
                                      or actor.nome
                        end
                        -- actor.serial IS the player GUID, so identity is provable here.
                        StoreNameIlvl(actor.displayName, ilvl, actor.serial)
                        StoreNameIlvl(actor.nome, ilvl, actor.serial)
                        StoreNameBonus(actor.displayName, setBonusCache[actor.serial], actor.serial)
                        StoreNameBonus(actor.nome, setBonusCache[actor.serial], actor.serial)
                    end
                end
            end
        end
    end
end

---------------------------------------------------------------
-- Extract player name from text like "1. Quinroth"
---------------------------------------------------------------
local ExtractName = util.ExtractName  -- defined in util.lua (ns.util)

---------------------------------------------------------------
-- Build the iLvl tag string for a given player name
-- Returns e.g. " |cFF0070DD[252]|r |cFF00FF00[2P]|r" or nil
---------------------------------------------------------------
local function BuildTag(name, noLeadingSpace)
    local ilvl = nameToIlvl[name]
    if not ilvl then return nil end

    local prefix = noLeadingSpace and "" or " "
    local tag
    if db.colorIlvl then
        tag = prefix .. GetIlvlColor(ilvl) .. "[" .. ilvl .. "]|r"
    else
        tag = prefix .. "[" .. ilvl .. "]"
    end

    -- O(1) set bonus lookup — nameToSetBonus is kept in sync with nameToIlvl.
    -- Previously this iterated the full ilvlCache (O(N) per bar, O(N²) in 40-man raids).
    if db.showSetBonus then
        local sbTag = SetBonusTag(nameToSetBonus[name])
        if sbTag then
            tag = tag .. " " .. sbTag
        end
    end

    return tag
end

---------------------------------------------------------------
-- Per-window gate: limit Details! iLvl display to a single window.
-- db.detailsWindowId: 0 = all windows (default), 1-10 = only that
-- Details! instance. instanceId may be nil on bars Details! hasn't
-- assigned an instance to yet — fail OPEN there so we never hide a bar
-- we can't classify (worst case: a stray bar shows on the "wrong"
-- window, which beats hiding wanted bars).
---------------------------------------------------------------
local function IsDetailsWindowAllowed(instanceId)
    local want = db and db.detailsWindowId or 0
    if want == 0 then return true end
    if instanceId == nil then return true end
    return instanceId == want
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
        -- User can pin a fixed iLvl text size (db.detailsFontSize, 6-30);
        -- 0 = match Details' own bar font (default, current behavior).
        local override = db and db.detailsFontSize or 0
        if override > 0 then size = override end
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
        if not bar:IsShown() or not IsDetailsWindowAllowed(bar.instance_id) then
            -- Clear text too (not just Hide): Pass 2 re-shows any bar whose
            -- ilvlFS still has text, so leaving stale text on an excluded-window
            -- bar could repaint it without a preceding ClearAllColumns.
            cols.ilvlFS:SetText("")
            cols.ilvlFS:Hide()
            cols.tierFS:SetText("")
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
                -- No brackets here: the columns layout gives the tier its own
                -- field, so they would only cost width.
                -- One mark only: this column is a fixed 28 px truncation
                -- threshold (COL_TIER_WIDTH), and a clipped fragment of a
                -- second mark reads worse than a clean single one. The
                -- current season's is preferred, matching the other
                -- width-limited surfaces (Danders, Grid2).
                cols.tierFS:SetText(SetBonusTag(sb, false, true) or "")

                -- Measure our ilvl column
                local iw = cols.ilvlFS:GetStringWidth() or 0; if isSecretValue(iw) then iw = 0 end
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
                                local w = fs:GetStringWidth() or 0; if isSecretValue(w) then w = 0 end
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
                                local w = fs:GetStringWidth() or 0; if isSecretValue(w) then w = 0 end
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
                                local w = fs:GetStringWidth() or 0; if isSecretValue(w) then w = 0 end
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
                -- GetWidth() returns a SECRET number when the bar is anchored to a
                -- secret-positioned region (SecretWhenAnchoringSecret); the width
                -- arithmetic below would throw. Clamp to 0 → this bar falls into the
                -- hide branch (no columns shown) instead of crashing.
                if isSecretValue(barWidth) then barWidth = 0 end

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
-- Fill barCleanText from what is on screen right now, if we have nothing.
--
-- Three guards, and all three must stay: GetText() can hand back a secret
-- string (Details! Itemlevelfinder), a non-string, or our OWN already-injected
-- text. Capturing the last one would bake a tag into the "clean" text and
-- double it on the next refresh.
local function SeedCleanText(fontString)
    if barCleanText[fontString] then return end
    local currentText = fontString:GetText()
    if not isSecretValue(currentText)
       and currentText and type(currentText) == "string"
       and not currentText:find("%[%d+%]") then
        barCleanText[fontString] = currentText
    end
end

local function HookBarTextIfNeeded(bar)
    if not bar or not bar.lineText1 then return end

    local fontString = bar.lineText1
    if hookedFontStrings[fontString] then
        -- Already hooked, but the clean text may have been WIPED since: the
        -- SetText hook below clears it whenever Details! passes a secret
        -- string. In a boss fight that happens, and afterwards the segment is
        -- static — Details! never calls SetText for those rows again, so the
        -- entry never came back and RefreshAllBarTexts skipped the bar for the
        -- rest of the session. Re-hooking did not help either, because this
        -- early return used to sit BEFORE the seeding below. Observed live
        -- 2026-08-15: one Details! window fully tagged, the other tagged only
        -- on the two rows that had been rewritten since.
        SeedCleanText(fontString)
        return
    end
    hookedFontStrings[fontString] = true
    fsBar[fontString] = bar  -- remember owner for per-window gating in RefreshAllBarTexts

    -- Create column FontStrings for this bar (no-op if already created)
    CreateBarColumns(bar)

    -- Seed immediately: without this, RefreshAllBarTexts has nothing to work
    -- with until Details! calls SetText again (e.g. never, if the window was
    -- just resized).
    SeedCleanText(fontString)
    mapDirty = true

    hooksecurefunc(fontString, "SetText", function(self, text)
        if isOurSetText then return end
        if not db or not db.enabled then return end
        if detailsBarErrors >= DETAILS_BAR_ERROR_LIMIT then return end
        SafeCall(function()
            -- Details! Itemlevelfinder passes "secret string" values to SetText.
            if isSecretValue(text) then
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
            if text:match("^%d+%.%s") or not barCleanText[self] then
                barCleanText[self] = text
            end

            if not db.showInDetails then return end
            -- Per-window filter: this bar's window may be excluded (db.detailsWindowId).
            -- Gate here covers both layouts — columns are also hidden in RefreshAllColumns.
            if not IsDetailsWindowAllowed(bar.instance_id) then return end

            if db.layout == "columns" then
                ScheduleColumnRefresh()
                return
            end

            -- Don't inject during combat (taint with secure UI elements)
            if MayBeInCombat() then return end

            local name = ExtractName(text)
            if name then
                local isLeft = db.ilvlPosition == "left"
                local tag = BuildTag(name, isLeft)
                if tag then
                    isOurSetText = true
                    if isLeft then
                        -- Insert between rank prefix and name: "1. [272] Playername"
                        local rank, rest = text:match("^(%d+%.%s*)(.*)")
                        if rank then
                            self:SetText(rank .. tag .. " " .. rest)
                        else
                            self:SetText(tag .. " " .. text)
                        end
                    else
                        self:SetText(text .. tag)
                    end
                    isOurSetText = false
                end
            end
        end)
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

    local isLeft = db.ilvlPosition == "left"
    isOurSetText = true
    for fontString in pairs(hookedFontStrings) do
        -- barCleanText values are pre-validated on insert (isSecretValue checked
        -- in SetText hook and GetText seed). No pcall needed here.
        -- Per-window filter: skip bars whose Details! window is excluded.
        local ownBar = fsBar[fontString]
        if fontString:IsShown() and (not ownBar or IsDetailsWindowAllowed(ownBar.instance_id)) then
            local text = barCleanText[fontString]
            if text then
                local name = ExtractName(text)
                if name then
                    local tag = BuildTag(name, isLeft)
                    if tag then
                        if isLeft then
                            local rank, rest = text:match("^(%d+%.%s*)(.*)")
                            if rank then
                                fontString:SetText(rank .. tag .. " " .. rest)
                            else
                                fontString:SetText(tag .. " " .. text)
                            end
                        else
                            fontString:SetText(text .. tag)
                        end
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
    resizeStats.fired = resizeStats.fired + 1
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
        resizeStats.refreshed = resizeStats.refreshed + 1
    end)
end

-- Details! instance frames expose their main window as `baseframe` — lowercase f
-- (assigned in Details' classes/class_instance.lua:2508 and :2605; ~1470 usages, and
-- there is no capital-F variant anywhere in Details!). We previously only read
-- `baseFrame`, which is always nil, so this hook never installed. The old spellings
-- are kept as trailing fallbacks: harmless, and they cost nothing if Details! ever
-- renames the field back.
HookInstanceResize = function(instance)
    resizeStats.attempts = resizeStats.attempts + 1
    local frame = instance.baseframe or instance.baseFrame or instance.frame
    if not frame then
        resizeStats.noFrame = resizeStats.noFrame + 1
        return
    end
    resizeStats.field = (instance.baseframe and "baseframe")
                     or (instance.baseFrame and "baseFrame")
                     or "frame"
    if hookedInstances[frame] then return end
    hookedInstances[frame] = true
    local ok = pcall(frame.HookScript, frame, "OnSizeChanged", OnDetailsResize)
    if ok then resizeStats.installed = resizeStats.installed + 1 end
end

---------------------------------------------------------------
-- Periodic update: hook new bars + rebuild map only if dirty
---------------------------------------------------------------
-- Runs every 2s. Routed through SafeCall (not called directly) because it
-- reaches deep into Details! internals: RefreshAllBarTexts alone does
-- hundreds of unguarded reads, and a restored-but-truncated cachedColLayout
-- from SavedVariables is enough to make the arithmetic throw. Unprotected,
-- that error repeated every 2 seconds for the rest of the session; via
-- SafeCall it trips the existing 5-error limit and disables only the
-- Details!-bar feature.
local function TickBody()
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

local function OnTick()
    SafeCall(TickBody)
end

---------------------------------------------------------------
-- Inspect group
---------------------------------------------------------------
-- Is the player looking at the inspect window right now?
--
-- We used to treat EVERY INSPECT_READY we hadn't requested as "the player is
-- manually inspecting" and pause for 60s. In a raid that is wrong nearly all
-- the time: Details! runs its own inspect queue, so foreign INSPECT_READY
-- arrives constantly and the pause never lifted. Three live dumps from a
-- 34-player world boss group showed `manualPause: yes` with 8-14 players
-- stuck in the queue.
--
-- The old comment justified skipping this check with "ElvUI replaces the
-- Blizzard frame". It does not — ElvUI reads _G.InspectFrame itself
-- (ElvUI/Game/Shared/Modules/Misc/InfoItemLevel.lua:67, :180, :450, :462),
-- it only skins it. The global is nil until Blizzard_InspectUI loads on
-- demand, and it cannot load without the player opening an inspect window,
-- so "no frame" is a reliable "not inspecting".
local function InspectWindowOpen()
    local frame = _G.InspectFrame
    if not frame then return false end
    local ok, shown = pcall(frame.IsShown, frame)
    return ok and shown or false
end

local function ProcessNextInspect()
    if IsInCombatSafe() or #inspectQueue == 0 then
        isInspecting = false
        return
    end

    -- Don't fire our background inspect while the player has the inspect
    -- window open — see the INSPECT_READY handler for how that is detected.
    if (GetTime() - lastManualInspectTime) < 60 then
        isInspecting = false
        C_Timer.After(5, ProcessNextInspect)
        return
    end

    isInspecting = true
    local entry = table.remove(inspectQueue, 1)

    if SafeUnitGUID(entry.unit) == entry.guid and CanInspect(entry.unit, false) then
        pendingInspect[entry.guid] = true -- track that WE triggered this inspect
        NotifyInspect(entry.unit)
        -- Safety timeout: if INSPECT_READY never fires (server throttle, player
        -- LoS'd mid-inspect, disconnect), unblock the queue after 15s. Capture
        -- the sweep generation so that a QueueGroupInspect in the meantime (it
        -- wipes the queue and bumps the generation) turns this stale timer into
        -- a no-op — otherwise it could start a SECOND ProcessNextInspect chain
        -- over the freshly-rebuilt queue (double inspects / out-of-order removal).
        local gen = inspectGeneration
        C_Timer.After(15, function()
            if inspectGeneration == gen and isInspecting and pendingInspect[entry.guid] then
                isInspecting = false
                pendingInspect[entry.guid] = nil
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
    wipe(pendingInspect)
    wipe(inspectQueue)
    inspectGeneration = inspectGeneration + 1  -- invalidate in-flight safety timeouts from the previous sweep

    local prefix, count, numGroup = GetGroupInfo()
    if numGroup <= 1 then return end

    for i = 1, count do
        local unit = prefix .. i
        -- Self-check via SafeUnitGUID, NOT raw UnitGUID. UnitGUID() can return a
        -- SECRET value for a restricted-identity unit (12.0.7 flipped the
        -- RequiresDeclassifiedUnitIdentity FailureMode to ReturnWithError), and a
        -- raw secret-GUID comparison throws "attempt to compare a secret string
        -- value". SafeUnitGUID returns nil on secret, so we skip that member this
        -- sweep and pick them up next pass. (This site previously assumed UnitGUID
        -- was "always safe" — the Slave Pens crash at UNIT_INVENTORY_CHANGED
        -- disproved that for any unit whose identity is restricted.)
        if UnitExists(unit) and UnitIsPlayer(unit) then
            local guid = SafeUnitGUID(unit)
            if guid and guid ~= SafeUnitGUID("player") then
                -- Pre-populate nameToIlvl/nameToSetBonus from cache now while we have the unit.
                -- UnitName() is reliable here; at INSPECT_READY the unit token
                -- may already be stale if the player moved or reloaded.
                local cached = ilvlCache[guid]
                if cached and cached.ilvl then
                    local name, realm = SafeUnitName(unit)
                    if name then
                        local fullName = (realm and realm ~= "") and (name .. "-" .. realm) or name
                        StoreNameIlvl(fullName, cached.ilvl, guid)
                        StoreNameIlvl(name, cached.ilvl, guid)
                        StoreNameBonus(fullName, setBonusCache[guid], guid)
                        StoreNameBonus(name, setBonusCache[guid], guid)
                    end
                end
                -- Queue if we have nothing, if something explicitly marked the
                -- entry stale (boss kill, gear change), or if it aged past the
                -- refresh horizon. The stale flag replaces the old trick of
                -- back-dating .time, which could not work: the back-dated age
                -- was always just under this very threshold.
                if not cached or cached.stale
                   or (time() - cached.time >= CACHE_REFRESH) then
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
    local guid = SafeUnitGUID("player")
    if not guid then return end
    local pname = SafeUnitName("player")
    if not pname then return end
    -- Only let a COMPLETE read touch the set bonus. An incomplete one means
    -- the item cache was still cold (async C_Item.GetItemInfo) — writing its
    -- nil would erase a correct 4P, and nothing on this path ever put it back:
    -- the delayed re-reads exist only in the login bootstrap, not on zoning.
    -- Reported live 2026-08-15: own [4P] vanished on entering a raid and came
    -- back only after re-equipping a piece.
    local sb, complete = GetSetBonusForUnit("player")
    local ilvl = math.floor(equipped)
    ilvlCache[guid] = {ilvl = ilvl, time = time(), name = pname, source = "self"}
    if complete then
        setBonusCache[guid] = sb or false
        selfBonusRetries = 0
    else
        if setBonusCache[guid] == nil then
            setBonusCache[guid] = false -- first ever read: record "known nothing"
        end
        -- Keep whatever we had; do NOT let an unreadable slot erase it.
        sb = setBonusCache[guid] or nil
        -- Bounded retry with a widening delay. GET_ITEM_INFO_RECEIVED usually
        -- beats us to it, but it only fires for items the client actually
        -- requests — if the data trickles in another way we would never look
        -- again. A flat 3x3s proved too short: after a loading screen the item
        -- cache can still be cold nine seconds later, and then the stale value
        -- (already persisted in SavedVariables) survived until the next gear
        -- change. This covers ~2 minutes and then stops.
        local delays = {3, 5, 10, 20, 30, 60}
        selfBonusRetries = selfBonusRetries + 1
        local wait = delays[selfBonusRetries]
        if wait then
            C_Timer.After(wait, UpdatePlayerCache)
        end
    end
    if pname then
        StoreNameIlvl(pname, ilvl, guid)
        StoreNameBonus(pname, sb, guid)
    end
    mapDirty = true
    NotifyElvUI(pname)
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
            ns.db = db  -- expose to UI / other sub-modules (single source of truth)
            -- Defaults setup sequence:
            -- 1. Recursive merge fills missing keys (handles nested tables).
            -- 2. Schema migration upgrades old DB layouts to current.
            -- 3. Read-time validators clamp/coerce out-of-range or wrongly-
            --    typed values so manually-edited SavedVars don't crash.
            RecursiveDefaultsMerge(db, defaults)
            MigrateSchema(db)
            ValidateDb(db)

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

            -- The addon's ONLY deletion site — see CACHE_REFRESH/CACHE_DISCARD
            -- at the top of this file for why it must use the 7-day number.
            -- A malformed entry (no timestamp) is kept rather than dropped:
            -- treating "unknown age" as "infinitely old" is exactly how the
            -- old time = 0 marker destroyed fresh data.
            local now = time()
            for guid, data in pairs(ilvlCache) do
                if type(data.time) == "number" and data.time > 0
                   and (now - data.time) >= CACHE_DISCARD then
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
                    -- LoR fires GearUpdate(GetUnitID(name), unitGearInfo, allUnitsGear):
                    -- arg 1 is a UNIT TOKEN ("party3"/"raid11"/"player") for anyone in
                    -- the group, NOT a "Name-Realm" string, and the gear table is arg 2.
                    -- (The old code treated arg 1 as a name and matched it against the
                    -- roster, which never matched for group members — so this fast path
                    -- was silently dead and we fell back to the inspect queue.)
                    lib.RegisterCallback({}, "GearUpdate", function(_, unit, gearInfo)
                        if not unit or not ilvlCache then return end
                        if isSecretValue(unit) then return end
                        if not UnitExists(unit) then return end          -- token must be a live unit
                        gearInfo = gearInfo or (lib.GetUnitGear and lib.GetUnitGear(unit))
                        if not gearInfo or not gearInfo.ilevel or gearInfo.ilevel <= 0 then return end
                        local guid = SafeUnitGUID(unit)
                        if not guid then return end
                        if guid == SafeUnitGUID("player") then return end    -- self: GetAverageItemLevel is more accurate
                        local ilvl = math.floor(gearInfo.ilevel)
                        local existing = ilvlCache[guid]
                        if not existing or ilvl ~= existing.ilvl or (time() - existing.time) > 300 then
                            local name, realm = SafeUnitName(unit)
                            if not name then return end
                            local storedName = (realm and realm ~= "") and (name.."-"..realm) or name
                            ilvlCache[guid] = {ilvl = ilvl, time = time(), name = storedName, source = "lor"}
                            StoreNameIlvl(storedName, ilvl, guid)
                            StoreNameIlvl(name, ilvl, guid)
                            mapDirty = true
                            NotifyElvUI(storedName)
                        end
                    end)
                end
            end
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Guard against multiple tickers: PLAYER_ENTERING_WORLD fires on every
        -- zone transition. Without this flag, rapid zoning within 3s creates
        -- multiple tickers and OnTick runs multiple times per interval.
        if not detailsReady and not tickerStarted and not bootstrapArmed then
            bootstrapArmed = true

            -- Re-read our OWN tier set once the item cache is warm.
            -- C_Item.GetItemInfo is async: on a fresh login the tier pieces are
            -- usually not cached yet, so GetSetBonusForUnit undercounts and we
            -- store `false` for the session (reported 2026-08-13: four equipped
            -- tier pieces, /dilvl tier showing all four as whitelist=YES, and
            -- still no [4P] until an item was re-equipped).
            --
            -- Registered OUTSIDE the setup closure below on purpose. In there
            -- they would sit behind RebuildNameIlvlMap/HookAllBars, and a throw
            -- in any of those would silently drop the repair — while
            -- tickerStarted (set just above) prevents the block from ever
            -- re-arming. The result would be the exact original symptom with no
            -- error to explain it. These two calls depend on nothing in that
            -- closure. UpdatePlayerCache is idempotent and returns early when
            -- the cache is not bound yet.
            C_Timer.After(5, UpdatePlayerCache)
            C_Timer.After(20, UpdatePlayerCache)

            C_Timer.After(3, function()
                detailsReady = true

                -- Ticker FIRST, and tickerStarted only once it really exists.
                -- It used to be created after the two Details! calls below,
                -- with tickerStarted set before the closure even ran: a throw
                -- in RebuildNameIlvlMap or HookAllBars killed the ticker, the
                -- login message, and all three inspect sweeps for the whole
                -- session — while the guard above blocked every later
                -- PLAYER_ENTERING_WORLD from retrying. /dilvl debug made it
                -- worse by reporting "Ticker: true" the entire time.
                C_Timer.NewTicker(2, OnTick)
                tickerStarted = true

                -- Inspect in both modes (Details + ElvUI-only).
                -- Scheduled before anything that can throw, for the same
                -- reason as the ticker above.
                C_Timer.After(5, QueueGroupInspect)
                -- LFR: unit tokens for all 25 players may not exist yet after 5s.
                -- Retry at 15s and 30s to catch late-appearing group members.
                C_Timer.After(15, QueueGroupInspect)
                C_Timer.After(30, QueueGroupInspect)

                if Details then
                    pcall(RebuildNameIlvlMap)
                    pcall(HookAllBars)
                end

                -- Build mode string for login message
                local modes = {}
                if Details then modes[#modes + 1] = "Details!" end
                if db.blizzDM == true or (db.blizzDM == nil and not Details) then
                    modes[#modes + 1] = "Blizzard DM"
                end
                if db.elvuiTag and ElvUI then modes[#modes + 1] = "ElvUI" end
                if db.grid2Status and Grid2 then modes[#modes + 1] = "Grid2" end
                if db.dandersText and DandersFrames_IsReady then modes[#modes + 1] = "Danders" end
                local modeStr = #modes > 0 and table.concat(modes, " + ") or "cache-only"
                print("|cFF00FF00Details! iLvl Display|r v" .. addonVersion .. " loaded (" .. modeStr .. "). /dilvl")

                ShowLoginHints()
            end)
        end

        -- Rebuild name maps on zone change. Same reasoning as the roster
        -- branch below: flag only, no wipe — the rebuild clears them itself.
        if ilvlCache then
            local currentMap = C_Map.GetBestMapForUnit("player")
            if currentMap and currentMap ~= lastMapID then
                mapDirty = true
                lastMapID = currentMap
            end
        end

        -- Fresh retry budget per zone: a loading screen is exactly when the
        -- item cache is cold, and the previous zone may have used it up.
        selfBonusRetries = 0
        UpdatePlayerCache()

    elseif event == "INSPECT_READY" then
        if _hasanysecretvalues(...) then return end -- (#15)
        local guid = ...
        if isSecretValue(guid) then return end
        local prefix, count = GetGroupInfo()

        for i = 1, count do
            local u = prefix .. i
            if SafeUnitGUID(u) == guid then
                -- Skip own GUID — GetAverageItemLevel is always more accurate for self
                if guid == SafeUnitGUID("player") then break end
                local ilvl = C_PaperDollInfo.GetInspectItemLevel(u)
                if ilvl and ilvl > 0 then
                    local name, realm = SafeUnitName(u)
                    local ilvlFloor = math.floor(ilvl)
                    local fullName = name and (realm and realm ~= "") and (name .. "-" .. realm) or name
                    local setBonus, sbComplete = GetSetBonusForUnit(u)
                    -- Store false (not nil) for "inspected, no bonus" so persistence
                    -- can distinguish from "never inspected" (nil = not in table).
                    -- Same rule as UpdatePlayerCache: an INCOMPLETE read (item
                    -- data not cached yet) must never overwrite a known bonus.
                    -- The re-inspect after the next boss kill will fill it in.
                    if sbComplete or setBonusCache[guid] == nil then
                        setBonusCache[guid] = setBonus or false
                    else
                        setBonus = setBonusCache[guid] or nil
                    end
                    -- Fallback to existing cached name if UnitName() returned nil
                    -- (unit token can go stale between queue and INSPECT_READY)
                    local cachedName = ilvlCache[guid] and ilvlCache[guid].name
                    ilvlCache[guid] = {ilvl = ilvlFloor, time = time(), name = fullName or name or cachedName, source = "inspect"}
                    lastInspectInfo = {name = fullName or name or cachedName, ilvl = ilvlFloor, time = GetTime()}
                    -- Populate nameToIlvl directly — don't rely on Details! combat
                    -- actors (player may not have dealt damage/healed yet).
                    if name then
                        StoreNameIlvl(name, ilvlFloor, guid)
                        StoreNameBonus(name, setBonus, guid)
                        if fullName and fullName ~= name then
                            StoreNameIlvl(fullName, ilvlFloor, guid)
                            StoreNameBonus(fullName, setBonus, guid)
                        end
                    end
                end
                break
            end
        end

        -- Only advance the queue if WE triggered this INSPECT_READY.
        mapDirty = true
        NotifyElvUI(lastInspectInfo and lastInspectInfo.name or nil)
        if pendingInspect[guid] then
            pendingInspect[guid] = nil
            ClearInspectPlayer()
            C_Timer.After(1.0, ProcessNextInspect)
        elseif InspectWindowOpen() then
            -- Someone else asked for this inspect AND the player has the
            -- inspect window open — back off so we don't repopulate it
            -- under them.
            lastManualInspectTime = GetTime()
        end

    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        UpdatePlayerCache()

    elseif event == "GET_ITEM_INFO_RECEIVED" then
        if _hasanysecretvalues(...) then return end -- (#15)
        -- C_Item.GetItemInfo is async — on fresh login, tier slot items may
        -- not be cached yet, causing GetSetBonusForUnit to undercount.
        -- Re-check only when a tier slot item finishes loading.
        local itemID = ...
        if isSecretValue(itemID) then return end
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
        if _hasanysecretvalues(...) then return end -- (#15)
        -- ENCOUNTER_END fires on both kills (success=1) AND wipes (success=0).
        -- Only re-inspect on kills — loot (and potential ilvl gains) only drop on kills.
        local _, _, _, _, success = ...
        if isSecretValue(success) then return end -- Delves: success can be lazy-tainted
        if db and db.enabled and success == 1 then
            -- Mark the group for re-inspection WITHOUT touching the timestamp.
            -- .time is also the deletion key, so back-dating it to force a
            -- refresh was really a deletion request: the old code aged the
            -- whole group to 60s short of the purge and still queued nobody,
            -- every single boss kill. A separate flag says "refresh me"
            -- without saying "I am old".
            local prefix, count = GetGroupInfo()
            for i = 1, count do
                local guid = SafeUnitGUID(prefix .. i)
                if guid and ilvlCache[guid] then
                    ilvlCache[guid].stale = true
                end
            end
            C_Timer.After(5, QueueGroupInspect)
        end

    elseif event == "GROUP_ROSTER_UPDATE" then
        if not IsInCombatSafe() and db and db.enabled then
            -- Mark for rebuild, but do NOT wipe here. The maps are keyed by
            -- NAME, not by unit token, so a roster reshuffle cannot make an
            -- entry wrong: "Torvi-Onyxia -> 287" stays true whether she is
            -- raid12 or raid8. RebuildNameIlvlMap wipes as its own first
            -- step and re-adds ex-group members from the cache anyway, so
            -- wiping early gained nothing and cost up to one ticker interval
            -- of untagged bars. In a world boss raid filling from 17 to 34
            -- players this fired constantly; two live dumps caught the map
            -- at 0 entries while the cache held 32.
            mapDirty = true
            NotifyElvUI()
            C_Timer.After(3, QueueGroupInspect)
        end

    elseif event == "UNIT_INVENTORY_CHANGED" then
        if _hasanysecretvalues(...) then return end -- (#15)
        -- Re-inspect a group member when they equip new gear.
        -- The event ALSO fires for derived tokens ("targettarget", "focus",
        -- nameplates, …) whose UnitGUID() is SECRET inside restricted instances
        -- (event dungeons like the Slave Pens). The unit-token string itself is
        -- not secret — only the GUID it resolves to — so isSecretValue(unit)
        -- passes and the old raw `UnitGUID(unit) ~= UnitGUID("player")` compare
        -- threw "attempt to compare a secret string value". Route the foreign
        -- GUID through SafeUnitGUID (nil on secret/unavailable); UnitGUID("player")
        -- is always declassified, so the surviving compare is plain-vs-plain.
        local unit = ...
        if isSecretValue(unit) then return end
        if not unit or not UnitIsPlayer(unit) or IsInCombatSafe() then return end
        local guid = SafeUnitGUID(unit)
        if not guid or guid == SafeUnitGUID("player") then return end -- secret, gone, or self
        if ilvlCache[guid] then
            -- Flag for re-inspection. This used to write time = 0, which the
            -- load-time purge read as an age of ~1.79 billion seconds and
            -- deleted on sight. That was only survivable if the +2s inspect
            -- below actually succeeded — and it silently does not when the
            -- player is in combat (QueueGroupInspect returns early), out of
            -- range, or has left the group, so a simple gear swap before a pull
            -- could destroy a perfectly good entry at the next reload.
            ilvlCache[guid].stale = true
            C_Timer.After(2, QueueGroupInspect)
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
-- Defaults / schema / validators / reset — keeps SavedVariables sane
-- across upgrades and manual edits.
---------------------------------------------------------------
CURRENT_SCHEMA_VERSION = 1  -- assigns to forward-declared upvalue at file top

-- Validators: clamp/coerce setting values to sane ranges. Run after
-- defaults-merge so missing keys are filled first. Generic fallback below
-- (boolean/number/string type-check + reset to default) covers settings
-- not in this table.
VALIDATORS = {
    dandersFontSize = function(v)
        if type(v) ~= "number" then return 10 end
        if v < 6 then return 6 end
        if v > 30 then return 30 end
        return math.floor(v + 0.5)
    end,
    detailsFontSize = function(v)
        if type(v) ~= "number" then return 0 end
        if v == 0 then return 0 end                       -- 0 = auto (match Details' font)
        if v < DETAILS_FONT_MIN then return DETAILS_FONT_MIN end
        if v > DETAILS_FONT_MAX then return DETAILS_FONT_MAX end
        return math.floor(v + 0.5)
    end,
    detailsWindowId = function(v)
        if type(v) ~= "number" then return 0 end
        v = math.floor(v + 0.5)
        if v < 0 then return 0 end
        if v > 10 then return 10 end
        return v
    end,
    dandersPos = function(v)
        if type(v) ~= "string" then return "topright" end
        -- Validate against the canonical POS_KEYS_SET. If POS_KEYS_SET
        -- isn't loaded yet (load order race), trust the value and let the
        -- next refresh catch a bad key.
        if ns.POS_KEYS_SET and not ns.POS_KEYS_SET[v] then return "topright" end
        return v
    end,
    layout = function(v)
        if v ~= "inline" and v ~= "columns" then return "inline" end
        return v
    end,
    ilvlPosition = function(v)
        if v ~= "left" and v ~= "right" then return "right" end
        return v
    end,
    blizzDM = function(v)
        -- Tristate: nil / true / false are all valid
        if v == nil or v == true or v == false then return v end
        return nil
    end,
}

RecursiveDefaultsMerge = function(target, source)
    for k, v in pairs(source) do
        if type(v) == "table" then
            if type(target[k]) ~= "table" then target[k] = {} end
            RecursiveDefaultsMerge(target[k], v)
        elseif target[k] == nil then
            target[k] = v
        end
    end
end

MigrateSchema = function(db_in)
    local from = db_in.schemaVersion or 1
    -- Placeholder for future migrations. Pattern:
    --   if from < 2 then
    --       -- migrate from v1 to v2 (e.g. rename a key, drop a removed enum value)
    --       db_in.schemaVersion = 2
    --       from = 2
    --   end
    db_in.schemaVersion = CURRENT_SCHEMA_VERSION
end

ValidateDb = function(db_in)
    for k, defaultVal in pairs(defaults) do
        local actualVal = db_in[k]
        local validator = VALIDATORS[k]
        if validator then
            -- Specific validator wins (handles enum, range, type all at once)
            local ok, newVal = pcall(validator, actualVal)
            if ok then db_in[k] = newVal end
        elseif type(defaultVal) == "boolean" then
            if type(actualVal) ~= "boolean" then db_in[k] = defaultVal end
        elseif type(defaultVal) == "number" then
            if type(actualVal) ~= "number" then db_in[k] = defaultVal end
        elseif type(defaultVal) == "string" then
            if type(actualVal) ~= "string" then db_in[k] = defaultVal end
        end
    end
end

---------------------------------------------------------------
-- Reset-to-Defaults — soft wipe: only resets known settings keys, preserves
-- ilvlCache, setBonusCache, uiState. Triggered from the Settings UI via a
-- StaticPopup confirmation. After reset, re-applies enabled + layout so the
-- in-world state matches the wiped db.
---------------------------------------------------------------
ns.ResetToDefaults = function()
    if not db then return end
    local preserve = {
        ilvlCache    = db.ilvlCache,
        setBonusCache = db.setBonusCache,
        uiState      = db.uiState,
    }
    -- Wipe only known defaults keys (preserve unknown user-added entries +
    -- the preserved caches above)
    for k in pairs(defaults) do db[k] = nil end
    -- Re-fill from defaults
    RecursiveDefaultsMerge(db, defaults)
    -- Restore preserved
    for k, v in pairs(preserve) do
        if v ~= nil then db[k] = v end
    end
    -- Re-render: broadcast every settings key so all surfaces refresh
    -- (was: only enabled+layout, which left 10 other settings stale-visible
    -- until next sort event or tab switch — final review finding).
    if ns.ApplySettingChangeSafe then
        for k in pairs(defaults) do
            ns.ApplySettingChangeSafe(k)
        end
    end
    if ns.ui and ns.ui.preview and ns.ui.preview.MarkDirty then
        ns.ui.preview.MarkDirty()
    end
    -- Re-render the currently-open UI tab so widgets reflect fresh values
    if ns.ui and ns.ui.main and ns.ui.main.activeTabId then
        ns.ui.main.SwitchTab(ns.ui.main.activeTabId)
    end
    print("|cFF00FF00Details! iLvl Display:|r All settings reset to defaults.")
end

---------------------------------------------------------------
-- ApplySettingChange — central refresh-router. Both the slash handler and
-- the Settings UI call this after writing a setting to db so the visual
-- side-effects (re-render Details! bars, switch layout mode, etc.) happen
-- consistently regardless of which entry point changed the setting.
---------------------------------------------------------------
-- Every caller must go through ApplySettingChangeSafe, never the raw function.
-- All three call sites used a bare `pcall(ns.ApplySettingChange, k)` and threw
-- the error away, so a setting that failed to apply looked exactly like one
-- that worked: the checkbox flipped, the value landed in db, and the world
-- never changed. Nothing reached BugSack either, so it could not be reported.
-- Logged once per key — core.lua's own reset loops over every default, and a
-- single broken key would otherwise spam the error frame on each pass.
local _applyErrorLogged = {}
ns.ApplySettingChangeSafe = function(key)
    if not ns.ApplySettingChange then return false end
    local ok, err = pcall(ns.ApplySettingChange, key)
    if not ok and not _applyErrorLogged[key] then
        _applyErrorLogged[key] = true
        geterrorhandler()("Details! iLvl Display: applying setting ["
            .. tostring(key) .. "] failed: " .. tostring(err))
    end
    return ok
end

ns.ApplySettingChange = function(key)
    if not db then return end
    if key == "enabled" then
        if db.enabled then
            RefreshAllBarTexts()
            NotifyElvUI()
        else
            ClearAllBarTags()
            NotifyElvUI()
        end
    elseif key == "colorIlvl" or key == "showSetBonus" then
        RefreshAllBarTexts()
        if db.layout == "columns" then RefreshAllColumns() end
        NotifyElvUI()
    elseif key == "showInDetails" then
        if db.showInDetails then
            detailsBarErrors = 0
            RefreshAllBarTexts()
        else
            ClearAllBarTags()
        end
    elseif key == "detailsFontSize" then
        -- Re-copy fonts (picks up the size override) then redraw columns.
        -- Only affects the Columns layout (own FontStrings); inline text
        -- is part of Details!' own FontString and keeps Details' size.
        UpdateAllColumnFonts()
        if db.layout == "columns" then RefreshAllColumns() end
    elseif key == "detailsWindowId" then
        -- Window filter changed: wipe all tags/columns, re-hook, redraw so
        -- excluded windows go clean and the selected one (re)populates.
        ClearAllBarTags()       -- also clears columns (calls ClearAllColumns)
        HookAllBars()
        RebuildNameIlvlMap()
        if db.layout == "columns" then
            RefreshAllColumns()
        else
            RefreshAllBarTexts()
        end
    elseif key == "ilvlPosition" then
        if db.layout == "inline" then
            ClearAllBarTags()
            RefreshAllBarTexts()
        end
    elseif key == "layout" then
        if db.layout == "columns" then
            ClearAllBarTags()
            HookAllBars()
            RebuildNameIlvlMap()
            RefreshAllColumns()
        else
            ClearAllColumns()
            RebuildNameIlvlMap()
            RefreshAllBarTexts()
        end
    elseif key == "elvuiTag" then
        NotifyElvUI()
    elseif key == "grid2Status" then
        NotifyElvUI()  -- Grid2 status updates piggyback on the same callback bus
    elseif key == "dandersText" then
        -- Toggle ON after auto-disable: reset error counter + re-register
        -- callback so frames refresh. Toggle OFF: no extra work; next
        -- refresh sees the flag and clears overlay text.
        if db.dandersText and Details_iLvlDisplay_DandersReset then
            pcall(Details_iLvlDisplay_DandersReset)
        end
    elseif key == "dandersPos" then
        -- Live-apply position to visible Danders frames so the user sees
        -- the change immediately (else they'd wait 30+s for next sort).
        if Details_iLvlDisplay_DandersApplyPos then
            pcall(Details_iLvlDisplay_DandersApplyPos, db.dandersPos)
        end
    elseif key == "dandersFontSize" then
        if Details_iLvlDisplay_DandersApplyFontSize then
            pcall(Details_iLvlDisplay_DandersApplyFontSize, db.dandersFontSize)
        end
    elseif key == "blizzDM" then
        -- Tristate change (auto/on/off). Reset error counter so a prior
        -- auto-disable doesn't immediately re-disable. NotifyElvUI bus
        -- carries the change to BlizzDM integration.
        if Details_iLvlDisplay_BlizzDMReset then
            pcall(Details_iLvlDisplay_BlizzDMReset)
        end
        NotifyElvUI()
    end
end

---------------------------------------------------------------
-- Slash command
---------------------------------------------------------------
SLASH_DILVL1 = "/dilvl"
SlashCmdList["DILVL"] = function(msg)
    msg = msg:lower():trim()

    if msg == "" then
        -- Bare /dilvl opens the Settings UI — the home for every option and the
        -- What's New overview. All subcommands below still work; the full text
        -- list is /dilvl help.
        if ns.ui and ns.ui.slash then
            ns.ui.slash.HandleSlash("")
        else
            print("|cFF00FF00Details! iLvl Display:|r Settings UI not loaded yet — try /reload.")
        end
        return
    end

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
    elseif msg:match("^details size") then
        local arg = msg:match("^details size%s+(%S+)")
        local n = arg and tonumber(arg)
        if n and (n == 0 or (n >= DETAILS_FONT_MIN and n <= DETAILS_FONT_MAX)) then
            n = math.floor(n + 0.5)  -- round, matching the VALIDATORS.detailsFontSize rule
            db.detailsFontSize = n
            if ns.ApplySettingChange then ns.ApplySettingChange("detailsFontSize") end
            if n == 0 then
                print("|cFF00FF00Details! iLvl Display:|r Details text size: auto (matches Details' font)")
            else
                print(string.format("|cFF00FF00Details! iLvl Display:|r Details text size: %d (Columns layout)", n))
            end
        else
            local cur = db.detailsFontSize or 0
            print("|cFF00FF00Details! iLvl Display:|r Current Details text size: " .. ((cur == 0) and "auto" or tostring(cur)))
            print(string.format("  Usage: /dilvl details size <0|%d-%d>  (0 = match Details' font; Columns layout)", DETAILS_FONT_MIN, DETAILS_FONT_MAX))
        end

    elseif msg:match("^details window") then
        local arg = msg:match("^details window%s+(%S+)")
        if arg == "all" or arg == "0" then
            db.detailsWindowId = 0
            if ns.ApplySettingChange then ns.ApplySettingChange("detailsWindowId") end
            print("|cFF00FF00Details! iLvl Display:|r Details window: all windows")
        else
            local n = arg and tonumber(arg)
            if n and n >= 1 and n <= 10 then
                db.detailsWindowId = math.floor(n)
                if ns.ApplySettingChange then ns.ApplySettingChange("detailsWindowId") end
                print(string.format("|cFF00FF00Details! iLvl Display:|r Details window: only window %d", math.floor(n)))
            else
                local cur = db.detailsWindowId or 0
                print("|cFF00FF00Details! iLvl Display:|r Current Details window: " .. ((cur == 0) and "all windows" or ("window " .. cur)))
                print("  Usage: /dilvl details window <all|1-10>")
            end
        end

    elseif msg == "details" then
        db.showInDetails = not db.showInDetails
        if not db.showInDetails then
            ClearAllBarTags()
        else
            -- Reset the hook-error counter so the user gets a fresh
            -- 5-error budget after toggling back on. Otherwise a prior
            -- auto-disable would remain at 5/5 and re-trip on the very
            -- next error.
            detailsBarErrors = 0
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
            if guid == SafeUnitGUID("player") then
                name = SafeUnitName("player") or name
            end
            if name == "Unknown" and Details and Details.item_level_pool and Details.item_level_pool[guid] then
                name = Details.item_level_pool[guid].name or name
            end
            local age = now - data.time
            local sbTag = SetBonusTag(setBonusCache[guid])
            local sb = sbTag and (sbTag .. " ") or ""
            -- `stale` = explicitly flagged for re-inspect (boss kill, gear change).
            -- The old marker was time = 0, which the load purge read as an age of
            -- ~1.79 billion seconds and deleted. Age and "needs refresh" are now
            -- separate facts, so both can be shown honestly.
            local ageStr = (age .. "s ago") .. (data.stale and " (flagged)" or "")
            local isExpired = data.stale or age >= CACHE_REFRESH
            local ageColor = isExpired and "|cFFFF4444" or "|cFF888888"
            local expiredNote = isExpired and " |cFFFF4444[EXPIRED]|r" or ""
            print(string.format("  %s: %s|cFFFFD900%d|r iLvl %s(%s)%s",
                name, sb, data.ilvl, ageColor, ageStr, expiredNote))
            count = count + 1
            if age >= CACHE_REFRESH then expired = expired + 1 end
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
        --
        -- TWO THINGS THIS MUST GET RIGHT, both learned the hard way:
        -- 1. Forward ALL arguments. The wrapper used to take a single `m`, so
        --    while the dump ran, any other addon calling print(a, b, c) silently
        --    lost b and c.
        -- 2. Restore `print` NO MATTER WHAT. This swaps a GLOBAL for ~370 lines.
        --    Before, a single throw anywhere in the dump left our wrapper
        --    installed for the rest of the session — breaking every addon that
        --    prints, and doing it in the one command people run when something
        --    is already wrong. The body is wrapped in pcall below and `print` is
        --    restored on both paths.
        local debugBuf = {}
        local origPrint = print
        print = function(...)
            origPrint(...)
            local n = select("#", ...)
            if n == 1 then
                local v = ...
                debugBuf[#debugBuf + 1] = isSecretValue(v) and "(secret)" or tostring(v)
            else
                local parts = {}
                for i = 1, n do
                    local v = select(i, ...)
                    parts[i] = isSecretValue(v) and "(secret)" or tostring(v)
                end
                debugBuf[#debugBuf + 1] = table.concat(parts, " ")
            end
        end

        local dumpOk, dumpErr = pcall(function()

        local cacheCount, mapCount, hookCount, setBonusCount, bonusMapCount, colCount = 0, 0, 0, 0, 0, 0
        for _ in pairs(ilvlCache) do cacheCount = cacheCount + 1 end
        for _ in pairs(nameToIlvl) do mapCount = mapCount + 1 end
        for _ in pairs(hookedFontStrings) do hookCount = hookCount + 1 end
        -- How many hooked bars actually have a usable clean text. A hook
        -- without one renders nothing, and the gap between the two numbers is
        -- the only visible symptom — chasing it from the outside cost an
        -- evening on 2026-08-15.
        local cleanTextCount = 0
        for _ in pairs(barCleanText) do cleanTextCount = cleanTextCount + 1 end

        -- Break the "hooks minus text" gap down by CAUSE. Without this the
        -- number says something is missing but not why, and the three causes
        -- need completely different answers:
        --   empty   = an unused reserve row Details! keeps around → harmless
        --   secret  = the string is protected; the player sees the name, we may
        --             not read it → Blizzard restriction, nothing we can fix
        --   tagged  = the text already carries OUR tag, so the seed refuses it
        --             (it must, or the tag gets baked into the "clean" copy) →
        --             OUR bug, and the bar stays untagged until Details! rewrites it
        local fsEmpty, fsSecret, fsTagged = 0, 0, 0
        for fontString in pairs(hookedFontStrings) do
            if not barCleanText[fontString] then
                local t = fontString:GetText()
                if isSecretValue(t) then
                    fsSecret = fsSecret + 1
                elseif t == nil or t == "" then
                    fsEmpty = fsEmpty + 1
                elseif type(t) == "string" and t:find("%[%d+%]") then
                    fsTagged = fsTagged + 1
                end
            end
        end
        for _ in pairs(setBonusCache) do setBonusCount = setBonusCount + 1 end
        for _ in pairs(nameToSetBonus) do bonusMapCount = bonusMapCount + 1 end
        for _ in pairs(barColumns) do colCount = colCount + 1 end

        local prefix, count, numGroup = GetGroupInfo()
        local rawCombat = InCombatRaw()
        local inCombat = isSecretValue(rawCombat) and "SECRET(safe=no)" or (rawCombat and "yes" or "no")
        -- Guard the 0 sentinel: without it every session reports a phantom
        -- pause during the first minute after client launch.
        local manualPause = (lastManualInspectTime > 0
            and (GetTime() - lastManualInspectTime) < 60) and "yes" or "no"
        -- pendingInspect is a set now, so report how many of our own requests
        -- are still in flight rather than a single GUID.
        local pendingCount = 0
        for _ in pairs(pendingInspect) do pendingCount = pendingCount + 1 end
        local pending = (pendingCount > 0) and (pendingCount .. " in flight") or "none"
        -- GetBuildInfo returns version, build, date, tocversion. Field 4 is the
        -- INTERFACE number (120100), not the build (69283) -- labelling it
        -- "WoW build" sent every bug report in with the wrong number.
        local wowVer, wowBuildNum = GetBuildInfo()
        local wowToc = select(4, GetBuildInfo())
        local detailsVer = Details and (Details.userversion or Details.version) or "n/a"

        print("=== Details! iLvl Display v" .. addonVersion .. " — Bug Report ===")
        -- Sub-module load state. If any of these say "MISSING", the TOC is
        -- stale or a sub-file failed to load — pasted bug reports surface
        -- the issue immediately instead of looking like a runtime bug.
        print(string.format("  Modules: init=%s  secrets=%s  util=%s",
            ns.addonName and "ok" or "MISSING",
            (ns.secrets and ns.secrets.SafeUnitName) and "ok" or "MISSING",
            -- probe the NEWEST util export, not the oldest: GetIlvlColor has
            -- existed since v1.0, so it says "ok" even for a stale util.lua.
            (ns.util and ns.util.StripRealm) and "ok" or "MISSING"))
        print(string.format("  WoW: %s.%s (toc %s)  Details: %s",
            tostring(wowVer), tostring(wowBuildNum), tostring(wowToc), tostring(detailsVer)))
        local blizzDMState = db.blizzDM == nil and ("AUTO(" .. (Details and "off" or "on") .. ")") or (db.blizzDM and "ON" or "OFF")
        print(string.format("  Addon: %s  Details-bars: %s  ElvUI-tag: %s  BlizzDM: %s  Layout: %s  Position: %s",
            db.enabled and "ON" or "OFF",
            db.showInDetails and "ON" or "OFF",
            db.elvuiTag and "ON" or "OFF",
            blizzDMState,
            db.layout or "inline",
            db.ilvlPosition or "right"))
        print(string.format("  Color: %s  SetBonus: %s",
            db.colorIlvl and "ON" or "OFF",
            db.showSetBonus and "ON" or "OFF"))
        print(string.format("  Grid2: %s (host: %s)  Danders: %s (host: %s)",
            db.grid2Status and "ON" or "OFF",
            Grid2 and "loaded" or "absent",
            db.dandersText and "ON" or "OFF",
            (DandersFrames_IsReady and DandersFrames_IsReady()) and "ready" or (DandersFrames_IsReady and "loaded" or "absent")))
        if Details_iLvlDisplay_DandersDebug then
            for _, line in ipairs(Details_iLvlDisplay_DandersDebug()) do
                print(line)
            end
        end
        print(string.format("  Group: %s (%d members)  InCombat: %s",
            prefix, numGroup, inCombat))
        -- Short-form count: with cross-realm players cached, nameMap must hold
        -- BOTH "Name-Realm" and "Name". Zero short forms against a non-empty
        -- cache is the realm-stripping bug and nothing else -- that ratio was
        -- the tell that identified it on 2026-08-13, and it took a manual
        -- /dilvl map to see. Now it is one line in the standard dump.
        local shortForms = 0
        for k in pairs(nameToIlvl) do
            if type(k) == "string" and not k:find("-", 1, true) then
                shortForms = shortForms + 1
            end
        end
        -- Ambiguous short names: two players from different realms sharing a
        -- first name. Details! bars print only the short form, so we refuse to
        -- serve it rather than show one of them the other's item level. A
        -- number here means the guard fired, not that something broke.
        local ambiguousShorts = 0
        for _ in pairs(shortNameAmbiguous) do ambiguousShorts = ambiguousShorts + 1 end

        print(string.format("  Cache: %d iLvl  %d setBonus  %d nameMap (%d short-form)  %d bonusMap  %d hooks (%d w/ text)  %d columns",
            cacheCount, setBonusCount, mapCount, shortForms, bonusMapCount, hookCount, cleanTextCount, colCount))
        if ambiguousShorts > 0 then
            local names = {}
            for short in pairs(shortNameAmbiguous) do names[#names + 1] = short end
            print(string.format("  Ambiguous short names (no tag on Details! bars): %d — %s",
                ambiguousShorts, table.concat(names, ", ")))
        end
        if hookCount > cleanTextCount then
            print(string.format("  Bars without clean text: %d empty (reserve rows)  %d secret (Blizzard-protected)  %d already tagged (OUR bug)",
                fsEmpty, fsSecret, fsTagged))
        end
        -- Resize-hook health (v1.5.3). installed=0 with attempts>0 means the
        -- OnSizeChanged hook never attached — that was the pre-1.5.3 bug (we read
        -- instance.baseFrame, Details! spells it baseframe). Expect installed>=1 per
        -- open Details! window, field=baseframe, and fired>0 after dragging the window edge.
        print(string.format("  Resize-hook: %d installed / %d attempts  noFrame=%d  field=%s  fired=%d  refreshed=%d",
            resizeStats.installed, resizeStats.attempts, resizeStats.noFrame,
            tostring(resizeStats.field), resizeStats.fired, resizeStats.refreshed))
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
            -- tostring() on the name: it is built as `fullName or name or cachedName`
            -- and 12.1 can make SafeUnitName return nil for every one of those, so a
            -- bare %s on a nil throws. Every other value in this dump is already
            -- tostring-wrapped; this line was the outlier, and it sat inside the
            -- block that swaps the global print -- which is what turned a cosmetic
            -- nil into a session-wide breakage for every other addon.
            print(string.format("  Last inspect: %s → %d iLvl (%s)",
                tostring(lastInspectInfo.name), lastInspectInfo.ilvl or 0, ago))
        end
        print(string.format("  Details ready: %s  Ticker: %s  MapDirty: %s  LibOpenRaid: %s  Details!-HookErrors: %d/%d",
            tostring(detailsReady), tostring(tickerStarted), tostring(mapDirty),
            openRaidLib and "active" or "n/a",
            detailsBarErrors, DETAILS_BAR_ERROR_LIMIT))
        print(string.format("  SecretAPI: CanCompareUnitTokens=%s  UnitNameBlocked: %d  UnitNameRejected: %d  UnitIsUnitBlocked: %d",
            (C_Secrets and C_Secrets.CanCompareUnitTokens) and "yes" or "no",
            secretStats.unitNameBlocked,
            secretStats.unitNameRejected or 0,
            secretStats.unitIsUnitBlocked))
        -- Per-callback error counters (one row per registered callback).
        -- Empty if all callbacks healthy; lists names + counts when not.
        local cbErrSummary = {}
        for name, n in pairs(_callbackErrors) do
            if n and n > 0 then
                cbErrSummary[#cbErrSummary + 1] = name .. "=" .. n
            end
        end
        if #cbErrSummary > 0 then
            -- The first number is how many callbacks have errors, NOT an error
            -- count against the limit -- the old label read as "3/5 errors".
            print(string.format("  Callbacks with errors: %d  (limit %d per callback): %s",
                #cbErrSummary, CALLBACK_ERROR_LIMIT, table.concat(cbErrSummary, "  ")))
        else
            print(string.format("  Callback errors: 0  (limit: %d/cb, auto-unregister on breach)",
                CALLBACK_ERROR_LIMIT))
        end

        -- BlizzDM diagnostics
        if Details_iLvlDisplayAPI.GetBlizzDMDebug then
            local windows, frames, hasGuid, hasTag, secretName, entries, ci, resolveFails, maxResolveFails, apiGuid, nameSkips, backfills, bfReason = Details_iLvlDisplayAPI.GetBlizzDMDebug()
            maxResolveFails = maxResolveFails or 3
            print("  --- Blizzard Damage Meter ---")
            -- BlizzDM auto-disable counter (separate from Details!-HookErrors).
            if Details_iLvlDisplay_BlizzDMState then
                local state, limit = Details_iLvlDisplay_BlizzDMState()
                print(string.format("    errors: %d/%d   disabled: %s",
                    state.errors, limit, tostring(state.disabled)))
                if state.lastError then
                    print("    lastError: " .. state.lastError)
                end
                -- v1.4.2: GAVE-UP-lock smart-reset diagnostics. resetCount
                -- counts every nameResolveFails clearance since /reload;
                -- lastResetReason shows what triggered the most recent reset
                -- (cache-write / REGEN / roster-leave / session-switch).
                if state.resetCount and state.resetCount > 0 then
                    print(string.format("    resets: %d   lastReset: %s",
                        state.resetCount, tostring(state.lastResetReason or "?")))
                end
            end
            if type(ci) == "table" then
                -- GUID is split by trust: "api" came from Blizzard's own
                -- combatSource and may carry a name on screen; the remainder is
                -- our name lookup and may not. nameSkip counts rows we left
                -- alone for exactly that reason — a number there is the safety
                -- rule working, not a fault.
                print(string.format("    windows: %d  frames: %d  GUID: %d (%d api, %d backfill)  tagged: %d  secret: %d  nameSkip: %d(session)",
                    windows, frames, hasGuid, apiGuid or 0, backfills or 0, hasTag, secretName, nameSkips or 0))
                -- direct = rows the ScrollBox answered for outright. Everything
                -- after it is a reason a row could NOT be decided, in the order
                -- the checks run, so the first one is where it breaks.
                if bfReason and bfReason ~= "" then
                    print("    backfill: " .. bfReason)
                end
                print(string.format("    combat: group=%s  self=%s  ICL=%s  encounter=%s%s  unitFlags=%s  members=%d",
                    ci.groupCombat and "YES" or "no",
                    ci.inCombat and "YES" or "no",
                    ci.iclRaw or "?",
                    ci.encounter and "YES" or "no",
                    ci.encounterSecret and "(SECRET)" or "",
                    ci.unitFlags and "YES" or "no",
                    ci.members or 0))
                print(string.format("    refresh: active=%s  passes=%d  tagged=%d/%d  lastPass=%.1fs ago  deferRetry=%s",
                    ci.refreshActive and "YES" or "idle",
                    ci.refreshPasses or 0,
                    ci.refreshTagged or 0,
                    ci.refreshTotal or 0,
                    -- 0 means "never ran"; truthiness would print client uptime
                    (ci.refreshLastPass and ci.refreshLastPass > 0)
                        and (GetTime() - ci.refreshLastPass) or -1,
                    ci.deferredRetry and "PENDING" or "no"))
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
                    flags = flags .. " [" .. (e.path or "?") .. "]"
                    if e.nameFSType then flags = flags .. " fs:" .. e.nameFSType end
                    local failStr = ""
                    if e.resolveFails and e.resolveFails > 0 then
                        failStr = string.format("  fails:%d/%d", e.resolveFails, maxResolveFails)
                    end
                    print(string.format("    [%d] %s%s  guid:%s  cache:%s  tag:%s%s%s",
                        i, e.name,
                        e.isLocal and " (YOU)" or "",
                        e.guid and "yes" or "NO",
                        e.cached and "yes" or "no",
                        e.tagged and "yes" or "no",
                        flags, failStr))
                    -- Extended debug: show native text and cache name
                    local extra = "        "
                    if e.nativeTxt then extra = extra .. "native:" .. e.nativeTxt end
                    if e.cacheName then extra = extra .. "  cName:" .. e.cacheName end
                    if e.textColor then extra = extra .. "  color:" .. e.textColor end
                    print(extra)
                end
            end
            if frames == 0 then
                print("    (open Blizzard DM window to see entries)")
            end
            -- Per-player resolve fail tracker
            if resolveFails and #resolveFails > 0 then
                print("    --- Resolve Fails (per player) ---")
                for _, rf in ipairs(resolveFails) do
                    print(string.format("    %s: %d/%d%s",
                        rf.name:sub(1, 20), rf.fails, maxResolveFails,
                        rf.gaveUp and " GAVE-UP" or ""))
                end
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
                        local bw = bar.statusbar and bar.statusbar:GetWidth() or 0
                        if isSecretValue(bw) then bw = 0 end -- secret width → no crash in /dilvl debug
                        print(string.format("      barWidth=%.1f  shown=%s",
                            bw, tostring(bar:IsShown())))
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
                                    else local sw0 = fs:GetStringWidth() or 0; sw = isSecretValue(sw0) and "SECRET" or string.format("%.1f", sw0) end
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
                                local w = fs:GetStringWidth() or 0; if isSecretValue(w) then w = 0 end
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
                                local w = fs:GetStringWidth() or 0; if isSecretValue(w) then w = 0 end
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
                                local w = fs:GetStringWidth() or 0; if isSecretValue(w) then w = 0 end
                                if w > dk2w then dk2w = w end
                            end
                        end
                    end
                    -- Our ilvl width
                    if iv then
                        local iw = cols.ilvlFS:GetStringWidth() or 0; if isSecretValue(iw) then iw = 0 end
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
                    if isSecretValue(sampleWidth) then sampleWidth = 0 end -- secret width → no crash in /dilvl debug
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
                local age = ((now - data.time) .. "s") .. (data.stale and "+flag" or "")
                -- Season suffix belongs to storage, not to the eye. Show the
                -- season only where it differs from the current one, so the
                -- normal case stays as short as it was.
                local rawSb = setBonusCache[guid]
                local sb = rawSb and ("[" .. util.SetBonusDebug(rawSb) .. "] ") or ""
                local src = data.source and string.upper(data.source) or "?"
                print(string.format("    %s: %s%d iLvl [%s] (%s)", name, sb, data.ilvl, src, age))
            end
        end

        -- Tier slots: own gear.
        -- The live return value goes FIRST and on its own line. The slot list
        -- below shows the ingredients; this shows what the function actually
        -- makes of them right now, next to what is stored. When those three
        -- disagree the bug is located in one glance — without it, 2026-08-15
        -- cost an evening of inference.
        do
            local liveSb, liveComplete = GetSetBonusForUnit("player")
            local pg = SafeUnitGUID("player")
            local storedSb = pg and setBonusCache[pg]
            local function show(v)
                if v == nil then return "nil" end
                return util.SetBonusDebug(v) or tostring(v)
            end
            print(string.format("  --- Own Tier Slots ---  live: %s (complete=%s)  stored: %s",
                show(liveSb), tostring(liveComplete), show(storedSb)))

            -- Cross-check our hand-set season against what the client thinks.
            -- They are ALLOWED to differ: measured on 2026-08-16 the API already
            -- said 2 during the season-2 pre-season while everyone still wore
            -- season-1 tier. This line is how we notice the day it is time to
            -- flip U.CURRENT_TIER_SEASON, instead of finding out from a user.
            local uiSeason
            if C_MythicPlus and C_MythicPlus.GetCurrentUIDisplaySeason then
                local okS, v = pcall(C_MythicPlus.GetCurrentUIDisplaySeason)
                if okS then uiSeason = v end
            end
            print(string.format("      tier season: ours=%d  client=%s%s",
                util.CURRENT_TIER_SEASON, tostring(uiSeason),
                (uiSeason and uiSeason ~= util.CURRENT_TIER_SEASON)
                    and "  |cFFFFD100(differ — check whether the new season has opened)|r" or ""))
        end
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
        end)

        -- Restore original print on BOTH paths, then show the copy-paste popup.
        -- A partial dump is still worth showing: whatever was collected before
        -- the error is usually exactly what the bug report needs, and the error
        -- itself is appended so it travels with the report.
        print = origPrint
        if not dumpOk then
            local msg2 = "|cFFFF4444[dump aborted: " .. tostring(dumpErr) .. "]|r"
            origPrint(msg2)
            debugBuf[#debugBuf + 1] = msg2
        end
        ShowDebugWindow(table.concat(debugBuf, "\n"))

    elseif msg == "auras" then
        print("|cFF00FF00Details! iLvl Display:|r Player auras (looking for tier bonus):")
        local found = 0
        for i = 1, 60 do
            -- pcall, not just a result guard: 12.1 gave the aura APIs
            -- RequiresUnitAuraAccess with FailureMode "Error", so in restricted
            -- content this THROWS INSIDE THE CALL -- before any value comes back
            -- for isSecretValue() to inspect. Same shape as the v1.5.2 mixin
            -- crash: the only thing that helps is wrapping the call itself.
            local ok, aura = pcall(C_UnitAuras.GetBuffDataByIndex, "player", i)
            if not ok then
                print("  (aura data is restricted here — nothing readable)")
                break
            end
            if not aura then break end
            local sid = aura.spellId
            local name = aura.name or "?"
            if sid then
                -- 12.1.0 (PTR 3) makes aura fields secret in instances/combat/M+;
                -- string.format("%d"/"%s", secret) would throw. Guard before the format.
                if isSecretValue(sid) or isSecretValue(name) then
                    print(string.format("  [%d] <secret aura>", i))
                else
                    print(string.format("  [%d] %s (spellID=%d)", i, name, sid))
                end
                found = found + 1
            end
        end
        if found == 0 then print("  (none found or spellIds are secret)") end

    elseif msg == "sets" or msg:match("^sets%s") then
        -- Find the item-set IDs for a new season without waiting for someone to
        -- equip the gear. Blizzard ships the set table with the patch, so the IDs
        -- are readable as soon as the patch is live — a season only gates when the
        -- items DROP, not when they exist. C_Item.GetItemSetInfo(setID) returns the
        -- set's name (or nothing for an unused ID), which is enough to identify it.
        local from = tonumber(msg:match("^sets%s+(%d+)")) or 1975
        local to   = tonumber(msg:match("^sets%s+%d+%s+(%d+)")) or (from + 79)
        if to - from > 400 then to = from + 400 end -- keep one command cheap
        print(string.format("|cFF00FF00Details! iLvl Display:|r item sets %d-%d  (usage: /dilvl sets [from] [to])", from, to))
        local found = 0
        for id = from, to do
            local ok, name = pcall(C_Item.GetItemSetInfo, id)
            if ok and name and name ~= "" and not isSecretValue(name) then
                found = found + 1
                print(string.format("    [%d] %s%s", id, name,
                    MIDNIGHT_TIER_SETS[id] and "  |cFF00FF00(in whitelist)|r" or "  |cFFFF8000(NOT in whitelist)|r"))
            end
        end
        if found == 0 then
            -- Distinguish "range is empty" from "the API is gone": probe a set
            -- we know exists (1990 is in our own whitelist).
            local probeOk, probeName = pcall(C_Item.GetItemSetInfo, 1990)
            if not probeOk or not probeName or probeName == "" then
                print("    C_Item.GetItemSetInfo unavailable or blocked — not a range problem.")
            else
                print("    (no sets in this range — try another, e.g. /dilvl sets 2000 2080)")
            end
        else
            print(string.format("    %d set(s) found. Whitelist currently holds %d IDs.", found, (function()
                local n = 0; for _ in pairs(MIDNIGHT_TIER_SETS) do n = n + 1 end; return n
            end)()))
        end

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
        Details_iLvlDisplayAPI:RestoreCallback("elvui")
        NotifyElvUI()
        print("|cFF00FF00Details! iLvl Display:|r ElvUI tag |cFFFFD900[dilvl]|r enabled. Add it to your ElvUI name/health tag.")
    elseif msg == "elvui off" then
        db.elvuiTag = false
        NotifyElvUI()
        print("|cFF00FF00Details! iLvl Display:|r ElvUI tag |cFFFFD900[dilvl]|r disabled.")

    elseif msg == "grid2" or msg == "grid2 on" then
        if not Grid2 then
            print("|cFF00FF00Details! iLvl Display:|r Grid2 not installed.")
        else
            db.grid2Status = true
            Details_iLvlDisplayAPI:RestoreCallback("grid2")
            NotifyElvUI()
            print("|cFF00FF00Details! iLvl Display:|r Grid2 status |cFFFFD900dilvl|r enabled. Add it to a Grid2 text indicator.")
        end
    elseif msg == "grid2 off" then
        db.grid2Status = false
        NotifyElvUI()
        print("|cFF00FF00Details! iLvl Display:|r Grid2 status |cFFFFD900dilvl|r disabled.")

    elseif msg == "danders" or msg == "danders on" then
        if not DandersFrames_IsReady then
            print("|cFF00FF00Details! iLvl Display:|r Danders Frames not installed.")
        else
            db.dandersText = true
            -- Reset error counter + clear disabled state so user gets a
            -- fresh chance without /reload.
            if Details_iLvlDisplay_DandersReset then
                Details_iLvlDisplay_DandersReset()
            end
            NotifyElvUI()
            print("|cFF00FF00Details! iLvl Display:|r Danders Frames overlay enabled.")
        end
    elseif msg == "danders off" then
        db.dandersText = false
        NotifyElvUI()
        print("|cFF00FF00Details! iLvl Display:|r Danders Frames overlay disabled.")

    elseif msg:match("^danders pos") then
        local arg = msg:match("^danders pos%s+(%S+)")
        if arg and POS_KEYS_SET[arg] then
            db.dandersPos = arg
            if Details_iLvlDisplay_DandersApplyPos then
                Details_iLvlDisplay_DandersApplyPos(arg)
            end
            print("|cFF00FF00Details! iLvl Display:|r Danders position: " .. arg)
        else
            print("|cFF00FF00Details! iLvl Display:|r Current Danders position: " .. (db.dandersPos or "topright"))
            print("  Inside:    top, topright, topleft, bottom, bottomright, bottomleft, center")
            print("  Off-frame: above, aboveleft, aboveright, below, belowleft, belowright")
        end

    elseif msg:match("^danders size") then
        local arg = msg:match("^danders size%s+(%S+)")
        local n = arg and tonumber(arg)
        if n and n >= DANDERS_FONT_MIN and n <= DANDERS_FONT_MAX then
            n = math.floor(n)
            db.dandersFontSize = n
            local applied = 0
            if Details_iLvlDisplay_DandersApplyFontSize then
                applied = Details_iLvlDisplay_DandersApplyFontSize(n) or 0
            end
            print(string.format("|cFF00FF00Details! iLvl Display:|r Danders text size: %d", n))
            if applied == 0 then
                print("  No visible Danders frames yet — setting saved, will apply on next refresh.")
            end
        else
            local cur = db.dandersFontSize or 10
            print(string.format("|cFF00FF00Details! iLvl Display:|r Current Danders text size: %d (range %d-%d)",
                cur, DANDERS_FONT_MIN, DANDERS_FONT_MAX))
            print(string.format("  Usage: /dilvl danders size <%d-%d>", DANDERS_FONT_MIN, DANDERS_FONT_MAX))
        end

    elseif msg == "blizzdm" then
        -- Recovery-aware toggle. If BlizzDM was auto-disabled, restore the
        -- tristate the user had BEFORE the disable (nil/auto, true, false)
        -- instead of blindly toggling false → true (which would force ON
        -- and lose the user's prior 'auto' setting).
        local wasDisabled, prior = false, nil
        if Details_iLvlDisplay_BlizzDMReset then
            wasDisabled, prior = Details_iLvlDisplay_BlizzDMReset()
        end
        if wasDisabled then
            db.blizzDM = prior -- nil/true/false — restore prior intent
        else
            -- Normal user toggle: nil (auto) → force ON; true → OFF; false → ON
            if db.blizzDM == nil then
                db.blizzDM = true
            else
                db.blizzDM = not db.blizzDM
            end
        end
        NotifyElvUI()
        local stateStr = db.blizzDM == nil and "AUTO" or (db.blizzDM and "ON" or "OFF")
        print("|cFF00FF00Details! iLvl Display:|r Blizzard Damage Meter " .. stateStr
            .. (wasDisabled and " (restored after auto-disable)" or ""))
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

    elseif msg == "taint" then
        -- Active taint-safety self-test: pcall-probes the Blizzard DM foreign-mixin
        -- surface and flags any call that throws while tainted (the v1.5.2 class).
        if Details_iLvlDisplay_BlizzDMSelfTest then
            ShowDebugWindow(table.concat(Details_iLvlDisplay_BlizzDMSelfTest(), "\n"))
        else
            print("|cFF00FF00Details! iLvl Display:|r Taint self-test needs Blizzard's Damage Meter loaded.")
        end

    elseif msg == "position" or msg == "position left" or msg == "position right" then
        if msg == "position left" then
            db.ilvlPosition = "left"
        elseif msg == "position right" then
            db.ilvlPosition = "right"
        else
            db.ilvlPosition = (db.ilvlPosition == "left") and "right" or "left"
        end
        -- Refresh to apply new position
        if db.layout == "inline" then
            ClearAllBarTags()
            RefreshAllBarTexts()
        end
        print("|cFF00FF00Details! iLvl Display:|r Position: " .. db.ilvlPosition)

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

    elseif msg == "ui" or msg:match("^ui%s") or msg:match("^ui$") then
        local rest = msg:match("^ui%s+(.*)$") or ""
        if ns.ui and ns.ui.slash then
            ns.ui.slash.HandleSlash(rest)
        else
            print("|cFF00FF00Details! iLvl Display:|r Settings UI not loaded yet.")
        end

    else
        print("|cFF00FF00Details! iLvl Display|r v" .. addonVersion)
        print("  /dilvl [ui]            — Open the Settings UI (home for all options)")
        print("  /dilvl on|off          — Enable / disable")
        print("  /dilvl details         — Toggle iLvl on Details! bars")
        print("  /dilvl details size <n>  — Details! text size (0=auto, 6-30; Columns layout)")
        print("  /dilvl details window <n> — Show iLvl on only one Details! window (all|1-10)")
        print("  /dilvl elvui on|off    — Toggle iLvl in ElvUI party frames")
        print("  /dilvl grid2 on|off    — Toggle iLvl status in Grid2 raid frames")
        print("  /dilvl danders on|off  — Toggle iLvl overlay on Danders Frames")
        print("  /dilvl danders pos <opt> — Danders text position (live, no /reload)")
        print("      inside:    top, topright, topleft, bottom, bottomright, bottomleft, center")
        print("      off-frame: above, aboveleft, aboveright, below, belowleft, belowright")
        print("  /dilvl danders size <n>  — Danders text size (6-30, live)")
        print("  /dilvl blizzdm         — Toggle iLvl on Blizzard Damage Meter")
        print("  /dilvl color           — Toggle color-coded iLvl")
        print("  /dilvl setbonus        — Toggle 2P/4P display")
        print("  /dilvl layout          — Toggle inline/columns layout")
        print("  /dilvl position        — Toggle iLvl left/right of name (inline mode)")
        print("  /dilvl inspect         — Manually trigger group inspect")
        print("  /dilvl debug           — Full status report (paste when reporting a bug)")
        print("  /dilvl cache           — Show cached iLvl entries")
        print("  /dilvl map             — Show name→iLvl map")
        print("  /dilvl tier            — Scan own tier slots")
        print("  /dilvl sets [from] [to] — List item-set IDs (find a new season's tier sets)")
        print("  /dilvl auras           — Show own auras (spellID debug)")
        print("  /dilvl taint           — BlizzDM taint-safety self-test (run in a restricted instance)")
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
    -- UnitName() returns just "Name", so every comparison below runs on the
    -- stripped form.
    -- Fallback: if player left the group, reverse-lookup from ilvlCache
    -- so Blizz DM can still show iLvl for past sessions.
    ResolveGUIDByName = function(name)
        if not name then return nil end
        local cleanName = StripRealm(name)
        local pName = SafeUnitName("player")
        -- Claim the local player only on a form that CANNOT belong to anyone
        -- else. This used to compare the realm-STRIPPED name, so a group member
        -- "Torvi-Draenor" matched a local player "Torvi" and got our GUID — and
        -- with it our item level, printed under their name. Blizzard's own
        -- nameText supplies the name, so the row contradicted itself silently:
        -- exactly the "wrong number under a right name" this function's roster
        -- loop below goes to such lengths to avoid.
        -- A name that still carries a realm is settled further down instead:
        -- the exact uFull match (the player is enumerated among raid1..N) or,
        -- failing that, the ilvlCache fallback.
        if pName and name == pName then return SafeUnitGUID("player") end
        -- Try roster first
        local prefix, count
        if IsInRaid() then
            prefix, count = "raid", GetNumGroupMembers()
        elseif IsInGroup() then
            prefix, count = "party", GetNumGroupMembers() - 1
        end
        if prefix then
            -- Collect ALL matches instead of taking the first. Two players from
            -- different realms share a short name ("Torvi-Onyxia" and
            -- "Torvi-Draenor" both answer to "Torvi"), and returning whichever
            -- unit index came first was a silent coin flip: the caller then
            -- painted one player's item level under the other's name — a wrong
            -- number under a right name, the hardest kind to notice.
            --
            -- StoreNameIlvl already refuses exactly this ambiguity for the
            -- Details! bars; without this the two surfaces answered the same
            -- collision differently.
            local found, ambiguous = nil, false
            for i = 1, count do
                local unit = prefix .. i
                local uName, uRealm = SafeUnitName(unit)
                if uName then
                    -- Prefer an EXACT match including the realm. BlizzDM usually
                    -- hands us "Name-Realm", and that form cannot collide — so
                    -- only fall back to short matching when the caller gave us
                    -- no realm to work with.
                    local uFull = (uRealm and uRealm ~= "") and (uName .. "-" .. uRealm) or uName
                    if uFull == name then
                        local g = SafeUnitGUID(unit)
                        if g then return g end
                        break
                    end
                    if uName == cleanName then
                        -- UnitGUID(unit) can be SECRET for a restricted group
                        -- member; SafeUnitGUID returns nil there. Never hand back
                        -- a secret — every caller compares it or uses it as a
                        -- table key and would throw.
                        local g = SafeUnitGUID(unit)
                        if g then
                            if found and found ~= g then
                                ambiguous = true
                                break
                            end
                            found = found or g
                        end
                    end
                end
            end
            if ambiguous then return nil end
            if found then return found end
        end
        -- Fallback: reverse lookup from ilvlCache (players who left group)
        if ilvlCache then
            -- Exact full-name match first: it carries the realm and cannot
            -- collide, so it is always safe to trust.
            for guid, cached in pairs(ilvlCache) do
                if cached.name == name then
                    return guid
                end
            end
            -- Then short form, with the same ambiguity rule as the roster loop
            -- above. The old comment here said we "accept this fuzzy match,
            -- better a tag than no tag" — but the tag it produced could belong
            -- to the wrong player, and a wrong number under a right name is
            -- worse than no number at all.
            local cFound, cAmbiguous = nil, false
            for guid, cached in pairs(ilvlCache) do
                if cached.name and StripRealm(cached.name) == cleanName then
                    if cFound and cFound ~= guid then
                        cAmbiguous = true
                        break
                    end
                    cFound = cFound or guid
                end
            end
            if cAmbiguous then return nil end
            if cFound then return cFound end

            -- Cross-realm asymmetry: input is "Name-Realm" but cached.name
            -- may be bare "Name" (legacy [DETAILS]-source entries written
            -- before the realm-enrichment fix, or post-disband entries we
            -- couldn't enrich because the player was not in the roster at
            -- write time). Strip realm from input, retry as last resort —
            -- with the same ambiguity rule, for the same reason.
            local inputBare = cleanName:match("^([^%-]+)")
            if inputBare and inputBare ~= cleanName then
                local bFound, bAmbiguous = nil, false
                for guid, cached in pairs(ilvlCache) do
                    if cached.name then
                        local cachedBare = StripRealm(cached.name)
                        if cachedBare == inputBare then
                            if bFound and bFound ~= guid then
                                bAmbiguous = true
                                break
                            end
                            bFound = bFound or guid
                        end
                    end
                end
                if bAmbiguous then return nil end
                if bFound then return bFound end
            end
        end
        return nil
    end,
    -- Shared color function so ElvUI tag uses the same tier colors.
    GetIlvlColor = GetIlvlColor,
    -- RGB variant for widget APIs that take numbers instead of an escape
    -- sequence (Grid2 SetTextColor). Same thresholds, one source: util.ILVL_COLORS.
    GetIlvlColorRGB = util.GetIlvlColorRGB,
    -- Season-aware set-bonus rendering. Stored form may carry a season suffix
    -- ("4P#1"); never print the raw value, always split it through these.
    SetBonusTag = util.SetBonusTag,
    SetBonusPlain = util.SetBonusPlain,
    SetBonusDebug = util.SetBonusDebug,
    -- Shared realm stripper. Every channel must use this and never Ambiguate
    -- directly — see util.StripRealm.
    StripRealm = StripRealm,
    -- Live db reference — elvui_tags.lua checks db.elvuiTag at call time.
    GetDb = function() return db end,
    -- Callback registry — multiple consumers (elvui_tags, blizzdm) register here.
    -- Fires on: INSPECT_READY, UpdatePlayerCache, GROUP_ROSTER_UPDATE.
    _callbacks = {},
    RegisterCallback = function(self, name, fn)
        self._callbacks[name] = fn
        -- Clear any stale counters from a prior auto-unregister so the
        -- newly-registered callback gets a fresh 0/5 budget. Without
        -- this, a re-register after auto-unregister would inherit the
        -- old 5 count and trip the limit on its first error.
        _callbackErrors[name] = nil
        _callbackErrorLogged[name] = nil
    end,
    UnregisterCallback = function(self, name)
        self._callbacks[name] = nil
        _callbackErrors[name] = nil
        _callbackErrorLogged[name] = nil
        _callbackParked[name] = nil
    end,
    -- Bring a parked callback back after the error that killed it is gone
    -- (ElvUI finished its profile switch, Grid2 reloaded its layout).
    -- Called from the /dilvl elvui|grid2 on branches, which reset the
    -- counters anyway. No-op if nothing is parked under that name.
    RestoreCallback = function(self, name)
        local parked = _callbackParked[name]
        if not parked or self._callbacks[name] then return false end
        _callbackParked[name] = nil
        self:RegisterCallback(name, parked)
        return true
    end,
    -- Secret-value defense surface (#26). Sub-files used to duplicate
    -- these guards locally — blizzdm.lua now reads them from here so
    -- the pcall hardening from secrets.lua applies consistently.
    SafeUnitName    = SafeUnitName,
    SafeUnitGUID    = SafeUnitGUID,
    SafeUnitIsUnit  = SafeUnitIsUnit,
    IsInCombatSafe  = IsInCombatSafe,
    MayBeInCombat   = MayBeInCombat,
    InCombatRaw     = InCombatRaw,
    isSecretValue   = isSecretValue,
    hasanysecretvalues = _hasanysecretvalues,
}

-- Internal helper — call once after any cache write that should update UI.
-- Forward-declared at top of file so event handlers can reference it.
--
-- Per-callback fault isolation: each callback has its own error counter.
-- First error per callback gets logged via geterrorhandler() (BugSack
-- picks it up, user is informed). After CALLBACK_ERROR_LIMIT consecutive
-- errors, that callback is auto-unregistered — others keep working.
-- Counter resets on success (transient errors don't accumulate forever).
-- Counter tables (_callbackErrors, _callbackErrorLogged) and limit are
-- forward-declared near the top of this file so /dilvl debug can read
-- them.
-- playerName (optional): when a cache write targets one specific player, pass
-- their full name (e.g. "Zoltara-Azshara"). Subscribers can use it for targeted
-- logic such as resetting per-player resolve-fail counters (blizzdm.lua v1.4.2).
-- Existing subscribers ignore the extra arg — Lua silently drops unused params.
NotifyElvUI = function(playerName)
    local registry = Details_iLvlDisplayAPI._callbacks
    for name, cb in pairs(registry) do
        local ok, err = pcall(cb, playerName)
        if ok then
            -- Reset on success — transient errors don't accumulate forever.
            if _callbackErrors[name] then
                _callbackErrors[name] = 0
                _callbackErrorLogged[name] = nil
            end
        else
            local n = (_callbackErrors[name] or 0) + 1
            _callbackErrors[name] = n
            -- Log first error per callback so user/dev sees it in BugSack;
            -- skip subsequent ones to avoid spam.
            if not _callbackErrorLogged[name] then
                _callbackErrorLogged[name] = true
                geterrorhandler()("Details! iLvl Display: callback ["
                    .. name .. "] error: " .. tostring(err))
            end
            if n >= CALLBACK_ERROR_LIMIT then
                -- Park, don't discard. All four RegisterCallback sites run at
                -- load time and nobody ever re-registers, so dropping the
                -- function used to kill that integration for the session with
                -- /reload as the only cure. Details!-bars, BlizzDM and Danders
                -- all have reset paths; ElvUI and Grid2 simply never got one.
                -- Parked callbacks come back via RestoreCallback (/dilvl elvui
                -- on, /dilvl grid2 on).
                _callbackParked[name] = cb
                registry[name] = nil
                geterrorhandler()("Details! iLvl Display: callback ["
                    .. name .. "] auto-unregistered after "
                    .. CALLBACK_ERROR_LIMIT .. " errors. Other integrations still active.")
            end
        end
    end
end
