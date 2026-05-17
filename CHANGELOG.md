# Changelog

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

Older releases: see [HISTORY.md](HISTORY.md).
