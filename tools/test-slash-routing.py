# -*- coding: utf-8 -*-
"""Behaviour test for the slash-command routing wrapper.

The slash branches set db directly and refresh only the Details! side. The
router is what tells the other renderers a setting moved, and the slash path
never reached it -- so `/dilvl off` left every tag standing on Blizzard's meter
while the same toggle in the options panel cleaned up. Reported live 20.08.2026.

The wrapper snapshots the routed keys, runs the command, and forwards whatever
changed. This drives the REAL wrapper extracted from core.lua.
"""
import io, os, re, sys
import lupa
from control_harness import run_controls

os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
SRC = io.open("core.lua", encoding="utf-8").read().replace("\r\n", "\n")

m = re.search(r"^local ROUTED_KEYS = \{", SRC, re.M)
if not m:
    sys.exit("ROUTED_KEYS nicht gefunden")
rest = SRC[m.start():]
e = re.search(r"\n            ns\.ApplySettingChangeSafe\(k\)\n        end\n    end\nend", rest)
if not e:
    sys.exit("Ende des Wrappers nicht gefunden")
WRAPPER = rest[: e.end()]
assert "SlashCmdList" in WRAPPER and "ROUTED_KEYS" in WRAPPER

HARNESS = u"""
local db = {enabled = true, colorIlvl = true, layout = "inline",
            ilvlPosition = "left", blizzDM = nil, dandersText = true}
local forwarded = {}
local ns = {ApplySettingChangeSafe = function(k) forwarded[#forwarded+1] = k end}
SlashCmdList = {}

local pending
local function SlashBody(msg) if pending then pending(db) end end

__WRAPPER__

local R = {}
local function run(mutate)
  forwarded = {}
  pending = mutate
  SlashCmdList["DILVL"]("egal")
  pending = nil
  table.sort(forwarded)
  return table.concat(forwarded, ",")
end

R.nothing   = run(nil)
R.offCmd    = run(function(d) d.enabled = false end)
R.onCmd     = run(function(d) d.enabled = true end)
-- Der Fall, an dem eine naive Pruefung scheitert: nil ist ein eigener Zustand
R.blizzNil  = run(function(d) d.blizzDM = false end)
R.blizzBack = run(function(d) d.blizzDM = nil end)
R.twoKeys   = run(function(d) d.layout = "columns" d.ilvlPosition = "right" end)
R.sameValue = run(function(d) d.colorIlvl = true end)
R.unrouted  = run(function(d) d.somethingElse = 42 end)
return R
"""

chunk = HARNESS.replace("__WRAPPER__", WRAPPER)
R = lupa.LuaRuntime(unpack_returned_tuples=False).execute(chunk)

checks = [
    ("ohne Aenderung wird nichts weitergereicht", R["nothing"] == ""),
    ("/dilvl off reicht 'enabled' weiter", R["offCmd"] == "enabled"),
    ("/dilvl on reicht 'enabled' weiter", R["onCmd"] == "enabled"),
    ("nil -> false wird als Aenderung erkannt", R["blizzNil"] == "blizzDM"),
    ("false -> nil wird als Aenderung erkannt", R["blizzBack"] == "blizzDM"),
    ("zwei geaenderte Schluessel, zwei Weiterleitungen",
     R["twoKeys"] == "ilvlPosition,layout"),
    ("gleicher Wert loest nichts aus", R["sameValue"] == ""),
    ("ein Schluessel ausserhalb der Liste loest nichts aus", R["unrouted"] == ""),
]

print()
bad = 0
for n, ok in checks:
    print("  %s  %s" % ("PASS" if ok else "FAIL", n))
    bad += 0 if ok else 1

print()
controls = [
    ("Schnappschuss entfernt (alles gilt als unveraendert)",
     chunk.replace("before[k] = db[k]", "before[k] = nil"),
     lambda r: r["sameValue"] == "" and r["nothing"] == ""),
    ("Weiterleitung ganz entfernt",
     chunk.replace("ns.ApplySettingChangeSafe(k)", ""),
     lambda r: r["offCmd"] == "enabled"),
]
bad += run_controls(chunk, controls)

print("\n%s" % ("ALLE %d PRUEFUNGEN GRUEN" % len(checks) if not bad else "%d FEHLER" % bad))
sys.exit(1 if bad else 0)
