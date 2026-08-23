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
hält sie aktuell, und wir erben das umsonst. Fünf der sechs Grenzen sind Werte,
die Blizzard definiert, nicht Werte, die wir erfunden haben.

| Band | Grenze | Bedeutung |
|---|---|---|
| artifact | `>= reward(+10)` | jenseits dessen, was Mythic+ überhaupt ausgibt |
| legendary | `>= reward(+7)` | |
| epic | `>= reward(+4)` | |
| rare | `>= reward(+2)` | der Season-Boden: aktueller Content begonnen |
| uncommon | `>= reward(+2) - 20` | die eine erfundene Zahl, und die mildeste |
| poor | darunter | |

Die Farben kommen aus `C_Item.GetItemQualityColor`, aus demselben Grund: wenn
Blizzard je die Palette nachjustiert, folgen wir, statt zu driften.

`U.ILVL_COLORS` im Code ist der **Fallback**, in derselben Zeilenform gehalten,
damit jeder Konsument unverändert weiterläuft, wenn die API nichts sagt. Es ist
eine Momentaufnahme und **wird verrotten**: die abgeleiteten Season-2-Werte,
gemessen in-game am 18.08.2026 (Schlüssel 2/4/7/10 lieferten 305/308/315/318).
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
