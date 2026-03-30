# Changelog

Versioning: `MAJOR.MINOR.PATCH`
- **PATCH** — bug fix, tier IDs update for new season
- **MINOR** — new user-facing feature
- **MAJOR** — core rewrite or new WoW expansion (API breaking)

---

## [1.0.0] - 2026-03-30 — First Public Release

### Features
- Shows item level in brackets next to every player name on Details! damage meter bars: `Quinroth [252]`
- Color-coded by gear tier (orange = BiS, purple = high, blue = normal, green = low, grey = base)
- **2P/4P tier set bonus display** — `[2P]` or `[4P]` tag for players with Midnight Season 1 tier pieces
- Automatic group/raid inspect outside of combat with 2-hour persistent cache
- After boss kill: all group members re-inspected (potential loot/iLvl gains)
- Cross-realm player support
- LFR/LFD instance group support
- Manual inspect protection — background queue pauses after player manually inspects someone
- `/dilvl` slash command for control and debug

### Technical
- Set bonus detection via `C_Item.GetItemInfo` setID whitelist (Midnight S1: 1978–1990)
- Player self-detection without inspect via `GetInventoryItemID("player", slot)`
- `PLAYER_EQUIPMENT_CHANGED` event updates own set bonus on gear swap
- UI-mod-agnostic manual inspect guard (`lastManualInspectTime` — works with ElvUI etc.)

---

## Pre-release History (internal, 2026-03-28 – 2026-03-30)

Development history before public release. Preserved for reference.

<details>
<summary>Show internal changelog (v1.1 – v1.8)</summary>

### [1.8] - 2026-03-30
- Fix: off-by-one in pcall return — was reading `expansionID` (=11) instead of `setID` (=1988) from `C_Item.GetItemInfo`
- Fix: player self set-bonus detection (`UpdatePlayerCache` + `PLAYER_EQUIPMENT_CHANGED`)
- Fix: re-queue players if `setBonusCache` missing even when iLvl cache is fresh (session-only cache)
- Fix: manual inspect guard rewritten to be UI-mod-agnostic (`lastManualInspectTime` replaces `InspectFrame:IsShown()`)
- Fix: replaced Details internal `item_level_pool` with public `Details.ilevel:GetIlvl()`

### [1.7] - 2026-03-29
- Feat: set bonus detection (2P/4P) via INSPECT_READY + tier slot scan
- Feat: `/dilvl setbonus` toggle
- Fix: manual inspect window no longer wiped by background queue

### [1.6] - 2026-03-29
- Feat: persistent iLvl cache via SavedVariables (2h TTL)
- Feat: ENCOUNTER_END re-inspect after boss kills
- Feat: MapID-based cache invalidation on zone change

### [1.5] - 2026-03-29
- Fix: inspect retry (up to 3x) for out-of-range players
- Fix: taint crash in RefreshAllBarTexts — cache Details! clean text, never call GetText()
- Fix: multiple ticker bug on rapid zone transitions

### [1.4] - 2026-03-29
- Fix: CanInspect(unit, false) — no error message spam
- Fix: ClearInspectPlayer() after INSPECT_READY
- Fix: inspect delay raised to 1.0s (server throttle)

### [1.3] - 2026-03-29
- Fix: RefreshAllBarTexts always runs on tick
- Fix: inspect range check deferred to inspect time
- Fix: mapDirty on PLAYER_REGEN_ENABLED

### [1.2] - 2026-03-28
- Perf: lazy map rebuild via mapDirty flag
- Perf: early Details instance loop exit

### [1.1] - 2026-03-28
- Fix: cross-realm iLvl display
- Fix: iLvl tags refresh after combat ends

</details>
