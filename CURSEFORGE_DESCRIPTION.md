**Details! Item Level Display** shows item level and tier set bonus next to every player name on [Details! Damage Meter](https://www.curseforge.com/wow/addons/details), [ElvUI](https://tukui.org/elvui) party frames, and **Blizzard's built-in Damage Meter** (as fallback).

Built for **WoW: Midnight (12.0+)**. Primarily a **Details! plugin** — also supports ElvUI party frames and Blizzard's built-in Damage Meter as fallback for players without Details!. No configuration needed, **auto-detects** which meters you use.

**Don't use Details!?** No problem — the addon automatically falls back to **Blizzard's Damage Meter** (12.0+), showing iLvl and tier set bonus directly on WoW's built-in DPS, Healing, and Overall windows. Force on with `/dilvl blizzdm`.

***

**Features**

*   Item level in brackets next to each player name: `Razul [259]`
*   **Three meter support**: Details! bars, ElvUI party frames, and Blizzard Damage Meter (12.0+ fallback) — independently toggleable
*   **Two layout modes** (Details!): `inline` (default) or `columns` — switch via `/dilvl layout`
*   **Column mode works during combat** — iLvl and tier stay visible while fighting. When bars swap positions, columns briefly refresh to keep data accurate
*   Color-coded by gear tier (orange = BiS, purple = high, blue = mid, green = low, grey = base)
*   **2P / 4P tier (PvE) set bonus** detection for Midnight Season 1 tier pieces
*   **Instant iLvl via LibOpenRaid** — players running Details! share iLvl instantly, no inspect delay
*   **ElvUI party frame support** — `[dilvl]` tag showing iLvl on unit frames (enable via `/dilvl elvui on`)
*   Automatic background inspection outside of combat — no manual action needed
*   2-hour persistent cache — survives `/reload`, loads instantly on re-login
*   Automatic re-inspection after boss kills (catches loot upgrades)
*   Your own iLvl updates instantly on gear swap — no inspect needed
*   Cross-realm, M+, LFR and LFD support (up to 40 players)
*   **Defensive combat guard** — during combat, the addon does nothing on Blizzard DM frames. Tags appear between pulls and after boss kills

***

**Supported Meters**

| Meter | Default | Toggle |
| --- | --- | --- |
| **Details! Damage Meter** | ON when Details! is installed | `/dilvl details` |
| **ElvUI party frames** | OFF (opt-in) | `/dilvl elvui on` |
| **Blizzard Damage Meter** (12.0+) | AUTO — ON when Details! is not installed | `/dilvl blizzdm` |

No dependencies required. Install the addon, and it works with whatever you have.

***

**Slash Commands**

*   `/dilvl` — show all commands
*   `/dilvl on` / `off` — enable / disable
*   `/dilvl details` — toggle Details! bars
*   `/dilvl blizzdm` — toggle Blizzard Damage Meter overlay
*   `/dilvl elvui on` / `off` — toggle ElvUI tag
*   `/dilvl layout` — toggle between inline and column mode
*   `/dilvl color` — toggle color-coded display
*   `/dilvl setbonus` — toggle 2P/4P display
*   `/dilvl inspect` — manual re-inspect
*   `/dilvl debug` — full status report for bug reports

***

**FAQ**

**Q: Why doesn't iLvl show during combat?**
That's a Blizzard API limitation — they block the tooltip data we need for iLvl during combat. No addon can work around that without risking UI taint errors. Once combat ends, everything updates automatically.

***

Full documentation, source code, and issue tracker on [GitHub](https://github.com/HK2084/Details_iLvlDisplay).
