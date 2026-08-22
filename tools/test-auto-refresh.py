# -*- coding: utf-8 -*-
"""Behaviour test for the post-fight auto-flip fallback.

The mechanism was proven live 21.08.2026 (manual cvarflip, outcome (a)). This
suite is not about the mechanism - it is about the DISCIPLINE around it, which
is what the maintainer conditioned the feature on:

  * fires only when sealed rows remain after the documented paths
  * one shot per fight, spent before the flip, re-armed at combat start
  * never in combat, never in an active keystone, off-switch respected
  * kills itself for the session when a bounce stops helping (the canary for
    Blizzard changing the undocumented behaviour underneath us)

Drives the REAL TryAutoFlip extracted from blizzdm.lua.
"""
import io, os, re, sys
import lupa
from control_harness import run_controls

os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
SRC = io.open("blizzdm.lua", encoding="utf-8").read().replace("\r\n", "\n")

m = re.search(r"^local autoFlipArmed = true.*?^Details_iLvlDisplay_BlizzDMTryAutoFlip = TryAutoFlip$",
              SRC, re.M | re.S)
if not m:
    sys.exit("AutoFlip-Block nicht gefunden")
BLOCK = m.group(0)
for needle, why in [
    ("autoFlipArmed = false", "der Einmal-Riegel"),
    ("autoFlipDead = true", "der Sitzungs-Kill-Switch"),
    ("ChallengeMode", "die Keystone-Sperre"),
    ("db.blizzAutoRefresh == false", "der Nutzer-Schalter"),
]:
    if needle not in BLOCK:
        sys.exit("%s fehlt im AutoFlip-Block" % why)

HARNESS = u"""
local SECRET = setmetatable({}, {})
local function isSecret(v) return v == SECRET end
local function format(...) return string.format(...) end
local function trace() end

COMBAT = false
local function IsGroupInCombat() return COMBAT end

KEYSTONE = false
C_RestrictedActions = {IsAddOnRestrictionActive = function(t)
    return t == 2 and KEYSTONE or false
end}
Enum = {AddOnRestrictionType = {Combat = 0, ChallengeMode = 2}}

DB = {enabled = true, blizzDM = true, blizzAutoRefresh = true}
local API = {GetDb = function() return DB end}
Details = nil

local blizzDMState = {disabled = false}
STATE = blizzDMState

SHOWN = true
DamageMeter = {IsShown = function() return SHOWN end}

CVAR = "1"
CVAR_LOG = {}
function GetCVar(name) return CVAR end
function SetCVar(name, v)
    CVAR = v
    CVAR_LOG[#CVAR_LOG + 1] = v
    if THROW_ON_SET then error("blocked") end
end
THROW_ON_SET = false

-- Zensus: wie viele versiegelte Zeilen. Vom Test gesteuert; sinkt nach einem
-- Flip nur, wenn EFFECTIVE wahr ist -- so wird der Kill-Switch pruefbar.
SEALED = 0
EFFECTIVE = true
local function SecureTestCensus()
    return 25, SEALED, SEALED
end

TIMERS = {}
C_Timer = {After = function(delay, fn) TIMERS[#TIMERS + 1] = fn end}
local function ScheduleRefresh() end

__BLOCK__

local R = {}
local function runTimers()
    local t = TIMERS
    TIMERS = {}
    for _, fn in ipairs(t) do
        if EFFECTIVE and CVAR == "1" and #CVAR_LOG >= 2 then SEALED = 0 end
        fn()
    end
end

local function reset(opts)
    opts = opts or {}
    COMBAT = opts.combat or false
    KEYSTONE = opts.keystone or false
    SHOWN = opts.shown ~= false
    CVAR = "1"
    CVAR_LOG = {}
    TIMERS = {}
    SEALED = opts.sealed or 5
    EFFECTIVE = opts.effective ~= false
    DB.blizzAutoRefresh = opts.toggle ~= false
    Details_iLvlDisplay_BlizzDMArmAutoFlip()
end

-- 1) Normalfall: versiegelte Zeilen -> genau ein Flip 0->1
reset({})
TryAutoFlip()
runTimers()
R.flips1 = table.concat(CVAR_LOG, ",")
R.armedAfter = Details_iLvlDisplay_BlizzDMAutoFlipState().armed

-- 2) Zweiter Versuch im selben Kampf: nichts
TryAutoFlip()
R.flips2 = table.concat(CVAR_LOG, ",")

-- 2b) Der Riegel allein, vom Zensus getrennt: Zeilen bleiben versiegelt
-- (Timer nie gelaufen), trotzdem kein zweiter Flip im selben Kampf.
reset({})
TryAutoFlip()
TryAutoFlip()
R.latchProbe = table.concat(CVAR_LOG, ",")
runTimers()

-- 3) Neuer Kampf: wieder scharf
Details_iLvlDisplay_BlizzDMArmAutoFlip()
R.rearmed = Details_iLvlDisplay_BlizzDMAutoFlipState().armed

-- 4) Keine versiegelten Zeilen: kein Flip, Schuss bleibt im Lauf
reset({sealed = 0})
TryAutoFlip()
R.noSealed = #CVAR_LOG
R.stillArmed = Details_iLvlDisplay_BlizzDMAutoFlipState().armed

-- 5) Sperren: Kampf, Keystone, Schalter, verstecktes Meter
reset({combat = true});   TryAutoFlip(); R.gateCombat = #CVAR_LOG
reset({keystone = true}); TryAutoFlip(); R.gateKeystone = #CVAR_LOG
reset({toggle = false});  TryAutoFlip(); R.gateToggle = #CVAR_LOG
reset({shown = false});   TryAutoFlip(); R.gateHidden = #CVAR_LOG

-- 5b) Verify-Fenster: der naechste Pull laeuft schon, wenn der 0.5s-Zensus
-- feuert. Zeilen sind dann bauartbedingt wieder versiegelt -- das darf einen
-- funktionierenden Bounce NICHT fuer tot erklaeren.
reset({})
TryAutoFlip()
COMBAT = true
EFFECTIVE = false
runTimers()
R.verifyInCombatDead = Details_iLvlDisplay_BlizzDMAutoFlipState().dead
COMBAT = false

-- 6) Kill-Switch: der Flip senkt die Zahl nicht -> tot fuer die Sitzung
reset({effective = false})
TryAutoFlip()
runTimers()
R.deadAfter = Details_iLvlDisplay_BlizzDMAutoFlipState().dead
Details_iLvlDisplay_BlizzDMArmAutoFlip()
reset({effective = true})
TryAutoFlip()
R.deadStays = #CVAR_LOG

return R
"""

chunk = HARNESS.replace("__BLOCK__", BLOCK)
R = lupa.LuaRuntime(unpack_returned_tuples=False).execute(chunk)

checks = [
    ("versiegelte Zeilen nach dem Kampf: genau ein Flip 0 dann 1",
     R["flips1"] == "0,1"),
    ("der Schuss ist danach verbraucht", R["armedAfter"] is False),
    ("kein zweiter Flip im selben Kampf", R["flips2"] == "0,1"),
    ("auch bei weiter versiegelten Zeilen kein zweiter Flip",
     R["latchProbe"] == "0,1"),
    ("Kampfbeginn stellt wieder scharf", R["rearmed"] is True),
    ("ohne versiegelte Zeilen kein Flip", R["noSealed"] == 0),
    ("und der Schuss bleibt fuer spaeter im Lauf", R["stillArmed"] is True),
    ("Kampf-Sperre haelt", R["gateCombat"] == 0),
    ("Keystone-Sperre haelt", R["gateKeystone"] == 0),
    ("Nutzer-Schalter haelt", R["gateToggle"] == 0),
    ("verstecktes Meter: kein Flip", R["gateHidden"] == 0),
    ("Zensus mitten im naechsten Pull toetet das Feature nicht",
     R["verifyInCombatDead"] is False),
    ("wirkungsloser Flip toetet das Feature fuer die Sitzung",
     R["deadAfter"] is True),
    ("und tot bleibt tot, auch nach neuem Kampf", R["deadStays"] == 0),
]

print()
bad = 0
for n, ok in checks:
    print("  %s  %s" % ("PASS" if ok else "FAIL", n))
    bad += 0 if ok else 1

print()
controls = [
    ("Einmal-Riegel entfernt (zweiter Flip im selben Kampf)",
     chunk.replace("    autoFlipArmed = false\n", "", 1),
     lambda r: r["latchProbe"] == "0,1"),
    ("Kill-Switch entfernt (wirkungsloser Flip wiederholt sich)",
     chunk.replace('autoFlipDead = true\n                blizzDMState.autoFlipDead = format', 'blizzDMState.autoFlipDead = format'),
     lambda r: r["deadAfter"] is True),
    ("Keystone-Sperre entfernt",
     chunk.replace("if okR and act == true then return end", ""),
     lambda r: r["gateKeystone"] == 0),
    ("Zensus-Bedingung entfernt (Flip auch ohne versiegelte Zeilen)",
     chunk.replace("if sealedRows == 0 then return end", ""),
     lambda r: r["noSealed"] == 0),
    ("Kampf-Sperre im Verify-Fenster entfernt (Pull-Zensus toetet den Bounce)",
     chunk.replace("            if IsGroupInCombat() then return end\n", ""),
     lambda r: r["verifyInCombatDead"] is False),
]
bad += run_controls(chunk, controls)

print("\n%s" % ("ALLE %d PRUEFUNGEN GRUEN" % len(checks) if not bad else "%d FEHLER" % bad))
sys.exit(1 if bad else 0)
