# -*- coding: utf-8 -*-
"""Behaviour test for buildBands, the derived iLvl colour scale.

Extracts the real constants and functions out of util.lua and drives them
against the mythic+ reward curve as actually measured in-game on 2026-09-17 --
including its hole at key 8, which returns 305 and therefore sits BELOW both
key 7 (315) and key 6 (311).

The case this exists for: the curve only covers the bottom half of the scale.
Keys 11 through 20 all return the same 318 as key 10, so every band above the
ceiling is placed by upgrade rank instead. The first version of that had the top
band fatal like the curve-derived ones, which would have thrown the whole
derived scale back to the rotting fallback whenever one colour was missing --
the exact failure that shipped in 1.5.8 and painted everyone orange on season 2
launch day. The split matters: a missing colour below the ceiling is fatal, a
missing colour above it drops one band and nothing else.

Positive controls at the bottom remove each guard and must fail.
"""
import io, os, re, sys
import lupa
from control_harness import run_controls

os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
SRC = io.open("util.lua", encoding="utf-8").read().replace("\r\n", "\n")

START = "local BAND_KEYS = {10, 6}"
s = SRC.find(START)
if s < 0:
    sys.exit("BAND_KEYS nicht gefunden")
e = SRC.find("\n    return rows\nend", s)
if e < 0:
    sys.exit("Ende von buildBands nicht gefunden")
FN = SRC[s : e + len("\n    return rows\nend")]
for needed in ("ABOVE_CEILING", "FLOOR_KEY", "buildBands", "rewardFor",
               "UNCOMMON_BELOW_FLOOR", "PLAUSIBLE_MIN"):
    assert needed in FN, needed

HARNESS = u"""
-- Der Client ist Lua 5.1 und schneidet bei %X die Nachkommastellen ab; lupa
-- laeuft hier unter 5.5 und wirft stattdessen. qualityColor uebergibt
-- absichtlich r * 255 + 0.5 und rundet damit ueber genau diesen Schnitt.
-- Ohne diesen Nachbau testet die Suite eine Semantik, die es im Spiel nicht
-- gibt. Alle Werte sind positiv, floor ist hier dasselbe wie 5.1s Cast.
local unpack = unpack or table.unpack
local rawformat = string.format
local function format(fmt, ...)
    local a, n = {...}, select("#", ...)
    for i = 1, n do
        if type(a[i]) == "number" then a[i] = math.floor(a[i]) end
    end
    return rawformat(fmt, unpack(a, 1, n))
end

-- Gemessen 2026-09-17 in-game, Stufen 2 bis 20. Das Loch bei 8 ist echt.
local CURVE = {
    [2]=305, [3]=305, [4]=308, [5]=308, [6]=311, [7]=315, [8]=305, [9]=315,
    [10]=318, [11]=318, [12]=318, [13]=318, [14]=318, [15]=318,
    [16]=318, [17]=318, [18]=318, [19]=318, [20]=318,
}

-- Blizzards Palette, gemessen ueber C_Item.GetItemQualityColor.
local QUALITY = {
    [0] = {0.616, 0.616, 0.616},   -- poor
    [2] = {0.118, 1.000, 0.000},   -- uncommon
    [3] = {0.000, 0.439, 0.867},   -- rare
    [4] = {0.639, 0.208, 0.933},   -- epic
    [5] = {1.000, 0.502, 0.000},   -- legendary
    [6] = {0.902, 0.800, 0.502},   -- artifact
    [7] = {0.000, 0.800, 1.000},   -- heirloom
}

local curveOverride = nil
local missingQuality = {}
local secretQuality = {}

-- Im Client WIRFT der Vergleich eines geheimen Wertes; eine Lua-Zahl kann das
-- in dieser Sandbox nicht nachbauen. Der Sentinel prueft deshalb das, worauf es
-- ankommt: dass der Waechter ueberhaupt GEFRAGT wird, bevor verglichen oder
-- gerechnet wird. Er liegt bewusst UEBER PLAUSIBLE_MIN, sonst faenge ihn die
-- Plausibilitaetsgrenze ab und die Positivkontrolle liefe ins Leere.
local SECRET = 424242
local function isSecretValue(v) return v == SECRET end

C_MythicPlus = {
    GetRewardLevelFromKeystoneLevel = function(k)
        return (curveOverride or CURVE)[k]
    end,
}

C_Item = {
    GetItemQualityColor = function(q)
        if missingQuality[q] then return nil end
        local c = QUALITY[q]
        if not c then return nil end
        if secretQuality[q] then return SECRET, c[2], c[3] end
        return c[1], c[2], c[3]
    end,
}

__FN__

local R = {}

local function shape(rows, prefix)
    R[prefix .. "Built"] = rows and true or false
    if not rows then return end
    R[prefix .. "N"]   = #rows
    R[prefix .. "Top"] = rows[1][1]
    R[prefix .. "Hex"] = rows[1][2]
    R[prefix .. "Low"] = rows[#rows][1]
    local ok = true
    for i = 2, #rows do
        if rows[i][1] >= rows[i - 1][1] then ok = false end
    end
    R[prefix .. "Desc"] = ok
end

-- Normalfall: volle Skala
shape(buildBands(), "full")

-- Alle sieben Grenzen einzeln, damit eine verrutschte Stufe auffaellt
local full = buildBands()
for i = 1, #full do R["b" .. i] = full[i][1] end
R.gap = full[1][1] - full[4][1]     -- oberstes Band ueber der Decke

-- Ueber der Decke ist jedes Band eine Verfeinerung: fehlt die Farbe, bleibt
-- der Rest stehen
missingQuality = {[7] = true}
shape(buildBands(), "noHeirloom")
missingQuality = {[6] = true}
shape(buildBands(), "noArtifact")
missingQuality = {}

-- Unter der Decke ist dieselbe Luecke toedlich
missingQuality = {[4] = true}
R.noEpic = buildBands()
missingQuality = {[2] = true}
R.noUncommon = buildBands()
missingQuality = {}

-- Kurve nicht streng absteigend
curveOverride = {[2]=305, [6]=320, [10]=318}
R.holeCurve = buildBands()

-- Boden ueber dem Band darueber: ebenfalls keine Kurve mehr
curveOverride = {[2]=315, [6]=311, [10]=318}
R.floorTooHigh = buildBands()

-- Null-Decke: gefaehrlicher als nil, wuerde jede Schwelle negativ machen
curveOverride = {[2]=305, [6]=311, [10]=0}
R.zeroCeiling = buildBands()

-- Kurve, die NUR an der Plausibilitaetsgrenze scheitert: streng absteigend,
-- also am Monotonie-Waechter vorbei, aber viel zu niedrig fuer Ausruestung.
curveOverride = {[2]=50, [6]=80, [10]=150}
R.lowCurve = buildBands()

-- Geheime Belohnungsstufe: muss wie "nichts" wirken, nicht wie eine Zahl
curveOverride = {[2]=305, [6]=311, [10]=SECRET}
R.secretReward = buildBands()
curveOverride = nil

-- Geheime Farbe ueber der Decke: nur dieses Band entfaellt
secretQuality = {[7] = true}
shape(buildBands(), "secretTop")
secretQuality = {}

-- API stumm
curveOverride = {}
R.silent = buildBands()
curveOverride = nil

return R
"""

chunk = HARNESS.replace("__FN__", FN)
R = lupa.LuaRuntime(unpack_returned_tuples=False).execute(chunk)

# Der Fallback in util.lua muss dieselbe Form haben, sonst faellt die Skala bei
# stummer API auf eine Tabelle zurueck, die andere Grenzen zieht.
rows = re.findall(r"^\s*\{(\d+),\s*\"([0-9A-F]{6})\"", SRC, re.M)
fallback = [(int(a), b) for a, b in rows]
derived = [R["b%d" % i] for i in range(1, 8)]

checks = [
    ("volle Skala wird gebaut", R["fullBuilt"] is True),
    ("sieben Baender", R["fullN"] == 7),
    ("Grenzen sind 328/324/321/318/311/300/0",
     derived == [328, 324, 321, 318, 311, 300, 0]),
    ("oberstes Band ist Erbstueck-Cyan", R["fullHex"] == "00CCFF"),
    ("oberstes Band liegt 10 ueber der Decke", R["gap"] == 10),
    ("unterstes Band faengt alles", R["fullLow"] == 0),
    ("Skala ist streng absteigend", R["fullDesc"] is True),

    ("ohne Erbstueck-Farbe baut die Skala trotzdem", R["noHeirloomBuilt"] is True),
    ("ohne Erbstueck-Farbe bleiben sechs Baender", R["noHeirloomN"] == 6),
    ("ohne Erbstueck-Farbe fuehrt 324", R["noHeirloomTop"] == 324),
    ("ohne Artefakt-Farbe baut die Skala trotzdem", R["noArtifactBuilt"] is True),
    ("ohne Artefakt-Farbe bleiben sechs Baender", R["noArtifactN"] == 6),
    ("ohne Artefakt-Farbe fuehrt weiterhin 328", R["noArtifactTop"] == 328),

    ("fehlende Farbe UNTER der Decke kippt die Skala", R["noEpic"] is False),
    ("fehlende Boden-Farbe kippt die Skala", R["noUncommon"] is False),

    ("nicht absteigende Kurve wird verworfen", R["holeCurve"] is False),
    ("Boden ueber dem Band darueber wird verworfen", R["floorTooHigh"] is False),
    ("Null-Decke wird verworfen", R["zeroCeiling"] is False),
    ("unplausibel niedrige Kurve wird verworfen", R["lowCurve"] is False),
    ("stumme API wird verworfen", R["silent"] is False),
    ("geheime Belohnungsstufe kippt die Skala", R["secretReward"] is False),
    ("geheime Farbe ueber der Decke laesst den Rest stehen",
     R["secretTopBuilt"] is True and R["secretTopN"] == 6),

    ("Fallback hat ebenfalls sieben Zeilen", len(fallback) == 7),
    ("Fallback deckt sich mit der abgeleiteten Skala",
     [t for t, _ in fallback] == derived),
    ("Fallback fuehrt mit 328/00CCFF", fallback[0] == (328, "00CCFF")),
]

print()
bad = 0
for n, ok in checks:
    print("  %s  %s" % ("PASS" if ok else "FAIL", n))
    bad += 0 if ok else 1

print()
controls = [
    ("Baender ueber der Decke wieder toedlich gemacht",
     chunk.replace("        if ahex then\n"
                   "            table.insert(rows, 1, {ceiling + offset, ahex, ar, ag, ab})\n"
                   "        end",
                   "        if not ahex then return false end\n"
                   "        table.insert(rows, 1, {ceiling + offset, ahex, ar, ag, ab})"),
     lambda r: r["noHeirloomBuilt"] is True),
    ("Rangabstand entfernt, alle oberen Baender fallen auf die Decke",
     chunk.replace("{ceiling + offset, ahex", "{ceiling, ahex"),
     lambda r: r["b1"] == 328),
    ("Monotonie-Waechter entfernt",
     chunk.replace("        if prev and lvl >= prev then return false end\n", ""),
     lambda r: r["holeCurve"] is False),
    ("Boden-Waechter entfernt",
     chunk.replace(" or floorLvl >= prev", ""),
     lambda r: r["floorTooHigh"] is False),
    ("isSecretValue-Waechter vor dem Vergleich entfernt",
     chunk.replace("or isSecretValue(lvl)\n       ", ""),
     lambda r: r["secretReward"] is False),
    ("isSecretValue-Waechter vor der Farbrechnung entfernt",
     chunk.replace("\n       or isSecretValue(r) or isSecretValue(g) or isSecretValue(b)", ""),
     lambda r: r["secretTopN"] == 6),
    ("Plausibilitaetsgrenze entfernt",
     chunk.replace(" or lvl < PLAUSIBLE_MIN", ""),
     lambda r: r["lowCurve"] is False),
]
bad += run_controls(chunk, controls)

print("\n%s" % ("ALLE %d PRUEFUNGEN GRUEN" % len(checks) if not bad else "%d FEHLER" % bad))
sys.exit(1 if bad else 0)
