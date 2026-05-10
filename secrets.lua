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
-- - SafeCall + hookErrors counter — those wrap Details!-bar hooks, the
--   counter mutates `db.showInDetails`, so the function lives next to its
--   callers in core.lua. A future per-feature SafeCall refactor will
--   generalize that pattern; this file stays free of feature-specific
--   kill-switch state.
-- - blizzdm.lua's local `isSecret` / `_hasanysecretvalues` duplicates —
--   Issue #26 will migrate those callers to use ns.secrets.* directly.

local _, ns = ...
local S = ns.secrets

-- Per-call counters surfaced in /dilvl debug. core.lua reads
-- secretStats.unitNameBlocked + secretStats.unitIsUnitBlocked.
S.stats = { unitNameBlocked = 0, unitIsUnitBlocked = 0 }

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
-- builds — most recent flip was 67235 rolling back 67186's hard-reject).
-- Returns name, realm or nil, nil when blocked by secrets.
--
-- NOTE: this guards against secret RETURNS only. Callers that may run
-- from tainted execution context should additionally pcall the function
-- — Issue #26 tracks the blizzdm.lua hardening.
----------------------------------------------------------------
function S.SafeUnitName(unit)
    local name, realm = UnitName(unit)
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
