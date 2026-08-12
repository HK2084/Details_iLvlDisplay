# Plugin-Architektur: "Wie bauen wir das Addon für die MEISTEN UIs?"

Synthese-Empfehlung, Stand 2026-08-12
Anlass: zweite EllesmereUI-Anfrage (aisenfaire, 2026-08-08, CurseForge) nach harrissx im Juni.
Grundlage: vier Code-Lenses gegen die lokalen Clones, plus eigene Nachprüfung der Kernstellen in `core.lua`.

---

## ⚠ ERRATA (2026-08-12, nach adversarialem Faktencheck)

Ein Refute-first-Check über die tragenden Behauptungen hat mehrere Stellen dieses Dokuments widerlegt oder
abgeschwächt. **Die Grundempfehlung bleibt gültig** — die Belege dafür sind teils schwächer als hier
behauptet. Was unten im Fließtext steht, gilt nur mit diesen Korrekturen:

| Stelle | Behauptet | Tatsächlich |
|---|---|---|
| §1, Z. 32 | „Diese eine fehlende Information kostet uns rund 1500 Zeilen" | **Falsch.** Identitätsauflösung in `blizzdm.lua` ≈ **225 Zeilen (13,9 %)** + 59 in `core.lua`. Größter Block ist **Diagnostik: 415 Zeilen (26 %)**, davon `GetBlizzDMDebug` allein 245. |
| §1, Z. 30 | „Die einzige Variable ist, wer den Vertrag besitzt und wer Identität auflöst" | **Zwei** Variablen. Danders bekommt Identität frei Haus (`danders_integration.lua:178` `frame.unit`) und kostet trotzdem 363 Zeilen — Rendering-Ownership ist der zweite Kostentreiber. |
| Titel/§0 | „Push statt Pull" | **Vertauscht.** Grid2 (`grid2_status.lua:39`) und ElvUI (`elvui_tags.lua:63`) **ziehen** von uns. Der echte Push ist `blizzdm.lua` (`hooksecurefunc` + `nameFS:SetText`). Richtiger Titel: **„Provider, not frame-walking"**. |
| Faktor 12,3 | als Architektur-Gesetz | Zahlen stimmen (72/89/363/1622, reproduziert), aber brutto 12,3 vs. netto 16,9 — **eine** Messreihe nennen und benennen. Außerdem sind 86 der 1622 Zeilen der Taint-Selbsttest vom 08.08., vier Tage vor diesem Dokument. |
| §2, Z. 42 | „23.244 Installs" | CurseForge misst **Downloads**, nicht Installs: „~23,3 K Downloads (CurseForge, abgerufen 12.08.2026)". |
| §Cell, Z. 174 | „4.472.226 vs 2.752.084" | „~4,47 Mio. vs ~2,78 Mio. (CurseForge, 12.08.2026)". Kumulative Downloads taugen **nicht** als Priorisierung — Cell aggregiert Retail + fünf Classic-Flavours, unser TOC ist retail-only. |
| §Cell, Z. 174/200/231 | Cell-Kanal „80–120 Zeilen" | **~220–280 Codezeilen.** Falsche Vergleichsklasse: ElvUI/Grid2 sind klein, weil der Host ein Text-Tag-System hat. Cell hat keine Third-Party-Text-API → Danders-Klasse. |
| §Cell, Z. 200/235 | „unser Clone ist Classic-only" | **Falsch.** `Cell/Cell_Deprecated.toc:1` = `## Interface: 120005` (Retail) und lädt `RaidFrames/UnitButton.lua`. Der Clone ist als Retail-Quelle brauchbar. |
| Zitat | `Cell/RaidFrames/UnitButton.lua:2154` als Beleg für `states.guid` | Dort steht `local unit = self.states.unit`. **Zitat streichen** — `:1700` und `:1984` sind verbatim korrekt. |
| §Cell | „`b.states.guid` liefert Identität frei Haus" | Kann **secret** sein; Cell guardet selbst (`UnitButton.lua:2167`, „Midnight 12.0.0+: guid may be secret"). Ein Cell-Kanal muss durch `API.SafeUnitGUID`. |
| §API | „unsere fünf Kanäle" (Registry) | **Vier** registrieren: `elvui`, `grid2`, `blizzdm`, `danders`. Der Details!-Bar-Kanal läuft direkt in `core.lua` und registriert nie. |
| §API | Konsumenten = vier Dateien | **Fünf**: dazu `core.lua:1925-1926`, das `GetBlizzDMDebug` liest — von `blizzdm.lua:1356` **von außen** an die öffentliche Tabelle geschraubt. Zweites Ownership-Loch, das v1.6 mitdenken muss. |
| §API | `RegisterCallback` bei `core.lua:2504` | Zuweisung steht auf **:2505**; :2504 ist der Funktionskopf. Die Funktion resettet zusätzlich die Fehlerzähler (:2510-2511) → ein Squatter löscht auch das Fehlerbudget. |
| §API | „gibt Cache-Subtabellen zurück" | Präziser: Rückgabe **1** (`ilvlCache[guid]`) ist eine Live-Referenz in `db.ilvlCache` → persistiert. Rückgabe **2** ist ein Skalar, nicht mutierbar. |
| §API-Defekt 1 | „secret values are truthy **userdata**" | **Falsch.** Ein Secret behält seinen Lua-Typ (secret GUID = weiterhin `string`), es liest sich nur nie als nil/false. Beleg: `Blizzard_SharedXML/Dump.lua:98-113`. Im Addon-Code am 12.08. an vier Stellen korrigiert. |

**Zusätzlich in den v1.6-Scope aufgenommen** (im Dokument noch nicht enthalten): `util.lua:18` —
`GetIlvlColor(nil)` wirft und ist ungewrappt öffentlich re-exportiert (`core.lua:2498`); `fn = nil` als
stilles Unregister; der Fehlerbudget-Reset.

**Strategisch offen:** Cells **Retail-Linie ruht**. Letzter retail-getaggter CurseForge-Build: r274
(22.01.2026); im HEAD-Commit `c9490c5d` (07.08.2026) wurde `Cell.toc` → `Cell_Deprecated.toc` umbenannt.
Ein öffentliches Statement des Autors gibt es nicht — nur diese Packaging-Fakten, keine Absicht unterstellt.
**v1.7 ist damit keine Umsetzungs-, sondern eine Grundsatzfrage.**

**Zitier-Regel für die Zukunft:** Jede `core.lua:NNNN`-Angabe muss die Top-Level-Datei meinen —
`.release/Details_iLvlDisplay/` ist eine veraltete v1.1.0-Kopie, in der die API-Tabelle auf Zeile 1061
statt 2424 liegt. In diesem Dokument traten zwei „fabricated-by-location"-Zitate auf (oUF innerhalb
EllesmereUI — dort liegt oUF gar nicht; und Cell `:2154`). Fundstelle immer selbst öffnen.

---

## 0. Die Antwort in drei Sätzen

Wir bauen das Addon **nicht** für die meisten UIs, sondern wir machen es so, dass die meisten UIs es **bei uns abholen können**.
Konkret: `Details_iLvlDisplayAPI` bekommt eine schmale, versionierte, dokumentierte v1-Fassade (rund 70 Zeilen, additiv, null neue Settings) und wird auf CurseForge/README als Datenquelle beworben; unsere fünf eigenen Kanäle bleiben, werden aber schrittweise selbst zu Consumern derselben API.
Neue Kanäle bauen wir nur noch dort, wo der Host uns **Identität** (GUID oder Unit-Token) frei Haus liefert — genau das ist der Unterschied zwischen 72 Zeilen (Grid2) und 1622 Zeilen (Blizzard DM).

---

## 1. Die Kernentscheidung: Push, nicht Pull

### Die Zahl, die die Entscheidung trägt

Der Beweis steht in unserem eigenen Repo, nicht in einer Analogie. Gemessene Dateigrößen (verifiziert 2026-08-12, `wc -l`):

| Kanal | Zeilen | Wer besitzt den Vertrag? |
|---|---:|---|
| `grid2_status.lua` | 72 | Host (Grid2 Status-API) |
| `elvui_tags.lua` | 89 | Host (oUF Tag-API) |
| `danders_integration.lua` | 363 | Host-API vorhanden, aber wir besitzen das Rendering |
| `blizzdm.lua` | 1622 | Wir (Reverse-Engineering + Name→GUID) |

**161 Zeilen gegen 1985 Zeilen — Faktor 12,3.** Gleiche Daten, gleicher Cache, gleicher Autor. Die einzige Variable ist, wer den Vertrag besitzt und wer die Spieler-Identität auflöst.

Und die Ursache ist präzise benennbar: Grid2 und ElvUI geben uns ein **Unit-Token**, Cell gäbe uns `b.states.guid`. Blizzard DM gibt uns einen **Anzeigenamen** — deshalb existiert `ResolveGUIDByName` mit Roster-Scan, `Ambiguate`, Cross-Realm-Fallback und Fuzzy-Match auf den bloßen Namen (`core.lua:2437-2500`, selbst nachgelesen). Diese eine fehlende Information kostet uns rund 1500 Zeilen.

### Wir sind bereits Push — wir haben es nur nie ausgesprochen

Grid2 exponiert exakt drei Symbole (`Grid2.statusPrototype`, `Grid2.setupFunc`, `Grid2:RegisterStatus`) und rendert selbst. ElvUI exponiert `E:AddTag` und rendert selbst. In beiden Fällen liefern wir eine Zahl und einen String, und der Host macht den Rest. Das ist bereits das Provider-Modell — nur in der falschen Richtung dokumentiert: wir konsumieren fremde Verträge, veröffentlichen aber unseren eigenen nicht.

Dass unser eigener Vertrag schon die richtige Form hat, ist ebenfalls belegbar: LibOpenRaid — die Bibliothek, die wir bereits konsumieren — besteht aus genau zwei Hälften, einem Getter mit dokumentiertem Struct (`GetUnitGear(unitId)`) und einem Event (`RegisterCallback(obj, "GearUpdate", handler)`). Unsere API hat beide Hälften bereits: `GetCacheData(guid)` und den `NotifyElvUI`-Dispatch mit `RegisterCallback`. Wir stehen also schon auf beiden Seiten desselben Vertragsmusters.

### Warum Pull als Primärstrategie scheitert

1. **Rechnerisch.** Wir haben 23.244 Installs. Die Hosts, die wir bedienen wollen, haben das 100- bis 15.000-fache. Jeder neue Pull-Kanal kostet uns 100 bis 1600 Zeilen dauerhafter Wartung gegen genau ein Ziel — und jedes Ziel kann sich jederzeit ändern.
2. **Empirisch.** Bei EllesmereUIs Damage Meter ist Pull nicht nur teuer, sondern **falsch**: derselbe Row-Pool wird für den Spell-Breakdown wiederverwendet (`EllesmereUIDamageMeters.lua:3810`), und der Zustand `W.curDMType` liegt im privaten `ns`. Ein Frame-Walk würde ein Item Level neben *"-3.2s Fireball"* stempeln. Das ist ein Korrektheitsfehler, nicht nur ein Etikettenverstoß.
3. **Strukturell.** Zwei der Oberflächen mit der größten Reichweite — WeakAuras und Cell-Snippets — sind per Frame-Hooking **überhaupt nicht** erreichbar. Sie sind nur erreichbar, wenn wir etwas veröffentlichen, das der Nutzer aufrufen kann.

### Die Entscheidung

> **Details_iLvlDisplay ist primär eine Datenquelle mit dokumentiertem, versioniertem Vertrag. Eigene Kanäle sind Referenz-Implementierungen dieses Vertrags, keine Produktstrategie.**

Neue Kanäle bauen wir nur, wenn drei Bedingungen zugleich gelten: (a) der Host liefert Identität als GUID oder Unit-Token, (b) es gibt eine öffentliche/dokumentierte Oberfläche, (c) der Kanal bleibt unter ~150 Zeilen. Sonst gilt: API dokumentieren, Snippet liefern, oder upstream fragen.

### Was wir bewusst nicht wählen (die verlockende Alternative)

Die zweite denkbare Architektur ist das **Masque-Modell**: `DiLvl:NewGroup("EllesmereUI","DamageMeter")` + `g:AddLabel(frame, {resolve = fn})` — der Fremdautor übergibt uns sein Widget, wir besitzen FontString, Refresh, Farbe, Secret-Defense und Teardown. Drei Zeilen für den Partner, maximal bequem.

Wir tun es trotzdem nicht, und der Grund steht in unserem eigenen Code: `danders_integration.lua` **ist** diese Engine bereits (`ensureFS`, `applyAnchor`, `updateFrame`, `refreshAll`) — und ein einziger Host hat dafür 363 Zeilen, 13 Anker-Positionen und einen eigenen Font-Size-Slash-Befehl gekostet. Mit N Hosts erbt jeder Host seine eigenen Anker- und Größen-Präferenzen. Das ist exakt die "Settings-Seite pro Integration", die als schlechte Architektur ausgeschlossen wurde. Zweitens: ein öffentliches `AddLabel` bedeutet, dass fremde Addons uns beliebige Frames reichen — inklusive geschützter — und wir uns Combat-/Taint-Exposure auf Frames einhandeln, die wir nicht kontrollieren.

---

## 2. Die Ziel-Architektur

### Prinzip: additive Fassade, kein Umbau

Alles, was heute auf `Details_iLvlDisplayAPI` liegt, bleibt **byteidentisch** und wird als INTERNAL dokumentiert ("kann sich ohne Ankündigung ändern"). Unsere vier internen Consumer (`blizzdm.lua:25`, `elvui_tags.lua:28`, `grid2_status.lua:22`, `danders_integration.lua:47` — verifiziert, es sind genau diese vier) binden weiter die internen Felder und werden zunächst **nicht angefasst**. Null Regressionsrisiko am laufenden Betrieb.

Die v1-Fassade wird darunter angehängt.

### Drei Defekte, die vor der Veröffentlichung repariert werden müssen

Alle drei selbst im Code nachgeprüft:

1. **Der Getter wirft.** `GetCacheData` prüft `if not guid or not ilvlCache` (`core.lua:2428`) — ein Secret Value ist truthy Userdata, rutscht durch und lässt `ilvlCache[guid]` mit *"attempt to use a secret value as a table key"* fliegen. Unser eigener Code weiß das bereits und filtert vor (`danders_integration.lua:180-184`). Ein Fremdentwickler schreibt aber das Naheliegende, `API.GetCacheData(UnitGUID(unit))`, und bekommt einen Fehler **aus unserer Funktion mit unserem Namen im BugSack**. Gleiche Klasse: `GetIlvlColor(nil)` wirft, weil `util.lua:18` direkt `if ilvl >= 280` vergleicht.
2. **Der Callback-Namespace kollidiert.** `RegisterCallback = function(self, name, fn) self._callbacks[name] = fn end` ist ein blanker Überschreib-Vorgang ohne Ownership-Prüfung (`core.lua:2504`). Sobald die API öffentlich ist, killt ein WeakAura, das sich als `"elvui"` registriert, **stillschweigend unseren ElvUI-Kanal**. Jedes untersuchte Vorbild vermeidet das: LibOpenRaid keyt auf `(addonObject, memberName)`, CallbackHandler-1.0 auf ein Self-Token, Cell auf `(eventName, funcName)`.
3. **`GetDb()` gibt die lebende SavedVariables-Tabelle heraus** (`core.lua:2500`). Für unsere Sub-Dateien korrekt, für Dritte inakzeptabel — jeder Consumer könnte unsere Settings schreiben, inklusive der Kill-Switches anderer Kanäle. Ebenso gibt `GetCacheData` die Cache-Sub-Tabellen **per Referenz** zurück; ein `entry.time = 0` ("Refresh erzwingen") schreibt in SavedVariables und persistiert auf Platte.

Nicht anfassen: die Fault-Isolation in `NotifyElvUI` (`core.lua:2546-2574`) ist genau die Disziplin, die ein öffentlicher Event-Bus braucht — pcall pro Consumer, erster Fehler über `geterrorhandler()`, Auto-Unregister nach 5 Fehlern, Counter-Reset bei Erfolg. Die wird gespiegelt, nicht ersetzt.

### Die Signaturen (Public API v1)

```lua
---------------------------------------------------------------
-- PUBLIC API v1 - additive Fassade. Alles OBERHALB ist INTERNAL:
-- unsere eigenen Integrationsdateien binden es direkt, es kann sich
-- jederzeit aendern. Dritte benutzen ausschliesslich das Folgende.
---------------------------------------------------------------
API.VERSION       = 1            -- Integer, wird NUR bei Breaking Change erhoeht
API.ADDON_VERSION = ns.version   -- z.B. "1.6.0"
API.CAPS = { getIlvl = true, format = true, subscribe = true, resolveName = true }
-- Feature-Detection immer ueber CAPS, nie ueber VERSION.
-- Neue Funktion => neuer CAPS-Key, VERSION bleibt 1.

--- true, sobald der Cache verdrahtet ist (nach ADDON_LOADED).
function API.IsReady() end

--- Gecachtes Item Level + Tier-Bonus. Wirft NIE. Gibt NIE ein Secret zurueck.
--- @param who string  Unit-Token ("party1") | Name ("Ragnar-Blackmoore") | GUID
--- @return number|nil ilvl, string|nil tier ("2P"/"4P"), number|nil ageSeconds
function API.GetIlvl(who) end

--- Farb-Escape fuer ein iLvl, "" wenn unbekannt. Wirft nie.
--- @return string  z.B. "|cFFA335EE"
function API.GetColor(ilvl) end

--- Exakt der String, den wir selbst rendern wuerden. Gibt immer einen String zurueck.
--- @param opts table|nil {color=bool, brackets=bool, tier=bool}
---        fehlende Keys folgen den User-Settings
function API.Format(ilvl, tier, opts) end

--- Change-Notification. EIGENE Registry, getrennt von _callbacks -
--- ein Dritter kann "blizzdm"/"elvui"/"grid2"/"danders" nicht ueberschreiben.
--- @param id string    eindeutig; Konvention "AddonName" oder "AddonName:feature"
--- @param fn function  fn("DILVL_UPDATE", { name=, guid=, reason= })
---        reason in "inspect"|"self"|"lor"|"roster"|"settings"
--- @return boolean ok, string|nil err  -- false, wenn id bereits vergeben
---         (ablehnen statt still ueberschreiben - der Unterschied zu RegisterCallback)
function API.Subscribe(id, fn) end
function API.Unsubscribe(id) end
```

Implementierungs-Kernpunkte:

* `GetIlvl` akzeptiert Unit-Token, Namen und GUID, prüft `isSecretValue` **vor** jedem Tabellenzugriff, läuft komplett in einem `pcall` und gibt **Skalar-Kopien** zurück — nie die Cache-Tabelle.
* `Format` ist die einzige Stelle, an der das Aussehen definiert wird. Heute ist dieselbe Logik viermal handgeschrieben (`blizzdm.lua:340-351`, `elvui_tags.lua:46-58`, `grid2_status.lua:46-49`, `danders_integration.lua:191-193`) — mit vier leicht unterschiedlichen Ergebnissen; bei Danders wird die Farbe **nach** dem Tier-Suffix angewendet, färbt also den Tier-Text mit. Das ist ein realer Inkonsistenz-Bug, den die Zentralisierung nebenbei behebt.
* Einzige Änderung an bestehendem Code: in `NotifyElvUI` bleibt die vorhandene `_callbacks`-Schleife unverändert; darunter kommt eine zweite Schleife über `API._subs` mit eigenen Fehlerzählern nach demselben Muster. Optional ein `reason`-String als zweites Argument an den 9 Fire-Stellen — rein additiv, der Code dokumentiert bereits, dass bestehende Subscriber zusätzliche Argumente stillschweigend ignorieren.

### Dogfooding

Nach v1 wandern unsere eigenen Kanäle **schrittweise** auf `API.Format` und `API.Subscribe` — beginnend mit den beiden billigsten (ElvUI, Grid2), wo ein Fehler sofort sichtbar und der Rollback trivial ist. `blizzdm.lua` bleibt vorerst auf den internen Feldern; es ist die komplexeste Datei mit dem größten Taint-Risiko und hat keinen Nutzen von der Fassade außer Konsistenz. Dogfooding ist Mittel zum Zweck (der Vertrag wird dadurch nachweislich benutzbar), nicht Selbstzweck.

### Consumer-Beispiel (das, was in die README kommt)

```lua
-- Beliebiges Addon / WeakAura / Cell-Snippet
local API = _G.Details_iLvlDisplayAPI
if not (API and API.CAPS and API.CAPS.getIlvl) then return end  -- weich degradieren

local function Decorate(frame, unit)
    local ilvl, tier = API.GetIlvl(unit)          -- wirft nie, nil wenn unbekannt
    frame.myText:SetText(API.Format(ilvl, tier))  -- "" wenn ilvl nil
end

API.Subscribe("MyUI:ilvl", function(_, info)
    -- info.guid / info.name / info.reason ; einfach neu zeichnen
    RefreshMyFrames()
end)
```

Für Cell reduziert sich das auf ein vom **Nutzer** eingefügtes Snippet (Cell besitzt einen offiziellen Code-Snippet-Runner, `Cell/README.md:38-48`) — null Zeilen von uns, null Zeilen vom Cell-Autor.

---

## 3. Was das für die konkreten Anfragen bedeutet

### EllesmereUI (2 Nutzer) — die Antwort ist jetzt "teilweise ja, sofort"

Die alte Notiz vom 14.06. muss in zwei Punkten korrigiert werden, bevor irgendwer sie upstream zitiert:

* **Falsch war:** "Window-Frames sind nil-benannt". `_G.EllesmereUIDMFrame1..5` existieren seit Release v7.5.5 (2026-05-07), also schon vor unserer Prüfung (`EllesmereUIDamageMeters.lua:2368`).
* **Richtig bleibt:** die Rows sind anonym, und es gibt **keinen Rückverweis vom Frame auf die Datentabelle** (`bar._src`/`bar._srcGUID` liegen auf der Lua-Tabelle, `bar.row` ist nur das Frame). Dazu kommen zwei neue, stärkere Blocker: der geteilte Row-Pool (Spell-Breakdown, s.o.) und die Tatsache, dass Blizzard `name` in `DamageMeterCombatSource` als `ConditionalSecret` markiert, während `sourceGUID` und `classFilename` sauber sind (`DamageMeterDocumentation.lua:199-201`).

Der Damage Meter bleibt also blockiert. **Aber zwei andere EllesmereUI-Oberflächen sind heute schon offen — ohne jede Upstream-Kooperation:**

* **Unit Frames laufen auf unverändertem Standard-oUF.** `EllesmereUIUnitFrames.toc:11` deklariert `## X-oUF: EllesmereUF`, und `.pkgmeta` zieht oUF unverändert von upstream. oUFs eigener Vertrag exportiert daraufhin `_G[global] = oUF` (`oUF/ouf.lua:1093-1099`), also existiert **`_G.EllesmereUF` als dokumentierte, öffentliche oUF-Instanz** mit `oUF.objects` — jedes Frame trägt `.unit`. Das ist exakt unser Danders-Muster, nur auf einem dokumentierten öffentlichen Array. Einschränkung: der reine Tag-Weg funktioniert nicht, weil Tag-Strings aus einem festen Dropdown-Enum kommen — der Nutzer kann `[dilvl]` nicht eintippen. Es braucht also den FontString-Overlay.
* **Raid Frames über Blizzards eigenen Vertrag.** Benannte Secure Header `ERFGroupHeader1..8`, `ERFFlatHeader`, `ERFPartyHeader`, plus `_G.EllesmereUIRaidFrames`; die Unit kommt über das Standard-`button:GetAttribute("unit")`.

Und es gibt keine Konkurrenz-Funktion: EllesmereUI zeigt Item Level nur im Charakterfenster und in Taschen, nirgends auf Unit-/Raid-Frames.

**Timing-Falle:** `.github/CONTRIBUTING.md` (committed 2026-08-07, einen Tag vor aisenfaires Anfrage) sagt: *"FEATURE REQUESTS ARE TEMPORARILY HALTED. ONLY BUG FIXES WILL BE ACCEPTED UNTIL A FEW WEEKS AFTER 12.1 LAUNCH"* und verweist für größere Features explizit auf Discord-DM vor dem PR. Ein Issue heute wird auf Policy geschlossen und verbrennt die Anfrage. Also: **jetzt kein Issue.** Nach 12.1 ein Discord-DM, danach ein PR mit einem Hook, der `sourceGUID` + `classFilename` übergibt (nie `name`), ohne Tabellen-Allokation pro Frame, und mit `nil`, wenn die Row gerade keinen Spieler zeigt.

Antwort an aisenfaire/harrissx: nicht "geht nicht", sondern "der Damage Meter geht aus einem konkreten technischen Grund nicht, Unit- und Raid-Frames kommen — und für den Meter frage ich nach 12.1 beim Autor an."

### Cell — der eigentliche Gewinner

Cell hat 4.472.226 Downloads gegen EllesmereUIs 2.752.084, ist vollständig global (`_G.Cell`), hat eine Callback-Registry, und — entscheidend — reicht uns `b.states.guid` direkt (`RaidFrames/UnitButton.lua:1700,1984,2154`). Damit entfällt die gesamte Name-Auflösungs-Kostenklasse; Cell landet in der 80-120-Zeilen-Klasse, nicht in der 363er. Cell hat außerdem **keinen eigenen iLvl-Code**, kollidiert also nicht. Zusätzlich existiert der Snippet-Runner, über den Nutzer die Integration auch ohne uns bauen können, sobald die API dokumentiert ist.

Hinweis zur Zuordnung: die Vorlage weist die Cell-Anfrage harrissx zu, das Juni-Zitat aus dem Briefing weist harrissx dagegen EllesmereUI zu. Ich konnte die CurseForge-Kommentare nicht selbst einsehen — bitte vor einer öffentlichen Antwort kurz prüfen, wer was gefragt hat.

### Jede künftige "Can you support X?"-Anfrage

Die Antwort wird zu einer von drei Standard-Antworten:

1. **"Hier ist das Snippet"** — Host hat Snippet-/Custom-Code-Fähigkeit (Cell, WeakAuras, Plater). Aufwand: null.
2. **"Frag deinen UI-Autor, er soll `Details_iLvlDisplayAPI` aufrufen"** — mit Link auf die README-Doku und dem 8-Zeilen-Beispiel. Aufwand: null.
3. **"Ich baue es"** — nur wenn Identität frei Haus kommt, Oberfläche öffentlich ist und der Kanal unter ~150 Zeilen bleibt.

Der beste Hebel für Fall 2 ist `DandersFrames/API.lua`: eine einzige Datei mit `DandersFrames_IsReady()`, `DandersFrames_GetFrameForUnit(unit)`, `DandersFrames_IterateFrames(callback)` plus ein CallbackHandler-Event — kein einziges Interna nach außen. Das ist der Präzedenzfall, den man einem fremden Autor zeigt, statt einen abstrakten Gefallen zu erbitten.

---

## 4. Reihenfolge

**v1.6 — "Publish the contract" (klein, kein neuer Kanal)**
1. v1-Fassade in `core.lua` anhängen: `VERSION`, `ADDON_VERSION`, `CAPS`, `IsReady`, `GetIlvl`, `GetColor`, `Format`, `Subscribe`/`Unsubscribe`. Rund 70 Zeilen, additiv.
2. Zweite Dispatch-Schleife über `API._subs` in `NotifyElvUI`, mit eigenen Fehlerzählern nach dem bestehenden Muster. Bestehende Schleife unverändert.
3. `GetDb` und `_callbacks` als INTERNAL kennzeichnen; `GetBlizzDMDebug` als Diagnostik markieren (9 unbenannte Rückgabewerte sind keine API).
4. README-Abschnitt "For UI authors" + kurzer Block in `CURSEFORGE_DESCRIPTION.md`. Heute steht dort **null** — verifiziert: `Details_iLvlDisplayAPI` kommt in beiden Dateien 0-mal vor.
5. Antwort an aisenfaire und harrissx.

**v1.7 — Cell-Kanal + erstes Dogfooding**
6. Cell-Kanal (~80-120 Zeilen) über `Cell.unitButtons` + `Cell.RegisterCallback`, Identität aus `states.guid`. Vorher die Retail-Variante lokal ziehen (unser Clone ist Classic-only).
7. Fertiges Cell-Snippet in die Doku, damit die Integration auch ohne Update funktioniert.
8. `elvui_tags.lua` und `grid2_status.lua` auf `API.Format` umstellen — die zwei billigsten und am leichtesten zurückrollbaren Kanäle.

**v1.8 — EllesmereUI, ohne Upstream**
9. Overlay-Kanal auf `_G.EllesmereUF.objects` (Unit Frames), Reuse der Danders-Overlay-Engine, aber **ohne** neue Anker-/Größen-Settings — feste Standardposition, ein Kill-Switch wie überall.
10. Optional Raid Frames über die benannten Secure Header, wenn 9 sauber läuft.

**Parallel/später, nicht terminiert**
11. Nach 12.1: Discord-DM an Ellesmere, danach PR mit `RegisterDamageMeterRowDecorator`.
12. Tooltip-Kanal (~30-50 Zeilen). `TooltipDataProcessor.AddTooltipPostCall` ist eine echte Erweiterungsstelle mit eingebauter Taint-Firewall — Blizzard ruft `forceinsecure()` auf Addon-Callbacks (`TooltipDataHandler.lua:181-199`). Andere Risikoklasse als Raid-Frames, aber trotzdem neue Oberfläche und damit erst nach dem Kern.
13. `blizzdm.lua` auf die Fassade migrieren — nur wenn es einen konkreten Nutzen gibt.

---

## 5. Was wir bewusst NICHT tun

* **Kein Frame-Walking in EllesmereUIs Damage Meter.** Nicht (nur) wegen der Hausregel, sondern weil es nachweislich **falsche Ausgaben** produziert: der Row-Pool wird für Spell-Rows wiederverwendet, und der einzige frame-erreichbare Identitätsträger ist ein realm-gestrippter, secret-abgeleiteter Anzeigename.
* **Kein Masque-Modell (`AddLabel(frame, ...)`).** Es ist die bequemste Variante für Partner und die teuerste für uns: Anker- und Größen-Settings pro Host, plus Taint-/Combat-Exposure auf fremden, möglicherweise geschützten Frames und starke Referenzen auf fremde Frames in unserer Tabelle. Falls es je gebaut wird: Anker wird vom Host pro Aufruf übergeben und von uns **nie** persistiert.
* **Kein LibDataBroker als Transport.** Die Vertragsphilosophie ist richtig, das Datenmodell nicht: LDB ist ein Singleton-Vertrag (ein Broker = ein Anzeigeobjekt). 40 Raid-Mitglieder wären 40 Broker oder ein Text-Blob. Philosophie übernehmen, eigene Per-GUID-Tabelle behalten.
* **Kein `InstallPlugin`-Zeremoniell à la Details!/Plater.** Neun positionale Parameter, Icon, SavedVariables-Tabelle, Version-Gate — korrekt für einen Host, der Fenster und Config-Panels vergibt. Wir vergeben eine Zahl und einen String.
* **Keine Settings-Seite pro Integration.** v1 führt **null** neue persistierte Settings ein. Die bestehenden Per-Kanal-Kill-Switches reichen.
* **Kein LFG-Bewerberlisten-Kanal.** Blizzard liefert das bereits nativ: `C_LFGList.GetApplicantMemberInfo` gibt `itemLevel` als fünften Rückgabewert zurück und die Row rendert es (`LFGList.lua:1890, 1934`). Wir würden ein Blizzard-Feature duplizieren, über einen Datenpfad, der mit unserer Engine nichts teilt.
* **Keine Blizzard-Standard-Raidframes.** Bleibt zurückgestellt (`ROADMAP_RESEARCH_2026-08-08.md:368`): `SecureUnitButton_OnLoad` macht die Frames attribut-getrieben und secure, die Taint-Oberfläche ist deutlich größer als bei Cell. Erst Cell, dann neu bewerten.
* **Kein Umbau der bestehenden `_callbacks`-Registry.** Fünf Kanäle hängen daran. Die neue Registry kommt daneben, nicht darüber. Fault-Isolation und Secret-Defense bleiben unangetastet.
* **Kein GitHub-Issue bei EllesmereUI vor 12.1.** Feature-Requests sind per Policy eingefroren; ein Issue jetzt wird geschlossen und verbrennt den Anlauf.

---

## 6. Ehrlichkeit: Aufwand und Unsicherheiten

**Aufwand, realistisch.** v1.6 ist ein Arbeitstag Code plus ein halber Tag Doku und Test — die Fassade ist klein, aber `GetIlvl` muss gegen Secret Values, Unit-Token, Namen und GUIDs geprüft werden, und das braucht In-Game-Tests. v1.7 (Cell) sind 80-120 Zeilen **nur, wenn** `states.guid` sich im Retail-Zweig so verhält wie gelesen. v1.8 (EllesmereUI oUF) schätze ich auf 120-180 Zeilen, weil die Overlay-Engine wiederverwendbar ist — mit Risiko nach oben, falls EllesmereUI seine Frames anders recycelt als Danders.

**Was nicht verifiziert ist:**
* **Kein einziger der neuen Kanäle wurde in-game getestet.** Alle Aussagen sind Quellcode-Lesungen. Statische Symbole beweisen Erreichbarkeit, nicht Laufzeitverhalten (Recycling, Timing, Kampf-Restriktionen).
* **Cells Retail-Zweig** wurde nur über GitHub `master` im Web geprüft, weil unser lokaler Clone Classic-only ist (keine Retail-TOC). Vor Baubeginn den Retail-Zweig lokal ziehen.
* **ElvUIs Install-Basis ist nicht verifizierbar** — ElvUI ist nicht auf CurseForge, sondern self-hosted. Ich habe keine Zahl geschätzt.
* **Alle Download-Zahlen sind kumulativ über Jahre und Spielvarianten** und überschätzen aktive Installs systematisch. Recounts 121 Mio. sind historisch, letzter Retail-Build 11.1.7a (2025-07-10). Nur als Größenordnungs-Ranking benutzen.
* **Zeilenzahlen:** hier durchgehend Gesamtzeilen (`wc -l`, selbst nachgemessen: 72 / 89 / 363 / 1622). Eine der Lenses hat Netto-Codezeilen ohne Kommentare gezählt (40 / 40 / 220 / 1131). Beide Messreihen zeigen dasselbe Verhältnis; nicht mischen.
* **Zuordnung der Cell-Anfrage zu harrissx** konnte ich nicht gegen CurseForge prüfen (siehe oben).

**Der Grund, warum dieser Weg auch dann richtig ist, wenn die Schätzungen daneben liegen:** Die beiden reichweitenstärksten Oberflächen, die wir nicht bauen können — WeakAuras und der Cell-Snippet-Runner — werden ausschließlich dadurch erreichbar, dass wir die API veröffentlichen, die seit Version 1.x ungenutzt in `core.lua` liegt. Das ist der billigste Schritt im ganzen Plan und der einzige, der ohne fremde Zustimmung Reichweite erzeugt.
