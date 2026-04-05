-- blizzdm.lua — Blizzard Damage Meter iLvl overlay
-- Shows iLvl (and tier set bonus) next to player names on WoW's built-in
-- damage meter (Blizzard_DamageMeter, added in 12.0).
--
-- SAFE TO LOAD WITHOUT BLIZZARD DM: if the Mixin doesn't exist (Classic,
-- or Blizzard removes/renames it in a future patch) this file does nothing.
--
-- DESIGN: defensive against future Blizzard DM changes.
--   - Hooks UpdateName to inject iLvl after Blizzard sets clean text
--   - Listens for DAMAGE_METER_COMBAT_SESSION_UPDATED to refresh
--   - Uses DamageMeter:ForEachSessionWindow to iterate visible frames
--   - READ-ONLY: never modifies Blizzard frame fields (nameText etc.)
--   - Never calls frame:UpdateName() — avoids taint + stack overflow
--   - Never calls C_DamageMeter APIs directly
--   - Overlay FontString when native is locked by secret text
--   - issecretvalue/issecrettable guards before any field read
--   - If any global is missing → silent exit, no errors
--
-- TOGGLE: /dilvl blizzdm  (saved between sessions, default ON)

-- Guard: Blizzard_DamageMeter must be loaded
if not DamageMeterEntryMixin then return end
if not DamageMeter then return end

local API = Details_iLvlDisplayAPI
if not API then return end

---------------------------------------------------------------
-- Secret value guards (mirrors core.lua pattern from Issue #2)
---------------------------------------------------------------
local _issecretvalue = issecretvalue or function() return false end
local _issecrettable = issecrettable or function() return false end

local function isSecret(val)
    if _issecretvalue(val) then return true end
    if _issecrettable(val) then return true end
    return false
end

---------------------------------------------------------------
-- Combat state tracking.
-- We skip injection entirely when ANYONE in the group is in combat,
-- not just the player. Blizzard's Secret Value system locks down
-- sourceName, nameText, and FontString content (ConditionalSecret)
-- for the entire group during combat. Reading these fields risks
-- getting secret values that break our display logic.
-- Blizzard is continuously tightening secret restrictions (April 2026:
-- UnitIsUnit hotfix, more expected). Safest approach: only inject
-- when the entire group is out of combat. We refresh on
-- PLAYER_REGEN_ENABLED + delayed passes for stale FontStrings.
---------------------------------------------------------------
local inCombat = false
local globalFontFile = nil    -- cached from first CLEAN frame: font file path
local globalFontSize = nil    -- cached from first CLEAN frame: font size (includes TextScale)
local globalFontFlags = nil   -- cached from first CLEAN frame: font flags ("OUTLINE" etc.)
do
    local icl = InCombatLockdown()
    -- InCombatLockdown() returns secret in instances (Issue #2).
    -- Only trust an explicit true; secret or false → assume out of combat.
    if icl == true then inCombat = true end
end

-- Check if ANY group member is in combat. Cached for 1s to avoid
-- scanning 25 units on every InjectIlvl call.
-- If UnitAffectingCombat ever returns secret (future Blizzard restriction),
-- we treat it as "in combat" (safe default).
local groupCombatTime = 0
local groupCombatResult = false
local function IsGroupInCombat()
    if inCombat then return true end
    if IsEncounterInProgress() then return true end
    local now = GetTime()
    if now - groupCombatTime < 1 then return groupCombatResult end
    groupCombatTime = now
    local count = GetNumGroupMembers()
    if count == 0 then groupCombatResult = false; return false end
    local prefix = IsInRaid() and "raid" or "party"
    for i = 1, count do
        local afc = UnitAffectingCombat(prefix .. i)
        if isSecret(afc) then groupCombatResult = true; return true end
        if afc == true then groupCombatResult = true; return true end
    end
    groupCombatResult = false
    return false
end

---------------------------------------------------------------
-- Build iLvl tag string from GUID (reuses core.lua API)
---------------------------------------------------------------
local function BuildTag(guid)
    local db = API.GetDb()
    if not db or not db.enabled then return nil end

    -- blizzDM: nil = auto (ON when Details! absent), true = forced ON, false = forced OFF
    if db.blizzDM == false then return nil end
    if db.blizzDM == nil and Details then return nil end

    local cached, setBonus = API.GetCacheData(guid)
    if not cached or not cached.ilvl then return nil end

    local tag
    if db.colorIlvl then
        tag = " " .. API.GetIlvlColor(cached.ilvl) .. "[" .. cached.ilvl .. "]|r"
    else
        tag = " [" .. cached.ilvl .. "]"
    end

    if db.showSetBonus and setBonus then
        tag = tag .. " |cFF00FF00[" .. setBonus .. "]|r"
    end

    return tag
end

---------------------------------------------------------------
-- Resolve GUID for a DamageMeter entry frame.
-- Reads self.* fields set by Blizzard's untainted code.
-- Strategy:
--   1. isLocalPlayer → UnitGUID("player")
--   2. _dilvlGUID captured from Init hook (not secret-annotated)
--   3. sourceName → roster lookup via Ambiguate (fallback)
-- Returns guid or nil.
---------------------------------------------------------------
local function ResolveFrameGUID(frame)
    -- isLocalPlayer is NeverSecret, set by Blizzard's Init
    if frame.isLocalPlayer == true then
        return UnitGUID("player")
    end

    -- Prefer GUID captured from Init (sourceGUID has no secret annotation)
    local cachedGUID = frame._dilvlGUID
    if cachedGUID and not isSecret(cachedGUID) then
        return cachedGUID
    end

    -- Fallback: sourceName roster lookup (ConditionalSecret during combat)
    local name = frame.sourceName
    if not name or isSecret(name) then return nil end

    return API.ResolveGUIDByName(name)
end

---------------------------------------------------------------
-- Hook: DamageMeterSourceEntryMixin:Init()
-- Captures sourceGUID from combatSource before secrets lock it.
-- sourceGUID has no Secret annotation in the Blizzard API docs
-- (unlike sourceName which is ConditionalSecret).
---------------------------------------------------------------
if DamageMeterSourceEntryMixin then
    hooksecurefunc(DamageMeterSourceEntryMixin, "Init", function(self, combatSource)
        if not combatSource or isSecret(combatSource) then return end
        local guid = combatSource.sourceGUID
        if guid and not isSecret(guid) then
            self._dilvlGUID = guid
        end
    end)
end

---------------------------------------------------------------
-- Restore Blizzard's native Name FontString after SetToDefaults.
-- Re-applies layout from DamageMeterEntry.lua SetupDefaultStyle.
---------------------------------------------------------------
local function RestoreNameFS(frame, nameFS)
    local statusBar = frame.StatusBar
    if statusBar then
        nameFS:SetPoint("LEFT", statusBar, "LEFT", 5, 0)
        local valueFS = frame.GetValue and frame:GetValue()
        if valueFS and not isSecret(valueFS) then
            nameFS:SetPoint("RIGHT", valueFS, "LEFT", -25, 0)
        else
            nameFS:SetPoint("RIGHT", statusBar, "RIGHT", -40, 0)
        end
    end
    nameFS:SetDrawLayer("OVERLAY", 7)  -- above bar fill texture
    nameFS:SetJustifyH("LEFT")
    nameFS:SetJustifyV("MIDDLE")
    -- ALWAYS set a font — SetToDefaults clears it, "Font not set" error otherwise.
    -- Use GetFont() cache (file, size, flags) for pixel-perfect restore.
    -- Priority: per-frame cache > global cache > NumberFontNormal fallback.
    if frame._dilvlFontFile then
        nameFS:SetFont(frame._dilvlFontFile, frame._dilvlFontSize, frame._dilvlFontFlags)
    elseif globalFontFile then
        nameFS:SetFont(globalFontFile, globalFontSize, globalFontFlags)
    else
        nameFS:SetFontObject(NumberFontNormal)
    end
    nameFS:SetWordWrap(false)  -- XML default, SetToDefaults resets to true → text wraps & squishes bars
    nameFS:SetAlpha(1)
end

---------------------------------------------------------------
-- Clear secret text aspect from a FontString.
-- Prefers ClearAspect (surgical, keeps font/anchoring) over
-- SetToDefaults (nuclear, resets everything).
-- Returns true if aspect was cleared.
---------------------------------------------------------------
local function ClearSecretText(frame, nameFS)
    -- Try surgical clear first (Blizzard internal API, may exist)
    if nameFS.ClearAspect and Enum and Enum.SecretAspect then
        local ok = pcall(nameFS.ClearAspect, nameFS, Enum.SecretAspect.Text)
        if ok then return true end
    end
    -- Fallback: nuclear SetToDefaults + full restore
    nameFS:SetToDefaults()
    RestoreNameFS(frame, nameFS)
    return true
end

---------------------------------------------------------------
-- Clear overlay + fix stale-secret FontStrings.
-- If the native FontString holds secret text and we're out of
-- combat, SetToDefaults() clears the secret aspect so Blizzard's
-- own text becomes visible again (even without our iLvl tag).
---------------------------------------------------------------
local function ClearOverlay(frame)
    if frame._dilvlNameFS then
        frame._dilvlNameFS:Hide()
    end
    local nameFS = frame:GetName()
    if not nameFS or type(nameFS) == "string" then return end
    nameFS:SetAlpha(1)

    -- Safeguard: clear stale secret/nil text when not in combat.
    -- Only attempt SetToDefaults if we can actually restore the text afterwards.
    -- NO-GUID frames without cache have no restore path → leave them alone.
    if not IsGroupInCombat() then
        local fsTxt = nameFS:GetText()
        if not fsTxt or isSecret(fsTxt) then
            -- Check if we have ANY text to restore before nuking with SetToDefaults
            local restoreText
            local blizzText = frame.GetNameText and frame:GetNameText()
            if blizzText and not isSecret(blizzText) then
                restoreText = blizzText
            else
                local guid = ResolveFrameGUID(frame)
                if guid then
                    local cached = API.GetCacheData(guid)
                    if cached and cached.name and not isSecret(cached.name) then
                        restoreText = Ambiguate(cached.name, "short")
                    end
                end
            end
            -- Only clear secret if we have text to put back
            if restoreText then
                ClearSecretText(frame, nameFS)
                nameFS:SetText(restoreText)
            end
            -- else: leave the FontString as-is, Blizzard will fix it on next UpdateName
        end
    end
end

---------------------------------------------------------------
-- Inject iLvl into a single entry frame's Name FontString.
-- READ-ONLY: never modifies Blizzard frame fields (nameText,
-- sourceName) or calls frame:UpdateName().
--
-- When nameText is clean: SetText on native FontString (fast).
-- When nameText is secret: native FontString is "locked" by
-- the secret value — addon SetText is silently ignored.
-- In that case we create a thin overlay FontString that we own,
-- hide the native text (SetAlpha 0), and display there instead.
---------------------------------------------------------------
local function InjectIlvl(frame)
    -- Skip when ANY group member is in combat — not just us.
    -- Blizzard's Secret Value system locks ALL name fields group-wide.
    -- IsGroupInCombat checks: our inCombat flag, IsEncounterInProgress(),
    -- and UnitAffectingCombat on all group members (cached 1s).
    -- If any check returns secret → assume combat (future-safe).
    if IsGroupInCombat() then ClearOverlay(frame) return end

    local guid = ResolveFrameGUID(frame)
    if not guid then ClearOverlay(frame) return end

    local tag = BuildTag(guid)
    if not tag then ClearOverlay(frame) return end

    -- GetName() returns the StatusBar.Name FontString.
    local nameFS = frame:GetName()
    if not nameFS then ClearOverlay(frame) return end

    -- Resolve base display name from best available source.
    -- Priority: nameText (Blizzard's display) > sourceName > player name > cache name.
    -- Post-combat, FontStrings can stay stale-secret even though InCombat is false
    -- (Blizzard only refreshes nameText on the NEXT UpdateName call, which may not
    -- happen between pulls). Cache-name fallback handles this reliably because
    -- we captured the name during inspect when it was still readable.
    local baseName
    -- Priority 1: Blizzard's formatted text with rank prefix ("1. Quinroth")
    local nameText = frame.nameText
    if nameText and not isSecret(nameText) then
        baseName = nameText
    else
        -- Priority 2: GetNameText() — formatted with rank, readable post-combat
        local fmtText = frame.GetNameText and frame:GetNameText()
        if fmtText and not isSecret(fmtText) then
            baseName = fmtText
        else
            -- Priority 3: sourceName / player name / cache name (no rank prefix)
            local name = frame.sourceName
            if not name or isSecret(name) then
                if frame.isLocalPlayer == true then
                    name = UnitName("player")
                end
            end
            if not name or isSecret(name) then
                local cached = API.GetCacheData(guid)
                if cached and cached.name and not isSecret(cached.name) then
                    name = Ambiguate(cached.name, "short")
                end
            end
            if not name or isSecret(name) then ClearOverlay(frame) return end
            baseName = name
        end
    end

    local displayText = baseName .. tag

    -- Cache actual font properties from native FontString while readable.
    -- GetFont() returns the rendered font (file, size, flags) regardless of how it was set.
    -- This captures Blizzard's runtime SetTextScale effect on fontSize.
    local fontFile, fontSize, fontFlags = nameFS:GetFont()
    if fontFile and not isSecret(fontFile) and fontSize and not isSecret(fontSize) then
        frame._dilvlFontFile = fontFile
        frame._dilvlFontSize = fontSize
        frame._dilvlFontFlags = fontFlags or ""
        if not globalFontFile then
            globalFontFile = fontFile
            globalFontSize = fontSize
            globalFontFlags = fontFlags or ""
        end
    end

    -- Write-first: try SetText directly (works when FontString is clean).
    nameFS:SetText(displayText)
    nameFS:SetAlpha(1)
    if frame._dilvlNameFS then frame._dilvlNameFS:Hide() end

    local fsTxt = nameFS:GetText()
    if fsTxt and not isSecret(fsTxt) then
        -- Ensure native properties are intact (SetToDefaults from a previous
        -- session may have left wrong font/wordwrap that persists across /reload).
        nameFS:SetWordWrap(false)
        if frame._dilvlFontFile then
            nameFS:SetFont(frame._dilvlFontFile, frame._dilvlFontSize, frame._dilvlFontFlags)
        elseif globalFontFile then
            nameFS:SetFont(globalFontFile, globalFontSize, globalFontFlags)
        end
        return  -- Clean path: SetText succeeded
    end

    -- FontString holds sticky secret aspect (persists after combat).
    -- ClearAspect(Text) if available (surgical), else SetToDefaults (nuclear).
    -- Runs ONCE per combat transition, not every frame.
    ClearSecretText(frame, nameFS)

    -- NOW SetText works — secret aspect is cleared
    nameFS:SetText(displayText)
end

---------------------------------------------------------------
-- Refresh all visible DamageMeter entry frames.
-- Uses DamageMeter:ForEachSessionWindow → ForEachEntryFrame
-- (official Blizzard iteration API, same pattern ElvUI uses).
---------------------------------------------------------------
local function RefreshAllFrames()
    local db = API.GetDb()
    if not db or not db.enabled then return end
    if db.blizzDM == false then return end
    if db.blizzDM == nil and Details then return end

    if not DamageMeter.ForEachSessionWindow then return end

    DamageMeter:ForEachSessionWindow(function(sessionWindow)
        if not sessionWindow.ForEachEntryFrame then return end
        sessionWindow:ForEachEntryFrame(function(frame)
            InjectIlvl(frame)
        end)
    end)
end

---------------------------------------------------------------
-- Hook: DamageMeterEntryMixin:UpdateName()
-- Fires EVERY time Blizzard sets/resets bar name text (on
-- combat update, session switch, style change, etc.).
-- This is the primary injection point — much more reliable
-- than Init which only fires on ScrollBox frame creation.
---------------------------------------------------------------
hooksecurefunc(DamageMeterEntryMixin, "UpdateName", function(self)
    -- Capture GUID from sourceName when readable (OOC).
    -- Init hook misses ScrollBox-recycled frames, this catches them.
    if not self._dilvlGUID or isSecret(self._dilvlGUID) then
        local name = self.sourceName
        if name and not isSecret(name) then
            local guid = API.ResolveGUIDByName(name)
            if guid then self._dilvlGUID = guid end
        end
    end
    InjectIlvl(self)
end)

---------------------------------------------------------------
-- Event listener: refresh when Blizzard DM data changes.
-- DAMAGE_METER_COMBAT_SESSION_UPDATED fires after each combat
-- update. We delay by 1 frame so Blizzard finishes its Refresh
-- first, then we inject on top.
--
-- Combat safeguards — layered defense against Secret Values:
--   PLAYER_REGEN_DISABLED/ENABLED — own combat state
--   UNIT_FLAGS — instant detection when ANY group member enters/leaves combat
--   ENCOUNTER_START/END — precise boss encounter boundaries
--   INSTANCE_ENCOUNTER_ENGAGE_UNIT — earliest boss detection (frame appears)
--   LOADING_SCREEN_DISABLED — safe moment after zone transitions
--   PLAYER_ENTERING_WORLD — login, reload, instance port
-- Future-safe: if any of these start returning secrets, IsGroupInCombat()
-- treats unknown/secret values as "in combat" (safe default).
---------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
-- Blizzard DM data events
eventFrame:RegisterEvent("DAMAGE_METER_COMBAT_SESSION_UPDATED")
eventFrame:RegisterEvent("DAMAGE_METER_CURRENT_SESSION_UPDATED")
eventFrame:RegisterEvent("DAMAGE_METER_RESET")
-- Combat state tracking (own)
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
-- Group combat detection (instant, fires per-unit)
eventFrame:RegisterEvent("UNIT_FLAGS")
-- Boss encounter boundaries (precise start/end)
eventFrame:RegisterEvent("ENCOUNTER_START")
eventFrame:RegisterEvent("ENCOUNTER_END")
-- Earliest boss detection (boss frame appears before ENCOUNTER_START)
eventFrame:RegisterEvent("INSTANCE_ENCOUNTER_ENGAGE_UNIT")
-- Group changes
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
-- Blizzard DM's own combat signal (synchronous, 12.0+)
eventFrame:RegisterEvent("PLAYER_IN_COMBAT_CHANGED")
-- Safe refresh moments after transitions
eventFrame:RegisterEvent("LOADING_SCREEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

local pendingRefresh = false
local function ScheduleRefresh()
    if not pendingRefresh then
        pendingRefresh = true
        C_Timer.After(0, function()
            pendingRefresh = false
            RefreshAllFrames()
        end)
    end
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
    -- === Combat START signals — clear overlays immediately ===
    if event == "PLAYER_REGEN_DISABLED" then
        inCombat = true
        groupCombatTime = 0 -- force recheck on next IsGroupInCombat()
        RefreshAllFrames()  -- ClearOverlay on all frames
        return
    end
    if event == "PLAYER_IN_COMBAT_CHANGED" then
        -- Blizzard DM's own synchronous combat signal (12.0+).
        -- Payload: inCombat (bool). Fires same frame as state change.
        local combatState = ...
        if combatState == true or isSecret(combatState) then
            inCombat = true
            groupCombatTime = 0
            RefreshAllFrames()
        else
            inCombat = false
            groupCombatTime = 0
            ScheduleRefresh()
        end
        return
    end
    if event == "ENCOUNTER_START" or event == "INSTANCE_ENCOUNTER_ENGAGE_UNIT" then
        -- Boss detected — force combat state even if REGEN hasn't fired yet
        groupCombatTime = 0
        RefreshAllFrames()
        return
    end
    if event == "UNIT_FLAGS" then
        -- A unit's combat state changed. Invalidate cache so
        -- IsGroupInCombat() re-scans on next InjectIlvl call.
        groupCombatTime = 0
        -- If someone just entered combat, clear overlays immediately.
        -- If someone left combat, schedule a refresh (might be safe to inject).
        local unit = ...
        if unit then
            local afc = UnitAffectingCombat(unit)
            if afc == true or isSecret(afc) then
                RefreshAllFrames()
                return
            end
        end
        ScheduleRefresh()
        return
    end

    -- === Combat END signals — safe to inject again ===
    if event == "PLAYER_REGEN_ENABLED" then
        inCombat = false
        groupCombatTime = 0
        ScheduleRefresh()
        return
    end
    if event == "ENCOUNTER_END" then
        -- Boss killed or wiped — names become readable soon.
        -- Delay slightly: Blizzard unlocks secrets after this event.
        groupCombatTime = 0
        ScheduleRefresh()
        return
    end

    -- === Transition events — clean slate, safe to refresh ===
    if event == "LOADING_SCREEN_DISABLED" or event == "PLAYER_ENTERING_WORLD" then
        inCombat = false
        groupCombatTime = 0
        ScheduleRefresh()
        return
    end

    -- === Data events — standard refresh ===
    ScheduleRefresh()
end)

-- Register with core.lua's callback system (inspect complete, gear swap, etc.)
API:RegisterCallback("blizzdm", RefreshAllFrames)

-- Hook DM window visibility + session changes.
-- Close/reopen and session switching (Heal→DPS, Aktuell→Gesamt) don't always
-- trigger UpdateName, so our hook misses the re-injection.
if DamageMeter.ForEachSessionWindow then
    -- Main DM frame show/hide
    if DamageMeter.SetShown then
        hooksecurefunc(DamageMeter, "SetShown", function() ScheduleRefresh() end)
    end
    -- Per-window: Show, Refresh, session type changes
    DamageMeter:ForEachSessionWindow(function(sessionWindow)
        if sessionWindow.Show then
            hooksecurefunc(sessionWindow, "Show", function() ScheduleRefresh() end)
        end
        if sessionWindow.Refresh then
            hooksecurefunc(sessionWindow, "Refresh", function() ScheduleRefresh() end)
        end
    end)
end

---------------------------------------------------------------
-- Debug diagnostics — called by core.lua's /dilvl debug
-- Returns: windows, frames, hasGuid, hasTag, secretName, entries[], combatInfo
-- combatInfo = { groupCombat, inCombat, encounter, unitFlags }
---------------------------------------------------------------
API.GetBlizzDMDebug = function()
    local windows, frames, hasGuid, hasTag, secretName = 0, 0, 0, 0, 0
    local entries = {}

    -- Detailed combat state for debug output
    local eip = IsEncounterInProgress()
    local unitFlagsCombat = false
    local count = GetNumGroupMembers()
    if count > 0 then
        local prefix = IsInRaid() and "raid" or "party"
        for i = 1, count do
            local afc = UnitAffectingCombat(prefix .. i)
            if afc == true or isSecret(afc) then
                unitFlagsCombat = true
                break
            end
        end
    end
    local combatInfo = {
        groupCombat = IsGroupInCombat(),
        inCombat = inCombat,
        encounter = eip == true,
        encounterSecret = eip and isSecret(eip),
        unitFlags = unitFlagsCombat,
        members = count,
    }

    if not DamageMeter.ForEachSessionWindow then
        return 0, 0, 0, 0, 0, entries, combatInfo
    end

    DamageMeter:ForEachSessionWindow(function(sessionWindow)
        if not sessionWindow:IsShown() then return end
        if not sessionWindow.ForEachEntryFrame then return end
        windows = windows + 1
        sessionWindow:ForEachEntryFrame(function(frame)
            frames = frames + 1

            local name = frame.sourceName
            local nameSecret = name and isSecret(name)
            local displayName = nameSecret and "(secret)" or tostring(name or "nil")
            local isLocal = frame.isLocalPlayer == true
            local guid = ResolveFrameGUID(frame)
            local hasCached = false
            local cacheName = nil
            if guid then
                hasGuid = hasGuid + 1
                local cached = API.GetCacheData(guid)
                hasCached = cached and cached.ilvl ~= nil
                if cached and cached.name then
                    cacheName = tostring(cached.name)
                end
            end

            local tagged = false
            local txtSecret = false
            local alphaHidden = false
            local hasOverlay = false
            local nativeTxt = nil
            local ovrTxt = nil
            local nameFS = frame:GetName()
            local nameFSType = nameFS and type(nameFS) or "nil"
            if nameFS and type(nameFS) ~= "string" then
                -- Safety net: detect invisible native FontString
                local alpha = nameFS:GetAlpha()
                if alpha and not isSecret(alpha) and alpha < 0.5 then
                    alphaHidden = true
                end
                local txt = nameFS:GetText()
                if txt and not isSecret(txt) then
                    nativeTxt = tostring(txt):sub(1, 30)
                    if type(txt) == "string" and txt:find("%[%d+%]") then
                        tagged = true
                        hasTag = hasTag + 1
                    end
                elseif txt and isSecret(txt) then
                    nativeTxt = "(secret)"
                    txtSecret = true
                    secretName = secretName + 1
                else
                    nativeTxt = "(nil)"
                end
            elseif nameFS and type(nameFS) == "string" then
                -- GetName() returned a string (frame name), not a FontString!
                nativeTxt = "STR:" .. nameFS:sub(1, 20)
            end
            -- Also check overlay FontString
            if frame._dilvlNameFS then
                local otxt = frame._dilvlNameFS:GetText()
                local ovr = frame._dilvlNameFS
                local ovrW = ovr:GetWidth() or 0
                local ovrH = ovr:GetHeight() or 0
                local ovrA = ovr:GetAlpha() or 0
                -- Guard against secret contamination from anchoring
                if isSecret(ovrW) then ovrW = -1 end
                if isSecret(ovrH) then ovrH = -1 end
                if isSecret(ovrA) then ovrA = -1 end
                local ovrFont = "?"
                local ovrFontObj = ovr:GetFontObject()
                if ovrFontObj and not isSecret(ovrFontObj) then
                    ovrFont = tostring(ovrFontObj:GetName() or ovrFontObj)
                elseif ovrFontObj and isSecret(ovrFontObj) then
                    ovrFont = "SECRET"
                else
                    ovrFont = "nil"
                end
                -- Also check native FontString dimensions for comparison
                local nativeW = nameFS and type(nameFS) ~= "string" and nameFS:GetWidth() or 0
                local nativeH = nameFS and type(nameFS) ~= "string" and nameFS:GetHeight() or 0
                if isSecret(nativeW) then nativeW = -1 end
                if isSecret(nativeH) then nativeH = -1 end
                local ovrShown = ovr:IsShown()
                if isSecret(ovrShown) then ovrShown = false end
                if ovrShown then
                    hasOverlay = true
                    local otxtStr = "(nil)"
                    if otxt and not isSecret(otxt) then otxtStr = tostring(otxt):sub(1, 25)
                    elseif otxt and isSecret(otxt) then otxtStr = "(secret)" end
                    ovrTxt = string.format("%s  dim:%.0fx%.0f(n:%.0fx%.0f) a:%.1f font:%s",
                        otxtStr, ovrW, ovrH, nativeW, nativeH, ovrA, ovrFont)
                else
                    local otxtHid = "nil"
                    if otxt and not isSecret(otxt) then otxtHid = tostring(otxt):sub(1, 20)
                    elseif otxt and isSecret(otxt) then otxtHid = "(secret)" end
                    ovrTxt = "HIDDEN:" .. otxtHid
                end
                if not tagged and otxt and type(otxt) == "string" and otxt:find("%[%d+%]") then
                    tagged = true
                    hasTag = hasTag + 1
                    if txtSecret then
                        secretName = secretName - 1
                        txtSecret = false
                    end
                end
            end

            -- Determine what path InjectIlvl would take
            local path = "?"
            if IsGroupInCombat() then
                path = "COMBAT-SKIP"
            elseif not guid then
                path = "NO-GUID"
            elseif not API.GetCacheData(guid) or not API.GetCacheData(guid).ilvl then
                path = "NO-CACHE"
            else
                local nt = frame.nameText
                if nt and not isSecret(nt) then
                    path = "CLEAN"
                else
                    local sn = frame.sourceName
                    local resolved = false
                    if sn and not isSecret(sn) then
                        resolved = true
                    elseif isLocal then
                        resolved = true
                    elseif cacheName then
                        resolved = true
                        path = "CACHE-NAME"
                    end
                    if resolved and path ~= "CACHE-NAME" then
                        -- Check FontString path
                        if nameFS and type(nameFS) ~= "string" then
                            local ft = nameFS:GetText()
                            if ft and not isSecret(ft) then
                                path = "CLEAN-FS"
                            else
                                path = "OVERLAY"
                            end
                        else
                            path = "NO-FS"
                        end
                    elseif not resolved then
                        path = "NO-NAME"
                    end
                end
            end

            entries[#entries + 1] = {
                name = displayName,
                isLocal = isLocal,
                guid = guid ~= nil,
                cached = hasCached,
                tagged = tagged,
                secret = txtSecret,
                alphaHidden = alphaHidden,
                overlay = hasOverlay,
                nativeTxt = nativeTxt,
                ovrTxt = ovrTxt,
                cacheName = cacheName,
                path = path,
                nameFSType = nameFSType,
            }
        end)
    end)
    return windows, frames, hasGuid, hasTag, secretName, entries, combatInfo
end
