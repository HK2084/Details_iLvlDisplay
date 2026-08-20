-- Details! Item Level Display — Copyright (c) 2026 HK2084. All rights reserved.
-- Licensed for private use only; see LICENSE. No redistribution of modified copies.
-- blizzdm.lua — Blizzard Damage Meter iLvl overlay
-- Shows iLvl (and tier set bonus) next to player names on WoW's built-in
-- damage meter (Blizzard_DamageMeter, added in 12.0).
--
-- SAFE TO LOAD WITHOUT BLIZZARD DM: if the Mixin doesn't exist (Classic,
-- or Blizzard removes/renames it in a future patch) this file does nothing.
--
-- DESIGN: defensive against future Blizzard DM changes.
--   - Hooks UpdateName to inject iLvl after Blizzard sets clean text
--   - Listens for DAMAGE_METER_COMBAT_SESSION_UPDATED to refresh
--   - Uses DamageMeter:ForEachSessionWindow to iterate visible frames
--   - READ-ONLY: never modifies Blizzard frame fields (nameText etc.)
--   - Never calls frame:UpdateName() — avoids taint + stack overflow
--   - Never calls C_DamageMeter APIs directly
--   - When the native FontString is locked by secret text we leave it alone
--     and skip the tag; there is no overlay FontString (an earlier design
--     claimed one, but it was never created — the branches were removed)
--   - issecretvalue/issecrettable guards before any field read
--   - If any global is missing → silent exit, no errors
--
-- TOGGLE: /dilvl blizzdm  (saved between sessions, default ON)

-- Guard: Blizzard_DamageMeter must be loaded
if not DamageMeterEntryMixin then return end
if not DamageMeter then return end

local API = Details_iLvlDisplayAPI
if not API then return end

---------------------------------------------------------------
-- Secret value guards — read from the shared defense layer in
-- secrets.lua (#26). The pcall hardening in SafeUnitName covers
-- tainted-execution hard-rejects (UnitName.RequiresDeclassifiedUnitIdentity
-- FailureMode flipped to ReturnWithError in 12.0.7).
---------------------------------------------------------------
local isSecret             = API.isSecretValue
                            or function(val) return issecretvalue and issecretvalue(val) end
local _hasanysecretvalues  = API.hasanysecretvalues
                            or (hasanysecretvalues or function() return false end)
local SafeUnitName         = API.SafeUnitName
                            or function() return nil end
local SafeUnitGUID         = API.SafeUnitGUID  or function() return nil end

---------------------------------------------------------------
-- The rank prefix Blizzard draws in front of a name is LOCALISED, and it is
-- not always a full stop:
--     enUS/deDE/koKR/ruRU   "%d. %s"
--     zhCN                  "%d、%s"      (U+3001)
--     zhTW                  "%d。%s"      (U+3002)
-- Three places used to hardcode "^%d+%." — two identity fallbacks that read
-- Blizzard's rendered text, and the split that keeps the rank in front of our
-- tag. On a Chinese client none of them matched: the fallbacks silently
-- resolved nothing and the rank was pushed off the line. A missing tag, never
-- a wrong one, which is why it could sit there unnoticed.
--
-- Derived from Blizzard's own format string rather than enumerated, so a locale
-- we have not looked at is covered too. gsub escapes byte-wise, which is what
-- we want: the multi-byte separators come out as literal bytes in the pattern.
--
-- NOTE: this is for BLIZZARD's meter only. Details! hardcodes ". " in every
-- language (Details-Damage-Meter/boot.lua:1332), so the patterns in core.lua
-- and util.lua are correct as they stand and must NOT be switched over.
---------------------------------------------------------------
local RANK_CAPTURE, RANK_SPLIT
do
    local fmt = DAMAGE_METER_SOURCE_NAME
    local sep = type(fmt) == "string" and fmt:match("^%%d(.-)%%s$") or nil
    if sep and sep ~= "" then
        local escaped = sep:gsub("(%W)", "%%%1")
        RANK_CAPTURE = "^%d+" .. escaped .. "%s*(.+)"
        RANK_SPLIT   = "^(%d+" .. escaped .. "%s*)(.*)"
    else
        RANK_CAPTURE = "^%d+%.%s*(.+)"
        RANK_SPLIT   = "^(%d+%.%s*)(.*)"
    end
end
-- Realm stripper. Never Ambiguate directly — see util.StripRealm. The
-- fallback keeps this file working even if core.lua is older than this one.
local StripRealm           = API.StripRealm
                            or function(n)
                                   if type(n) ~= "string" then return n end
                                   return n:match("^([^%-]+)") or n
                               end
-- Combat-state wrappers from secrets.lua (via the API). IsInCombatSafe treats a
-- secret/unknown InCombatLockdown as OUT of combat — exactly this file's
-- long-standing rule that "only an explicit true counts as in combat", so the
-- existing `== true` / `~= true` checks keep their meaning. InCombatRaw is for
-- the /dilvl debug dump only; its one caller tests isSecret() before comparing.
local IsInCombatSafe       = API.IsInCombatSafe or function() return false end
local InCombatRaw          = API.InCombatRaw    or function() return false end

-- IsEncounterInProgress() is deprecated in 12.0 (it survives only on the
-- loadDeprecationFallbacks compat shim and is slated for removal at 13.0).
-- The canonical API is C_InstanceEncounter.IsEncounterInProgress(). Cache it
-- at load with a fallback so all call sites below migrate transparently; the
-- secret-return handling (only `== true` counts as in-progress) is unchanged.
local IsEncounterInProgress = (C_InstanceEncounter and C_InstanceEncounter.IsEncounterInProgress)
                            or IsEncounterInProgress

-- frame:GetNameText() is a Blizzard DamageMeter mixin method that INTERNALLY
-- compares the secret field sourceDisplayType (DamageMeterEntry.lua:87). Inside a
-- restricted instance that compare throws *inside the call* in our tainted context
-- ("secret ... while tainted by Details_iLvlDisplay") — before it ever returns, so
-- a result-side isSecret() guard cannot help: the pcall must wrap the CALL itself.
-- Returns the name, or nil on throw/secret → caller falls through to its next name
-- source. NEVER call frame:GetNameText() raw.
local function SafeGetNameText(frame)
    if not frame.GetNameText then return nil end
    local ok, t = pcall(frame.GetNameText, frame)
    if ok and t and not isSecret(t) then return t end
    return nil
end

---------------------------------------------------------------
-- Local fault isolation.
-- Counter resets on /reload (non-persistent). disableSelf flips
-- db.blizzDM = false (NOT db.enabled — master switch stays user-owned)
-- and routes a one-shot message via geterrorhandler() (BugSack picks
-- it up). Other integrations are unaffected.
---------------------------------------------------------------
local BLIZZDM_ERROR_LIMIT = 5
-- priorDb: stash db.blizzDM tristate (nil/true/false) BEFORE auto-disable
-- so /dilvl blizzdm reset restores the user's prior auto/manual setting
-- (instead of leaving them stuck on forced-OFF after a transient error).
-- resetCount + lastResetReason track GAVE-UP-lock smart-resets (v1.4.2). The
-- 3-retry budget is preserved; counters wipe only on real trigger events
-- (cache-write per player, PLAYER_REGEN_ENABLED, roster-leave). Surfaced in
-- /dilvl debug so behavior is observable without /reload.
local blizzDMState = { errors = 0, lastError = nil, disabled = false, priorDb = nil,
                       resetCount = 0, lastResetReason = nil }

-- Rows we deliberately left alone because the identity was only guessed and the
-- name was unreadable. Shown in /dilvl debug: a number here is the feature
-- working as intended (no invented names), not a fault.
local unverifiedNameSkips = 0

-- Forward-declared for disableBlizzDMSelf, for the same reason ScheduleRefresh
-- is forward-declared further down: the auto-disable sets db.blizzDM = false,
-- and from that instant RefreshAllFrames early-returns, so no row is ever
-- written again. Whatever tags are on screen at that moment would stay there
-- for the rest of the session.
local StripAllTags
-- Same reason, one line further: IsGroupInCombat is defined ~230 lines below.
-- A Lua closure binds its upvalues where it is CREATED, so without this
-- declaration the call inside disableBlizzDMSelf would compile as a global read,
-- resolve to nil at runtime and throw — inside the very handler whose job is to
-- shut things down cleanly after a throw.
local IsGroupInCombat

local function disableBlizzDMSelf(reason)
    if blizzDMState.disabled then return end
    blizzDMState.disabled = true
    local db = API.GetDb()
    if db then
        blizzDMState.priorDb = db.blizzDM -- preserve nil (auto) / true / false
        db.blizzDM = false
    end
    -- Leave no orphans behind. We are shutting down because something threw, so
    -- the cleanup is itself pcall'd — a second throw here must not recurse into
    -- the kill-switch. In combat there is nothing to strip: PLAYER_REGEN_DISABLED
    -- already did it, and writing then would be the taint we are avoiding.
    if StripAllTags and IsGroupInCombat and not IsGroupInCombat() then
        pcall(StripAllTags)
    end
    pcall(geterrorhandler(),
        "Details! iLvl Display: Blizzard DM integration auto-disabled after "
        .. BLIZZDM_ERROR_LIMIT .. " errors. Recovery: /dilvl blizzdm. Last: " .. tostring(reason))
end

local function SafeBlizzCall(label, fn, ...)
    if blizzDMState.disabled then return nil end
    if blizzDMState.errors >= BLIZZDM_ERROR_LIMIT then return nil end
    local ok, a, b, c = pcall(fn, ...)
    if ok then
        -- Success clears accumulated errors: the kill-switch should trip on 5
        -- CONSECUTIVE failures (a persistently broken integration), not on 5
        -- transient errors spread across a long session.
        blizzDMState.errors = 0
        return a, b, c
    end
    blizzDMState.errors = blizzDMState.errors + 1
    blizzDMState.lastError = ("[%s] %s"):format(label, tostring(a))
    if blizzDMState.errors >= BLIZZDM_ERROR_LIMIT then
        disableBlizzDMSelf(blizzDMState.lastError)
    end
    return nil
end

-- Public reset for /dilvl blizzdm (toggle path) and debug section.
-- Returns (wasDisabled, priorDb): if wasDisabled is true, caller should
-- restore db.blizzDM to priorDb (which may be nil/auto, true, or false)
-- to preserve the user's tristate intent across auto-disable + recovery.
Details_iLvlDisplay_BlizzDMReset = function()
    local wasDisabled = blizzDMState.disabled
    local prior = blizzDMState.priorDb
    blizzDMState.errors = 0
    blizzDMState.lastError = nil
    blizzDMState.disabled = false
    blizzDMState.priorDb = nil
    return wasDisabled, prior
end

Details_iLvlDisplay_BlizzDMState = function()
    return blizzDMState, BLIZZDM_ERROR_LIMIT
end

---------------------------------------------------------------
-- Event trace for post-combat debugging.
-- Toggle: /dilvl blizztrace
-- Logs combat→OOC event sequence + frame secret state.
---------------------------------------------------------------
local traceEnabled = false
local traceLog = {}
local MAX_TRACE = 200

local function trace(msg)
    if not traceEnabled then return end
    local t = GetTime()
    local entry = format("%.1f %s", t, msg)
    table.insert(traceLog, entry)
    if #traceLog > MAX_TRACE then table.remove(traceLog, 1) end
end

local function traceFrameState(tag, detailed)
    if not traceEnabled then return end
    if not DamageMeter or not DamageMeter.ForEachSessionWindow then return end
    local total, secret, tagged, noGuid = 0, 0, 0, 0
    local ok, err = pcall(function()
        DamageMeter:ForEachSessionWindow(function(sw)
            if not sw.ForEachEntryFrame then return end
            sw:ForEachEntryFrame(function(frame)
                total = total + 1
                if not frame._dilvlGUID then noGuid = noGuid + 1 end
                local nameFS = frame.GetName and frame:GetName()
                if not nameFS or type(nameFS) == "string" then return end
                local hasTxt, txt = pcall(nameFS.GetText, nameFS)
                if not hasTxt or not txt or isSecret(txt) then
                    secret = secret + 1
                else
                    if type(txt) == "string" and txt:find("%[%d+%]") then tagged = tagged + 1 end
                end
                -- Detailed per-frame log: what data is readable right now?
                if detailed then
                    local sn = frame.sourceName
                    local snS = (not sn and "nil") or (isSecret(sn) and "SEC") or tostring(sn):sub(1,15)
                    local nt = frame.nameText
                    local ntS = (not nt and "nil") or (isSecret(nt) and "SEC") or tostring(nt):sub(1,20)
                    local gnt = SafeGetNameText(frame)
                    local gntS = (not gnt and "nil") or (isSecret(gnt) and "SEC") or tostring(gnt):sub(1,20)
                    local lp = frame.isLocalPlayer == true and "YOU" or ""
                    local gd = frame._dilvlGUID and "GUID" or "noGUID"
                    trace(format("  [%d] sn=%s nt=%s gnt=%s %s %s",
                        total, snS, ntS, gntS, gd, lp))
                end
            end)
        end)
    end)
    if ok then
        trace(format("[%s] frames=%d secret=%d tagged=%d noGuid=%d",
            tag, total, secret, tagged, noGuid))
    else
        trace(format("[%s] ERROR: %s", tag, tostring(err)))
    end
end

---------------------------------------------------------------
-- Taint-safety self-test (/dilvl taint).
-- Actively pcall-probes the Blizzard DamageMeter entry-mixin surface we call
-- into and classifies every foreign call as ok / secret-result / THROWS. A
-- THROWS line is the v1.5.2 taint-crash class: a mixin method (e.g. GetNameText,
-- which internally compares the secret sourceDisplayType) that throws *inside
-- the call* while our execution is tainted — the exact failure SafeGetNameText /
-- SafeBlizzCall exist to absorb. Running this inside a restricted instance
-- BEFORE a release surfaces such a call as a diagnostic line instead of a live
-- crash. Read-only; every probe is pcall-wrapped so the test can never error.
---------------------------------------------------------------
-- Probes a mixin method RAW inside a pcall — deliberately NOT via SafeGetNameText,
-- because the whole point is to detect whether the raw call throws (which the safe
-- wrapper would silently swallow). Dynamic index, so the mixin-lint's ':Method('
-- rule does not flag it, and it stays pcall-guarded regardless.
local function probeCall(frame, method)
    if not frame[method] then return "n/a" end
    local ok, res = pcall(frame[method], frame)
    if not ok then return "THROWS(" .. tostring(res):gsub("[\r\n]", " "):sub(1, 48) .. ")" end
    if res == nil then return "nil" end
    if isSecret(res) then return "SECRET" end
    if type(res) == "string" then return "ok'" .. res:sub(1, 16) .. "'" end
    return "ok:" .. type(res)
end

local function fieldState(v)
    if v == nil then return "nil" end
    if isSecret(v) then return "SECRET" end
    if type(v) == "string" then return "'" .. v:sub(1, 16) .. "'" end
    return tostring(v):sub(1, 16)
end

-- Returns an array of report lines (strings). Never throws.
function Details_iLvlDisplay_BlizzDMSelfTest()
    local out = {}
    local function add(s) out[#out + 1] = s end
    add("=== BlizzDM taint-safety self-test ===")
    add(format("env: DamageMeter=%s  DamageMeterEntryMixin=%s  killswitch=%s(err=%d)",
        DamageMeter and "loaded" or "MISSING",
        DamageMeterEntryMixin and "present" or "MISSING",
        tostring(blizzDMState.disabled), blizzDMState.errors))
    add(format("state: IsInCombatSafe=%s  encounterInProgress=%s",
        tostring(IsInCombatSafe()), tostring(IsEncounterInProgress() == true)))
    if not (DamageMeter and DamageMeter.ForEachSessionWindow) then
        add("No session-window iterator — open Blizzard's damage meter and re-run (ideally in a restricted instance, in combat).")
        return out
    end
    local frames, throws, secretFrames, sampled = 0, 0, 0, 0
    local ok, err = pcall(function()
        DamageMeter:ForEachSessionWindow(function(sw)
            if not sw.ForEachEntryFrame then return end
            sw:ForEachEntryFrame(function(frame)
                frames = frames + 1
                local gnt = probeCall(frame, "GetNameText")
                if gnt:find("THROWS", 1, true) then throws = throws + 1 end
                local sdt = fieldState(frame.sourceDisplayType) -- the field GetNameText compares
                local sn  = fieldState(frame.sourceName)
                local nt  = fieldState(frame.nameText)
                if sdt == "SECRET" or sn == "SECRET" or nt == "SECRET" then
                    secretFrames = secretFrames + 1
                end
                if sampled < 8 then
                    sampled = sampled + 1
                    add(format("  [%d]%s GetNameText=%s | sourceDisplayType=%s sourceName=%s nameText=%s",
                        frames, frame.isLocalPlayer == true and "*" or "", gnt, sdt, sn, nt))
                end
            end)
        end)
    end)
    if not ok then
        add("ITERATION-ERROR: " .. tostring(err))
        return out
    end
    add(format("totals: frames=%d  GetNameText-THROWS=%d  secret-field-frames=%d", frames, throws, secretFrames))
    if throws > 0 then
        add(">>> TAINT-CRASH CLASS ACTIVE: GetNameText throws on " .. throws
            .. " frame(s). The raw call is unsafe here — SafeGetNameText/SafeBlizzCall are absorbing it. Never call it raw.")
    elseif frames == 0 then
        add("No entry frames found (meter empty). Re-run after a fight with the meter visible.")
    else
        add("OK: no foreign-mixin call currently throws. Re-run inside a restricted instance IN COMBAT to stress the secret path.")
    end
    add("(* = local player. SECRET = value is secret-wrapped right now. Probe is read-only and self-contained.)")
    return out
end

---------------------------------------------------------------
-- Combat state tracking.
-- We skip injection entirely when ANYONE in the group is in combat,
-- not just the player. Blizzard's Secret Value system locks down
-- sourceName, nameText, and FontString content (ConditionalSecret)
-- for the entire group during combat. Reading these fields risks
-- getting secret values that break our display logic.
-- Blizzard is continuously tightening secret restrictions (April 2026:
-- UnitIsUnit hotfix, more expected). Safest approach: only inject
-- when the entire group is out of combat. We refresh on
-- PLAYER_REGEN_ENABLED + delayed passes for stale FontStrings.
---------------------------------------------------------------
local inCombat = false
local globalFontFile = nil     -- cached from first CLEAN frame: font file path
local globalFontSize = nil     -- cached from first CLEAN frame: font size
local globalFontFlags = nil    -- cached from first CLEAN frame: font flags ("OUTLINE" etc.)
local globalTextScale = nil    -- cached from first CLEAN frame: Blizzard's runtime text scale
do
    local icl = IsInCombatSafe()
    -- InCombatLockdown() is a plain bool in 12.0.x (NOT secret — verified against
    -- RestrictedActionsDocumentation). IsInCombatSafe() just routes it through the
    -- wrapper for invariant uniformity (secret => false defensively). The real
    -- secret risk is the combat EVENT args, handled in PLAYER_IN_COMBAT_CHANGED.
    -- Only an explicit true counts as in combat.
    if icl == true then inCombat = true end
end

-- Combat guard: should we inject right now?
-- Only checks OUR combat state + boss encounter.
-- In LFR, someone in the 25-man raid is almost ALWAYS in combat
-- (tank pulls next trash before everyone is OOC). Scanning all
-- members with UnitAffectingCombat blocked us permanently.
-- Our own REGEN events + IsEncounterInProgress is sufficient:
-- secrets on OUR frames unlock when WE leave combat.
function IsGroupInCombat()
    if inCombat then return true end
    local eip = IsEncounterInProgress()
    -- IsEncounterInProgress() can return secret in instances — treat as false
    if eip == true then return true end
    return false
end

---------------------------------------------------------------
-- Build iLvl tag string from GUID (reuses core.lua API)
---------------------------------------------------------------
local function BuildTag(guid)
    local db = API.GetDb()
    if not db or not db.enabled then return nil end

    -- blizzDM: nil = auto (ON when Details! absent), true = forced ON, false = forced OFF
    if db.blizzDM == false then return nil end
    if db.blizzDM == nil and Details then return nil end

    local cached, setBonus = API.GetCacheData(guid)
    if not cached or not cached.ilvl then return nil end

    local isLeft = db.ilvlPosition == "left"
    local prefix = isLeft and "" or " "
    local tag
    if db.colorIlvl then
        tag = prefix .. API.GetIlvlColor(cached.ilvl) .. "[" .. cached.ilvl .. "]|r"
    else
        tag = prefix .. "[" .. cached.ilvl .. "]"
    end

    if db.showSetBonus then
        local sbTag = API.SetBonusTag(setBonus)
        if sbTag then tag = tag .. " " .. sbTag end
    end

    return tag
end

---------------------------------------------------------------
-- Strip our iLvl/tier tags from a text string.
-- Used by StripAllTags (combat start) and ResolveFrameGUID
-- (parse nameText for roster lookup).
---------------------------------------------------------------
local function StripTagFromText(txt)
    if not txt or type(txt) ~= "string" then return txt end
    -- Strip colored iLvl tags: " |cFFxxxxxx[245]|r" or "|cFFxxxxxx[245]|r "
    -- Left-position places tag AFTER rank with trailing space, right-position
    -- places tag at end with leading space. Handle both with surrounding %s*.
    txt = txt:gsub("%s*|c%x%x%x%x%x%x%x%x%[%d+%]|r%s*", " ")
    -- Strip uncolored iLvl tags: " [245]" or "[245] "
    txt = txt:gsub("%s*%[%d+%]%s*", " ")
    -- Strip colored tier tags: " |cFF00FF00[2P]|r", " |cFF9D9D9D[4P]|r".
    -- The colour VARIES since season colouring (green = current season, grey
    -- = older), so this must stay a wildcard match and must never be narrowed
    -- to one code — a tag we fail to strip is a tag that doubles up.
    txt = txt:gsub("%s*|c%x%x%x%x%x%x%x%x%[%d[PT]%]|r%s*", " ")
    -- Collapse any double spaces and trim
    txt = txt:gsub("  +", " ")
    txt = txt:match("^%s*(.-)%s*$") or txt
    return txt
end

---------------------------------------------------------------
-- Resolve GUID for a DamageMeter entry frame.
-- Reads self.* fields set by Blizzard's untainted code.
-- Strategy:
--   1. isLocalPlayer → UnitGUID("player")
--   2. _dilvlGUID captured from Init hook (not secret-annotated)
--   3. sourceName → roster lookup via Ambiguate (fallback)
-- Returns guid or nil.
---------------------------------------------------------------
-- Single writer for a frame's identity. Every write MUST go through here so
-- the GUID and its trust flag can never drift apart. They did: five
-- assignments in ResolveFrameGUID and one clear in the session-switch handler
-- set or cleared the GUID while leaving _dilvlGUIDFromAPI untouched, so a
-- guessed GUID could inherit a stale "authoritative" mark and then be allowed
-- to write a player name.
-- ownerName is the name Blizzard handed us together with an API GUID. It is the
-- only way to tell later whether the row still belongs to that player: UpdateName
-- fires from inside Init, so it sees the NEW sourceName while the stored GUID is
-- still the previous occupant's.
-- `bound` is narrower than `fromAPI`, and the difference is what makes the index
-- join checkable. Both mean the GUID came from Blizzard, but bound means it came
-- from a binding that CANNOT be re-sorted: the combatSource handed to this very
-- frame's Init, or the ScrollBox's own GetElementData closure. An identity we
-- inferred from a position in a list is fromAPI too — it is still Blizzard's
-- GUID — but it is worthless as evidence that the list is in the right order,
-- because that is the thing it assumed. Only bound identities may serve as
-- controls.
local function SetFrameGUID(frame, guid, fromAPI, ownerName, bound)
    frame._dilvlGUID = guid
    frame._dilvlGUIDFromAPI = (guid and fromAPI) or nil
    frame._dilvlGUIDOwner = (guid and ownerName) or nil
    frame._dilvlGUIDBound = (guid and bound) or nil
    return guid
end

local function ResolveFrameGUID(frame)
    -- isLocalPlayer is NeverSecret, set by Blizzard's Init
    if frame.isLocalPlayer == true then
        return SafeUnitGUID("player")
    end

    local cachedGUID = frame._dilvlGUID
    local name = frame.sourceName
    local nameReadable = name and not isSecret(name)

    -- An API-sourced GUID is a FACT and is re-set on every recycle by the Init
    -- hook. Never second-guess it. The previous version re-resolved it from the
    -- name and overwrote it on mismatch — which meant our roster/cache lookup
    -- could replace Blizzard's own answer with a wrong one and stick that onto
    -- the frame for good.
    if cachedGUID and not isSecret(cachedGUID) and frame._dilvlGUIDFromAPI then
        return cachedGUID
    end

    -- No API GUID: fall back to the name, and prefer a FRESH name lookup over a
    -- previously guessed value, since the frame may have been recycled since.
    if cachedGUID and not isSecret(cachedGUID) then
        if nameReadable then
            local freshGUID = API.ResolveGUIDByName(name)
            -- A guessed GUID is not evidence. If the name we can read RIGHT NOW
            -- resolves to somebody else — or to nobody, because it is ambiguous —
            -- then the stored guess belongs to this row's previous occupant.
            -- Keeping it would put that player's item level under this name.
            if freshGUID ~= cachedGUID then
                return SetFrameGUID(frame, freshGUID, false)
            end
        end
        return cachedGUID
    end

    -- No cached GUID — resolve from sourceName
    if nameReadable then
        local guid = API.ResolveGUIDByName(name)
        if guid then SetFrameGUID(frame, guid, false) end
        return guid
    end

    -- Fallback 1: nameText field (no secret wrapper on field itself)
    local nt = frame.nameText
    if nt and not isSecret(nt) then
        local parsed = tostring(nt):match(RANK_CAPTURE) or tostring(nt)
        parsed = StripTagFromText(parsed)
        parsed = parsed and parsed:match("^%s*(.-)%s*$")
        if parsed and parsed ~= "" then
            local guid = API.ResolveGUIDByName(parsed)
            if guid then
                return SetFrameGUID(frame, guid, false)
            end
        end
    end

    -- Fallback 2: read native FontString GetText() directly.
    -- Post-combat, sourceName and nameText may be secret but the rendered
    -- FontString often has the readable text (e.g. "1. Phaenthar-Silvermoon").
    local nameFS = frame.GetName and frame:GetName()
    if nameFS and type(nameFS) ~= "string" then
        local ok, txt = pcall(nameFS.GetText, nameFS)
        if ok and txt and not isSecret(txt) and type(txt) == "string" then
            local parsed = txt:match(RANK_CAPTURE) or txt
            parsed = StripTagFromText(parsed)
            parsed = parsed and parsed:match("^%s*(.-)%s*$")
            if parsed and parsed ~= "" then
                -- Try full name first (e.g. "Phaenthar-Silvermoon")
                local guid = API.ResolveGUIDByName(parsed)
                if guid then
                    return SetFrameGUID(frame, guid, false)
                end
                -- Fallback: FontString may truncate realm names (e.g. "Тобальд-Гордун"
                -- instead of "Тобальд-Гордунни"). Strip realm and try name-only.
                local nameOnly = parsed:match("^([^%-]+)")
                if nameOnly and nameOnly ~= parsed then
                    guid = API.ResolveGUIDByName(nameOnly)
                    if guid then
                        return SetFrameGUID(frame, guid, false)
                    end
                end
            end
        end
    end

    -- All fallbacks exhausted — trace why
    if traceEnabled then
        local snS = (not name and "nil") or (isSecret(name) and "SEC") or "ok"
        local ntS = (not frame.nameText and "nil") or (isSecret(frame.nameText) and "SEC") or "ok"
        trace(format("ResolveGUID FAIL: sn=%s nt=%s cached=%s lp=%s",
            snS, ntS,
            cachedGUID and (isSecret(cachedGUID) and "SEC" or "ok") or "nil",
            tostring(frame.isLocalPlayer)))
    end
    return nil
end

---------------------------------------------------------------
-- Hook: DamageMeterSourceEntryMixin:Init()
-- Captures sourceGUID from combatSource before secrets lock it.
-- sourceGUID has no Secret annotation in the Blizzard API docs
-- (unlike sourceName which is ConditionalSecret).
---------------------------------------------------------------

---------------------------------------------------------------
-- Restore Blizzard's native Name FontString after SetToDefaults.
-- Re-applies layout from DamageMeterEntry.lua SetupDefaultStyle.
---------------------------------------------------------------
local function RestoreNameFS(frame, nameFS)
    local statusBar = frame.StatusBar
    if statusBar then
        nameFS:SetPoint("LEFT", statusBar, "LEFT", 5, 0)
        local valueFS = frame.GetValue and frame:GetValue()
        if valueFS and not isSecret(valueFS) then
            nameFS:SetPoint("RIGHT", valueFS, "LEFT", -25, 0)
        else
            nameFS:SetPoint("RIGHT", statusBar, "RIGHT", -40, 0)
        end
    end
    nameFS:SetDrawLayer("OVERLAY", 7)  -- above bar fill texture
    nameFS:SetJustifyH("LEFT")
    nameFS:SetJustifyV("MIDDLE")
    -- ALWAYS set a font — SetToDefaults clears it, "Font not set" error otherwise.
    -- Use GetFont() cache (file, size, flags) for pixel-perfect restore.
    -- Priority: per-frame cache > global cache > NumberFontNormal fallback.
    if frame._dilvlFontFile then
        nameFS:SetFont(frame._dilvlFontFile, frame._dilvlFontSize, frame._dilvlFontFlags)
    elseif globalFontFile then
        nameFS:SetFont(globalFontFile, globalFontSize, globalFontFlags)
    else
        nameFS:SetFontObject(NumberFontNormal)
    end
    -- Restore TextScale — SetToDefaults resets to 1.0, Blizzard sets a runtime scale.
    if frame._dilvlTextScale then
        nameFS:SetTextScale(frame._dilvlTextScale)
    elseif globalTextScale then
        nameFS:SetTextScale(globalTextScale)
    end
    nameFS:SetWordWrap(false)  -- XML default, SetToDefaults resets to true → text wraps & squishes bars
    nameFS:SetAlpha(1)
end

---------------------------------------------------------------
-- Clear secret text aspect from a FontString.
-- Prefers ClearAspect (surgical, keeps font/anchoring) over
-- SetToDefaults (nuclear, resets everything).
-- Returns true if aspect was cleared.
---------------------------------------------------------------
local function ClearSecretText(frame, nameFS)
    -- Surgical clear, IF Blizzard ever ships it. As of 12.1 it does not:
    -- grepping ClearAspect across the whole wow-ui-source Interface/ tree
    -- returns nothing, so this branch has never executed and the
    -- SetToDefaults path below is what always runs. The feature check stays
    -- because it costs one comparison and picks the better path for free the
    -- day the method appears — but do not mistake it for working code.
    if nameFS.ClearAspect and Enum and Enum.SecretAspect then
        local ok = pcall(nameFS.ClearAspect, nameFS, Enum.SecretAspect.Text)
        if ok then return true end
    end
    -- The path that actually runs. SetToDefaults is a Blizzard widget method
    -- called on a frame we do not own, in a file whose whole premise is that
    -- such calls can throw while tainted (that was the v1.5.2 crash), so it
    -- gets the same pcall treatment as every other foreign call here.
    -- RestoreNameFS only makes sense if the reset succeeded.
    local ok = pcall(nameFS.SetToDefaults, nameFS)
    if not ok then return false end
    RestoreNameFS(frame, nameFS)
    return true
end

---------------------------------------------------------------
-- Clear overlay + fix stale-secret FontStrings.
-- If the native FontString holds secret text and we're out of
-- combat, SetToDefaults() clears the secret aspect so Blizzard's
-- own text becomes visible again (even without our iLvl tag).
---------------------------------------------------------------
function StripAllTags()
    if not DamageMeter or not DamageMeter.ForEachSessionWindow then return end
    trace("StripAllTags")
    DamageMeter:ForEachSessionWindow(function(sw)
        if not sw.ForEachEntryFrame then return end
        sw:ForEachEntryFrame(function(frame)
            local nameFS = frame.GetName and frame:GetName()
            if not nameFS or type(nameFS) == "string" then return end
            local ok, txt = pcall(nameFS.GetText, nameFS)
            if not ok or not txt or isSecret(txt) then return end
            local clean = StripTagFromText(txt)
            if clean ~= txt then
                nameFS:SetText(clean)
            end
        end)
    end)
    traceFrameState("StripAllTags_DONE")
end

local function ClearOverlay(frame)
    local nameFS = frame:GetName()
    if not nameFS or type(nameFS) == "string" then return end
    nameFS:SetAlpha(1)

    -- Safeguard: clear stale secret/nil text when not in combat.
    -- Only attempt SetToDefaults if we can actually restore the text afterwards.
    -- NO-GUID frames without cache have no restore path → leave them alone.
    if not IsGroupInCombat() then
        local fsTxt = nameFS:GetText()
        if not fsTxt or isSecret(fsTxt) then
            -- Check if we have ANY text to restore before nuking with SetToDefaults
            local restoreText
            local blizzText = SafeGetNameText(frame)
            if blizzText and not isSecret(blizzText) then
                restoreText = blizzText
            else
                -- Same rule as InjectIlvl: a name from OUR cache may only be
                -- written into a row whose identity is a FACT. This path had no
                -- such check, and ResolveFrameGUID can reach it through the
                -- name-parsing fallbacks — so a guessed GUID could put another
                -- player's name on the row while merely "restoring" it.
                if frame._dilvlGUIDFromAPI or frame.isLocalPlayer == true then
                    local guid = ResolveFrameGUID(frame)
                    if guid then
                        local cached = API.GetCacheData(guid)
                        if cached and cached.name and not isSecret(cached.name) then
                            restoreText = StripRealm(cached.name)
                        end
                    end
                else
                    unverifiedNameSkips = unverifiedNameSkips + 1
                    -- restoreText stays nil: leave the FontString untouched and
                    -- let Blizzard redraw it, rather than label it ourselves.
                end
            end
            -- Only clear secret if we have text to put back
            if restoreText then
                ClearSecretText(frame, nameFS)
                nameFS:SetText(restoreText)
            end
            -- else: leave the FontString as-is, Blizzard will fix it on next UpdateName
        end
    end
end

---------------------------------------------------------------
-- Inject iLvl into a single entry frame's Name FontString.
-- READ-ONLY: never modifies Blizzard frame fields (nameText,
-- sourceName) or calls frame:UpdateName().
--
-- When nameText is clean: SetText on native FontString (fast).
-- When nameText is secret: native FontString is "locked" by
-- the secret value — addon SetText is silently ignored.
-- In that case we create a thin overlay FontString that we own,
-- hide the native text (SetAlpha 0), and display there instead.
---------------------------------------------------------------
local MAX_RESOLVE_FAILS = 3  -- stop retrying after this many consecutive failures per player
local nameResolveFails = {}   -- sourceName → fail count (per-player, not per-frame)

---------------------------------------------------------------
-- v1.4.2: smart-reset for the 3-retry GAVE-UP lock.
-- Pre-1.4.2 the counter only cleared on /reload; if combat-secret blocks or
-- transient resolve gaps tripped MAX_RESOLVE_FAILS, the player stayed
-- permanently untagged for the whole session even after fresh inspect data
-- arrived. Resets fire on real trigger events:
--   - cache-write per player (NotifyElvUI(name) callback path)
--   - PLAYER_REGEN_ENABLED (combat state change invalidates prior fails)
--   - GROUP_ROSTER_UPDATE (player left → fresh budget on rejoin)
--   - sessionWindow:Refresh hook (existing wipe at session switch)
-- The 3-retry defense itself is preserved.
---------------------------------------------------------------
local function ResetFailCounter(name, reason)
    if not name then return false end
    local cleared = false
    if nameResolveFails[name] then
        nameResolveFails[name] = nil
        cleared = true
    end
    -- Cross-realm symmetry: BlizzDM may show a truncated form (FontString
    -- width). Clear the realm-less variant too so whichever form the counter
    -- is keyed under gets reset — otherwise a GAVE-UP sticks for the whole
    -- session even after the player resolves fine under the other spelling.
    local short = StripRealm(name)
    if short and short ~= name and nameResolveFails[short] then
        nameResolveFails[short] = nil
        cleared = true
    end
    if cleared then
        blizzDMState.resetCount = blizzDMState.resetCount + 1
        blizzDMState.lastResetReason = reason or ("cache:" .. tostring(name):sub(1, 20))
    end
    return cleared
end

local function WipeAllFailCounters(reason)
    local n = 0
    for k in pairs(nameResolveFails) do
        nameResolveFails[k] = nil
        n = n + 1
    end
    if n > 0 then
        blizzDMState.resetCount = blizzDMState.resetCount + n
        blizzDMState.lastResetReason = (reason or "wipe-all") .. " (" .. n .. ")"
    end
    return n
end

-- Build a set of current-roster names (full + short forms). Used by
-- GROUP_ROSTER_UPDATE to purge counters for players who left the group.
local function BuildRosterNameSet()
    local set = {}
    local count = GetNumGroupMembers()
    if count > 0 then
        local prefix = IsInRaid() and "raid" or "party"
        for i = 1, count do
            local unit = prefix .. i
            if UnitExists(unit) then
                local n, realm = SafeUnitName(unit)
                if n and not isSecret(n) then
                    set[n] = true
                    if realm and realm ~= "" then set[n .. "-" .. realm] = true end
                end
            end
        end
    end
    local pn, prealm = SafeUnitName("player")
    if pn and not isSecret(pn) then
        set[pn] = true
        if prealm and prealm ~= "" then set[pn .. "-" .. prealm] = true end
    end
    return set
end

-- When a GUID resolves on one frame, propagate it to ALL other visible frames
-- with the same sourceName. Fixes: left-position causes frame A to fail while
-- frame B (same player, different window) succeeds — without propagation,
-- frame A hits MAX_RESOLVE_FAILS and gives up permanently.
-- fromAPI: whether the GUID being spread came from Blizzard's combatSource or
-- from our own name lookup. It MUST travel with the GUID. Without it this
-- function silently broke the trust rule in both directions: a guessed GUID
-- landing on a frame that still carried _dilvlGUIDFromAPI = true would look
-- authoritative and be allowed to write a player name, and a correct
-- Blizzard-supplied GUID could be replaced by a worse one.
local function PropagateGUID(sourceName, guid, fromAPI)
    if not sourceName or not guid then return end
    if not DamageMeter or not DamageMeter.ForEachSessionWindow then return end
    DamageMeter:ForEachSessionWindow(function(sw)
        if not sw.ForEachEntryFrame then return end
        sw:ForEachEntryFrame(function(f)
            if f.sourceName and not isSecret(f.sourceName)
               and f.sourceName == sourceName and f._dilvlGUID ~= guid then
                -- Never downgrade: a frame that got its identity straight from
                -- Blizzard keeps it. Init re-runs on every recycle, so that
                -- value is at least as fresh as anything we could spread.
                if f._dilvlGUIDFromAPI and not fromAPI then return end
                local prev = f._dilvlGUID
                -- Always written as GUESSED, never as api-sourced, even when
                -- the origin frame's GUID was. The receiving frame was picked
                -- by NAME EQUALITY a few lines up, and a matching name is not
                -- proof of identity — that is the whole reason this guard
                -- exists. Costs nothing: a frame with a readable sourceName
                -- never needs the cached name anyway.
                SetFrameGUID(f, guid, false)
                if traceEnabled then
                    trace(format("PropagateGUID: %s → frame (was %s)",
                        sourceName and tostring(sourceName):sub(1,15) or "?",
                        prev and "cached" or "nil"))
                end
            end
        end)
    end)
end

local function InjectIlvl(frame)
    -- Combat = we don't exist. Pure return, no writes, no ClearOverlay.
    -- StripAllTags already cleaned up on combat start.
    -- RefreshAllFrames will re-inject when everyone is OOC.
    if IsGroupInCombat() then return end

    -- Give-up: stop retrying PLAYERS that are permanently secret (e.g. Schadensklassen segment)
    -- Track by sourceName so ALL frames for the same player share one counter.
    local sn = frame.sourceName
    local snKey = sn and not isSecret(sn) and tostring(sn) or nil
    if snKey and nameResolveFails[snKey] and nameResolveFails[snKey] >= MAX_RESOLVE_FAILS then
        return
    end

    local guid = ResolveFrameGUID(frame)
    if not guid then
        -- Track consecutive failures per player name
        if snKey then
            nameResolveFails[snKey] = (nameResolveFails[snKey] or 0) + 1
            if nameResolveFails[snKey] >= MAX_RESOLVE_FAILS and traceEnabled then
                trace(format("InjectIlvl: giving up on player '%s' after %d resolve fails",
                    snKey:sub(1,15), MAX_RESOLVE_FAILS))
            end
        end
        ClearOverlay(frame) return
    end
    -- Reset fail counter on success + propagate GUID to sibling frames
    if snKey then
        nameResolveFails[snKey] = nil
        PropagateGUID(sn, guid, frame._dilvlGUIDFromAPI)
    end

    local tag = BuildTag(guid)
    if not tag then ClearOverlay(frame) return end

    -- GetName() returns the StatusBar.Name FontString.
    local nameFS = frame:GetName()
    if not nameFS then ClearOverlay(frame) return end

    -- Resolve base display name from best available source.
    -- Priority: nameText (Blizzard's display) > sourceName > player name > cache name.
    -- Post-combat, FontStrings can stay stale-secret even though InCombat is false
    -- (Blizzard only refreshes nameText on the NEXT UpdateName call, which may not
    -- happen between pulls). Cache-name fallback handles this reliably because
    -- we captured the name during inspect when it was still readable.
    local baseName
    local nameSource -- trace: which priority resolved the name
    -- Priority 1: Blizzard's formatted text with rank prefix ("1. Quinroth")
    local nameText = frame.nameText
    if nameText and not isSecret(nameText) then
        baseName = nameText
        nameSource = "nameText"
    else
        -- Priority 2: GetNameText() — formatted with rank, readable post-combat
        local fmtText = SafeGetNameText(frame)
        if fmtText and not isSecret(fmtText) then
            baseName = fmtText
            nameSource = "GetNameText"
        else
            -- Priority 3: sourceName / player name / cache name (no rank prefix)
            local name = frame.sourceName
            if not name or isSecret(name) then
                if frame.isLocalPlayer == true then
                    local pn = SafeUnitName("player")
                    if pn and not isSecret(pn) then name = pn end
                    nameSource = name and "SafeUnitName(player)" or nil
                end
            else
                nameSource = "sourceName"
            end
            -- Substituting a name from OUR cache means putting a name on screen
            -- that we chose, into a row whose real content we cannot read. That
            -- is only defensible when the row's identity is a FACT: either
            -- Blizzard handed us the GUID (Init hook) or Blizzard told us this
            -- row is the local player. With a name-guessed GUID it is not — a
            -- wrong lookup would label another player, and the class icon next
            -- to it still comes from Blizzard, so the row would contradict
            -- itself. Rule from the addon author, 2026-08-15: a missing tag is
            -- fine, a wrong name is not.
            if not name or isSecret(name) then
                if frame._dilvlGUIDFromAPI or frame.isLocalPlayer == true then
                    local cached = API.GetCacheData(guid)
                    if cached and cached.name and not isSecret(cached.name) then
                        name = StripRealm(cached.name)
                        nameSource = "cache"
                    end
                else
                    unverifiedNameSkips = unverifiedNameSkips + 1
                end
            end
            if not name or isSecret(name) then
                trace(format("InjectIlvl SKIP: no readable name for GUID %s (nameText=%s sn=%s)",
                    guid:sub(1,8) .. "..",
                    nameText and (isSecret(nameText) and "SEC" or "ok") or "nil",
                    frame.sourceName and (isSecret(frame.sourceName) and "SEC" or "ok") or "nil"))
                ClearOverlay(frame) return
            end
            -- Priorities 1 and 2 come from Blizzard's own formatter, which puts
            -- the rank in front (DamageMeterEntry.lua:568). Priority 3 is a bare
            -- name, so writing it as-is silently drops the row's number — a list
            -- where exactly the tagged rows have lost their rank. Rebuild it the
            -- way Blizzard does: same frame field, same global format string, so
            -- it matches in every locale instead of us inventing "%d. ".
            -- Death-recap rows carry no rank there either (:563), none here.
            local idx = frame.index
            if idx and not isSecret(idx) and DAMAGE_METER_SOURCE_NAME
                and (not frame.deathRecapID or frame.deathRecapID == 0) then
                local okFmt, ranked = pcall(format, DAMAGE_METER_SOURCE_NAME, idx, name)
                if okFmt and ranked and not isSecret(ranked) then name = ranked end
            end
            baseName = name
        end
    end

    local displayText
    local db = API.GetDb()
    if db and db.ilvlPosition == "left" then
        -- Insert between rank prefix and name: "1. [272] Playername"
        local rank, rest = baseName:match(RANK_SPLIT)
        if rank then
            displayText = rank .. tag .. " " .. rest
        else
            displayText = tag .. " " .. baseName
        end
    else
        displayText = baseName .. tag
    end

    -- Cache actual font properties from native FontString while readable.
    -- GetFont() returns the rendered font (file, size, flags) regardless of how it was set.
    -- This captures Blizzard's runtime SetTextScale effect on fontSize.
    local fontFile, fontSize, fontFlags = nameFS:GetFont()
    if fontFile and not isSecret(fontFile) and fontSize and not isSecret(fontSize) then
        frame._dilvlFontFile = fontFile
        frame._dilvlFontSize = fontSize
        frame._dilvlFontFlags = fontFlags or ""
        -- Track the LATEST clean read (not write-once): if the user changes the
        -- Blizzard DM font/scale mid-session, the global fallback the secret-clear
        -- path (RestoreNameFS) uses follows along instead of staying stale.
        globalFontFile = fontFile
        globalFontSize = fontSize
        globalFontFlags = fontFlags or ""
    end
    local textScale = nameFS:GetTextScale()
    if textScale and not isSecret(textScale) then
        frame._dilvlTextScale = textScale
        globalTextScale = textScale
    end

    -- Write-first: try SetText directly (works when FontString is clean).
    nameFS:SetText(displayText)
    nameFS:SetAlpha(1)

    local fsTxt = nameFS:GetText()
    if fsTxt and not isSecret(fsTxt) then
        -- Ensure native properties are intact (SetToDefaults from a previous
        -- session may have left wrong font/wordwrap that persists across /reload).
        nameFS:SetWordWrap(false)
        if frame._dilvlFontFile then
            nameFS:SetFont(frame._dilvlFontFile, frame._dilvlFontSize, frame._dilvlFontFlags)
        elseif globalFontFile then
            nameFS:SetFont(globalFontFile, globalFontSize, globalFontFlags)
        end
        if frame._dilvlTextScale then
            nameFS:SetTextScale(frame._dilvlTextScale)
        elseif globalTextScale then
            nameFS:SetTextScale(globalTextScale)
        end
        -- Clean path: do NOT touch color — Blizzard's own SetTextColor is correct.
        -- We only restore color after ClearSecretText (clear path below).
        return  -- Clean path: SetText succeeded
    end

    -- FontString holds sticky secret aspect (persists after combat).
    -- ClearAspect(Text) if available (surgical), else SetToDefaults (nuclear).
    -- Runs ONCE per combat transition, not every frame.
    ClearSecretText(frame, nameFS)

    -- NOW SetText works — secret aspect is cleared
    nameFS:SetText(displayText)

    -- Clear path: ClearSecretText nuked the color, restore from cache.
    -- Use cached Blizzard color (captured in UpdateName hook when frame was clean).
    -- Do NOT use GetPlayerInfoByGUID — GUID mapping is unreliable in LFR.
    if frame._dilvlTextColor then
        pcall(nameFS.SetTextColor, nameFS, unpack(frame._dilvlTextColor))
        frame._dilvlColorSetByAddon = "cached"
        if traceEnabled then
            trace(format("InjectIlvl: restore cached color (clear path) for %s", baseName and baseName:sub(1, 20) or "?"))
        end
    else
        frame._dilvlColorSetByAddon = nil
        if traceEnabled then
            trace(format("InjectIlvl: NO cached color for %s — Blizz default", baseName and baseName:sub(1, 20) or "?"))
        end
    end
end

---------------------------------------------------------------
-- Refresh all visible DamageMeter entry frames.
-- Uses DamageMeter:ForEachSessionWindow → ForEachEntryFrame
-- (official Blizzard iteration API, same pattern ElvUI uses).
---------------------------------------------------------------
-- One-shot deferred retry flag: when RefreshAllFrames finds frames still
-- secret after combat ends (~0.5s unlock delay), it sets this flag so the
-- next UpdateName hook fires a full refresh. Event-driven, no timer (#19).
local deferredRetryPending = false

-- Forward-declared HERE, above the UpdateName hook, on purpose: that hook's #19
-- deferred-retry path closes over ScheduleRefresh. Declared only at their
-- definitions (far below) the closure would capture a nil global and the
-- post-combat secret-unlock recovery would silently never fire (dead code).
local ScheduleRefresh, StartPostCombatRefresh

---------------------------------------------------------------
-- Identity backfill: ask Blizzard for the row's owner instead of
-- waiting to be handed it.
--
-- The Init hook is the only place Blizzard gives us a row's GUID, and it fires
-- exactly when a row is (re)filled. That moment is wrong for us twice over:
-- DURING a fight sourceGUID is not available, and once the fight ENDS nothing
-- refills the rows — so they keep the empty identity the last in-combat Init
-- left behind, read "[NO-GUID]" for the rest of the session, and stay untagged
-- even though every player on them is sitting in our cache with a full item
-- level. Switching the window mode by hand cures it, and only because that
-- forces a rebuild. Reported live twice, 2026-08-16.
--
-- So we fetch the data ourselves. GetCombatSession (DamageMeterSessionWindow
-- .lua:562) is a plain getter over C_DamageMeter.GetCombatSessionFromType /
-- FromID, and frame.index points straight at the row's entry in that list:
-- BuildDataProvider stamps combatSource.index = i (:640) and Init copies it
-- (DamageMeterEntry.lua:477).
--
-- The index alone is NOT proof. The list can be reordered between a frame's
-- last Init and now, and trusting it blindly would hand one player's identity
-- to another player's row — the exact failure this addon refuses to produce.
-- So every match is confirmed against two fields that Blizzard guarantees are
-- never secret and that Init copied from that same source: the damage total
-- (:473) and the class (:496). Both must agree, or we take nothing.
--
-- Out of combat only: GetCombatSessionFromType is SecretWhenInCombat
-- (DamageMeterDocumentation.lua:39-41).
---------------------------------------------------------------
local identityBackfills = 0

-- Why a backfill attempt gave up. Every early return below bumps exactly one of
-- these, so a single debug line says where the chain breaks instead of leaving
-- us to guess which of six preconditions failed.
-- `direct` is the one success counter here: rows the ScrollBox answered for
-- outright. Everything after it is a reason we could NOT decide a row.
local bfWhy = {
    direct = 0,
    combat = 0, noApi = 0, noSession = 0, secretSession = 0, noSources = 0,
    noIndex = 0, noSrc = 0, classSecret = 0, classDiff = 0, specDiff = 0,
    -- noLicence is NOT a weaker ambiguous, it is a different problem. ambiguous
    -- means the row could be several players; noLicence means the window had
    -- nothing to check its ordering against, so the index was never consulted.
    -- One is fixed with better evidence about the row, the other with a witness.
    ambiguous = 0, noLicence = 0, guidNil = 0, guidSecret = 0,
}

-- The index join's positive control, counted so the report shows the licence and
-- not just the result. `ok` are rows whose owner Blizzard bound to the frame
-- itself and that sit at the index they claim, `bad` are rows that do not. A
-- window is trusted only with at least one ok and no bad at all.
local bfCtrl = {ok = 0, bad = 0, classBad = 0, windows = 0, trusted = 0}

-- Blizzard's own frame-to-data mapping, and the reason none of the guesswork
-- below should normally be needed.
--
-- ScrollBox installs GetElementData on every frame it hands out, as a CLOSURE
-- over the exact elementData that frame was filled with (ScrollBoxListView.lua
-- :80-84). Blizzard's comment there: "Views require this function to relate data
-- provider elements with their frame counterpart." Because it is a closure and
-- not an index lookup, re-sorting the list cannot desync it.
--
-- It is installed in AcquireInternal (:386) BEFORE the initializer runs — the
-- initializer itself reads it (:397) — so it is already live when our Init hook
-- fires, and it is set back to nil when the frame is released (:120-124). Its
-- absence therefore means "this frame is not bound to any row", which is exactly
-- the liveness check we want before writing to it.
--
-- The damage meter's element data IS the DamageMeterCombatSource: BuildDataProvider
-- inserts the combatSource table itself (DamageMeterSessionWindow.lua:646), and the
-- window uses a LINEAR view (:336), so no tree-node unwrapping applies.
local function ElementDataOf(frame)
    local fn = frame.GetElementData
    if type(fn) ~= "function" then return nil end
    local ok, data = pcall(fn, frame)
    if not ok or not data or isSecret(data) then return nil end
    return data
end

local function BackfillIdentity()
    if IsGroupInCombat() then bfWhy.combat = bfWhy.combat + 1 return end
    if not DamageMeter.ForEachSessionWindow then return end

    SafeBlizzCall("BackfillIdentity", DamageMeter.ForEachSessionWindow, DamageMeter,
        function(sw)
            if not sw.ForEachEntryFrame or not sw.GetCombatSession then
                bfWhy.noApi = bfWhy.noApi + 1 return
            end
            -- Edit mode hands back a mock session (DamageMeterSessionWindow.lua:564).
            if sw.IsEditing and sw:IsEditing() then return end

            -- Ask the frame what it is showing. No index, no ordering assumption,
            -- no inference — this is the framework's own answer.
            local claimed, pending = {}, {}
            SafeBlizzCall("BackfillDirect", sw.ForEachEntryFrame, sw,
                function(frame)
                    if frame.spellID ~= nil then return end
                    if frame._dilvlGUIDFromAPI then
                        local g = frame._dilvlGUID
                        if g and not isSecret(g) then claimed[g] = true end
                        return
                    end

                    local src = ElementDataOf(frame)
                    local guid = src and src.sourceGUID
                    if guid and not isSecret(guid) then
                        local owner = src.name
                        if owner ~= nil and isSecret(owner) then owner = nil end
                        -- Bound: GetElementData is a closure over the element
                        -- this frame was filled with, so no re-sort can move it.
                        SetFrameGUID(frame, guid, true, owner, true)
                        frame._dilvlBfWhy = nil
                        claimed[guid] = true
                        identityBackfills = identityBackfills + 1
                        bfWhy.direct = bfWhy.direct + 1
                        return
                    end

                    pending[#pending + 1] = frame
                end)

            -- Everything answered directly: the inference below is not needed and
            -- its cost (a session fetch plus a full grouping pass) is not paid.
            if #pending == 0 then return end

            local okSession, session = pcall(sw.GetCombatSession, sw)
            if not okSession or not session then
                bfWhy.noSession = bfWhy.noSession + 1 return
            end
            if isSecret(session) then
                bfWhy.secretSession = bfWhy.secretSession + 1 return
            end
            local sources = session.combatSources
            if not sources or isSecret(sources) then
                bfWhy.noSources = bfWhy.noSources + 1 return
            end

            -- Is the fresh list still in the order the rows were drawn from?
            -- Everything below joins a row to a source BY INDEX, and an index is
            -- worth nothing unless that holds.
            --
            -- A positive control decides it, not an assumption. Rows whose owner
            -- Blizzard bound to the frame itself are checked against the index
            -- they claim. Land every one of them on itself and the list has not
            -- moved, which licenses the same index for the rows we cannot read.
            -- One landing elsewhere — or nothing to check with at all — and the
            -- join stays shut for this window.
            --
            -- The local player is a control that costs nothing and is there
            -- almost every time: isLocalPlayer is NeverSecret
            -- (DamageMeterDocumentation.lua:206) and UnitGUID("player") needs no
            -- list to answer.
            local ctrlOk, ctrlBad, ctrlClassBad = 0, 0, 0
            SafeBlizzCall("BackfillControl", sw.ForEachEntryFrame, sw,
                function(frame)
                    if frame.spellID ~= nil then return end
                    local idx = frame.index
                    if not idx or isSecret(idx) then return end
                    local s = sources[idx]
                    if not s or isSecret(s) then return end

                    -- Every row is a witness to the ordering, named or not.
                    -- classFilename is NeverSecret (DamageMeterDocumentation.lua
                    -- :202) so it survives on the sealed rows too, and a
                    -- character cannot change class — a row sitting on a
                    -- source of another class means the list moved, not that this
                    -- row is unusual. It matters because after a fight the named
                    -- witnesses are often down to the local player alone, and a
                    -- re-sort that leaves the top line where it was would walk
                    -- past a single witness untouched.
                    --
                    -- Spec is deliberately NOT read this way: a player can respec
                    -- mid-session, so a spec difference is that row's own
                    -- business and stays a per-row refusal further down.
                    local fc, sc = frame.classFilename, s.classFilename
                    if fc ~= nil and sc ~= nil
                        and not isSecret(fc) and not isSecret(sc)
                        and fc ~= sc then
                        ctrlClassBad = ctrlClassBad + 1
                    end

                    local sg = s.sourceGUID
                    if not sg or isSecret(sg) then return end

                    local known
                    if frame.isLocalPlayer == true then
                        known = SafeUnitGUID("player")
                    elseif frame._dilvlGUIDBound then
                        local g = frame._dilvlGUID
                        if g and not isSecret(g) then known = g end
                    end
                    if not known then return end

                    if known == sg then
                        ctrlOk = ctrlOk + 1
                    else
                        ctrlBad = ctrlBad + 1
                    end
                end)
            local orderTrusted = (ctrlBad == 0 and ctrlClassBad == 0 and ctrlOk > 0)
            bfCtrl.ok = bfCtrl.ok + ctrlOk
            bfCtrl.bad = bfCtrl.bad + ctrlBad + ctrlClassBad
            bfCtrl.classBad = bfCtrl.classBad + ctrlClassBad
            bfCtrl.windows = bfCtrl.windows + 1
            if orderTrusted then bfCtrl.trusted = bfCtrl.trusted + 1 end

            -- Group the sources by the two fields Blizzard marks NeverSecret
            -- (DamageMeterDocumentation.lua:202-203). They stay readable exactly
            -- when everything else does not — the damage totals we used to confirm
            -- with stay secret for good once they were recorded in restricted
            -- combat. Measured, not assumed: the counter read totalSecret=489
            -- during the fight and 621 AFTER it, every combat flag back to "no".
            --
            -- n counts ALL members of a group, guids only the ones we can name.
            -- Both are needed: n decides uniqueness, guids decide elimination, and
            -- a group holding a member we cannot name (blind) can do neither.
            local groups, srcKey = {}, {}
            for i, s in ipairs(sources) do
                if s and not isSecret(s) then
                    local c, sp = s.classFilename, s.specIconID
                    if c ~= nil and sp ~= nil and not isSecret(c) and not isSecret(sp) then
                        local key = tostring(c) .. "\0" .. tostring(sp)
                        srcKey[i] = key
                        local g = groups[key]
                        if not g then g = {guids = {}, n = 0, blind = false} groups[key] = g end
                        g.n = g.n + 1
                        local sg = s.sourceGUID
                        if sg and not isSecret(sg) then
                            g.guids[#g.guids + 1] = sg
                        else
                            g.blind = true
                        end
                    end
                end
            end

            -- `claimed` and `pending` are already filled by the direct pass above:
            -- claimed holds every identity we know for a fact, pending the rows the
            -- framework could not answer for. Identities are also CONSTRAINTS — a
            -- player shown on one line cannot also be on another.

            -- Fixpoint. Every acceptance adds a constraint that may decide another
            -- row (three players of one spec, two already known → the third
            -- follows), so sweep until a full pass changes nothing.
            local reason = {}
            local progress = true
            while progress do
                progress = false
                for i = #pending, 1, -1 do
                    local frame = pending[i]
                    local why, guid, src

                    local idx = frame.index
                    if not idx or isSecret(idx) then
                        why = "noIndex"
                    else
                        src = sources[idx]
                        if not src or isSecret(src) then why = "noSrc" end
                    end

                    if not why then
                        -- The row and the source must agree on class AND spec
                        -- before anything else is considered.
                        local class, fClass = src.classFilename, frame.classFilename
                        local spec, fSpec = src.specIconID, frame.specIconID
                        if class == nil or fClass == nil or spec == nil or fSpec == nil
                            or isSecret(class) or isSecret(fClass)
                            or isSecret(spec) or isSecret(fSpec) then
                            why = "classSecret"
                        elseif class ~= fClass then
                            why = "classDiff"
                        elseif spec ~= fSpec then
                            why = "specDiff"
                        end
                    end

                    if not why then
                        guid = src.sourceGUID
                        if not guid then why = "guidNil"
                        elseif isSecret(guid) then why = "guidSecret" end
                    end

                    if not why then
                        -- Agreement at a position is not proof on its own: the list
                        -- may have been reordered since this frame was last filled,
                        -- and another player of the same class and spec could now
                        -- sit there. Exactly one of these has to settle it.
                        local g = groups[srcKey[idx]]
                        local decided = false

                        -- 1. Nobody else has this class+spec, so no reordering
                        --    could put anyone else on this row.
                        if g and g.n == 1 then
                            decided = true

                        -- 2. Elimination: every OTHER player with this class+spec is
                        --    already accounted for on another row, so this one is
                        --    the only candidate left. Requires the group to be fully
                        --    named — an unnamed member could be the real occupant.
                        elseif g and not g.blind and #g.guids == g.n and not claimed[guid] then
                            local free = 0
                            for _, cand in ipairs(g.guids) do
                                if not claimed[cand] then free = free + 1 end
                            end
                            decided = (free == 1)
                        end

                        -- 3. The damage totals pin the row exactly. Unavailable once
                        --    they were recorded in restricted combat, but they do
                        --    fire on unrestricted sessions.
                        if not decided then
                            local total, fTotal = src.totalAmount, frame.value
                            decided = total ~= nil and fTotal ~= nil
                                and not isSecret(total) and not isSecret(fTotal)
                                and total == fTotal
                        end

                        -- 4. The list is provably still in the order these rows
                        --    were filled from, so the index IS the binding rather
                        --    than a guess about it. Last of the four because the
                        --    three above decide a row on its own evidence and
                        --    this one leans on the window as a whole; the claimed
                        --    check still keeps two rows from taking one player.
                        --
                        --    Without it the raid case had no way through at all:
                        --    half a dozen players share a class and spec, so (1)
                        --    and (2) never fire, and (3) needs damage totals that
                        --    stay secret for good once they were recorded in
                        --    restricted combat. 1456 refusals in one evening, on
                        --    rows whose item level was sitting in the cache.
                        if not decided and orderTrusted and not claimed[guid] then
                            decided = true
                        end

                        if not decided then
                            why = orderTrusted and "ambiguous" or "noLicence"
                        end
                    end

                    if why then
                        reason[frame] = why
                    else
                        local owner = src.name
                        if owner ~= nil and isSecret(owner) then owner = nil end
                        SetFrameGUID(frame, guid, true, owner)
                        frame._dilvlBfWhy = nil
                        claimed[guid] = true
                        identityBackfills = identityBackfills + 1
                        table.remove(pending, i)
                        progress = true
                    end
                end
            end

            -- Count each unresolved row ONCE, with the reason from its final
            -- evaluation. Counting inside the loop would multiply by sweep.
            for _, frame in ipairs(pending) do
                local why = reason[frame]
                if why then bfWhy[why] = (bfWhy[why] or 0) + 1 end
                -- Kept on the row so the dump can name the reason for THIS row.
                -- The session totals above cannot: they say 552 of one kind and
                -- 345 of another across every pass, which is no help at all when
                -- two specific rows are missing a tag and everything else worked.
                frame._dilvlBfWhy = why
            end
        end)
end

local function RefreshAllFrames()
    if blizzDMState.disabled then return end
    local db = API.GetDb()
    if not db or not db.enabled then return end
    if db.blizzDM == false then return end
    if db.blizzDM == nil and Details then return end

    -- Safety reset: if inCombat is stuck but we're clearly OOC, force-reset.
    -- Catches Delve/M+ edge cases where combat events fire in unexpected order.
    if inCombat then
        local icl = IsInCombatSafe()
        local eip = IsEncounterInProgress()
        if icl ~= true and eip ~= true then
            inCombat = false
            trace("RefreshAllFrames: inCombat stuck, ICL+EIP both false → FORCE RESET")
        end
    end

    if not DamageMeter.ForEachSessionWindow then return end

    -- Give rows an identity before trying to write to them. Without this the
    -- pass below can only tag what Blizzard still lets us read by name.
    BackfillIdentity()

    local hasRetriableSecret = false
    -- Wrapped iteration: a thrown error in Blizzard's iteration API or our
    -- InjectIlvl can't take down all remaining frames silently. SafeBlizzCall
    -- counts errors; after BLIZZDM_ERROR_LIMIT it auto-disables BlizzDM only
    -- (db.blizzDM = false), without touching db.enabled or other features.
    SafeBlizzCall("ForEachSessionWindow", DamageMeter.ForEachSessionWindow,
        DamageMeter, function(sessionWindow)
            if not sessionWindow.ForEachEntryFrame then return end
            SafeBlizzCall("ForEachEntryFrame", sessionWindow.ForEachEntryFrame,
                sessionWindow, function(frame)
                    SafeBlizzCall("InjectIlvl", InjectIlvl, frame)
                    -- "Worth retrying" is about rows we cannot NAME, not rows
                    -- whose sourceName is secret. Those two came apart once the
                    -- identity stopped depending on the name: a frame keeps the
                    -- secret string it was filled with during the fight for as
                    -- long as the window lives, because Blizzard never rewrites
                    -- it, so the old test stayed true forever and left deferRetry
                    -- reading PENDING for the rest of the session while every row
                    -- on screen was long since tagged.
                    if not hasRetriableSecret and frame.sourceName
                        and isSecret(frame.sourceName)
                        and frame.isLocalPlayer ~= true
                        and not frame._dilvlGUID then
                        hasRetriableSecret = true
                    end
                end)
        end)

    -- Only defer retry if there are frames that haven't given up yet
    if hasRetriableSecret and not IsGroupInCombat() then
        deferredRetryPending = true
        trace("RefreshAllFrames: frames still secret, deferred retry pending")
    elseif not hasRetriableSecret and deferredRetryPending then
        deferredRetryPending = false
        trace("RefreshAllFrames: all secret frames gave up, retry stopped")
    end
end

-- Take the row's identity straight from Blizzard's combatSource. sourceGUID
-- carries no secret annotation (DamageMeterDocumentation.lua:199), unlike
-- `name` which is ConditionalSecret — so identity stays readable exactly when
-- the name does not.
--
-- WHICH function to hook is not a detail, it decides whether this works at all:
--
--   * DamageMeterSourceEntryMixin.Init is reached as frame:Init(...) from the
--     ScrollBox initializer (DamageMeterSessionWindow.lua:318). But the frames
--     are built with mixin="DamageMeterSourceEntryMixin" (DamageMeterEntry.xml:49),
--     and `mixin=` COPIES the functions onto each frame at creation. Hooking the
--     mixin table therefore only reaches frames created after we loaded. That is
--     exactly why a live dump read "GUID: 25 (13 api)" — twelve older frames ran
--     through their unhooked copies.
--   * DamageMeterEntryMixin.Init is invoked as a TABLE call at
--     DamageMeterEntry.lua:510, so it always resolves through the hooked table,
--     no matter how old the frame is.
--
-- WHEN it runs matters just as much. UpdateName has exactly one caller in the
-- whole Blizzard tree — DamageMeterEntry.lua:481, inside DamageMeterEntryMixin
-- :Init itself. So during a recycle the order was:
--     sourceName := new player  ->  UpdateName -> our hook -> we WRITE
--       -> only then our old post-hook set the new GUID
-- We wrote the tag while the identity still belonged to the previous occupant.
-- Injecting from here instead puts the write AFTER the identity is correct.
local function CaptureIdentityAndInject(frame, source)
    -- Spell rows set spellID before calling the base Init (DamageMeterEntry.lua
    -- :618). They show abilities, not players — nothing for us to do.
    if frame.spellID ~= nil then return end

    -- A recycled frame must never keep the previous player's identity.
    SetFrameGUID(frame, nil, false, nil)
    if source and not isSecret(source) then
        local guid = source.sourceGUID
        if guid and not isSecret(guid) then
            -- Record WHO this GUID belongs to while the name is readable. The
            -- UpdateName hook needs it to tell "Blizzard redrew this row" apart
            -- from "this row was handed to a different player".
            local owner = source.name
            if owner ~= nil and isSecret(owner) then owner = nil end
            -- Bound: this is the combatSource Blizzard is filling THIS frame
            -- from, one call up the stack.
            SetFrameGUID(frame, guid, true, owner, true)
        end
    end
    SafeBlizzCall("InjectIlvl", InjectIlvl, frame)
end

if DamageMeterEntryMixin then
    hooksecurefunc(DamageMeterEntryMixin, "Init", CaptureIdentityAndInject)
end

---------------------------------------------------------------
-- Hook: DamageMeterEntryMixin:UpdateName()
-- Fires EVERY time Blizzard sets/resets bar name text (on
-- combat update, session switch, style change, etc.).
-- This is the primary injection point — much more reliable
-- than Init which only fires on ScrollBox frame creation.
---------------------------------------------------------------
hooksecurefunc(DamageMeterEntryMixin, "UpdateName", function(self)
    -- Combat = we don't exist. No reads, no writes, no traces.
    -- Full group combat check (inCombat + IsEncounterInProgress + UnitAffectingCombat).
    if IsGroupInCombat() then return end

    -- No identity work and no injection here any more. UpdateName's only caller
    -- in the entire Blizzard tree is DamageMeterEntryMixin:Init itself
    -- (DamageMeterEntry.lua:481), so this hook fires DURING a recycle — after
    -- sourceName has been set to the new player but before anyone has told us
    -- the new GUID. Writing from here meant writing with the previous
    -- occupant's identity, which is precisely how another player's name and
    -- item level ended up on a row. Both jobs moved to CaptureIdentityAndInject,
    -- which runs on the same Init one level up, after the identity is correct.
    --
    -- What stays: the two things that are genuinely about "Blizzard just
    -- redrew this name" rather than about identity.
    local name = self.sourceName

    -- Cache class color from native FontString while readable (OOC).
    -- ClearSecretText resets color to default; we restore it in InjectIlvl.
    local nameFS = self.GetName and self:GetName()
    if nameFS and nameFS.GetTextColor then
        local ok, r, g, b, a = pcall(nameFS.GetTextColor, nameFS)
        if ok and r and not isSecret(r) and not isSecret(g) and not isSecret(b) then
            self._dilvlTextColor = {r, g, b, a or 1}
            if traceEnabled then
                trace(format("UpdateName: cached color r=%.2f g=%.2f b=%.2f for %s",
                    r, g, b, name and not isSecret(name) and tostring(name) or "?"))
            end
        end
    end

    -- Inject here too, but only when it cannot write someone else's data.
    --
    -- Why it must happen here at all: when a fight ends Blizzard un-secrets the
    -- names and calls UpdateName, but the ScrollBox does NOT rebuild its rows,
    -- so Init never runs. With injection living only in the Init hook the whole
    -- meter stayed untagged after every pull until something forced a rebuild —
    -- switching the window mode, for instance. Reported live, 2026-08-15.
    --
    -- Why it is gated: UpdateName's only caller is Init itself
    -- (DamageMeterEntry.lua:481), so it also fires mid-recycle, when sourceName
    -- is already the NEW player while _dilvlGUID still holds the previous one —
    -- and ResolveFrameGUID hands back an API GUID unconditionally. Writing then
    -- put one player's item level under another's name (fixed in 62544d4).
    -- Two cases are provably safe:
    --   * no API identity stored — ResolveFrameGUID then resolves fresh from the
    --     name Blizzard just drew, which is by definition the current occupant.
    --     This is the post-combat case above: the in-combat Init cleared the
    --     identity because the GUID was unreadable.
    --   * an API identity whose recorded owner still matches sourceName — the
    --     row was redrawn, not reassigned.
    -- Everything else is a recycle: skip it, CaptureIdentityAndInject injects a
    -- moment later with the correct identity. A tag one frame late beats a wrong
    -- tag now.
    if self.spellID == nil then
        local owner = self._dilvlGUIDOwner
        local readable = (name ~= nil and not isSecret(name)) and name or nil
        if self._dilvlGUIDFromAPI == nil
            or (owner ~= nil and readable ~= nil and owner == readable) then
            SafeBlizzCall("InjectIlvl", InjectIlvl, self)
        end
    end

    -- Deferred retry: post-combat RefreshAllFrames found secret frames,
    -- now UpdateName fired (secrets unlocked ~0.5s later) → full refresh (#19)
    if deferredRetryPending and ScheduleRefresh then
        deferredRetryPending = false
        trace("UpdateName: deferred retry → RefreshAllFrames")
        ScheduleRefresh()
    end

    -- Trace: log when Blizzard calls UpdateName and what state the frame is in
    if traceEnabled then
        local nameFS = self.GetName and self:GetName()
        local txtOk, txt = nameFS and pcall(nameFS.GetText, nameFS)
        local display = (txtOk and txt and not isSecret(txt)) and tostring(txt):sub(1, 30) or "(secret)"
        trace(format("UpdateName [%s] nameText=%s",
            name and not isSecret(name) and tostring(name) or "?", display))
    end

end)

---------------------------------------------------------------
-- Event dispatch system (self-registering handlers).
-- RegisterHandler(event, fn) registers the event AND its handler
-- in one call — can't forget one without the other.
--
-- Combat safeguards — layered defense against Secret Values:
--   PLAYER_REGEN_DISABLED/ENABLED — own combat state
--   UNIT_FLAGS — registered, no-op (kept for future use)
--   ENCOUNTER_START/END — precise boss encounter boundaries
--   INSTANCE_ENCOUNTER_ENGAGE_UNIT — earliest boss detection (frame appears)
--   LOADING_SCREEN_DISABLED — safe moment after zone transitions
--   PLAYER_ENTERING_WORLD — login, reload, instance port
-- Future-safe: if any of these start returning secrets, IsGroupInCombat()
-- treats unknown/secret values as "in combat" (safe default).
---------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
local eventHandlers = {}

local function RegisterHandler(event, handler)
    eventHandlers[event] = handler
    eventFrame:RegisterEvent(event)
end

---------------------------------------------------------------
-- Dirty-flag refresh system (replaces C_Timer.After ScheduleRefresh).
-- Multiple events in the same frame only trigger ONE refresh.
-- After combat ends, OnUpdate keeps checking for untagged frames
-- whose secrets have unlocked, refreshing them incrementally
-- until all visible frames are tagged (then goes idle).
-- Zero closure allocation, purely event-driven.
---------------------------------------------------------------
local refreshDirty = false      -- set by events/hooks, consumed by OnUpdate
local refreshActive = false     -- true while post-combat catch-up is running
local refreshThrottle = 0       -- throttle post-combat catch-up to every 0.5s
local REFRESH_INTERVAL = 0.5    -- seconds between catch-up passes
local refreshStats = {total = 0, tagged = 0, passes = 0, lastPass = 0}

local refreshFrame = CreateFrame("Frame")
refreshFrame:Hide()  -- starts idle, no CPU cost

-- ScheduleRefresh / StartPostCombatRefresh are forward-declared near the top of
-- the file (above the UpdateName hook) so the #19 deferred-retry closure binds them.

refreshFrame:SetScript("OnUpdate", function(self, elapsed)
    -- Safety reset: if inCombat is stuck but ICL + EIP both say OOC, force-reset.
    -- Must run BEFORE IsGroupInCombat() check, otherwise we never reach RefreshAllFrames.
    if inCombat then
        local icl = IsInCombatSafe()
        local eip = IsEncounterInProgress()
        if icl ~= true and eip ~= true then
            inCombat = false
            trace("OnUpdate: inCombat stuck, ICL+EIP both false → FORCE RESET")
            StartPostCombatRefresh()
        end
    end
    if IsGroupInCombat() then
        refreshDirty = false
        self:Hide()
        return
    end

    if refreshDirty then
        refreshDirty = false
        refreshStats.passes = refreshStats.passes + 1
        refreshStats.lastPass = GetTime()
        RefreshAllFrames()
    end

    -- Post-combat catch-up: throttled to every 0.5s.
    -- If no progress since last pass → go idle (avoid endless loop
    -- when frames have readable nameText but GUID can't be resolved).
    if refreshActive then
        refreshThrottle = refreshThrottle - elapsed
        if refreshThrottle > 0 then return end
        refreshThrottle = REFRESH_INTERVAL
        local tagged = 0
        local total = 0
        if DamageMeter.ForEachSessionWindow then
            DamageMeter:ForEachSessionWindow(function(sw)
                if not sw.ForEachEntryFrame then return end
                sw:ForEachEntryFrame(function(frame)
                    total = total + 1
                    local nameFS = frame.GetName and frame:GetName()
                    if not nameFS or type(nameFS) == "string" then return end
                    local txt = nameFS:GetText()
                    if txt and not isSecret(txt) and type(txt) == "string" and txt:find("%[%d+%]") then
                        tagged = tagged + 1
                    end
                end)
            end)
        end
        refreshStats.total = total
        local prevTagged = refreshStats.tagged
        refreshStats.tagged = tagged
        if tagged > prevTagged then
            -- Made progress — keep going
            refreshDirty = true
        else
            -- No progress — go idle
            refreshActive = false
            if not refreshDirty then
                self:Hide()
                trace(format("RefreshIdle: %d/%d tagged in %d passes",
                    tagged, total, refreshStats.passes))
            end
        end
    elseif not refreshDirty then
        self:Hide()  -- no work left, go idle
    end
end)

function ScheduleRefresh()
    refreshDirty = true
    refreshFrame:Show()  -- wake up OnUpdate
end

-- Start post-combat catch-up: OnUpdate keeps running until all frames tagged
function StartPostCombatRefresh()
    refreshActive = true
    refreshStats.passes = 0
    ScheduleRefresh()
end

---------------------------------------------------------------
-- Public: a setting this file renders from has changed.
--
-- core.lua's settings router forwards EVERY key here and this file decides what
-- it means for a Blizzard-meter row. That direction is the whole point. The
-- router's branches are written around db.layout, which is a DETAILS!-only
-- concept, so any Blizzard-meter work parked inside one of them inherits a guard
-- that means nothing here. That is exactly how ilvlPosition came to reach
-- Details! and nothing else: the row keeps whatever placement it was drawn with,
-- Blizzard never repaints it (its UpdateName only writes when the text differs
-- from its own nameText field, which we deliberately never touch), and the meter
-- sits there with the old layout until the next pull. Reported live 20.08.2026;
-- the same branch is on master, so this has been broken since v1.3.5.
--
-- Redraw, never strip-then-redraw: InjectIlvl rebuilds each row from Blizzard's
-- own name text, so re-running it over an already-tagged row yields the new
-- placement by itself. A strip pass first would be churn, and it cannot help the
-- rows that need it most — StripAllTags skips a frame whose text is secret.
--
-- The OFF transitions are the opposite case and the reason the strip branch
-- exists at all. Once db.enabled or db.blizzDM says no, RefreshAllFrames returns
-- before it touches a frame, so a redraw does nothing and every row keeps its
-- tag forever. Turning the addon off has to take the tags with it.
--
-- No combat guard on the redraw path, deliberately: ScheduleRefresh only sets a
-- dirty flag, and its OnUpdate refuses to run while the group is in combat. The
-- options panel can be opened mid-pull, so deferring IS the guard. The strip
-- branch writes immediately, so it takes the explicit check.
---------------------------------------------------------------
function Details_iLvlDisplay_BlizzDMApplySetting(key)
    local db = API.GetDb()
    if not db then return end

    local on = db.enabled
        and db.blizzDM ~= false
        and not (db.blizzDM == nil and Details)

    if key == "enabled" or key == "blizzDM" then
        -- Switching ON needs nothing from us: the router already rings the cache
        -- callback for these two, which lands on a full refresh. OFF is the gap.
        if not on and not IsGroupInCombat() then
            StripAllTags()
        end
    elseif key == "ilvlPosition" then
        -- The one key this file renders from that nothing else announces.
        -- colorIlvl and showSetBonus already arrive over the cache callback.
        if on and not blizzDMState.disabled then ScheduleRefresh() end
    end
end

---------------------------------------------------------------
-- Event handlers (self-registering: one call = register + define)
---------------------------------------------------------------

-- === Combat START signals — strip our tags, go silent ===
RegisterHandler("PLAYER_REGEN_DISABLED", function()
    inCombat = true
    refreshActive = false
    refreshFrame:Hide()
    StripAllTags()
end)

RegisterHandler("PLAYER_IN_COMBAT_CHANGED", function(...)
    -- Guard: if any event arg is secret, fall back to InCombatLockdown().
    -- Previous approach: always assume combat-start on secret args.
    -- Problem: in Delves, PLAYER_IN_COMBAT_CHANGED fires with secret args
    -- AFTER combat ends. inCombat got stuck true with no event to reset it.
    if _hasanysecretvalues(...) then
        local icl = IsInCombatSafe()
        if icl == true then
            inCombat = true
            trace("COMBAT_CHANGED → SECRET args, ICL=true → IN")
            StripAllTags()
        else
            inCombat = false
            trace("COMBAT_CHANGED → SECRET args, ICL=false → OUT")
            traceFrameState("COMBAT_CHANGED_SECRET_OUT", true)
            StartPostCombatRefresh()
        end
        return
    end
    local combatState = ...
    if isSecret(combatState) then
        -- Lazy-taint: hasanysecretvalues passed but individual arg is secret
        local icl = IsInCombatSafe()
        if icl == true then
            inCombat = true
            trace("COMBAT_CHANGED → lazy-secret, ICL=true → IN")
            StripAllTags()
        else
            inCombat = false
            trace("COMBAT_CHANGED → lazy-secret, ICL=false → OUT")
            traceFrameState("COMBAT_CHANGED_LAZY_OUT", true)
            StartPostCombatRefresh()
        end
    elseif combatState == true then
        inCombat = true
        trace("COMBAT_CHANGED → IN")
        StripAllTags()
    else
        inCombat = false
        trace("COMBAT_CHANGED → OUT")
        traceFrameState("COMBAT_CHANGED_OUT", true)
        StartPostCombatRefresh()
    end
end)

local function OnCombatStart()
    inCombat = true
    StripAllTags()
end
RegisterHandler("ENCOUNTER_START", OnCombatStart)
RegisterHandler("INSTANCE_ENCOUNTER_ENGAGE_UNIT", OnCombatStart)

-- No-op: no longer used for combat detection, kept registered for future use
RegisterHandler("UNIT_FLAGS", function() end)

-- === Combat END signals — safe to inject again ===
RegisterHandler("PLAYER_REGEN_ENABLED", function()
    inCombat = false
    -- v1.4.2: combat is a state change. Per-player fails accumulated under
    -- combat secret-locks aren't valid OOC. Wipe wholesale; the 3-retry
    -- budget rebuilds organically on the next refresh pass. Fixes permanent
    -- GAVE-UP locks for players whose frames were transiently secret in
    -- combat but become resolvable post-combat.
    local n = WipeAllFailCounters("REGEN_ENABLED")
    trace(format("REGEN_ENABLED  wipedFails=%d", n))
    traceFrameState("REGEN_ENABLED", true)
    StartPostCombatRefresh()
end)

RegisterHandler("ENCOUNTER_END", function()
    -- Don't blindly set inCombat=false here — trash packs after a boss can
    -- mean we're still in combat. Use InCombatLockdown() as truth.
    local icl = IsInCombatSafe()
    if icl ~= true then
        inCombat = false
    end
    trace(format("ENCOUNTER_END icl=%s inCombat=%s", tostring(icl), tostring(inCombat)))
    traceFrameState("ENCOUNTER_END")
    StartPostCombatRefresh()
end)

-- === Transition events — clean slate, safe to refresh ===
local function OnTransition()
    inCombat = false
    ScheduleRefresh()
end
RegisterHandler("LOADING_SCREEN_DISABLED", OnTransition)
RegisterHandler("PLAYER_ENTERING_WORLD", OnTransition)

-- === Data events ===
RegisterHandler("DAMAGE_METER_COMBAT_SESSION_UPDATED", function()
    -- Safety reset on data events too (OnUpdate may be hidden/idle)
    if inCombat then
        local icl = IsInCombatSafe()
        local eip = IsEncounterInProgress()
        if icl ~= true and eip ~= true then
            inCombat = false
            trace("DM_SESSION_UPDATED: inCombat stuck → FORCE RESET")
            StartPostCombatRefresh()
            return
        end
    end
    if not IsGroupInCombat() then
        trace("DM_SESSION_UPDATED → dirty")
        ScheduleRefresh()
    end
end)

-- Fallback events — no special logic, just schedule a refresh
RegisterHandler("DAMAGE_METER_CURRENT_SESSION_UPDATED", ScheduleRefresh)
RegisterHandler("DAMAGE_METER_RESET", ScheduleRefresh)
-- v1.4.2: roster-leave purge. Clear nameResolveFails entries for players no
-- longer in the group so their next (re)join gets a fresh 3-retry budget
-- instead of inheriting permanent GAVE-UP from a prior session.
RegisterHandler("GROUP_ROSTER_UPDATE", function()
    local rosterNames = BuildRosterNameSet()
    local purged = 0
    for nm in pairs(nameResolveFails) do
        local short = StripRealm(nm)
        if not rosterNames[nm] and not rosterNames[short] then
            nameResolveFails[nm] = nil
            purged = purged + 1
        end
    end
    if purged > 0 then
        blizzDMState.resetCount = blizzDMState.resetCount + purged
        blizzDMState.lastResetReason = format("roster-leave (%d)", purged)
    end
    ScheduleRefresh()
end)
RegisterHandler("ZONE_CHANGED_NEW_AREA", ScheduleRefresh)

-- Dispatcher: O(1) table lookup, fallback for any future unhandled events
eventFrame:SetScript("OnEvent", function(_, event, ...)
    local handler = eventHandlers[event]
    if handler then handler(...) else ScheduleRefresh() end
end)

-- Register with core.lua's callback system (inspect complete, gear swap, etc.)
-- v1.4.2: wrapped to receive optional playerName from NotifyElvUI(name). When
-- a cache-write targets one specific player, their nameResolveFails counter is
-- cleared BEFORE RefreshAllFrames so the next InjectIlvl pass picks up the
-- fresh data instead of bouncing off the GAVE-UP early-return.
local function OnCacheChange(playerName)
    -- type() is NOT a secret check. A secret string still reports "string"
    -- (Blizzard_SharedXML/Dump.lua:98-113) — only issecretvalue can tell, and
    -- this exact misconception was corrected in four comments on 2026-08-12.
    -- It mattered here: playerName goes on to be used as a TABLE KEY in
    -- ResetFailCounter (nameResolveFails[name]) and is passed to :sub() one
    -- line below. Both throw on a secret, so the "guard" was handing a live
    -- grenade to two operations that cannot survive it.
    if playerName and not isSecret(playerName) and type(playerName) == "string" then
        ResetFailCounter(playerName, "cache:" .. playerName:sub(1, 20))
    end
    RefreshAllFrames()
end
API:RegisterCallback("blizzdm", OnCacheChange)

-- Hook DM window visibility + session changes.
-- Close/reopen and session switching (Heal→DPS, Aktuell→Gesamt) don't always
-- trigger UpdateName, so our hook misses the re-injection.
if DamageMeter.ForEachSessionWindow then
    -- Main DM frame show/hide
    if DamageMeter.SetShown then
        hooksecurefunc(DamageMeter, "SetShown", function() ScheduleRefresh() end)
    end
    -- Per-window: Show, Refresh, session type changes
    DamageMeter:ForEachSessionWindow(function(sessionWindow)
        if sessionWindow.Show then
            hooksecurefunc(sessionWindow, "Show", function() ScheduleRefresh() end)
        end
        if sessionWindow.Refresh then
            hooksecurefunc(sessionWindow, "Refresh", function(sw)
                -- Session switch (DPS→Gesamt, Heal→DPS): frames get recycled
                -- for different players. Clear per-frame caches so InjectIlvl
                -- re-resolves everything fresh via Ambiguate API.
                if sw.ForEachEntryFrame then
                    sw:ForEachEntryFrame(function(frame)
                        -- A guessed GUID carries no guarantee that it still belongs
                        -- to this row, so it goes: a recycled frame can represent a
                        -- DIFFERENT player while sourceName is still secret, and a
                        -- preserved guess would paint the previous occupant's item
                        -- level onto the wrong bar.
                        --
                        -- An API identity is the opposite case and must SURVIVE.
                        -- Refresh re-Inits every frame BEFORE this post-hook body
                        -- runs (DamageMeterSessionWindow.lua:747-750, and :762 →
                        -- SetDataProvider → the initializer, which ScrollBox runs
                        -- synchronously), so CaptureIdentityAndInject has already
                        -- cleared and re-established each frame's identity from
                        -- Blizzard's own combatSource. Wiping again here deleted
                        -- exactly that, in the same call stack, a moment later.
                        --
                        -- That is why every live dump read "(0 api)": the identity
                        -- survived only on rows the ScrollBox acquired by SCROLLING,
                        -- the one path that never goes through Refresh — which is
                        -- also why a dump taken right after scrolling read "(4 api)"
                        -- for exactly the four newly exposed rows. The consequence
                        -- was not wrong data but no data: with no API identity, a
                        -- row whose name Blizzard still protects after a fight has
                        -- nothing to be attributed by, so it stays untagged even
                        -- though its item level is sitting in our cache.
                        if not frame._dilvlGUIDFromAPI then
                            SetFrameGUID(frame, nil, false, nil)
                            frame._dilvlFontFile = nil
                            frame._dilvlFontSize = nil
                            frame._dilvlFontFlags = nil
                            frame._dilvlTextScale = nil
                            frame._dilvlTextColor = nil
                            frame._dilvlColorSetByAddon = nil
                        end
                    end)
                    -- Reset per-player resolve fails (session switch = new context)
                    WipeAllFailCounters("session-switch")
                end
                ScheduleRefresh()
            end)
        end
    end)
end

---------------------------------------------------------------
-- Debug diagnostics — called by core.lua's /dilvl debug
-- Returns: windows, frames, hasGuid, hasTag, secretName, entries[], combatInfo,
--          resolveFails, maxResolveFails, apiGuid, unverifiedNameSkips,
--          identityBackfills
-- combatInfo = { groupCombat, inCombat, encounter, unitFlags }
---------------------------------------------------------------
API.GetBlizzDMDebug = function()
    local windows, frames, hasGuid, hasTag, secretName = 0, 0, 0, 0, 0
    local apiGuid = 0 -- of hasGuid: how many came straight from Blizzard's combatSource
    local entries = {}

    -- Detailed combat state for debug output
    local eip = IsEncounterInProgress()
    local icl = InCombatRaw()
    local unitFlagsCombat = false
    local count = GetNumGroupMembers()
    if count > 0 then
        local prefix = IsInRaid() and "raid" or "party"
        for i = 1, count do
            local afc = UnitAffectingCombat(prefix .. i)
            if afc == true or isSecret(afc) then
                unitFlagsCombat = true
                break
            end
        end
    end
    local combatInfo = {
        groupCombat = IsGroupInCombat(),
        iclRaw = (isSecret(icl) and "SECRET") or (icl == true and "YES") or "no",
        inCombat = inCombat,
        encounter = eip == true,
        encounterSecret = eip and isSecret(eip),
        unitFlags = unitFlagsCombat,
        members = count,
        refreshActive = refreshActive,
        refreshPasses = refreshStats.passes,
        refreshTagged = refreshStats.tagged,
        refreshTotal = refreshStats.total,
        refreshLastPass = refreshStats.lastPass,
        deferredRetry = deferredRetryPending, -- (#19)
        ctrlOk = bfCtrl.ok,
        ctrlBad = bfCtrl.bad,
        ctrlClassBad = bfCtrl.classBad,
        ctrlWindows = bfCtrl.windows,
        ctrlTrusted = bfCtrl.trusted,
    }

    if not DamageMeter.ForEachSessionWindow then
        return 0, 0, 0, 0, 0, entries, combatInfo
    end

    DamageMeter:ForEachSessionWindow(function(sessionWindow)
        if not sessionWindow:IsShown() then return end
        if not sessionWindow.ForEachEntryFrame then return end
        windows = windows + 1
        sessionWindow:ForEachEntryFrame(function(frame)
            frames = frames + 1

            local name = frame.sourceName
            local nameSecret = name and isSecret(name)
            local displayName = nameSecret and "(secret)" or tostring(name or "nil")
            local isLocal = frame.isLocalPlayer == true
            local guid = ResolveFrameGUID(frame)
            local hasCached = false
            local cacheName = nil
            if guid then
                hasGuid = hasGuid + 1
                -- Split by TRUST, not just presence: an API-sourced GUID is a
                -- fact from Blizzard, a name-resolved one is our guess. Only the
                -- first may put a name on screen, so the ratio matters.
                if frame._dilvlGUIDFromAPI then apiGuid = apiGuid + 1 end
                local cached = API.GetCacheData(guid)
                hasCached = cached and cached.ilvl ~= nil
                if cached and cached.name then
                    cacheName = tostring(cached.name)
                end
            end

            local tagged = false
            local txtSecret = false
            local alphaHidden = false
            local nativeTxt = nil
            local nameFS = frame:GetName()
            local nameFSType = nameFS and type(nameFS) or "nil"
            if nameFS and type(nameFS) ~= "string" then
                -- Safety net: detect invisible native FontString
                local alpha = nameFS:GetAlpha()
                if alpha and not isSecret(alpha) and alpha < 0.5 then
                    alphaHidden = true
                end
                local txt = nameFS:GetText()
                if txt and not isSecret(txt) then
                    nativeTxt = tostring(txt):sub(1, 30)
                    if type(txt) == "string" and txt:find("%[%d+%]") then
                        tagged = true
                        hasTag = hasTag + 1
                    end
                elseif txt and isSecret(txt) then
                    nativeTxt = "(secret)"
                    txtSecret = true
                    secretName = secretName + 1
                else
                    nativeTxt = "(nil)"
                end
            elseif nameFS and type(nameFS) == "string" then
                -- GetName() returned a string (frame name), not a FontString!
                nativeTxt = "STR:" .. nameFS:sub(1, 20)
            end

            -- Determine what path InjectIlvl would take
            local path = "?"
            if IsGroupInCombat() then
                path = "COMBAT-SKIP"
            elseif not guid then
                local sn = frame.sourceName
                local snDbg = sn and not isSecret(sn) and tostring(sn) or nil
                if snDbg and nameResolveFails[snDbg] and nameResolveFails[snDbg] >= MAX_RESOLVE_FAILS then
                    path = "GAVE-UP(" .. snDbg:sub(1,10) .. ")"
                else
                    -- Carry the backfill's own verdict for this row. Without it
                    -- NO-GUID says only "we do not know who this is", which is
                    -- true of a row nobody ever looked at and of a row the join
                    -- deliberately refused, and those need opposite responses.
                    local bw = frame._dilvlBfWhy
                    path = bw and ("NO-GUID:" .. tostring(bw)) or "NO-GUID"
                end
            elseif not API.GetCacheData(guid) or not API.GetCacheData(guid).ilvl then
                path = "NO-CACHE"
            else
                local nt = frame.nameText
                if nt and not isSecret(nt) then
                    path = "CLEAN"
                else
                    local sn = frame.sourceName
                    local resolved = false
                    if sn and not isSecret(sn) then
                        resolved = true
                    elseif isLocal then
                        resolved = true
                    elseif cacheName then
                        -- Mirror InjectIlvl's trust rule exactly. Without this
                        -- the dump reported CACHE-NAME for rows the real code
                        -- now refuses to touch — a report that describes
                        -- behaviour the addon no longer has is worse than no
                        -- report, because it is what we reason from.
                        if frame._dilvlGUIDFromAPI or isLocal then
                            resolved = true
                            path = "CACHE-NAME"
                        else
                            path = "NAME-SKIP"
                        end
                    end
                    if resolved and path ~= "CACHE-NAME" then
                        -- Check FontString path
                        if nameFS and type(nameFS) ~= "string" then
                            local ft = nameFS:GetText()
                            if ft and not isSecret(ft) then
                                path = "CLEAN-FS"
                            else
                                path = "OVERLAY"
                            end
                        else
                            path = "NO-FS"
                        end
                    elseif not resolved then
                        path = "NO-NAME"
                    end
                end
            end

            -- What the row is ACTUALLY rendered with right now, read back from
            -- the live FontString rather than from our own cache -- the cache is
            -- the suspect, so quoting it would prove nothing.
            local fontDbg
            if nameFS and type(nameFS) ~= "string" then
                local okF, ff, fh, fl = pcall(nameFS.GetFont, nameFS)
                local okS, ts = pcall(nameFS.GetTextScale, nameFS)
                if okF and fh and not isSecret(fh) then
                    fontDbg = format("%s%s x%s",
                        tostring(fh),
                        (fl and fl ~= "" and ("/" .. tostring(fl))) or "",
                        (okS and ts and not isSecret(ts)) and tostring(ts) or "?")
                end
            end

            entries[#entries + 1] = {
                fontDbg = fontDbg,
                name = displayName,
                isLocal = isLocal,
                guid = guid ~= nil,
                cached = hasCached,
                tagged = tagged,
                secret = txtSecret,
                alphaHidden = alphaHidden,
                nativeTxt = nativeTxt,
                cacheName = cacheName,
                textColor = (function()
                    -- Show current FS color + source for debug
                    local colorStr = ""
                    if nameFS and type(nameFS) ~= "string" then
                        local ok, r, g, b = pcall(nameFS.GetTextColor, nameFS)
                        if ok and r and not isSecret(r) then
                            colorStr = format("%.2f/%.2f/%.2f", r, g, b)
                        else
                            colorStr = "secret"
                        end
                    end
                    -- Determine color source
                    local src = "blizz"
                    if frame._dilvlColorSetByAddon then
                        src = frame._dilvlColorSetByAddon
                    end
                    return colorStr ~= "" and (colorStr .. "(" .. src .. ")") or nil
                end)(),
                path = path,
                nameFSType = nameFSType,
                resolveFails = (function()
                    local sn = frame.sourceName
                    local snK = sn and not isSecret(sn) and tostring(sn) or nil
                    return snK and nameResolveFails[snK] or 0
                end)(),
            }
        end)
    end)
    -- Expose per-player resolve fail counts for debug
    local resolveFails = {}
    for name, count in pairs(nameResolveFails) do
        resolveFails[#resolveFails + 1] = { name = name, fails = count, gaveUp = count >= MAX_RESOLVE_FAILS }
    end

    -- Only the reasons that actually fired, in the order the chain checks them,
    -- so the first non-zero entry IS the place it breaks.
    local bfOrder = {"direct",
        "combat", "noApi", "noSession", "secretSession", "noSources",
        "noIndex", "noSrc", "classSecret", "classDiff", "specDiff", "ambiguous",
        "noLicence", "guidNil", "guidSecret"}
    local bfReason = ""
    for _, k in ipairs(bfOrder) do
        if (bfWhy[k] or 0) > 0 then
            bfReason = bfReason .. format("%s%s=%d", bfReason == "" and "" or "  ", k, bfWhy[k])
        end
    end

    return windows, frames, hasGuid, hasTag, secretName, entries, combatInfo, resolveFails, MAX_RESOLVE_FAILS, apiGuid, unverifiedNameSkips, identityBackfills, bfReason
end

---------------------------------------------------------------
-- Global trace toggle — called from /dilvl blizztrace
---------------------------------------------------------------
function Details_iLvlDisplay_BlizzTrace(showWindow)
    traceEnabled = not traceEnabled
    if traceEnabled then
        wipe(traceLog)
        print("|cFF00FF00Details! iLvl Display:|r Blizz trace |cFF00FF00ON|r — fight, leave combat, then /dilvl blizztrace")
    else
        print("|cFF00FF00Details! iLvl Display:|r Blizz trace |cFFFF0000OFF|r")
        if showWindow and #traceLog > 0 then
            local buf = {"=== Blizz DM Event Trace (" .. #traceLog .. " entries) ===\n"}
            for _, entry in ipairs(traceLog) do
                table.insert(buf, entry)
            end
            table.insert(buf, "\n=== End Trace ===")
            local text = table.concat(buf, "\n")
            if Details_iLvlDisplay_ShowDebugWindow then
                Details_iLvlDisplay_ShowDebugWindow(text)
            else
                print(text)
            end
        elseif showWindow then
            print("  (no events captured)")
        end
    end
end
