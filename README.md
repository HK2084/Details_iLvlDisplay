# Details! Item Level Display

Shows **item level** and **tier set bonus** on **Details!**, **ElvUI**, **Grid2**, **Danders Frames**, and **Blizzard's built-in Damage Meter** (12.0+). Auto-detects what's installed, each surface independently toggleable.

---

## Features

- Item level displayed next to each player name: `Quinroth [254]`
- **In-game Settings UI** (new in v1.5) — three tabs with persistent live preview, resizable window, full English + German. Open with `/dilvl ui` or via Esc → Options → AddOns
- **Five output channels**, all independently toggleable:
  - **Details! Damage Meter** — inline or column layout
  - **Blizzard's built-in Damage Meter** (12.0+) — fallback when Details! isn't installed
  - **ElvUI** — `[dilvl]` (with brackets) and `[dilvl:plain]` (bare) tags for any Custom Text
  - **Grid2** — `dilvl` status for any text indicator
  - **DandersFrames** — overlay FontString with 13 anchor positions and live font-size slider
- **Auto-detection** — the addon detects what you have installed and only enables what makes sense by default
- **Two layout modes** (Details! only): `inline` (appended to name) or `columns` (separate right-aligned columns)
- **Column mode works during combat** — uses addon-created overlays, no taint
- Color-coded by gear tier (see table below)
- **2P / 4P tier set bonus** detection for Midnight Season 1 tier pieces
- **Instant iLvl via LibOpenRaid** — if group members run Details!, their iLvl arrives via addon-comm with no inspect delay
- Automatic background inspection of group and raid members outside of combat (fallback for players without Details!)
- 2-hour persistent cache — survives `/reload`, loads instantly on re-login
- Automatic re-inspection after boss kills (catches loot upgrades)
- Your own iLvl and set bonus update instantly on gear swap — no inspect needed
- Cross-realm, LFR and LFD support (up to 40 players)
- Manual inspect protection — background queue pauses when you inspect someone
- **Per-feature fault isolation** — a bug in one channel can't take down the others (each has its own auto-disable + recovery)
- **Read-time validators** on SavedVariables — out-of-range or corrupted values are clamped or reset on every login, so a hand-edited config file can never crash the addon

---

## Preview

**Inline mode** (default):

```text
1. Quinroth [252] [2P]     298K
2. Tankplayer [265] [4P]   210K
3. Healsalot [248]          95K
```

**Column mode** (`/dilvl layout columns`):

```text
1. Quinroth          4P  252     2.3M    298K
2. Tankplayer        4P  265     1.8M    210K
3. Healsalot             248     950K     95K
```

Column mode shows iLvl and tier set during combat. Columns auto-hide on narrow windows. When bars swap positions, columns briefly disappear and reappear with the correct player's data.

### iLvl Colors

| Color | Range |
| --- | --- |
| Orange | BiS / top tier |
| Purple | High end |
| Blue | Mid |
| Green | Low |
| Grey | Base |

---

## Supported Output Channels

| Channel | Default | Toggle | Notes |
| --- | --- | --- | --- |
| **Details! Damage Meter** | ON when Details! is installed | `/dilvl details` | Full inline + column support, position toggle |
| **Blizzard Damage Meter** (12.0+) | AUTO — ON when Details! is not installed | `/dilvl blizzdm` | Inline + position toggle; experimental in instanced content |
| **ElvUI** | OFF (opt-in), requires [ElvUI](https://tukui.org/elvui) | `/dilvl elvui on` | `[dilvl]` and `[dilvl:plain]` tags for Custom Text |
| **Grid2** | OFF (opt-in), requires [Grid2](https://www.curseforge.com/wow/addons/grid2) | `/dilvl grid2 on` | Custom `dilvl` status, place in any text indicator via Grid2 GUI |
| **DandersFrames** | OFF (opt-in), requires [DandersFrames](https://www.curseforge.com/wow/addons/dandersframes) | `/dilvl danders on` | Overlay FontString, 13 anchor positions, live font-size slider |

**Smart auto-detection:** the addon detects what you have installed and only enables what makes sense by default. The Settings UI (Allgemein tab) shows ✓ / ✗ per surface in real time.

**No dependencies required.** Install the addon, and it works with whatever you have.

---

## Settings UI

Open with `/dilvl ui` (or via Esc → Options → AddOns → Details! iLvl Display).

- **Allgemein / General** — master switch, color-by-tier, set-bonus toggle, layout (inline/columns), position (left/right of name), auto-detected channels with ✓ / ✗ status
- **Ausgabe-Kanäle / Output Channels** — five channel panels with toggles plus per-channel sub-settings (ElvUI tag hint, Grid2 hint, Danders anchor dropdown with all 13 positions, Danders font-size slider 6-30 live, Blizzard DM tristate Auto/Forced On/Forced Off)
- **Diagnose / Diagnostics** — scrollable, selectable debug dump for bug reports, UI-layer error counters, Reset UI Error Counters and Reset to Defaults buttons

**Persistent live-preview pane** below the tabs — mock Details!-bars and a representative unit-frame react in real time as you change settings, so you see exactly how your changes will look.

**Resizable window** via the grip in the bottom-right corner. Position and size persisted per character.

**German translation** included. Community translations welcome — add a file to `locales/` and submit a PR.

---

## How it works

The addon has two data sources:

1. **LibOpenRaid** (instant) — when group members also run Details!, their iLvl is broadcast via addon-comm. No inspect delay.
2. **Inspect API** (fallback) — for players without Details!, the addon inspects them outside of combat.

iLvl data is cached for 2 hours per player.

**Expected behavior — not bugs:**

- **First pull:** iLvl may not show for all players yet. Inspection runs after you join the group and takes a few seconds per player.
- **In combat (all meters):** during combat, the addon does **nothing** — no tags, no writes, no UI changes. This is intentional. Blizzard locks player data with Secret Values during combat, and writing to bars while they're being repositioned causes display glitches. Tags are stripped cleanly at combat start and re-applied when combat ends.
- **In combat (Details! column mode):** iLvl and tier columns stay visible throughout combat. When DPS rankings change and bars swap positions, columns may briefly disappear and reappear — this is normal and ensures every bar always shows the correct player's data.
- **Blizzard DM after combat:** DPS/Overall & Heal/Overall windows may need a quick window toggle (close/open or switch between A/G) to refresh. This is because Blizzard unlocks player data at different times for different windows.
- **Blizzard DM after `/reload` during combat:** do **not** `/reload` while in combat. Blizzard recreates all frames during `/reload`, and in combat all player data is locked — this permanently corrupts the frame data until the next session switch or window toggle. `/reload` between pulls is fine.
- **After the first fight:** everyone should be fully tagged.
- **After a boss kill:** the whole group gets re-inspected automatically.
- **On `/reload` (out of combat):** cached data is restored instantly. Only new or uncached players get re-inspected.

**Tier set bonus `[2P]` / `[4P]`:**

- Only Midnight Season 1 tier pieces are detected (raid and M+ drops)
- Crafted gear, previous expansion tier, and PvP gear are not counted
- Your own set bonus appears immediately — other players appear after their inspect completes

---

## Slash Commands

| Command | What it does |
| --- | --- |
| `/dilvl` | Show all commands |
| `/dilvl ui` | Open the in-game Settings UI (v1.5) |
| `/dilvl on` / `off` | Enable / disable the addon (master switch) |
| `/dilvl details` | Toggle iLvl display on Details! bars |
| `/dilvl blizzdm` | Toggle iLvl display on Blizzard Damage Meter |
| `/dilvl elvui on` / `off` | Toggle ElvUI `[dilvl]` / `[dilvl:plain]` tags |
| `/dilvl grid2 on` / `off` | Toggle Grid2 `dilvl` status |
| `/dilvl danders on` / `off` | Toggle Danders Frames overlay |
| `/dilvl danders pos <opt>` | Danders anchor position. Inside: `top`, `topright`, `topleft`, `bottom`, `bottomright`, `bottomleft`, `center`. Off-frame: `above`, `aboveleft`, `aboveright`, `below`, `belowleft`, `belowright` |
| `/dilvl danders size <n>` | Danders text size (6-30, live, no `/reload`) |
| `/dilvl layout` | Toggle between `inline` and `columns` mode (Details! only) |
| `/dilvl layout inline` | Switch to inline mode (appended to name) |
| `/dilvl layout columns` | Switch to column mode (separate columns, works in combat) |
| `/dilvl position` | Toggle iLvl left / right of player name |
| `/dilvl color` | Toggle color-coded iLvl display |
| `/dilvl setbonus` | Toggle 2P/4P tier set bonus display |
| `/dilvl inspect` | Manually trigger a full group re-inspect |
| `/dilvl debug` | Full status report — paste this when reporting a bug |
| `/dilvl cache` | Show all cached iLvl entries with age |
| `/dilvl map` | Show current name → iLvl map |
| `/dilvl tier` | Scan your own tier slots and set IDs |
| `/dilvl auras` | List your current buffs with spell IDs |

---

## ElvUI Integration (Optional)

If you use ElvUI, you can display iLvl directly on party/raid frames:

1. Run `/dilvl elvui on` to enable the tags
2. In ElvUI → Unit Frames → Party (or Raid/Player) → Name text, add `[dilvl]` (brackets) or `[dilvl:plain]` (bare)
3. Example name text:
   - `[name] [dilvl]` → renders `Quinroth [263]`
   - `[name] [dilvl:plain]` → renders `Quinroth 263`

Both tags coexist and share the same color, set-bonus, and toggle settings. Pick whichever fits your unit-frame layout.

The tags update instantly when inspect data arrives, on gear swaps, or when the group changes — no polling timer. Zero performance cost during idle time.

**No ElvUI installed? This does nothing — no errors, no performance cost.**

---

## Troubleshooting

**"iLvl is missing for some players"**
→ They were likely out of range when the inspect ran. Wait until after the first pull, or run `/dilvl inspect` to trigger a manual re-inspect.

**"Set bonus not showing"**
→ Only Midnight Season 1 tier pieces are supported. Crafted, PvP, and previous-expansion gear are not counted.

**"iLvl disappeared after resizing the Details! window"**
→ Fixed in v1.0.1. Tags re-appear automatically within 0.3s after you stop resizing.

**"Nothing is showing at all"**
→ Run `/dilvl debug` and check that `Addon` is `ON` and at least one output is enabled (`Details-bars`, `BlizzDM`, or `ElvUI-tag`). Then `/dilvl inspect`.

**"iLvl shows on Details! but not on Blizzard DM" (or vice versa)**
→ Both are independent toggles. Run `/dilvl blizzdm` or `/dilvl details` to toggle each one.

**"Blizzard DM shows names but no iLvl tags"**
→ Switch the window (A→G→A or close/reopen). This triggers Blizzard to refresh the frames so our addon can read player data. See [#12](https://github.com/HK2084/Details_iLvlDisplay/issues/12) for details.

**"Blizzard DM tags disappeared after `/reload` in a fight"**
→ Don't `/reload` during combat. Wait until the fight ends, then `/reload` if needed.

**Reporting a bug:** run `/dilvl debug` and include the full output in your report. You can also [open an issue on GitHub](https://github.com/HK2084/Details_iLvlDisplay/issues).

---

## Links

- [CurseForge](https://www.curseforge.com/wow/addons/details-item-level-plugin) — download & install
- [GitHub Issues](https://github.com/HK2084/Details_iLvlDisplay/issues) — bug reports & feature requests

---

## License

Custom — free to download and use, private modifications allowed,
redistribution of modified copies is not. See [LICENSE](LICENSE).
