# -*- coding: utf-8 -*-
"""Behaviour test for the debug window.

Live 20.08.2026: /dilvl debug printed the whole report into chat and left the
window blank, twice, with nothing said either way. Two causes in one place.

The EditBox is a scroll child with no height of its own and no letter cap. A
long report is then refused outright -- no error, no text -- and the window shows
an empty box over the game world. The options page sets both a cap and a height
derived from the line count and has never blanked; this window set neither, and
the report has since grown past 30 000 characters in a raid.

The rule this enforces: the window either holds the report, or it SAYS it could
not. Silence that reads as "nothing happened" is what this addon's diagnostics
have been caught by three times now.

Drives the REAL ShowDebugWindow extracted from core.lua.
"""
import io, os, re, sys
import lupa
from control_harness import run_controls

os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
SRC = io.open("core.lua", encoding="utf-8").read().replace("\r\n", "\n")

m = re.search(r"^local function ShowDebugWindow\(text\)\n.*?^end$", SRC, re.M | re.S)
if not m:
    sys.exit("ShowDebugWindow nicht gefunden")
# Der Torwaechter haengt seit dem Release-Review direkt am Fenstereingang;
# das Fenster laeuft hier mit dem ECHTEN ScrubUtf8 davor, nicht mit einem Stub.
m2 = re.search(r"^local function ScrubUtf8\(str\)\n.*?^end$", SRC, re.M | re.S)
if not m2:
    sys.exit("ScrubUtf8 nicht gefunden")
SHOW = m2.group(0) + "\n" + m.group(0)
for needle, why in [
    ("SetMaxLetters", "die aufgehobene Zeichenkappe"),
    ("SetHeight", "die Hoehe des Scroll-Kindes"),
    ("return false", "die Rueckmeldung bei Ablehnung"),
]:
    if needle not in SHOW:
        sys.exit("%s fehlt in ShowDebugWindow" % why)

HARNESS = u"""
local EM_DASH = "-"

-- Eine EditBox, die ab einer Grenze schweigend ablehnt -- genau das Verhalten,
-- an dem das Fenster live leer blieb.
SCROLL_W = 800
LIMIT = nil
local box = {text = "", height = 0, highlighted = false, maxLetters = nil,
             maxBytes = nil, width = 0}
function box:SetMultiLine() end
function box:SetFontObject() end
function box:SetWidth(w) self.width = w end
function box:GetWidth() return self.width end
function box:GetHeight() return self.height end
function box:SetAutoFocus() end
function box:SetScript() end
function box:SetMaxLetters(n) self.maxLetters = n end
function box:SetMaxBytes(n) self.maxBytes = n end
function box:GetFont() return "font", 12, "" end
function box:SetHeight(h) self.height = h end
function box:SetText(t)
    if LIMIT and #t > LIMIT then self.text = "" else self.text = t end
end
function box:GetText() return self.text end
function box:HighlightText() self.highlighted = true end

SHOWN = 0
DILvlDebugFrame = {
    editBox = box,
    scroll = {GetWidth = function() return SCROLL_W end},
    GetWidth = function() return 900 end,
    Show = function() SHOWN = SHOWN + 1 end,
}

-- Alles, was der Original-Aufbau beruehrt, wird nie erreicht: das Fenster
-- existiert bereits. Die Stubs unten fangen nur ab, falls das doch passiert.
function CreateFrame() error("Fenster wurde unerwartet neu gebaut") end

__SHOW__

local R = {}

local function build(n)
    local t = {}
    for i = 1, n do t[i] = "Zeile " .. i end
    return table.concat(t, "\\n")
end

-- 1) Normalfall: passt hinein
LIMIT = nil
box.text, box.height, box.highlighted = "", 0, false
local small = build(40)
R.okReturn    = ShowDebugWindow(small)
R.okText      = box.text
R.okHeight    = box.height
R.okHighlight = box.highlighted
R.okCap       = box.maxLetters
R.okCapBytes  = box.maxBytes
R.okWidth     = box.width

-- 2) Die Box lehnt ab: Rueckgabe false, und im Fenster steht, was passiert ist
LIMIT = 500
box.text, box.height, box.highlighted = "", 0, false
local big = build(400)
R.bigReturn = ShowDebugWindow(big)
R.bigText   = box.text
R.bigSize   = #big

-- 3) Scroll-Frame noch nicht vermessen: die Breite muss trotzdem brauchbar sein
SCROLL_W = 0
LIMIT = nil
box.text, box.width = "", 0
R.unlaidReturn = ShowDebugWindow(build(40))
R.unlaidWidth  = box.width
SCROLL_W = 800

-- 4) Leerer Bericht ist kein Fehlschlag
LIMIT = nil
box.text = ""
R.emptyReturn = ShowDebugWindow("")

-- 5) Ungueltige Kodierung am Fenstereingang: wird an der Tuer repariert, egal
-- welcher Aufrufer den rohen Schnitt verursacht hat (blizztrace, taint) --
-- der Bericht-Sammler ist nicht mehr der einzige bewachte Weg.
LIMIT = nil
box.text = ""
R.scrubReturn = ShowDebugWindow("kaputt: " .. string.char(0xC3) .. " Ende")
-- Urteil in Lua faellen: das rohe Byte darf nicht zurueck nach Python
-- (dort waere es selbst der Kodierungsfehler, den es nachweist).
R.scrubText = (box.text == "kaputt: ? Ende") and "repariert"
    or (box.text:find(string.char(0xC3), 1, true) and "roh" or "anders")

R.shown = SHOWN
return R
"""

chunk = HARNESS.replace("__SHOW__", SHOW)
R = lupa.LuaRuntime(unpack_returned_tuples=False).execute(chunk)

checks = [
    ("passender Bericht landet im Fenster", R["okText"].startswith("Zeile 1")),
    ("und wird als Erfolg gemeldet", R["okReturn"] is True),
    ("das Scroll-Kind bekommt eine Hoehe aus der Zeilenzahl",
     R["okHeight"] > 40 * 12),
    ("der Text ist vorausgewaehlt, Strg+C reicht", R["okHighlight"] is True),
    ("die Zeichenkappe ist aufgehoben", R["okCap"] == 0),
    ("die Byte-Kappe ebenfalls", R["okCapBytes"] == 0),
    ("die Textbreite folgt dem Fenster", R["okWidth"] == 800 - 8),

    ("eine ablehnende Box wird als Fehlschlag gemeldet", R["bigReturn"] is False),
    # Was die Box am Ende annimmt, haengt von ihrer Grenze ab -- die Zusage ist
    # nur, dass etwas drinsteht und dass es sich erklaert.
    ("das Fenster bleibt dabei NICHT leer", R["bigText"] != ""),
    ("und nennt beide Groessen: was ankam und was es haette sein sollen",
     str(R["bigSize"]) in R["bigText"] and "took 0 of" in R["bigText"]),

    ("ein leerer Bericht gilt nicht als Fehlschlag", R["emptyReturn"] is True),
    ("ohne vermessenes Scroll-Frame bleibt die Breite brauchbar",
     R["unlaidWidth"] > 100 and R["unlaidReturn"] is True),
    ("ungueltige Bytes werden an der Fenstertuer zu '?' repariert",
     R["scrubText"] == "repariert"),
    ("das Fenster wird in jedem Fall gezeigt", R["shown"] == 5),
]

print()
bad = 0
for n, ok in checks:
    print("  %s  %s" % ("PASS" if ok else "FAIL", n))
    bad += 0 if ok else 1

print()
controls = [
    ("Erfolgspruefung entfernt (Ablehnung faellt nicht mehr auf)",
     chunk.replace("if #body > 0 and got < #body then", "if false then"),
     lambda r: r["bigReturn"] is False),
    ("Hoehe des Scroll-Kindes entfernt",
     chunk.replace("eb:SetHeight(lineCount * ((fontHeight or 12) * 1.25) + 20)", ""),
     lambda r: r["okHeight"] > 40 * 12),
    ("Zeichenkappe nicht mehr aufgehoben",
     chunk.replace("    eb:SetMaxLetters(0)\n    eb:SetMaxBytes(0)",
                   "    eb:SetMaxBytes(0)"),
     lambda r: r["okCap"] == 0),
    ("Byte-Kappe nicht mehr aufgehoben",
     chunk.replace("    eb:SetMaxBytes(0)\n", "", 1),
     lambda r: r["okCapBytes"] == 0),
    ("Fenster erst nach dem Text gezeigt (Layout fehlt beim Schreiben)",
     chunk.replace("    DILvlDebugFrame:Show()\n    -- Width from the scroll frame",
                   "    -- Width from the scroll frame"),
     lambda r: r["shown"] == 5),
    ("Torwaechter am Fenstereingang entfernt (roher Schnitt kaeme durch)",
     chunk.replace('    text = ScrubUtf8(text or "")\n', ""),
     lambda r: r["scrubText"] == "repariert"),
    ("Breiten-Rueckfall entfernt (0 - 8 ergibt eine negative Breite)",
     chunk.replace("if scrollW < 100 then scrollW = 650 end", "")
          .replace("if scrollW < 100 then scrollW = (DILvlDebugFrame:GetWidth() or 0) - 40 end", ""),
     lambda r: r["unlaidWidth"] > 100),
]
bad += run_controls(chunk, controls)

print("\n%s" % ("ALLE %d PRUEFUNGEN GRUEN" % len(checks) if not bad else "%d FEHLER" % bad))
sys.exit(1 if bad else 0)
