# Changelog

## [1.5] - 2026-03-29

### Fixes from live testing

- Fix: players out of inspect range at dungeon start now retry up to 3 times (re-queued to end of inspect queue). Previously they were silently dropped until after the first fight.
- Fix: taint crash "attempt to index secret string" in RefreshAllBarTexts — GetText() returns our own injected text which WoW marks as tainted. Now caching Details!'s original clean text in the SetText hook (barCleanText table) and never calling GetText() again.
- Fix: multiple ticker bug — PLAYER_ENTERING_WORLD fires on every zone transition. Without a guard, rapid zoning within 3s created multiple C_Timer.NewTicker instances and OnTick ran multiple times per interval. Fixed with tickerStarted flag.
- Fix: isOurSetText could get stuck as true if SetText raised an error mid-loop, permanently disabling the injection hook. Wrapped in pcall with guaranteed reset.

## [1.4] - 2026-03-29

### Release preparation

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
