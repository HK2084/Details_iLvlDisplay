# Code Review — Details_iLvlDisplay v1.5.3 (working tree, HEAD 691720a)

**Datum:** 2026-08-12 · **Client:** 12.1.0.69273 (heute live) · **Umfang:** 5 Lenses (Correctness, 12.1-Readiness, Peer-Patterns, Performance, Robustheit) + adversarielle Gegenprüfung, danach von mir Zeile für Zeile nachgeschlagen.

**Read-only:** Es wurde keine `.lua`-Datei und keine Datei des Arbeitsbaums verändert, erstellt oder gelöscht. `git status --short` ist leer, HEAD unverändert `691720a`. Einzige Neuanlage ist dieses Review-Dokument; `.md` steht in keiner Zeile der `Details_iLvlDisplay.toc` (dort sind alle Dateien einzeln gelistet), WoW lädt es also nicht. Der Raid-Test ist davon nicht berührt.

**Zitierdisziplin:** Jede `datei:zeile` unten habe ich persönlich geöffnet und die Zeile wörtlich gelesen. `.release/` wurde nicht angefasst. Wo ich mich auf eine Lens verlasse, ohne selbst nachgeschlagen zu haben, steht das explizit dabei.

---

## 1. Gesamturteil

Das ist eine ungewöhnlich disziplinierte Codebase für ein WoW-Addon. Die Secret-Value-Verteidigung hält: über alle Top-Level-Dateien gibt es keinen einzigen ausführbaren Roh-Aufruf von `UnitGUID`/`UnitName`/`UnitIsUnit` außerhalb von `secrets.lua` — die 16 Grep-Treffer stecken sämtlich in Kommentaren. Beide CI-Gates laufen sauber (`luacheck --only 113`: 0/0 über 21 Dateien). Die Fremd-Feld-Zugriffe auf Details!, Blizzard_DamageMeter, ElvUI, Grid2 und DandersFrames sind — bis auf **eine** Ausnahme — gegen die echte Peer-Quelle korrekt; das ist nach dem `baseframe`-Debakel bemerkenswert. Der Kill-Switch-Gedanke ist real implementiert und nicht nur behauptet.

Die Schwächen liegen alle in derselben Klasse und sie ist verräterisch: **dokumentierte Sicherheitsnetze, die es nicht gibt.** Der Overlay-FontString `_dilvlNameFS` wird an sechs Stellen gelesen und nie erzeugt. Der „chirurgische" `ClearAspect`-Pfad in blizzdm ist tote Verzweigung, weil die Methode in der gesamten Blizzard-API nicht existiert. Der Re-Entrancy-Guard in `QueueGroupInspect` kann per Konstruktion nie greifen. Der oUF-Refresh für `[dilvl:plain]` feuert seit ~3,5 Monaten ins Leere. Das ist exakt dasselbe Muster wie der `baseFrame`-Bug: eine Fallback-Kette, deren bevorzugter Zweig unerreichbar ist, maskiert dadurch, dass der Fallback zufällig funktioniert. Das ist die Klasse, auf die du beim nächsten Durchgang systematisch jagen solltest — nicht auf neue Features.

Für den Raid heute Abend: **v1.5.3 ist versandfähig.** Kein einziger bestätigter Defekt kostet Frames im Kampf oder crasht den Client. Der realistischste Ärger heute Abend ist `/dilvl debug` selbst (Finding D1/D2 unten) — genau das Werkzeug, das du benutzen würdest, wenn etwas schiefgeht. Das ist die einzige Sache, bei der ich zögere.

---

## 2. Echte Defekte

Reihenfolge = Priorität. Alle haben die adversarielle Gegenprüfung überlebt und sind von mir nachverifiziert.

### D1 — `/dilvl debug` kapert das **globale** `print()` dauerhaft, wenn irgendeine Zeile wirft

**core.lua:1813** (Hijack) und **core.lua:2187** (Restore) — verifiziert, das sind die **einzigen** beiden `print = `-Zuweisungen in core.lua.

```lua
1813:        print = function(m)
...
2187:        print = origPrint
```

Es gibt kein lokales `print` in core.lua, also wird das echte Global überschrieben. Dazwischen liegen ~374 Zeilen **ohne** pcall.

**Failure-Szenario:** Wirft irgendeine dieser Zeilen, bleibt der Wrapper für den Rest der Session installiert. Der Wrapper nimmt genau **einen** Parameter `m` — jedes andere Addon, das `print(a, b, c)` ruft, verliert ab diesem Moment `b` und `c`. Ein zweiter `/dilvl debug` verschlimmert es: `local origPrint = print` (core.lua:1812) fängt den bereits installierten Wrapper und schachtelt eine weitere Ebene. Das verletzt Architekturregel 4 in der schlimmsten Richtung — statt still und isoliert zu scheitern, scheitern wir laut in jedes andere Addon hinein.

**Minimalfix:** Dump-Body in eine lokale Funktion kapseln, `local ok, err = pcall(body)`, danach `print = origPrint` **unbedingt**, dann `ShowDebugWindow`, dann bei `not ok` via `geterrorhandler()` nachreichen. ~6 Zeilen, kein Verhaltensunterschied auf dem Erfolgspfad.

**Aufwand:** klein.

---

### D2 — `core.lua:1897` formatiert einen möglicherweise-`nil` Namen mit `%s` — der konkrete 12.1-Auslöser für D1

```lua
1897:            print(string.format("  Last inspect: %s → %d iLvl (%s)", lastInspectInfo.name, lastInspectInfo.ilvl, ago))
```

Verifiziert. Und verifiziert, dass `lastInspectInfo` bei **core.lua:1276** so gebaut wird:

```lua
1276:                    lastInspectInfo = {name = fullName or name or cachedName, ilvl = ilvlFloor, time = GetTime()}
```

**Failure-Szenario:** 12.1 bringt `SecretWhenUnitNameIdentityRestricted` auf `UnitName`. In einer restricted Instanz gibt `SafeUnitName` `nil` zurück; `fullName` wird dann ebenfalls `nil`, und `cachedName` ist bei einem Erst-Inspect `nil`. Der Item-Level-Lesepfad ist ausdrücklich **nicht** secret-gated (verifiziert, s. Abschnitt 3), also läuft der Eintrag mit `ilvl` durch und `name = nil`. Der erste `/dilvl debug` danach wirft bei :1897 — **nachdem** print bei :1813 gekapert wurde. Damit ist D2 der wahrscheinlichste Weg, wie D1 heute Abend tatsächlich feuert.

Bemerkenswert: jeder andere möglicherweise-nil-Wert in diesem Dump ist gewrappt (`tostring(detailsReady)` bei :1900 habe ich gesehen). Diese eine Stelle ist der Ausreißer — was selbst schon der Beleg dafür ist, dass es ein Versehen war.

**Minimalfix:** `tostring(lastInspectInfo.name)` und `tonumber(lastInspectInfo.ilvl) or 0`. Entspricht der Konvention, die im Dump ohnehin überall gilt.

**Aufwand:** trivial. **Das ist der eine Fix, den ich vor dem Raid machen würde, wenn ich einen machen dürfte.**

---

### D3 — `QueueGroupInspect`: der `not isInspecting`-Guard ist toter Code

**core.lua:1037** vs. **core.lua:1081** — beide von mir im Zusammenhang gelesen:

```lua
1037:    isInspecting = false
...
1081:    if #inspectQueue > 0 and not isInspecting then
1082:        C_Timer.After(0.5, ProcessNextInspect)
```

`grep -n "isInspecting" core.lua` liefert 33, 986, 995, 1000, 1014, 1015, 1037, 1081, 1878 — **null** Zuweisungen zwischen 1038 und 1080, und Lua kann in diesem Body nicht yielden. Der Term `and not isInspecting` ist also unbedingt erfüllt. `ProcessNextInspect` hat selbst keinen Re-Entrancy-Check; `inspectGeneration` (:1040) schützt nur den 15s-Safety-Closure bei :1014, nicht die Kette.

**Failure-Szenario (die adversarielle Prüfung hat es präzisiert und dabei verschärft):** Der Kommentar bei :1034-1036 sagt „Always reset here since we're rebuilding from scratch" — die Absicht ist klar, die Wirkung nicht. Der **breitere** Riss ist gar nicht die <0,5s-Race, sondern `pendingInspectGuid = nil` bei :1038: Wenn ein `INSPECT_READY` noch fliegt, während der nächste Sweep läuft (die Login-Sweeps liegen bei 5s/15s/30s auseinander — das reicht völlig), scheitert der Vergleich `guid == pendingInspectGuid` bei :1297, der Else-Zweig setzt `lastManualInspectTime = GetTime()` (:1303), und `ProcessNextInspect` verweigert daraufhin **60 Sekunden** den Dienst (:994). Bei einem normalen Raid-Login reproduzierbar.

Zu relativieren: `core.lua:995-996` re-armt mit `C_Timer.After(5, ProcessNextInspect)`, die Pause läuft also ab. Es ist ein **kumulierender Stall**, kein permanenter Datenverlust — jede pausierte Kette re-armt sich unabhängig, sodass sich parallele 5s-Retry-Loops ansammeln, gemeinsam wieder anlaufen und die Fehlklassifikation erneut auslösen. Praktischer Effekt im Raid: doppelte `NotifyInspect`-Calls in eine server-gedrosselte API und ein Teil des Raids bekommt spürbar verzögert eine iLvl.

**Minimalfix (Peer-Muster, s. Abschnitt 4):** Details! führt keinen Skalar, sondern eine Menge — `inspecting[guid]` (Details-Damage-Meter/core/inspect.lua:451, `if (inspecting[guid] or ...)`, von mir gelesen). Analog: `pendingInspect[guid] = true` statt eines Skalars, damit eine out-of-order-Antwort sich selbst klassifiziert. Zusätzlich `local gen = inspectGeneration` an jeder `C_Timer.After(..., ProcessNextInspect)`-Stelle mitgeben und als erste Zeile prüfen — nutzt den Generationszähler, der bei :1012-1019 schon existiert.

**Aufwand:** klein bis mittel (ein Parameter + fünf Scheduling-Sites, oder Skalar → Tabelle).

**Hinweis:** `ROADMAP_RESEARCH_2026-08-08.md:133` dokumentiert einen **anderen** Defekt in derselben Funktion (Timeout-Pfad verwirft den Eintrag). Die Re-Entrancy-/Fehlklassifikation ist nirgends in den Repo-Docs erfasst — das hier ist neu.

---

### D4 — oUF `RefreshMethods` nimmt **einen** Tag; `[dilvl:plain]` wird nie refresht

**elvui_tags.lua:88** (selbst geöffnet):

```lua
88:    pcall(E.oUF.Tags.RefreshMethods, E.oUF.Tags, "dilvl", "dilvl:plain")
```

Gegenquelle, selbst geöffnet — `ElvUI/ElvUI_Libraries/Game/Shared/oUF/elements/tags.lua:1070`:

```lua
	RefreshMethods = function(_, tag)
		if not tag then return end
		tag = '%[' .. tag:gsub('[%^%$%(%)%%%.%*%+%-%?]', '%%%1') .. '%]'
```

Genau ein benannter Parameter, kein Vararg — das vierte Argument wird von Lua verworfen. Repo-weiter Grep über alle 12 Peers: exakt zwei Treffer, die Definition bei tags.lua:1070 und ein Ein-Argument-Aufruf `Tags:RefreshMethods(tagName)` bei `ElvUI/ElvUI/Game/Shared/Tags/API.lua:115`. Es gibt keinen ElvUI-Override.

Zweiter, unabhängiger Grund: das gebaute Muster ist literal `%[dilvl%]`, und `StripTag` (tags.lua:1058-1060, gelesen) entfernt nur `[x>`-Präfixe und `<x]`-Suffixe, niemals ein `:plain`-Suffix. Selbst wenn der Tag durchgereicht würde, würde `[dilvl]` in `[dilvl:plain]` nicht matchen.

**Failure-Szenario:** Ein Nutzer folgt unserem eigenen Login-Hinweis (init.lua:86-88 bewirbt `[dilvl:plain]`) und setzt `[name] [dilvl:plain]` in einen ElvUI Custom Text. Wir inspizieren die Gruppe, der Cache füllt sich, wir feuern den Callback — und seine Frames rendern nicht neu. Die Zahl bleibt leer, bis für genau diese Unit zufällig `UNIT_INVENTORY_CHANGED` feuert (das einzige Event, auf das der Tag registriert ist, elvui_tags.lua:64/68). Sieht für den Nutzer aus wie ein Cache-Problem, ist ein Refresh-Problem.

**Der Kommentar direkt darüber behauptet das Gegenteil — elvui_tags.lua:84-85:**
```
84: -- forcing a tag re-evaluation; it accepts multiple tag names
85: -- in one call so both variants refresh together.
```
Dieselbe Falschaussage steht ein zweites Mal bei **elvui_tags.lua:19-20** („Our callback calls Tags:RefreshMethods on both / tag names"). Beide korrigieren.

**Minimalfix:**
```lua
pcall(E.oUF.Tags.RefreshMethods, E.oUF.Tags, "dilvl")
pcall(E.oUF.Tags.RefreshMethods, E.oUF.Tags, "dilvl:plain")
```
Öffentliche API, weiterhin pro Tag einzeln pcall-geschützt.

**Aufwand:** trivial. **Achtung:** das verdoppelt die Kosten pro Notify — deshalb gehört D4 in denselben Change wie P1/P2 (Abschnitt 5), sonst wird der ElvUI-Pfad messbar teurer.

---

### D5 — `/dilvl auras` ruft `C_UnitAuras.GetBuffDataByIndex` roh; 12.1 macht daraus einen harten Error

**core.lua:2194** (selbst geöffnet):

```lua
2194:            local aura = C_UnitAuras.GetBuffDataByIndex("player", i)
```

Die vorhandene Absicherung bei :2201 (`if isSecretValue(sid) or isSecretValue(name)`) prüft nur die **Rückgabewerte** — sie hilft nicht, wenn die Precondition den Aufruf selbst ablehnt.

**Beleg, selbst geöffnet** — `wow-ui-source/Interface/AddOns/Blizzard_APIDocumentationGenerated/UnitAuraDocumentation.lua:304-308`:
```lua
			Name = "GetBuffDataByIndex",
			Type = "Function",
			RequiresUnitAuraAccess = true,
			SecretWhenUnitAuraRestricted = true,
```
und `SecretPredicatesDocumentation.lua:47-50`:
```lua
			Name = "RequiresUnitAuraAccess",
			Type = "Precondition",
			FailureMode = "Error",
```
Das ist ein blankes `"Error"`, nicht das mildere `"ReturnWithError"`, das die vier in `secrets.lua:19-28` dokumentierten Preconditions verwenden. Genau die Fehlerklasse, die `tools/lint-secret-mixin.sh` beschreibt („throws *inside the call*" — der v1.5.2-Crash). Es gibt auch keinen Vorab-Test: die `C_Secrets`-Oberfläche hat `ShouldAurasBeSecret`/`ShouldUnitAuraIndexBeSecret` („werden die **Werte** secret"), aber nichts für „habe ich **Zugriff**". pcall ist die einzige Absicherung.

**Failure-Szenario:** Du tippst mitten im Raid `/dilvl auras`, um ein fehlendes Tier-Tag zu diagnostizieren — und bekommst einen rohen Lua-Error statt des Dumps, in genau dem Kampf, für den die Diagnose gedacht war.

**Minimalfix:** `local ok, aura = pcall(C_UnitAuras.GetBuffDataByIndex, "player", i)`, danach `if not ok then print("  (aura access blocked)"); break end` vor dem bestehenden `if not aura then break end`. Der Secret-Guard bei :2201 bleibt exakt wie er ist.

**Aufwand:** trivial, 2 Zeilen.

---

### D6 — blizzdm `ClearSecretText`: der „chirurgische" Zweig ist unerreichbar, der Fallback ungeschützt

**blizzdm.lua:537-542** (selbst geöffnet):
```lua
537:    if nameFS.ClearAspect and Enum and Enum.SecretAspect then
538:        local ok = pcall(nameFS.ClearAspect, nameFS, Enum.SecretAspect.Text)
...
542:    nameFS:SetToDefaults()
```

**Beleg:** `grep -rn "ClearAspect" Interface/` über das komplette `wow-ui-source` (12.1.0.69273, version.txt selbst gelesen) liefert **nichts**. FontString hat `ClearAlphaGradient` und `ClearText`, FrameScriptObject hat `AddSecretAspect`/`HasSecretAspect`/`HasAnySecretAspect`/`HasSecretValues` — kein Gegenstück zum Entfernen. `nameFS.ClearAspect` ist also immer `nil`, der pcall bei :538 wird nie erreicht, und die Kontrolle landet **immer** bei `SetToDefaults()` — ohne pcall.

Der Kommentar bei blizzdm.lua:531-532 beschreibt einen Zwei-Pfad-Entwurf, der nie zwei Pfade hatte. Exakt dasselbe Muster wie `baseFrame`/`baseframe`.

**12.1-Verschärfung** (aus Lens B, von mir nicht einzeln nachgeschlagen — vor einem Fix bitte selbst prüfen): `SimpleFrameScriptObjectAPIDocumentation.lua` soll für `SetToDefaults` neu `ChecksForbiddenAspects = { SetToDefaults, RemoveSecretAspects }` tragen, wo 12.0.7 nur `IsProtectedFunction = true` hatte; `ForbiddenAspectConstantsDocumentation.lua` ist eine neue Datei in 12.1. Wenn das stimmt, ist unser einziger real existierender Pfad in 12.1 zusätzlich gegated — und ungeschützt.

**Minimalfix:** `local ok = pcall(nameFS.SetToDefaults, nameFS); if not ok then return false end` statt des nackten Aufrufs. Den `ClearAspect`-Probe **nicht** entfernen (Regel 3 — falls Blizzard sie nachliefert, greift sie automatisch), aber den Kommentar auf „nicht in 12.1.0.69273 vorhanden, Probe für die Zukunft" korrigieren, damit niemand sie für aktiv hält.

**Aufwand:** klein.

---

### D7 — `frame._dilvlNameFS` wird nie erzeugt; das dokumentierte Overlay-Sicherheitsnetz existiert nicht

Selbst verifiziert: `grep -n "_dilvlNameFS\|CreateFontString" blizzdm.lua` — das Feld wird bei **559, 574, 575, 850, 1451, 1452, 1453** gelesen und bei **1340** auf `nil` gesetzt; `CreateFontString` kommt in blizzdm.lua **null Mal** vor. Alle sieben Lesestellen haben die Form `if frame._dilvlNameFS then …` und sind damit permanent tot.

Das widerspricht dem Datei-Header (blizzdm.lua:15, „Overlay FontString when native is locked by secret text") und dem Doc-Block bei blizzdm.lua:617-621 (aus Lens A zitiert). Der Secret-Pfad in `InjectIlvl` ruft nur `ClearSecretText` und wiederholt dann `nameFS:SetText(displayText)` auf Blizzards eigenem FontString — und der ist nach D6 unter Umständen gar nicht gesäubert.

**Failure-Szenario:** Ein DamageMeter-Eintrag behält ein klebendes Secret-Text-Aspect. `SetText` wird still ignoriert, der Spieler bekommt nie ein Tag, es gibt keinen Fallback und keine Meldung.

**Bewertung:** Das ist **kein Crash** und blockiert nichts. Es ist eine Lücke zwischen Doku und Code, und `/dilvl debug` meldet zusätzlich einen Phantom-„OVERLAY"-Pfad (blizzdm.lua:1451-1453), was eine Fehlersuche aktiv in die Irre führt.

**Minimalfix — zwei Optionen, ich empfehle (a):**
(a) **Lean:** Die sieben toten Zweige und die Header-Zeilen entfernen, Doku auf den Ist-Zustand bringen. Macht die Datei kleiner und ehrlich.
(b) Das Overlay tatsächlich bauen. Mehr Code, mehr Fläche, und ohne In-Game-Nachweis, dass das klebende Aspect real auftritt, ist es spekulative Komplexität.

**Vor (b) braucht es einen In-Game-Test, keinen Source-Read:** Tritt der Fall „ClearSecretText schlägt fehl und SetText wird verschluckt" überhaupt auf? Das kann ich aus der Quelle nicht beantworten.

**Aufwand:** (a) klein, (b) mittel.

---

### D8 — Der 2-Sekunden-Ticker-Pfad hat keinen pcall, keinen Zähler und keine Drosselung

Selbst verifiziert: `grep -n "SafeCall" core.lua` liefert **genau zwei** Treffer — die Definition bei :97 und **eine** Verwendung bei :769 (der `hooksecurefunc`-SetText-Hook). `OnTick` (core.lua:964-979, gelesen) ruft `HookAllBars()`, `RebuildNameIlvlMap()` und `RefreshAllBarTexts()` vollkommen ungeschützt, und `RefreshAllBarTexts` führt in `RefreshAllColumns` mit hunderten ungeschützten Lesezugriffen auf Details!-Internals.

Der Header-Kommentar bei core.lua:82-88 beschreibt eine Feature-Isolation, die diesen Pfad nicht abdeckt. „Was passiert beim 6. Fehler" hat damit zwei verschiedene Antworten: auf dem Hook-Pfad rastet der Zähler ein und stoppt sauber; auf dem Ticker-Pfad gibt es keinen 5. oder 6. — der Fehler wiederholt sich alle 2 Sekunden für den Rest der Session.

**Failure-Szenario (aus Lens E, plausibel, von mir nicht bis ins letzte nachgerechnet):** `cachedColLayout.contentEdge` wird aus SavedVariables restauriert und nicht validiert. Eine abgeschnittene `SavedVariables.lua` — der Normalfall nach einem Client-Crash beim Logout — liefert eine Teiltabelle, `contentEdge = nil`, und die Arithmetik wirft. Alle 2 Sekunden, den ganzen Raidabend.

**Minimalfix:** Body von `OnTick` in `TickBody` auslagern und über das vorhandene `SafeCall` routen. Nutzt Zähler und Kill-Switch, die schon da sind, führt keinen neuen Zustand ein, und hält Details!-Fehler auf `db.showInDetails` beschränkt — genau wie bei :78-88 dokumentiert.

**Aufwand:** klein. **Das ist mein Favorit für v1.6**, weil es mit einer Zeile die größte ungeschützte Fläche der Codebase schließt.

---

### D9 — Post-Login-Bootstrap kann dauerhaft und still sterben; `tickerStarted` lügt

**core.lua:1204-1212** (selbst geöffnet):
```lua
1204:        if not detailsReady and not tickerStarted then
1205:            tickerStarted = true
1206:            C_Timer.After(3, function()
1207:                detailsReady = true
1208:                if Details then
1209:                    RebuildNameIlvlMap()
1210:                    HookAllBars()
1211:                end
1212:                C_Timer.NewTicker(2, OnTick)
```

`tickerStarted = true` steht **vor** dem Closure. Wirft `RebuildNameIlvlMap()` oder `HookAllBars()`, wird der Ticker bei :1212 nie erzeugt, die Login-Meldung erscheint nie, die drei QueueGroupInspect-Sweeps werden nie geplant — und weil `tickerStarted` schon `true` ist, blockiert der Guard bei :1204 **jedes** weitere `PLAYER_ENTERING_WORLD`. Kein Zonenwechsel, kein Instanzeintritt, kein Gruppenwechsel versucht es erneut. Das Addon ist für die Session tot, `/reload` ist die einzige Kur.

Und `/dilvl debug` bestätigt aktiv das Falsche: es druckt `tickerStarted` als „Ticker: %s" (core.lua:1900, gelesen) — also `true`, obwohl nie ein Ticker existierte.

**Minimalfix, zwei Teile, beide winzig:**
(a) `C_Timer.NewTicker(2, OnTick)` als **erste** Anweisung im Closure, vor den Details!-abhängigen Aufrufen.
(b) `tickerStarted = true` **in** das Closure verschieben, an die Stelle, wo der Ticker real entsteht — dann kann ein gescheiterter Versuch beim nächsten `PLAYER_ENTERING_WORLD` wiederholt werden.

**Aufwand:** klein.

---

### D10 — Callback-Auto-Unregister ist für ElvUI und Grid2 eine Einbahnstraße

**core.lua:2567** — `registry[name] = nil` nach `CALLBACK_ERROR_LIMIT` Fehlern (den kompletten `NotifyElvUI`-Block bei core.lua:2546-2573 habe ich gelesen).

Selbst verifiziert: `API:RegisterCallback` wird an **genau vier** Stellen gerufen, alle zur Ladezeit — `blizzdm.lua:1303`, `danders_integration.lua:339`, `elvui_tags.lua:87`, `grid2_status.lua:70`. Niemand registriert nach. `/dilvl elvui on` setzt nur `db` und feuert die inzwischen leere Registry.

**Der Auslöser ist real, nicht exotisch:** `elvui_tags.lua:88` lautet `pcall(E.oUF.Tags.RefreshMethods, E.oUF.Tags, …)`. Lua wertet Argumente **vor** dem pcall aus — die Feldkette `E.oUF.Tags.RefreshMethods` wird also **außerhalb** des Schutzes dereferenziert. Ist ElvUIs oUF während eines Profilwechsels oder nach einem ElvUI-Update `nil`, wirft das jedes Mal, der Zähler läuft auf 5, und der ElvUI-Tag ist für die Session still tot.

Das ist asymmetrisch: Details!-Bars, BlizzDM und Danders haben funktionierende Reset-Pfade (`Details_iLvlDisplay_BlizzDMReset`, `Details_iLvlDisplay_DandersReset`, `detailsBarErrors = 0`). Die Entwurfsabsicht ist also eindeutig Wiederherstellbarkeit — zwei Kanäle haben sie nur nicht bekommen.

**Minimalfix, zwei unabhängige Einzeiler:**
(a) `elvui_tags.lua:88`: Dereferenzierung nach innen ziehen — `pcall(function() E.oUF.Tags:RefreshMethods("dilvl") end)` (kombiniert mit D4: zwei solche Zeilen).
(b) Statt `registry[name] = nil` die Funktion in `_callbackParked[name]` beiseitelegen und in den bestehenden `/dilvl elvui|grid2 on`-Zweigen über `RegisterCallback` zurückholen — der Zähler wird dort ohnehin schon zurückgesetzt. Keine neue Einstellung, kein neuer Befehl.

**Aufwand:** klein.

---

### D11 — Wir übernehmen Details!' Item-Level-Pool in beliebigem Alter und stempeln ihn als frisch

**core.lua:237-256** (selbst geöffnet):
```lua
237:        local ok, data = pcall(Details.ilevel.GetIlvl, Details.ilevel, guid)
238:        if ok and data and data.ilvl and data.ilvl > 0 then
...
250:            ilvlCache[guid] = {
251:                ilvl = ilvl,
252:                time = time(),
```
`data.time` wird vom Peer geliefert und nie gelesen; wir überschreiben es mit der aktuellen Uhr.

**Gegenquelle, selbst geöffnet** — `Details-Damage-Meter/core/inspect.lua:456-457`:
```lua
	local ilvlTable = Details.ilevel:GetIlvl(guid)
	if (ilvlTable and ilvlTable.time + 3600 > time()) then
```
Details! selbst behandelt seinen eigenen Pool-Eintrag nach einer Stunde als veraltet. Und der Pool ist nicht session-lokal: `item_level_pool` steht in `functions/profiles.lua:1661` (Default) und `:1983` (Saved-Liste) — selbst gegrept, also **persistiert**.

**Failure-Szenario:** Am Sonntag mit Zoltara auf 271 geraidet; sie gearet unter der Woche auf 284 um. Heute Abend verfehlt `GetIlvlForGuid` unseren eigenen Cache, liest Sonntags 271 aus dem persistierten Pool und schreibt es mit `time = time()`. `QueueGroupInspect` sieht danach einen frischen Eintrag innerhalb `CACHE_EXPIRE` und stellt sie **nie** in die Queue — unser eigener, korrekter Inspect wird unterdrückt und die Bars zeigen 271 den ganzen Abend. Das re-armt sich bei jedem Ablauf neu.

**Minimalfix:** Die Zeitmarke ehren, die der Peer uns ohnehin gibt, mit dem Schwellwert des Peers: nach dem pcall `if data.time and (time() - data.time) >= 3600 then` → Schreiben überspringen und `nil` zurückgeben, damit die Inspect-Queue den Spieler aufnimmt. Alles andere (Namens-Anreicherung, `prev.name`-Erhalt) bleibt.

**Aufwand:** klein, eine Bedingung. **Der beste Nutzen-pro-Zeile-Fix im ganzen Review.**

---

### D12 — ElvUI-Refresh läuft bedingungslos, obwohl `elvuiTag` per Default `false` ist

**elvui_tags.lua:87-89** (selbst geöffnet): der Callback-Body prüft `db.elvuiTag` nie. Nur `buildIlvl` (elvui_tags.lua:38, aus Lens D) tut das. `init.lua:28` setzt `elvuiTag = false` als Default — das ist also der **Normalzustand** jedes ElvUI-Nutzers.

`RefreshMethods` ist nicht billig: tags.lua:1070-1096 iteriert `bracketFuncs` **und** `tagStringFuncs`, ruft je `StripTag` (zwei gsubs, zwei String-Allokationen pro Eintrag), nullt die gecachten Tag-Funktionen und erzwingt damit eine Neukompilierung, und läuft danach über **jeden** getaggten FontString der gesamten ElvUI-Oberfläche.

**Failure-Szenario:** Ein Raider, der von diesem Feature nie gehört hat, zahlt pro Inspect-Ergebnis mehrere hundert Mikrosekunden. Der Post-Kill-Sweep produziert ~25 `INSPECT_READY` über ~12s — reine Verschwendung.

**Minimalfix (wichtig: **nicht** einfach bei `false` früh raus — sonst bleibt nach `/dilvl elvui off` stehender `[284]`-Text auf den Frames):** Ein-Transitions-Latch — `local lastEnabled = false` auf Dateiebene, im Callback `local on = db and db.elvuiTag or false`, `if not on and not lastEnabled then return end`, `lastEnabled = on`, dann refreshen. Das erhält das Aufräumen beim OFF-Übergang.

**Aufwand:** klein.

---

## Geprüft und entkräftet

### ✗ „Details!-Actor-Felder sind der letzte ungeschützte Secret-Seam und werfen alle 2s"

Zwei Lenses (A und B) haben das als Top-Finding gemeldet — sauber zitiert, aber die Prämisse hält nicht.

**Was stimmt:** `core.lua:266-274` (`StoreNameIlvl`) hat wirklich keinen `isSecretValue`-Guard — selbst gelesen:
```lua
266: local function StoreNameIlvl(name, ilvl)
267:     if not name or not ilvl then return end
268:     nameToIlvl[name] = ilvl
...
271:     local shortName = Ambiguate(name, "none")
```
und `core.lua:359-378` reicht wirklich `actor.serial`/`actor.displayName`/`actor.nome` roh weiter (selbst gelesen). Und die Typ-Erhaltung stimmt: eine Secret-String `type()`t als `"string"`.

**Warum es trotzdem entkräftet ist:** Ein Details!-Actor kann uns nicht mit secret `nome`/`serial` erreichen. Jeder Actor wird von `actorContainer:GetOrCreateActor` erzeugt (`Details-Damage-Meter/classes/container_actors.lua:890`), und dort steht — von mir selbst geöffnet:
```lua
935:		local actorIndex = self._NameIndexTable[actorName]
...
955:		if (actorSerial:match("^C")) then
```
Der Name als Tabellenschlüssel, der Serial in einem String-Match — beides ungeschützt. Details! würde also **in seinem eigenen Container** werfen, bevor so ein Actor existiert, den `ListActors()` uns zurückgeben könnte. Der Fehler landet bei Details!, nicht bei uns.

Zweitens: die behauptete „drei ungefangene Throws in der BlizzDM-Integration" ist unabhängig davon falsch. `blizzdm`s `OnCacheChange` ist nur über den Callback-Bus erreichbar, und `NotifyElvUI` dispatcht **jeden** Callback unter pcall — `core.lua:2549 local ok, err = pcall(cb, playerName)`, selbst gelesen. Schlimmstenfalls ein geloggter Fehler plus Selbst-Deaktivierung des Kanals: Architekturregel 4 wie entworfen.

**Was bleibt:** Eine reine Verteidigungs-Asymmetrie. `StoreNameIlvl`/`StoreNameBonus` sind die einzigen Namens-Eingänge ohne den Guard, den alle anderen tragen. Das ist **billig zu schließen** (`if isSecretValue(name) then return end` bei :267 und :279) und ist Rüstung gegen ein zukünftiges Details!-Release, das Namen intern sanitisiert statt zu werfen — was `SecretWhenUnitNameIdentityRestricted` plausibel macht. **Nicht vor dem Raid. Kein Blocker. Kandidat für v1.6, Priorität niedrig.**

**Nebenbefund:** Die Superlative „der einzige ungeschützte Fremd-String-Seam" war schlicht falsch. **core.lua:525-527** ist derselbe Seam und liegt auf dem Hot Path — selbst gelesen:
```lua
525:            local actor = bar.minha_tabela
526:            if actor and actor.serial then
527:                ilvl = GetIlvlForGuid(actor.serial)
```
Wenn du :267 härtest, härte :526 gleich mit.

### ✗ Weitere zurückgewiesene Detail-Behauptungen
- **„Der sofortige Throw passiert bei core.lua:268."** Falsch attributiert: wäre `actor.serial` secret, würde es schon in `GetIlvlForGuid` beim Tabellenzugriff werfen, lange vor `StoreNameIlvl`.
- **„Ein Secret-Name überlebt einen /reload in SavedVariables."** Ohne Beleg. Die Quellen bei core.lua:370-372 sind `ResolveFullNameByGuid` (SafeUnitName-gestützt, `nil` bei secret) und die Actor-Felder, die nach oben nicht secret sein können.
- **Zitatkorrektur zu D4:** Der falsche Kommentar steht bei elvui_tags.lua:83-85, nicht 84-86 (Zeile 86 ist der `---`-Trenner) — und die identische Falschaussage steht ein zweites Mal bei elvui_tags.lua:19-20, was alle drei Lenses übersehen haben.
- **Mechanismus-Korrektur zu D4:** Es ist „der FontString wird nie zum Neu-Rendern aufgefordert", **nicht** „eine gecachte Funktion liefert veraltete Daten". Die neu gebaute Tag-Closure liest bei jedem Aufruf den Live-Cache.

---

## 3. 12.1-Lage

**Kurzfassung: wir stehen gut. Besser als die meisten Peers.**

Die fünf neuen Prädikate, gegen `SecretPredicatesDocumentation.lua` in `wow-ui-source` @ 12.1.0.69273 gemappt (version.txt selbst gelesen):

| Prädikat | Betrifft | Unsere Exposition |
|---|---|---|
| `SecretWhenUnitNameIdentityRestricted` | nur `UnitName` | **Ja, aber Verbesserung.** Ersetzt `SecretWhenUnitIdentityRestricted` und ist strikt **lockerer**. `SafeUnitName` deckt es ab. |
| `SecretWhenUnitPossessionRestricted` | `UnitIsCharmed`, `UnitIsPossessed` | Wir rufen keines von beiden. |
| `RequiresUnitAuraAccess` | 16 `C_UnitAuras` + 6 `C_TooltipInfo` | **Ja — genau ein Aufruf.** → D5. |
| `RequiresNonSecretAura` | 3 Aura-Lookups nach Name/SpellID | Keiner. |
| `SecretWhenAurasRestricted` | nur das `UNIT_AURA`-Event | Wir registrieren es nie. |

**Die größere 12.1-Geschichte, die die Prädikatsliste verdeckt** (aus Lens B, nachvollziehbar belegt, von mir nicht Zeile für Zeile nachgeschlagen): fünfzehn weitere `Unit*`-APIs haben neu `SecretWhenUnitIdentityRestricted` bekommen — `UnitClass`, `UnitClassBase`, `UnitGroupRolesAssigned`, `UnitHonorLevel`, `UnitInRaid`, `UnitIsGroupAssistant`, `UnitIsGroupLeader`, `UnitIsOwnerOrControllerOfUnit`, `UnitIsPVP`, `UnitIsRaidOfficer`, `UnitLeadsAnyGroup`, `UnitPhaseReason`, `UnitRace`, `UnitSex`, `UnitSexBase`. **Genau daran sind die Peers zerbrochen:** Grid2 `62ba513` (UnitIsCharmed) und `632f1c2` (UnitGroupRolesAssigned). Wir rufen **keine** der fünfzehn.

**Item-Level-Lesepfad: sauber.** `C_PaperDollInfo.GetInspectItemLevel`, `C_Item.GetItemInfo`, `C_Item.GetDetailedItemLevelInfo` tragen in 69273 nur `SecretArguments = "AllowedWhenUntainted"` — kein `Secret*`/`Requires*`-Prädikat. Der Tier-Set-Pfad (`util.lua:66-91`, setID via `C_Item.GetItemInfo`, pcall-gewrappt) berührt `C_UnitAuras` nie und ist von den Aura-Restriktionen echt unberührt.

**Eine Lücke, die ich nicht schließen konnte:** `GetInventoryItemID` taucht in `Blizzard_APIDocumentationGenerated` **nirgends** auf. Seine Secret-Lage ist damit **undeklariert**, nicht „bewiesen sicher". `if itemID and itemID > 0` (util.lua:73) ist unverifizierbar. Das ist die einzige offene 12.1-Unsicherheit im Kernpfad — und sie ist nur per In-Game-Test zu klären, nicht per Source-Read.

**Was 12.1 sonst neu bringt und uns streift:** `ForbiddenAspectConstantsDocumentation.lua` ist eine **neue Datei** (11 Aspects); `SetScript`/`HookScript`/`GetScript`/`ClearText`/`SetToDefaults`/`SetParent`/`SetPoint` haben `ChecksForbiddenAspects` bzw. `CheckAllow*`-Gates bekommen, `HookScript` zusätzlich einen `success`-Bool-Rückgabewert und `SecretArguments = "NotAllowed"`. **`hooksecurefunc` ist unverändert**, ebenso `SetText`/`SetTextColor`/`GetStringWidth`/`GetWidth`/`GetText`. Für uns relevant: D6 (ungeschütztes `SetToDefaults`) und mittelfristig der neue `HookScript`-Rückgabewert — den könnten wir bei `HookInstanceResize` (core.lua:957) auswerten, statt nur den pcall-Erfolg zu zählen.

**Haben Peers etwas gefunden, das wir übersehen haben?** Eine Sache, als Kanarienvogel wertvoll: **EllesmereUI `c9e30a25`** dokumentiert „eine `and`-Kette, die den Getter mitten in der Bedingung ruft, wirft sofort statt zu überspringen". Lens B hat unsere `and`-Ketten daraufhin durchgesehen und keinen Live-Fall gefunden (`GetNumPoints` trägt kein Prädikat; `IsShown` ist `SecretReturnsForAspect{Shown}`, aber ein Secret-Boolean ist truthy, kein Throw). Das deckt sich mit meiner Stichprobe. Ich würde es trotzdem als wiederkehrenden Prüfpunkt in den `dilvl-secret-radar` aufnehmen.

Zweitens, und das ist eher eine Chance als eine Lücke: **BigWigs `032c4adbc` + DBM `a0375034a`** belegen, dass eine Secret-String **gerendert** werden kann — `string.format` und `SetText` akzeptieren Secrets, `SetText` stempelt nur `SecretAspect.Text` auf den FontString. Das ist der Notausgang, falls wir irgendwann einen Spieler anzeigen wollen, den wir nicht benennen dürfen.

---

## 4. Von anderen gelernt

Das ist der wertvollste Teil dieses Reviews. Getrennt nach „macht unseren Code kleiner/robuster" und „gut zu wissen".

### 4a. Übernehmen — macht den Code kleiner oder robuster

#### ① Details! hat einen öffentlichen Event-Bus. Wir raten stattdessen an einem privaten Feld herum.

**Peer:** `Details-Damage-Meter/functions/events.lua:406` — `function Details:CreateEventListener()`, selbst gelesen. Die Event-Liste steht in `Definitions.lua:14/16/22`:
```
14: ---| "DETAILS_INSTANCE_SIZECHANGED"
16: ---| "DETAILS_INSTANCE_ENDRESIZE"
22: ---| "DETAILS_INSTANCE_NEWROW"
```
Gefeuert wird `DETAILS_INSTANCE_SIZECHANGED` aus dem OnSizeChanged-Handler des Base-Frames selbst (`frames/window_main.lua:1094`, plus zehn weitere Sites), und `DETAILS_INSTANCE_ENDRESIZE` genau einmal beim Loslassen des Resize-Griffs (`window_main.lua:1551`) — beides selbst gegrept. Dispatch läuft über `xpcall(func, geterrorhandler(), event, ...)` (`functions/events.lua:265`, selbst gelesen), ein Throw in unserem Handler kann also nicht zu Details! entweichen.

**Wo es bei uns greift:** `core.lua:945-959` (`HookInstanceResize`, selbst gelesen) rät:
```lua
947:    local frame = instance.baseframe or instance.baseFrame or instance.frame
```
und trägt sechs `resizeStats`-Zähler (core.lua:49-56), deren einziger Zweck es ist, „hat der Hook installiert?" beobachtbar zu machen — weil er vier Monate lang still nicht installiert hatte.

**Vorgehen (Regel 3 respektiert):** Im `if Details then`-Block einen Listener anlegen und beide Events registrieren; SIZECHANGED → `ScheduleColumnRefresh()`, ENDRESIZE → den entprellten Body von `OnDetailsResize`. Den HookScript-Pfad als Fallback **behalten** — beide münden in denselben Handler, der über `columnRefreshPending`/`resizeDebounce` ohnehin koalesziert, Doppelzustellung ist ein No-Op. Netto ~8 Zeilen mehr; das Feature hängt danach nicht mehr an einem privaten Feldnamen. Sobald `resizeStats.fired` im echten Raid bestätigt, dass der Event-Pfad lebt, können der HookScript-Pfad und vier der sechs Zähler weg — **dann wird die Datei kleiner als heute.**

Bonus: `DETAILS_INSTANCE_NEWROW` (gefeuert mit `(instance, newLine)` direkt nach `instance.barras[index] = newLine`) könnte mittelfristig unser 2s-Polling in `HookAllBars` ersetzen. Das ist ein größerer Umbau — v1.7-Kandidat, nicht jetzt.

#### ② Details! benutzt eine Menge, keinen Skalar, um laufende Inspects zu verfolgen

**Peer:** `Details-Damage-Meter/core/inspect.lua:451` — `if (inspecting[guid] or Details.trusted_characters[guid]) then return end`, selbst gelesen. Pro-GUID-Zustand statt eines einzelnen `pendingInspectGuid`.

**Wo es greift:** Direkt der Fix für **D3**. Eine out-of-order-Antwort klassifiziert sich selbst korrekt, und die 60s-Fehlklassifikation verschwindet strukturell statt per Zusatzguard.

Cooperation-Check, der sauber zurückkam: Details! hooked das globale `NotifyInspect` (`core/inspect.lua:342-344`) und deckelt sich selbst bei einem gleichzeitigen Inspect (`CONST_MAX_INSPECT_AMOUNT = 1`). Unser `NotifyInspect` drosselt Details!' Loop also bereits, statt mit ihm zu rennen — hier ist **nichts** zu tun.

#### ③ Details! verhindert Spalten-Jitter mit einem monotonen Max-Cache

**Peer:** `Details-Damage-Meter/classes/class_damage.lua:3086-3094` (aus Lens C, Mechanismus plausibel, ich habe die Umgebung nicht selbst geöffnet) — Offsets dürfen nur **wachsen**; der Kommentar bei :3092 lautet sinngemäß „use the distance value cached to avoid jittering in the string".

**Wo es greift:** `core.lua:621-646`. Wir bauen `contentEdge` bei jedem Refresh aus frisch gemessenen Breiten neu und überschreiben `cachedColLayout` bedingungslos. Mitten im Pull geht der DPS-Text der Top-Bar von „1.2M" auf „998.7K", `contentEdge` fällt, und unsere iLvl-/Tier-Spalte rutscht ein paar Pixel — sichtbares Flimmern direkt neben Details!' eigenen Spalten, die per Design stillstehen. **Weniger Code als ein Feature-Fix, weil nur eine Vergleichsbedingung dazukommt.**

#### ④ Alle Peers benutzen `xpcall(fn, geterrorhandler())`, wir benutzen nacktes `pcall`

**Peer:** `Details-Damage-Meter/functions/events.lua:265` (selbst gelesen), dasselbe Muster in DBM.

**Wo es greift:** `core.lua:2549` (`pcall(cb, playerName)`), `core.lua:97` (`SafeCall`). Gleicher Kontrollfluss, aber BugSack bekommt einen **Traceback** statt eines nackten Strings. Bei einem Bug-Report aus dem Feld ist das der Unterschied zwischen „irgendwas in elvui" und einer Zeilennummer. Null zusätzliche Komplexität.

#### ⑤ Plater drosselt identische Fehler auf einen pro Sekunde — und meldet sie **sichtbar**

**Peer:** `Plater-Nameplates/Plater.lua:12228-12233`, selbst gelesen:
```lua
		local lastTime = prevErrors[msg]
		local curTime = GetTime()
		if lastTime and curTime - lastTime < 1 then
			return
		end
		prevErrors[msg] = curTime
```
und **Plater.lua:12242** — `Plater:Msg (msg .. ...)` läuft **zusätzlich** zu `geterrorhandler()`, unbedingt.

**Wo es greift:** Zweifach. (a) Als Netz unter **D8** — falls du `SafeCall` nicht überall hinbekommst, kappt ein Throttle wenigstens die 2s-Endlosschleife. (b) Als Fix für die stille Selbstdeaktivierung (Abschnitt 6): unsere fünf Auto-Disable-Stellen (`core.lua:105`, `core.lua:2568`, `blizzdm.lua:98`, `danders_integration.lua:273`, `ui/safe_callback.lua:89`) melden **ausschließlich** über `geterrorhandler()`. `Blizzard_ScriptErrorsFrame.lua:30` gated seinen Frame auf `not GetCVarBool("scriptErrors")` — ein Nutzer mit abgeschalteten Script-Errors und ohne BugSack sieht **buchstäblich nichts**, wenn sich das Addon abschaltet.

#### ⑥ DBM kombiniert Vorab-Prüfung **und** pcall-Fallback — und begründet warum

**Peer:** `DeadlyBossMods/DBM-Core/DBM-Core.lua:495` und :510-521, selbst gelesen:
```lua
495:	local issecretunit = C_Secrets and C_Secrets.ShouldUnitIdentityBeSecret or function(val) return false end
...
511:		if issecretunit(unit) then
512:			return true
513:		end
514:		-- Workaround for Blizzard API where ShouldUnitIdentityBeSecret returns false
515:		--but compound unit tokens throw error on UnitGUID
516:		local guidSuccess, guid = pcall(UnitGUID, unit)
517:		if not guidSuccess or guid == nil then
518:			return true
519:		end
```
Das ist genau der richtige Umgang mit einer Vorab-Prüfung: sie **ersetzt** den pcall nicht, sie spart ihn im Normalfall. Der Kommentar bei :514-515 nennt den Grund — Compound-Unit-Tokens werfen, obwohl `ShouldUnitIdentityBeSecret` `false` sagt.

**Wo es greift:** `secrets.lua`. Wir könnten `C_Secrets.ShouldUnitIdentityBeSecret` als billigen Vorfilter in `SafeUnitGUID`/`SafeUnitName` legen — **ohne** einen einzigen bestehenden Guard anzufassen (Regel 3). Spart pro Roster-Walk ein paar Dutzend pcalls. Nice-to-have, kein Muss.

#### ⑦ Schwache Schlüssel gegen geleakte Bar-Tabellen — wir wissen es schon, machen es aber nur an einer Stelle

**Unser eigener Code, selbst gelesen** — `danders_integration.lua:66`:
```lua
local fontStrings = setmetatable({}, {__mode = "k"}) -- frame -> our FontString; weak keys so a frame Danders drops can fall out instead of pinning our overlay forever
```
Das Problem ist auf der Details!-Seite identisch: `Details:RestauraJanela` setzt `self.barras = {}` (aus Lens E: `classes/class_instance.lua:2584`, von mir nicht selbst geöffnet), während unsere fünf bar-verschlüsselten Tabellen starke Schlüssel haben. Fenster schließen/öffnen leakt also. **Lösung ist bereits im eigenen Repo vorhanden** — nur kopieren.

#### ⑧ LibOpenRaid erkennt Tier ohne setID-Whitelist — und wir werfen das Feld weg

**Peer, selbst gelesen** — `Details-Damage-Meter/Libs/LibOpenRaid/Functions.lua:475-493`:
```lua
                    if (leftText:match( "%s%(%d%/5%)$" )) then
                        return true
```
und `Libs/LibOpenRaid/LibOpenRaid.lua:1908-1916`, wo daraus `unitGearInfo.tierAmount` aggregiert wird — selbst gegrept.

**Wo es greift:** `util.lua:44-58` ist eine handgepflegte Liste von 13 setIDs mit dem Kommentar „Update this table when a new raid tier is added". Und unser LibOpenRaid-`GearUpdate`-Callback (**core.lua:1174-1195**, selbst gelesen) empfängt die volle `gearInfo`-Tabelle und liest daraus **nur** `gearInfo.ilevel`.

Zwei konkrete Lücken schließt das: (a) Am Tag, an dem Midnight Season 2 live geht, ist jede setID in unserer Whitelist falsch und **niemand** im Raid bekommt ein Tier-Tag, bis du 13 IDs im Spiel nachträgst. (b) Schon heute: ein LoR-versorgter Spieler (außer Inspect-Reichweite im 20er) bekommt von uns eine iLvl, aber nie ein 2P/4P — der GearUpdate-Pfad schreibt `setBonusCache` gar nicht.

**Vorgehen:** Nach dem ilvl-Write (core.lua:1189) `gearInfo.tierAmount` lesen und `setBonusCache[guid]` setzen — **aber nur wenn `setBonusCache[guid] == nil`**, also als Fallback, der niemals einen eigenen Inspect-Wert überschreibt. Die Whitelist bleibt der präzise Primärpfad (sie ist strenger: das `(n/5)`-Muster matcht auch Nicht-Tier-5er-Sets). ~4 Zeilen an der Aufrufstelle, nichts in util.lua.

**Vorsicht/Unsicherheit:** `isTierPiece` scrapt den Tooltip via `C_TooltipInfo.GetHyperlink`. Ich habe nachgesehen — `TooltipInfoDocumentation.lua:337-340` zeigt für `GetHyperlink` nur `MayReturnNothing = true` und `SecretArguments = "AllowedWhenUntainted"`, **kein** neues 12.1-Prädikat. Der Pfad ist also derzeit offen. Aber Tooltip-Scraping ist die fragilste Technik in dieser ganzen Liste, und Blizzard hat in 12.1 sechs `C_TooltipInfo`-Aura-Funktionen gegated — das kann als nächstes kommen. Deshalb: **Fallback, nie Primärquelle.**

### 4b. Gut zu wissen — nicht jetzt umsetzen

- **BigWigs' Callback-Registry** (`Loader.lua:1584-1633`, aus Lens C) ist die Referenzimplementierung für das, was wir in v1.6 als öffentliche API veröffentlichen wollen: `.`-vs-`:`-Fehlbedienung mit Klartext-Fehler erkennen, Argumenttypen prüfen, Re-Entrancy-Defer beim Registrieren während des Dispatch, `securecallfunction`-Dispatch. Beim API-Design abschreiben, nicht vorher.
- **DandersFrames' `API.lua`** ist das Modell für den Vertrag: „THIS IS A PUBLIC CONTRACT"-Notiz mit add-never-rename, benannte String-Fehlergründe statt nacktem `nil` (`"BAD_ARGS"`/`"UNKNOWN_ID"`/`"IN_COMBAT"`), dokumentierte Snapshot-Kopien, Capability-Probe (`DandersFrames_IsReady`/`GetVersion`), und ein `/dfapi`-Slash zum Live-Testen inklusive Abonnentenliste. **EllesmereUI** liefert die Doku-Hälfte als 148-zeilige `SKINNING_API.md` — die Form ist übernehmenswert, wortwörtlich.
- **BigWigs unterdrückt sein „neues Feature"-Popup bei Frischinstallation** (`if BigWigs3DB then`, Loader.lua:1173-1178). Wir machen das Gegenteil. Kosmetik, aber ein guter erster Eindruck.
- **Cell benutzt `fs:IsTruncated()`** für Text-Passung (`Utils.lua:507-522`) statt Pixel-Arithmetik. Falls unsere Spaltenmessung je zickt, ist das die einfachere Physik.
- **Plater spreizt Arbeit über ein FPS-Budget** (`Plater.lua:7178-7216`). **Bewusst abgelehnt** — unsere eigenen `perfStats` sagen ~0,09 ms für den Column-Refresh. Es gibt nichts zu spreizen. Das wäre Bloat und verletzt Regel 2.

---

## 5. Performance

**Ehrliches Urteil: die Details!-Seite ist bereits in Ordnung. Ich empfehle dort ausdrücklich nichts.**

Der Bar-SetText-Hook und `RefreshAllColumns` liegen im Sub-Millisekunden-Bereich, der In-Combat-Skip des teuren Mess-Blocks ist korrekt implementiert, `ListActors` ist allokationsfrei, die Caches sind begrenzt. Der BlizzDM-Teil ist der bestbenommene Code im Addon: beide Hot-Handler kehren in der ersten Zeile im Kampf zurück, und der OnUpdate idlet sich per `self:Hide()` selbst aus. ElvUI/Grid2/Danders pollen überhaupt nicht.

Ich nenne bewusst **nicht** die Mikrooptimierungen, die ein naiver Durchgang melden würde: unlokalisierte `math.abs`/`math.floor` (~15 µs/s — stehenlassen), die beiden `debugprofilestop()` (das **ist** die Messung), `RefreshAllBarTexts`, das alle 2s identische Strings neu setzt (20 SetText/s). Alles Rauschen.

**Die echten Kosten sind nicht pro Frame, sie sind Burst.** `NotifyElvUI` (core.lua:2546, gelesen) fächert einen einzelnen Cache-Write synchron an alle vier Integrationen auf und wird **nirgends** koalesziert. Der teuerste Konsument ist mit Abstand `elvui_tags.lua:88` → oUF `RefreshMethods`: 0,3–1,5 ms in einer Raid-UI.

Und — selbst nachgeschlagen in `PaperDollInfoDocumentation.lua:375-383` — `PLAYER_EQUIPMENT_CHANGED` ist ein **Pro-Slot**-Event:
```lua
			LiteralName = "PLAYER_EQUIPMENT_CHANGED",
			SynchronousEvent = true,
			Payload =
			{
				{ Name = "equipmentSlot", Type = "number", Nilable = false },
```
Ein Equipment-Manager-Set-Wechsel vor dem Pull feuert das also bis zu ~19-mal **im selben Frame**, und jedes Mal läuft die komplette Auffächerung. Sichtbarer Stutter zum denkbar schlechtesten Zeitpunkt.

**Wir sind hier der Ausreißer, nicht der Normalfall.** Beide Bibliotheken, die **innerhalb** von Details! ausgeliefert werden, entprellen genau dieses Event: `Libs/PlayerInfo/PlayerInfo.lua:1668` routet es über `setSchedule` (1s-Unique-Timer) mit dem expliziten Kommentar „schedules to avoid executing multiple times in a short period"; `Libs/LibOpenRaid/LibOpenRaid.lua:1196-1199` nutzt `NewUniqueTimer(4 + random(0,5), ...)`. (Beides aus Lens D; die Mechanik deckt sich mit dem, was ich in LibOpenRaid gesehen habe, die exakten Zeilen habe ich nicht einzeln geöffnet.)

**P1 — `NotifyElvUI` koaleszieren.** Mit dem **eigenen** vorhandenen Idiom: `ScheduleColumnRefresh` (core.lua:719-734) macht genau das schon — Flag + `C_Timer.After(0, flush)`. Eine wiederverwendete `notifyPending`-Tabelle als Namensmenge (bei Flush `wipe`, also null Steady-State-Allokation), einmal pro eindeutigem Namen dispatchen, damit blizzdms Per-Spieler-`ResetFailCounter` weiterhin jeden Namen sieht. **An dieser einen Stelle** repariert es den Equipment-Burst, den `GROUP_ROSTER_UPDATE`-Burst (core.lua:1372) und den LibOpenRaid-`GearUpdate`-Burst (core.lua:1193) gleichzeitig. Kein Guard angefasst, keine Einstellung, kein Vertrag geändert. **Aufwand: mittel.**

**P2 — ElvUI-Callback gaten.** Siehe **D12**. Latch, nicht Early-Return.

**Zusammenspiel, wichtig:** **D4 verdoppelt** die Kosten pro Notify (zwei `RefreshMethods`-Aufrufe statt einem). D4, P1 und P2 gehören deshalb in **einen** Change. Einzeln ausgeliefert macht D4 den ElvUI-Pfad messbar langsamer.

**Für den Raid-Test:** Nach dem Pull `/dilvl debug` und die Zeile „perf: N calls, avg=..ms, last=..ms, peak=..ms" (core.lua:2149) lesen. Bleibt `avg` unter ~0,3 ms, ist die Details!-Seite bestätigt gesund und alle Mikro-Findings sind endgültig erledigt. **Aber:** genau dieser Befehl ist durch D1/D2 gefährdet. Wenn du **einen** Fix vorziehst, dann D2.

---

## 6. Robustheit

Vier Lücken, nach Wert sortiert. Details oben bei D1, D8, D9, D10.

1. **Abdeckungslücke (D8).** `SafeCall` schützt genau **eine** Aufrufstelle. Der 2s-Ticker-Pfad und der komplette `frame:SetScript("OnEvent", …)`-Handler (core.lua:1120-1397) laufen ungeschützt. Der Header-Kommentar bei core.lua:82-88 verspricht mehr, als der Code liefert. **Grösste ungeschützte Fläche der Codebase, mit der kleinsten Fix-Zeile.**

2. **Stille Selbstdeaktivierung.** Alle fünf Auto-Disable-Stellen melden **nur** über `geterrorhandler()`. Kein einziges `print()`. Ein Standard-konfigurierter Nutzer merkt nicht, dass sich das Addon abgeschaltet hat. Beide Peers machen es andersherum: Plater ruft `Plater:Msg(msg)` unbedingt **zusätzlich** (Plater.lua:12242, selbst gelesen); DBM schiebt eine Chat-Nachricht, die sich alle 30s selbst neu plant. **Fix ohne Bloat:** eine `print()`-Zeile pro Kill-Switch mit dem Hinweis auf den bestehenden Reset-Befehl. Keine neue Einstellung, keine neue UI.

3. **Steckengebliebene Kill-Switches (D10).** Details!-Bars, BlizzDM und Danders haben echte Wiederherstellung. Der Callback-Bus nicht, für ElvUI und Grid2. Asymmetrie ist der Beleg, dass es Versehen war. Zusätzlich: `SC.ResetAll` hängt nur an einem Button, der auf der Diagnose-Seite selbst lebt (`ui/page_diagnostics.lua:185`, aus Lens E) — wenn genau diese Seite kaputt ist, ist der Reset unerreichbar.

4. **Diagnose lügt an zwei Stellen.** „Ticker: %s" druckt `tickerStarted`, das **vor** der Ticker-Erzeugung gesetzt wird → meldet `true`, wenn nie ein Ticker existierte (D9). Und die Callback-Fehlerzeile formatiert die **Anzahl der fehlerhaften Callbacks** so, als wäre es ein Fehlerzähler gegen das Limit (core.lua:1917-1918, aus Lens E) — ein toter Callback druckt „Callback errors (1/5 limit): elvui=5", was gesund aussieht. Beides sind Ein-Zeilen-Korrekturen, und beide sind genau dann wichtig, wenn du das Werkzeug wirklich brauchst.

---

## 7. Reihenfolge

### v1.5.3 — **so ausliefern. Nichts anfassen.**
Der Baum ist eingefroren, beide CI-Gates halten, kein bestätigter Defekt kostet Frames oder crasht. Der `baseframe`-Fix und die zwei `GetStringWidth`-Guards sind genau das, was heute Abend getestet gehört. **Taggen und raiden.**

Die einzige Sache, bei der ich zögere: **D2** (`core.lua:1897`, ein `tostring()`). Wenn `SafeUnitName` in eurer Instanz `nil` liefert, tötet der erste `/dilvl debug` das globale `print` für die Session — und `/dilvl debug` ist das Werkzeug, das du bei einem Problem als erstes ziehst. Das ist eine Ein-Zeichen-Klasse von Änderung. **Meine Empfehlung: trotzdem nicht anfassen** (der Baum ist eingefroren, du hast getestet, was du getestet hast) — aber **benutze heute Abend `/dilvl debug` nur, wenn du es wirklich brauchst**, und wenn danach andere Addons komisch werden, weißt du warum.

Im Raid mitschreiben, was **nur** in-game zu klären ist:
- `perf: avg/peak` nach dem Pull (core.lua:2149).
- Erscheint `[dilvl:plain]` in einem ElvUI Custom Text? (D4-Bestätigung im Feld.)
- Bekommen Spieler außer Inspect-Reichweite eine iLvl, aber kein 2P/4P? (Bestätigt die LoR-Lücke aus 4a⑧.)
- Zeigt eine Details!-Bar hartnäckig eine veraltete iLvl bei jemandem, der diese Woche umgeared hat? (Bestätigt **D11** im Feld.)

### v1.6 — die zehn Zeilen, die am meisten bringen
In dieser Reihenfolge:
1. **D2** — `tostring()` bei core.lua:1897. Trivial.
2. **D1** — pcall um den Debug-Dump, `print` auf beiden Wegen restaurieren. Klein. (1+2 zusammen machen das Diagnosewerkzeug erst verlässlich.)
3. **D11** — `data.time`-Prüfung gegen Details!' eigene 3600s-Schwelle. Eine Bedingung, größter Nutzen pro Zeile.
4. **D8** — `OnTick` durch das vorhandene `SafeCall` routen. Größte Flächenreduktion pro Zeile.
5. **D4 + D12 + P1 gemeinsam** — zwei `RefreshMethods`-Aufrufe, Latch-Gate, Koaleszierung in `NotifyElvUI`. **Nur zusammen ausliefern.**
6. **D5** — pcall um `GetBuffDataByIndex`. Zwei Zeilen, echtes 12.1-Risiko.
7. **D9** — Ticker zuerst erzeugen, `tickerStarted` danach setzen.
8. **D10** — Dereferenzierung in den pcall ziehen, Callbacks parken statt löschen.
9. **D6** — pcall um `SetToDefaults`, Kommentar zu `ClearAspect` ehrlich machen.
10. **D7 Variante (a)** — die sieben toten `_dilvlNameFS`-Zweige und die Header-Behauptung entfernen. **Macht die Datei kleiner.**
11. **Stille Selbstdeaktivierung** — eine `print()`-Zeile pro Kill-Switch. Und die zwei lügenden Diagnosezeilen korrigieren.
12. **Peer-Muster ①** — Details!' Event-Bus als zweiter Pfad neben dem HookScript-Hook. ~8 Zeilen, entkoppelt uns vom privaten Feldnamen.
13. **Peer-Muster ④** — `pcall` → `xpcall(fn, geterrorhandler())` an den zwei Stellen. Tracebacks in BugSack.

Optional, sehr billig: `isSecretValue`-Guard bei core.lua:267/279 und die Serial-Hoistung bei :360/:526 — **redundante Rüstung**, nicht heute erreichbar (siehe „entkräftet"), aber vier Zeilen für Zukunftssicherheit gegen ein Details!-Release, das Namen sanitisiert statt zu werfen.

### v1.7 und später
- **Peer-Muster ②** — `pendingInspectGuid` zur Pro-GUID-Menge + Generations-Guard an allen Scheduling-Sites (**D3**). Kein Blocker, aber die Fehlklassifikation verschwindet strukturell statt per Zusatz-Guard.
- **Peer-Muster ⑧** — `gearInfo.tierAmount` als Fallback in den GearUpdate-Callback, nur wenn `setBonusCache[guid] == nil`. Nimmt der neuen Season die Klippe.
- **Peer-Muster ③** — monotoner Max-Cache gegen Spalten-Jitter.
- **Peer-Muster ⑦** — `__mode = "k"` auf die fünf bar-verschlüsselten Tabellen. Kopie aus dem eigenen Repo.
- **`DETAILS_INSTANCE_NEWROW`** könnte das 2s-Polling in `HookAllBars` ersetzen. Größerer Umbau, erst nach v1.6-Stabilisierung.
- **v1.6-API-Veröffentlichung:** DandersFrames' `API.lua` als Vertragsmodell, BigWigs' Registry als Implementierungsmodell, EllesmereUIs `SKINNING_API.md` als Doku-Form.
- **Peer-Muster ⑥** — `C_Secrets.ShouldUnitIdentityBeSecret` als Vorfilter in `secrets.lua`, **zusätzlich** zu den pcalls, nie statt ihrer.

### Was ich bewusst **nicht** empfehle
- FPS-Budget-Scheduling à la Plater. Bloat, Regel 2.
- `_dilvlNameFS` tatsächlich zu bauen (D7b), bevor In-Game bewiesen ist, dass klebende Secret-Aspects real auftreten.
- Irgendeine Mikrooptimierung auf der Details!-Seite. Die ist gesund.
- Eine Einstellungsseite pro Integration. Der Per-Kanal-Kill-Switch reicht.

---

## Restunsicherheiten — ehrlich benannt

- **`GetInventoryItemID`** ist in der gesamten `Blizzard_APIDocumentationGenerated` nicht deklariert. Seine Secret-Lage ist **unbekannt**, nicht „sicher". Nur per In-Game-Test zu klären.
- **D6's 12.1-Verschärfung** (`ChecksForbiddenAspects` auf `SetToDefaults`) stammt aus Lens B; ich habe die konkreten Zeilen in `SimpleFrameScriptObjectAPIDocumentation.lua` nicht selbst geöffnet. Vor dem Fix nachschlagen.
- **`ui/`-Dateien** habe ich nicht vollständig gelesen; Lens E hat sie abgedeckt. Die zwei Zitate daraus (`page_diagnostics.lua:185`, `safe_callback.lua:89`) sind ungeprüft übernommen.
- **`resizeStats`** kann nur der echte Raid beantworten: feuert der Resize-Hook nach dem v1.5.3-Fix wirklich? Das ist der wichtigste Datenpunkt heute Abend, und keine Quellenlektüre ersetzt ihn.
- **Peer-Commit-Hashes** (Grid2 `62ba513`/`632f1c2`, Plater `3526fff7`, DBM `fea99dd27`, EllesmereUI `c9e30a25`, BigWigs `032c4adbc`) stammen aus Lens B/C; ich habe die Diffs nicht selbst gezogen. Als Signal belastbar, als Zitat nicht von mir verifiziert.
