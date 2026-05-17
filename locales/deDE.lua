-- locales/deDE.lua — German overrides, only loaded on deDE clients.
--
-- Hasan ist DE-native, daher von Tag 1 dabei. Andere Locales (frFR, esES,
-- ruRU, ...) koennen Community per PR im Locales/-Folder beisteuern, ohne
-- dass wir Core anfassen muessen. Missing keys fallen via Metatable in
-- enUS.lua zurueck — kein Crash, einfach English-Anzeige.

if GetLocale() ~= "deDE" then return end

local addonName, ns = ...
local L = ns.L

---------------------------------------------------------------
-- Window chrome
---------------------------------------------------------------
L["Settings"]                   = "Einstellungen"
L["Open Settings"]              = "Einstellungen oeffnen"
L["Close"]                      = "Schliessen"

---------------------------------------------------------------
-- Tabs
---------------------------------------------------------------
L["General"]                    = "Allgemein"
L["Output Channels"]            = "Ausgabe-Kanaele"
L["Live Preview"]               = "Live-Vorschau"
L["Diagnostics"]                = "Diagnose"

---------------------------------------------------------------
-- Page: General
---------------------------------------------------------------
L["GENERAL_INFO"]               = "Erkennt automatisch was du installiert hast. Einzelne Oberflaechen im Tab 'Ausgabe-Kanaele' umschalten."
L["Master Toggles"]             = "Haupt-Schalter"
L["Enable Details! iLvl Display"] = "Details! iLvl-Anzeige aktivieren"
L["TOOLTIP_MASTER_ENABLE"]      = "Haupt-Schalter fuer das ganze Addon. Deaktivieren um alle Ausgabe-Kanaele still zu legen ohne deinstallieren."
L["Color by gear tier"]         = "Farbe nach Gegenstands-Stufe"
L["TOOLTIP_COLOR"]              = "Faerbt die iLvl-Zahl nach Gegenstands-Qualitaet: Orange=BiS, Lila=hoch, Blau=mittel, Gruen=niedrig, Grau=Basis."
L["Show 2P/4P set bonus"]       = "2P/4P Set-Bonus anzeigen"
L["TOOLTIP_SETBONUS"]           = "Zeigt den Set-Bonus neben der iLvl, z.B. 'Razul [263] [4P]'."

L["Display"]                    = "Darstellung"
L["Layout (Details!)"]          = "Layout (Details!)"
L["Inline"]                     = "Inline"
L["Columns"]                    = "Spalten"
L["TOOLTIP_LAYOUT"]             = "Inline: an Spielername angehaengt. Spalten: separate rechts-buendige Spalten (nur Details!, sichtbar im Kampf)."

L["Position"]                   = "Position"
L["Left of name"]               = "Links vom Namen"
L["Right of name"]              = "Rechts vom Namen"
L["TOOLTIP_POSITION"]           = "Wo der iLvl-Tag relativ zum Spielernamen sitzt. Gilt fuer Details! und Blizzard DM."

L["Auto-detected"]              = "Automatisch erkannt"
L["AUTODETECT_DESCRIPTION"]     = "Erkannte Oberflaechen in deinen installierten Addons:"

---------------------------------------------------------------
-- Page: Output Channels
---------------------------------------------------------------
L["CHANNELS_INFO"]              = "Jeden Ausgabe-Kanal unabhaengig umschalten. Jeder Kanal deaktiviert sich automatisch nach 5 Fehlern, ohne die anderen zu beeinflussen."
L["Details! bars"]              = "Details! Balken"
L["ElvUI tags"]                 = "ElvUI Tags"
L["Grid2 status"]               = "Grid2 Status"
L["Danders Frames overlay"]     = "Danders Frames Overlay"
L["Blizzard DM"]                = "Blizzard DM"

L["ElvUI Tag Format"]           = "ElvUI Tag-Format"
L["Brackets: [dilvl]"]          = "Klammern: [dilvl]"
L["Plain: [dilvl:plain]"]       = "Schlicht: [dilvl:plain]"

L["Danders Anchor Position"]    = "Danders Anker-Position"
L["Inside frame"]               = "Im Frame"
L["Outside frame"]              = "Ausserhalb Frame"
L["Danders Font Size"]          = "Danders Schriftgroesse"
L["TOOLTIP_DANDERS_SIZE"]       = "Groesse des iLvl-Texts auf Danders Frames. Bereich 6-30, live-Update ohne /reload."

L["Blizzard DM Mode"]           = "Blizzard DM Modus"
L["Auto"]                       = "Automatisch"
L["Forced On"]                  = "Erzwungen An"
L["Forced Off"]                 = "Erzwungen Aus"
L["TOOLTIP_BLIZZDM_MODE"]       = "Automatisch: an wenn Details! fehlt. Erzwungen An/Aus ueberschreibt die Auto-Erkennung."

---------------------------------------------------------------
-- Page: Live Preview
---------------------------------------------------------------
L["PREVIEW_INFO"]               = "Mock-Frames updaten live waehrend du Einstellungen aenderst. Sie zeigen keine echten Unit-Daten — nur Styling-Beispiele."
L["Damage Meter Preview"]       = "Damage Meter Vorschau"
L["Unit Frame Preview"]         = "Unit Frame Vorschau"

---------------------------------------------------------------
-- Page: Diagnostics
---------------------------------------------------------------
L["DIAGNOSTICS_INFO"]           = "Wenn du einen Bug findest, kopiere die untenstehende Ausgabe und schicke sie als CurseForge-Kommentar oder GitHub-Issue."
L["Refresh"]                    = "Aktualisieren"
L["Reset UI Error Counters"]    = "UI-Fehler-Zaehler zuruecksetzen"
L["Manual Re-inspect"]          = "Manuelles Re-Inspect"

---------------------------------------------------------------
-- Footer
---------------------------------------------------------------
L["FOOTER_HINT"]                = "/dilvl debug fuer Bug-Reports"

---------------------------------------------------------------
-- Error placeholders
---------------------------------------------------------------
L["PAGE_BROKEN_TITLE"]          = "Einstellungs-Seite defekt"
L["PAGE_BROKEN_BODY"]           = "Seite '%s' wurde nach %d Fehlern deaktiviert.\nAndere Seiten funktionieren weiter. Nutze /dilvl Slash-Befehle\noder /reload zum Wiederherstellen."
L["PAGE_BROKEN_LAST"]           = "Letzter Fehler: %s"
