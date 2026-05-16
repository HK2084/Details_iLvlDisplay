# Changelog

## v1.4.4

### New

- **Adjustable text size on Danders Frames** — new slash `/dilvl danders size <n>`, range 6-30. Live update without `/reload`. Default 10, persists per character. Existing users see a one-shot login hint when Danders Frames is installed. Thanks to harrissx for the request
- **Off-frame anchor positions on Danders Frames** — six new positions for `/dilvl danders pos`: `above`, `aboveleft`, `aboveright`, `below`, `belowleft`, `belowright`. The iLvl text now floats *outside* the frame bounding box so it doesn't overlap the unit's name or HP at larger font sizes. Inside positions (top/topright/...) remain available — pick whichever fits your raid layout. Note: in dense raid stacks (25er with no gap between frames), above/below will overlap the neighbouring frame, so prefer inside positions in that case

### Defense

- **SafeUnitName: pcall-protected** — `UnitName()` is now wrapped against tainted-execution rejection so a hard-error from Blizzard's secret-arguments layer can't take the addon down. Three direct call sites in the Blizzard Damage Meter integration migrated to the shared wrapper. New `UnitNameRejected` counter in `/dilvl debug` makes regressions visible
- **12.0.7 compatibility** — TOC declares `120007` alongside `120001` and `120005`. Audited against PTR build 67227: no breaking changes for our APIs. Four preconditions (`RequiresDeclassifiedUnitIdentity`, `RequiresScriptObjectAlphaAccess`, `RequiresScriptObjectDesaturationAccess`, `RequiresStatusBarDesaturationAccess`) flip their failure mode from `ReturnNothing` to `ReturnWithError`; our `pcall` defense layer covers both paths

### Refactor

- **Foundation modular-base** — addon namespace bootstrap split into `init.lua` (defaults, position keys, login-hint registry), `secrets.lua` (12.0+ secret-value defense layer), `util.lua` (tier-set whitelist, color, name extraction). `core.lua` reduced from 2264 → ~2100 lines. Zero behavior change for existing users
- **Per-feature kill-switch isolation** — the previously-named `hookErrors` counter was Details!-bars-scoped already, now renamed `detailsBarErrors` to make that explicit. BlizzDM, Danders, ElvUI, and Grid2 have always carried their own independent counters — a bug in one feature can never auto-disable another
- **CanCompareUnitTokens probe fixed in /dilvl debug** — the foundation refactor accidentally dropped the local probe in `core.lua`, making the report always read `no`. Now reads `C_Secrets.CanCompareUnitTokens` directly

---

Older releases: see [HISTORY.md](HISTORY.md).
