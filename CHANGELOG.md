# Changelog

## v1.5.5

### New

*   **Season 2 tier sets are recognised from day one.** All thirteen new set bonuses are in, so 2P/4P appears as soon as people start wearing the new gear.

### Fixed

*   **Item levels fill in far quicker in raids.** When another addon inspected someone, we mistook it for you opening the inspect window and paused for a minute — in a raid that kept repeating, leaving people untagged.
*   **Tags no longer blink out when someone joins or leaves the group.** Every roster change cleared all item levels until the next update; in a group that is still filling up, that was most of the time.
*   **ElvUI's `[dilvl:plain]` tag now refreshes** with the rest instead of waiting for a gear change — and if you never switched the ElvUI tag on, it costs you nothing at all now.

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

- **Settings UI** — type `/dilvl` to open it (or Esc → Options → AddOns → Details! iLvl Display). Four tabs — What's New / General / Output Channels / Diagnostics — plus a persistent live-preview pane below the tabs that updates as you change settings. Resizable window (grip in the bottom-right corner); position and size are persisted per character.
- **What's New tab** — a curated list of recent features so you never miss what the addon can now do. The window opens to it once after each update, then remembers your last tab. (Bug fixes stay out of it — those live in the linked version history.)
- **Details! text size** — set a fixed iLvl text size on Details! bars (Columns layout) with the slider or `/dilvl details size <n>` (`0` = match Details' own font). *(CurseForge request from 404Missingno.)*
- **Per-window display** — show iLvl on only one Details! window instead of all of them, with the dropdown or `/dilvl details window <all|1-10>`. *(CurseForge request from 404Missingno.)*
- **Full configuration from the UI** — Master Toggles (Enable / Color / Set bonus), Layout (inline/columns) and Position (left/right of name) on the General tab; per-channel toggles, the Details! window picker + text-size slider, the Danders anchor position (all 13) + font-size slider, and the Blizzard DM tristate (Auto / Forced On / Forced Off) on the Output Channels tab.
- **Live preview** — mock Details! bars and a representative mock unit-frame react in real time to every setting change, so you see exactly how it looks before committing.
- **Diagnostics tab** — scrollable, selectable debug dump (one-click select-all-and-copy for bug reports), UI error counters, and Reset UI Error Counters / Reset to Defaults buttons.
- **German translation** — full deDE locale for every UI string with real Umlauts. Community translations can be added as additional `locales/` files without touching the core.

### Fixes & reliability

- **LibOpenRaid gear data is used again for group members** — the instant addon-comm gear path had been silently inert (it matched a name against a unit token), so the addon always fell back to inspecting. Group item level now populates faster with less inspect traffic.
- **Blizzard DM no longer briefly shows the wrong player's iLvl** after switching meter views while names were still secret-locked.
- **Grid2 and ElvUI tags are secret-value safe inside instances** — reading a unit GUID could throw in a tainted tag callback; now guarded.
- **Channels no longer falsely auto-disable** over a long session — the per-channel error counters reset on success, so only a genuinely broken integration trips the kill-switch.
- **12.0.x hardening** — migrated off the deprecated `IsEncounterInProgress` global, removed the only per-refresh memory allocation on the Details! hot path, and tightened several inspect-queue and font-cache edge cases.

### Defense

- **UI-layer fault isolation** — every widget callback is pcall-wrapped, every page init is pcall-wrapped, and a per-page error counter (cap 5) swaps a broken page to an inline error placeholder while the rest of the UI keeps working.
- **Read-time validators on SavedVariables** — out-of-range slider values, invalid enum strings, and wrong types are clamped or reset to defaults on every login, so a hand-edited SavedVariables file can't crash the addon.
- **Recursive defaults merge + schema-version migration scaffold** — future setting additions and renames apply cleanly to existing installs without losing user data.
- **Single-source refresh router** — both the slash handler and the Settings UI go through one apply function per setting, so flipping Layout or any other option always triggers the same Clear/Re-render sequence.
- **Reset to Defaults** — confirmation popup before wiping; the soft-wipe preserves the iLvl cache, set-bonus cache, and window position.

---

Older releases: see [HISTORY.md](HISTORY.md).
