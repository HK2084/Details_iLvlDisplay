# Release History

Full changelog for all versions. Current release notes: [CHANGELOG.md](CHANGELOG.md)

---

## v1.5.6

### New

*   **Tier sets are colour-coded by season.** The current season's set bonus renders in green, an older season's in grey. While a player is switching over, both are shown side by side — two older pieces next to two current ones read as a grey `[2P]` followed by a green `[2P]` — so one look at the meter tells you who has already moved across and who is still on last season's set.

### Optimised

*   **Package reduced to runtime files only.** The download is roughly a third smaller: 144 KB.

### Fixed

*   **Rank prefixes are read from the client's own format string** instead of assuming a full stop. zhCN and zhTW use a different separator (`1、Name`), which previously broke both the name lookup and the rank display on those clients.

## v1.5.5

### New

*   **Season 2 tier sets are recognised from day one.** All thirteen new set bonuses are in, so 2P/4P appears as soon as people start wearing the new gear.

### Fixed

*   **Item level no longer disappears from Details! bars after a boss fight.** A single protected value written during combat could drop a player from the display for the rest of the session — a `/reload` was the only way back.
*   **Your own 2P/4P survives a loading screen.** Entering a raid or dungeon could wipe your set bonus, and only re-equipping a piece brought it back. Item data that has not finished loading is no longer mistaken for "wears no tier set".
*   **`/dilvl off` now really silences everything.** The ElvUI tag and the Grid2 text ignored the master switch and kept their numbers on screen.
*   **Item levels fill in far quicker in raids.** When another addon inspected someone, we mistook it for you opening the inspect window and paused for a minute — in a raid that kept repeating, leaving people untagged.
*   **Tags no longer blink out when someone joins or leaves the group.** Every roster change cleared all item levels until the next update; in a group that is still filling up, that was most of the time.
*   **ElvUI's `[dilvl:plain]` tag now refreshes** with the rest instead of waiting for a gear change — and if you never switched the ElvUI tag on, it costs you nothing at all now.
*   **Blizzard's damage meter keeps its item levels after a fight.** They used to disappear the moment a pull started and only came back if you switched the window mode by hand. Rows now stay tagged through a kill, a wipe and the walk to the next boss.
*   **The rank number stays in front of the name**, instead of Blizzard's `1.` `2.` `3.` numbering being pushed off the line.
*   **Nobody else's item level can land on your row, or yours on theirs.** A group member whose character name matched yours on another realm was shown with your gear.

### Under the hood

*   An error inside Details! can no longer take down the update loop or the login setup for the rest of the session, and a channel that switched itself off after repeated errors comes back with `/dilvl elvui on` or `/dilvl grid2 on`.

## v1.5.4

### Fixed

*   **Item level is back on Details! bars.** Patch 12.1 changed how the game shortens cross-realm names, so anyone from another realm lost their tag. Blizzard's own damage meter kept working, which is why this looked random rather than broken.
*   **Your own 2P/4P shows up right after logging in** instead of only after re-equipping something.
*   **Item level reappears instantly when you resize the Details! window** instead of a second or two later.
*   **Players stay tagged on Blizzard's damage meter.** Someone who failed to resolve once could stay untagged for the rest of the session.

### Under the hood

*   Hardened the remaining text measurements and the `/dilvl debug` and `/dilvl auras` output against the 12.1 secret-value changes, and added a build-time guard against the class of bug behind the v1.5.2 crash.

## v1.5.2

### Fixed

*   **Crash in the newest raids/instances (e.g. the Sporefall raid) while using Blizzard's built-in Damage Meter.** In the new restricted content, enemy units on Blizzard's meter made it throw a secret-value error through the addon — repeatedly, throughout each fight (the reporter saw it hundreds of times). Every call into Blizzard's meter is now secret-safe, so it can't crash there anymore. _(reported by Profion85 — thanks for the detailed logs!)_
*   **Item-level tags on Details! bars survive leaving a group.** Players who left now keep their cached name, so their tag reappears on its own within a couple of seconds instead of needing a `/reload`.

### Under the hood

*   Hardened every remaining call into Blizzard's Damage Meter and all bar-width measurements against the 12.0 secret-value system — including the `/dilvl debug` output — so nothing in restricted content can throw.

## v1.5.1

### Fixed

- **Crash in restricted instances — the new event dungeons such as the Slave Pens.** Blizzard's 12.0 "secret value" system now hands back a *secret* GUID for indirect unit tokens like `targettarget` inside these instances, and comparing it threw `attempt to compare a secret string value` on `UNIT_INVENTORY_CHANGED` — which could break the addon for the rest of the run. Every unit-GUID lookup now goes through a secret-safe wrapper that skips a secret value instead of touching it. *(Reported by Profion85 — thank you for the detailed log, it made this a quick fix.)*
- **Settings UI version-history label no longer bleeds onto the other tabs** (a v1.5.0 display glitch).

### Reliability

- **Routed every remaining unit-GUID, unit-name and combat-state read through the same secret-safe wrappers** — the inspect queue, group sweep, `INSPECT_READY`, the after-boss re-inspect, the Blizzard DM name resolver, Danders Frames, and the Settings UI. None of these reproduced the crash on their own (they only ever see your own party/raid, whose data isn't secret), but they shared the pattern, so they're now hardened against any current or future restricted content.
- **The Settings UI opens correctly inside instances again** — the combat check no longer mistakes a secret "not in combat" value for "in combat" and wrongly defers the window.

### Under the hood

- Added a build-time lint rule that fails CI if a raw `UnitGUID` / `UnitName` / `UnitIsUnit` / `InCombatLockdown` call is ever introduced outside the addon's secret-handling layer — so this whole class of crash can't quietly come back.
- **Listed for the upcoming 12.1.0 patch** (Interface `120100`) — checked against the 12.1.0 PTR API and found no breaking changes for this addon, so it loads cleanly on the PTR.

## v1.5.0

### New

- **Settings UI** — opens via `/dilvl ui` or via Esc → Options → AddOns → Details! iLvl Display. Three tabs (General / Output Channels / Diagnostics) plus a persistent live-preview pane below the tabs that updates as you change settings. Resizable window (grip in bottom-right corner). Position and size persisted per character
- **Full configuration from the UI** — Master Toggles (Enable / Color / Set bonus), Layout (inline/columns), Position (left/right of name) on the General tab. Per-channel toggles, Danders anchor position dropdown with all 13 positions, Danders font-size slider (6–30 live), Blizzard DM tristate (Auto / Forced On / Forced Off) on the Output Channels tab
- **Live preview** — mock Details!-bars and a representative mock unit-frame react in real time to every setting change, so users see exactly how their changes look before committing
- **Diagnostics tab** — scrollable, selectable debug dump (one-click select-all-and-copy for bug reports), UI error counters, Reset UI Error Counters and Reset to Defaults buttons
- **German translation** — full deDE locale for every UI string with real Umlauts. Community translations can be added as additional `locales/` files without touching the core

### Defense

- **UI-layer fault isolation** — every widget callback is pcall-wrapped, every page init is pcall-wrapped, and a per-page error counter (cap 5) swaps a broken page to an inline error placeholder while the rest of the UI keeps working
- **Read-time validators on SavedVariables** — out-of-range slider values, invalid enum strings, wrong types are clamped or reset to defaults on every login. A manually-edited SavedVariables file with garbage values can't crash the addon
- **Recursive defaults merge + schema-version migration scaffold** — future setting additions and renames apply cleanly to existing installs without losing user data
- **Single-source refresh router** — both the slash handler and the Settings UI go through one apply function per setting so flipping Layout or any other option always triggers the same Clear/Re-render sequence (no more double-rendered tags)
- **Reset to Defaults** — confirmation popup before wiping; soft-wipe preserves the iLvl cache, set-bonus cache, and window position so users don't lose minutes of inspection work after a setting mistake

---

## v1.4.4

### New

- **Adjustable text size on Danders Frames** — new slash `/dilvl danders size <n>`, range 6-30. Live update without `/reload`. Default 10, persists per character. Existing users see a one-shot login hint when Danders Frames is installed. Thanks to harrissx for the request
- **Off-frame anchor positions on Danders Frames** — six new positions for `/dilvl danders pos`: `above`, `aboveleft`, `aboveright`, `below`, `belowleft`, `belowright`. The iLvl text now floats *outside* the frame bounding box so it doesn't overlap the unit's name or HP at larger font sizes. Inside positions (top/topright/...) remain available — pick whichever fits your raid layout. Note: in dense raid stacks (25er with no gap between frames), above/below will overlap the neighbouring frame, so prefer inside positions in that case

### Defense

- **SafeUnitName: pcall-protected** — `UnitName()` is now wrapped against tainted-execution rejection so a hard-error from Blizzard's secret-arguments layer can't take the addon down. Three direct call sites in the Blizzard Damage Meter integration migrated to the shared wrapper. New `UnitNameRejected` counter in `/dilvl debug` makes regressions visible
- **12.0.7 compatibility** — TOC declares `120007` alongside `120001` and `120005`. Audited against PTR build 67227: no breaking changes for our APIs. Four preconditions (`RequiresDeclassifiedUnitIdentity`, `RequiresScriptObjectAlphaAccess`, `RequiresScriptObjectDesaturationAccess`, `RequiresStatusBarDesaturationAccess`) flip their failure mode from `ReturnNothing` to `ReturnWithError`; our `pcall` defense layer covers both paths

### Refactor

- **Foundation modular-base** — addon namespace bootstrap split into `init.lua` (defaults, position keys, login-hint registry), `secrets.lua` (12.0+ secret-value defense layer), `util.lua` (tier-set whitelist, color, name extraction). `core.lua` reduced from 2264 → ~2100 lines. Zero behavior change for existing users
- **Per-feature kill-switch isolation** — the previously-named `hookErrors` counter was Details!-bars-scoped already, now renamed `detailsBarErrors` to make that explicit. BlizzDM, Danders, ElvUI, and Grid2 have always carried their own independent counters — a bug in one feature can never auto-disable another
- **CanCompareUnitTokens probe fixed in /dilvl debug** — the foundation refactor accidentally dropped the local probe in `core.lua`, making the report always read `no`. Now reads `C_Secrets.CanCompareUnitTokens` directly

---

## v1.4.3

### New

- **`[dilvl:plain]` ElvUI tag** — renders the item level as a bare number without surrounding brackets, e.g. `Raza 284` instead of `Raza [284]`. Both `[dilvl]` and `[dilvl:plain]` coexist and share the same `/dilvl elvui on/off` toggle, color, and set-bonus settings. Listed in ElvUI's tag browser under "Details! iLvl Display" with descriptions. Thanks to NiGhTwAlKeR559 for the request
- **First-time login hints for new features** — ElvUI users now receive a single one-shot chat message at login pointing to the new `[dilvl:plain]` tag. Hints are dependency-gated and only fire on the first login per character

### Fixed

- **Cross-realm tags lost after group disband** — iLvl tags for some cross-realm players disappeared from Blizzard's Damage Meter once the group ended. Tags are now retained correctly

---

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

- **Addon broken inside instances** — combat state could get stuck "in combat" in WoW 12.0+ dungeons/raids when the combat *event args* (`PLAYER_IN_COMBAT_CHANGED`) arrived as secret values, blocking inspects, bar refreshes, and roster updates. Fixed by cross-checking `InCombatLockdown()` + `IsEncounterInProgress()` (both plain booleans) as the non-secret source of truth
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
