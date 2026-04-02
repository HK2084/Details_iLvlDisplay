# Changelog

Versioning: `MAJOR.MINOR.PATCH`
- **PATCH** — bug fix, tier IDs update for new season
- **MINOR** — new user-facing feature
- **MAJOR** — core rewrite or new WoW expansion (API breaking)

---

## [1.1.0] - 2026-04-02

### Added

- **LibOpenRaid-1.0 integration**: iLvl data from players running Details! is now received instantly via addon-comm — no inspect needed. Own inspect queue remains as fallback for players without Details!
- **Secret value guard**: proactive `issecretvalue()` check (WoW 12.0+) before touching potentially tainted strings — catches secret values early, before the pcall safety net

### Changed

- `LibOpenRaid-1.0` added to TOC `OptionalDeps`
- `/dilvl debug` now shows LibOpenRaid status (`active` / `n/a`)

---

## [1.0.2.3] - 2026-04-02

### Fixed

- Own iLvl not updating in Details! bars when re-equipping gear — `UpdatePlayerCache` now calls `StoreNameIlvl` and sets `mapDirty = true` so bars refresh immediately on gear swap in both directions

---

## [1.0.2.2] - 2026-04-01

### Fixed

- **ElvUI-only mode**: addon now fully works without Details! loaded — inspect queue runs, `[dilvl]` tag populates correctly
- `GetText()` seed in `HookBarTextIfNeeded` wrapped in `pcall` — prevented crash when Details! Itemlevelfinder returns a secret string during initial bar hook
- `ENCOUNTER_END` no longer force-expires cache — uses soft-expire (60s before real TTL) so tags survive until fresh inspect data arrives after boss kill
- LFR late unit tokens: `QueueGroupInspect` retried at 15s and 30s after zone-in — ensures all 25 players get tagged even when unit tokens are not available immediately

---

## [1.0.2.1] - 2026-04-01

### Fixed
- Inspect queue could deadlock if `INSPECT_READY` never fired (server throttle, player out of range mid-inspect) — 15s safety timeout added
- `setBonusCache` is now persisted in SavedVariables; no longer re-inspects the entire group on every `/reload` just to rebuild set bonus data

---

## [1.0.2.0] - 2026-04-01

### Fixed
- All slash command toggles now apply immediately without waiting for the next ticker cycle:
  - `/dilvl on` refreshes bars and ElvUI frames instantly
  - `/dilvl off` strips injected tags from bars instantly
  - `/dilvl color` and `/dilvl setbonus` update all visible bars immediately
  - `/dilvl elvui on/off` triggers an immediate ElvUI frame refresh

---

## [1.0.1.9] - 2026-04-01

### Fixed
- Crash when Details! **Itemlevelfinder** is enabled — it passes secret string values to `SetText` which caused `attempt to index local 'text'` errors (×497). Hook body now wrapped in `pcall` to silently skip secret values

---

## [1.0.1.8] - 2026-04-01

### Added
- **Independent toggles**: Details! bars and ElvUI party frames can now be enabled/disabled separately
  - `/dilvl details` — toggle iLvl on Details! bars
  - `/dilvl elvui on/off` — already existed, now consistent
- Details! is now an **optional dependency** — addon loads and works without it (ElvUI-only mode)
- `/dilvl debug` now shows `Details-bars` and `ElvUI-tag` status explicitly

---

## [1.0.1.7] - 2026-04-01

### Fixed
- iLvl missing on **middle-ranked bars (rows 6–15)** in raids/LFR after combat — `barCleanText` was not updated during `InCombatLockdown`, leaving stale player names for bars whose ranks changed mid-fight
- `PLAYER_REGEN_ENABLED`: iLvl now injects within 0.5s of combat end instead of waiting up to 2s for the next ticker
- `FontString:ClearText` (new in WoW 12.0.1) now hooked to prevent stale player names from leaking into refreshed bars

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
