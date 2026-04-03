# Release History

Full changelog for all versions. Current release notes: [CHANGELOG.md](CHANGELOG.md)

---

## v1.2.0

### New

- **Column layout mode** — `/dilvl layout columns` shows iLvl and tier set as separate right-aligned columns, positioned left of Details!' DPS/total columns
- Columns visible **during combat** (inline mode still pauses during combat). In instances, columns briefly hide during bar reshuffles (WoW SECRET value protection) and reappear with correct data once Details! finishes updating
- Tiered resize: tier column hides first on narrow windows, iLvl column last
- `/dilvl layout inline` to switch back to classic mode
- Debug source tracking — `[SELF]`, `[INSPECT]`, `[LOR]`, `[DETAILS]` per cache entry
- Debug queue info — shows pending inspects and last inspect result

### Fixed

- **Own iLvl wrong during combat** — LibOpenRaid GearUpdate could overwrite the accurate `GetAverageItemLevel()` value with stale sync data from other players (#6)
- **Cache purge too aggressive** — removed zone-change purge entirely, 2h TTL handles expiry (#5)
- **Column spacing lost after /reload in instances** — column layout cache now persists in SavedVariables
- **Debug print crash** — `/dilvl debug` crashed when inspect queue contained table entries instead of plain strings
- **SELF-Priority** — own GUID now skips Details API and INSPECT_READY (always uses `GetAverageItemLevel()`)
- **Tier bonus missing after login** — `GET_ITEM_INFO_RECEIVED` event triggers tier re-check instead of relying on timers
- **Column data wrong during bar reshuffles** — in instances, columns briefly hide during DPS ranking changes instead of showing stale data from the previous player (#7)

---

## v1.1.1

### Fixed
- **Addon broken inside instances** — `InCombatLockdown()` returns a secret value in WoW 12.0+ instances, making the addon think you're permanently in combat. Inspect queue, bar refreshes, and roster updates were all blocked
- Wrong version string in chat (#1) — hardcoded strings replaced with dynamic TOC lookup

---

## v1.1.0

### New
- **LibOpenRaid-1.0 integration** — players running Details! now share iLvl instantly via addon-comm, no inspect delay
- **Secret value guard** — proactive `issecretvalue()` check (WoW 12.0+) catches tainted strings before they can crash

### Changed
- `/dilvl debug` now shows LibOpenRaid status

---

## v1.0.2

### Fixed
- Own iLvl not updating after gear swap
- ElvUI-only mode (works without Details! loaded)
- Secret string crashes with Details! Itemlevelfinder
- LFR late unit tokens — all 25 players get tagged now
- Inspect queue deadlock — 15s safety timeout added
- Slash commands now apply immediately instead of waiting for next tick

---

## v1.0.0 — First Public Release

- Item level display on Details! bars: `Quinroth [252]`
- Color-coded by gear tier
- 2P/4P tier set bonus detection (Midnight Season 1)
- Automatic group inspect with 2h persistent cache
- Re-inspect after boss kills
- Cross-realm, LFR/LFD support
- ElvUI `[dilvl]` tag for party/raid frames
- `/dilvl` slash command suite
