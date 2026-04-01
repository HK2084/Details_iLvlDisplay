# Details! iLvl Display

Shows **item level** and **tier set bonus** next to every player name on [Details! Damage Meter](https://www.curseforge.com/wow/addons/details) bars.

Built for **WoW: Midnight** (12.0+). Details! stopped exposing third-party item levels in Midnight — this addon brings that back.

---

## Features

- Item level displayed in brackets next to each player name: `Quinroth [254]`
- Color-coded by gear tier (see table below)
- **2P / 4P tier set bonus** detection for Midnight Season 1 tier pieces
- Automatic background inspection of group and raid members outside of combat
- 2-hour persistent cache — survives `/reload`, loads instantly on re-login
- Automatic re-inspection after boss kills (catches loot upgrades)
- Your own iLvl and set bonus update instantly on gear swap — no inspect needed
- Cross-realm, LFR and LFD support (up to 40 players)
- Manual inspect protection — background queue pauses when you inspect someone
- iLvl tags re-appear immediately after resizing the Details! window
- **Independent toggles** — enable Details! bars and/or ElvUI frames separately
- Optional **ElvUI integration**: adds a `[dilvl]` tag for party/raid unit frames

---

## Preview

```text
1. Quinroth     [252] [2P]     298K
2. Tankplayer   [265] [4P]     210K
3. Healsalot    [248]           95K
```

### iLvl Colors

| Color | Range |
| --- | --- |
| Orange | BiS / top tier |
| Purple | High end |
| Blue | Mid |
| Green | Low |
| Grey | Base |

---

## Requirements

- [Details! Damage Meter](https://www.curseforge.com/wow/addons/details) — optional (bars feature only)
- [ElvUI](https://www.tukui.org/download.php?ui=elvui) — optional (party frame tag only)

The addon works without either — install only what you use.

---

## How it works

The addon inspects group members **outside of combat** using WoW's native inspect API. iLvl data is cached for 2 hours per player.

**Expected behavior — not bugs:**

- **First pull:** iLvl may not show for all players yet. Inspection runs after you join the group and takes a few seconds per player.
- **In combat:** no updates. Tags stay as-is until combat ends.
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
| `/dilvl elvui on` / `off` | Toggle ElvUI `[dilvl]` party frame tag |
| `/dilvl color` | Toggle color-coded iLvl display |
| `/dilvl setbonus` | Toggle 2P/4P tier set bonus display |
| `/dilvl inspect` | Manually trigger a full group re-inspect |
| `/dilvl debug` | Full status report — paste this when reporting a bug |
| `/dilvl cache` | Show all cached iLvl entries with age |
| `/dilvl map` | Show current name → iLvl map |
| `/dilvl tier` | Scan your own tier slots and set IDs |
| `/dilvl elvui on` | Enable ElvUI `[dilvl]` party frame tag |
| `/dilvl elvui off` | Disable ElvUI `[dilvl]` party frame tag |
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
→ Run `/dilvl debug` and check that `Details-bars` and `Addon` are both `ON`. If `Details-bars: OFF`, run `/dilvl details` to re-enable. Then `/dilvl inspect`.

**Reporting a bug:** run `/dilvl debug` and include the full output in your report.

---

## License

MIT — see [LICENSE](LICENSE)
