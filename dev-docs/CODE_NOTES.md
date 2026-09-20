# Details! iLvl Display — Code Notes

Warum der Code so aussieht, wie er aussieht.

Die Quelldateien tragen kurze Kommentare: **was** eine Regel ist und **welche
Falle** sie abwehrt. Die Herleitung dahinter — die Messung, der Live-Vorfall,
die Beweiskette gegen Blizzards Quelltext — steht hier. Wer eine Regel ändern
will, liest zuerst den passenden Abschnitt: fast jede davon ist die Narbe eines
Fehlers, der schon einmal live war.

Verweise im Code sehen so aus: `-- Why: dev-docs/CODE_NOTES.md#striprealm`.

Diese Datei ist **versioniert** (sie muss mit dem Code wandern, sonst driftet
sie davon weg), wird aber **nicht ausgeliefert**: `.pkgmeta` ignoriert
`dev-docs/` vollständig, und `tools/lint-package-contents.sh` prüft das bei
jedem Release gegen dieselbe Liste. Nicht zu verwechseln mit `docs/` — das
bleibt der ungetrackte Ort für interne Analysen und Arbeitsnotizen.

---

## util.lua

### StripRealm — `Ambiguate(name, "short")`, niemals `"none"` {#striprealm}

Wir riefen lange `Ambiguate(name, "none")` auf und verließen uns darauf, dass es
den Realm abschneidet. Das hat es nie getan und konnte es nie tun: das zweite
Argument benennt den **Kontext**, für den vereinheitlicht werden soll, und
`"none"` heißt wörtlich *nicht vereinheitlichen, gib den vollen Namen zurück*.
Blizzards eigener Code nutzt `"none"`, wenn er den unangetasteten Namen will
(`ChatFrameUtil.lua:1014`, `TextToSpeechFrame.lua:971`), und `"short"`, wenn der
Realm weg soll (`LFGList.lua:2038`). Wir haben von Anfang an das Gegenteil von
dem angefordert, was wir wollten.

Das Symptom, aufgezeichnet in-game am 13.08.2026: `/dilvl map` hielt 51
Einträge, jeder davon ein voller `"Name-Realm"`-String und kein einziger in
Kurzform, weil

```lua
local short = Ambiguate(name, "none"); if short ~= name then ... end
```

niemals feuern kann. Details!-Balken zeigen nur `"Fhina"`, also traf nichts
zusammen und kein Item Level erschien — während Blizzards Meter (das
`"Fhina-Thrall"` zeigt) weiterlief. Das wurde damals als 12.1-Verhaltensänderung
gelesen, und der Kommentar im Code behauptete das auch. Falsch: die
Dokumentation hat sich nicht geändert, weil sich die Funktion nicht geändert
hat. Der Fallback-Match darunter hat den Fehler gut genug verdeckt, dass er wie
Blizzards Fehler aussah.

Korrigiert am 20.08.2026 auf `"short"`. `Ambiguate` bleibt bewusst **zuerst**:
es ist die sanktionierte API und kennt Namensformen, die ein simpler Match nicht
kennt. Der Match bleibt als Fallback, damit ein Client, auf dem `Ambiguate`
fehlt oder seltsam antwortet, trotzdem Kurznamen bekommt. Realm-Namen dürfen
kein `-` enthalten, also ist das erste Segment der Charaktername.

**Secret-Sicherheit:** `type()` kann kein Secret erkennen — ein geheimer String
meldet weiterhin `"string"` (siehe `secrets.lua`). `Ambiguate` akzeptiert
geheime Argumente (`PlayerScriptDocumentation`: `SecretArguments =
"AllowedWhenTainted"`, und `fullName` trägt kein `NeverSecret`-Flag), also heißt
Secret rein auch Secret raus. Deshalb werden Eingabe *und* Ergebnis mit
`issecretvalue` geprüft, nicht mit `type()`: ein Secret hier zurückzugeben
reichte es direkt an `nameToIlvl[shortName] = ilvl` in core.lua weiter, und ein
geheimer Tabellen-Schlüssel wirft. Die Eingabe unverändert zurückzugeben ist die
sichere Antwort — Aufrufer behandeln "keine Kurzform" ohnehin als normal.

### ShortenForDisplay — der eine Pfad, der ein Secret durchreichen darf {#shortenfordisplay}

`StripRealm` weigert sich absichtlich, ein Secret anzufassen: sein Ergebnis
speist `nameToIlvl[shortName]`, und ein geheimer Tabellen-Schlüssel wirft.
Dieser Schutz ist für jeden seiner Aufrufer richtig. Für genau eine Aufgabe ist
er falsch — einen String zu bauen, den wir ausschließlich an
`FontString:SetText` weiterreichen, nie vergleichen, nie als Schlüssel nutzen.

Blizzard gewährt genau das. `Ambiguate` ist `SecretArguments =
"AllowedWhenTainted"` (`PlayerScriptDocumentation.lua:22-30`, `fullName`
unbeschränkt, `context` `NeverSecret`), und `SimpleFontString:SetText` trägt
`SecretArgumentsAddAspect = {Enum.SecretAspect.Text}` mit derselben
`AllowedWhenTainted`-Gewährung — die einzige Setter-Familie auf diesem Widget,
die sie hat. Secret rein, Secret raus, und das Secret verlässt nie die C-Grenze.

Warum es überhaupt existieren muss: Details! kürzt einen versiegelten Namen
selbst, wenn die Quelle ein Spec-Icon trägt (`class_damage.lua:3182-3193`).
Bauen wir eine Zeile neu, ohne dasselbe zu tun, würde jeder Cross-Realm-Spieler
im Raid plötzlich `"Name-Realm"` zeigen, wo Details! `"Name"` zeigte. Kein
falscher Name, aber eine sichtbare Regression auf den meisten Zeilen eines
Raids.

**Das Ergebnis darf von keinem Aufrufer gespeichert, verglichen oder als
Schlüssel benutzt werden.** Wer einen Namen zum Nachschlagen braucht, will
`StripRealm`.

### iLvl-Farbbänder — abgeleitet statt fest {#ilvl-colors}

Die Tabelle war früher fest, und die Zahlen sind verrottet. Gemessen an 256
echten Cache-Einträgen am 17.08.2026: die alten Schwellen steckten **43,4 %**
aller in vier Tagen getroffenen Spieler ins oberste Band. Orange hatte
aufgehört, "gut ausgerüstet" zu heißen, und angefangen, "spielt das Spiel" zu
heißen. Season 2 hätte das vollendet — die ganze Stichprobe lief von 157 bis
295, während die *niedrigste* Season-2-Mythic+-Belohnung bei 305 liegt. Binnen
Tagen wäre jeder einzelne Spieler für den Rest der Erweiterung orange gewesen.

Eine feste Tabelle kann das nicht überleben, weil das Gemessene sich jede Season
bewegt und die Tabelle nicht. Also werden die Bänder aus Blizzards eigener
Mythic+-Belohnungskurve abgeleitet: diese Zahlen **sind** die Season, Blizzard
hält sie aktuell, und wir erben das umsonst. Sechs der sieben Grenzen sind an
Werte geknüpft, die Blizzard definiert, nicht an Werte, die wir erfunden haben.

| Band | Grenze | Rang | Anteil (184 Eintraege, 20.09.) |
|---|---|---|---|
| heirloom (teal) | `>= reward(+10) + 10` | Myth 4/6 | 0,0 % |
| artifact (gold) | `>= reward(+10) + 6` | Myth 3/6 | 11,4 % |
| legendary (orange) | `>= reward(+10) + 3` | Hero 6/6 | 25,6 % |
| epic (lila) | `>= reward(+10)` | Hero 5/6 | 21,7 % |
| rare (blau) | `>= reward(+6)` | Hero 3/6 | 23,4 % |
| uncommon (gruen) | `>= reward(+2) - 5` | Boden minus 5 | 13.6 % |
| poor (grau) | darunter | | 4.3 % |

#### Warum die halbe Skala die Kurve verlaesst

Weil die Kurve aufhoert. Gemessen am 17.09.2026 ueber alle Schluesselstufen von
2 bis 20: ab Stufe 10 liefert `GetRewardLevelFromKeystoneLevel` konstant **318**,
Stufe 11 bis 20 aendern nichts mehr. `GetRewardLevelForDifficultyLevel` sieht
nach einem Ausweg aus und ist keiner: die Funktion hat in Blizzards komplettem
UI null Aufrufer und gab im Test fuer jedes Argument dieselbe 318 mit
`endOfRunRewardLevel = 0` zurueck. Ueber den gesamten Addon-Bestand des Rechners
(3.623 Lua-Dateien in 88 installierten Addons, plus neun Dev-Repos) nutzt **kein
einziges anderes Addon** diese APIs zur Schwellenbildung. Die Luecke ist echt,
nicht uebersehen.

#### Die Belohnungskurve IST der Hero-Track

Gemessen am 20.09.2026 mit `C_Item.GetItemUpgradeInfo` ueber die angelegte
Ausruestung. **Wichtig: die API braucht einen `itemLink`** — mit einer blossen
Item-ID liefert sie durchgehend Nullen, daran ist der erste Messversuch
gescheitert.

| gemessen | |
|---|---|
| Hero 2/6 = 308 · 3/6 = 311 · 6/6 = **321** | Champion 6/6 = 308 |
| Myth 1/6 = **318** · 6/6 = **334** | `maxLevel` = 6 bei allen Tracks |

Damit faellt die Leiter dieser Season zusammen: die Kurvenwerte 305/308/311/315/318
sind exakt **Hero 1 bis 5**, und die Stufen laufen +3,+3,+4 im Wechsel:

```
305  308  311  315  318  321  324  328  331  334
 H1   H2   H3   H4   H5   H6
                     M1   M2   M3   M4   M5   M6
```

Die Tracks ueberlappen: Myth 1/6 und Hero 5/6 sind beide 318, und ein Spieler
mit vollem Hero 6/6 (321) ist besser ausgeruestet als einer mit Myth 1/6.

**Das war der eigentliche Fehler der alten Skala.** Das oberste Kurvenband sass
auf der Decke (318) und nannte sich "jenseits dessen, was Mythic+ ausgibt" — aber
Hero 6/6 ist 321 und kommt allein aus Mythic+. Gemessen an 184 echten
Cache-Eintraegen am 20.09.2026 hielt Gold damit **58,7 %**, drei Tage zuvor waren
es noch 32,6 %. Ein Band, in dem in jedem Run alle stehen, traegt keine
Information mehr. Nicht die Schwelle war zu grosszuegig, die *Begruendung* war
falsch.

Deshalb haengen jetzt drei Baender als Rangabstand an der Decke (`ABOVE_CEILING`,
+3/+6/+10) statt an Schluesselstufen. 321 und 334 sind direkt gemessen, 324 und
328 aus dem Stufenmuster interpoliert. Gold heisst damit zum ersten Mal wirklich
"mehr als Mythic+ hergibt": 324 ist der erste Rang oberhalb eines vollen
Hero-Sets.

`UNCOMMON_BELOW_FLOOR` ist von 20 auf **5** gefallen, aus demselben Grund in die
andere Richtung: bei einem Boden von 305 lag Grau bei 285 und war schlicht leer,
der niedrigste beobachtete Wert ueberhaupt war 296. Mit 300 traegt Grau 4.3 % und
Gruen 13.6 %, statt 0 % und 9,2 %.

Kein Band haelt mehr als 25.5 % — vorher waren es 58,7 %.

#### Was belegt ist und was nicht

- **Belegt:** sechs Raenge pro Track (`maxLevel = 6` bei Hero, Myth *und*
  Champion), Hero 6/6 = 321, Myth 1/6 = 318, Myth 6/6 = 334, Hero 2/6 = 308,
  Hero 3/6 = 311.
- **Interpoliert:** 324 und 328 als Myth 3/6 und 4/6. Die Spanne 318 bis 334
  ueber fuenf Schritte ist gemessen, die Verteilung der +3/+4-Schritte darin
  folgt dem Muster des Hero-Tracks.
- **Unbrauchbar:** `ItemUpgradeInfo.maxItemLevel` liefert durchgehend 0, auch bei
  Myth-6/6-Teilen. Als Quelle fuer die Decke faellt das Feld aus.
- **Offen messbar:** Myth 2/6 oder 3/6 an einem echten Gegenstand wuerde die
  Interpolation zur Messung machen.

Die Farben kommen aus `C_Item.GetItemQualityColor`, aus demselben Grund: wenn
Blizzard je die Palette nachjustiert, folgen wir, statt zu driften.

`U.ILVL_COLORS` im Code ist der **Fallback**, in derselben Zeilenform gehalten,
damit jeder Konsument unverändert weiterläuft, wenn die API nichts sagt. Es ist
eine Momentaufnahme und **wird verrotten**: die abgeleiteten Season-2-Werte,
gemessen in-game am 18.08.2026 (Schlüssel 2/4/7/10 lieferten 305/308/315/318),
am 17.09.2026 unverändert bestätigt. Die drei Zeilen ueber der Decke (321/324/328)
sind Rangabstaende darauf, nicht eigene Kurvenwerte.
Hebt Season 3 die Belohnungskurve, wird diese Tabelle zu *großzügig* — alle gold
— dasselbe Versagen wie die Season-1-Zahlen am Season-2-Starttag, nur umgekehrt.
Auffrischen bei jedem Season-Start (die Anweisung steht auch im Code):

```lua
/run for _,k in ipairs({2,4,7,10}) do print(k, C_MythicPlus.GetRewardLevelFromKeystoneLevel(k)) end
```

Auch die Farben sind gemessen (`C_Item.GetItemQualityColor`, selber Tag) statt
aus einem Wiki abgeschrieben — Blizzards Palette lebt in der Engine, nicht in
einer Lua-Datei, die wir diffen könnten.

**Eine Tabelle, zwei Leser:** Kanäle, die farbigen *Text* schreiben, brauchen
die Escape-Sequenz; Grid2 reicht seine Farben an `SetTextColor` und braucht
Zahlen. Die Schwellen an einem Ort zu halten ist der Punkt — sie zweimal zu
tippen ist genau, wie der Grid2-Kanal dauerhaft weiß blieb, während alles andere
farbig war.

### CURRENT_TIER_SEASON — Handkonstante, mit Absicht {#tier-season}

Welche Raid-Season **läuft**. Season 2 begann mit Patch 12.1; die Pre-Season
gehört schon dazu, also ist Season-1-Tier bereits das *alte* Set, während die
meisten Spieler es noch tragen.

Genau dieser letzte Satz ist die Falle, und ich bin am 16.08.2026 hineingelaufen:
Ich sah einen Raid voller Season-1-Tier und schloss daraus, Season 1 müsse noch
laufen und `C_MythicPlus.GetCurrentUIDisplaySeason()` (das 2 antwortete) laufe
der Realität voraus. Tat es nicht. Was Leute **tragen**, sagt nichts darüber,
welche Season läuft — das Hinterherhinken ist genau der Übergang, den diese
Einfärbung sichtbar machen soll.

Trotzdem eine handgesetzte Konstante statt jenes API-Aufrufs, aber aus
Kontrolle, nicht aus Misstrauen: die Set-IDs werden ohnehin pro Season von Hand
gepflegt, eine Season ohne neues Tier ließe die beiden berechtigt auseinander
laufen, und das hier falsch zu haben, kennzeichnet jedes Set im Raid auf einmal
falsch. `/dilvl debug` druckt beide und flaggt eine Abweichung, damit die API
die Gegenprobe bleibt.

Auch nicht aus den Set-IDs ableitbar: die höchste ID ist nicht verlässlich die
aktuelle Season (2070 "Biss von Zul'jan" liegt komplett außerhalb der
Tier-Reihe).

Die Set-ID-Tabelle selbst ist eine Whitelist, weil `GetSetBonusText()` in 12.0
entfernt wurde. PvP-Ausrüstung (Ehre/Eroberung) hat eigene Set-IDs außerhalb
dieses Bereichs — der Whitelist-Ansatz ignoriert sie damit automatisch,
unabhängig von ihren Werten.

### GetSetBonusForUnit — `complete` ist die wichtigere Hälfte {#setbonus-complete}

`C_Item.GetItemInfo` ist **asynchron**: für ein Item, das der Client noch nicht
zwischengespeichert hat, liefert es überhaupt nichts, und dann kann diese
Funktion "trägt kein Tier" nicht von "konnte es noch nicht lesen" unterscheiden.
Beides kam früher als nacktes `nil` zurück, und jeder Aufrufer schrieb das
direkt in den Cache — also löschte ein unglücklicher Lesevorgang direkt nach
einem Ladebildschirm ein korrektes 4P, und nichts stellte es je wieder her (live
gemeldet am 15.08.2026: eigenes `[4P]` weg nach dem Zonen in einen Raid,
wiederhergestellt nur durch Neu-Anlegen eines Teils).

`complete = false` heißt "mindestens ein belegter Tier-Slot ließ sich nicht
auflösen". Aufrufer müssen behalten, was sie schon hatten, und es später erneut
versuchen.

### Set-Bonus-Auswahl — Bonus vergleichen, nie Teile zählen {#setbonus-auswahl}

Das stärkste **einzelne** Set gewinnt — Zählungen werden nie über Sets hinweg
summiert, also liest sich 2 alt + 2 neu korrekt als 2P statt 4P.

Bei Gleichstand gewinnt die aktuelle Season. Wer 2 alte und 2 neue Teile trägt,
hat beide 2er-Boni; der aktuelle ist der stärkere von beiden und der, auf den
die Person zugeht, also der nützlichere zum Anzeigen. Der umgekehrte Fall zählt
genauso und ist der Grund, warum der stärkste Bonus trotzdem klar gewinnt: 4 alt
+ 2 neu ist ein echter 4er-Bonus, und dort 2P zu zeigen würde die Person
untertreiben.

Berichtet wird **jedes** Set, das tatsächlich einen Bonus gewährt, nicht nur das
beste. Während eines Tier-Wechsels kann jemand zwei lebende Boni tragen — etwa 2
alte und 2 neue Teile — und nur einen davon zu zeigen verbirgt genau den
Zustand, für den diese Einfärbung gebaut wurde.

Verglichen wird der **Bonus**, nie die Teilezahl: drei Teile und zwei Teile
gewähren beide 2P, also ließ Teile-Zählen ein Set eines "schlagen", mit dem es in
Wahrheit gleichauf lag. Fünf Tier-Slots bedeuten, dass höchstens zwei Sets
gleichzeitig einen Bonus erreichen können (2+2 passt, 2+2+2 nicht), aber nichts
im Code setzt das voraus.

### seasonColor — kein Grün ohne Beleg {#season-color}

Grün für die aktuelle Season, grau für eine ältere, und **nichts** für einen
Wert, dessen Season wir nicht kennen.

Der letzte Fall ist der entscheidende, und er wäre beinahe falsch ausgeliefert
worden. Bevor es Seasons gab, war Grün schlicht "die Farbe eines Set-Bonus" —
neutral, die einzige, die es gab. In dem Moment, in dem Grau dazukam, hörte Grün
auf, neutral zu sein, und wurde zu einer **Behauptung**: "aktuelle Season". Jeder
Eintrag, der aus v1.5.5 in den SavedVariables eines Nutzers liegt, trägt keine
Season, und diese grün zu malen hätte jene Behauptung für Daten aufgestellt, die
sie nicht tragen können — für den ganzen Cache auf einmal, beim ersten Login
nach dem Update, genau in dem Moment, in dem sie in der Praxis alle Sets der
letzten Season sind.

Grau dürfen sie ebenso wenig werden: v1.5.5 erkannte auch schon Season-2-Sets,
also ist ein suffixloser Wert season-**unbekannt**, nicht season-1. Grau wäre
dieselbe unbelegte Behauptung in die andere Richtung.

Also zeigen die farbigen Oberflächen nichts, bis der nächste Inspect den Eintrag
mit einer Season neu schreibt — ein fehlendes Tag ist in Ordnung, ein falsches
nicht. Die *unfarbigen* Oberflächen (Danders, Grid2) zeigen den Bonus weiter,
weil dort die Farbbehauptung gar nicht erst entsteht.

`9D9D9D` ist bereits der Boden unserer Item-Level-Skala und liest sich als
veraltet.

---

## core.lua

### barRankInfo — warum der Datensatz seine GUID mitträgt {#barrankinfo}

Der Datensatz hält fest, was Details! zuletzt in eine FontString geschrieben
hat: den Rang als blanke Zahl und den Anzeigenamen getrennt, **bevor** Details!
beides zu einem String verschweißt. Geschrieben wird er ausschließlich vom
`UpdateBarApocalypseWow`-Post-Hook, dem beide Hälften einzeln übergeben werden.
Genau dieser eine Aufruf ist der einzige Moment, in dem die Teile getrennt
existieren — danach liegt nur noch ein undurchsichtiger Klumpen vor, den wir
nicht zerschneiden dürfen. Das ist es, was echte Links-Platzierung auf einer
versiegelten Zeile überhaupt möglich macht.

Die Namenshälfte darf ein Secret sein. Als Tabellen-**Wert** ist das sicher
(genau wie `barSecretText`), und sie wird ausschließlich als `%s`-Argument an
`string.format` gereicht.

**Der Kommentar an dieser Stelle hat einmal gelogen, und die Lüge hat den Fehler
verdeckt.** Er behauptete, der Datensatz werde im Gleichschritt mit
`barSecretText` geleert, sodass eine wiederverwendete Zeile niemals den
vorherigen Bewohner erneut ausgeben könne. Falsch: Eine FontString ist kein
Spieler, sondern ein Zeilen-**Slot**, den Details! bei jeder Neusortierung einem
anderen Akteur zuteilt. Details! überschreibt `lineText1` an Ort und Stelle
(`class_damage.lua:3199`), ohne je zu leeren — `ClearText()` kommt in seinem
gesamten Quelltext nicht vor. Bei einer Übergabe von versiegelt zu versiegelt
feuert also **keine** der beiden Leerstellen, und der Datensatz überlebt in den
nächsten Bewohner hinein.

Was das erzeugte: Das Tag wird aus der **aktuellen** `actorGUID` der Zeile
zusammengesetzt, Name und Rang stammen aber aus dem Datensatz — eine Zeile
konnte also den Namen des gegangenen Spielers neben dem Item Level des
ankommenden zeigen. Ein falscher Name auf dem Bildschirm ist das eine Ergebnis,
das dieses Addon nicht akzeptiert. Deshalb reist die GUID mit dem Datensatz, und
bei Abweichung wird er verworfen.

### Der Cache-Fallback — Auffrisch-Horizont ist kein Anzeige-Horizont {#cache-fallback}

`CACHE_REFRESH` ist ein **Re-Inspect**-Horizont, kein Anzeige-Horizont. Der
Kommentar an seiner Deklaration sagt das ausdrücklich: „re-inspect if we can
reach them". Ihn zusätzlich zum Unterdrücken des Tags zu benutzen heißt, dass
das Tag für jeden verschwindet, den wir gar nicht mehr erreichen können — jemand,
der die Gruppe verlassen hat, oder ein gespeichertes Segment aus einem früheren
Raid. Für die kommt nie ein neuerer Wert, also ist „warte auf etwas Frischeres"
ein Versprechen, das nicht eingelöst werden kann.

Es brachte außerdem die beiden Renderer über dieselben Daten in Widerspruch.
`API.GetCacheData`, das der Blizzard-Meter-Pfad benutzt, liest `ilvlCache` ganz
ohne Altersfilter — ein zwei Stunden alter Eintrag markierte dort also jede
Zeile, während die Details!-Balken daneben leer blieben. Live am 20.08.2026 sah
das so aus: Details! verlor eine Stunde nach dem Raid seine Tags, **35.385**
Ablehnungen wegen „kein Item Level" gegen einen Cache, der jeden einzelnen davon
enthielt. Nichts war kaputt — die Einträge hatten schlicht 7.200 Sekunden
überschritten.

Das schwächt die Frische-Regel nicht. Alles darüber bevorzugt weiterhin die
frischere Quelle, und die Inspect-Pipeline inspiziert nach ihrem eigenen Plan
neu. Es hört nur auf, die Antwort wegzuwerfen, wenn es keine bessere gibt. Was
wir gemessen haben, ist zuschreibbar; nichts zu zeigen, während das Meter daneben
die Zahl zeigt, ist einfach inkonsistent.

### Niemals `actor.displayName` {#displayname}

Details! führt die beiden Felder ausdrücklich getrennt:

```
Definitions.lua:601   displayName   "actor name shown in the regular window"
Definitions.lua:610   nome          "name of the actor"
```

`displayName` ist ein **gerenderter** String, den Details! frei umschreibt. Zwei
der drei Pfade sind **standardmäßig an**:

- Ein Gilden-Spitzname ersetzt ihn vollständig (`container_actors.lua:644-651`).
  `ignore_nicktag` ist standardmäßig `false` (`profiles.lua:1330`), und der Pool
  wird über den GILDEN-Addon-Kanal gefüllt — der String ist also von einem
  anderen Spieler verfasst. `checkValidNickname` beschränkt **wer**, nicht
  **was**: keine Ähnlichkeitsprüfung, „Gandalf" für Ivan-Blackrock geht durch.
- `remove_realm_from_name` ist standardmäßig `true` (`profiles.lua:980`) und
  entfernt den Realm bei `:657-658` — für einen Cross-Realm-Spieler bleibt das
  blanke „Torvi", genau der Kollisionsvektor, um den sich Zeile 340 sorgt. (Die
  `>`-Form bei `:802` ist der PET-Zweig; wir filtern auf `IsPlayer()`, er kann
  uns nicht erreichen.)
- Translit ist standardmäßig aus, romanisiert aber **an Ort und Stelle**, wenn
  eingeschaltet (`class_damage.lua:3921-3925`) — ein einziges Rendern irgendwo
  lässt den geteilten Akteur dauerhaft „!Ivan" für „Иван" tragen.

Jedes davon wäre hier als Identität persistiert worden — und `blizzdm.lua:909`
schreibt `cached.name` auf eine Blizzard-eigene Zeile. Wir hätten also eine von
uns erfundene Schreibweise unter fremde Balken gesetzt. Ein Name, den wir nicht
zuschreiben können, ist schlimmer als kein Name, und `nome` wird nie
umgeschrieben.

Der Rückwärts-Fallback über `nameOnly` in `ResolveGUIDByName` deckt übrig
gebliebene blanke Einträge weiterhin ab.

### Inline-Tagging statt Ticker — der Flicker-Fix {#inline-tagging}

Die versiegelte Zeile wird **hier** getaggt, innerhalb von Details!' eigenem
`SetText`-Aufruf, nicht nur aus dem 2-Sekunden-Ticker.

Das ist die Behebung des am 20.08.2026 live gemeldeten Flackerns. Eine Zeile,
die wir **lesen** können, wird bei jedem Neuzeichnen synchron neu getaggt, weil
dieser Hook innerhalb von Details!' `SetText` läuft und anhängt, bevor das Bild
gezeichnet wird — dieser Pfad hat nie geflackert. Eine **versiegelte** Zeile
wurde früher nur vom Ticker getaggt, also ließ jedes Neuzeichnen von Details! sie
nackt zurück, bis zu zwei Sekunden lang. Das Tag erschien und verschwand — das
war „Details blinkt". Es erklärt auch die scheinbaren Lücken: Ein Screenshot
erwischt die Hälfte des Zyklus, die gerade zu sehen ist.

Das hängt ausdrücklich **nicht** davon ab, wie oft Details! neu zeichnet. Sobald
das Tag im selben Aufruf geschrieben wird wie der Text, zu dem es gehört, gibt es
kein Einzelbild, in dem die ungetaggte Fassung auf dem Schirm steht.

Die Identität ist hier **besser** als auf dem Ticker, nicht schlechter: Details!
setzt `instanceLine.actorGUID` bei `class_damage.lua:3129` und schreibt
`lineText1` bei `:3199` — dieselbe Funktion, derselbe Aufruf, GUID zuerst. Wenn
wir laufen, gehört die GUID neben dem Secret auch wirklich zu ihm und ist keine
Hinterlassenschaft eines früheren Bewohners.

`isOurSetText` wird um den Aufruf herum gesetzt, damit unser eigenes `SetText`
in den Wächter am Kopf dieses Hooks läuft: Der getaggte String kann nie als
Details!' Original eingefangen werden, das Tag kann sich also nicht verdoppeln.
`SafeCall` verhindert, dass ein Wurf `isOurSetText` auf `true` stranden lässt —
das würde das Taggen für den Rest der Sitzung still abwürgen.

### Das `stale`-Flag — drei tragende Gründe {#stale-flag}

`stale` heißt „ein INSPECT ist geschuldet", und nur ein `INSPECT_READY` darf es
löschen. Drei Gründe, alle tragend:

1. **Ein bestehendes Flag mitnehmen.** Ein Bosskill flaggt die ganze Gruppe und
   reiht einen Re-Inspect ein; LibOpenRaid sendet die Ausrüstung ein paar
   Sekunden nach Kampfende erneut. Ohne das käme der LoR-Schreibvorgang zuerst,
   löschte das Flag und annullierte den Re-Inspect nach dem Kill für alle.
2. **Eines setzen, wenn wir diesen Spieler nie inspiziert haben.** LoR liefert
   ein Item Level, nie einen Set-Bonus — der hat für Gruppenmitglieder genau
   einen Erzeuger, den Inspect-Pfad. Ein LoR-Schreibvorgang ohne Flag sieht aus
   wie ein abgeschlossener Inspect: vorhanden, nicht stale, null Sekunden alt.
   Die Warteschlange fragte dann nie, `setBonusCache` bliebe leer, und das
   `[2P]`/`[4P]`-Tag verschwände still für jeden, den LoR abdeckt.
3. **Eines erneut setzen, sobald der Inspect-Horizont abgelaufen ist.** Der
   frühe Ausstieg oben greift nur bei UNVERÄNDERTEM Item Level innerhalb von
   300 s, also schreibt jede spätere Lieferung `.time` neu — und LibOpenRaid
   sendet die Ausrüstung der ganzen Gruppe nach **jedem** Kampfende erneut,
   nicht nur bei Änderungen. Ohne diese Klausel wird `.time` schneller
   aufgefrischt als `CACHE_REFRESH`, das Warteschlangen-Tor kann nie wieder
   feuern, und der 2-Stunden-Re-Inspect, der ein veraltetes `[2P]`/`[4P]` neben
   einer frischen Zahl in Rente schickt, ist für jeden weg, den LoR abdeckt.

Bewusst **nicht** an „das Item Level hat sich geändert" gekoppelt: Unsere Zahl
kommt aus der Inspect-API, LoRs aus `GetAverageItemLevel`. Eine dauerhafte
Abweichung um einen Punkt würde den ganzen Raid nach jedem Pull neu einreihen.
Der Horizont feuert höchstens einmal pro Spieler und 2 Stunden und fängt auch
einen Tier-Tausch bei gleichem Item Level.

### Der Settings-Router — ein Ort statt zwanzig {#settings-router}

Die Slash-Zweige setzen `db` direkt und rufen dann die Details!-seitige
Auffrischung auf, die sie gerade brauchen. Das funktionierte, solange Details!
die einzige Oberfläche war. Jetzt ist es falsch: Der Router ist das, was den
**anderen** Renderern mitteilt, dass sich eine Einstellung bewegt hat, und der
Slash-Pfad erreichte ihn nie. Also räumte `/dilvl off` die Details!-Balken und
die Unit-Frame-Oberflächen ab und ließ jedes Tag auf Blizzards Meter stehen —
während derselbe Schalter im Optionsfenster, der durch den Router geht, sauber
aufräumte. Live gemeldet am 20.08.2026. `/dilvl blizzdm` hatte dasselbe Loch.

Behoben an dieser einen Stelle statt an den zwanzig Zuweisungsstellen, weil eine
Behebung pro Stelle eine Behebung ist, die die einundzwanzigste Stelle nicht
bekommt. Schlüssel schnappschießen, Befehl ausführen, weiterreichen, was sich
tatsächlich geändert hat. Ein künftiger Befehl ist damit von Bauart her
abgedeckt.

Die eingebauten Auffrischungen in den Zweigen bleiben unangetastet. Eine davon
doppelt laufen zu lassen kostet einen überflüssigen Durchlauf bei einem Befehl,
den der Nutzer von Hand getippt hat — also nichts —, und sie zu entfernen hieße,
zwanzig Zweige für eine nicht messbare Ersparnis neu zu testen.

---

## blizzdm.lua

### Das Rang-Präfix ist lokalisiert — und nur bei Blizzard {#rank-prefix}

Das Rang-Präfix, das Blizzard vor einen Namen zeichnet, ist **lokalisiert**, und
es ist nicht immer ein Punkt:

```
enUS/deDE/koKR/ruRU   "%d. %s"
zhCN                  "%d、%s"      (U+3001)
zhTW                  "%d。%s"      (U+3002)
```

Drei Stellen hatten `^%d+%.` fest verdrahtet — zwei Identitäts-Fallbacks, die
Blizzards gerenderten Text lesen, und die Aufteilung, die den Rang vor unserem
Tag hält. Auf einem chinesischen Client traf keine davon zu: Die Fallbacks lösten
still nichts auf, und der Rang wurde aus der Zeile geschoben. Ein fehlendes Tag,
nie ein falsches — genau deshalb konnte das unbemerkt dort sitzen.

Aus Blizzards eigenem Formatstring abgeleitet statt aufgezählt, damit eine
Sprache, die wir nie angesehen haben, mit abgedeckt ist. `gsub` escapt
byteweise, und das ist genau, was wir wollen: Die mehrbyte-Trenner landen als
literale Bytes im Muster.

**Das gilt ausschließlich für BLIZZARDS Meter.** Details! verdrahtet `". "` in
jeder Sprache fest (`Details-Damage-Meter/boot.lua:1332`), die Muster in
`core.lua` und `util.lua` sind also korrekt, wie sie sind, und dürfen **nicht**
umgestellt werden.

### Identitäts-Nachtrag — der Index allein ist kein Beweis {#identity-backfill}

Der `Init`-Hook ist die einzige Stelle, an der Blizzard uns die GUID einer Zeile
gibt, und er feuert genau dann, wenn eine Zeile (neu) befüllt wird. Dieser
Moment ist für uns gleich zweifach falsch: **Während** eines Kampfes ist
`sourceGUID` nicht verfügbar, und sobald der Kampf **endet**, befüllt nichts die
Zeilen neu — sie behalten also die leere Identität, die der letzte
In-Combat-`Init` hinterlassen hat, lesen für den Rest der Sitzung `[NO-GUID]`
und bleiben ungetaggt, obwohl jeder Spieler darauf mit vollem Item Level in
unserem Cache sitzt. Den Fenstermodus von Hand umzuschalten heilt es, und nur
deshalb, weil das einen Neuaufbau erzwingt. Zweimal live gemeldet, 16.08.2026.

Also holen wir die Daten selbst. `GetCombatSession`
(`DamageMeterSessionWindow.lua:562`) ist ein schlichter Getter über
`C_DamageMeter.GetCombatSessionFromType` / `FromID`, und `frame.index` zeigt
direkt auf den Eintrag der Zeile in dieser Liste: `BuildDataProvider` stempelt
`combatSource.index = i` (`:640`), und `Init` kopiert es
(`DamageMeterEntry.lua:477`).

**Der Index allein ist KEIN Beweis.** Die Liste kann zwischen dem letzten `Init`
eines Frames und jetzt umsortiert worden sein, und ihm blind zu vertrauen würde
die Identität eines Spielers der Zeile eines anderen zuteilen — genau das
Versagen, das dieses Addon nicht produziert. Deshalb wird jede Übereinstimmung
gegen die zwei Felder bestätigt, die Blizzard als `NeverSecret` markiert und die
`Init` aus derselben Quelle kopiert hat: `classFilename` und `specIconID`
(`DamageMeterDocumentation.lua:202-203`). Die Schadenssumme gehört **nicht**
dazu — sie trägt überhaupt keine Annotation, genau wie `sourceGUID` (`:199`,
`:204`), ist auf einer versiegelten Zeile also unlesbar und dient nur als
Zusatzbestätigung, wenn sie zufällig verfügbar ist.

Nur außerhalb des Kampfes: `GetCombatSessionFromType` ist `SecretWhenInCombat`
(`DamageMeterDocumentation.lua:39-41`).

### Index-Join Regel 4 — warum gezählt und nicht lizenziert wird {#index-join-rule4}

Regel 4 lautet: Jede **andere** Quelle dieser Klasse und Spezialisierung sitzt
auf einem Index, den ein bestätigter Zeuge belegt hat — diese Zeile ist also der
einzige Platz, der für diese eine übrig bleibt.

Die fensterweite Lizenz allein reicht hier **nicht**, und das war ein echter
Defekt, kein theoretischer. `orderTrusted` wird von zwei Signalen gesetzt:
bestätigte Zeilen, die auf dem Index landen, den sie behaupten, und keine Klasse,
die irgendwo ihrer Quelle widerspricht. Ein Tausch zweier Spieler, die Klasse
**und** Spezialisierung teilen, sendet **keines von beiden** — der Klassenstring
ist an jedem Index unverändert, und solange nicht einer der beiden getauschten
Zeilen selbst ein Zeuge ist, bewegt sich kein Zeuge. Nach einem Kampf ist der
einzige Zeuge meist die eigene Zeile, eine einzige unbewegte Probe hätte also
zwei Dutzend andere lizenziert. Die Regeln 1 bis 3 lehnen für genau diese
Population alle ab, diese Regel war also die entscheidende — und sie hätte den
Namen **und** das Item Level des anderen Spielers auf die Zeile geschrieben,
unter einem Klassensymbol, das weiterhin passte. Nichts auf dem Bildschirm hätte
dem widersprochen, und der direkte Durchlauf überspringt Zeilen, die bereits eine
API-Identität tragen — kein späterer Durchlauf repariert das also.

Angeheftete Positionen zu zählen schließt die Lücke: Eine klassenerhaltende
Vertauschung muss mindestens zwei Mitglieder einer Gruppe bewegen, und wenn jedes
andere Mitglied angeheftet ist, bleibt kein zweites zum Bewegen übrig.

### Injektion in UpdateName — zwei beweisbar sichere Fälle {#updatename-gate}

**Warum es hier überhaupt passieren muss:** Wenn ein Kampf endet, hebt Blizzard
die Geheimhaltung der Namen auf und ruft `UpdateName` — aber die ScrollBox baut
ihre Zeilen **nicht** neu auf, `Init` läuft also nie. Lebte die Injektion nur im
`Init`-Hook, bliebe das ganze Meter nach jedem Pull ungetaggt, bis irgendetwas
einen Neuaufbau erzwingt, etwa das Umschalten des Fenstermodus. Live gemeldet
am 15.08.2026.

**Warum es abgesichert ist:** `UpdateName`s einziger Aufrufer ist `Init` selbst
(`DamageMeterEntry.lua:481`), es feuert also auch mitten im Recycling — wenn
`sourceName` bereits der **neue** Spieler ist, während `_dilvlGUID` noch den
vorherigen hält — und `ResolveFrameGUID` gibt bedingungslos eine API-GUID
zurück. Dann zu schreiben setzte das Item Level des einen Spielers unter den
Namen eines anderen (behoben in `62544d4`).

Zwei Fälle sind beweisbar sicher:

- **Keine API-Identität gespeichert** — `ResolveFrameGUID` löst dann frisch aus
  dem Namen auf, den Blizzard gerade gezeichnet hat, und das ist per Definition
  der aktuelle Bewohner. Das ist der Nach-Kampf-Fall von oben: Der
  In-Combat-`Init` hat die Identität geleert, weil die GUID unlesbar war.
- **Eine API-Identität, deren notierter Eigentümer weiterhin zu `sourceName`
  passt** — die Zeile wurde neu gezeichnet, nicht neu vergeben.

Alles andere ist ein Recycling: überspringen. `CaptureIdentityAndInject`
injiziert einen Moment später mit der korrekten Identität. Ein Tag einen Frame
zu spät schlägt ein falsches Tag jetzt.

### Refresh — Vermutung fliegt, API-Identität überlebt {#refresh-identity}

Eine **geratene** GUID trägt keine Garantie, dass sie noch zu dieser Zeile
gehört, also fliegt sie: Ein wiederverwendetes Frame kann einen **anderen**
Spieler darstellen, während `sourceName` noch geheim ist, und eine erhaltene
Vermutung würde das Item Level des vorherigen Bewohners auf den falschen Balken
malen.

Eine **API-Identität** ist der umgekehrte Fall und muss **überleben**. `Refresh`
re-initialisiert jedes Frame, **bevor** der Rumpf dieses Post-Hooks läuft
(`DamageMeterSessionWindow.lua:747-750`, und `:762` → `SetDataProvider` → der
Initializer, den die ScrollBox synchron ausführt). `CaptureIdentityAndInject` hat
die Identität jedes Frames also bereits geleert und aus Blizzards eigener
`combatSource` neu aufgebaut. Hier noch einmal zu löschen entfernte genau das —
im selben Aufrufstapel, einen Moment später.

Deshalb las jeder Live-Dump `(0 api)`: Die Identität überlebte nur auf Zeilen,
die die ScrollBox durch **Scrollen** erworben hat, dem einzigen Pfad, der nie
durch `Refresh` läuft. Genau deshalb las ein Dump direkt nach dem Scrollen
`(4 api)` für exakt die vier neu freigelegten Zeilen. Die Folge waren keine
falschen Daten, sondern **gar keine**: Ohne API-Identität hat eine Zeile, deren
Namen Blizzard nach einem Kampf weiterhin schützt, nichts, wodurch sie
zugeschrieben werden könnte — sie bleibt ungetaggt, obwohl ihr Item Level in
unserem Cache liegt.

### /dilvl securetest — die beiden Experimente {#securetest}

Aus der Tiefenanalyse vom 21.08.2026. **Nur von Hand.** Nichts hierin läuft je
von selbst. Beide Experimente sondieren undokumentiertes Verhalten, und
undokumentiertes Verhalten ist genau das, was Blizzard ohne Vorwarnung unter uns
ändern darf — keines darf also zu einem automatischen Codepfad werden, außer eine
spätere Version sichert es mit einer Versions-Kanarie **und** einem Kill-Switch
ab, als **Fallback** hinter den dokumentierten Pfaden. Entscheidung des
Maintainers, 21.08.2026, und die richtige.

**E2 „guid":** Das an jede versiegelte Zeile gebundene ScrollBox-Element hält
noch die versiegelte `sourceGUID` aus dem Kampf. `UnitTokenFromGUID` /
`UnitNameFromGUID` / `GetPlayerInfoByGUID` sind
`SecretArguments=AllowedWhenTainted`, und ihr Geheimhaltungs-Prädikat
(`SecretWhenUnitIdentityRestricted`) dokumentiert eine Ausnahme für
Gruppen-/Raidmitglieder. Die versiegelte GUID hineinzureichen ist also legal; ob
die **Rückgabe** lesbar ist, ist der undokumentierte Teil. Jeder Aufruf ist
`pcall`'t, jede Rückgabe wird vor jedem Vergleich `issecretvalue`-geprüft — nur
Lesen, keine Schreibvorgänge, kein Blizzard-Code angetrieben: null Taint-Risiko.
Eine lesbare Rückgabe wäre ein Zeuge pro Zeile, und die „ambiguous"-Ablehnungen
stürben.

**E1 „cvarflip":** `SetCVar("damageMeterEnabled", 0 dann 1)` lässt Blizzards
eigenen CVar-Handler das Meter verstecken und wieder zeigen, und `OnShow` ruft
`Refresh` — das programmatische Gegenstück zum Segment-Umschalten des Nutzers.
Aus der Dokumentation **nicht entscheidbar**, ob diese Zustellung unseren Taint
erbt (`CVAR_UPDATE` ist `SynchronousEvent`, aber die Cache-Behandlung in
`CvarUtil` legt nahe, dass die Zustellung sicher beginnt). Daher ein Experiment,
hart abgesichert:

- verweigert im Kampf (volles Gatter) und innerhalb eines aktiven Keystones —
  zwischen M+-Trashgruppen flackert die Beschränkung, und ein Flip im falschen
  Moment ist genau das Chaos, das der Maintainer vorhergesagt hat
- verweigert, solange das Meter nicht gezeigt wird, die CVar nicht `"1"` liest
  und nicht tatsächlich versiegelte Zeilen existieren (sonst beweist das Ergebnis
  nichts)
- verlangt das wörtliche Argument `"confirm"`, nachdem das Wiederherstellungs-
  Protokoll gedruckt wurde
- **ein** Lauf pro Sitzung. Wirft Blizzards Handler, taucht der Fehler in BugSack
  auf, nicht in unserem `pcall` — nach jedem Lauf bleibt der Riegel also unten,
  und die Wiederherstellung ist die Einstellungs-Checkbox oder `/reload`,
  **niemals** ein zweiter Flip (ein fehlgeschlagener Lauf vergiftet den
  CVar-Cache, erneutes Feuern vergiftet ihn erneut).

### Der automatische Nach-Kampf-Nachtrag {#auto-backfill}

Der E1-CVar-Bounce als **Fallback**, live bewiesen am 21.08.2026 (manuelles
`/dilvl securetest cvarflip`, Ausgang (a)): `SetCVar("damageMeterEnabled","0"→"1")`
bringt Blizzards **eigenen** Handler dazu, das Meter zu verstecken und wieder zu
zeigen; `OnShow` ruft `Refresh`, das jede Zeile aus nach dem Kampf lesbaren
Gettern neu aufbaut, in Blizzards eigener sicherer Ausführung. 25 versiegelte
Zeilen wurden bei t+0 lesbar, Sitzungen intakt, kein Fehler geworfen.

Fallback-Disziplin, die ausdrückliche Bedingung des Maintainers: Das feuert nur,
**nachdem** die dokumentierten Pfade ihre Chance hatten, und nur, wenn sie
versiegelte Zeilen hinterlassen haben. Einmal pro Kampf scharf gestellt,
verweigert innerhalb eines aktiven Keystones, verweigert bei jedem Kampfsignal,
und wenn ein Bounce je die Zahl der versiegelten Zeilen nicht senkt, nimmt es an,
Blizzard habe das undokumentierte Verhalten unter uns geändert, und schaltet sich
für den Rest der Sitzung ab — der Kill-Switch, ohne den dieses Feature nicht
ausgeliefert werden durfte. `/dilvl autorefresh` schaltet es ganz aus.

Der sichtbare Preis: Das Meter blinkt für einen Frame, wenn der Bounce feuert.
