# -*- coding: utf-8 -*-
"""Behaviour test for the Blizzard-meter index join and its positive control.

Blizzard's session window refreshes only while damage events keep arriving
(DamageMeterSessionWindow.lua:193-208). After a kill the events stop, and every
row keeps the secret name and secret GUID it was filled with mid-fight until
something happens to refresh it -- which may be minutes later, or a /reload.
Live 20.08.2026: half the raid stood untagged after a boss died and filled in on
its own several minutes later, with nobody touching anything.

The addon reads the session fresh from C_DamageMeter itself, where names and
GUIDs ARE readable out of combat, and joins it to the rows by index. What that
join needs is proof the list has not been re-sorted since the rows were drawn:
rows whose owner Blizzard bound to the frame itself must land on the index they
claim. This drives the REAL BackfillIdentity extracted from blizzdm.lua.
"""
import io, os, re, sys
import lupa

os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
SRC = io.open("blizzdm.lua", encoding="utf-8").read().replace("\r\n", "\n")


def extract(name):
    m = re.search(r"^local function %s\([^)]*\)\n" % name, SRC, re.M)
    if not m:
        sys.exit("%s nicht gefunden" % name)
    rest = SRC[m.start():]
    e = re.search(r"\n^end$", rest, re.M)
    if not e:
        sys.exit("Ende von %s nicht gefunden" % name)
    return rest[: e.end()]


ELEMENT_DATA = extract("ElementDataOf")
BACKFILL = extract("BackfillIdentity")
assert "orderTrusted" in BACKFILL, "die Ordnungs-Kontrolle fehlt in BackfillIdentity"
assert "_dilvlGUIDBound" in BACKFILL, "der Provenienz-Merker fehlt in BackfillIdentity"

# SetFrameGUID kommt im Original aus einer frueheren Stelle der Datei.
m = re.search(r"^local function SetFrameGUID\(.*?\n^end$", SRC, re.M | re.S)
if not m:
    sys.exit("SetFrameGUID nicht gefunden")
SET_GUID = m.group(0)
assert "bound" in SET_GUID, "SetFrameGUID kennt keine Provenienz"

HARNESS = u"""
-- ---------------------------------------------------------------- Umgebung
local SECRET = setmetatable({}, {__tostring = function() return "(secret)" end})
local function isSecret(v) return v == SECRET end

local inCombat = false
local function IsGroupInCombat() return inCombat end

local PLAYER = "Player-Quinroth"
local function SafeUnitGUID(unit) if unit == "player" then return PLAYER end end

local function SafeBlizzCall(label, fn, ...) return fn(...) end

local identityBackfills = 0
local bfWhy = {
    direct = 0, combat = 0, noApi = 0, noSession = 0, secretSession = 0,
    noSources = 0, noIndex = 0, noSrc = 0, classSecret = 0, classDiff = 0,
    specDiff = 0, ambiguous = 0, guidNil = 0, guidSecret = 0,
}
local bfCtrl = {ok = 0, bad = 0, windows = 0, trusted = 0}

__SET_GUID__

-- Blizzards Fenster: ForEachEntryFrame + GetCombatSession, wie im Original.
local WINDOW, SOURCES
local DamageMeter = {}
function DamageMeter:ForEachSessionWindow(fn) fn(WINDOW) end

local function MakeWindow(frames, sources)
    SOURCES = sources
    return {
        ForEachEntryFrame = function(self, fn)
            for _, f in ipairs(frames) do fn(f) end
        end,
        GetCombatSession = function(self)
            return {combatSources = SOURCES}
        end,
        IsEditing = function(self) return false end,
    }
end

__ELEMENT_DATA__

__BACKFILL__

-- ---------------------------------------------------------------- Faelle
-- Eine Reihe, wie Blizzard sie nach dem Kampf hinterlaesst: Name geheim, keine
-- Identitaet, aber classFilename/specIconID bleiben lesbar (NeverSecret).
local function Row(index, class, spec, opts)
    opts = opts or {}
    local f = {
        index = index,
        classFilename = class,
        specIconID = spec,
        sourceName = opts.name or SECRET,
        isLocalPlayer = opts.isLocalPlayer or false,
        value = opts.value,
    }
    if opts.boundGuid then
        SetFrameGUID(f, opts.boundGuid, true, opts.owner, true)
    end
    if opts.elementData then
        f.GetElementData = function() return opts.elementData end
    end
    return f
end

local function Source(guid, class, spec, opts)
    opts = opts or {}
    return {
        sourceGUID = guid, classFilename = class, specIconID = spec,
        name = opts.name, isLocalPlayer = opts.isLocalPlayer or false,
        totalAmount = opts.totalAmount,
    }
end

local R = {}
local function run(frames, sources, combat)
    inCombat = combat or false
    bfCtrl.ok, bfCtrl.bad, bfCtrl.windows, bfCtrl.trusted = 0, 0, 0, 0
    WINDOW = MakeWindow(frames, sources)
    BackfillIdentity()
    inCombat = false
    local out = {}
    for i, f in ipairs(frames) do out[i] = f._dilvlGUID or "-" end
    return table.concat(out, ","), bfCtrl.trusted, bfCtrl.ok, bfCtrl.bad
end

-- Der Live-Fall: vier Jaeger derselben Spezialisierung, Schadenszahlen geheim.
-- Ohne bewiesene Reihenfolge kommt hier kein einziger durch.
local function raid(shift, opts)
    opts = opts or {}
    local frames = {
        Row(1, "HUNTER", 11, {isLocalPlayer = true}),
        Row(2, "HUNTER", 11, {boundGuid = opts.boundWrong or "G2"}),
        Row(3, "HUNTER", 11),
        Row(4, "HUNTER", 11),
    }
    local sources = {
        Source(PLAYER, "HUNTER", 11), Source("G2", "HUNTER", 11),
        Source("G3", "HUNTER", 11),   Source("G4", "HUNTER", 11),
    }
    if shift then table.insert(sources, 1, Source("GX", "HUNTER", 11)) end
    if opts.stripBound then frames[2] = Row(2, "HUNTER", 11) end
    if opts.stripPlayer then frames[1] = Row(1, "HUNTER", 11) end
    return frames, sources
end

R.trusted        = {run(raid(false))}
R.reordered      = {run(raid(true))}
R.noControl      = {run(raid(false, {stripBound = true, stripPlayer = true}))}
R.playerOnly     = {run(raid(false, {stripBound = true}))}
R.inCombat       = {run(raid(false), nil, true)}

-- Ein Bound-Treffer stimmt, einer nicht: ein einziger Fehlschlag schliesst das
-- ganze Fenster, auch wenn die Mehrheit passt.
do
    local frames = {
        Row(1, "HUNTER", 11, {isLocalPlayer = true}),
        Row(2, "HUNTER", 11, {boundGuid = "FALSCH"}),
        Row(3, "HUNTER", 11),
    }
    local sources = {Source(PLAYER, "HUNTER", 11), Source("G2", "HUNTER", 11),
                     Source("G3", "HUNTER", 11)}
    R.oneMismatch = {run(frames, sources)}
end

-- Klasse/Spezialisierung widersprechen: die Reihenfolge mag bewiesen sein, die
-- Reihe selbst passt nicht zu ihrer Quelle.
do
    local frames = {
        Row(1, "HUNTER", 11, {isLocalPlayer = true}),
        Row(2, "MAGE", 62),
    }
    local sources = {Source(PLAYER, "HUNTER", 11), Source("G2", "PRIEST", 258)}
    R.classDiff = {run(frames, sources)}
end

-- Zwei Reihen, eine Quelle: der Zweite darf den Spieler nicht auch bekommen.
do
    local frames = {
        Row(1, "HUNTER", 11, {isLocalPlayer = true}),
        Row(2, "HUNTER", 11), Row(2, "HUNTER", 11),
    }
    local sources = {Source(PLAYER, "HUNTER", 11), Source("G2", "HUNTER", 11)}
    R.doubleClaim = {run(frames, sources)}
end

-- Der frische Lesevorgang liefert selbst noch Geheimnisse.
do
    local frames = {Row(1, "HUNTER", 11, {isLocalPlayer = true}),
                    Row(2, "HUNTER", 11)}
    local sources = {Source(PLAYER, "HUNTER", 11), Source(SECRET, "HUNTER", 11)}
    R.secretGuid = {run(frames, sources)}
end

-- Der direkte Weg schlaegt alles: GetElementData bindet die Reihe an ihr
-- Element, unabhaengig von jeder Sortierung.
do
    local ed = {sourceGUID = "GD", classFilename = "HUNTER", specIconID = 11}
    local frames = {Row(9, "HUNTER", 11, {elementData = ed})}
    R.direct = {run(frames, {})}
end

-- Zwei Laeufe hintereinander auf denselben Reihen. Im ersten lizenziert der
-- eigene Charakter das Fenster und zwei Reihen bekommen ihre Identitaet aus dem
-- Index. Im zweiten ist die Kontrolle weg -- und die abgeleiteten Identitaeten
-- duerfen sich nicht selbst die Erlaubnis ausstellen, aus der sie entstanden
-- sind. Genau daran haengt der Unterschied zwischen _dilvlGUIDBound und
-- _dilvlGUIDFromAPI.
do
    local p1 = Row(1, "HUNTER", 11, {isLocalPlayer = true})
    local r2 = Row(2, "HUNTER", 11)
    local r3 = Row(3, "HUNTER", 11)
    local r4 = Row(4, "HUNTER", 11)
    local sources = {Source(PLAYER, "HUNTER", 11), Source("G2", "HUNTER", 11),
                     Source("G3", "HUNTER", 11),   Source("G4", "HUNTER", 11)}
    R.lauf1 = {run({p1, r2, r3}, sources)}
    R.selfLicense = {run({r2, r3, r4}, sources)}
end

R.backfills = identityBackfills
return R
"""

chunk = (HARNESS
         .replace("__SET_GUID__", SET_GUID)
         .replace("__ELEMENT_DATA__", ELEMENT_DATA)
         .replace("__BACKFILL__", BACKFILL))

R = lupa.LuaRuntime(unpack_returned_tuples=False).execute(chunk)


def guids(key):
    return R[key][1]


def lic(key):
    return R[key][2]


checks = [
    ("bewiesene Reihenfolge loest alle vier Jaeger auf",
     guids("trusted") == "Player-Quinroth,G2,G3,G4"),
    ("dabei ist genau ein Fenster lizenziert", lic("trusted") == 1),
    ("umsortierte Liste loest nichts auf", guids("reordered") == "-,G2,-,-"),
    ("und lizenziert kein Fenster", lic("reordered") == 0),
    ("ohne jede Kontrolle wird nichts aufgeloest",
     guids("noControl") == "-,-,-,-" and lic("noControl") == 0),
    ("der eigene Charakter allein reicht als Kontrolle",
     guids("playerOnly") == "Player-Quinroth,G2,G3,G4" and lic("playerOnly") == 1),
    ("im Kampf laeuft der Abgleich gar nicht erst",
     guids("inCombat") == "-,G2,-,-"),
    ("eine einzige Abweichung schliesst das ganze Fenster",
     guids("oneMismatch") == "-,FALSCH,-" and lic("oneMismatch") == 0),
    ("widersprechende Klasse blockt die Reihe trotz Lizenz",
     guids("classDiff") == "Player-Quinroth,-" and lic("classDiff") == 1),
    # Welche der beiden Reihen den Zuschlag bekommt, legt die Reihenfolge des
    # Fixpunkts fest und ist nicht die Zusage. Die Zusage ist: genau eine.
    ("zwei Reihen bekommen nicht denselben Spieler",
     guids("doubleClaim").split(",").count("G2") == 1
     and guids("doubleClaim").startswith("Player-Quinroth,")),
    ("geheime GUID in der frischen Liste wird nicht verwendet",
     guids("secretGuid") == "Player-Quinroth,-"),
    ("der direkte Weg braucht weder Index noch Lizenz",
     guids("direct") == "GD"),
    ("erster Lauf loest per Index auf",
     guids("lauf1") == "Player-Quinroth,G2,G3"),
    ("abgeleitete Identitaet lizenziert sich nicht selbst",
     guids("selfLicense") == "G2,G3,-" and lic("selfLicense") == 0),
]

print()
bad = 0
for n, ok in checks:
    print("  %s  %s" % ("PASS" if ok else "FAIL", n))
    bad += 0 if ok else 1

print()
controls = [
    ("Lizenz-Bedingung entfernt (jede Reihenfolge gilt als bewiesen)",
     chunk.replace("local orderTrusted = (ctrlBad == 0 and ctrlOk > 0)",
                   "local orderTrusted = true"),
     lambda r: r["reordered"][1] == "-,G2,-,-" and r["noControl"][1] == "-,-,-,-"),
    ("Klassen-Vergleich entfernt",
     chunk.replace('elseif class ~= fClass then\n                            why = "classDiff"',
                   'elseif false then\n                            why = "classDiff"'),
     lambda r: r["classDiff"][1] == "-,-"),
    ("Doppelvergabe-Sperre entfernt",
     chunk.replace("if not decided and orderTrusted and not claimed[guid] then",
                   "if not decided and orderTrusted then"),
     lambda r: r["doubleClaim"][1] == "-,G2,-"),
    ("Provenienz ignoriert (abgeleitete Identitaet dient als Kontrolle)",
     chunk.replace("elseif frame._dilvlGUIDBound then",
                   "elseif frame._dilvlGUID then"),
     lambda r: r["selfLicense"][1] == "G2,G3,-"),
]
for name, broken, still_ok in controls:
    if broken == chunk:
        print("  WARN  Kontrolle '%s' konnte nichts entfernen" % name)
        bad += 1
        continue
    try:
        held = still_ok(lupa.LuaRuntime(unpack_returned_tuples=False).execute(broken))
    except Exception:
        held = False
    print("  %s  Positivkontrolle: %s" % ("OK  " if not held else "VERDAECHTIG", name))
    if held:
        bad += 1

print("\n%s" % ("ALLE %d PRUEFUNGEN GRUEN" % len(checks) if not bad else "%d FEHLER" % bad))
sys.exit(1 if bad else 0)
