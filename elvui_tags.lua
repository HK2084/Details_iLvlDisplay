-- Details! Item Level Display — Copyright (c) 2026 HK2084. All rights reserved.
-- Licensed for private use only; see LICENSE. No redistribution of modified copies.
-- elvui_tags.lua — optional ElvUI party frame integration
-- Registers two custom ElvUI tags that show iLvl (and set bonus)
-- in ElvUI unit frames (party, raid, player, etc.):
--   [dilvl]       — iLvl wrapped in square brackets, e.g. "[284]"
--   [dilvl:plain] — bare iLvl number, e.g. "284"
--
-- SAFE TO LOAD WITHOUT ELVUI: if ElvUI is not installed this file
-- does nothing — no errors, no prints, no performance cost.
--
-- USAGE (after enabling via /dilvl elvui):
--   In ElvUI → Unit Frames → Party/Raid/Player → Name text, add one of:
--     [name] [dilvl]        → "Raza [284]"
--     [name] [dilvl:plain]  → "Raza 284"
--
-- TOGGLE: /dilvl elvui on|off  (saved between sessions, gates BOTH tags)
--
-- UPDATE STRATEGY: event-driven, no polling timer.
-- core.lua fires registered callbacks after: INSPECT_READY, gear swap,
-- GROUP_ROSTER_UPDATE. Our callback calls Tags:RefreshMethods once per
-- tag name (it takes exactly one), re-rendering every visible frame
-- using that tag. During 3h farming with no group changes: zero extra
-- calls — and none at all while the feature is switched off.

local _, ns = ...   -- addon namespace; only ns.L is used here

if not ElvUI then return end -- no ElvUI installed → silent exit

local E = unpack(ElvUI)
if not E then return end

local API = Details_iLvlDisplayAPI
if not API then return end -- core.lua didn't load (shouldn't happen)

---------------------------------------------------------------
-- Shared tag body — pure cache lookup, no API calls. Both tag
-- variants delegate here so color/setbonus/master-toggle behaviour
-- stays identical; only the iLvl wrapping differs.
---------------------------------------------------------------
-- Returns nil, never "", when there is nothing to show.
--
-- oUF only suppresses a tag's literals on a NIL return: CreateTagFunc reads
-- `return str and format('%s%s%s', prefix, str, suffix) or nil`
-- (oUF/elements/tags.lua:707), and "" is truthy in Lua. So an empty string
-- still prints the literals — a user writing [dilvl<ilvl] would read
-- "Raza ilvl" with no number on every uninspected frame, forever, with no
-- error. The oUF docs promise the opposite: literals "will be only displayed
-- when the function returns a non-nil value".
local function buildIlvl(unit, withBrackets)
    local db = API.GetDb()
    -- db.enabled is the addon-wide master switch. It used to be missing here,
    -- so /dilvl off silenced every other channel and left the ElvUI number
    -- standing on the frames.
    if not db or not db.enabled or not db.elvuiTag then return nil end

    local guid = API.SafeUnitGUID(unit)  -- secret-safe: nil (not a throw) inside instances
    if not guid then return nil end

    local cached, setBonus = API.GetCacheData(guid)
    if not cached or not cached.ilvl then return nil end

    local num = cached.ilvl
    local body = withBrackets and ("[" .. num .. "]") or tostring(num)

    local tag
    if db.colorIlvl then
        tag = API.GetIlvlColor(num) .. body .. "|r"
    else
        tag = body
    end

    if db.showSetBonus then
        local sbTag = API.SetBonusTag(setBonus)
        if sbTag then tag = tag .. " " .. sbTag end
    end

    return tag
end

E:AddTag("dilvl", "UNIT_INVENTORY_CHANGED", function(unit)
    return buildIlvl(unit, true)
end)

E:AddTag("dilvl:plain", "UNIT_INVENTORY_CHANGED", function(unit)
    return buildIlvl(unit, false)
end)

-- Tag-browser text goes through the locale table like the rest of the UI.
-- These run at FILE SCOPE, which is why locales load ahead of this file in
-- the TOC; ns.L must already exist here. The identity fallback in enUS.lua
-- means a missing key degrades to the key, never to nil.
local L = ns.L

E:AddTagInfo("dilvl", L["Details! iLvl Display"], L["ELVUI_TAG_DILVL_D"])
E:AddTagInfo("dilvl:plain", L["Details! iLvl Display"], L["ELVUI_TAG_PLAIN_D"])

---------------------------------------------------------------
-- Register callback: core.lua fires all registered callbacks
-- whenever cached iLvl data changes. We respond by calling
-- RefreshMethods, the official oUF API for forcing a tag
-- re-evaluation, which re-renders every visible frame using
-- that tag.
--
-- ONE tag per call: oUF's RefreshMethods takes a single named
-- parameter and no vararg (oUF/elements/tags.lua:1070), so the
-- second tag name we used to pass was silently dropped and
-- [dilvl:plain] never refreshed. Its pattern is built as a
-- literal '%[dilvl%]' too, which would not match [dilvl:plain]
-- even if the argument had arrived.
--
-- The whole call sits INSIDE the pcall closure, not as pcall
-- arguments: Lua evaluates arguments first, so the old form
-- dereferenced E.oUF.Tags outside the protection and threw for
-- real whenever ElvUI's oUF was momentarily nil (profile switch,
-- ElvUI update) — five of those and core.lua unregistered us.
---------------------------------------------------------------

-- Latch so we still run once on the ON -> OFF transition. Returning
-- early whenever the tag is off would leave stale "[284]" text on the
-- frames after /dilvl elvui off.
local lastEnabled = false

API:RegisterCallback("elvui", function()
    local db = API.GetDb()
    local on = (db and db.elvuiTag) and true or false
    -- Default is elvuiTag = false, i.e. the normal state for every ElvUI
    -- user who never enabled this. RefreshMethods is not cheap: it walks
    -- bracketFuncs and tagStringFuncs, gsubs twice per entry and forces a
    -- recompile across every tagged FontString in the UI. A post-kill sweep
    -- fires ~25 INSPECT_READY in ~12s, so this used to burn real time for
    -- people who never turned the feature on.
    if not on and not lastEnabled then return end
    lastEnabled = on

    pcall(function()
        E.oUF.Tags:RefreshMethods("dilvl")
        E.oUF.Tags:RefreshMethods("dilvl:plain")
    end)
end)
