# Details! iLvl Display

Shows item level and tier set bonus next to player names on the **Details! Damage Meter** bars.

> **Requires:** [Details! Damage Meter](https://www.curseforge.com/wow/addons/details)

---

## What it looks like

```
1. Quinroth     [252] [2P]     298K
2. Tankplayer   [265] [4P]     —
3. Healsalot    [248]          95K
```

- `[252]` — item level, color-coded by tier
- `[2P]` / `[4P]` — Midnight Season 1 tier set bonus (2-piece or 4-piece)

### Colors

| Color | Meaning |
|---|---|
| 🟠 Orange | BiS / top tier |
| 🟣 Purple | High end |
| 🔵 Blue | Mid |
| 🟢 Green | Low |
| ⚫ Grey | Base |

---

## When does it show up?

The addon inspects your group members **outside of combat** to read their gear.

**Expected behavior — this is not a bug:**

- **First pull:** iLvl may not show yet — inspection happens after you join the group, takes a few seconds
- **In combat:** nothing updates, tags stay as-is (WoW restricts addon actions in combat)
- **After the first fight:** everyone should be fully tagged
- **After a boss kill:** the group gets re-inspected automatically (someone may have gotten loot)
- **On `/reload`:** cached data loads instantly, new players get inspected in the background

**Set bonus `[2P]`/`[4P]`:**
- Only shows for players with **Midnight Season 1** tier pieces (raid/M+ drops)
- Your own set bonus appears immediately on load — no inspect needed
- For other players it appears after their inspect completes

---

## Installation

1. Extract the `Details_iLvlDisplay` folder into:
   ```
   World of Warcraft\_retail_\Interface\AddOns\
   ```
2. Make sure **Details!** is installed and enabled
3. Log in or `/reload`

---

## Slash Commands

| Command | What it does |
|---|---|
| `/dilvl` | Show help |
| `/dilvl on` / `off` | Enable / disable |
| `/dilvl color` | Toggle color-coded iLvl |
| `/dilvl setbonus` | Toggle 2P/4P display |
| `/dilvl inspect` | Manually trigger group inspect |
| `/dilvl debug` | Full status report (paste this when reporting a bug) |

---

## Something looks wrong?

Run `/dilvl debug` and paste the output. It contains everything needed to diagnose the issue.

**Common questions:**

**"iLvl is missing for some players"**
→ They were out of range when the inspect ran. Wait until after the first fight, or run `/dilvl inspect` manually.

**"Set bonus not showing"**
→ Only Midnight Season 1 tier pieces are detected. Crafted gear, previous expansion tier, and PvP gear are not counted.

**"It stopped showing anything"**
→ Run `/dilvl on` to make sure it's enabled, then `/dilvl inspect`.

---

## License

MIT — [github.com/HK2084/Details_iLvlDisplay](https://github.com/HK2084/Details_iLvlDisplay)
