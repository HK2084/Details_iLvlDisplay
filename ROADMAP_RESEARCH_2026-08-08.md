# Details_iLvlDisplay — Roadmap aus Recherche

**Stand:** 2026-08-08 · **Lokale Version:** 1.5.3 (TOC) · **CurseForge live:** 1.5.2 (2026-06-24)
**Leitplanke:** „Schöner aber schlicht. Nicht überladen." — jeder Punkt unten wurde gegen diesen Satz geprüft.

---

## Vorab: die ehrliche Nachfrage-Lage

Ich habe alle 34 CurseForge-Kommentare live gezogen
(`https://www.curseforge.com/api/v1/mods/1501917/comments?page=0` und `?page=1`, `page` ist 0-basiert)
und verbatim gelesen. Das Ergebnis ist unbequem klar:

**Es gibt genau zwei offene User-Wünsche. Alles andere ist bereits ausgeliefert.**

| Datum | User | Wunsch (verbatim) | Status |
|---|---|---|---|
| 2026-04-03 | Joster91 | „not working accurately for set piece, it showed 2P when I had 4P" | ✅ v1.2.0 |
| 2026-04-06 | Profion85 | iLvl im Kampf sichtbar | ⚠ siehe Sonderfall unten |
| 2026-04-24 | harrissx | „other unitframes then Elvui ? like standart blizz or dangers frames or **Cell** or Grid ?" | ◑ Grid2+Danders ✅ · **Cell + Blizz offen** |
| 2026-04-27 | NiGhTwAlKeR559 | Klammern weg | ✅ `[dilvl:plain]` v1.4.3 |
| 2026-05-08 | harrissx | Danders Textgröße | ✅ v1.4.4 |
| 2026-06-04 | 404Missingno | „change the text size / **font**" + nur ein Details-Fenster | ◑ Größe+Fenster ✅ · **Font-Familie nie geliefert** |
| 2026-06-22/24 | Profion85 | 2 Secret-Value-Crashes | ✅ v1.5.1 / v1.5.2 |

**Das wichtigste Signal im ganzen Datensatz:** Von sechs Feature-Wünschen aus fünf Jahren ging
**kein einziger** um *mehr Daten*. Alle gingen um **Lesbarkeit, Platzierung und wo es angezeigt wird**.
Niemand hat je nach M+-Score, Enchant-Audit, Loot-Übersicht oder Tooltip-Modus gefragt.
Das deckt sich exakt mit deinem Brief — und es heißt: **die Roadmap ist Politur, keine Features.**

Dasselbe Muster bei den Peers (Simple Item Levels, OiLvl, TinyInspect): sechs unabhängige User,
vier Addons, fünf Jahre — alle fragen nach **Schriftgröße, Schriftart, Farbe, Lesbarkeit**.
Beispiel `BarDOGfgc` (OiLvl, 2024-04-01): *„is there a way to change the font to arial?
Russian names don't display properly"* — genau die Fehlerklasse, die unser
„Font vom Host erben"-Ansatz heute produziert.

**Was ich NICHT belegen kann:** Reddit war nicht abrufbar (WebFetch blockiert `reddit.com`,
`search.json` liefert Cloudflare-403, pullpush.io-Mirror 502). Es gibt in dieser Roadmap
**keine einzige Reddit-Evidenz** — ich habe keine erfunden.

---

# 🔥 DO THESE NEXT

Fünf Punkte, alle Aufwand **S**, zusammen ein v1.6, das messbar besser ist ohne größer zu sein.
Sie fügen **eine** neue Einstellung hinzu (Font-Dropdown) und löschen unterm Strich Code.

---

### 1. Live-Preview zeigt Farben, die das Addon gar nicht rendert · [OUR-IDEA] · S

**Was sich ändert:** Die private Farbleiter in `ui/preview_widgets.lua:42-48` löschen und
stattdessen `ns.util.GetIlvlColor` aufrufen. Tier-Suffix mit dem festen Grün rendern statt
mit der iLvl-Farbe (`preview_widgets.lua:60`). Die drei Mock-iLvls so setzen, dass sie die
echten Bänder überspannen.

**Evidenz (selbst verifiziert, nicht aus zweiter Hand):**

| | Preview (`preview_widgets.lua:42-46`) | Real (`util.lua:18-22`) |
|---|---|---|
| Orange | ≥ 290 | ≥ 280 |
| Lila | ≥ 270 | ≥ 268 |
| Blau | ≥ 250 | ≥ 255 |
| Grün | ≥ 230 | ≥ 242 |

Der Mock-Spieler „Razul" hat iLvl 263 (`preview_widgets.lua:32`) → **im Preview rare-blau,
im Spiel uncommon-grün.** Zusätzlich färbt das Preview `[2P]`/`[4P]` mit der iLvl-Farbe
(`preview_widgets.lua:60`), während **alle vier** echten Flächen hart `|cFF00FF00` setzen
(`core.lua:411`, `core.lua:549`, `elvui_tags.lua:57`, `blizzdm.lua:350`).
Der Dateikommentar behauptet wörtlich *„Mirrors core.lua's tier-color bands"* — tut er nicht.
Und alle drei Mock-Werte (259/261/263) fallen in der echten Leiter in **dasselbe** Band,
das Preview kann den beworbenen Farbverlauf also gar nicht zeigen.

**Warum zuerst:** Das Preview ist das Aushängeschild von v1.5.0. Ein Preview, das lügt,
ist schlimmer als keins. Und der Fix **entfernt** Code.

**Bloat-Risiko:** keins — negativ, es löscht eine Funktion.

---

### 2. Typografie-Bündel: Font-Familie + Breiten, die mitskalieren · [USER-ASKED] + [OUR-IDEA] · S–M

Drei zusammenhängende Fixes an genau dem Feature, das 404Missingno bestellt hat.

**2a — Font-Familie (die nie gelieferte Hälfte) · [USER-ASKED]**
404Missingno, CurseForge, 2026-06-04, verbatim:
> „Personally, I'm missing the option to change the text size / **font**, and to set it so that
> it's only visible on one window in Details and not on all of them."

Größe und Fenster kamen in v1.5.0. Die Schriftart wurde stillschweigend fallengelassen.
Verifiziert: `CopyBarFont` (`core.lua:439-452`) liest `source:GetFont()` und überschreibt
**ausschließlich** `size`; `danders_integration.lua:128` macht dasselbe
(`local path, _, flags = fs:GetFont()`).

Ein Dropdown (LibSharedMedia falls vorhanden, sonst die 3 Blizzard-Fonts), **nur** für die
FontStrings, die **wir** selbst erzeugen: Details-Columns und Danders-Overlay.
Inline, ElvUI und Grid2 bleiben unangetastet — das ist fremder Text und muss erben.
Default bleibt „auto = wie Details".

**2b — Spaltenbreiten skalieren mit der Schriftgröße · [OUR-IDEA]**
`db.detailsFontSize` erlaubt 6–30 (`core.lua:444-446`), die Boxen sind aber hart
`COL_ILVL_WIDTH = 36` / `COL_TIER_WIDTH = 28` (`core.lua:111-112`), gesetzt via `SetWidth`
(`core.lua:462`, `:469`). `GetStringWidth()` ist durch diese Breite gedeckelt — deshalb hat
das Details-Framework extra `GetUnboundedStringWidth` (`Details-Framework/fw.lua:1977`).
Folge oben im Bereich: **Doppelfehler** — die dreistellige Zahl wird abgeschnitten *und*
`maxWidthIlvl` sättigt bei 36, sodass `tierAnchor` aus einer falschen Messung berechnet wird
und die Tier-Spalte auf die Zahl rutscht. Breite als Funktion der aufgelösten Größe berechnen,
Cap bleibt als Sicherheitsnetz.

**2c — `SetWidth` statt `SetSize` beim Namen · [OUR-IDEA] · eine Zeile**
`core.lua:690`: `bar.lineText1:SetSize(nameMaxW, 15)`. Details setzt die Höhe des Namens
bewusst auf `lineHeight*2` (`Details-Damage-Meter/classes/class_damage.lua:3286`).
Unsere hartcodierte 15 überschreibt das bei jedem Refresh — wer die Bar-Schrift hochdreht
(genau das tut jemand, der eine größere iLvl will), bekommt den Namen vertikal beschnitten.
`ClearAllColumns` setzt bereits mit `SetWidth(0)` zurück, die Paarung wird also symmetrisch.

**Bloat-Risiko:** gering, **aber deckeln**: *ein* globaler Font, kein Per-Channel-Font.
Ich würde den Outline-Toggle bewusst **weglassen** — er wäre die zweite Entscheidung für
ein Problem, das noch niemand gemeldet hat.

---

### 3. Timeout-Inspects wieder einreihen (+ Reichweiten-Vorabprüfung) · [OUR-IDEA] · S

**Was sich ändert:** Zwei Eingriffe in `ProcessNextInspect`, ~20 Zeilen, keine neue Datei,
kein neuer State, keine Einstellung.

**Evidenz — selbst nachgelesen, `core.lua:1001-1028`:**
```lua
local entry = table.remove(inspectQueue, 1)          -- :1001  raus aus der Queue
if SafeUnitGUID(entry.unit) == entry.guid and CanInspect(entry.unit, false) then
    NotifyInspect(entry.unit)
    C_Timer.After(15, function() ... isInspecting = false ... end)   -- kein Re-Queue!
else
    entry.retries = (entry.retries or 0) + 1
    if entry.retries <= 3 then table.insert(inspectQueue, entry) end  -- Budget am falschen Zweig
end
```

Das Retry-Budget hängt **ausschließlich** am `CanInspect == false`-Zweig. Der Timeout-Pfad
verliert den Eintrag ersatzlos.

Und `CanInspect` hat **keine Reichweiten-Komponente** — verifiziert an der offiziellen Signatur
in `wow-ui-source/.../Blizzard_APIDocumentationGenerated/PlayerScriptDocumentation.lua:55-68`:
genau **ein** Argument (`targetGUID`, Typ `UnitToken`). Nebenbei: unser Aufruf übergibt ein
zweites Argument `false`, das schlicht ignoriert wird.

Damit nimmt der häufigste reale Fehlerfall — **Spieler außer Reichweite** — den Timeout-Pfad
und bekommt **null** Retries. Danach hilft nur noch ein voller Sweep, und der feuert nur bei
`GROUP_ROSTER_UPDATE`, `ENCOUNTER_END(success)` und `UNIT_INVENTORY_CHANGED`. In einem M+-Key
feuert während einer langen Trash-Strecke keines davon: **der Tank, der beim Zonen vorausläuft,
kann 15 Minuten leer bleiben.**

Beide Peers machen die Vorabprüfung, wir nicht:
- `Cell/Libs/LibGroupInfo.lua:449` — `if not UnitIsConnected(unit) or not CheckInteractDistance(unit, 1) or not CanInspect(unit) then`
- `Details-Damage-Meter/core/inspect.lua:107` — `... and CheckInteractDistance(unitid, CONST_INSPECT_ACHIEVEMENT_DISTANCE) and CanInspect(unitid)`

**Warum das wichtiger ist als jedes Feature:** Das ist der unsichtbare Grund, warum manche
User Lücken sehen. Niemand hat es gemeldet, weil man einen fehlenden Wert nicht als Bug
erkennt — man hält das Addon für ungenau.

**Bloat-Risiko:** keins. Null neue Einstellungen, null neue UI. Reinste Form von „es funktioniert einfach".

---

### 4. Drei tote Design-Tokens verkabeln · [OUR-IDEA] · S

Alles selbst per grep verifiziert. Das ist „schöner aber schlicht" in Reinform: es fügt
**nichts** hinzu, es aktiviert, was du schon geschrieben und vergessen hast.

**4a — `theme.PANEL_INSET` ist tot.** `grep -rn "PANEL_INSET" ui/ core.lua init.lua` liefert
**genau einen** Treffer: die Definition selbst, `ui/theme.lua:56`. Null Verwendungen.
Gleichzeitig ankert jeder Panel-Titel bei x=10 (`ui/widgets.lua:43`), während jedes Control
darin bei x=12 sitzt (`page_general.lua:92,119,143`, `page_channels.lua:116`).
**Der Titel steht in jedem Panel 2 px links von dem, was er beschriftet.** Eine ausgefranste
linke Kante in einer umrandeten Box ist das deutlichste „unfertig"-Signal, das es gibt —
und es ist eine Konstante. Insgesamt sind fünf Innenabstände im Umlauf (8/10/12/14/16).

**4b — Radio-Labels sind 10 pt, Checkbox-Labels 12 pt, nebeneinander.**
`W.CreateCheckbox` überschreibt das Font-Objekt (`ui/widgets.lua:80`),
`W.CreateRadioGroup` setzt **nur** die Farbe und nie `SetFontObject` — selbst nachgelesen,
`ui/widgets.lua:297-301`:
```lua
if rb.text then
    rb.text:SetText(choice.label)
    theme.SetTextColor(rb.text, "primary")   -- kein SetFontObject
end
```
`UIRadioButtonTemplate` erbt `GameFontNormalSmall` = 10 pt. Auf dem General-Tab steht das
Panel „Master Toggles" (12 pt) direkt neben „Display" (10 pt). **Eine Zeile.**

**4c — Tab-Hover ist optisch identisch mit Tab-Selected.**
`ui/main_frame.lua:106-109` legt bei Hover eines *nicht* aktiven Tabs wörtlich
`ApplyBackdrop(self, "tab_active")` an — inklusive goldenem `BORDER_ACTIVE`. Beim Mauszug
über die Tab-Leiste sehen kurzzeitig zwei Tabs ausgewählt aus; nur die Labelfarbe unterscheidet.
Und `theme.BG_PANEL_HOVER` (`ui/theme.lua:21`) ist deklariert, hat **keinen** Zweig in
`ApplyBackdrop` und **null** Referenzen — auch hier bestätigt der grep nur die Definition.
Der Hover-Token, den du entworfen hast, ist nie angeschlossen worden.

**Bloat-Risiko:** keins, negativ. Aktiviert vorhandene Tokens, entfernt Magic Numbers,
null Entscheidungen für den User.

> **Bewusst NICHT anfassen:** Dein Backdrop-Rezept (`ui/theme.lua:75-100`: `WHITE8x8`-Kante,
> `edgeSize=1`, über gekacheltem `UI-Tooltip-Background`) ist byte-genau die Konvention des
> Details!-Frameworks (`Details-Framework/fw.lua:3334-3341`). Das ist für ein Addon, das
> *in* Details! wohnt, exakt richtig. Nicht „modernisieren".

---

### 5. Ein Formatter für den Tier-Suffix + Grid2 an „Color by tier" anschließen · [OUR-IDEA] · S

**Was sich ändert:** `U.SET_BONUS_COLOR` + `U.FormatSetBonus(sb, withBrackets)` in `util.lua`,
fünf Aufrufstellen darauf umbiegen. Plus `DiLvl:GetColor` in Grid2 implementieren.

**Evidenz — dieselben zwei Zahlen, vier verschiedene Darstellungen (selbst gegreppt):**

| Fläche | Datei:Zeile | Ausgabe |
|---|---|---|
| Details inline | `core.lua:411` | ` \|cFF00FF00[2P]\|r` |
| Details columns | `core.lua:549` | `\|cFF00FF002P\|r` — **ohne Klammern** |
| ElvUI | `elvui_tags.lua:57` | ` \|cFF00FF00[2P]\|r` |
| BlizzDM | `blizzdm.lua:350` | ` \|cFF00FF00[2P]\|r` |
| Grid2 | `grid2_status.lua:47` | ` 2P` — **ohne Klammern, ohne Grün** |

Wer Details-Columns + Danders parallel laufen hat, sieht zwei verschiedene Tier-Notationen
auf einem Bildschirm. Dazu kommt `blizzdm.lua:369`, eine Strip-Regex, die mit dem
Emittierten synchron bleiben muss und heute **nur** die geklammerte Form trifft — eine
stille Bruchstelle bei jeder künftigen Änderung.

**Grid2 ignoriert `db.colorIlvl` komplett.** Selbst nachgelesen, `grid2_status.lua:27`:
`DiLvl.GetColor = Grid2.statusLibrary.GetColor` — der Standard-Resolver, der `dbx.color1`
zurückgibt. `GetText` (`:40-49`) ruft `API.GetIlvlColor` nie auf. Der Master-Schalter
„Color by tier" auf dem General-Tab wirkt also auf **4 von 5** Kanälen. Für dich unsichtbar,
weil Grid2 *eine* Farbe zeigt — nur die falsche.

Fallback-Verhalten sauber halten: bei `colorIlvl = false` weiter durch den Library-Resolver,
damit die eigene Grid2-Farbwahl des Users gewinnt.

**Bloat-Risiko:** keins, Netto weniger Zeilen. Macht künftige Farb-/Notationsänderungen
zu einer Ein-Zeilen-Änderung statt zu einer Fünf-Datei-Jagd.

---

# 🕒 Worth doing later

### 6. Der Profion85-Kampf-Thread — mit Vorsicht · [USER-ASKED] · S · ⚠ erst in-game prüfen

Profion85, CurseForge, 2026-04-06, verbatim:
> „While I'm in combat the ilvl doesnt show up for any char in details, out of combat worked
> fine! **I tried the layout columns but still ilvl isnt visible.** Is thare an option to make
> ilvl visible in combat for all players in damage meter?"

Deine Antwort am selben Tag: *„That's a Blizzard API limitation unfortunately … No addon can
work around that … Nothing I can do on my end, sorry!"*

**Wichtige Korrektur an dem, was hier naheliegt.** Der Code sagt heute klar, dass Columns im
Kampf rendert — `core.lua:724` *„No combat guard: column FontStrings are addon-created, not
protected"*, `core.lua:867` *„Column mode: no combat guard needed"*, während Inline bei
`core.lua:804` und `:874` per `MayBeInCombat()` aussteigt. Es wäre also verlockend, ihm
einfach zu schreiben „geht doch".

**Tu das nicht ungeprüft** — er schreibt ausdrücklich, dass er Columns probiert hat und es
trotzdem leer blieb, und v1.2.0 war zu dem Zeitpunkt bereits live (belegt im Joster91-Thread
vom 2026-04-03: *„v1.2.0 is live now"*).

Die wahrscheinliche echte Erklärung ist feiner und ehrlicher: **Rendern** geht im Kampf,
**Beschaffen** nicht. `QueueGroupInspect` (`core.lua:1032`) und `ProcessNextInspect`
(`core.lua:985`) steigen beide bei `IsInCombatSafe()` sofort aus. Wer vor Kampfbeginn nicht
im Cache war, bleibt den ganzen Kampf leer — unabhängig vom Layout. Das ist übrigens genau
der Fall, den **Punkt 3** verbessert.

**Reihenfolge:** erst Punkt 3 bauen, dann 60 Sekunden in-game gegenprüfen, dann antworten —
und zwar mit der differenzierten Aussage („bereits erfasste Spieler bleiben im Columns-Layout
sichtbar; neu dazugekommene erst nach Kampfende"), nicht mit „geht jetzt".

---

### 7. Cell — als dokumentiertes Snippet, nicht als Modul · [USER-ASKED] · S (als Doku) / M (als Modul)

harrissx, 2026-04-24, hat Cell **namentlich** gefragt; du hast am 2026-04-26 öffentlich
zugesagt (*„Cell and Blizzard's default party/raid frames are on my radar"*). Grid2 und
Danders aus demselben Satz kamen binnen Tagen — Cell ist nach 3,5 Monaten offen (GitHub #25).
Cell hat 4,4 Mio. Downloads und **null** eigenen iLvl-Code.

Machbarkeit belegt: `Cell.RegisterCallback` (`Cell/Libs/CallbackHandler.lua:5`),
`Cell.unitButtons` (`Cell/RaidFrames/MainFrame.lua:7`), und der Autor sanktioniert
Erweiterungen ausdrücklich (`Cell/README.md:38-48`).

**Der schlanke Weg:** ~25-Zeilen-Snippet auf der CurseForge-Seite und im README, das aus
unserer bestehenden `Details_iLvlDisplayAPI` liest. **Null Zeilen im Addon.** Erst wenn es
Zuspruch findet, zum echten `cell_integration.lua` befördern.

⚠ **Caveat:** Unser lokaler Cell-Klon ist ein Classic-Checkout (nur Cata/Mists/TBC/Vanilla/
Wrath-TOCs, kein Retail-TOC). Vor der ersten Zeile den Retail-Branch ziehen und
`Cell.unitButtons` gegenprüfen.

**Bloat-Risiko:** als Snippet keins — und es etabliert das Muster für **jede** künftige
„unterstützt ihr Addon X?"-Anfrage: unsere API macht daraus 25 Zeilen bei jemand anderem
statt 300 bei uns.

---

### 8. Die öffentliche API dokumentieren, die es längst gibt · [OUR-IDEA] · S

`Details_iLvlDisplayAPI` existiert (`core.lua:2424`), ist stabil, fehler-isoliert, und unsere
eigenen Grid2-/ElvUI-Dateien konsumieren sie. Sie ist in **keiner** Doku erwähnt — verifiziert:
`grep -n "Details_iLvlDisplayAPI" README.md CURSEFORGE_DESCRIPTION.md` liefert **null Treffer**.

Ein README-Abschnitt (`GetCacheData`, `ResolveGUIDByName`, `GetIlvlColor`, `RegisterCallback`),
optional ein 6-Zeilen-Wrapper `GetIlvl(nameOrGuid)`, damit ein WeakAura ein Einzeiler wird.
Das ist der schlankeste Wachstumshebel überhaupt: mehr Reichweite ohne **einen einzigen**
neuen Toggle. Und es ist der einzige Weg zu WeakAuras (253 Mio.) und EllesmereUI, die beide
keine Frames exponieren, die wir hooken könnten.

---

### 9. LibOpenRaid-Bestand auslesen statt nur auf den Callback warten · [OUR-IDEA] · S

Wir registrieren `GearUpdate` und lesen daraus genau ein Feld — sehen also nur Gear-Daten,
die **nach** unserem Handler eintreffen. LoR hält einen vollen Store, den wir nie abfragen
(`GetAllUnitsGear` / `GetUnitGear`, `LibOpenRaid.lua:1762-1768`). Ein One-Shot-Sweep am Kopf
von `QueueGroupInspect` füllt bekannte Spieler sofort **und** verkürzt die Inspect-Queue für
die, die wirklich einen Inspect brauchen. Details! macht exakt dieses Muster bereits vor.

Zusätzliches Argument: `Details.track_item_level` ist per Default **`false`**
(`Details-Damage-Meter/functions/profiles.lua:946`) und der Scan ist auf Raid/Party-Zonen
begrenzt — unser Details-Fallback ist also schwächer, als das README suggeriert.

---

### 10. Issue-Hygiene · [OUR-IDEA] · S

#27 (Danders Textgröße, v1.4.4), #24 (Config UI, v1.5.0) und #30 (v1.5.2) sind ausgeliefert
und trotzdem OPEN. Das lässt uns langsamer aussehen, als wir sind — bei einem Addon, dessen
Changelog eigentlich beeindruckend schnell ist.

---

### 11. `UIDropDownMenu` → `WowStyle1DropdownTemplate` · [OUR-IDEA] · M

Zwei Gründe. **Deprecation:** Blizzard schreibt wörtlich, dass `UIDropDownMenu` veraltet ist
und **keine Shims** bereitgestellt werden (`Blizzard_Menu/11_0_0_MenuImplementationGuide.lua:4-6`).
**Optik, und die wiegt hier schwerer:** die Platte des alten Templates ist ein
`Interface\Glues\CharacterCreate`-Asset — ein verschnörkelter goldgerahmter Rahmen und damit
das stilistisch fremdeste Objekt in einem sonst flachen dunklen Fenster. Es taucht dreimal auf.

Netto verschwinden ~15 Zeilen manueller Sync-Code und `uniqueName()` wird löschbar.
**Aber:** einziger Punkt der Liste, der wirklich in-game getestet werden muss statt begutachtet —
daher bewusst nicht in „Do these next".

---

### 12. Stille Alterung der beiden Saison-Tabellen · [OUR-IDEA] · S

`GetIlvlColor` (280/268/255/242, `util.lua:18-22`) und `U.MIDNIGHT_TIER_SETS`
(`util.lua:44-58`) sind hartcodiert. Der Kommentar sagt selbst *„Update this table when a new
raid tier is added"*. Beim nächsten Tier kollabieren die Farben auf durchgehend Orange und
2P/4P verschwindet für **alle** — ohne Signal an dich oder den User. Ein Hinweis in
`/dilvl debug` („Tier-Tabelle Stand Midnight S1") kostet drei Zeilen und verhindert einen
stillen Totalausfall eines Kernfeatures.

---

# 🤔 Only if users ask

| Idee | Warum warten |
|---|---|
| **Blizzard Default-Raidframes** (#9) | Von harrissx mitgefragt, von dir zugesagt — aber die Taint-Oberfläche ist deutlich größer als bei Cell. Erst #25, dann das. |
| **Enchant-/Gem-Marker** | Einziges OiLvl-Feature, das billig und iLvl-nah wäre (LoR liefert `noEnchants`/`noGems` in der Tabelle, die wir schon empfangen). **Aber:** LoRs Test ist `nEnchantId < 6300` — eine Dragonflight-Konstante, die „kein Enchant" mit „veraltetes Enchant" verwechselt. Und **null** User haben je danach gefragt. Nur als *ein* Glyph, nie als Panel. |
| **Tooltip-Modus** (#8) | Für Details-Bars **erledigt durch Details selbst**: `Details:GetIlvl` läuft bereits im Bar-Hover-Tooltip (`frames/window_main.lua:2203/2258`). Nur der Welt-/Unit-Tooltip wäre echt neu — und die Anfrage kam aus dem WUI-Discord, nicht von unseren Usern. |
| **Outline-Toggle für unsere FontStrings** | Cell setzt Indikator-Fonts per Default auf „Outline", weil kleine Zahlen auf klassenfarbenen Balken sonst leiden — und unsere Farben kollidieren real: unser Rare-Blau `0070DD` ist **byte-identisch** mit der Schamanen-Klassenfarbe. Trotzdem: **niemand hat Lesbarkeit auf Bars gemeldet.** Prävention, kein Bug. Aufheben, bis es jemand meldet. |

---

# 🚫 Rejected as bloat

| Idee | Grund |
|---|---|
| **Raid Loot Summary** (#3) | Genau die Raid-Manager-Suite, die der Brief verbietet. Anderes Produkt. |
| **M+-Score / Spec-Anzeige / Gear-Reports per Whisper / Bag-iLvl** | Alles in OiLvl verifiziert vorhanden — und alles außerhalb von „iLvl neben einem Namen". Null Nachfrage bei uns. Das ist OiLvls Produkt, nicht unseres. |
| **Per-Channel-Font-Einstellungen** | Fünf Kanäle × Font × Größe × Outline = Optionsmatrix. Ein globaler Font. Punkt. |
| **VuhDo- / Plater- / EllesmereUI-Integration** | VuhDo hat keine Registrierungsfläche (nur flache `VUHDO_*`-Globals), EllesmereUI baut eigene Bars und wirbt selbst mit *„Zero Blizzard frame hooks"*, Plater hat zwar `InstallPlugin()` aber praktisch keinen Use Case für iLvl. Alle drei wären Namespace-Hacking. Stattdessen Punkt 8: die sollen zu **uns** kommen. |
| **Stale-Dimming / Alters-Indikator für Cache-Einträge** | Meine Idee, kein User-Wunsch. Fügt visuelles Rauschen und einen Zustand hinzu, den der User interpretieren muss. |
| **Mehr Login-Chat-Hinweise** | `ns.LOGIN_HINTS` (`init.lua:64`) feuert bereits gestaffelt in den Chat. Wenn überhaupt, gehören die in den What's-New-Tab, der v1.5.0 **genau dafür** gebaut wurde — Chat-Spam beim Login ist das Gegenteil von schlicht. |
| **Settings-Suche / Profile / Import-Export** | Für vier Tabs mit ~15 Controls ist das Infrastruktur ohne Problem. |

---

## Was diese Roadmap bewusst NICHT tut

Sie schlägt **kein einziges neues Subsystem** vor. Die „Do these next"-Fünf fügen unterm
Strich **eine** Einstellung hinzu (Font-Familie — und die ist die einzige unerfüllte Hälfte
einer echten User-Anfrage), löschen eine redundante Funktion, aktivieren drei bereits
geschriebene Design-Tokens und reparieren einen Datenpfad, den niemand melden kann, weil man
eine fehlende Zahl nicht als Bug erkennt.

Wenn nach v1.6 Zeit bleibt, ist der größte Hebel nicht Punkt 6–12, sondern **Punkt 8**:
die API dokumentieren und andere für uns integrieren lassen. Wir hängen an Addons mit
1000-facher Reichweite — der Engpass ist nicht die Zahl der Flächen, die wir selbst bedienen.

---

*Alle Datei:Zeile-Angaben wurden am 2026-08-08 gegen den lokalen Stand (TOC 1.5.3) direkt
verifiziert. CurseForge-Zitate stammen aus einem Live-Pull der Kommentar-API, nicht aus
Erinnerung. Für Reddit liegt keine Evidenz vor — die Quelle war nicht abrufbar.*

---

## Feature-Idee: alte vs. neue Season-Sets unterscheiden (Hasan, 2026-08-15)

**Wunsch:** Auf einen Blick sehen, ob jemand noch das *alte* Tier-Set trägt oder schon das aktuelle.

**Warum das billig ist:** Die Information liegt bereits vor, wir werfen sie nur weg.
`U.MIDNIGHT_TIER_SETS` ist schon nach Saison gruppiert (S1 = 1978–1990, S2 = 2055–2067),
speichert aber nur `true`.

**Umbau, rückwärtskompatibel:** `[id] = true` → `[id] = season` (Zahl). Alle fünf
Abfragestellen (`core.lua:2450`, `:2518`, `:2532`, `:2544`, `util.lua:179`) nutzen den
Wert ausschließlich als Wahrheitswert oder zählen Schlüssel — `1`/`2` sind in Lua wahr,
also **null Änderungen an den Aufrufern**. Danach kann `GetSetBonusForUnit` zusätzlich
die Saison zurückgeben (`bonus, complete, season`).

**Anzeige (offen, mit Hasan zu entscheiden):** eigener Marker (`[4P·S1]`) oder Farbe
(aktuell grün, alt grau/orange). Farbe ist platzsparender — die Bar-Breite ist auf
Details!-Zeilen knapp, und `FitNameText` im kommenden Details!-Rework kürzt zusätzlich.

**⚠ Falle, aus eigener Erfahrung:** „Aktuelle Saison = höchste bekannte ID" ist
**falsch**. Am 13.08.2026 lagen die S2-IDs bereits im Client, **bevor** die Saison
startete — Blizzard liefert die Item-Set-Tabelle mit dem Patch, nicht mit dem
Season-Start. Eine automatische Ableitung hätte die laufende Saison als „alt" markiert.
Also **explizite Konstante** `U.CURRENT_TIER_SEASON = 2`, die beim Season-Start
bewusst hochgezählt wird — dieselbe Pflege wie die Whitelist selbst.

**Mischfälle:** 2 Teile S1 + 2 Teile S2 ergeben heute korrekt „2P" (Boni stapeln nicht
über Sets hinweg, `best` nimmt das Maximum pro setID). Mit Saison-Info sollte der Marker
die Saison des Sets zeigen, das den Bonus liefert — nicht die des zuletzt gefundenen Teils.

### Entscheidung Hasan 2026-08-15: Farbe statt Suffix, und BEIDE Sets zeigen

Grau = altes Season-Set, Grün = aktuelles. Begründung von Hasan, und sie schlägt den
ursprünglichen Entwurf: Spieler steigen **stufenweise** um (2 alte + 2 neue Teile, dann
4 neue). In dieser Phase trägt man **zwei unvollständige Sets gleichzeitig**.

Der heutige Code zeigt nur `best` — das Maximum über alle setIDs — und damit erscheint
ein einzelnes `[2P]`, das nicht verrät, aus welchem Set es stammt oder dass daneben ein
zweites halbes Set liegt. Genau die Übergangsphase wird also unsichtbar.

**Ziel-Anzeige:** `[2P]` grau + `[2P]` grün = halb umgestiegen · nur `[4P]` grün = fertig.

**Folge für die Datenschicht:** `GetSetBonusForUnit` darf nicht länger einen einzelnen
String liefern, sondern die Zählung **pro Saison** (z.B. `{[1]=2, [2]=2}`). Der
`best`-Kollaps in util.lua entfällt bzw. wandert in die Anzeige.

**Palette passt bereits:** `9D9D9D` ist die unterste Stufe unserer iLvl-Farbskala und
liest sich schon als „veraltet". Keine Kollision, weil iLvl-Zahl und Set-Marker
getrennte Elemente sind.

**Offene Frage — Platz:** zwei Marker statt einem kosten Breite. Auf Details!-Zeilen ist
sie knapp, und der kommende Row-Text-Rework kürzt zusätzlich per `FitNameText`.
Kandidat für eine Regel: das alte Set nur zeigen, solange das aktuelle noch **kein** 4P
hat — dann kostet es nur während des Übergangs Platz und verschwindet, sobald man durch ist.
