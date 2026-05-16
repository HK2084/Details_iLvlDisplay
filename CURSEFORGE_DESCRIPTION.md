**Details! Item Level Display** shows item level and tier set bonus next to every player name across five different surfaces: [Details! Damage Meter](https://www.curseforge.com/wow/addons/details), [ElvUI](https://tukui.org/elvui) party/raid frames, [Grid2](https://www.curseforge.com/wow/addons/grid2) raid frames, [Danders Frames](https://www.curseforge.com/wow/addons/dandersframes), and **Blizzard's built-in Damage Meter** (as fallback).

Built for **WoW: Midnight (12.0+)**. Primarily a **Details! plugin** — also supports four other surfaces. No configuration needed, **auto-detects** what you have installed.

**Don't use Details!?** No problem — the addon automatically falls back to **Blizzard's Damage Meter** (12.0+), showing iLvl and tier set bonus directly on WoW's built-in DPS, Healing, and Overall windows. Force on with `/dilvl blizzdm`.

***

**Features**

*   Item level in brackets next to each player name: `Razul [259]`
*   **Five-surface support**: Details! bars, ElvUI party/raid frames, Grid2 raid frames, Danders Frames overlay, and Blizzard Damage Meter (12.0+ fallback) — independently toggleable, fault-isolated (a bug in one never disables another)
*   **Two layout modes** (Details!): `inline` (default) or `columns` — switch via `/dilvl layout`
*   **Column mode works during combat** — iLvl and tier stay visible while fighting. When bars swap positions, columns briefly refresh to keep data accurate
*   Color-coded by gear tier (orange = BiS, purple = high, blue = mid, green = low, grey = base)
*   **2P / 4P tier (PvE) set bonus** detection for Midnight Season 1 tier pieces
*   **Instant iLvl via LibOpenRaid** — players running Details! share iLvl instantly, no inspect delay
*   **ElvUI tags** — `[dilvl]` (with brackets, `Raza [284]`) and `[dilvl:plain]` (bare number, `Raza 284`). Both listed in ElvUI's tag browser, usable in any Custom Text
*   **Grid2 status** — `dilvl` registers as a Grid2 status, addable to any text indicator (corner, side, ...) via the Grid2 GUI
*   **Danders Frames overlay** — addon-owned FontString per Danders Frame, 13 anchor positions (7 inside-frame + 6 off-frame above/below the unit), adjustable text size (6-30, live, no `/reload`)
*   **iLvl position toggle** — `/dilvl position` places the iLvl tag before or after the player name
*   Automatic background inspection outside of combat — no manual action needed
*   2-hour persistent cache — survives `/reload`, loads instantly on re-login
*   Automatic re-inspection after boss kills (catches loot upgrades)
*   Your own iLvl updates instantly on gear swap — no inspect needed
*   Cross-realm, M+, LFR and LFD support (up to 40 players)
*   **Defensive combat guard** — during combat, the addon does nothing on Blizzard DM frames. Tags appear between pulls and after boss kills
*   **First-time login hints** — new features announce themselves once per character via a single chat message so you discover them without reading the changelog

***

**Supported Surfaces**

| Surface | Default | Toggle |
| --- | --- | --- |
| **Details! Damage Meter** | ON when Details! is installed | `/dilvl details` |
| **ElvUI** (party/raid frames via `[dilvl]` / `[dilvl:plain]`) | OFF (opt-in) | `/dilvl elvui on` |
| **Grid2** (raid frames via `dilvl` status) | OFF (opt-in) | `/dilvl grid2 on` |
| **Danders Frames** (FontString overlay) | OFF (opt-in) | `/dilvl danders on` |
| **Blizzard Damage Meter** (12.0+) | AUTO — ON when Details! is not installed | `/dilvl blizzdm` |

No dependencies required. Install the addon, and it works with whatever you have.

***

**Slash Commands**

*   `/dilvl` — show all commands
*   `/dilvl on` / `off` — master enable / disable
*   `/dilvl details` — toggle Details! bars
*   `/dilvl elvui on` / `off` — toggle ElvUI tag
*   `/dilvl grid2 on` / `off` — toggle Grid2 status
*   `/dilvl danders on` / `off` — toggle Danders Frames overlay
*   `/dilvl danders pos <opt>` — Danders text position (live, no `/reload`). Inside: top, topright, topleft, bottom, bottomright, bottomleft, center. Off-frame: above, aboveleft, aboveright, below, belowleft, belowright
*   `/dilvl danders size <n>` — Danders text size (6-30, live)
*   `/dilvl blizzdm` — toggle Blizzard Damage Meter overlay
*   `/dilvl layout` — toggle between inline and column mode (Details!)
*   `/dilvl position` — toggle iLvl left/right of name (inline mode)
*   `/dilvl color` — toggle color-coded display
*   `/dilvl setbonus` — toggle 2P/4P display
*   `/dilvl inspect` — manual re-inspect
*   `/dilvl debug` — full status report for bug reports

***

**FAQ**

**Q: Why doesn't iLvl show during combat?**
That's a Blizzard API limitation — they block the tooltip data we need for iLvl during combat. No addon can work around that without risking UI taint errors. Once combat ends, everything updates automatically.

**Q: My Danders Frames iLvl text overlaps the unit's name. Can I move it?**
Yes — use `/dilvl danders pos above` (or `below`, `aboveleft`, `belowright`, ...). The text then floats outside the frame. In very dense raid layouts (25er stacked frames with no gap), off-frame positions may overlap the neighbouring frame — in that case pick a smaller font size with `/dilvl danders size <n>` and stick to inside positions.

**Q: Does this work without Details!?**
Yes — Blizzard's built-in Damage Meter, ElvUI, Grid2, and Danders Frames all work standalone. The addon auto-detects what you have.

***

Full documentation, source code, and issue tracker on [GitHub](https://github.com/HK2084/Details_iLvlDisplay).
