# Changelog

## v1.3.0

### New

- **Blizzard Damage Meter integration** — iLvl and tier set bonus displayed on WoW's built-in Damage Meter (12.0+). Experimental feature, auto-enabled when Details! is not installed. Force on/off with `/dilvl blizzdm` (#9)
- Works on DPS, Healing, and Overall windows simultaneously
- Fully **event-driven** — no timers, no polling
- **Defensive combat guard** — during combat the addon does absolutely nothing on Blizzard DM frames. Tags are stripped at combat start, re-applied when combat ends
- Supports LFR 25-man, cross-realm players, and special characters in names

### Fixed

- **Cross-realm GUID resolution** — `ResolveGUIDByName` now correctly matches players on non-connected realms using `GetUnitName(unit, true)` with `Ambiguate`. Previously, cross-realm players like "Skizzor-Blackrock" could fail to match because `UnitName` returns just "Skizzor"
- **StripAllTags uses pattern matching** — combat-start tag removal now strips our tags via Lua pattern instead of relying on `GetNameText()` which can cache our own tags in Blizzard's dirty-check

### Known Limitations (Blizzard DM)

- After combat ends, DPS/Overall windows may need a quick window toggle (A→G→A) to show all tags. Healing window updates automatically. See #12
- Do not `/reload` during combat — Blizzard recreates frames with locked data that cannot be read afterwards

---

## v1.2.1

### Improved

- **Smart cache refresh** — group members are automatically re-inspected when they equip new gear (`UNIT_INVENTORY_CHANGED`), so iLvl updates without manual refresh
- **Ambiguate cleanup** — replaced manual realm-stripping regex with WoW's built-in `Ambiguate()` API for more reliable cross-realm name matching (#10)

---

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
