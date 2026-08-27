# Details! iLvl Display

## Project Overview

Details! iLvl Display shows item level and tier set bonus next to player names on
five independent output channels: Details! Damage Meter bars, Blizzard's built-in
Damage Meter, ElvUI unit-frame tags, Grid2 status indicators, and DandersFrames
overlays. Each channel is separately toggleable and fault-isolated — a bug in one
must never take down another.

Built for WoW: Midnight (12.0+). The hard part of this addon is not the item
level; it is attributing a number to the right player when the game deliberately
hides who a row belongs to.

## The rule that outranks every other rule

**Never show data we cannot attribute.** A missing tag is fine. A wrong name, a
wrong number, or a number under someone else's name is not.

Every heuristic in this codebase declines rather than guesses. When you are
tempted to relax a check because "it is almost always right", read
`dev-docs/CODE_NOTES.md` first — most of those checks exist because the
almost-always-right version already shipped once and put one player's item level
under another player's name.

Concretely, this means:

* A row is tagged only when its owner is proven, never when it is likely.
* Identity travels with the GUID it was built from, and every consumer re-checks it.
* An incomplete reading produces no tag and schedules another look. It never
  produces a partial tag that gets cached as final.

## Non-negotiables

1. **Nothing may throw out of a hook.** We run inside Details! and next to
   Blizzard's meter. An error escaping our code surfaces with *our* name on it in
   someone else's addon. Every foreign-mixin call is wrapped; see `SafeCall` in
   `core.lua` and the pcall discipline in `blizzdm.lua`.
2. **Documented APIs only.** Never call `Ambiguate` directly outside
   `util.lua`/`secrets.lua`; never use elevation primitives. Undocumented
   behaviour may be used only as a *fallback* behind a documented path, and only
   with a version canary and a kill switch (see `#auto-backfill` and
   `#securetest` in the code notes).
3. **Never drive Blizzard's meter redraw.** Asking it to rebuild reaches
   `DamageMeterEntry.lua:104` under our taint and throws, freezing the meter.
   This was tried twice and reverted twice. Settled 20.08.2026, documented in the
   `blizzdm.lua` header. Do not try a third time.
4. **Secret values are detected with `issecretvalue`, never with `type()`.** A
   secret string still reports `"string"`. Comparing, concatenating, or using a
   secret as a table key throws. `secrets.lua` is the only file allowed to call
   the six secret-prone APIs raw; everything else goes through its wrappers, and
   `.luacheckrc` enforces that by leaving those APIs out of `read_globals`.
5. **Never skip a version number**, and never write the maintainer's real name
   into a file. The public handle is `HK2084`.

## Before you propose a change: run the gates

```
python tools/check-lua-limits.py      # real Lua 5.1 compile: 60 upvalues, 200 locals
python tools/test-*.py                # 10 behaviour suites, each with positive controls
bash   tools/lint-secret-mixin.sh     # no raw secret-touching mixin calls
bash   tools/lint-package-contents.sh # allowlist: nothing but addon content ships
bash   tools/lint-no-setscript.sh     # blizzdm.lua may SetScript only on its own frames
python tools/lint-doc-anchors.py      # code and dev-docs/CODE_NOTES.md stay in sync
```

All of them must pass. They are not decoration: every suite exists because the
bug it tests for shipped once. Each carries **positive controls** — deliberately
broken variants that the suite must fail on — so a suite that silently stops
testing anything is itself caught.

If you change a comment block that a suite extracts by regex, re-run the suites:
the anchors are code (function signatures, `end`), but refactors move them.

## Architecture

| File | Responsibility |
|---|---|
| `init.lua` | defaults, login hints, position keys. Load order: first. |
| `secrets.lua` | the only place the six secret-prone APIs are called raw |
| `util.lua` | pure helpers — arguments in, values out, no addon state |
| `core.lua` | cache, inspect pipeline, Details! rendering, settings router, debug |
| `blizzdm.lua` | Blizzard Damage Meter integration (identity, injection, backfill) |
| `elvui_integration.lua`, `grid2_integration.lua`, `danders_integration.lua` | one channel each |
| `ui/` | settings UI — plain CreateFrame plus Blizzard templates |
| `tools/` | the gates (see above). Not shipped. |
| `dev-docs/` | why the code looks the way it does. Not shipped. |

Keep the architecture free of cycles. Anything that touches caches, db, hooks or
events belongs in `core.lua`, not `util.lua`.

## Code style

* Indent with 4 spaces. Comments are line comments (`--`), not block comments.
* **Comments state the rule and the trap it guards, in a few lines.** The
  derivation — the measurement, the live incident, the proof against Blizzard's
  source — belongs in `dev-docs/CODE_NOTES.md`, linked from the code as
  `-- Why: dev-docs/CODE_NOTES.md#anchor`. `tools/lint-doc-anchors.py` checks
  both directions of that link.
* Cite foreign code by `file:line` when you rely on its behaviour
  (`class_damage.lua:3199`, `DamageMeterEntry.lua:477`). Claims about Details!
  or Blizzard internals need a reference, not an assertion.
* Source files stay ASCII-safe: write `—` and similar as byte escapes
  (`"\226\128\148"`). Documentation under `dev-docs/` may use UTF-8 freely.
* Lua 5.1: 60 upvalues per closure, 200 locals per chunk. `check-lua-limits.py`
  compiles with a real Lua 5.1 because exceeding this took the client down once.

## Localization

The addon ships English and German; the AddOn-list description is also localised
for ruRU, zhCN, zhTW and koKR. When adding a user-facing string, add it to all
locales present in the locale table. Use in-game wording — for German, address
players politely ("Ihr"), matching Blizzard's own strings. Blizzard's
`GlobalStrings.lua` per locale is the reference for exact in-game terms.

**Rank prefixes are localised and are not always a full stop** (zhCN uses U+3001,
zhTW U+3002). Never hardcode `"^%d+%."` for Blizzard's meter — derive it from the
format string. Details! is the opposite case: it hardcodes `". "` in every
language, so the patterns in `core.lua` and `util.lua` are correct as they are.

## Performance

The hot path is the Details! `SetText` hook: measured at ~28 writes per second
over a four-hour session, ~90 % of them on sealed rows. What matters there is the
allocation rate, not microseconds — avoid anonymous closures, string
concatenation, and table literals in that path. Cold paths (settings, debug
report, the post-fight backfill) may be written for clarity instead.

Do not add a throttle: Details! already ticks at its own `update_speed`, and a
second throttle only risks flicker.

## Reporting and diagnostics

`/dilvl debug` produces the full status report users paste into bug reports. If
you add state that a future bug will hinge on, surface it there — a counter no
report prints is a counter nobody will ever see.

## Contributions

Issues and pull requests are welcome at
<https://github.com/HK2084/Details_iLvlDisplay>. Translations from native
speakers are especially welcome. Please run the gates before opening a PR, and
say in the description which live scenario you tested — this addon's failure
modes only appear in a real group.
