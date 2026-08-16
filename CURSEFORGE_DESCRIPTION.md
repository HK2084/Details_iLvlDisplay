**Details! Item Level Display** shows item level and tier set bonus next to every player name on [Details! Damage Meter](https://www.curseforge.com/wow/addons/details), [ElvUI](https://tukui.org/elvui), [Grid2](https://www.curseforge.com/wow/addons/grid2), [DandersFrames](https://www.curseforge.com/wow/addons/dandersframes), and **Blizzard's built-in Damage Meter** (experimental).

Built for **WoW: Midnight (12.0+)**. Five independent output channels — the addon detects what you have installed. Details! and Blizzard's meter come up on their own; the three unit-frame channels are one command away.

**New in v1.5.6:** tier set bonuses are **colour-coded by season** — green for the current season's set, grey for last season's. While someone is switching over, both are shown side by side, so one look at the meter tells you who has already moved across and who is still on the old set.

**Don't use Details!?** No problem — the addon falls back to **Blizzard's Damage Meter** (12.0+) and works on top of your unit-frame addon of choice (ElvUI / Grid2 / Danders). Force BlizzDM on with `/dilvl blizzdm`.

***

**How It Looks**

| Mode                    |Example                   |Command               |
| ----------------------- |------------------------- |--------------------- |
| <strong>Inline right</strong> (default) |<code>1. Raza [263] [4P] 67K</code> |<code>/dilvl position right</code> |
| <strong>Inline left</strong> |<code>1. [263] [4P] Raza 67K</code> |<code>/dilvl position left</code> |
| <strong>Columns</strong> (Details! only) |<code>1. Raza 4P 263 67K</code> |<code>/dilvl layout columns</code> |
| <strong>ElvUI frame tag</strong> |<code>Raza [263]</code> or <code>Raza 263</code> |<code>/dilvl elvui on</code> |
| <strong>Grid2 indicator</strong> |<code>263</code> on any text indicator |<code>/dilvl grid2 on</code> |
| <strong>Danders Frames overlay</strong> |<code>263</code> in 13 positions, live size 6-30 |<code>/dilvl danders on</code> |

The tier mark carries the season colour: **green** = the current season's bonus, **grey** = an older one. Mid tier change a row reads `1. Raza [271] [2P] [2P] 67K` — first the grey mark for what is being left behind, then the green one for what is being built.

Position toggle (`/dilvl position`) applies to Details! and Blizzard DM. Column layout is Details! only.

***

**Features**

*   Item level in brackets next to each player name: `Raza [259]`
*   **Tier set bonus coloured by season** — green for the current season, grey for an older one. Both are shown next to each other while a player is switching over, oldest first, so you can see who in the run is still on last season's set
*   **2P / 4P tier (PvE) set bonus** detection for Midnight **Season 1 and Season 2**
*   **In-game Settings UI** — four tabs (What's New / General / Output Channels / Diagnostics) with a persistent live-preview pane that updates as you change settings. Resizable window. Open via `/dilvl` or Esc → Options → AddOns. Full EN + DE
*   **Five output channels** — Details! bars, ElvUI tag, Grid2 status, Danders FontString, Blizzard DM — independently toggleable
*   **Two layout modes** (Details!): `inline` or `columns` — switch via `/dilvl layout`
*   **Position toggle** — iLvl before or after player name via `/dilvl position`
*   **Column mode works during combat** — iLvl and tier stay visible while fighting
*   Item level colour-coded by gear tier, in the familiar quality colours (orange → purple → blue → green → grey). The tier mark's green and grey mean *season*, not gear tier
*   **Instant iLvl via LibOpenRaid** — Details! users share iLvl instantly, no inspect delay
*   **Two ElvUI tags** — `[dilvl]` (with brackets, `Raza [284]`) and `[dilvl:plain]` (bare number, `Raza 284`). Listed in ElvUI's tag browser, usable in any Custom Text
*   **Danders Frames overlay** — 13 anchor positions (7 inside + 6 off-frame above/below the unit) and live text size (`/dilvl danders size <n>`, range 6-30, no `/reload` needed)
*   **Details! fine-tuning** — pin the iLvl text size with `/dilvl details size <n>` (0 = match Details' own font) and restrict the display to a single Details! window with `/dilvl details window <n>`
*   **First-time login hints** — new features announce themselves once per character via a single chat message so you discover them without reading the changelog
*   **Per-feature fault isolation** — a bug in one channel can't take down the others (each has its own auto-disable + recovery)
*   Automatic background inspection outside of combat
*   Persistent cache — survives `/reload`, loads instantly on re-login. Entries refresh themselves after 2 hours and are kept for 7 days
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

Blizzard's Secret Value system in Midnight seals combat data inside instanced content (Dungeons, Delves, M+, LFR/Raid). Two effects remain:

*   Tags disappear during combat and reappear between pulls
*   Some class colors may briefly reset after combat ends

These are Blizzard restrictions, not addon bugs.

**Improved in v1.5.5:** rows keep their tags through a kill, a wipe and the walk to the next boss. Switching segments (A–G) by hand to get the numbers back is no longer necessary.

**ElvUI, Grid2 and DandersFrames are unaffected** — they have no combat gate at all. **Details! bars** follow the same rule as Blizzard's meter in inline layout; in **Columns layout** (`/dilvl layout columns`) iLvl and tier stay visible right through the fight.

***

**Slash Commands**

*   `/dilvl` — open the Settings UI
*   `/dilvl help` — list every command in chat
*   `/dilvl on` / `off` — enable / disable
*   `/dilvl details` — toggle Details! bars
*   `/dilvl details size <n>` — iLvl text size on Details! bars (0 = match Details' font, or 6-30; Columns layout)
*   `/dilvl details window <n>` — show iLvl on only one Details! window (`all` or 1-10)
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

`/dilvl help` also lists the diagnostic commands used when reporting a bug.

***

Full documentation, source code, and issue tracker on [GitHub](https://github.com/HK2084/Details_iLvlDisplay).
