**Details! Item Level Display** shows item level and tier set bonus next to every player name on [Details! Damage Meter](https://www.curseforge.com/wow/addons/details), [ElvUI](https://tukui.org/elvui), [Grid2](https://www.curseforge.com/wow/addons/grid2), [DandersFrames](https://www.curseforge.com/wow/addons/dandersframes), and **Blizzard's built-in Damage Meter** (experimental).

Built for **WoW: Midnight (12.0+)**. Five independent output channels — auto-detects what you have installed, no configuration needed.

**New in v1.5:** in-game Settings UI (`/dilvl ui` or Esc → Options → AddOns) with three tabs, live preview, and full German translation. Resizable window. Per-page fault isolation so a broken tab can never take down the rest of the UI.

**Don't use Details!?** No problem — the addon falls back to **Blizzard's Damage Meter** (12.0+) and works on top of your unit-frame addon of choice (ElvUI / Grid2 / Danders). Force BlizzDM on with `/dilvl blizzdm`.

***

**How It Looks**

| Mode                    |Example                   |Command               |
| ----------------------- |------------------------- |--------------------- |
| <strong>Inline right</strong> (default) |<code>1. Razul [263] [4P] 67K</code> |<code>/dilvl position right</code> |
| <strong>Inline left</strong> |<code>1. [263] [4P] Razul 67K</code> |<code>/dilvl position left</code> |
| <strong>Columns</strong> (Details! only) |<code>1. Razul 4P 263 67K</code> |<code>/dilvl layout columns</code> |
| <strong>ElvUI frame tag</strong> |<code>Razul [263]</code> or <code>Razul 263</code> |<code>/dilvl elvui on</code> |
| <strong>Grid2 indicator</strong> |<code>263</code> on any text indicator |<code>/dilvl grid2 on</code> |
| <strong>Danders Frames overlay</strong> |<code>263</code> in 13 positions, live size 6-30 |<code>/dilvl danders on</code> |

Position toggle (`/dilvl position`) applies to Details! and Blizzard DM. Column layout is Details! only.

***

**Features**

*   Item level in brackets next to each player name: `Razul [259]`
*   **In-game Settings UI** (new in v1.5) — three tabs (General / Output Channels / Diagnostics) with a persistent live-preview pane that updates as you change settings. Resizable window. Open via `/dilvl ui` or Esc → Options → AddOns. Full EN + DE
*   **Five output channels** — Details! bars, ElvUI tag, Grid2 status, Danders FontString, Blizzard DM — independently toggleable
*   **Two layout modes** (Details!): `inline` or `columns` — switch via `/dilvl layout`
*   **Position toggle** — iLvl before or after player name via `/dilvl position`
*   **Column mode works during combat** — iLvl and tier stay visible while fighting
*   Color-coded by gear tier (orange = BiS, purple = high, blue = mid, green = low, grey = base)
*   **2P / 4P tier (PvE) set bonus** detection for Midnight Season 1
*   **Instant iLvl via LibOpenRaid** — Details! users share iLvl instantly, no inspect delay
*   **Two ElvUI tags** — `[dilvl]` (with brackets, `Raza [284]`) and `[dilvl:plain]` (bare number, `Raza 284`). Listed in ElvUI's tag browser, usable in any Custom Text
*   **Danders Frames overlay** — 13 anchor positions (7 inside + 6 off-frame above/below the unit) and live text size (`/dilvl danders size <n>`, range 6-30, no `/reload` needed)
*   **First-time login hints** — new features announce themselves once per character via a single chat message so you discover them without reading the changelog
*   **Per-feature fault isolation** — a bug in one channel can't take down the others (each has its own auto-disable + recovery)
*   Automatic background inspection outside of combat
*   2-hour persistent cache — survives `/reload`, loads instantly on re-login
*   Automatic re-inspection after boss kills (catches loot upgrades)
*   Your own iLvl updates instantly on gear swap
*   Cross-realm, M+, LFR and LFD support (up to 40 players)

***

**Supported Output Channels**

| Channel                       |Default           |Toggle            |Notes                                                                   |
| ----------------------------- |----------------- |----------------- |----------------------------------------------------------------------- |
| <strong>Details! Damage Meter</strong> |ON when installed |<code>/dilvl details</code> |Full support: inline, columns, position toggle                          |
| <strong>ElvUI</strong>        |OFF (opt-in)      |<code>/dilvl elvui on</code> |<code>[dilvl]</code> and <code>[dilvl:plain]</code> tags for unit frames |
| <strong>Grid2</strong>        |OFF (opt-in)      |<code>/dilvl grid2 on</code> |Custom <code>dilvl</code> status, assignable to any text indicator      |
| <strong>DandersFrames</strong> |OFF (opt-in)      |<code>/dilvl danders on</code> |FontString overlay, 13 anchor positions, live text size (6-30)         |
| <strong>Blizzard Damage Meter</strong> (12.0+) |AUTO              |<code>/dilvl blizzdm</code> |Experimental: inline + position toggle (<a href="#blizzard-damage-meter--known-limitations" rel="nofollow">limitations</a>) |

No dependencies required. Install the addon, and it works with whatever you have.

***

**⚠️ Blizzard Damage Meter — Known Limitations**

Due to Blizzard's Secret Value system in Midnight, the Blizz DM overlay has the following limitations in instanced content (Dungeons, Delves, M+, LFR/Raid):

*   Tags disappear during combat and reappear between pulls
*   Some class colors may briefly reset after combat ends
*   In LFR/Raid, certain segments (e.g. "Damage by Class") may not show tags — switch segments (A–G) to refresh
*   After a wipe in LFR/Raid, tags may not return until the next segment switch
*   **Left position** (`/dilvl position left`): players who haven't been inspected yet (out of range, just joined) may show no tag until the next pull. Right position is more forgiving here

These are Blizzard restrictions, not addon bugs. **Details! bars, ElvUI, Grid2, and DandersFrames are unaffected and always show full data.**

***

**Slash Commands**

*   `/dilvl` — show all commands
*   `/dilvl ui` — open the in-game Settings UI (v1.5)
*   `/dilvl on` / `off` — enable / disable
*   `/dilvl details` — toggle Details! bars
*   `/dilvl blizzdm` — toggle Blizzard Damage Meter overlay
*   `/dilvl elvui on` / `off` — toggle ElvUI tag
*   `/dilvl grid2 on` / `off` — toggle Grid2 status
*   `/dilvl danders on` / `off` — toggle Danders Frames overlay
*   `/dilvl danders pos <opt>` — Danders anchor position. Inside: `top`, `topright`, `topleft`, `bottom`, `bottomright`, `bottomleft`, `center`. Off-frame: `above`, `aboveleft`, `aboveright`, `below`, `belowleft`, `belowright`
*   `/dilvl danders size <n>` — Danders text size (6-30, live, no `/reload`)
*   `/dilvl layout` — toggle inline / columns (Details! only)
*   `/dilvl position` — toggle iLvl left / right of player name
*   `/dilvl color` — toggle color-coded display
*   `/dilvl setbonus` — toggle 2P/4P display
*   `/dilvl inspect` — manual re-inspect
*   `/dilvl debug` — full status report for bug reports

***

Full documentation, source code, and issue tracker on [GitHub](https://github.com/HK2084/Details_iLvlDisplay).
