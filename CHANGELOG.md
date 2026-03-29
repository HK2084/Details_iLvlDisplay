# Changelog

## [1.4] - 2026-03-29
- Added custom HK icon for addon list
- Version strings unified across .toc and slash commands
- Fix: `CanInspect(unit, true)` → `false` — verhindert Error-Message-Spam beim stillen Inspect-Check
- Fix: `ClearInspectPlayer()` nach INSPECT_READY hinzugefügt — gibt Inspect-State frei, WoW monitored Spieler nicht mehr unnötig weiter
- Fix: Inspect-Delay nach INSPECT_READY von 0.3s auf 1.0s erhöht — verhindert Server-Throttle in größeren Raids (throttled Requests feuern kein Event)

## [1.3] - 2026-03-29
- Fix: RefreshAllBarTexts now always runs on tick, not only when map is dirty
- Fix: Inspect queue no longer skips players outside CanInspect range at queue time (range check deferred to inspect time)
- Fix: mapDirty flag now set on PLAYER_REGEN_ENABLED to rebuild iLvl map after every fight

## [1.2] - 2026-03-28
- Perf: lazy map rebuild via mapDirty flag — RebuildNameIlvlMap only called when new inspect data arrives
- Perf: early instance loop exit if Details instance not found

## [1.1] - 2026-03-28
- Fix: cross-realm player iLvl display (strips realm suffix for name matching)
- Fix: iLvl tags now refresh correctly after combat ends

## [1.0] - 2026-03-28
- Initial release
- Shows item level next to player names on Details! bars
- Color-coded by gear tier
- Automatic group/raid inspect with 10-minute cache
- `/dilvl` slash command
