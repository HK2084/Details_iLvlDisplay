# -*- coding: utf-8 -*-
"""A shortened snippet of foreign text must never carry a half escape sequence.

Live 20.08.2026, and the symptom was not where the cause was. This addon's debug
window came up empty -- and so did the CHAT's own copy window, which belongs to
somebody else entirely. Two unrelated windows blanking at once was the tell: the
poison travelled with the text.

Blizzard's damage-meter rows carry escapes: a class atlas as |A:...|a and a
colour as |cAARRGGBB ... |r. The report shortened that text to a fixed 30
characters, which lands inside one of those sooner or later. A half sequence is
not cosmetic: WoW's renderer cannot parse it, and one of them is enough to blank
the whole widget the text is drawn in.

The proof was in the reports all along -- "|cFF9D9D9" on the row numbered 1 and
"|cFF9D9D" on the one numbered 10, one character shorter because the longer rank
pushed the cut one position earlier.

Doubling every bar makes the text literal, so the cut may then land anywhere.
Drives the REAL SafeSnippet extracted from blizzdm.lua.
"""
import io, os, re, sys
import lupa
from control_harness import run_controls

os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
SRC = io.open("blizzdm.lua", encoding="utf-8").read().replace("\r\n", "\n")

m = re.search(r"^            local function SafeSnippet\(s, n\)\n.*?^            end$",
              SRC, re.M | re.S)
if not m:
    sys.exit("SafeSnippet nicht gefunden")
SNIP = "\n".join(line[12:] for line in m.group(0).split("\n"))

HARNESS = u"""
__SNIP__

local R = {}
-- Wie Blizzard eine Zeile wirklich zusammensetzt: Klassen-Atlas, Rang, unser
-- Tag in Farbe, dann der Name.
local ROW = "|A:classicon-hunter:14:14|a 10. [282] |cFF9D9D9D[4P]|r Quinroth"
-- Der fuenfte Fall: ein Name mit Mehrbyte-Zeichen, dessen Schnitt mitten im
-- Zeichen landet -- ein halbes Zeichen ist ungueltige Kodierung und vergiftet
-- jede EditBox, die den Bericht je anfasst.
local UMLAUT_ROW = "5. |cFF9D9D9D[266]|r M" .. string.char(195,182) .. "hre-Bl" .. string.char(195,164) .. "ckmoore extra"

R.plain   = SafeSnippet("kein Balken hier", 30)
R.nilIn   = SafeSnippet(nil, 30)
R.short   = SafeSnippet("kurz", 30)

-- Jede Schnittlaenge muss ein Ergebnis liefern, in dem KEIN einzelner Balken
-- steht: eine ungerade Zahl von Balken am Stueck ist genau der kaputte Fall.
local worstOdd, worstLen = 0, 0
for n = 1, #ROW + 4 do
    local out = SafeSnippet(ROW, n)
    for run in out:gmatch("|+") do
        if #run % 2 == 1 then
            worstOdd = worstOdd + 1
            worstLen = n
        end
    end
    if #out > n then worstOdd = worstOdd + 1000 end
end
R.oddRuns = worstOdd
R.oddAt   = worstLen

R.cut30   = SafeSnippet(ROW, 30)

-- Jede Schnittlaenge: NIE ein unvollstaendiges UTF-8-Zeichen am Ende.
local utf8Bad = 0
for n = 1, #UMLAUT_ROW + 2 do
    local out = SafeSnippet(UMLAUT_ROW, n)
    local last = out:byte(#out)
    if last and last >= 0x80 then
        -- Endet auf Fortsetzungs- oder Lead-Byte: nur gueltig, wenn das
        -- komplette Zeichen drin ist. Pruefe die letzten 4 Bytes rueckwaerts.
        local k = #out
        while k > 0 and out:byte(k) >= 0x80 and out:byte(k) <= 0xBF do k = k - 1 end
        local lead = k > 0 and out:byte(k) or 0
        local need = (lead >= 0xF0 and 4) or (lead >= 0xE0 and 3) or (lead >= 0xC2 and 2) or 1
        if #out - k + 1 ~= need then utf8Bad = utf8Bad + 1 end
    end
end
R.utf8Bad = utf8Bad
return R
"""

chunk = HARNESS.replace("__SNIP__", SNIP)
R = lupa.LuaRuntime(unpack_returned_tuples=False).execute(chunk)

checks = [
    ("Text ohne Balken bleibt unveraendert", R["plain"] == "kein Balken hier"),
    ("nil bleibt nil", R["nilIn"] is None),
    ("kurzer Text wird nicht angefasst", R["short"] == "kurz"),
    ("bei KEINER Schnittlaenge entsteht ein einzelner Balken", R["oddRuns"] == 0),
    ("der Schnitt haelt die Laengenzusage ein", len(R["cut30"]) <= 30),
    ("und der Balken ist verdoppelt, also literal", "||" in R["cut30"]),
    ("bei KEINER Schnittlaenge endet der Text in einem halben UTF-8-Zeichen",
     R["utf8Bad"] == 0),
]

print()
bad = 0
for n, ok in checks:
    print("  %s  %s" % ("PASS" if ok else "FAIL", n))
    bad += 0 if ok else 1

print()
controls = [
    ("Verdoppelung entfernt (der alte, kaputte Schnitt)",
     chunk.replace('s = tostring(s):gsub("|", "||")', "s = tostring(s)"),
     lambda r: r["oddRuns"] == 0),
    ("UTF-8-Schwanz-Beschnitt entfernt (der fuenfte Fall)",
     chunk.replace("while #s > 0 do", "while false do"),
     lambda r: r["utf8Bad"] == 0),
    ("Schutz gegen den halbierten Balken entfernt",
     chunk.replace("if trailing % 2 == 1 then s = s:sub(1, #s - 1) end", ""),
     lambda r: r["oddRuns"] == 0),
]
bad += run_controls(chunk, controls)

print("\n%s" % ("ALLE %d PRUEFUNGEN GRUEN" % len(checks) if not bad else "%d FEHLER" % bad))
sys.exit(1 if bad else 0)
