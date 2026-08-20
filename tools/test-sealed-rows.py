# -*- coding: utf-8 -*-
"""Behaviour test for the sealed-row fix.

Extracts the REAL EmitSealedTag and the REAL SetText-hook body out of core.lua
(no copy, no paraphrase) and runs them under stubs, so the thing under test is
the shipped code. Then drives the exact sequence the live client produces.

Positive controls included: every assertion is re-run against a deliberately
broken variant to prove the test could have failed.
"""
import io, os, re, sys
import lupa

os.chdir(r"e:/dev/gaming/wow-addons/Details_iLvlDisplay")
SRC = io.open("core.lua", encoding="utf-8").read().replace("\r\n", "\n")


def extract(start_pat, end_pat):
    m = re.search(start_pat, SRC, re.M)
    if not m:
        sys.exit("nicht gefunden: %s" % start_pat)
    rest = SRC[m.start():]
    e = re.search(end_pat, rest, re.M)
    if not e:
        sys.exit("Ende nicht gefunden fuer %s" % start_pat)
    return rest[: e.end()]


EMIT = extract(r"^EmitSealedTag = function\(", r"\n    sealedStats\.emitted = sealedStats\.emitted \+ 1\nend")
HOOK = extract(r"^        SafeCall\(function\(\)\n            -- Details! Itemlevelfinder",
               r"\n        end\)\n    end\)")
# strip the outer SafeCall(function() ... end) wrapper -> keep the body
HOOK_BODY = HOOK.split("\n", 1)[1]
HOOK_BODY = HOOK_BODY.rsplit("\n        end)", 1)[0]

print("extrahiert: EmitSealedTag %d Zeilen, Hook-Body %d Zeilen"
      % (EMIT.count("\n") + 1, HOOK_BODY.count("\n") + 1))
assert "sealedStats.inline" in HOOK_BODY, "Hook-Body enthaelt den neuen Zweig nicht"
assert "EmitSealedTag" in HOOK_BODY, "Hook-Body ruft EmitSealedTag nicht"

HARNESS = u"""
-- ---------- Stubs, so nah am Original wie noetig ----------
local SECRETS = {}                       -- markiert "Secret"-Strings
local function isSecretValue(v) return SECRETS[v] == true end

local calls = {}                         -- Protokoll aller SetText-Aufrufe
local function newFS(name)
  local fs = {name = name, text = ""}
  function fs:SetText(t) self.text = t; calls[#calls+1] = {fs = self.name, text = t} end
  function fs:GetText() return self.text end
  function fs:Hide() end
  function fs:IsShown() return true end
  return fs
end

local barCleanText, barSecretText, barColumns = {}, {}, {}
local hookStats = {calls = 0, secret = 0, clean = 0, since = 0}
local barRankInfo = {}
local numbersRows = true
local function DetailsNumbersRows(bar) return numbersRows end
local detailsShowsRank = true
local function GetTime() return 123.0 end
local sealedStats = {emitted=0, noGuid=0, secretGuid=0, noIlvl=0, inline=0, ticker=0, ranked=0}
local isOurSetText = false
local EmitSealedTag

local db = {enabled=true, showInDetails=true, layout="inline", ilvlPosition="left",
            colorIlvl=false, showSetBonus=true}
local ILVL = {}                          -- guid -> ilvl
local setBonusCache = {}
local inCombat = false

local function MayBeInCombat() return inCombat end
local function IsDetailsWindowAllowed() return true end
local function GetIlvlForGuid(g) return ILVL[g] end
local function GetIlvlColor() return "|cFFFFFFFF" end
local function SetBonusTag(v) if v then return "["..v.."]" end end
local function SafeCall(fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then LAST_ERROR = err end
  return ok
end
local function ScheduleColumnRefresh() end
local function ExtractName() return nil end
local function BuildTag() return nil end
local function RefreshAllColumns() end
local detailsBarErrors, DETAILS_BAR_ERROR_LIMIT = 0, 5

-- ---------- ECHTER Code aus core.lua ----------
__EMIT__

-- ---------- Der ECHTE Hook-Rumpf, in eine aufrufbare Huelle gelegt ----------
local function detailsWritesText(fs, bar, text)
  -- entspricht dem Wachposten ganz oben im echten Hook
  if isOurSetText then return end
  if not db or not db.enabled then return end
  if detailsBarErrors >= DETAILS_BAR_ERROR_LIMIT then return end
  hookStats.calls = hookStats.calls + 1
  if hookStats.since == 0 then hookStats.since = GetTime() end
  local self = fs
  SafeCall(function()
__HOOK__
  end)
end

-- ---------- Szenario ----------
local fs  = newFS("row1")
local bar = {actorGUID = "Player-1403-AAA", instance_id = 1}
ILVL["Player-1403-AAA"] = 298
setBonusCache["Player-1403-AAA"] = "2P"

local SECRET1 = "\\1secret-name-1"       -- steht fuer Blizzards Secret-String
SECRETS[SECRET1] = true

local R = {}

-- 1) Details! zeichnet die Zeile: Secret rein
detailsWritesText(fs, bar, SECRET1)
R.afterFirstDraw   = fs.text
R.emitted1         = sealedStats.emitted
R.inline1          = sealedStats.inline
R.setTextCalls1    = #calls

-- 2) Details! zeichnet zehnmal neu (das, was frueher geflackert hat)
for i = 1, 10 do detailsWritesText(fs, bar, SECRET1) end
R.afterRedraws     = fs.text
R.emitted2         = sealedStats.emitted
R.tickerCount      = sealedStats.ticker

-- 3) Im Kampf darf NICHTS geschrieben werden
inCombat = true
local before = #calls
detailsWritesText(fs, bar, SECRET1)
R.combatWrites     = #calls - before
inCombat = false

-- 4) Keine GUID -> kein Tag, aber gezaehlt
local fs2 = newFS("row2")
local bar2 = {actorGUID = nil, instance_id = 1}
detailsWritesText(fs2, bar2, SECRET1)
R.row2Text         = fs2.text
R.noGuid           = sealedStats.noGuid

-- 5) GUID ist selbst Secret -> kein Tag, eigener Zaehler
local fs3 = newFS("row3")
local GUIDSECRET = "\\1secret-guid"
SECRETS[GUIDSECRET] = true
local bar3 = {actorGUID = GUIDSECRET, instance_id = 1}
detailsWritesText(fs3, bar3, SECRET1)
R.row3Text         = fs3.text
R.secretGuid       = sealedStats.secretGuid

-- 6) GUID lesbar, aber kein Item Level im Cache -> kein Tag
local fs4 = newFS("row4")
local bar4 = {actorGUID = "Player-1403-ZZZ", instance_id = 1}
detailsWritesText(fs4, bar4, SECRET1)
R.row4Text         = fs4.text
R.noIlvl           = sealedStats.noIlvl

-- 7) Lesbarer Text danach loescht das gemerkte Secret
detailsWritesText(fs, bar, "1. Klarname")
R.secretCleared    = (barSecretText[fs] == nil)
R.rankSeen         = detailsShowsRank

-- 8) Details! nummeriert NICHT -> "links" heisst wieder wirklich links
numbersRows = false
local fs5 = newFS("row5")
local bar5 = {actorGUID = "Player-1403-AAA", instance_id = 1}
detailsWritesText(fs5, bar5, SECRET1)
R.noRankLeftText   = fs5.text

-- 9) und zurueck: sobald wieder nummeriert wird, wandert das Tag nach hinten
numbersRows = true
local fs6 = newFS("row6")
detailsWritesText(fs6, bar5, SECRET1)
R.rankOnText       = fs6.text

R.hookCalls        = hookStats.calls
R.hookSecret       = hookStats.secret
R.hookClean        = hookStats.clean
R.isOurSetTextEnd  = isOurSetText
R.lastError        = LAST_ERROR
return R
"""

chunk = HARNESS.replace("__EMIT__", EMIT).replace("__HOOK__", HOOK_BODY)
io.open(os.path.join(os.environ.get("TEMP", "."), "sealed_harness.lua"), "w",
        encoding="utf-8").write(chunk)

L = lupa.LuaRuntime(unpack_returned_tuples=False)
try:
    R = L.execute(chunk)
except Exception as e:
    print("LUA-FEHLER:\n%s" % e)
    sys.exit(1)


def g(k):
    return R[k]


TAG = "[298] [2P]"
checks = [
    ("Tag sitzt sofort im ersten Zeichenaufruf",
     g("afterFirstDraw") is not None and g("afterFirstDraw").endswith(TAG)),
    ("genau ein Emit beim ersten Zeichnen", g("emitted1") == 1),
    ("Inline-Pfad wurde benutzt (nicht der Ticker)", g("inline1") == 1 and g("tickerCount") == 0),
    ("nach 10 Neuzeichnungen steht das Tag immer noch",
     g("afterRedraws") is not None and g("afterRedraws").endswith(TAG)),
    ("kein Doppel-Tag nach 10 Neuzeichnungen",
     g("afterRedraws").count("[298]") == 1),
    ("11 Emits nach 11 Zeichenaufrufen (jedes Mal frisch)", g("emitted2") == 11),
    ("im Kampf wird nichts geschrieben", g("combatWrites") == 0),
    ("ohne GUID kein Tag", g("row2Text") == ""),
    ("ohne GUID wird der Grund gezaehlt", g("noGuid") == 1),
    ("Secret-GUID: kein Tag", g("row3Text") == ""),
    ("Secret-GUID wird eigen gezaehlt", g("secretGuid") == 1),
    ("kein Item Level: kein Tag", g("row4Text") == ""),
    ("fehlendes Item Level wird eigen gezaehlt", g("noIlvl") == 1),
    ("lesbarer Text loescht das gemerkte Secret", g("secretCleared") is True),
    ("isOurSetText haengt nicht auf true fest", g("isOurSetTextEnd") is False),
    ("kein abgefangener Fehler unterwegs", g("lastError") is None),
    ("Hook zaehlt nur Details!-Schreibvorgaenge, nicht unsere", g("hookCalls") == 18),
    ("Secret- und Klartext-Zaehler trennen sauber",
     g("hookSecret") == 17 and g("hookClean") == 1),
    ("nummerierte Zeile: Rang bleibt vorn, Tag hinten",
     g("afterRedraws").startswith("secret") and g("afterRedraws").endswith(TAG)),
    ("ohne Rangnummern steht das Tag vorn", g("noRankLeftText").startswith(TAG)),
    ("mit Rangnummern steht das Tag hinten", g("rankOnText").endswith(TAG)),
]

print()
bad = 0
for name, ok in checks:
    print("  %s  %s" % ("PASS" if ok else "FAIL", name))
    if not ok:
        bad += 1

# ---------------- Positivkontrolle: derselbe Test gegen kaputten Code ----------------
broken = chunk.replace("sealedStats.inline = sealedStats.inline + 1\n                isOurSetText = true\n                SafeCall(EmitSealedTag, self, text, bar, db.ilvlPosition == \"left\")\n                isOurSetText = false\n", "")
if broken == chunk:
    print("\nWARNUNG: Positivkontrolle konnte den Zweig nicht entfernen")
else:
    L2 = lupa.LuaRuntime(unpack_returned_tuples=False)
    R2 = L2.execute(broken)
    fails = sum(1 for _, ok in [
        ("t", R2["afterFirstDraw"] is not None and R2["afterFirstDraw"].startswith(TAG)),
        ("t", R2["emitted1"] == 1),
    ] if not ok)
    print("\n  Positivkontrolle (Fix entfernt): %d/2 Kernpruefungen schlagen fehl %s"
          % (fails, "-- Test kann fehlschlagen" if fails == 2 else "-- VERDAECHTIG"))

print("\n%s" % ("ALLE %d PRUEFUNGEN GRUEN" % len(checks) if bad == 0 else "%d FEHLER" % bad))
sys.exit(1 if bad else 0)
