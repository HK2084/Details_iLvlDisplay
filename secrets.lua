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
-- Safe InCombatLockdown wrappers (WoW 12.0+).
--
-- Inside instances, InCombatLockdown() can return a secret value. A
-- secret-wrapped false is truthy in Lua (userdata, not nil/false), so a
-- raw `if InCombatLockdown() then` is ALWAYS true when the return is
-- secret. Two wrappers with opposite secret-default policies:
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
