**Details! Item Level Display** shows item level and tier set bonus next to every player name on [Details! Damage Meter](https://www.curseforge.com/wow/addons/details), [ElvUI](https://tukui.org/elvui), [Grid2](https://www.curseforge.com/wow/addons/grid2), [DandersFrames](https://www.curseforge.com/wow/addons/dandersframes), and **Blizzard's built-in Damage Meter**.

Built for **WoW: Midnight (12.0+)**. Five independent output channels — the addon detects what you have installed. Details! and Blizzard's meter come up on their own; the three unit-frame channels are one command away. **No dependencies required.**

**Don't use Details!?** No problem — the addon falls back to **Blizzard's Damage Meter** and works on top of your unit-frame addon of choice (ElvUI / Grid2 / Danders). Force it on with `/dilvl blizzdm`.

***

**How It Looks**

| Mode |Example |Command |
| ---- |------- |------- |
| <strong>Inline right</strong> (default) |<code>1. Raza [321] [4P] 67K</code> |<code>/dilvl position right</code> |
| <strong>Inline left</strong> |<code>1. [321] [4P] Raza 67K</code> |<code>/dilvl position left</code> |
| <strong>Columns</strong> (Details! only) |<code>1. Raza 4P 321 67K</code> |<code>/dilvl layout columns</code> |
| <strong>ElvUI frame tag</strong> |<code>Raza [321]</code> or <code>Raza 321</code> |<code>/dilvl elvui on</code> |
| <strong>Grid2 indicator</strong> |<code>321</code> on any text indicator |<code>/dilvl grid2 on</code> |
| <strong>Danders overlay</strong> |<code>321</code>, 13 positions, size 6-30 |<code>/dilvl danders on</code> |

***

**Item Level Colours — they move with the season**

The thresholds are **not fixed numbers**. At login the addon reads the current season's Mythic+ reward levels from the game itself and places every boundary on a real gear upgrade rank. When the next season raises everything, the scale follows on its own — nothing to update, and no season where half the raid shares one colour.

| Colour |What it takes to reach it |
| ------ |------------------------- |
| <strong>Teal</strong> |well into Mythic raid gear |
| <strong>Gold</strong> |past a fully upgraded Hero set |
| <strong>Orange</strong> |a fully upgraded Hero set — the practical Mythic+ ceiling |
| <strong>Purple</strong> |what a high Mythic+ vault awards |
| <strong>Blue</strong> |a mid-range key |
| <strong>Green</strong> |just under the season's entry level |
| <strong>Grey</strong> |below that, or an item level that cannot be read |

The **tier mark** means something else: its green and grey are the *season*, not the gear tier. Mid tier change a row reads `1. Raza [321] [2P] [2P] 67K` — grey for what is being left behind, green for what is being built. Grid2 and Danders show one uncoloured mark instead.

***

**Features**

*   Item level in brackets next to each player name, colour-coded by gear tier — derived from the live season, never a hardcoded table
*   **2P / 4P tier (PvE) set bonus** for Midnight **Season 1 and Season 2**, coloured by season so one look tells you who is still on last season's set
*   **Instant item levels via LibOpenRaid** — anyone in your group who also runs Details! broadcasts their gear, so their number appears with no inspect delay. Those entries are marked `[LOR]` in `/dilvl cache`
*   **Sealed rows still get tagged.** In instanced content the game hides most player names from addons; rows are identified by their player ID instead. Where identity cannot be established beyond doubt the row stays blank on purpose — a missing tag is fine, another player's name is not
*   **In-game Settings UI** — four tabs (What's New / General / Output Channels / Diagnostics) with two live preview panes that update as you change settings. Resizable, full EN + DE. Open with `/dilvl`, or `/dilvl ui diagnostics` for a bug report
*   **Five output channels**, independently toggleable, each fault-isolated: a bug in one cannot take down another, and each recovers on its own toggle
*   **Two layout modes** (Details!): `inline` or `columns` — and **columns keeps working during combat**, where inline cannot
*   **Position toggle** — item level before or after the player name, on Details! and Blizzard's meter
*   **Two ElvUI tags** — `[dilvl]` (`Raza [321]`) and `[dilvl:plain]` (`Raza 321`), listed in ElvUI's tag browser and usable in any Custom Text
*   **Danders Frames overlay** — 13 anchor positions (7 inside the frame, 6 above or below it) and live text size, 6-30, no `/reload`
*   **Details! fine-tuning** — pin the text size with `/dilvl details size <n>` and limit the display to a single window with `/dilvl details window <n>`
*   **First-time login hints** — a new feature announces itself once per character in a single chat line, and the What's New tab opens itself once after an update
*   Automatic background inspection outside combat, re-inspection after boss kills, on gear changes and on roster changes; timed-out inspects are retried
*   Persistent cache — survives `/reload`, loads instantly on re-login. Entries re-inspect themselves after two hours and are kept for seven days; the number stays on screen in between, including after that player has left your group
*   Cross-realm, M+, LFR and LFD support, up to 40 players

***

**Supported Output Channels**

| Channel |Default |Toggle |Notes |
| ------- |------- |------ |----- |
| <strong>Details! Damage Meter</strong> |ON when installed |<code>/dilvl details</code> |Full support: inline, columns, position toggle |
| <strong>ElvUI</strong> |OFF (opt-in) |<code>/dilvl elvui on</code> |<code>[dilvl]</code> and <code>[dilvl:plain]</code> tags for unit frames |
| <strong>Grid2</strong> |OFF (opt-in) |<code>/dilvl grid2 on</code> |Custom <code>dilvl</code> status, assignable to any text indicator |
| <strong>DandersFrames</strong> |OFF (opt-in) |<code>/dilvl danders on</code> |FontString overlay, 13 anchor positions, live text size |
| <strong>Blizzard Damage Meter</strong> |AUTO |<code>/dilvl blizzdm</code> |On by itself only when Details! is absent. Inline + position toggle; no columns |

AUTO means *on when Details! is not installed*. The slash toggle switches between forced on and forced off — use the Settings UI to return to AUTO.

***

**⚠️ Blizzard Damage Meter — What To Expect**

Blizzard's Secret Value system in Midnight seals combat data inside instanced content (Dungeons, Delves, M+, LFR/Raid). Tags are stripped at the pull and come back by themselves afterwards; some class colours may briefly reset when combat ends. These are Blizzard restrictions, not addon bugs.

Rows keep their tags through a kill, a wipe and the walk to the next boss — switching segments (A–G) by hand is no longer necessary.

Where the game lifts its combat restriction and no keystone is active, rows that came out of a fight still sealed are filled in automatically: the addon toggles the meter's own enable setting once and Blizzard rebuilds every row itself. **The meter blinks briefly when this fires.** It runs at most once per fight, never during combat and never inside an active keystone, and switches itself off for the session if it stops helping. `/dilvl autorefresh` disables it entirely, and inside a keystone the manual A–G switch remains the fallback.

**ElvUI, Grid2 and DandersFrames are unaffected** — they have no combat gate at all. **Details! bars** follow the same rule as Blizzard's meter in inline layout; in **Columns layout** item level and tier stay visible right through the fight.

***

**Slash Commands**

| Command |What it does |
| ------- |------------ |
| <code>/dilvl</code> |Open or close the Settings UI. In combat it opens by itself once the fight ends |
| <code>/dilvl ui &lt;tab&gt;</code> |Open straight to a tab: <code>whatsnew</code>, <code>general</code>, <code>channels</code>, <code>diagnostics</code> |
| <code>/dilvl on</code> / <code>off</code> |Enable / disable the addon |
| <code>/dilvl details</code> |Toggle Details! bars |
| <code>/dilvl details size &lt;n&gt;</code> |Text size on Details! bars (0 = match Details' own font, or 6-30; Columns layout) |
| <code>/dilvl details window &lt;n&gt;</code> |Show item level on only one Details! window (<code>all</code> or 1-10) |
| <code>/dilvl blizzdm</code> |Toggle Blizzard's Damage Meter overlay |
| <code>/dilvl autorefresh</code> |Turn the automatic post-fight refresh (and its blink) off |
| <code>/dilvl elvui</code> / <code>grid2</code> / <code>danders</code> |Toggle that channel — bare command means on, or add <code>on</code> / <code>off</code> |
| <code>/dilvl danders pos &lt;opt&gt;</code> |Inside: <code>top</code>, <code>topright</code>, <code>topleft</code>, <code>bottom</code>, <code>bottomright</code>, <code>bottomleft</code>, <code>center</code>. Off-frame: <code>above</code>, <code>aboveleft</code>, <code>aboveright</code>, <code>below</code>, <code>belowleft</code>, <code>belowright</code> |
| <code>/dilvl danders size &lt;n&gt;</code> |Danders text size, 6-30, live, no <code>/reload</code> |
| <code>/dilvl layout</code> |Toggle inline / columns (Details! only) |
| <code>/dilvl position</code> |Item level left or right of the name |
| <code>/dilvl color</code> |Toggle the colour coding |
| <code>/dilvl setbonus</code> |Toggle the 2P/4P mark |
| <code>/dilvl inspect</code> |Re-inspect the group by hand |
| <code>/dilvl cache</code> |List every cached item level and where it came from |
| <code>/dilvl debug</code> |Full status report in a selectable window, ready to paste into a bug report |

Any unrecognised command prints this list in chat, along with the remaining diagnostics.

***

Full documentation, source code, and issue tracker on [GitHub](https://github.com/HK2084/Details_iLvlDisplay).
