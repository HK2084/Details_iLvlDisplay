# -*- coding: utf-8 -*-
"""Behaviour test for the Blizzard-meter index join and its positive control.

Blizzard's session window refreshes only while damage events keep arriving
(DamageMeterSessionWindow.lua:193-208). After a kill the events stop, and every
row keeps the secret name and secret GUID it was filled with mid-fight until
something happens to refresh it -- which may be minutes later, or a /reload.
Live 20.08.2026: half the raid stood untagged after a boss died and filled in on
its own several minutes later, with nobody touching anything.

The addon reads the finished session back from C_DamageMeter itself, where names
and GUIDs ARE readable out of combat, and joins it to the rows by index. What
that join needs is proof the list has not been re-sorted since the rows were
drawn. Two things supply it, and the difference between them is the point of
this suite:

  * a WINDOW-wide licence -- verified rows land on the index they claim, and no
    class disagrees with its source anywhere
  * a PER-GROUP pin -- every other source sharing this class and spec sits on an
    index a verified witness confirmed

The licence alone is not enough, and that was a real defect rather than a
theoretical one: a swap of two players who share class AND spec emits neither
signal, so one unmoved witness would have licensed two dozen rows and written
another player's name and item level onto one of them.

This drives the REAL BackfillIdentity extracted from blizzdm.lua.
"""
import io, os, re, sys
import lupa
from control_harness import run_controls

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

_m = re.search(
    r"^local refreshRequested = setmetatable.*?"
    r"^local function RequestFreshElementData\(sw\)\n.*?^end$",
    SRC, re.M | re.S)
if not _m:
    sys.exit("Refresh-Anforderung nicht gefunden")
REFRESH_REQ = _m.group(0)

BACKFILL = extract("BackfillIdentity")
for needle, why in [
    ("orderTrusted", "die Ordnungs-Kontrolle"),
    ("_dilvlGUIDBound", "der Provenienz-Merker"),
    ("ctrlComplete", "die Abbruch-Erkennung der Kontrolle"),
    ("pinnedInKey", "die Gruppen-Fixierung"),
    ("GetLocalPlayerEntry", "die angeheftete Eigen-Zeile als Zeuge"),
    ("RequestFreshElementData", "die Anforderung eines frischen Lesevorgangs"),
]:
    if needle not in BACKFILL:
        sys.exit("%s fehlt in BackfillIdentity" % why)

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

-- pcall like the original: a throw inside must be CONTAINED, not propagated,
-- otherwise the test cannot see what the addon does after one.
local function SafeBlizzCall(label, fn, ...)
    local ok, a, b, c = pcall(fn, ...)
    if ok then return a, b, c end
    return nil
end

local identityBackfills = 0
local bfWhy = {
    direct = 0, combat = 0, noApi = 0, noSession = 0, secretSession = 0,
    noSources = 0, noIndex = 0, noSrc = 0, classSecret = 0, classDiff = 0,
    specDiff = 0, ambiguous = 0, noLicence = 0, guidNil = 0, guidSecret = 0,
}
local bfCtrl = {ok = 0, bad = 0, classBad = 0, windows = 0, trusted = 0}

__SET_GUID__

local WINDOW, SOURCES
local DamageMeter = {}
function DamageMeter:ForEachSessionWindow(fn) fn(WINDOW) end

-- throwAt: raise inside the row walk once that many rows have been handed out,
-- to model a Blizzard API that fails part way through.
-- sticky: a local-player entry that lives OUTSIDE the ScrollBox, exactly as
-- Blizzard pins it (MinimizeContainer.LocalPlayerEntry).
REFRESH_CALLS = 0
local function MakeWindow(frames, sources, throwAt, sticky, editing, elements)
    SOURCES = sources
    local w
    w = {
        IsEditing = function(self) return editing == true end,
        -- Was Blizzards Refresh tut, auf das Wesentliche eingedampft: die
        -- Element-Tabellen behalten ihre Identitaet und bekommen frische Werte.
        Refresh = elements and function(self)
            REFRESH_CALLS = REFRESH_CALLS + 1
            for i, e in pairs(elements) do
                local s = sources[i]
                if s then e.sourceGUID = s.sourceGUID end
            end
        end or nil,
        ForEachEntryFrame = function(self, fn)
            for i, f in ipairs(frames) do
                if throwAt and i > throwAt then error("blizzard blew up") end
                fn(f)
            end
        end,
        GetLocalPlayerEntry = function(self) return sticky end,
        GetCombatSession = function(self)
            return {combatSources = SOURCES}
        end,
    }
    return w
end

-- ---------------------------------------------------------------- Faelle
-- A row as Blizzard leaves it after a fight: name sealed, no identity, but
-- classFilename/specIconID still readable (both NeverSecret).
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
    if opts.inferredGuid then
        -- fromAPI, but NOT bound: this is what the index join itself produces.
        SetFrameGUID(f, opts.inferredGuid, true, opts.owner, nil)
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

__ELEMENT_DATA__

__REFRESH_REQ__

__BACKFILL__

local R = {}
local function run(frames, sources, opts)
    opts = opts or {}
    inCombat = opts.combat or false
    bfCtrl.ok, bfCtrl.bad, bfCtrl.classBad = 0, 0, 0
    bfCtrl.windows, bfCtrl.trusted = 0, 0
    if opts.armRefresh then ClearRefreshRequests() end
    -- Die Sperre haengt an der IDENTITAET des Fensters. Im Spiel ist das ueber
    -- alle Durchlaeufe dasselbe Frame, also muss der Test es auch wiederverwenden
    -- koennen -- sonst prueft er eine Sperre, die er selbst umgeht.
    if not (opts.reuseWindow and WINDOW) then
        WINDOW = MakeWindow(frames, sources, opts.throwAt, opts.sticky,
                            opts.editing, opts.elements)
    end
    BackfillIdentity()
    inCombat = false
    local out = {}
    for i, f in ipairs(frames) do out[i] = f._dilvlGUID or "-" end
    return table.concat(out, ","), bfCtrl.trusted, bfCtrl.ok, bfCtrl.bad,
           REFRESH_CALLS
end

-- Four hunters of one spec, damage totals sealed. Two of them are witnesses.
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

-- One row whose class does not match its source: a class cannot change, so the
-- list moved, and then no index in this window is worth anything.
local function raidWithStranger()
    local frames = {
        Row(1, "HUNTER", 11, {isLocalPlayer = true}),
        Row(2, "HUNTER", 11),
        Row(3, "HUNTER", 11),
        Row(4, "MAGE", 62),
    }
    local sources = {
        Source(PLAYER, "HUNTER", 11), Source("G2", "HUNTER", 11),
        Source("G3", "HUNTER", 11),   Source("G4", "WARRIOR", 71),
    }
    return frames, sources
end

R.trusted        = {run(raid(false))}
R.classVeto      = {run(raidWithStranger())}
R.reordered      = {run(raid(true))}
R.noControl      = {run(raid(false, {stripBound = true, stripPlayer = true}))}
R.playerOnly     = {run(raid(false, {stripBound = true}))}
R.inCombat       = {run(raid(false), nil, {combat = true})}

-- THE ONE THIS SUITE EXISTS FOR. Two mages of the same spec change places in
-- the list; the local player at the top does not move. No witness moves, and the
-- class string at every index is unchanged, so the window-wide licence is
-- granted -- and it must still decide nothing here.
do
    local frames = {
        Row(1, "HUNTER", 11, {isLocalPlayer = true}),
        Row(2, "MAGE", 62),
        Row(3, "MAGE", 62),
    }
    local sources = {Source(PLAYER, "HUNTER", 11),
                     Source("Y", "MAGE", 62), Source("X", "MAGE", 62)}
    R.transposed = {run(frames, sources)}
end

-- The same shape with one member pinned: now the remaining row is the only
-- place its source can be, and it resolves.
do
    local frames = {
        Row(1, "HUNTER", 11, {isLocalPlayer = true}),
        Row(2, "MAGE", 62, {boundGuid = "X"}),
        Row(3, "MAGE", 62),
    }
    local sources = {Source(PLAYER, "HUNTER", 11),
                     Source("X", "MAGE", 62), Source("Y", "MAGE", 62)}
    R.lastOne = {run(frames, sources)}
end

-- Blizzard pins the local player on a frame outside the ScrollBox. With your
-- own bar scrolled out that frame is the only place it exists, and without it
-- the window has no witness at all.
do
    local sticky = Row(1, "HUNTER", 11, {isLocalPlayer = true})
    sticky.IsShown = function() return true end
    -- Nur versiegelte Reihen in der ScrollBox: ohne die angeheftete Zeile hat
    -- dieses Fenster ueberhaupt keinen Zeugen.
    local frames = {Row(2, "HUNTER", 11)}
    local sources = {Source(PLAYER, "HUNTER", 11), Source("A", "HUNTER", 11)}
    R.stickyWitness = {run(frames, sources, {sticky = sticky})}
end

-- The row walk throws after the first agreement and before the disagreeing
-- witness. The counters live outside the callback, so without an explicit
-- completion flag this is the case that turns a fault INTO a licence.
do
    local frames = {
        Row(1, "HUNTER", 11, {isLocalPlayer = true}),
        Row(2, "MAGE", 62, {boundGuid = "FALSCH"}),
        Row(3, "MAGE", 62),
    }
    local sources = {Source(PLAYER, "HUNTER", 11),
                     Source("X", "MAGE", 62), Source("Y", "MAGE", 62)}
    R.ctrlThrow = {run(frames, sources, {throwAt = 1})}
end

-- One bound witness agrees, one does not: a single failure shuts the window.
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

-- Same class, different spec: a player may respec, so that is this one row's
-- business and no evidence the list moved. The window stays licensed.
do
    local frames = {
        Row(1, "HUNTER", 11, {isLocalPlayer = true}),
        Row(2, "HUNTER", 62),
    }
    local sources = {Source(PLAYER, "HUNTER", 11), Source("G2", "HUNTER", 258)}
    R.specDiff = {run(frames, sources)}
end

-- Two rows, one source: the second must not get the same player.
do
    local frames = {
        Row(1, "HUNTER", 11, {isLocalPlayer = true}),
        Row(2, "HUNTER", 11), Row(2, "HUNTER", 11),
    }
    local sources = {Source(PLAYER, "HUNTER", 11), Source("G2", "HUNTER", 11)}
    R.doubleClaim = {run(frames, sources)}
end

-- The fresh read still hands back secrets of its own.
do
    local frames = {Row(1, "HUNTER", 11, {isLocalPlayer = true}),
                    Row(2, "HUNTER", 11)}
    local sources = {Source(PLAYER, "HUNTER", 11), Source(SECRET, "HUNTER", 11)}
    R.secretGuid = {run(frames, sources)}
end

-- GetElementData binds a row to its element and no re-sort can move it, so the
-- direct path needs neither index nor licence.
do
    local ed = {sourceGUID = "GD", classFilename = "HUNTER", specIconID = 11}
    local frames = {Row(9, "HUNTER", 11, {elementData = ed})}
    R.direct = {run(frames, {})}
end

-- An identity the join itself produced is fromAPI, but it is NOT evidence about
-- the ordering -- that is the thing it assumed. It must not count as a witness.
do
    local frames = {Row(2, "HUNTER", 11, {inferredGuid = "G2"}),
                    Row(3, "PRIEST", 258)}
    local sources = {Source(PLAYER, "HUNTER", 11), Source("G2", "HUNTER", 11),
                     Source("G3", "PRIEST", 258)}
    R.selfLicense = {run(frames, sources)}
end

-- Nur die Lizenz entscheidet hier. Die Gruppe WARRIOR/71 hat zwei Mitglieder,
-- eines davon durch die eigene Zeile fixiert -- die Fixierung allein wuerde die
-- andere aufloesen, und die Ausschluss-Regel greift nicht, weil beide GUIDs noch
-- frei sind. Ein widersprechender Zeuge im selben Fenster nimmt die Erlaubnis.
do
    local frames = {
        Row(1, "WARRIOR", 71, {isLocalPlayer = true}),
        Row(2, "WARRIOR", 71),
        Row(3, "MAGE", 62, {boundGuid = "FALSCH"}),
    }
    local sources = {Source(PLAYER, "WARRIOR", 71), Source("Y", "WARRIOR", 71),
                     Source("A", "MAGE", 62)}
    R.licenceOnly = {run(frames, sources)}
end

-- Der eigentliche Weg: versiegelte Zeilen ohne Identitaet -> Blizzard einmal um
-- einen frischen Lesevorgang bitten, danach beantwortet der DIREKTE Pfad alles.
do
    ClearRefreshRequests()
    REFRESH_CALLS = 0
    local elements = {[2] = {sourceGUID = SECRET, classFilename = "HUNTER",
                             specIconID = 11}}
    local frames = {Row(1, "HUNTER", 11, {isLocalPlayer = true}),
                    Row(2, "HUNTER", 11, {elementData = elements[2]})}
    local sources = {Source(PLAYER, "HUNTER", 11), Source("G2", "HUNTER", 11)}
    -- Erster Lauf: bittet um den frischen Lesevorgang und entscheidet nichts.
    local a = {run(frames, sources, {elements = elements})}
    -- Zweiter Lauf: dieselben Frames, jetzt mit lesbaren Elementdaten.
    local b = {run(frames, sources, {elements = elements, reuseWindow = true})}
    R.refreshAsked  = {a[1], a[5]}
    R.refreshWorked = {b[1], b[5]}
end

-- Im Bearbeitungsmodus liefert das Fenster eine Attrappe; da ist ein frischer
-- Lesevorgang sinnlos.
do
    ClearRefreshRequests()
    REFRESH_CALLS = 0
    local frames = {Row(1, "HUNTER", 11, {isLocalPlayer = true}),
                    Row(2, "HUNTER", 11)}
    local sources = {Source(PLAYER, "HUNTER", 11), Source("G2", "HUNTER", 11)}
    local g = {run(frames, sources, {editing = true, armRefresh = true,
                                     elements = {}})}
    R.editingNoRefresh = {g[1], g[5]}
end

R.backfills = identityBackfills
return R
"""

chunk = (HARNESS
         .replace("__SET_GUID__", SET_GUID)
         .replace("__ELEMENT_DATA__", ELEMENT_DATA)
         .replace("__REFRESH_REQ__", REFRESH_REQ)
         .replace("__BACKFILL__", BACKFILL))

R = lupa.LuaRuntime(unpack_returned_tuples=False).execute(chunk)


def guids(key):
    return R[key][1]


def lic(key):
    return R[key][2]


def ctrl_ok(key):
    return R[key][3]


checks = [
    # --- the blocking case
    ("zwei vertauschte Spieler gleicher Klasse UND Spezialisierung werden nicht"
     " aufgeloest", guids("transposed") == "Player-Quinroth,-,-"),
    ("das Fenster gilt dabei trotzdem als lizenziert (Lizenz allein reicht nicht)",
     lic("transposed") == 1),
    ("ist jeder andere der Gruppe fixiert, loest die letzte Reihe auf",
     guids("lastOne") == "Player-Quinroth,X,Y"),

    # --- the licence itself
    # Die eigene Zeile bleibt hier absichtlich offen: ihre Gruppe hat zwei
    # Unbekannte. Auf dem Bildschirm fehlt sie trotzdem nie, weil
    # ResolveFrameGUID sie ueber UnitGUID("player") beantwortet, ganz ohne Liste.
    ("nur fixierte Gruppen kommen durch, der Rest bleibt leer",
     guids("trusted") == "-,G2,-,-"),
    ("dabei ist genau ein Fenster lizenziert", lic("trusted") == 1),
    ("umsortierte Liste loest nichts auf", guids("reordered") == "-,G2,-,-"),
    ("und lizenziert kein Fenster", lic("reordered") == 0),
    ("ohne jede Kontrolle wird nichts aufgeloest",
     guids("noControl") == "-,-,-,-" and lic("noControl") == 0),
    ("ein einzelner Zeuge lizenziert, entscheidet aber keine Gruppe mit mehreren"
     " Unbekannten", guids("playerOnly") == "-,-,-,-"
     and lic("playerOnly") == 1),
    ("eine einzige Abweichung schliesst das ganze Fenster",
     guids("oneMismatch") == "-,FALSCH,-" and lic("oneMismatch") == 0),
    ("eine unpassende Klasse schliesst das ganze Fenster",
     guids("classVeto") == "-,-,-,-" and lic("classVeto") == 0),

    # --- failing closed
    # Reihe 1 ist die einzige ihrer Klasse und faellt deshalb ueber Regel 1,
    # unabhaengig von jeder Lizenz. Reihe 3 braucht die Lizenz -- und bekommt sie
    # nicht, weil die Kontrolle nicht durchgelaufen ist.
    ("ein Abbruch mitten in der Kontrolle entzieht die Lizenz",
     guids("ctrlThrow") == "Player-Quinroth,FALSCH,-" and lic("ctrlThrow") == 0),
    ("im Kampf laeuft der Abgleich gar nicht erst",
     guids("inCombat") == "-,G2,-,-"),
    ("geheime GUID in der frischen Liste wird nicht verwendet",
     guids("secretGuid") == "Player-Quinroth,-"),

    # --- witnesses
    ("die angeheftete Eigen-Zeile zaehlt als Zeuge",
     guids("stickyWitness") == "A" and lic("stickyWitness") == 1),
    ("abgeleitete Identitaet zaehlt nicht als Zeuge",
     ctrl_ok("selfLicense") == 0 and lic("selfLicense") == 0),

    # --- per-row rules
    ("andere Spezialisierung blockt nur die Reihe, nicht das Fenster",
     guids("specDiff") == "Player-Quinroth,-" and lic("specDiff") == 1),
    # Which of the two rows wins is the fixpoint's iteration order and not the
    # promise. The promise is: exactly one.
    ("zwei Reihen bekommen nicht denselben Spieler",
     guids("doubleClaim").split(",").count("G2") == 1
     and guids("doubleClaim").startswith("Player-Quinroth,")),
    ("der direkte Weg braucht weder Index noch Lizenz",
     guids("direct") == "GD"),
    ("versiegelte Zeilen loesen genau EINEN frischen Lesevorgang aus",
     R["refreshAsked"][2] == 1),
    ("und dabei wird nichts geraten",
     R["refreshAsked"][1] == "-,-"),
    ("der zweite Lauf loest sie ueber den direkten Pfad auf, ohne erneut zu bitten",
     R["refreshWorked"][1] == "Player-Quinroth,G2"
     and R["refreshWorked"][2] == 1),
    ("im Bearbeitungsmodus wird nicht aufgefrischt",
     R["editingNoRefresh"][2] == 0),
    ("ein widersprechender Zeuge blockt auch eine fixierte Gruppe",
     guids("licenceOnly") == "-,-,FALSCH" and lic("licenceOnly") == 0),
]

print()
bad = 0
for n, ok in checks:
    print("  %s  %s" % ("PASS" if ok else "FAIL", n))
    bad += 0 if ok else 1

print()
controls = [
    ("Gruppen-Fixierung entfernt (Lizenz allein entscheidet wieder)",
     chunk.replace(
         "and grp and key\n                            and (grp.n - (pinnedInKey[key] or 0)) == 1 then",
         "and grp and key then"),
     lambda r: r["transposed"][1] == "Player-Quinroth,-,-"),
    ("Abbruch-Erkennung entfernt",
     chunk.replace("local orderTrusted = (ctrlComplete and ctrlBad == 0",
                   "local orderTrusted = (ctrlBad == 0"),
     lambda r: r["ctrlThrow"][2] == 0),
    ("Lizenz-Bedingung entfernt (jede Reihenfolge gilt als bewiesen)",
     chunk.replace(
         "local orderTrusted = (ctrlComplete and ctrlBad == 0\n"
         "                and ctrlClassBad == 0 and ctrlOk > 0)",
         "local orderTrusted = true"),
     lambda r: r["licenceOnly"][1] == "-,-,FALSCH"),
    ("Spezialisierungs-Vergleich entfernt",
     chunk.replace('elseif spec ~= fSpec then\n                            why = "specDiff"',
                   'elseif false then\n                            why = "specDiff"'),
     lambda r: r["specDiff"][1] == "Player-Quinroth,-"),
    ("Doppelvergabe-Sperre entfernt",
     chunk.replace("if not decided and orderTrusted and not claimed[guid]",
                   "if not decided and orderTrusted"),
     lambda r: r["doubleClaim"][1].split(",").count("G2") == 1),
    ("Provenienz ignoriert (abgeleitete Identitaet dient als Kontrolle)",
     chunk.replace("elseif frame._dilvlGUIDBound then",
                   "elseif frame._dilvlGUID then"),
     lambda r: r["selfLicense"][3] == 0),
    ("Wiedereintritts-Sperre entfernt (Auffrischen koennte sich wiederholen)",
     chunk.replace("if refreshRequested[sw] then return false end", ""),
     lambda r: r["refreshWorked"][2] == 1),
    ("angeheftete Eigen-Zeile nicht mehr befragt",
     chunk.replace("ControlFrame(lpe)", ""),
     lambda r: r["stickyWitness"][1] == "A"),
]
bad += run_controls(chunk, controls)

print("\n%s" % ("ALLE %d PRUEFUNGEN GRUEN" % len(checks) if not bad else "%d FEHLER" % bad))
sys.exit(1 if bad else 0)
