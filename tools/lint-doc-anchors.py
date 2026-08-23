# -*- coding: utf-8 -*-
"""Die Code-Doku darf nicht vom Code wegdriften.

Kommentare, die ihre Herleitung an eine .md abgeben, tauschen Naehe gegen
Kuerze. Der Preis: zwei Dateien, die auseinanderlaufen koennen, ohne dass
irgendetwas bricht -- kein Fehler, kein roter Test, nur ein Verweis, der ins
Leere zeigt, und ein Leser, der die Regel nicht mehr findet.

Drei Pruefungen:

1. Jeder `-- Why: dev-docs/CODE_NOTES.md#anker` im Code hat seinen Abschnitt.
2. Jeder Abschnitt der .md wird aus dem Code heraus verwiesen. Ein Abschnitt,
   den niemand zitiert, ist genau der, der beim naechsten Umbau vergessen wird.
3. Traegt ein Abschnitt einen Funktionsnamen im Titel, muss der Verweis darauf
   auch WIRKLICH ueber dieser Funktion stehen.

Pruefung 3 kommt aus einem echten Fehler vom 23.08.2026. Der Kommentarblock
ueber `U.ShortenForDisplay` beschrieb ZWEI Funktionen: erst die Herleitung zu
StripRealm, am Ende die Warnung zu ShortenForDisplay. Beim Kuerzen wurde er als
ein Block behandelt -- die Warnung "das Ergebnis darf nie gespeichert oder als
Schluessel benutzt werden" verschwand, und der uebrig gebliebene
StripRealm-Text stand ueber der falschen Funktion. Beides ohne einen einzigen
roten Test: Lua uebersetzt Kommentare nicht, und keine Suite liest sie.
"""
import io, os, re, sys

os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

DOC = "dev-docs/CODE_NOTES.md"
SOURCES = [f for f in os.listdir(".") if f.endswith(".lua")]
SOURCES += [os.path.join("ui", f) for f in os.listdir("ui") if f.endswith(".lua")] \
    if os.path.isdir("ui") else []

if not os.path.exists(DOC):
    print("  %s fehlt -- nichts zu pruefen" % DOC)
    sys.exit(0)

doc = io.open(DOC, encoding="utf-8").read().replace("\r\n", "\n")

# Abschnitte: "### Titel ... {#anker}"
sections = {}
for m in re.finditer(r"^#{2,4}\s+(.*?)\s*\{#([a-z0-9-]+)\}\s*$", doc, re.M):
    sections[m.group(2)] = m.group(1)

# Verweise im Code, mit Fundstelle
refs = []
for src in sorted(SOURCES):
    lines = io.open(src, encoding="utf-8").read().replace("\r\n", "\n").split("\n")
    for i, line in enumerate(lines):
        for m in re.finditer(r"CODE_NOTES\.md#([a-z0-9-]+)", line):
            refs.append((src, i + 1, m.group(1), lines))

bad = []

# 1) Verweis ohne Abschnitt
for src, ln, anchor, _ in refs:
    if anchor not in sections:
        bad.append("%s:%d verweist auf #%s -- diesen Abschnitt gibt es in %s nicht"
                   % (src, ln, anchor, DOC))

# 2) Abschnitt ohne Verweis
referenced = set(a for _, _, a, _ in refs)
for anchor in sorted(sections):
    if anchor not in referenced:
        bad.append("%s: Abschnitt #%s wird aus keiner .lua-Datei verwiesen" % (DOC, anchor))

# 3) Funktionsname im Titel -> steht der Verweis ueber genau dieser Funktion?
DEF = re.compile(r"^\s*(?:local\s+)?function\s+[\w.:]*?([\w]+)\s*\(")
for src, ln, anchor, lines in refs:
    title = sections.get(anchor)
    if not title:
        continue
    name = re.match(r"^`?([A-Za-z_][\w]*)`?\b", title)
    if not name:
        continue                      # Titel ist keine Funktion ("iLvl-Farbbaender")
    name = name.group(1)
    if not any(re.search(r"\bfunction\s+[\w.:]*%s\s*\(" % re.escape(name), l) for l in lines):
        continue                      # Funktion lebt woanders -- nicht unsere Sache
    # naechste Funktionsdefinition unter dem Verweis suchen
    nxt = None
    for j in range(ln, min(ln + 25, len(lines))):
        m = DEF.match(lines[j])
        if m:
            nxt = (m.group(1), j + 1)
            break
    if nxt and nxt[0] != name:
        bad.append("%s:%d verweist auf #%s (\"%s\"), aber darunter steht %s() in Zeile %d "
                   "-- der Kommentar sitzt an der falschen Funktion"
                   % (src, ln, anchor, name, nxt[0], nxt[1]))

print()
if bad:
    print("  Doku und Code sind auseinandergelaufen:\n")
    for b in bad:
        print("    * %s" % b)
    print("\n  %d PROBLEM(E)" % len(bad))
    sys.exit(1)

print("  %d Verweise, %d Abschnitte, beidseitig vollstaendig" % (len(refs), len(sections)))
print("  ALLE PRUEFUNGEN GRUEN")
sys.exit(0)
