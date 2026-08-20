# -*- coding: utf-8 -*-
"""Behaviour test for true "left" placement.

Extracts the REAL TagRankedRow, EmitSealedTag and DetailsNumbersRows out of
core.lua and drives them under stubs that mimic Details! and Blizzard's secret
rules. Positive controls prove each assertion can fail.
"""
import io, os, re, sys
import lupa

os.chdir(r"e:/dev/gaming/wow-addons/Details_iLvlDisplay")
SRC = io.open("core.lua", encoding="utf-8").read().replace("\r\n", "\n")


def grab(start, end):
    m = re.search(start, SRC, re.M)
    if not m:
        sys.exit("nicht gefunden: " + start)
    rest = SRC[m.start():]
    e = re.search(end, rest, re.M)
    if not e:
        sys.exit("Ende fehlt fuer " + start)
    return rest[: e.end()]


NUMBERS = grab(r"^local function DetailsNumbersRows\(bar\)", r"\n    return detailsShowsRank\nend")
EMIT = grab(r"^EmitSealedTag = function\(", r"\n    sealedStats\.emitted = sealedStats\.emitted \+ 1\nend")
RANKED = grab(r"^local function TagRankedRowBody\(", r"\n    sealedStats\.ranked = sealedStats\.ranked \+ 1\nend")

for nm, blob, must in (("DetailsNumbersRows", NUMBERS, "textL_show_number"),
                       ("EmitSealedTag", EMIT, "barRankInfo"),
                       ("TagRankedRow", RANKED, "ShortenForDisplay")):
    assert must in blob, "%s enthaelt %s nicht" % (nm, must)
print("extrahiert: %d + %d + %d Zeilen"
      % (NUMBERS.count("\n"), EMIT.count("\n"), RANKED.count("\n")))

HARNESS = u"""
local SECRETS = {}
local function isSecretValue(v) return SECRETS[v] == true end
local function mark(s) SECRETS[s] = true; return s end

local writes = {}
local function newFS(n)
  local fs = {name = n, text = ""}
  function fs:SetText(t) self.text = t; writes[#writes+1] = t end
  function fs:IsShown() return true end
  return fs
end

local barRankInfo, hookedFontStrings, setBonusCache = {}, {}, {}
local sealedStats = {emitted=0, noGuid=0, secretGuid=0, noIlvl=0, inline=0, ticker=0, ranked=0}
local isOurSetText = false
local detailsShowsRank = true
local ILVL = {}
local numbersRows = true          -- was Details! meldet
local inCombat = false

local db = {enabled=true, showInDetails=true, layout="inline", ilvlPosition="left",
            colorIlvl=false, showSetBonus=true}

Details = {}
function Details.GetInstance(_, id) return {row_info = {textL_show_number = numbersRows}} end

-- Details! deklariert den Renderer mit Doppelpunkt und ruft ihn so auf. Der
-- Test MUSS denselben Weg gehen: der Fehler vom 20.08. bestand genau darin,
-- dass der Handler direkt aufgerufen wurde und das implizite self fehlte.
local drawn = {}
function Details:UpdateBarApocalypseWow(instanceLine, source, ...)
  -- Rang wie im Original zuletzt, damit auch die aeltere 5-Argument-Signatur
  -- durchlaeuft (dort gab es totalValue noch nicht).
  local n = select("#", ...)
  local rank = n > 0 and select(n, ...) or nil
  drawn[#drawn+1] = rank
  if instanceLine and instanceLine.lineText1 and type(rank) == "number" then
    instanceLine.lineText1:SetText(string.format("%d. %s", rank, source.name))
  end
end

local hooks = {}
function hooksecurefunc(tbl, name, fn)
  local orig = tbl[name]
  hooks[name] = fn
  tbl[name] = function(...) orig(...) return fn(...) end
end

Ambiguate = function(name, ctx)
  -- Blizzards Semantik: "short" schneidet den Realm ab, Secret bleibt Secret
  if ctx ~= "short" then return name end
  local out = name:gsub("%-.*$", "")
  if SECRETS[name] then SECRETS[out] = true end
  return out
end
local function ShortenForDisplay(name)
  if name == nil then return nil end
  local ok, short = pcall(Ambiguate, name, "short")
  if ok and short ~= nil then return short end
  return name
end

local function MayBeInCombat() return inCombat end
local function IsDetailsWindowAllowed() return true end
local function GetIlvlForGuid(g) return ILVL[g] end
local function GetIlvlColor() return "|cFFFFFFFF" end
local function SetBonusTag(v) if v then return "["..v.."]" end end
local nameToIlvl = {}
local function RefreshAllBarTexts() end

__NUMBERS__
__EMIT__
__RANKED__

-- Die ausgelieferte Huelle, nachgebaut: SafeCall plus Flag-Ruecksetzung. Der
-- Test MUSS ueber sie laufen, denn hooksecurefunc ruft genau diese auf.
local function SafeCall(fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then LAST_ERROR = err end
  return ok
end
TagRankedRow = function(_, instanceLine, source, ...)
  SafeCall(TagRankedRowBody, instanceLine, source, ...)
  isOurSetText = false
end

-- ---------------- Szenario ----------------
local R = {}
local fs = newFS("row1")
hookedFontStrings[fs] = true
local line = {lineText1 = fs, instance_id = 1, actorGUID = "Player-AAA"}
ILVL["Player-AAA"] = 298
setBonusCache["Player-AAA"] = "2P"

local SEALED = mark("Littlemaxxis-Blackrock")
local source = {name = SEALED, specIconID = 12345}

-- 1) Details! zeichnet: 6 Argumente, Rang zuletzt
hooksecurefunc(Details, "UpdateBarApocalypseWow", TagRankedRow)
Details:UpdateBarApocalypseWow(line, source, {}, 100, 50, 3)
R.text6      = fs.text
R.ranked     = sealedStats.ranked
R.stored     = barRankInfo[fs] ~= nil
R.storedRank = barRankInfo[fs] and barRankInfo[fs].rank

-- 2) Alte Signatur mit 5 Argumenten: Rang immer noch zuletzt
local fs2 = newFS("row2"); hookedFontStrings[fs2] = true
local line2 = {lineText1 = fs2, instance_id = 1, actorGUID = "Player-AAA"}
Details:UpdateBarApocalypseWow(line2, source, {}, 100, 7)
R.text5 = fs2.text

-- 3) Kaputte Signatur: letztes Argument ist keine Zahl -> nichts schreiben
local fs3 = newFS("row3"); hookedFontStrings[fs3] = true
local line3 = {lineText1 = fs3, instance_id = 1, actorGUID = "Player-AAA"}
Details:UpdateBarApocalypseWow(line3, source, {}, 100, 50, "kaputt")
R.textBroken = fs3.text

-- 4) Lesbarer Name wird in Ruhe gelassen
local fs4 = newFS("row4"); hookedFontStrings[fs4] = true
local line4 = {lineText1 = fs4, instance_id = 1, actorGUID = "Player-AAA"}
Details:UpdateBarApocalypseWow(line4, {name = "Klarname", specIconID = 1}, {}, 100, 50, 4)
R.textClean = fs4.text

-- 5) Im Kampf: nichts
inCombat = true
local before = #writes
Details:UpdateBarApocalypseWow(line, source, {}, 100, 50, 3)
R.combatWrites = #writes - before
inCombat = false

-- 6) Der 2s-Ticker reproduziert dieselbe Anordnung aus barRankInfo
fs.text = ""
EmitSealedTag(fs, SEALED, line, true)
R.tickerText = fs.text

-- 7) Ohne Aufzeichnung faellt der Ticker auf die Suffix-Form zurueck
local fs5 = newFS("row5")
local line5 = {lineText1 = fs5, instance_id = 1, actorGUID = "Player-AAA"}
EmitSealedTag(fs5, SEALED, line5, true)
R.fallbackText = fs5.text

-- 8) Details! ohne Rangnummern -> "links" heisst wieder woertlich links
numbersRows = false
local fs6 = newFS("row6"); hookedFontStrings[fs6] = true
local line6 = {lineText1 = fs6, instance_id = 1, actorGUID = "Player-AAA"}
Details:UpdateBarApocalypseWow(line6, source, {}, 100, 50, 2)
R.noRankText = fs6.text
numbersRows = true

-- 9) Ohne Cache-Eintrag kein Tag
local fs7 = newFS("row7"); hookedFontStrings[fs7] = true
local line7 = {lineText1 = fs7, instance_id = 1, actorGUID = "Player-ZZZ"}
Details:UpdateBarApocalypseWow(line7, source, {}, 100, 50, 5)
R.noIlvlText = fs7.text

-- 10) Position "rechts": dieser Pfad haelt sich raus
db.ilvlPosition = "right"
local fs8 = newFS("row8"); hookedFontStrings[fs8] = true
local line8 = {lineText1 = fs8, instance_id = 1, actorGUID = "Player-AAA"}
Details:UpdateBarApocalypseWow(line8, source, {}, 100, 50, 6)
R.rightText = fs8.text
db.ilvlPosition = "left"

-- 11) Die Zeile wird an einen anderen Spieler weitergereicht. Details! blankt
-- dabei nichts, also ueberlebt die Aufzeichnung des Vorgaengers. Der Ticker
-- darf dessen Namen NICHT neben das Item Level des Neuen setzen.
local fs9 = newFS("row9"); hookedFontStrings[fs9] = true
local line9 = {lineText1 = fs9, instance_id = 1, actorGUID = "Player-AAA"}
Details:UpdateBarApocalypseWow(line9, source, {}, 100, 50, 4)
R.beforeHandover = fs9.text
ILVL["Player-BBB"] = 250
setBonusCache["Player-BBB"] = nil
line9.actorGUID = "Player-BBB"          -- neue Belegung, Aufzeichnung veraltet
fs9.text = ""
-- Details! haette laengst den Text des NEUEN Spielers geschrieben; genau den
-- bekommt der Ticker als Secret zu sehen.
local SEALED2 = mark("Neuling-Kazzak")
EmitSealedTag(fs9, SEALED2, line9, true)
R.afterHandover = fs9.text

R.ourFlag = isOurSetText
return R
"""

chunk = (HARNESS.replace("__NUMBERS__", NUMBERS)
                .replace("__EMIT__", EMIT)
                .replace("__RANKED__", RANKED))

L = lupa.LuaRuntime(unpack_returned_tuples=False)
try:
    R = L.execute(chunk)
except Exception as e:
    print("LUA-FEHLER:\n%s" % e); sys.exit(1)

TAG = "[298] [2P]"
checks = [
    ("Rang, Tag, Name - genau die gewuenschte Reihenfolge",
     R["text6"] == "3. " + TAG + " Littlemaxxis"),
    ("Realm entfernt wie bei Details!", "Blackrock" not in (R["text6"] or "")),
    ("als Rang-Platzierung gezaehlt", R["ranked"] == 1),
    ("Rang und Name fuer den Ticker gemerkt", R["stored"] is True and R["storedRank"] == 3),
    ("aeltere Signatur mit 5 Argumenten funktioniert auch",
     R["text5"] == "7. " + TAG + " Littlemaxxis"),
    ("unbekannte Signatur laesst Details!-Text stehen",
     R["textBroken"] == "kaputt. Littlemaxxis-Blackrock" or "[298]" not in (R["textBroken"] or "")),
    ("lesbare Zeile bleibt Details!-Text", "[298]" not in (R["textClean"] or "")),
    ("im Kampf schreibt nur Details! selbst, nicht wir", R["combatWrites"] == 1),
    ("Ticker reproduziert dieselbe Anordnung",
     R["tickerText"] == "3. " + TAG + " Littlemaxxis"),
    ("ohne Aufzeichnung faellt der Ticker auf Suffix zurueck",
     R["fallbackText"] is not None and R["fallbackText"].endswith(TAG)
     and R["fallbackText"].startswith("Littlemaxxis")),
    ("ohne Rangnummern steht das Tag ganz vorn",
     R["noRankText"] == TAG + " Littlemaxxis"),
    ("ohne Item Level kein Tag", "[" not in (R["noIlvlText"] or "").replace("5. ", "")),
    ("bei Position rechts haelt sich der Pfad raus", "[298]" not in (R["rightText"] or "")),
    ("isOurSetText haengt nicht fest", R["ourFlag"] is False),
    ("vor der Weitergabe steht der richtige Name",
     R["beforeHandover"] == "4. " + TAG + " Littlemaxxis"),
    ("nach der Weitergabe wird die alte Aufzeichnung verworfen",
     "Littlemaxxis" not in (R["afterHandover"] or "") and "Neuling" in (R["afterHandover"] or "")),
]

print()
bad = 0
for n, ok in checks:
    print("  %s  %s" % ("PASS" if ok else "FAIL", n))
    if not ok:
        bad += 1

# ---- Positivkontrollen: jede muss den Test umwerfen ----
print()
controls = [
    ("Rang aus fester Position statt vom Ende",
     chunk.replace("local rank = n > 0 and select(n, ...) or nil",
                   "local rank = select(3, ...)"),
     lambda r: r["text6"] == "3. " + TAG + " Littlemaxxis"),
    ("Realm-Kuerzung entfernt",
     chunk.replace("name = ShortenForDisplay(name)", "name = name"),
     lambda r: "Blackrock" not in (r["text6"] or "")),
    ("Identitaetspruefung entfernt (Name des Vorgaengers)",
     chunk.replace("if info and info.guid ~= guid then info = nil end", ""),
     lambda r: "Littlemaxxis" not in (r["afterHandover"] or "")),
    ("self-Argument weggelassen (der Fehler vom 20.08.)",
     chunk.replace("TagRankedRow = function(_, instanceLine, source, ...)",
                   "TagRankedRow = function(instanceLine, source, ...)"),
     lambda r: r["text6"] == "3. " + TAG + " Littlemaxxis"),
    ("Aufzeichnung fuer den Ticker entfernt",
     chunk.replace("barRankInfo[fontString] = {rank = rank, name = name, numbered = numbered, guid = guid}", ""),
     lambda r: r["tickerText"] == "3. " + TAG + " Littlemaxxis"),
]
for name, broken, still_ok in controls:
    if broken == chunk:
        print("  WARN  Kontrolle '%s' konnte nichts entfernen" % name); continue
    try:
        r2 = lupa.LuaRuntime(unpack_returned_tuples=False).execute(broken)
        held = still_ok(r2)
    except Exception:
        held = False
    print("  %s  Positivkontrolle: %s" % ("OK  " if not held else "VERDAECHTIG", name))

print("\n%s" % ("ALLE %d PRUEFUNGEN GRUEN" % len(checks) if bad == 0 else "%d FEHLER" % bad))
sys.exit(1 if bad else 0)
