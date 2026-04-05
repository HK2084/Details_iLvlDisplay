# Details! Item Level Display

Shows **item level** and **tier set bonus** next to player names on your damage meter — works with **Details!**, **Blizzard's built-in Damage Meter** (12.0+), and **ElvUI** party frames.

No configuration needed. The addon **auto-detects** which meters you use and activates accordingly.

---

## Features

- Item level displayed next to each player name: `Quinroth [254]`
- **Auto-detection**: works on Details!, Blizzard Damage Meter, or both at the same time
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
- **Independent toggles** — enable Details! bars, Blizzard DM, and/or ElvUI frames separately
- Optional **ElvUI integration**: adds a `[dilvl]` tag for party/raid unit frames

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

## Supported Meters

| Meter | Default | Toggle |
| --- | --- | --- |
| **Details! Damage Meter** | ON when Details! is installed (primary) | `/dilvl details` |
| **Blizzard Damage Meter** (12.0+) | AUTO — ON when Details! is **not** installed, OFF otherwise | `/dilvl blizzdm` |
| **ElvUI party frames** | OFF (opt-in), requires [ElvUI](https://tukui.org/elvui) | `/dilvl elvui on` |

**Smart auto-detection:** The addon is primarily a Details! plugin. If Details! is installed, iLvl shows on Details! bars and the Blizzard Damage Meter is left untouched. If you don't have Details!, the addon automatically falls back to Blizzard's built-in meter. You can always force both on with `/dilvl blizzdm`.

**No dependencies required.** Install the addon, and it works with whatever you have.

---

## How it works

The addon has two data sources:

1. **LibOpenRaid** (instant) — when group members also run Details!, their iLvl is broadcast via addon-comm. No inspect delay.
2. **Inspect API** (fallback) — for players without Details!, the addon inspects them outside of combat.

iLvl data is cached for 2 hours per player.

**Expected behavior — not bugs:**

- **First pull:** iLvl may not show for all players yet. Inspection runs after you join the group and takes a few seconds per player.
- **In combat (Details! inline mode):** tags pause until combat ends. Use **column mode** to see iLvl during combat.
- **In combat (Details! column mode):** iLvl and tier columns stay visible throughout combat. When DPS rankings change and bars swap positions, columns may briefly disappear and reappear — this is normal and ensures every bar always shows the correct player's data.
- **In combat (Blizzard DM):** player names may be secret-protected by Blizzard during combat. iLvl tags appear after combat ends when data becomes readable.
- **Blizzard DM after login / `/reload`:** iLvl does **not** appear on the existing bars immediately. The Blizzard meter only updates its bars when new combat data arrives — start a new fight and iLvl will appear. This is normal.
- **After the first fight:** everyone should be fully tagged.
- **After a boss kill:** the whole group gets re-inspected automatically.
- **On `/reload`:** cached data is restored instantly. Only new or uncached players get re-inspected.

**Tier set bonus `[2P]` / `[4P]`:**

- Only Midnight Season 1 tier pieces are detected (raid and M+ drops)
- Crafted gear, previous expansion tier, and PvP gear are not counted
- Your own set bonus appears immediately — other players appear after their inspect completes

---

## Slash Commands

| Command | What it does |
| --- | --- |
| `/dilvl` | Show all commands |
| `/dilvl on` / `off` | Enable / disable the addon |
| `/dilvl details` | Toggle iLvl display on Details! bars |
| `/dilvl blizzdm` | Toggle iLvl display on Blizzard Damage Meter |
| `/dilvl layout` | Toggle between `inline` and `columns` mode (Details! only) |
| `/dilvl layout inline` | Switch to inline mode (appended to name) |
| `/dilvl layout columns` | Switch to column mode (separate columns, works in combat) |
| `/dilvl elvui on` / `off` | Toggle ElvUI `[dilvl]` party frame tag |
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

1. Run `/dilvl elvui` to enable the tag
2. In ElvUI → Unit Frames → Party (or Raid/Player) → Name text, add `[dilvl]`
3. Example name text: `[name] [dilvl]`

The tag updates instantly when inspect data arrives, on gear swaps, or when the group changes — no polling timer. Zero performance cost during idle time.
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

**Reporting a bug:** run `/dilvl debug` and include the full output in your report. You can also [open an issue on GitHub](https://github.com/HK2084/Details_iLvlDisplay/issues).

---

## Links

- [CurseForge](https://www.curseforge.com/wow/addons/details-item-level-display) — download & install
- [GitHub Issues](https://github.com/HK2084/Details_iLvlDisplay/issues) — bug reports & feature requests

---

## License

MIT — see [LICENSE](LICENSE)
