# Details! iLvl Display

A lightweight plugin for [Details! Damage Meter](https://www.curseforge.com/wow/addons/details) that shows item level next to each player's name on the damage meter bars.

## Features

- Shows item level in brackets next to every player name: `Quinroth [487]`
- Color-coded by gear tier (orange = BiS, purple = heroic, blue = normal, green = LFR, grey = below)
- Inspects all group/raid members automatically outside of combat
- LRU cache (10 min) — no repeated inspects for the same player
- Cross-realm support (strips realm suffix for matching)
- Zero UI changes — hooks directly into Details! bar text
- `/dilvl` slash command for control and debugging

## Requirements

- [Details! Damage Meter](https://www.curseforge.com/wow/addons/details)

## Optional

- [Quick Item Level](https://www.curseforge.com/wow/addons/quick-item-level) — not required, but pairs well

## Installation

1. Download the latest release
2. Extract to `World of Warcraft\_retail_\Interface\AddOns\`
3. Make sure **Details!** is installed and enabled
4. Reload UI or log in

## Slash Commands

| Command | Description |
|---|---|
| `/dilvl` | Show help |
| `/dilvl on` | Enable |
| `/dilvl off` | Disable |
| `/dilvl color` | Toggle color-coded iLvl |
| `/dilvl inspect` | Manually trigger group inspect |
| `/dilvl cache` | Show cached iLvl values |
| `/dilvl map` | Show current name→iLvl map |
| `/dilvl debug` | Show debug info |

## How It Works

On `INSPECT_READY`, the addon reads item level via `C_PaperDollInfo.GetInspectItemLevel()` and caches it per GUID. After combat ends, the cache is refreshed. A lightweight ticker (every 2s) hooks new Details! bars and injects iLvl tags into bar text — only outside combat to avoid taint.

## License

MIT
