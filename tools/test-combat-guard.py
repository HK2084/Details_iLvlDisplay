# -*- coding: utf-8 -*-
"""The combat guard must catch combat even when our own event flag missed it.

Live 21.08.2026, raid trash. The report read:

    Group: raid (11 members)  InCombat: yes
    combat: group=no  self=no  ICL=YES  encounter=no  unitFlags=YES

group=no is IsGroupInCombat, the gate every write goes through. ICL=YES is the
client's own InCombatLockdown. The gate said "not in combat" while the client
said the opposite, and seven rows were written mid-fight - the one thing this
addon's design says never happens.

The cause is not exotic: the gate consulted our own PLAYER_REGEN_DISABLED flag
and IsEncounterInProgress, and nothing else. An event can be missed - entering
combat across a loading screen, or before the handlers are registered - and then
no signal remains. Shipped that way since at least v1.5.9; the function is
byte-identical on master.

Only an explicit `true` counts as in combat, so a secret or unknown lockdown
still reads as out of combat. That rule is older than this fix and stays.

Drives the REAL IsGroupInCombat extracted from blizzdm.lua.
"""
import io, os, re, sys
import lupa
from control_harness import run_controls

os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
SRC = io.open("blizzdm.lua", encoding="utf-8").read().replace("\r\n", "\n")

m = re.search(r"^function IsGroupInCombat\(\)\n.*?^end$", SRC, re.M | re.S)
if not m:
    sys.exit("IsGroupInCombat nicht gefunden")
GUARD = m.group(0)
if "IsInCombatSafe" not in GUARD:
    sys.exit("die Sperre fragt InCombatLockdown nicht")

HARNESS = u"""
local SECRET = setmetatable({}, {})

inCombat = false
ICL = false
EIP = false

function IsInCombatSafe() return ICL end
function IsEncounterInProgress() return EIP end

__GUARD__

local R = {}
local function probe(flag, icl, eip)
    inCombat, ICL, EIP = flag, icl, eip
    return IsGroupInCombat()
end

R.nothing      = probe(false, false, false)
R.ownFlag      = probe(true,  false, false)
-- Der Live-Fall: eigenes Ereignis verpasst, der Client sagt trotzdem Kampf.
R.iclOnly      = probe(false, true,  false)
R.encounterOnly= probe(false, false, true)
R.allThree     = probe(true,  true,  true)
-- Nur ein ausdrueckliches true zaehlt: ein Geheimwert oder nil bleibt "draussen".
R.iclSecret    = probe(false, SECRET, false)
R.iclNil       = probe(false, nil,   false)
R.eipSecret    = probe(false, false, SECRET)

inCombat, ICL, EIP = false, false, false
return R
"""

chunk = HARNESS.replace("__GUARD__", GUARD)
R = lupa.LuaRuntime(unpack_returned_tuples=False).execute(chunk)

checks = [
    ("ohne jedes Signal: kein Kampf", R["nothing"] is False),
    ("eigenes Ereignis-Flag zaehlt", R["ownFlag"] is True),
    ("Kampfsperre des Clients allein zaehlt (der Live-Fall)",
     R["iclOnly"] is True),
    ("laufender Encounter zaehlt", R["encounterOnly"] is True),
    ("alle drei zusammen", R["allThree"] is True),
    ("geheime Kampfsperre gilt als draussen", R["iclSecret"] is False),
    ("fehlende Kampfsperre gilt als draussen", R["iclNil"] is False),
    ("geheimer Encounter gilt als draussen", R["eipSecret"] is False),
]

print()
bad = 0
for n, ok in checks:
    print("  %s  %s" % ("PASS" if ok else "FAIL", n))
    bad += 0 if ok else 1

print()
controls = [
    ("Client-Kampfsperre nicht mehr gefragt (der Zustand vor dem Fix)",
     chunk.replace("if IsInCombatSafe() == true then return true end", ""),
     lambda r: r["iclOnly"] is True),
    ("eigenes Flag nicht mehr gefragt",
     chunk.replace("if inCombat then return true end", ""),
     lambda r: r["ownFlag"] is True),
    ("Encounter nicht mehr gefragt",
     chunk.replace("if eip == true then return true end", ""),
     lambda r: r["encounterOnly"] is True),
]
bad += run_controls(chunk, controls)

print("\n%s" % ("ALLE %d PRUEFUNGEN GRUEN" % len(checks) if not bad else "%d FEHLER" % bad))
sys.exit(1 if bad else 0)
