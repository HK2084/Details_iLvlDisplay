-- Details! Item Level Display — Copyright (c) 2026 HK2084. All rights reserved.
-- Licensed for private use only; see LICENSE. No redistribution of modified copies.
-- NO AI/ML USE. Permission is expressly withheld for training, embedding, indexing,
-- retrieval, code generation or any comparable use. See LICENSE clause 6.
-- secrets.lua — WoW 12.0+ secret-value defense layer
--
-- Centralizes the guard helpers that wrap Blizzard APIs which can return
-- tainted values (`issecretvalue`-true) or hard-reject tainted callers
-- (`AllowedWhenUntainted` SecretArguments). All sub-files (Details!,
-- BlizzDM, ElvUI, Grid2, Danders) read from here so the defense is
-- implemented once and consistent.
--
-- LOAD ORDER: must load AFTER init.lua (uses `ns`) and BEFORE core.lua
-- (core's locals shadow ns.secrets.X to keep the inline call sites short).
--
-- WHAT'S INTENTIONALLY NOT HERE:
-- - SafeCall + detailsBarErrors counter — wraps Details!-bar hooks, the
--   counter mutates `db.showInDetails`, so the function lives next to its
--   callers in core.lua. Other features (BlizzDM, Danders, ElvUI/Grid2
--   callbacks) carry their own per-feature counters in their own files,
--   so this file stays free of feature-specific kill-switch state.
--
-- 12.0.7 NOTE (Build 67227, scheduled 2026-06-16):
--   Four Preconditions changed FailureMode from ReturnNothing to
--   ReturnWithError:
--     - RequiresDeclassifiedUnitIdentity     (UnitName, UnitGUID, etc.)
--     - RequiresScriptObjectAlphaAccess
--     - RequiresScriptObjectDesaturationAccess
--     - RequiresStatusBarDesaturationAccess
--   Our SafeUnitName + SafeUnitIsUnit pcall-wrap both paths so the
--   addon stays alive whether the API returns secrets, returns nothing,
--   or hard-errors. No callsite change required.

local _, ns = ...
local S = ns.secrets

-- Per-call counters surfaced in /dilvl debug. core.lua reads these.
--   unitNameBlocked    -> SafeUnitName saw a secret-wrapped return
--   unitNameRejected   -> SafeUnitName's pcall caught a hard error (#26)
--   unitIsUnitBlocked  -> SafeUnitIsUnit refused via CanCompareUnitTokens
--                         OR caught a hard error from pcall fallback
S.stats = { unitNameBlocked = 0, unitNameRejected = 0, unitIsUnitBlocked = 0 }

----------------------------------------------------------------
-- Secret value guard (WoW 12.0+)
-- issecretvalue() / issecrettable() are Blizzard globals that
-- return true for tainted values that crash on string ops.
-- Check BEFORE touching the value — avoids the pcall entirely.
----------------------------------------------------------------
function S.isSecretValue(val)
    if issecretvalue and issecretvalue(val) then return true end
    if issecrettable and issecrettable(val) then return true end
    return false
end

-- Batch guard: true if ANY arg in the varargs is secret (#15)
S._hasanysecretvalues = hasanysecretvalues or function() return false end

----------------------------------------------------------------
-- 12.0.5 added C_Secrets.CanCompareUnitTokens(unit1, unit2). Cached at
-- file load — the API surface is stable for the addon session.
----------------------------------------------------------------
local CanCompareUnitTokens = C_Secrets and C_Secrets.CanCompareUnitTokens

----------------------------------------------------------------
-- Safe UnitIsUnit wrapper (12.0.5+: UnitIsUnit requires
-- CanCompareUnitTokens guard). Returns true/false, never a secret value.
-- Returns nil when the comparison is blocked.
----------------------------------------------------------------
function S.SafeUnitIsUnit(unit1, unit2)
    if CanCompareUnitTokens then
        if not CanCompareUnitTokens(unit1, unit2) then
            S.stats.unitIsUnitBlocked = S.stats.unitIsUnitBlocked + 1
            return nil
        end
        return not not UnitIsUnit(unit1, unit2)
    end
    -- Pre-12.0.5 fallback: pcall to catch secret errors
    local ok, result = pcall(UnitIsUnit, unit1, unit2)
    if not ok then
        S.stats.unitIsUnitBlocked = S.stats.unitIsUnitBlocked + 1
        return nil
    end
    return not not result
end

----------------------------------------------------------------
-- Safe UnitName wrapper (12.0.5+: UnitName.SecretArguments has
-- flip-flopped between AllowedWhenTainted and AllowedWhenUntainted across
-- builds — 67186 introduced hard-reject, 67235 rolled it back, 12.0.7
-- 67227 keeps AllowedWhenTainted but flips the precondition FailureMode
-- to ReturnWithError. pcall handles all three paths.
-- Returns name, realm or nil, nil when blocked by secrets OR when the
-- call is hard-rejected from a tainted execution context (#26).
--
-- Predicate rename, recorded so nobody investigates it twice: with build 69587
-- Blizzard renamed UnitName's guard from SecretWhenUnitIdentityRestricted to
-- SecretWhenUnitNameIdentityRestricted (radar run 06.09.2026). Rename only,
-- same behaviour, absorbed here unchanged. UnitGUID kept the old name — the two
-- are separate predicates now. SecretArguments stays on the watchlist: it is
-- AllowedWhenTainted today and has flipped before.
----------------------------------------------------------------
function S.SafeUnitName(unit)
    local ok, name, realm = pcall(UnitName, unit)
    if not ok then
        S.stats.unitNameRejected = S.stats.unitNameRejected + 1
        return nil, nil
    end
    if name and S.isSecretValue(name) then
        S.stats.unitNameBlocked = S.stats.unitNameBlocked + 1
        return nil, nil
    end
    if realm and S.isSecretValue(realm) then realm = nil end
    return name, realm
end

----------------------------------------------------------------
-- Safe UnitGUID wrapper. UnitGUID() can return a secret value inside
-- instances; using a secret GUID as a table key throws ("attempt to use a
-- secret value as a table key"), and the oUF / Grid2 tag environment can be
-- tainted when a frame re-evaluates. ElvUI itself shipped a fix for exactly
-- this ("oUF unitGUID secret error"). Returns the GUID, or nil when it's
-- unavailable / secret / hard-rejected. (Verified build 12.0.7.68256: UnitGUID
-- is gated by the SecretWhenUnitIdentityRestricted predicate — it RETURNS a
-- secret value for derived/foreign tokens, it does NOT hard-error; the
-- isSecretValue check covers that. The pcall future-proofs a FailureMode flip
-- and the separate RequiresDeclassifiedUnitIdentity precondition used elsewhere.)
----------------------------------------------------------------
function S.SafeUnitGUID(unit)
    if not unit then return nil end
    local ok, guid = pcall(UnitGUID, unit)
    if not ok or not guid then return nil end
    if S.isSecretValue(guid) then return nil end
    return guid
end

----------------------------------------------------------------
-- Safe InCombatLockdown wrappers (WoW 12.0+).
--
-- Inside instances, InCombatLockdown() can return a secret value. A secret
-- never reads as nil/false in a conditional — even when the value behind it
-- IS false — so a raw `if InCombatLockdown() then` is ALWAYS true when the
-- return is secret. (Note: a secret keeps its underlying Lua type; type() on
-- a secret string still says "string". The reliable test is issecretvalue(),
-- never a type check.) Two wrappers with opposite secret-default policies:
--
--   IsInCombatSafe()   -- secret => false  (use for inspect queue,
--                                            refresh, measurement)
--   MayBeInCombat()    -- secret => true   (use before touching
--                                            protected frames)
----------------------------------------------------------------
function S.IsInCombatSafe()
    local v = InCombatLockdown()
    if S.isSecretValue(v) then return false end
    return v
end

function S.MayBeInCombat()
    local v = InCombatLockdown()
    if S.isSecretValue(v) then return true end
    return v
end

----------------------------------------------------------------
-- Raw InCombatLockdown for DIAGNOSTICS ONLY (/dilvl debug). Returns the
-- unmodified value so the bug-report dump can SHOW whether it is secret
-- ("YES"/"SECRET"/"no"). The only non-policy raw read in the file; every
-- caller MUST test isSecretValue() BEFORE any comparison. Routed through here
-- so the .luacheckrc invariant (no raw InCombatLockdown outside secrets.lua)
-- has zero exceptions — grep stays clean, CI stays absolute.
----------------------------------------------------------------
function S.InCombatRaw()
    return InCombatLockdown()
end

----------------------------------------------------------------
-- canaccessvalue -- the question issecretvalue cannot answer.
--
-- issecretvalue asks "is this value sealed?"; canaccessvalue asks "may THIS
-- function touch it?" -- and the two come apart. A value can be secret and
-- still readable by us (Blizzard exempts party and raid members from several
-- identity predicates), and permission is judged against the immediate calling
-- function, so the answer belongs to the caller, not to the value.
--
-- Blizzard uses it exactly that way (ChatFrameFilters.lua:37), to decide
-- whether handing a decorated player name to a tainted callback is worthwhile.
--
-- pcall'd on purpose: the API itself carries SecretArguments =
-- "AllowedWhenUntainted", so calling it from our tainted code with a secret
-- argument is not guaranteed to be legal. A guard that throws is worse than no
-- guard at all.
--
-- Returns true / false / nil, where nil means "no answer" -- the API is absent
-- or the call itself was refused. Callers must treat nil as "no access".
--
-- No caller yet: this is the wrapper layer, and completeness here is the point
-- (same reason InCombatRaw exists). Grid2 needed this predicate where
-- issecretvalue was not enough; when we hit that case, the guard is in place.
----------------------------------------------------------------
function S.CanAccessValue(val)
    if not canaccessvalue then return nil end
    local ok, res = pcall(canaccessvalue, val)
    if not ok then return nil end
    if res == true then return true end
    if res == false then return false end
    return nil
end

----------------------------------------------------------------
-- GUID identity lookups -- the E2 probe set.
--
-- All four carry SecretWhenUnitIdentityRestricted on live: inside a restricted
-- instance they hand back a secret, and comparing or concatenating one throws.
-- They live here rather than at the call site so the .luacheckrc gate can keep
-- them out of the rest of the addon -- a new call site anywhere else then fails
-- CI instead of shipping.
--
-- Read-only. Every caller must isSecretValue-check the return before touching
-- it AND pcall the call itself: the lookups can throw on a sealed GUID.
----------------------------------------------------------------
S.guidLookups = {
    UnitTokenFromGUID   = UnitTokenFromGUID,
    UnitNameFromGUID    = UnitNameFromGUID,
    UnitClassFromGUID   = UnitClassFromGUID,
    GetPlayerInfoByGUID = GetPlayerInfoByGUID,
}

