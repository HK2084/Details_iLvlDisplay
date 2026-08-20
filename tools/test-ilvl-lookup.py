# -*- coding: utf-8 -*-
"""Behaviour test for GetIlvlForGuid, the lookup both Details! render paths use.

Extracts the real function out of core.lua and drives it under stubs. The case
this exists for: an entry older than CACHE_REFRESH used to answer "nothing",
which made every tag vanish two hours after a raid while the Blizzard-meter path
-- reading the same table with no age filter -- kept showing all of them.

Positive controls at the bottom restore the old behaviour and must fail.
"""
import io, os, re, sys
import lupa

os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
SRC = io.open("core.lua", encoding="utf-8").read().replace("\r\n", "\n")

m = re.search(r"^local function GetIlvlForGuid\(guid\)", SRC, re.M)
if not m:
    sys.exit("GetIlvlForGuid nicht gefunden")
rest = SRC[m.start():]
e = re.search(r"\n    return cached and cached\.ilvl or nil\nend", rest)
if not e:
    sys.exit("Ende von GetIlvlForGuid nicht gefunden")
FN = rest[: e.end()]
assert "CACHE_REFRESH" in FN

HARNESS = u"""
local NOW = 1000000
local function time() return NOW end
local CACHE_REFRESH = 7200
local ilvlCache = {}
local PLAYER = "Player-SELF"
local function SafeUnitGUID(u) if u == "player" then return PLAYER end end
local selfIlvl = 288
local function GetAverageItemLevel() return selfIlvl, selfIlvl end
local function ResolveFullNameByGuid(g) return "Name-Realm" end

local poolData = nil
Details = {ilevel = {GetIlvl = function(_, guid) return poolData end}}

__FN__

local R = {}

-- frischer eigener Eintrag
ilvlCache["Player-A"] = {ilvl = 295, time = NOW - 60, source = "inspect"}
R.fresh = GetIlvlForGuid("Player-A")

-- abgelaufener Eintrag, Details! hat nichts -> trotzdem unser Wert
ilvlCache["Player-B"] = {ilvl = 281, time = NOW - 7250, source = "inspect"}
poolData = nil
R.staleNoPool = GetIlvlForGuid("Player-B")

-- abgelaufener Eintrag, Details! hat etwas FRISCHERES -> Details! gewinnt
ilvlCache["Player-C"] = {ilvl = 270, time = NOW - 7250, source = "inspect"}
poolData = {ilvl = 291, time = NOW - 100}
R.staleFreshPool = GetIlvlForGuid("Player-C")

-- abgelaufener Eintrag, Details! ebenfalls abgelaufen -> unser Wert
ilvlCache["Player-D"] = {ilvl = 266, time = NOW - 9000, source = "inspect"}
poolData = {ilvl = 999, time = NOW - 9000}
R.staleStalePool = GetIlvlForGuid("Player-D")

-- gar kein Eintrag, Details! auch nichts -> nichts
poolData = nil
R.unknown = GetIlvlForGuid("Player-E")

-- eigener Charakter kommt immer aus der Ausruestung
R.selfLookup = GetIlvlForGuid(PLAYER)

-- ohne GUID nichts
R.noGuid = GetIlvlForGuid(nil)

R.dPreserved = ilvlCache["Player-D"].ilvl
return R
"""

chunk = HARNESS.replace("__FN__", FN)
R = lupa.LuaRuntime(unpack_returned_tuples=False).execute(chunk)

checks = [
    ("frischer Eintrag wird geliefert", R["fresh"] == 295),
    ("abgelaufener Eintrag ohne bessere Quelle wird trotzdem geliefert",
     R["staleNoPool"] == 281),
    ("frischere Details!-Daten schlagen unseren alten Wert",
     R["staleFreshPool"] == 291),
    ("ebenfalls abgelaufene Details!-Daten aendern nichts",
     R["staleStalePool"] == 266),
    ("abgelaufene Details!-Daten ueberschreiben unseren Eintrag nicht",
     R["dPreserved"] == 266),
    ("unbekannte GUID liefert nichts", R["unknown"] is None),
    ("eigener Charakter kommt aus der Ausruestung", R["selfLookup"] == 288),
    ("ohne GUID nichts", R["noGuid"] is None),
]

print()
bad = 0
for n, ok in checks:
    print("  %s  %s" % ("PASS" if ok else "FAIL", n))
    bad += 0 if ok else 1

print()
controls = [
    ("alter Rueckfall entfernt (Zustand vor dem Fix)",
     chunk.replace("    return cached and cached.ilvl or nil\nend",
                   "    return nil\nend"),
     lambda r: r["staleNoPool"] == 281),
    ("Rueckfall im Details!-Zweig entfernt",
     chunk.replace("                return cached and cached.ilvl or nil\n            end",
                   "                return nil\n            end"),
     lambda r: r["staleStalePool"] == 266),
]
for name, broken, still_ok in controls:
    if broken == chunk:
        print("  WARN  Kontrolle '%s' konnte nichts entfernen" % name)
        continue
    try:
        held = still_ok(lupa.LuaRuntime(unpack_returned_tuples=False).execute(broken))
    except Exception:
        held = False
    print("  %s  Positivkontrolle: %s" % ("OK  " if not held else "VERDAECHTIG", name))

print("\n%s" % ("ALLE %d PRUEFUNGEN GRUEN" % len(checks) if not bad else "%d FEHLER" % bad))
sys.exit(1 if bad else 0)
