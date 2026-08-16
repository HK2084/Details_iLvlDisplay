-- locales/deDE.lua — German overrides, only loaded on deDE clients.
--
-- Community translations (frFR, esES, ruRU, ...) can be added as additional
-- Locales/ files without touching the core. Missing keys fall back via the
-- enUS metatable, so a partial translation never crashes.
--
-- File must be UTF-8.

if GetLocale() ~= "deDE" then return end

local addonName, ns = ...
local L = ns.L

---------------------------------------------------------------
-- Window chrome
---------------------------------------------------------------
L["Open Settings"]              = "Einstellungen öffnen"

---------------------------------------------------------------
-- Tabs
---------------------------------------------------------------
L["General"]                    = "Allgemein"
L["Output Channels"]            = "Ausgabe-Kanäle"
L["Diagnostics"]                = "Diagnose"

---------------------------------------------------------------
-- Page: General
---------------------------------------------------------------
L["GENERAL_INFO"]               = "Erkennt automatisch was du installiert hast. Einzelne Oberflächen im Tab 'Ausgabe-Kanäle' umschalten."
L["Master Toggles"]             = "Haupt-Schalter"
L["Enable Details! iLvl Display"] = "Details! iLvl-Anzeige aktivieren"
L["TOOLTIP_MASTER_ENABLE"]      = "Haupt-Schalter für das ganze Addon. Deaktivieren um alle Ausgabe-Kanäle still zu legen ohne deinstallieren."
L["Color by gear tier"]         = "Farbe nach Gegenstands-Stufe"
L["TOOLTIP_COLOR"]              = "Färbt die iLvl-Zahl nach Gegenstands-Qualität: Orange=BiS, Lila=hoch, Blau=mittel, Grün=niedrig, Grau=Basis."
L["Show 2P/4P set bonus"]       = "2P/4P Set-Bonus anzeigen"
L["TOOLTIP_SETBONUS"]           = "Zeigt den Set-Bonus neben der iLvl, z.B. 'Razul [263] [4P]'."

L["Display"]                    = "Darstellung"
L["Layout (Details!)"]          = "Layout (Details!)"
L["Inline"]                     = "Inline"
L["Columns"]                    = "Spalten"
L["TOOLTIP_LAYOUT"]             = "Inline: an Spielername angehängt. Spalten: separate rechtsbündige Spalten (nur Details!, sichtbar im Kampf)."

L["Position"]                   = "Position"
L["Left of name"]               = "Links vom Namen"
L["Right of name"]              = "Rechts vom Namen"
L["TOOLTIP_POSITION"]           = "Wo der iLvl-Tag relativ zum Spielernamen sitzt. Gilt für Details! und Blizzard DM."

L["Auto-detected"]              = "Automatisch erkannt"
L["AUTODETECT_DESCRIPTION"]     = "Erkannte Oberflächen in deinen installierten Addons:"

---------------------------------------------------------------
-- Page: Output Channels
---------------------------------------------------------------
L["CHANNELS_INFO"]              = "Jeden Ausgabe-Kanal unabhängig umschalten. Jeder Kanal deaktiviert sich automatisch nach 5 Fehlern, ohne die anderen zu beeinflussen."
L["Details! bars"]              = "Details! Balken"
L["ElvUI tags"]                 = "ElvUI Tags"
L["Grid2 status"]               = "Grid2 Status"
L["Danders Frames overlay"]     = "Danders Frames Overlay"
L["Blizzard DM"]                = "Blizzard DM"

L["ELVUI_TAGS_HINT"]            = "Wähle [dilvl] (Klammern: Razul [263]) oder [dilvl:plain] (schlicht: Razul 263) in einem ElvUI Custom Text. Beide Tags stehen im ElvUI Tag-Browser."
L["GRID2_HINT"]                 = "Indikator-Platzierung in Grid2's GUI konfigurieren (Status -> dilvl)."

L["Danders Anchor Position"]    = "Danders Anker-Position"
L["Danders Font Size"]          = "Danders Schriftgröße"
L["TOOLTIP_DANDERS_SIZE"]       = "Größe des iLvl-Texts auf Danders Frames. Bereich 6-30, live-Update ohne /reload."

L["Details Window"]             = "Details! Fenster"
L["All windows"]                = "Alle Fenster"
L["Window 1"]                   = "Fenster 1"
L["Window 2"]                   = "Fenster 2"
L["Window 3"]                   = "Fenster 3"
L["Window 4"]                   = "Fenster 4"
L["Window 5"]                   = "Fenster 5"
L["TOOLTIP_DETAILS_WINDOW"]     = "Zeigt iLvl nur in EINEM Details!-Fenster statt in allen. 'Alle Fenster' ist Standard. Slash: /dilvl details window <all|1-10>."
L["Details Font Size"]          = "Details! Schriftgröße"
L["TOOLTIP_DETAILS_SIZE"]       = "Feste iLvl-Textgröße auf Details!-Balken (nur Spalten-Layout). Schieberegler 6-30; '/dilvl details size 0' nutzt Details' eigene Schrift."
L["DETAILS_SIZE_INLINE_NOTE"]   = "ⓘ Schriftgröße gilt im Spalten-Layout — Layout im Tab Allgemein umschalten."

L["Blizzard DM Mode"]           = "Blizzard DM Modus"
L["Auto"]                       = "Automatisch"
L["Forced On"]                  = "Erzwungen An"
L["Forced Off"]                 = "Erzwungen Aus"
L["TOOLTIP_BLIZZDM_MODE"]       = "Automatisch: an wenn Details! fehlt. Erzwungen An/Aus überschreibt die Auto-Erkennung."

---------------------------------------------------------------
-- Page: Live Preview
---------------------------------------------------------------
L["Damage Meter Preview"]       = "Damage Meter Vorschau"
L["Unit Frame Preview"]         = "Unit Frame Vorschau"
L["PREVIEW_UF_CAPTION"]         = "Beispiel-Frame — Grid2 / ElvUI rendern analog"

---------------------------------------------------------------
-- Page: Diagnostics
---------------------------------------------------------------
L["DIAGNOSTICS_INFO"]           = "Wenn du einen Bug findest, kopiere die untenstehende Ausgabe und schicke sie als CurseForge-Kommentar oder GitHub-Issue."
L["Refresh"]                    = "Aktualisieren"
L["Reset UI Error Counters"]    = "UI-Fehler-Zähler zurücksetzen"
L["Reset to Defaults"]          = "Auf Standard zurücksetzen"
L["RESET_DEFAULTS_CONFIRM"]     = "ALLE Einstellungen auf Standardwerte zurücksetzen?\n\nDein iLvl-Cache und die Fenster-Position bleiben erhalten."

---------------------------------------------------------------
-- Footer
---------------------------------------------------------------
L["FOOTER_HINT"]                = "/dilvl debug für Bug-Reports"
L["BLIZZ_PANEL_SLASH_HINT"]     = "Slash: /dilvl   |   /dilvl debug für Diagnose"

---------------------------------------------------------------
-- Error placeholders
---------------------------------------------------------------
L["PAGE_BROKEN_TITLE"]          = "Einstellungs-Seite defekt"
L["PAGE_BROKEN_BODY"]           = "Seite '%s' wurde nach %d Fehlern deaktiviert.\nAndere Seiten funktionieren weiter. Nutze /dilvl Slash-Befehle\noder /reload zum Wiederherstellen."
L["PAGE_BROKEN_LAST"]           = "Letzter Fehler: %s"

---------------------------------------------------------------
-- Page: What's New
---------------------------------------------------------------
L["What's New"]                 = "Neuigkeiten"
L["WHATSNEW_INFO"]              = "Die neuesten Features, neueste zuerst. Bugfixes stehen in der unten verlinkten Versions-Historie."
L["WHATSNEW_HISTORY"]           = "Vollständige Versions-Historie:"
L["WN_156_SEASON"]              = "Tier-Sets nach Season"
L["WN_156_SEASON_D"]            = "Der Bonus der aktuellen Season ist grün, der einer älteren grau. Wer gerade umsteigt, zeigt beide nebeneinander — die ältere zuerst."
L["WN_150_UI"]                  = "Einstellungs-Fenster"
L["WN_150_UI_D"]                = "Dieses Fenster — alle Optionen an einem Ort, keine Slash-Befehle mehr merken."
L["WN_150_SIZE"]                = "Details!-Textgröße"
L["WN_150_SIZE_D"]              = "Feste iLvl-Textgröße auf Details!-Balken (Spalten-Layout)."
L["WN_150_WINDOW"]              = "Pro-Fenster-Anzeige"
L["WN_150_WINDOW_D"]            = "iLvl nur in einem Details!-Fenster statt in allen anzeigen."
L["WN_144_DANDERS"]             = "Danders Frames Textgröße"
L["WN_144_DANDERS_D"]           = "Einstellbare iLvl-Textgröße plus Anker-Positionen außerhalb des Frames."
L["WN_143_ELVUI"]               = "ElvUI Plain-Tag"
L["WN_143_ELVUI_D"]             = "[dilvl:plain] — die nackte iLvl-Zahl ohne Klammern."
