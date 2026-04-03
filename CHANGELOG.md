# Changelog

## v1.2.0

### New

- **Column layout mode** — `/dilvl layout columns` shows iLvl and tier set as separate right-aligned columns, visible during combat. When bars swap positions, columns briefly disappear and reappear with the correct player's data
- Tiered resize: tier column hides first on narrow windows, iLvl column last
- Debug source tracking and queue info

### Fixed

- Own iLvl wrong during combat — LibOpenRaid SELF guard (#6)
- Cache purge too aggressive — removed, 2h TTL handles expiry (#5)
- Column data wrong during bar reshuffles (#7)
- Column spacing lost after /reload in instances
- SELF-Priority — always uses `GetAverageItemLevel()` for own GUID
- Tier bonus missing after login — event-driven re-check
- Debug print crash on table entries in inspect queue

---

## v1.1.1

### Fixed

- **Addon broken inside instances** — `InCombatLockdown()` returns a secret value in WoW 12.0+ dungeons/raids, making the addon think you're permanently in combat. Inspects, bar refreshes, and roster updates were all blocked
- Wrong version string in chat — now reads from TOC dynamically

---

## v1.1.0

### New

- **LibOpenRaid-1.0 integration** — players running Details! now share iLvl instantly via addon-comm, no inspect delay
- **Secret value guard** — proactive `issecretvalue()` check (WoW 12.0+) catches tainted strings before they can crash

### Changed

- `/dilvl debug` now shows LibOpenRaid status (`active` / `n/a`)

---

## v1.0.2

### Fixed

- Own iLvl not updating after gear swap
- ElvUI-only mode (works without Details! loaded)
- Secret string crashes with Details! Itemlevelfinder
- LFR late unit tokens — all 25 players get tagged now
- Inspect queue deadlock — 15s safety timeout added

---

## v1.0.0 — First Public Release

- Item level display on Details! bars
- Color-coded by gear tier
- 2P/4P tier set bonus detection (Midnight Season 1)
- Automatic group inspect with 2h persistent cache
- Re-inspect after boss kills
- Cross-realm, LFR/LFD support
- ElvUI `[dilvl]` tag for party/raid frames
- `/dilvl` slash command suite
