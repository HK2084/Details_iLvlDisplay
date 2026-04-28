# Changelog

## v1.4.3

### New

- **`[dilvl:plain]` ElvUI tag** — second tag variant that renders the iLvl as a bare number without surrounding brackets (e.g. `284` instead of `[284]`). Use it in any ElvUI Custom Text or Name Format slot — both `[dilvl]` (bracketed) and `[dilvl:plain]` (plain) coexist and respond to the same `/dilvl elvui on/off` master toggle, color setting, and set-bonus setting. Tier-set badge (e.g. `[4P]`) keeps its own brackets in both variants. Both tags are registered in ElvUI's tag browser under category "Details! iLvl Display" with descriptions, so users can discover them without docs. Requested by CurseForge user NiGhTwAlKeR559 (issue #23).
- **First-time login hint for new features** — ElvUI users see a single one-shot chat message about the new `[dilvl:plain]` tag at next login (8s after entering world, then dismissed forever per character). The previously-inlined `/dilvl position` hint from v1.3.5 has been moved into the same registry, so future feature releases can announce themselves without users needing to read changelogs. Hints are gated by dependency (the ElvUI hint stays silent if ElvUI is not loaded) and stagger 4s apart on fresh installs to avoid scroll spam.

### Fixed

- **Blizzard DM: false GAVE-UP for cross-realm players in historical (post-disband) frames** — the iLvl cache stored player names asymmetrically depending on which path wrote the entry: Inspect API and LibOpenRaid stored the full `Name-Realm` form, while the Details! actor-scan fallback often stored the bare `Name` only (Details! `actor.displayName` / `actor.nome` arrives without realm suffix for many cross-realm players). After group disband, BlizzDM frames carry the full `Name-Realm` `sourceName`. The reverse-lookup in `ResolveGUIDByName` did a strict-equality match after `Ambiguate("none")` normalisation, which could not bridge that asymmetry — the player was stuck at `3/3 GAVE-UP` permanently for the rest of the session, even though their iLvl was sitting in the cache the whole time. **In live raid/dungeon gameplay the bug was invisible** because the addon resolved through the live group roster instead of the reverse-lookup; it only surfaced when looking at historical BlizzDM data after the group had disbanded. Fixed via three-layer defence: (1) new `ResolveFullNameByGuid` helper resolves a GUID to its current `Name-Realm` form via roster lookup; (2) the `[DETAILS]`-source cache write path now enriches `cached.name` with the full form when the player is in the current roster; (3) `ResolveGUIDByName` now adds a `nameOnly` match as a last-resort fallback so legacy bare-named cache entries from prior sessions also resolve correctly. The fuzzy nameOnly match can collide on same-name-different-realm players in extreme edge cases — that tradeoff is intentional for historical view (better a slightly-wrong tag than no tag for a frame no longer in the live group).

## v1.4.2

### Fixed

- **Blizzard DM: permanent GAVE-UP-lock for some players** — once a player accumulated 3 consecutive resolve fails (e.g. transient secret-locks during combat trash, frame stack churn, brief out-of-range gaps), `nameResolveFails[name]` blocked their re-tagging for the rest of the session, even after fresh inspect data arrived. Symptoms: `/dilvl debug` showed players `cache:yes  tag:no [CLEAN]  fails:3/3 GAVE-UP` post-combat with valid iLvl in the cache. Only `/reload` recovered. Reproducible via LFR / 25-Mann content where 5-7+ players regularly stayed permanently untagged.

### New (smart-reset infrastructure)

- **Per-player cache-write reset** — `NotifyElvUI()` now optionally carries the player name; the BlizzDM callback clears that player's `nameResolveFails` entry before re-rendering, so fresh inspect / LibOpenRaid GearUpdate / self-update data immediately re-arms the 3-retry budget. Cross-realm Ambiguate forms cleared in lockstep
- **PLAYER_REGEN_ENABLED wipe** — combat is a state-change event; per-player fails accumulated under combat secret-locks are invalidated wholesale at combat end. The 3-retry defense still applies to genuine post-combat resolve failures
- **GROUP_ROSTER_UPDATE leave-purge** — players who leave the group get their counter cleared on next roster update so a re-join starts with a fresh budget
- **`/dilvl debug` diagnostics** — BlizzDM section now shows `resets: N   lastReset: <trigger>` (e.g. `cache:Zoltara-Azshara`, `REGEN_ENABLED (7)`, `roster-leave (2)`, `session-switch (5)`). Visible only when at least one reset has fired since `/reload`

### Preserved (no behavior change)

- `MAX_RESOLVE_FAILS = 3` defensive cap unchanged — counters reset only on real trigger events, not on every refresh tick
- Existing `wipe(nameResolveFails)` on session switch (Heal→DPS, Aktuell→Gesamt) is preserved and now also bumps the diagnostic counter
- All other integrations (Details!-bars, ElvUI tag, Grid2 status, Danders FontString) ignore the new `NotifyElvUI(name)` argument — Lua silently drops unused params

---

## v1.4.1

### New

- **Grid2 raid frame integration** — `dilvl` status registers in Grid2's status system. Add it to any text indicator (corner-text, side-text, ...) via Grid2 GUI. Color, set bonus, and toggle inherit from existing settings. Toggle: `/dilvl grid2 on`
- **Danders Frames integration** — addon-owned FontString attached per Danders Frame, anchored to `frame.contentOverlay` (the host's dedicated non-interactive overlay layer, stable across resizes and stacking direction). Default position `topright`; live-switchable to top / topleft / bottom / bottomright / bottomleft / center via `/dilvl danders pos <opt>`. Toggle: `/dilvl danders on`
- **`/dilvl debug` rewrite** — clearer per-feature counters: Details!-HookErrors, Callback errors (per-callback, with auto-unregister threshold), Danders + BlizzDM auto-disable state with last error message, position + frame-render diagnostics

### Improved (defensive hardening — fault isolation across all features)

- **Details!-bar hook errors no longer take down other integrations** — previously, 5+ Details! `SetText` hook errors flipped `db.enabled = false` (master switch), silently disabling BlizzDM overlays + halting ElvUI/Grid2/Danders refresh callbacks. Now: only `db.showInDetails = false` is set; other integrations keep working. Recovery: `/dilvl details` toggle resets the counter
- **Per-callback error isolation** — each integration's update callback (ElvUI, Grid2, Danders, BlizzDM) has its own consecutive-error counter. First error per callback fires `geterrorhandler()` (BugSack catches it); after 5 consecutive errors the faulty callback is auto-unregistered. Other callbacks keep firing
- **BlizzDM local kill-switch** — `RefreshAllFrames` iteration is wrapped per call site. After 5 errors `db.blizzDM` is auto-disabled (NOT `db.enabled` — master switch stays user-owned), with a one-shot BugSack notification including recovery hint (`/dilvl blizzdm` to re-enable). Counter resets on `/reload`. Tristate (auto / manual-on / manual-off) is preserved across auto-disable + recovery
- **Danders auto-disable** — same pattern: 5 errors in any host-API call (`DandersFrames_IsReady`, `IterateFrames`, `OnFramesSorted` callback, FontString creation) auto-disables only the Danders integration, others unaffected. Recovery: `/dilvl danders on`

---

## v1.4.0

### Improved

- **Blizz DM: event-table dispatch** — replaced 120-line if/elseif event chain with O(1) table-driven dispatcher. `RegisterHandler(event, fn)` self-registers event + handler in one call. Shared functions for combat-start (`OnCombatStart`) and zone transitions (`OnTransition`). All handler logic preserved, no behavioral changes (#16)

---

## v1.3.6

### Fixed

- **Blizz DM: left-position frames missing data** — when iLvl position was set to "left", 1-2 frames per window could permanently show no iLvl/tier data. Root cause: `StripTagFromText` only matched leading spaces before tags, but left-position places the space *after* the tag. Name parsing broke → GUID resolve failed → frame gave up
- **Blizz DM: per-frame give-up too aggressive** — resolve fail counter was tracked per frame, not per player. The same player on Window 1 could give up while Window 3 resolved fine. Now tracked per `sourceName` so all frames for a player share one counter
- **Blizz DM: GUID lost on segment switch** — toggling A→G→A cleared `_dilvlGUID` on all frames, but if `sourceName` was still secret (Blizzard keeps it locked after boss fights), the GUID couldn't be re-resolved. Now preserves GUID when sourceName is secret
- **Blizz DM: PropagateGUID crash** — comparing `f.sourceName` threw a Lua error when the field was a secret value. Added `isSecret()` guard before equality check

### New

- **Cross-frame GUID propagation** — when a GUID resolves on any frame, it's automatically shared with all other visible frames for the same player. Fixes left-position data gaps across multiple Blizz DM windows
- **Debug: per-player resolve fails** — `/dilvl debug` now shows `fails:N/3` per frame entry and a "Resolve Fails (per player)" summary section with GAVE-UP status

---

## v1.3.5

### New

- **iLvl position toggle** — `/dilvl position left` places the iLvl tag between rank and name ("1. [272] Playername"), `/dilvl position right` appends after name (default). `/dilvl position` toggles between both
- **One-time feature hint** — first-time notification about the new position command (saved in `seenHint_position`)

### Fixed

- **Blizz DM: color override on clean path** — native FontString color was being overwritten even when SetText succeeded. Now only restores cached color after ClearSecretText (clear path)
- **Retry limit** — 3 consecutive resolve failures per frame, then give up. Reset on session switch
- **ScheduleRefresh nil guard** — forward-reference bug where ScheduleRefresh was called before definition
- **Session cleanup** — all `_dilvl*` frame properties including TextColor, ColorSetByAddon, ResolveFails, NameFS are now properly cleaned on session switch

---

## v1.3.4

### Fixed

- **StartPostCombatRefresh nil crash** — forward-reference bug: the safety reset in OnUpdate called `StartPostCombatRefresh()` before its `local function` definition. Added forward declarations so Lua resolves the function correctly (reported by aisenfaire)

---

## v1.3.3

### Fixed

- **Delve crash: ENCOUNTER_END secret value** — the `success` parameter in Delves is lazy-tainted and bypasses the standard secret check. Comparing it crashed the addon. Added individual secret guards on all event parameters (reported by NiGhTwAlKeR559)
- **UnitIsUnit secret value bug** — gear change detection incorrectly skipped all units when UnitIsUnit returned a secret value. Replaced with reliable GUID comparison
- **Blizzard DM combat state stuck** — in Delves and M+, combat state could get permanently stuck after secret event args. Added safety reset that cross-checks InCombatLockdown + IsEncounterInProgress
- **IsEncounterInProgress secret guard** — encounter check could return a secret value (always truthy), blocking all tag injection indefinitely

### Improved

- **12.0.5 preparation** — all UnitName() calls now go through a secret-safe wrapper, ready for upcoming `AllowedWhenUntainted` restriction. UnitIsUnit wrapper uses the new `CanCompareUnitTokens` API
- **Debug output** — `/dilvl debug` now shows Secret API status and block counters. `/dilvl blizztrace` logs name resolution paths and GUID failure reasons

---

## v1.3.2

### Fixed

- **Cache key mismatch after group disband** — `Ambiguate("short")` → `"none"` everywhere (core.lua + blizzdm.lua). Cross-realm players now retain iLvl tags after leaving a group (#21)
- **Blizz DM: post-combat deferred retry** — when frames are still secret after combat ends (~0.5s Blizzard unlock delay), the addon now sets a one-shot flag and retries on the next `UpdateName` hook. Event-driven, no timer (#19)
- **Blizz DM: truncated realm name resolution** — FontString text can truncate long realm names (e.g. "Гордун" instead of "Гордунни"). New name-only fallback strips the realm and matches by character name alone
- **Secret value guard** — added `hasanysecretvalues()` batch guard on event args (`INSPECT_READY`, `ENCOUNTER_END`, `GET_ITEM_INFO_RECEIVED`, `UNIT_INVENTORY_CHANGED`, `PLAYER_IN_COMBAT_CHANGED`). Defense-in-depth against Blizzard's expanding Secret Value system (#15)
- **Error routing** — `SafeCall` kill-switch now uses `geterrorhandler()` instead of `print()`. Errors route through WoW's error handler → BugSack picks them up automatically (#13)

### Improved

- **Debug output** — `/dilvl debug` now shows `HookErrors: 0/5` (SafeCall status) and `deferRetry=no/PENDING` (post-combat retry state)
- **CurseForge FAQ** — added combat iLvl limitation explanation to CurseForge description

---

## v1.3.1

### Fixed

- **Blizz DM post-combat refresh** — replaced `C_Timer.After` with dirty-flag OnUpdate frame. After combat ends, the addon keeps checking for newly-readable frames and tags them automatically. Goes idle when done — zero CPU cost (#12, #17, #18)
- **Cross-realm name resolution** — switched `Ambiguate` from `"short"` to `"none"` (BigWigs pattern). Always strips realm suffix, fixing NO-GUID for non-connected cross-realm players like Náirah-Nazjatar (#14)
- **Endless refresh loop** — OnUpdate now tracks progress and stops when no new frames are tagged. Previously looped indefinitely when nameText was readable but GUID couldn't be resolved
- **Refresh throttle** — post-combat catch-up limited to every 0.5s instead of every frame (60fps → 2 checks/sec)

---

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

- After combat ends, DPS/Overall & Heal/Overall windows may need a quick window toggle (A→G→A) to show all tags. See #12
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
