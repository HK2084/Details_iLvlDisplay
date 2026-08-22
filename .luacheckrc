-- .luacheckrc — Details_iLvlDisplay secret-value INVARIANT linter
--
-- THE INVARIANT (the whole reason this file exists):
--   No raw secret-prone WoW API may be called outside secrets.lua. Every
--   UnitGUID / UnitName / GetUnitName / UnitFullName / UnitIsUnit /
--   InCombatLockdown call must go through the secret-safe wrappers in
--   secrets.lua (SafeUnitGUID / SafeUnitName / SafeUnitIsUnit /
--   IsInCombatSafe / MayBeInCombat). Inside WoW 12.0+ restricted instances
--   these APIs return SECRET values; a raw ==/~=/</#/tonumber/table-key/
--   concat on a secret throws ("attempt to compare/use a secret value").
--   That is the exact class of crash that hit the Slave Pens event dungeon.
--
-- HOW IT IS ENFORCED:
--   These six APIs are deliberately LEFT OUT of read_globals below. So a raw
--   call anywhere reads as luacheck code 113 ("accessing undefined variable")
--   => warning => CI fails. secrets.lua is the ONLY file that whitelists them
--   (see files["secrets.lua"] at the bottom). To satisfy the linter you must
--   route the call through a wrapper — which is the point.
--
--   Consequence: even the always-safe UnitGUID("player") / UnitName("player")
--   sites must use SafeUnitGUID("player") etc. (identical behaviour, never
--   secret) so the invariant has zero exceptions and stays trivially auditable.
--
-- Run locally:  luacheck . --std lua51
-- (read_globals regenerated from the addon's actual API surface via
--  `luacheck . --only 113 --globals ""`, minus the six forbidden APIs.)

std = "lua51"
max_line_length = false
codes = true
self = false

exclude_files = {
	"**/Libs",
	"**/.git",
	".release", -- BigWigs-packager build output (stale copies, not source)
	"**/.release",
}

-- Cosmetic noise we don't gate CI on (keep the signal = the secret invariant).
ignore = {
	"212", -- unused argument
	"213", -- unused loop variable
	"231", -- local var set but never accessed
	"311", -- value assigned to local never accessed
	"4.2", -- shadowing (431/432) — common with the `local X = ns.secrets.X` shadows
	"542", -- empty if branch
	"1/[A-Z][A-Z][A-Z0-9_]+", -- ALL_CAPS pseudo-constants (WoW enum-style globals)
}

-- Globals the addon itself DEFINES / writes (read + write allowed everywhere).
globals = {
	"Details_iLvlDisplayAPI",
	"Details_iLvlDisplayDB",
	"Details_iLvlDisplay_BlizzDMApplySetting",
	"Details_iLvlDisplay_BlizzDMArmAutoFlip",
	"Details_iLvlDisplay_BlizzDMAutoFlipState",
	"Details_iLvlDisplay_BlizzDMReset",
	"Details_iLvlDisplay_BlizzDMSecureTest",
	"Details_iLvlDisplay_BlizzDMSelfTest",
	"Details_iLvlDisplay_BlizzDMState",
	"Details_iLvlDisplay_BlizzDMTryAutoFlip",
	"Details_iLvlDisplay_BlizzTrace",
	"Details_iLvlDisplay_DandersApplyFontSize",
	"Details_iLvlDisplay_DandersApplyPos",
	"Details_iLvlDisplay_DandersDebug",
	"Details_iLvlDisplay_DandersReset",
	"Details_iLvlDisplay_DandersState",
	"Details_iLvlDisplay_ShowDebugWindow",
	"Grid2",
	"SLASH_DILVL1",
	"SlashCmdList",
	"StaticPopupDialogs",
}

-- Read-only API surface the addon uses. Regenerated mechanically from the
-- code; the six secret-prone APIs are intentionally ABSENT (see header).
read_globals = {
	"ACCEPT", "Ambiguate", "CANCEL",
	"C_AddOns", "C_DamageMeter", "C_InstanceEncounter", "C_Item", "C_Map",
	"C_MythicPlus", "C_PaperDollInfo", "C_RestrictedActions",
	"C_Secrets", "C_Timer", "C_UnitAuras",
	"CanInspect", "ClearInspectPlayer", "CreateFrame",
	"DETAILS_ATTRIBUTE_DAMAGE", "DETAILS_ATTRIBUTE_HEAL", "DILvlDebugFrame",
	"DamageMeter", "DamageMeterEntryMixin", "DamageMeterSourceEntryMixin",
	"DandersFrames", "DandersFrames_IsReady", "DandersFrames_IterateFrames",
	"Details", "ElvUI", "Enum",
	"GameFontHighlightSmall", "GameTooltip",
	"GetAverageItemLevel", "GetBuildInfo", "GetCVar", "GetInventoryItemID",
	"GetLocale", "GetNumGroupMembers", "GetPlayerInfoByGUID", "GetTime",
	"IsEncounterInProgress", "IsInGroup", "IsInRaid",
	"LE_PARTY_CATEGORY_INSTANCE", "LibStub",
	"NotifyInspect", "NumberFontNormal", "SetCVar", "Settings",
	"StaticPopup_Show",
	"UIDropDownMenu_AddButton", "UIDropDownMenu_CreateInfo",
	"UIDropDownMenu_Initialize", "UIDropDownMenu_SetSelectedValue",
	"UIDropDownMenu_SetText", "UIDropDownMenu_SetWidth",
	"UIParent", "UISpecialFrames",
	"UnitAffectingCombat", "UnitClassFromGUID", "UnitExists", "UnitIsPlayer",
	"UnitNameFromGUID", "UnitTokenFromGUID",
	"debugprofilestop", "format", "geterrorhandler", "hasanysecretvalues",
	"hooksecurefunc", "issecrettable", "issecretvalue",
	"time", "tinsert", "wipe",
}

-- The ONE exception: secrets.lua is the wrapper layer, so it is allowed to
-- call the six secret-prone APIs raw. Nothing else may.
files["secrets.lua"].read_globals = {
	"UnitGUID",
	"UnitName",
	"GetUnitName",
	"UnitFullName",
	"UnitIsUnit",
	"InCombatLockdown",
}
