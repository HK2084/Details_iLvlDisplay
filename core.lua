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
-- Inspect outcome accounting. Every field counts a RESULT, never a precondition:
-- `sent` is a NotifyInspect that actually left, not a queue insert; `ok` is an
-- item level we actually stored, not an INSPECT_READY we happened to receive.
-- Before this existed the dump printed "Queue: 0 pending  inspecting: false"
-- for BOTH "everyone is cached, nothing to do" and "all 20 requests died" —
-- opposite states, and the only distinction a bug report needs.
local inspectStats = {
    sent     = 0,   -- NotifyInspect calls that actually fired
    ok       = 0,   -- our request answered AND an item level was stored (a visible tag)
    empty    = 0,   -- our request answered but nothing was stored: no readable item
                    -- level, or the unit token no longer resolved to that player
    timedOut = 0,   -- 15s safety timer fired with our request still unanswered
    requeued = 0,   -- timed-out entries actually put back on the queue
    deferred = 0,   -- turns skipped BEFORE spending a request (CanInspect false, or
                    -- the queued token no longer resolves to that player)
    harvested = 0,  -- item levels stored from an INSPECT_READY somebody ELSE asked for.
                    -- Details! and other addons run their own inspect queues and we
                    -- read the results; without this counter a dump showing
                    -- "1 sent  0 ok" beside six seconds-old item levels reads as a
                    -- dead pipeline when it is in fact a well-fed one.
}
local INSPECT_FAIL_LIMIT = 3
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
-- fontString -> the last SECRET name string Details! passed to SetText for this
-- bar. Blizzard seals the name of every player outside our own group, and after
-- a fight the segment is static, so Details! never rewrites those rows again and
-- the clean text never comes back. We may not READ this value (GetText carries
-- SecretReturnsForAspect = {Text}) and any comparison, concatenation or use as a
-- table KEY throws -- but holding one as a table VALUE is safe, and Details!
-- itself parks the same secret on the row (Details/classes/class_damage.lua:3128)
-- and formats with it (:3199). The key here is the FontString, never the secret.
-- Written and cleared in lockstep with barCleanText so a bar can never re-emit
-- the previous occupant's name.
local barSecretText = {}
-- Forward declaration. The SetText hook has to emit the tag INSIDE Details!' own
-- SetText call (see the long note at that site), and the hook is installed far
-- above the definition of EmitSealedTag. Without this the closure would capture a
-- global nil and the sealed path would silently never run.
local EmitSealedTag
-- Outcome counters for the sealed path. /dilvl debug could previously only say
-- that a sealed row carried no tag, never WHY. A row we cannot attribute is
-- expected and correct; a path that never runs at all is a bug, and the two used
-- to look identical from the outside.
local sealedStats = {emitted = 0, noGuid = 0, secretGuid = 0, noIlvl = 0, inline = 0, ticker = 0, ranked = 0}
-- How often Details! writes a bar text at all, split by whether the text was
-- sealed. Without this, the emit count above is an absolute with nothing to
-- compare it to: 160k looks like a runaway loop of ours, when it is simply how
-- often Details! redraws multiplied by the number of rows. `clean` is the same
-- work the readable path has always done at the same rate, so if clean and
-- secret run at a similar per-row rate, the sealed path costs nothing new.
-- Our own writes never reach here (isOurSetText returns above), so these count
-- Details! only.
local hookStats = {calls = 0, secret = 0, clean = 0, since = 0}
-- Does Details! prefix its rows with a rank ("1. Name") right now? Details!
-- reads its own instance.row_info.textL_show_number for this, but that is its
-- config table and none of our business, so we observe it instead: every row we
-- CAN read tells us directly whether a rank is there. Defaults to true because
-- that is Details!' own default, and because assuming a rank is the safe guess
-- — it keeps the rank column aligned, which is the visible failure mode.
local detailsShowsRank = true
-- Per-FontString record of what Details! last drew there: the rank as a plain
-- number and the display name on its own, BEFORE Details! welded them into one
-- string. Written only by the UpdateBarApocalypseWow post-hook, which is handed
-- both separately. This is what makes true "left" placement possible on a
-- sealed row: the pieces exist for exactly one call, and afterwards there is
-- only an opaque blob we may not cut.
--
-- The name half may be a secret. That is safe as a table VALUE (same as
-- barSecretText) and it is only ever passed to string.format as a %s argument.
--
-- CARRIES THE GUID IT WAS BUILT FROM, and every consumer must check it.
--
-- The note here used to claim the record was cleared in lockstep with
-- barSecretText so a recycled row could never re-emit the previous occupant.
-- That was wrong, and it is what hid the bug. A FontString is not a player, it
-- is a row SLOT that Details! hands to a different actor on every re-sort, and
-- Details! overwrites lineText1 in place (class_damage.lua:3199) without ever
-- blanking it — `ClearText()` appears nowhere in its entire source. So on a
-- sealed-to-sealed handover NEITHER clear site fires and the record survives
-- into the next occupant.
--
-- What that produced: the tag is composed from the row's CURRENT actorGUID
-- while the name and rank come from the record, so a row could render the
-- departed player's name beside the arriving player's item level. A wrong name
-- on screen is the one outcome this addon does not accept, so the guid travels
-- with the record and a mismatch discards it.
local barRankInfo = {}
local detailsMethodHooked = false
-- Forward declaration: installed from HookAllBars, defined below EmitSealedTag.
local TagRankedRow
local isOurSetText = false -- prevent recursion in SetText hook
local mapDirty = false -- rebuild nameToIlvl only when new inspect data arrived
local tickerStarted = false -- true only once C_Timer.NewTicker actually returned (what /dilvl debug reports)
local bootstrapArmed = false -- guard against scheduling the 3s login setup twice on rapid zoning
local selfBonusRetries = 0 -- bounded re-reads when our own tier items are not in the item cache yet
-- Group members whose LAST set-bonus read came back incomplete. This records the
-- RESULT ("no bonus established"), not the precondition ("was inspected"): it is
-- set only when GetSetBonusForUnit reported complete == false, and cleared the
-- moment a complete read lands. Keyed by the GUID from INSPECT_READY, which is
-- rejected earlier when secret, so this table never holds a secret key.
local sbIncomplete = {}
local NotifyElvUI -- forward declaration; assigned after Details_iLvlDisplayAPI is built
-- Defaults-merge / schema-migration / validators are defined further down
-- but referenced inside the ADDON_LOADED OnEvent closure, so they need
-- upvalue forward-declarations here (else Lua binds the names as globals
-- at closure-compile time and the calls silently no-op).
local CURRENT_SCHEMA_VERSION
local VALIDATORS
local RecursiveDefaultsMerge, MigrateSchema, ValidateDb
local openRaidLib = nil -- LibOpenRaid-1.0 handle; assigned after ADDON_LOADED if available
-- LibOpenRaid delivery counters. Deliberately NOT "is the library loaded": that
-- question answered "yes" for the entire time the callback was never registered
-- and not one value ever arrived. Every field here measures a RESULT.
--   lib        -> LibStub handed us the library
--   registered -> lib.RegisterCallback returned boolean true. On failure it
--                 returns an integer code instead, which we keep verbatim
--   updates    -> GearUpdate callbacks actually received this session
--   fromSelf   -> of those, how many were about us (LoR reports the player too)
--   stored     -> item levels written to the cache from LoR (callback + sweep)
--   pulled     -> of those, how many came from a LoRPullAllGear sweep
--   noToken    -> callbacks dropped because arg 1 was not a live unit
local lorHandler -- forward decl: the persistent addon object handed to LoR
local lorStats = {lib = false, registered = false, regCode = nil,
                  updates = 0, fromSelf = 0, stored = 0, pulled = 0, noToken = 0}
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
-- The live registry. A file-local, NOT a field on Details_iLvlDisplayAPI any
-- more: a public table is a public write, and the ownership check in
-- RegisterCallback would be decorative if one assignment could walk around it.
local _callbackRegistry = {}     -- name -> fn
local _callbackRefuseLogged = {} -- name -> bool, so a refusal is reported once, not per call
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
-- Display-only shortener. Unlike StripRealm this one may return a secret, so its
-- result must go straight into SetText and nowhere else (util.lua).
local ShortenForDisplay  = util.ShortenForDisplay

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
                -- Details!' pool is no fresher than ours. Fall through to what
                -- we measured ourselves rather than answering "nothing" -- see
                -- the note at the end of this function.
                return cached and cached.ilvl or nil
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

    -- LAST RESORT: the value we measured, however old it is.
    --
    -- CACHE_REFRESH is a RE-INSPECT horizon, not a display horizon. The comment
    -- at its declaration says so: "re-inspect if we can reach them". Using it to
    -- suppress the tag as well means the tag vanishes for anyone we can no
    -- longer reach — someone who left the group, or a stored segment from an
    -- earlier raid. No newer value is ever coming for them, so "wait for
    -- something fresher" is a promise that cannot be kept.
    --
    -- It also made the two renderers disagree about the same data.
    -- API.GetCacheData, which the Blizzard-meter path uses, reads ilvlCache with
    -- no age filter at all, so a two-hour-old entry tagged every row over there
    -- while these rows went blank. Live on 20.08.2026 that showed up as Details!
    -- losing its tags an hour after a raid: 35385 refusals for "no item level"
    -- against a cache that held every one of them. Nothing had broken; the
    -- entries had simply crossed 7200 seconds.
    --
    -- This does not weaken the freshness rule. Everything above still prefers a
    -- fresher source and the inspect pipeline still re-inspects on its own
    -- schedule. It only stops us throwing the answer away when no fresher one
    -- exists. What we measured is attributable; showing nothing while the meter
    -- beside it shows the number is just inconsistent.
    return cached and cached.ilvl or nil
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
                        -- Prefer the Name-Realm form via the roster (cross-realm asymmetry
                        -- fix); otherwise actor.nome, which is the combat-log name.
                        --
                        -- NOT actor.displayName. Details! documents the two apart:
                        --   Definitions.lua:601  displayName  "actor name shown in the
                        --                                      regular window"
                        --   Definitions.lua:610  nome         "name of the actor"
                        -- displayName is a RENDERED string and Details! rewrites it freely.
                        -- Two of the three paths are ON BY DEFAULT:
                        --   * a guild nickname replaces it outright
                        --     (container_actors.lua:644-651). ignore_nicktag defaults to
                        --     false (profiles.lua:1330) and the pool is fed over the GUILD
                        --     addon channel, so the string is authored by another player.
                        --     checkValidNickname constrains WHO, not WHAT — no similarity
                        --     check, so "Gandalf" for Ivan-Blackrock passes.
                        --   * remove_realm_from_name defaults to true (profiles.lua:980) and
                        --     strips the realm at :657-658, giving the bare "Torvi" for a
                        --     cross-realm player — the collision vector line 340 worries
                        --     about. (The ">" form at :802 is the PET branch; we filter
                        --     IsPlayer(), so it cannot reach us.)
                        --   * Translit is off by default, but romanises IN PLACE when on
                        --     (class_damage.lua:3921-3925), so one render anywhere leaves
                        --     the shared actor permanently carrying "!Ivan" for "Иван".
                        -- Any of those would have been persisted here as identity —
                        -- and blizzdm.lua:909 writes cached.name onto a Blizzard-owned row,
                        -- so we would have put a spelling we invented under someone's bar.
                        -- A name we cannot attribute is worse than no name, and nome is
                        -- never rewritten.
                        --
                        -- The reverse-lookup nameOnly fallback in ResolveGUIDByName still
                        -- covers any leftover bare entries.
                        local entry = ilvlCache[actor.serial]
                        if entry and not entry.name then
                            entry.name = ResolveFullNameByGuid(actor.serial)
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
        hookStats.calls = hookStats.calls + 1
        if hookStats.since == 0 then hookStats.since = GetTime() end
        SafeCall(function()
            -- Details! Itemlevelfinder passes "secret string" values to SetText.
            if isSecretValue(text) then
                hookStats.secret = hookStats.secret + 1
                barCleanText[self] = nil
                -- Keep it, unopened. This is the ONLY writer of barSecretText, and
                -- our own re-emission runs with isOurSetText true (guard at the top
                -- of this hook), so our tagged line can never be captured as
                -- Details!' original and the tag can never double.
                barSecretText[self] = text
                if db.layout == "columns" then
                    local cols = barColumns[bar]
                    if cols then
                        cols.ilvlFS:SetText("")
                        cols.ilvlFS:Hide()
                        cols.tierFS:SetText("")
                        cols.tierFS:Hide()
                    end
                    return
                end
                -- Tag the sealed row HERE, inside Details!' own SetText call —
                -- not only from the 2s ticker.
                --
                -- This is the fix for the flicker reported live on 20.08.2026. A
                -- row we CAN read is re-tagged synchronously on every redraw,
                -- because this hook runs inside Details!' SetText and appends
                -- before the frame is drawn; that path has never flickered. A
                -- SEALED row used to be tagged only by the ticker, so every
                -- Details! redraw left it bare until the next tick, up to two
                -- seconds later. The tag appeared and vanished, and that is what
                -- "Details blinkt" was. It also explains the apparent gaps: a
                -- screenshot catches whichever half of the cycle is showing.
                --
                -- Note this does NOT depend on how often Details! redraws. Once
                -- the tag is written in the same call as the text it belongs to,
                -- there is no frame in which the untagged version is on screen.
                --
                -- Identity is BETTER here than on the ticker, not worse: Details!
                -- assigns instanceLine.actorGUID at class_damage.lua:3129 and
                -- writes lineText1 at :3199 — same function, same call, GUID
                -- first. When we run, the GUID beside the secret is the one that
                -- belongs to it, not one left over from a previous occupant.
                --
                -- isOurSetText is set around the call so our own SetText hits the
                -- guard at the top of this hook: the tagged string can never be
                -- captured as Details!' original, so the tag cannot double.
                -- SafeCall keeps a throw from stranding isOurSetText as true,
                -- which would kill tagging silently for the rest of the session.
                if not db.showInDetails then return end
                if not IsDetailsWindowAllowed(bar.instance_id) then return end
                -- Same combat rule as every other write to a Details! FontString.
                if MayBeInCombat() then return end
                -- The renderer hook runs a few instructions later in this same
                -- call and will place the tag properly between rank and name.
                -- Writing the suffix form first would be two writes per row per
                -- repaint for a result that is immediately overwritten. Keyed on
                -- the row having been handled before, so a row the renderer hook
                -- cannot serve still gets its fallback tag from here.
                if db.ilvlPosition == "left" and barRankInfo[self] then return end
                sealedStats.inline = sealedStats.inline + 1
                isOurSetText = true
                SafeCall(EmitSealedTag, self, text, bar, db.ilvlPosition == "left")
                isOurSetText = false
                return
            end
            -- A non-secret string arrived: this row is not sealed any more. This
            -- MUST sit above the two guards below. Details! blanks a row with
            -- SetText("") when it reuses it, and that empty string returns early;
            -- clearing after the guards would strand the previous occupant's
            -- secret and repaint their name onto a row Details! just emptied.
            barSecretText[self] = nil
            barRankInfo[self] = nil
            hookStats.clean = hookStats.clean + 1
            if not text or type(text) ~= "string" or text:match("^%s*$") then return end
            if text:find("%[%d+%]") then return end

            -- Cache Details!'s clean text before we inject anything.
            local hasRank = text:match("^%d+%.%s") ~= nil
            if hasRank or not barCleanText[self] then
                barCleanText[self] = text
            end
            -- Learn the row layout from the rows we are allowed to read, so the
            -- sealed rows can be placed to match. Only rows that carry OUR tag
            -- already, or none, are evidence; a row we just wrote would report
            -- our own formatting back to us, but those never reach here because
            -- isOurSetText returns above.
            detailsShowsRank = hasRank

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
            barSecretText[self] = nil
            barRankInfo[self] = nil
        end)
    end
end

---------------------------------------------------------------
-- Scan and hook all Details! bars
---------------------------------------------------------------
local function HookOneInstance(instance)
    if not instance then return end

    HookInstanceResize(instance) -- hook resize event on the Details! window

    -- No bars: a window that exists in the array but was never built (closed
    -- window, or pre-init right after login). SKIP it, never abandon the scan.
    local bars = instance.barras
    if not bars then return end

    for i = 1, #bars do
        HookBarTextIfNeeded(bars[i])
    end
end

local function HookAllBars()
    if not Details then return end

    -- Details! keeps EVERY window in one array — open or closed — and exposes it
    -- through the public Details:GetAllInstances() (classes/class_instance.lua:1090,
    -- declared in that addon's public surface at Definitions.lua:300). Its own doc
    -- comment says it plainly: "these instance could be not initialized yet, some
    -- might be open, some not in use". Verified against the installed build
    -- #Details.20260811.15270.172.
    --
    -- The old "1..10 + break" loop was wrong twice:
    --   * `break` on a missing `barras` killed every window BEHIND a closed one.
    --     A closed window keeps its array slot and never gets its widgets
    --     rebuilt, so window 1 closed + window 2 open meant: bail at index 1 and
    --     tag NOTHING, in any window. That is a total blackout of the Details!
    --     channel, not a partial one.
    --   * the cap of 10 hid windows 11-30, and 30 is Details' own maximum.
    --
    -- pcall also covers a Details! without the accessor: pcall(nil, ...) returns
    -- false rather than throwing, so the Details! surface simply stays off and
    -- every other channel is untouched.
    local ok, instances = pcall(Details.GetAllInstances, Details)
    if not ok or type(instances) ~= "table" then return end

    for i = 1, #instances do
        HookOneInstance(instances[i])
    end

    -- Install the renderer hook once, from here, because this runs on the ticker
    -- and therefore also catches a Details! that loaded after us.
    --
    -- The type check is a version canary, not a formality: this is an internal
    -- renderer with an era-branded name, and Details! reworked its bar text on
    -- 2026-08-14. If a future build renames or removes it we simply never hook,
    -- and every sealed row keeps the suffix tag from EmitSealedTag instead of
    -- silently losing its item level. hooksecurefunc cannot be undone, so the
    -- decision is made once and the guard inside TagRankedRow does the rest.
    if not detailsMethodHooked and type(Details.UpdateBarApocalypseWow) == "function" then
        detailsMethodHooked = true
        local hooked = pcall(hooksecurefunc, Details, "UpdateBarApocalypseWow", TagRankedRow)
        if not hooked then detailsMethodHooked = false end
    end
end

---------------------------------------------------------------
-- EmitSealedTag -- the only path that can tag a row whose name Blizzard sealed.
--
-- We never author a name. The secret string Details! wrote is handed straight
-- back and our tag is spliced on inside the C formatter, so the rank, the name,
-- realm handling, transliteration, any custom left-text template and any
-- role/faction icon survive byte-for-byte -- we never decompose them. Details!
-- itself proves the primitive on this build: it runs format("%d. %s", rank,
-- secretName) and SetText on the result for exactly these rows on every refresh
-- (Details/classes/class_damage.lua:3199) and passes a bare secret to SetText at
-- :3204.
--
-- Identity comes off the ROW, never out of the text. bar.actorGUID is written by
-- the same UpdateBarApocalypseWow call that writes lineText1
-- (class_damage.lua:3129 vs :3199), so the GUID and the sealed string can never
-- describe different actors. It is declared on Details!' line class
-- (Details/frames/window_main.lua:4266, "can be secret while in combat") -- which
-- is why the isSecretValue guard is mandatory, not decorative: GetIlvlForGuid
-- compares the GUID (core.lua:305) and uses it as a table key (:306, :318), and
-- both throw on a secret. No GUID, a secret GUID, or no cached iLvl means no tag.
--
-- Only append/prepend is possible: splitting the secret to insert between rank
-- and name would throw. In "left" mode the tag therefore lands BEFORE the rank
-- ("[272] 3. Name"). A different position is not a wrong value; inventing the
-- rank in order to rebuild the line would be.
---------------------------------------------------------------
-- Does Details! put a rank in front of its rows right now?
--
-- This used to be inferred from whatever readable row was written last, and that
-- is wrong in a way that only shows up in a raid: Details! draws a Total bar
-- that is readable AND rank-less (class_damage.lua:1921/2000, class_heal.lua:444
-- /513, class_resources.lua:534/594). One pass over that row taught us "no
-- ranks", and every sealed row then took the prefix form that pushes the rank
-- column out of line — the exact fault the placement logic exists to prevent.
--
-- Ask Details! instead. row_info.textL_show_number is the flag its own renderer
-- branches on at class_damage.lua:3197, reached through the public
-- Details:GetInstance (same pcall pattern as the window gate above). The
-- observed value stays as the fallback for the moment before Details! is ready.
local function DetailsNumbersRows(bar)
    if Details and bar and bar.instance_id then
        local ok, inst = pcall(Details.GetInstance, Details, bar.instance_id)
        if ok and inst and inst.row_info and inst.row_info.textL_show_number ~= nil then
            return inst.row_info.textL_show_number and true or false
        end
    end
    return detailsShowsRank
end

EmitSealedTag = function(fontString, secret, bar, isLeft)
    -- Each bail is counted separately. "No GUID" and "GUID is itself secret" are
    -- different facts about Blizzard's restrictions, and "no cached iLvl" is not a
    -- restriction at all — it just means we have never inspected this player.
    -- Lumping them together is what made the sealed path impossible to diagnose.
    local guid = bar and bar.actorGUID
    if not guid then
        sealedStats.noGuid = sealedStats.noGuid + 1
        return
    end
    if isSecretValue(guid) then
        sealedStats.secretGuid = sealedStats.secretGuid + 1
        return
    end

    local ilvl = GetIlvlForGuid(guid)
    if not ilvl then
        sealedStats.noIlvl = sealedStats.noIlvl + 1
        return
    end

    local tag
    if db.colorIlvl then
        tag = GetIlvlColor(ilvl) .. "[" .. ilvl .. "]|r"
    else
        tag = "[" .. ilvl .. "]"
    end
    if db.showSetBonus then
        local sbTag = SetBonusTag(setBonusCache[guid])
        if sbTag then
            tag = tag .. " " .. sbTag
        end
    end

    -- Tag always travels as a %s ARGUMENT, never inside the format string, so a
    -- stray %-sign in a colour code or set-bonus mark cannot misformat the line.
    --
    -- "left" cannot mean the same thing here as it does on a readable row. There
    -- we split "1. " off the front and insert between rank and name; on a sealed
    -- row that split would throw, so the tag can only go in front of the whole
    -- string — rank included. When Details! is numbering its rows that shifts
    -- every sealed rank to the right while the readable ones stay at the edge,
    -- and in a raid nearly every row is sealed, so the list stops lining up.
    -- Reported live 20.08.2026.
    --
    -- BEST CASE FIRST. If the renderer hook has been here, the rank and the name
    -- were recorded separately before Details! welded them together, and we can
    -- put the tag exactly where it was asked to go — between them. This is the
    -- same composition Blizzard's own meter performs
    -- (Blizzard_DamageMeter/DamageMeterEntry.lua:550 and :568) and the same one
    -- Details! performs (class_damage.lua:3199): a plain number, plain text, and
    -- a secret name, all as %s arguments to one format. We invent nothing.
    local info = isLeft and barRankInfo[fontString]
    -- Only trust a record that describes THIS row's current occupant. Details!
    -- reassigns a row slot to another actor without blanking it, so the record
    -- outlives the player it was built for; see the note at its declaration.
    -- Both sides are already proven non-secret before this point (the guard at
    -- the top of this function, and the same guard in TagRankedRow), so the
    -- comparison cannot throw. A mismatch simply falls through to the fallback
    -- below, which hands Details!' own live text back: right data, second-choice
    -- placement.
    if info and info.guid ~= guid then info = nil end
    if info then
        if info.numbered then
            fontString:SetText(string.format("%d. %s %s", info.rank, tag, info.name))
        else
            fontString:SetText(string.format("%s %s", tag, info.name))
        end
        sealedStats.emitted = sealedStats.emitted + 1
        return
    end

    -- FALLBACK, for a row the renderer hook has not reached: Details! on a build
    -- whose renderer we no longer recognise, or a row drawn before we hooked.
    -- Here the rank is welded into the secret and cutting it out would throw, so
    -- the tag can only go in front of the whole string or behind it.
    --
    -- Prefix only when there is no rank to push: then "left" is exactly what it
    -- says. With a rank present, suffix instead — the tag lands on the far side
    -- of the name, which is not where it was asked to be, but the numbered list
    -- stays a numbered list. Placement is cosmetic; a broken column is not.
    if isLeft and not DetailsNumbersRows(bar) then
        fontString:SetText(string.format("%s %s", tag, secret))
    else
        fontString:SetText(string.format("%s %s", secret, tag))
    end
    sealedStats.emitted = sealedStats.emitted + 1
end

---------------------------------------------------------------
-- TagRankedRow — post-hook on Details!' row renderer.
--
-- WHY A SECOND HOOK EXISTS AT ALL. Our SetText hook sees the finished line,
-- "1. Playername", as one sealed string. Blizzard permits us to pass that string
-- back through string.format, but not to cut it, so from there the tag can only
-- go in front of the rank or behind the name — never between them, which is
-- where "left" is supposed to put it. Details:UpdateBarApocalypseWow is handed
-- the two halves separately (class_damage.lua:3106, writes at :3199), so hooking
-- the renderer instead of the text is the only way to honour the setting.
--
-- SAFETY OF THE COMPOSITION. Not a loophole: SimpleFontString:SetText is
-- annotated SecretArguments = "AllowedWhenTainted" with SecretArgumentsAddAspect
-- = {Enum.SecretAspect.Text} — the only setter family on that widget that has the
-- grant. Blizzard's own damage meter builds a row the same way, nesting
-- string.format over a ConditionalSecret name
-- (Blizzard_DamageMeter/DamageMeterEntry.lua:550, :568). Details! reached the
-- same conclusion: its secret and non-secret branches at class_damage.lua:3197
-- are byte-identical, both plain format.
--
-- WHY POST-HOOK IS ENOUGH. hooksecurefunc runs after the function body, and
-- nothing else writes lineText1 for this row afterwards: there is no second
-- write in the remainder of UpdateBarApocalypseWow, and the legacy renderer that
-- would call FitNameText is unreachable on 12.1 (Details:IsUsingBlizzardAPI
-- returns a hardcoded true, class_damage.lua:2117-2125). The old second writer
-- in core/parser_nocleu1.lua:2884 sits behind an unconditional "do return end"
-- at :2755. So our write is the final state of the row for this refresh, and it
-- lands in the same call — no frame ever shows the untagged version.
--
-- RANK IS TAKEN FROM THE END, NOT BY POSITION. The signature already moved once:
-- totalValue was inserted ahead of rank in May 2026, shifting it from argument 5
-- to 6. A positional read would have silently started formatting a damage total
-- as a rank. The last argument plus a type check survives that; if a future
-- change appends something else, the type check fails and we fall back to the
-- suffix form rather than printing nonsense.
---------------------------------------------------------------
-- SELF COMES FIRST. Details! declares the renderer with a colon
-- (function Details:UpdateBarApocalypseWow) and every call site invokes it the
-- same way, so the implicit `self` is a real argument and hooksecurefunc hands
-- the post-hook the full list: (Details, instanceLine, source, instance,
-- topValue, totalValue, rank). Taking the first parameter as the line silently
-- shifts everything by one — instanceLine becomes the Details table, its
-- lineText1 is nil, and the whole path bails on the very first guard. Live
-- 20.08.2026 that read "renderer hook ON, 0 rows placed": hooked, running, and
-- refusing every single row. The rank is still read from the END, so the extra
-- argument at the front costs nothing there.
local function TagRankedRowBody(instanceLine, source, ...)
    if not db or not db.enabled or not db.showInDetails then return end
    if db.layout ~= "inline" then return end
    -- Only "left" needs this path. "right" is a plain append, which the SetText
    -- hook already does correctly and more cheaply.
    if db.ilvlPosition ~= "left" then return end
    if MayBeInCombat() then return end
    if not instanceLine or not source then return end

    local fontString = instanceLine.lineText1
    if not fontString or not hookedFontStrings[fontString] then return end
    if not IsDetailsWindowAllowed(instanceLine.instance_id) then return end

    -- Readable rows are left alone on purpose. The SetText hook already splits
    -- "1. " off and inserts, which preserves Details!' own text byte for byte.
    -- Rebuilding one would gain nothing and risk changing what it shows.
    local name = source.name
    if name == nil or not isSecretValue(name) then return end

    local n = select("#", ...)
    local rank = n > 0 and select(n, ...) or nil
    if type(rank) ~= "number" then return end

    local guid = instanceLine.actorGUID
    if not guid or isSecretValue(guid) then return end
    local ilvl = GetIlvlForGuid(guid)
    if not ilvl then return end

    -- Reproduce Details!' own shortening for a sealed name, or the realm suffix
    -- would appear on rows where Details! had removed it (class_damage.lua:3182
    -- -3193: Ambiguate short when the source carries a spec icon, raw otherwise).
    if source.specIconID then
        name = ShortenForDisplay(name)
    end

    local tag
    if db.colorIlvl then
        tag = GetIlvlColor(ilvl) .. "[" .. ilvl .. "]|r"
    else
        tag = "[" .. ilvl .. "]"
    end
    if db.showSetBonus then
        local sbTag = SetBonusTag(setBonusCache[guid])
        if sbTag then tag = tag .. " " .. sbTag end
    end

    local numbered = DetailsNumbersRows(instanceLine)
    -- Recorded so the 2s ticker can reproduce this exact layout. Without it,
    -- every tick would revert an idle window to the fallback suffix form and the
    -- tag would jump back and forth.
    barRankInfo[fontString] = {rank = rank, name = name, numbered = numbered, guid = guid}

    isOurSetText = true
    if numbered then
        fontString:SetText(string.format("%d. %s %s", rank, tag, name))
    else
        fontString:SetText(string.format("%s %s", tag, name))
    end
    isOurSetText = false
    -- Deliberately NOT counted in sealedStats.emitted, which belongs to the
    -- fallback path whose attempts are the inline+ticker pair. Sharing one
    -- counter produced "28874 emitted of 3082 tried" in a live report — more
    -- hits than attempts, which nobody can read. Two paths, two lines.
    sealedStats.ranked = sealedStats.ranked + 1
end

-- The wrapper exists because this is the only code we run inside Details!' own
-- call stack, and it was the only write path in the addon without a net.
-- Details! iterates its row list with no pcall of its own
-- (class_damage.lua:1951), so a throw here would abandon the remaining rows and
-- put our file in the traceback of somebody else's addon.
--
-- SafeCall also brings the error budget and the auto-disable that every sibling
-- write path already has, so a persistent fault switches the Details! surface
-- off instead of erroring once per row, several times a second.
--
-- isOurSetText is restored unconditionally: SafeCall catches the throw but does
-- not unwind the flag, and a stranded `true` makes the SetText hook return early
-- for every row until some later pass happens to clear it.
TagRankedRow = function(_, instanceLine, source, ...)
    SafeCall(TagRankedRowBody, instanceLine, source, ...)
    isOurSetText = false
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
            else
                -- No clean text. Either Blizzard sealed this row (we kept the
                -- secret) or Details! has not drawn it yet (we did not). Only the
                -- first can be tagged, and barSecretText is exactly that test.
                -- SafeCall, not a bare call: this runs on the 2s ticker, and an
                -- uncaught throw would both spam the error and leave isOurSetText
                -- stuck true, silently killing the SetText hook for the session.
                local secret = barSecretText[fontString]
                if secret then
                    -- Still needed as a safety net even though the SetText hook now
                    -- emits inline: a row hooked AFTER Details! last wrote it (window
                    -- resize, a window opened later) has a stored secret that no
                    -- SetText call is going to arrive for on its own.
                    --
                    -- Counted as an ATTEMPT, like the inline one: both are incremented
                    -- before EmitSealedTag has decided anything, so inline + ticker is
                    -- how often we tried and `emitted` is how often it worked. The
                    -- report spells that out rather than inviting the sum.
                    sealedStats.ticker = sealedStats.ticker + 1
                    SafeCall(EmitSealedTag, fontString, secret, ownBar, isLeft)
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
        inspectStats.sent = inspectStats.sent + 1 -- counted AFTER the call left
        -- Safety timeout: if INSPECT_READY never fires (server throttle, player
        -- LoS'd mid-inspect, disconnect), unblock the queue after 15s. Capture
        -- the sweep generation so that a QueueGroupInspect in the meantime (it
        -- wipes the queue and bumps the generation) turns this stale timer into
        -- a no-op — otherwise it could start a SECOND ProcessNextInspect chain
        -- over the freshly-rebuilt queue (double inspects / out-of-order removal).
        local gen = inspectGeneration
        -- The guard no longer tests `isInspecting`. That was a PRECONDITION flag
        -- and the wrong one: two ProcessNextInspect chains can overlap, and when
        -- they do, the first timeout sets isInspecting = false and the second one
        -- then fails its own guard — so that request's guid stayed in
        -- pendingInspect forever, uncounted and unretried. `inspectGeneration ==
        -- gen` plus `pendingInspect[entry.guid]` already say exactly the right
        -- thing: THIS request, from THIS sweep, is still unanswered.
        C_Timer.After(15, function()
            if inspectGeneration == gen and pendingInspect[entry.guid] then
                isInspecting = false
                pendingInspect[entry.guid] = nil
                inspectStats.timedOut = inspectStats.timedOut + 1
                -- Put the entry BACK. It was table.remove'd off the head before the
                -- request went out and the old code never re-added it, so a
                -- timed-out player got no second chance in this sweep — and since
                -- nothing sweeps periodically (the 2s ticker does not call
                -- QueueGroupInspect; every call site is event-driven), a static
                -- group meant no second chance for the rest of the session.
                --
                -- The bound is entry-scoped on purpose. A guid-keyed budget would
                -- outlive the sweep and write off a player who was merely behind a
                -- loading screen, for the whole evening, with no reset on zoning.
                -- Bounding the entry cannot do that: the next sweep builds a fresh
                -- entry and the player gets a clean slate.
                local fails = (entry.timeouts or 0) + 1
                entry.timeouts = fails
                if fails < INSPECT_FAIL_LIMIT then
                    inspectStats.requeued = inspectStats.requeued + 1
                    table.insert(inspectQueue, entry) -- tail: everyone else goes first
                end
                C_Timer.After(0.5, ProcessNextInspect)
            end
        end)
    else
        -- Can't inspect right now (out of range, throttled, etc.).
        -- Re-queue up to 3 times so we retry after other players are done.
        -- Deliberately NOT a timeout strike: "I could not even ask" is a
        -- different outcome from "the server ignored me", and conflating them
        -- would spend the re-queue budget without ever sending a request.
        inspectStats.deferred = inspectStats.deferred + 1
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

---------------------------------------------------------------
-- LibOpenRaid-1.0 gear ingestion — ONE store path, two callers: the
-- "GearUpdate" callback (live comms) and LoRPullAllGear (a sweep of what the
-- library already holds). Kept in one function so the sweep cannot grow its
-- own, subtly different, secret handling.
---------------------------------------------------------------
local function LoRApplyGear(unit, gearInfo)
    if not unit or not ilvlCache then return false end
    -- isSecretValue covers issecrettable too. type() can NEVER tell us this —
    -- a secret keeps its underlying Lua type — and indexing a secret table
    -- throws, so this has to come before the field read.
    if isSecretValue(gearInfo) then return false end
    if type(gearInfo) ~= "table" then return false end
    local raw = gearInfo.ilevel
    if isSecretValue(raw) then return false end
    if type(raw) ~= "number" or raw <= 0 then return false end
    local guid = SafeUnitGUID(unit)
    if not guid then return false end -- restricted instance: no identity, no write
    if guid == SafeUnitGUID("player") then return false end -- self: GetAverageItemLevel is exact
    local ilvl = math.floor(raw)
    local existing = ilvlCache[guid]
    if existing and ilvl == existing.ilvl and (time() - existing.time) <= 300 then
        return false -- unchanged and fresh: nothing to store, nothing to notify
    end
    local name, realm = SafeUnitName(unit)
    if not name then return false end
    local storedName = (realm and realm ~= "") and (name .. "-" .. realm) or name
    ilvlCache[guid] = {ilvl = ilvl, time = time(), name = storedName, source = "lor",
        -- `stale` means "an INSPECT is owed", and only an INSPECT_READY may clear
        -- it. Two separate reasons, both load-bearing:
        --   1. Carry an existing flag. A boss kill flags the whole group and
        --      queues a re-inspect; LibOpenRaid re-broadcasts gear a few seconds
        --      after combat ends, so without this the LoR write would land first,
        --      clear the flag, and cancel the post-kill re-inspect for everyone.
        --   2. Raise one when we have never inspected this player. LoR gives us
        --      an item level, never a set bonus — that has exactly one producer
        --      for group members, the inspect path. A LoR write with no flag looks
        --      like a completed inspect: present, not stale, zero seconds old. The
        --      queue would then never ask, setBonusCache would stay empty, and the
        --      [2P]/[4P] tag would silently disappear for everyone LoR covers.
        --   3. Re-raise one once the inspect horizon has already expired. The early
        --      return above only fires for an UNCHANGED item level inside 300s, so
        --      every later delivery rewrites `.time` — and LibOpenRaid re-sends the
        --      whole group's gear a few seconds after EVERY combat drop, not only
        --      when something changed. Without this clause `.time` is refreshed
        --      faster than CACHE_REFRESH, the queue gate can never fire again, and
        --      the 2h re-inspect that retires a stale [2P]/[4P] sitting beside a
        --      fresh number is gone for everyone LoR covers. Deliberately NOT keyed
        --      on "the item level changed": our number comes from the inspect API
        --      and LoR's from GetAverageItemLevel, so a permanent 1-point disagreement
        --      would re-queue the entire raid after every pull. The horizon fires at
        --      most once per player per 2h and also catches an equal-ilvl tier swap.
        stale = (existing and existing.stale) or (setBonusCache[guid] == nil)
                or (existing and (time() - existing.time) >= CACHE_REFRESH) or nil}
    StoreNameIlvl(storedName, ilvl, guid)
    StoreNameIlvl(name, ilvl, guid)
    lorStats.stored = lorStats.stored + 1
    mapDirty = true
    NotifyElvUI(storedName)
    return true
end

---------------------------------------------------------------
-- Drain LibOpenRaid's stored gear for everyone currently in the group.
--
-- WHY: the callback only fires when a comm ARRIVES. Anything the library
-- received before we registered, and any update whose unit we could not
-- resolve, sits in its store and would otherwise never reach us. Details!
-- itself runs the same token sweep, so this is the supported pattern rather
-- than a private-namespace trick: GetUnitGear(unitId) is public and does the
-- token -> internal-key resolution itself.
--
-- The pcall is NOT defensive noise and must not be tidied away: the library
-- resolves the token through a raw name lookup and then uses that name as a
-- TABLE KEY, which throws inside the library when the name is secret.
--
-- @bRequest: also ask the group to re-broadcast. Public, no-ops when not
-- grouped, and refuses a second send inside 30s. Only the login sweep passes
-- true — a roster sweep must not make 39 people re-broadcast every time
-- someone zones in.
---------------------------------------------------------------
local function LoRPullAllGear(bRequest)
    if not openRaidLib or not ilvlCache then return end
    if type(openRaidLib.GetUnitGear) ~= "function" then return end
    if bRequest and type(openRaidLib.RequestAllData) == "function" then
        pcall(openRaidLib.RequestAllData)
    end
    local prefix, count = GetGroupInfo()
    for i = 1, count do
        local unit = prefix .. i
        if UnitExists(unit) and UnitIsPlayer(unit) then
            local ok, gearInfo = pcall(openRaidLib.GetUnitGear, unit)
            if ok and gearInfo and LoRApplyGear(unit, gearInfo) then
                lorStats.pulled = lorStats.pulled + 1
            end
        end
    end
end

-- Collapse a burst of GROUP_ROSTER_UPDATEs into ONE sweep. In a world boss raid
-- filling from 17 to 34 that event fires constantly; without this the sweep
-- would run dozens of times for a single arrival.
local lorPullPending = false
local function LoRSchedulePull(delay)
    if lorPullPending then return end
    lorPullPending = true
    C_Timer.After(delay, function()
        lorPullPending = false
        LoRPullAllGear()
    end)
end

-- The addon object handed to LibOpenRaid. It must be a PERSISTENT table with a
-- NAMED member: the library stores the pair {addonObject, "OnGearUpdate"} and
-- later calls addonObject["OnGearUpdate"](...), so both halves have to outlive
-- the registration call.
lorHandler = {}

-- Payload is (unitId, unitGearInfo, allUnitsGear). The library dispatches with
-- the PAYLOAD ONLY — no self, no event name — so the old body's leading `_`
-- slot shifted every argument by one and `unit` actually held the gear table.
-- arg 3 is deliberately not taken: we act on the one unit that changed, and the
-- sweep covers the rest.
function lorHandler.OnGearUpdate(unitId, unitGearInfo)
    lorStats.updates = lorStats.updates + 1
    if not unitId or isSecretValue(unitId) then return end
    -- The library resolves this from its own id cache, which is refreshed at the
    -- END of its roster handler — so an early comm can arrive carrying a bare
    -- name instead of a token. Most of those still resolve, because unit
    -- functions accept a group member's name; the ones that do not have no GUID,
    -- and without a GUID we do not store. The next sweep picks them up.
    if not UnitExists(unitId) then
        lorStats.noToken = lorStats.noToken + 1
        return
    end
    -- Both reads must SUCCEED before they may be compared. Inside a restricted
    -- instance SafeUnitGUID returns nil, and nil == nil would then count a total
    -- stranger as "about us" -- a counter lying in the release built to stop that.
    local selfGuid = SafeUnitGUID("player")
    local unitGuid = SafeUnitGUID(unitId)
    if selfGuid and unitGuid and unitGuid == selfGuid then
        lorStats.fromSelf = lorStats.fromSelf + 1
    end
    LoRApplyGear(unitId, unitGearInfo)
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
frame:RegisterEvent("CHALLENGE_MODE_MAPS_UPDATE")

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
                -- A non-number ilvl passes every `cached.ilvl` truthiness guard
                -- and is then concatenated into a tag. Clearing the field turns
                -- it into "not inspected yet" — a missing tag, which is fine.
                -- The entry itself is kept, matching the rule just above.
                if data.ilvl ~= nil and type(data.ilvl) ~= "number" then data.ilvl = nil end
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
            --
            -- HOW LoR REGISTRATION ACTUALLY WORKS:
            --   RegisterCallback(addonObject, event, callbackMemberName)
            -- stores the PAIR {addonObject, callbackMemberName} and later calls
            -- addonObject[callbackMemberName](payload...). So arg 3 must be the
            -- NAME of a member of arg 1. Passing the function itself makes the
            -- library's integrity check hit `not addonObject[callbackMemberName]`
            -- and return 3, and RegisterCallback then returns that 3 WITHOUT ever
            -- registering. That is exactly what the previous
            -- `lib.RegisterCallback({}, "GearUpdate", function(...) end)` did: it
            -- never registered once, it never errored, and the debug dump said
            -- "active" the whole time. The return value is the only proof of
            -- success, so we keep it and print it.
            if LibStub then
                local ok, lib = pcall(LibStub, "LibOpenRaid-1.0")
                if ok and lib then
                    lorStats.lib = true
                    if type(lib.RegisterCallback) == "function" then
                        openRaidLib = lib
                        local okReg, result = pcall(lib.RegisterCallback,
                            lorHandler, "GearUpdate", "OnGearUpdate")
                        lorStats.registered = (okReg and result == true) or false
                        if not lorStats.registered then
                            lorStats.regCode = okReg and tostring(result) or "error"
                        end
                    end
                end
            end
        end

    elseif event == "CHALLENGE_MODE_MAPS_UPDATE" then
        -- The server answering util's RequestMapInfo(). This is the only signal
        -- that the season reward levels have arrived, and without it a cold
        -- login is stuck on the fallback colour scale for the whole session:
        -- we derive the bands at PLAYER_ENTERING_WORLD, which on a fresh login
        -- is always before the data exists. Reported live on season 2 launch
        -- day, 2026-08-18 — every player above 280 painted orange.
        --
        -- Repaint only when the scale actually flipped. RetryIlvlBands is
        -- bounded, so a client that never receives reward data settles on the
        -- fallback instead of asking forever.
        if util.RetryIlvlBands() then
            RefreshAllBarTexts()
            NotifyElvUI()
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Drop the derived colour bands so the next lookup re-asks Blizzard
        -- for the season reward curve. Ten calls (four reward levels, six
        -- quality colours), paid once per LOADING SCREEN, not per login, and
        -- unconditional on purpose: this fires on every zone change too, and
        -- re-deriving costs less than reasoning about when a patch could have
        -- moved the ceiling under us. A stale ceiling is wrong in the one
        -- direction nobody looks at.
        util.ResetIlvlBands()
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

            -- LibOpenRaid has no public "ready" signal. The observable schedule
            -- instead: it calls RequestAllData itself at its first
            -- PLAYER_ENTERING_WORLD and only when already grouped; responders
            -- answer after 1-6s. So the sweep at 6s lands on a mostly-filled
            -- store and re-asks (its own 30s cooldown makes a duplicate request a
            -- no-op), and the 20s sweep catches slow responders and the "logged
            -- in solo, invited during the loading screen" case.
            -- Scheduled rather than called inline, so a throw here cannot be what
            -- stops the ticker — same reasoning as the two calls above.
            -- C_Timer.After passes no arguments, so the 20s call gets
            -- bRequest = nil and only drains: exactly one request per login.
            C_Timer.After(6, function() LoRPullAllGear(true) end)
            C_Timer.After(20, LoRPullAllGear)

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
        local storedIlvl = false -- RESULT flag: did this event actually produce a tag?

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
                    --
                    -- The FIRST read used to be exempt from that rule, and that is
                    -- the one case that puts a WRONG number on screen: a member
                    -- wearing four tier pieces of which two are not in the item
                    -- cache yet counts as two, and that "2P" was persisted into
                    -- SavedVariables and rendered. A missing tag is fine, a wrong one
                    -- is not — so an incomplete first read now records "known
                    -- nothing" instead, which is exactly what the player's own path
                    -- already does.
                    if sbComplete then
                        setBonusCache[guid] = setBonus or false
                        sbIncomplete[guid] = nil
                    else
                        if setBonusCache[guid] == nil then
                            setBonusCache[guid] = false -- first read: never a partial count
                        end
                        setBonus = setBonusCache[guid] or nil
                        sbIncomplete[guid] = true
                    end
                    -- Fallback to existing cached name if UnitName() returned nil
                    -- (unit token can go stale between queue and INSPECT_READY)
                    local cachedName = ilvlCache[guid] and ilvlCache[guid].name
                    ilvlCache[guid] = {ilvl = ilvlFloor, time = time(), name = fullName or name or cachedName, source = "inspect"}
                    lastInspectInfo = {name = fullName or name or cachedName, ilvl = ilvlFloor, time = GetTime()}
                    storedIlvl = true -- set at the WRITE, so `ok` counts stored data, not events
                    -- An incomplete set-bonus read leaves this entry unfinished, so
                    -- its fresh timestamp must not read as "done". Reuse the stale
                    -- flag the inspect queue already honours, and the member is
                    -- re-inspected on the next sweep instead of waiting for a boss
                    -- kill. Self-clearing: the next INSPECT_READY replaces this table.
                    if sbIncomplete[guid] then
                        ilvlCache[guid].stale = true
                    end
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
        -- Somebody else asked, we kept the answer. Counted separately so `sent`
        -- and `ok` stay honest about OUR pipeline while the dump still shows where
        -- the data actually came from.
        if storedIlvl and not pendingInspect[guid] then
            inspectStats.harvested = inspectStats.harvested + 1
        end
        if pendingInspect[guid] then
            pendingInspect[guid] = nil
            -- Count the OUTCOME, not the event. An INSPECT_READY carrying no
            -- readable item level is a completely different failure from one that
            -- never arrived, and only `ok` means a tag now exists. That is the
            -- difference between "the server ignores us" and "the server answers
            -- with nothing" in a pasted bug report.
            if storedIlvl then
                inspectStats.ok = inspectStats.ok + 1
            else
                inspectStats.empty = inspectStats.empty + 1
            end
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
            -- One coalesced LoR sweep per roster burst. On any group change every
            -- other member's library schedules a full send 5-11s later, and those
            -- arrive as callbacks — but a comm that lands before the library
            -- refreshes its id cache reaches us as a name we may not resolve, and
            -- is dropped by the no-token guard. 12s is past that window, and the
            -- sweep is token-driven and therefore always GUID-attributable.
            LoRSchedulePull(12)
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
    -- Sealed rows: put Details!' untouched secret back. Without this, turning the
    -- feature off would strand our tag on screen forever -- the segment is static
    -- after a fight, so nothing else will ever repaint those rows. pcall, not a
    -- bare call: a throw here would leave isOurSetText stuck true and silently
    -- kill the SetText hook for the rest of the session.
    for fontString, secretText in pairs(barSecretText) do
        if fontString:IsShown() then
            pcall(fontString.SetText, fontString, secretText)
        end
    end
    isOurSetText = false
    -- The per-row records describe rows we have just restored to Details!' own
    -- text, so none of them is valid any more.
    wipe(barRankInfo)
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
    -- Every key goes to the Blizzard meter, which decides for itself what the
    -- change means over there. Forwarding unconditionally instead of adding
    -- calls inside individual branches is the point: the branches below are
    -- organised around Details!-only concepts like db.layout, and anything
    -- parked inside one of them silently inherits a guard that has no meaning
    -- for the other renderer. That is how a Position change came to reach
    -- Details! and nothing else for four minor versions.
    if Details_iLvlDisplay_BlizzDMApplySetting then
        pcall(Details_iLvlDisplay_BlizzDMApplySetting, key)
    end
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
---------------------------------------------------------------
-- /dilvl debug — the full report.
--
-- Lifted out of the slash handler because that closure crossed Lua 5.1's hard
-- ceiling of 60 upvalues and the client refused to load the file: "function at
-- line 2741 has more than 60 upvalues". Six hundred lines of diagnostics
-- reaching into every counter in the addon is most of what that closure was
-- capturing, and none of it belongs to command parsing. Splitting it gives each
-- function its own upvalue budget.
--
-- Nothing here reads the command text, so it takes no argument.
---------------------------------------------------------------
local function PrintDebugReport()
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
        -- Which colour scale is actually in force. Without this the fallback is
        -- indistinguishable from a working derivation in a bug report, and the
        -- fallback is the quiet failure mode we care about.
        do
            local bands, derived = util.GetIlvlBands()
            local parts = {}
            for i = 1, #bands do
                parts[#parts + 1] = string.format("|cFF%s%d|r", bands[i][2], bands[i][1])
            end
            print(string.format("  iLvl colours: %s  (%s)",
                table.concat(parts, " "),
                derived and "derived from this season's M+ reward curve"
                        or "|cFFFFD100FALLBACK — reward curve unavailable|r"))
        end
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

        -- Count only members who are STILL HERE. sbIncomplete is keyed by GUID and
        -- is cleared solely by a later complete read for the same player, so anyone
        -- who left keeps their flag forever -- and the line below would then report
        -- people who logged off hours ago, while telling the reader that a number
        -- which never falls means the item cache is not filling.
        local sbPending = 0
        for i = 1, count do
            local sbGuid = SafeUnitGUID(prefix .. i)
            if sbGuid and sbIncomplete[sbGuid] then sbPending = sbPending + 1 end
        end
        if sbPending > 0 then
            -- A RESULT: these members were inspected but their tier items were not
            -- readable, so they carry no set-bonus tag on purpose. They are flagged
            -- stale and will be re-read by the next sweep. A number here that never
            -- falls is the signature of an item cache that is not filling.
            print(string.format("  Set bonus: %d member(s) awaiting a complete read", sbPending))
        end
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
        -- Read `emitted` first. Zero with attempts > 0 means the sealed path runs
        -- but never produces a tag, and the three skip reasons say which wall it
        -- hits. `inline` should dwarf `ticker` once Details! is drawing: inline is
        -- the flicker-free path, the ticker is only the safety net for rows hooked
        -- after their last redraw.
        if sealedStats.inline > 0 or sealedStats.ticker > 0 then
            print(string.format("  Sealed-row tags: %d emitted of %d tried (%d inline, %d ticker)  refused: %d no-GUID  %d secret-GUID  %d no-iLvl",
                sealedStats.emitted, sealedStats.inline + sealedStats.ticker,
                sealedStats.inline, sealedStats.ticker,
                sealedStats.noGuid, sealedStats.secretGuid, sealedStats.noIlvl))
            -- Separate counter from the fallback line above, on purpose. A high
            -- no-iLvl figure up there next to a high figure here is normal, not a
            -- fault: rows with no item level in the cache (pets, creatures) never
            -- get a per-row record, so the hook retries them on every repaint and
            -- correctly refuses every time.
            print(string.format("  Rank-aware placement: %s  %d rows placed between rank and name",
                detailsMethodHooked and "renderer hook ON" or "renderer hook OFF (fallback)",
                sealedStats.ranked))
        end
        -- Read the emit count above against THIS line, never on its own. Both
        -- numbers are driven by how often Details! redraws, which is none of our
        -- doing — and the clean/secret split shows whether the sealed path
        -- costs anything the readable path was not already costing.
        if hookStats.calls > 0 then
            local secs = math.max(1, GetTime() - hookStats.since)
            print(string.format("  Details! bar writes: %d in %ds = %.0f/s  (%d secret, %d clean)  rows: %d",
                hookStats.calls, math.floor(secs), hookStats.calls / secs,
                hookStats.secret, hookStats.clean, hookCount))
        end
        -- Resize-hook health (v1.5.3). installed=0 with attempts>0 means the
        -- OnSizeChanged hook never attached — that was the pre-1.5.3 bug (we read
        -- instance.baseFrame, Details! spells it baseframe). Expect installed>=1 per
        -- open Details! window, field=baseframe, and fired>0 after dragging the window edge.
        --
        -- READ `installed`, NOT `attempts`. Since v1.6 the scan walks every window
        -- Details! knows about instead of stopping at the first closed one, so
        -- `attempts` free-runs (the ticker re-scans every 2s) and `noFrame` climbs
        -- for as long as any window stays closed. Both are normal now; only
        -- installed=0 with an open window is a fault.
        print(string.format("  Resize-hook: %d installed / %d attempts  noFrame=%d  field=%s  fired=%d  refreshed=%d",
            resizeStats.installed, resizeStats.attempts, resizeStats.noFrame,
            tostring(resizeStats.field), resizeStats.fired, resizeStats.refreshed))
        print(string.format("  Queue: %d waiting  %d in flight  inspecting: %s  manualPause: %s",
            #inspectQueue, pendingCount, tostring(isInspecting), manualPause))
        -- Outcomes, not preconditions. The line above still only describes the
        -- queue's CURRENT shape, and "0 waiting" reads the same whether every
        -- player is cached or every request died. This line separates them:
        --   sent      NotifyInspect calls that really left
        --   ok        OUR answers that produced a stored item level (a visible tag)
        --   empty     OUR answers that stored nothing (unreadable, or the token moved on)
        --   timedOut  15s expiries — the server never answered
        --   requeued  timed-out players handed another turn
        --   deferred  turns skipped before spending a request (cannot inspect, or the
        --             queued token no longer resolves to that player)
        --   harvested stored from an inspect ANOTHER addon asked for. High harvested
        --             with low sent is normal in a group running Details!, and is the
        --             reason "1 sent  0 ok" can sit beside fresh item levels.
        print(string.format("  Inspects: %d sent  %d ok  %d empty  %d timed out  %d re-queued  %d deferred  %d harvested",
            inspectStats.sent, inspectStats.ok, inspectStats.empty,
            inspectStats.timedOut, inspectStats.requeued, inspectStats.deferred,
            inspectStats.harvested))
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
        print(string.format("  Details ready: %s  Ticker: %s  MapDirty: %s  Details!-HookErrors: %d/%d",
            tostring(detailsReady), tostring(tickerStarted), tostring(mapDirty),
            detailsBarErrors, DETAILS_BAR_ERROR_LIMIT))
        -- LibOpenRaid health. The old slot printed "active" for `openRaidLib ~= nil`
        -- — for "the library is installed" — which stayed true for the entire time
        -- the callback was never registered and not one value ever arrived. What is
        -- reported now: whether LoR ACCEPTED our registration (its own return code
        -- when it did not), and how many values we actually received and stored.
        -- Reading it: solo, `updates` ticks once per loading screen and is all
        -- fromSelf, with stored 0 — that is correct, not a fault. In a group,
        -- updates minus fromSelf at 0 means nobody else runs an addon embedding
        -- LoR. updates high with stored 0 means every value was a duplicate or was
        -- refused for lack of a GUID (restricted instance).
        local lorState
        if not lorStats.lib then
            lorState = "not installed"
        elseif lorStats.registered then
            lorState = "registered"
        else
            lorState = "NOT REGISTERED ("
                .. tostring(lorStats.regCode) .. ")"
        end
        print(string.format("  LibOpenRaid: %s  updates: %d (%d self)  stored: %d  from-sweep: %d  no-token: %d",
            lorState, lorStats.updates, lorStats.fromSelf, lorStats.stored,
            lorStats.pulled, lorStats.noToken))
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

end

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
            -- Where the value came from. Five shipped strings -- the login hint,
            -- both locales, the README and the changelog -- tell people to look
            -- for [LOR] in `/dilvl cache`, and until now that marker existed only
            -- in `/dilvl debug`. Sending users to a command that cannot show what
            -- was promised is a broken promise in five places at once.
            --
            -- source is only ever one of four literals this file writes itself,
            -- never anything that arrives from the game, so it cannot be secret
            -- and string.upper cannot throw on it.
            local src = data.source and ("[" .. string.upper(data.source) .. "] ") or ""
            print(string.format("  %s: %s%s|cFFFFD900%d|r iLvl %s(%s)%s",
                name, src, sb, data.ilvl, ageColor, ageStr, expiredNote))
            count = count + 1
            if age >= CACHE_REFRESH then expired = expired + 1 end
        end
        print(string.format("|cFF00FF00Details! iLvl Display:|r %d cached, %d expired", count, expired))

    elseif msg == "map" or msg:match("^map%s+") then
        -- Optional filter: /dilvl map atro  shows only matching names.
        -- Two reasons this is not decoration. A well-used cache runs to several
        -- hundred entries and the chat frame silently drops the top of the dump,
        -- so the unfiltered form is least readable exactly when it matters. And
        -- the question this command answers is almost always "does the SHORT form
        -- exist for this player" — Details! bars show "Name", the cache stores
        -- "Name-Realm", and a missing short form means a missing tag. Sorting puts
        -- the two forms on adjacent lines so the answer is one glance.
        -- The summary prints LAST so it survives the scrollback.
        local filter = msg:match("^map%s+(.+)$")
        local names = {}
        for n in pairs(nameToIlvl) do names[#names + 1] = n end
        table.sort(names)
        local shown = 0
        for i = 1, #names do
            local n = names[i]
            if not filter or n:lower():find(filter:lower(), 1, true) then
                shown = shown + 1
                local sb = nameToSetBonus[n]
                print(string.format("  %s: |cFFFFD900%d|r%s", n, nameToIlvl[n],
                    sb and (" [" .. sb .. "]") or ""))
            end
        end
        print(string.format("|cFF00FF00Details! iLvl Display:|r name map: %d shown of %d%s",
            shown, #names, filter and (" matching '" .. filter .. "'") or ""))

    elseif msg == "debug" then
        PrintDebugReport()
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
        -- A SECRET guid is truthy, so `not guid` waves it straight through and
        -- the table lookups below throw "attempt to use a secret value as a
        -- table key". type() cannot see it either: a secret GUID still reports
        -- "string". This is PUBLIC — the obvious third-party call is
        -- API.GetCacheData(UnitGUID(unit)), and inside a restricted instance
        -- that value IS secret, so the throw would land in our file with our
        -- addon's name on it, for someone else's mistake.
        if not guid or isSecretValue(guid) or not ilvlCache then return nil, nil end
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
        -- Same hole as GetCacheData, one function along: StripRealm hands a
        -- secret back UNCHANGED, so it survives into the `name == pName`
        -- comparison below, and comparing a secret throws. A secret name
        -- carries nothing we could resolve anyway.
        if not name or isSecretValue(name) then return nil end
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
    -- Live db reference, and it stays live on purpose. READ-ONLY BY CONTRACT
    -- for anything outside this addon: do not write through it.
    -- Not copied and not proxied, for two reasons. Our own kill switches write
    -- through it (blizzdm.lua:145, danders_integration.lua:177 and :265) and
    -- against a copy those writes would silently vanish — the auto-disable
    -- would fire, not persist, and the error loop it exists to stop would
    -- restart. And this is a per-frame call, so a copy would allocate a table
    -- per tagged unit per refresh. If an external consumer ever needs
    -- protection the answer is a scalar GetSetting(key) next to this one.
    GetDb = function() return db end,
    -- Callback registry — multiple consumers (elvui_tags, blizzdm) register here.
    -- Fires on: INSPECT_READY, UpdatePlayerCache, GROUP_ROSTER_UPDATE.
    -- The registry table is a file-local now (_callbackRegistry, top of file)
    -- and no longer a field here. It used to be `_callbacks = {}`, and a public
    -- table is a public write: one line of
    -- Details_iLvlDisplayAPI._callbacks.elvui = fn replaced our channel with no
    -- message anywhere, walking straight around the ownership rule below.
    --
    -- OWNERSHIP RULE: a name that is live OR parked belongs to whoever put the
    -- function there. Registering a DIFFERENT function under it is refused and
    -- reported; registering the SAME function is allowed, which is what keeps
    -- RestoreCallback working unchanged. Returns true when installed, false
    -- when refused. A refusal touches nothing — not the registry, not the
    -- error counters.
    RegisterCallback = function(self, name, fn)
        -- isSecretValue, not type(): a secret string still reports "string",
        -- and every line below uses `name` as a table key.
        if type(name) ~= "string" or isSecretValue(name)
           or type(fn) ~= "function" or isSecretValue(fn) then
            geterrorhandler()("Details! iLvl Display: RegisterCallback expects "
                .. "(name, fn) — a plain string and a function. Call it with "
                .. "a colon: API:RegisterCallback(name, fn).")
            return false
        end
        -- Parked counts as taken: the callback is on its way back through
        -- RestoreCallback and the slot is still its owner's.
        local held = _callbackRegistry[name] or _callbackParked[name]
        if held and held ~= fn then
            if not _callbackRefuseLogged[name] then
                _callbackRefuseLogged[name] = true
                geterrorhandler()("Details! iLvl Display: callback name [" .. name
                    .. "] is already in use — pick a unique one. Nothing was changed.")
            end
            return false
        end
        local wasLive = _callbackRegistry[name] ~= nil
        _callbackRegistry[name] = fn
        if not wasLive then
            -- Fresh budget ONLY when the slot was actually vacant (first
            -- install, or a restore after auto-unregister). Re-registering over
            -- a LIVE callback must not wipe its error count, or the
            -- CALLBACK_ERROR_LIMIT kill switch below could be defeated forever
            -- by re-registering after every error.
            _callbackErrors[name] = nil
            _callbackErrorLogged[name] = nil
        end
        return true
    end,
    UnregisterCallback = function(self, name)
        if type(name) ~= "string" or isSecretValue(name) then return false end
        _callbackRegistry[name] = nil
        _callbackErrors[name] = nil
        _callbackErrorLogged[name] = nil
        _callbackParked[name] = nil
        _callbackRefuseLogged[name] = nil
        return true
    end,
    -- Bring a parked callback back after the error that killed it is gone
    -- (ElvUI finished its profile switch, Grid2 reloaded its layout).
    -- Called from the /dilvl elvui|grid2 on branches, which reset the
    -- counters anyway. No-op if nothing is parked under that name.
    RestoreCallback = function(self, name)
        if type(name) ~= "string" or isSecretValue(name) then return false end
        local parked = _callbackParked[name]
        if not parked or _callbackRegistry[name] then return false end
        -- Register FIRST, unpark only on success. The old order cleared the
        -- park and then called RegisterCallback, which could not fail. It can
        -- now, and a refusal after the clear would throw the parked function
        -- away for the session — the exact outcome parking exists to prevent.
        if not self:RegisterCallback(name, parked) then return false end
        _callbackParked[name] = nil
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
    -- LibOpenRaid delivery counters for the diagnostics page. Returns a COPY:
    -- the page renders the session counters, it must not be able to reset them.
    GetLoRDebug = function()
        return {
            lib = lorStats.lib, registered = lorStats.registered,
            regCode = lorStats.regCode, updates = lorStats.updates,
            fromSelf = lorStats.fromSelf, stored = lorStats.stored,
            pulled = lorStats.pulled, noToken = lorStats.noToken,
        }
    end,
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
    local registry = _callbackRegistry
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
