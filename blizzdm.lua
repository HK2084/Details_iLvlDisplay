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
local _hasanysecretvalues = hasanysecretvalues or function() return false end

local function isSecret(val)
    if _issecretvalue(val) then return true end
    if _issecrettable(val) then return true end
    return false
end

---------------------------------------------------------------
-- Local fault isolation (mirrors danders_integration.lua pattern).
-- Counter resets on /reload (non-persistent). disableSelf flips
-- db.blizzDM = false (NOT db.enabled — master switch stays user-owned)
-- and routes a one-shot message via geterrorhandler() (BugSack picks
-- it up). Other integrations are unaffected.
---------------------------------------------------------------
local BLIZZDM_ERROR_LIMIT = 5
local blizzDMState = { errors = 0, lastError = nil, disabled = false }

local function disableBlizzDMSelf(reason)
    if blizzDMState.disabled then return end
    blizzDMState.disabled = true
    local db = API.GetDb()
    if db then db.blizzDM = false end
    pcall(geterrorhandler(),
        "Details! iLvl Display: Blizzard DM integration auto-disabled after "
        .. BLIZZDM_ERROR_LIMIT .. " errors. Last: " .. tostring(reason))
end

local function SafeBlizzCall(label, fn, ...)
    if blizzDMState.disabled then return nil end
    if blizzDMState.errors >= BLIZZDM_ERROR_LIMIT then return nil end
    local ok, a, b, c = pcall(fn, ...)
    if ok then return a, b, c end
    blizzDMState.errors = blizzDMState.errors + 1
    blizzDMState.lastError = ("[%s] %s"):format(label, tostring(a))
    if blizzDMState.errors >= BLIZZDM_ERROR_LIMIT then
        disableBlizzDMSelf(blizzDMState.lastError)
    end
    return nil
end

-- Public reset for /dilvl blizzdm (toggle on path) and debug section.
Details_iLvlDisplay_BlizzDMReset = function()
    blizzDMState.errors = 0
    blizzDMState.lastError = nil
    blizzDMState.disabled = false
end

Details_iLvlDisplay_BlizzDMState = function()
    return blizzDMState, BLIZZDM_ERROR_LIMIT
end

---------------------------------------------------------------
-- Event trace for post-combat debugging.
-- Toggle: /dilvl blizztrace
-- Logs combat→OOC event sequence + frame secret state.
---------------------------------------------------------------
local traceEnabled = false
local traceLog = {}
local MAX_TRACE = 200

local function trace(msg)
    if not traceEnabled then return end
    local t = GetTime()
    local entry = format("%.1f %s", t, msg)
    table.insert(traceLog, entry)
    if #traceLog > MAX_TRACE then table.remove(traceLog, 1) end
end

local function traceFrameState(tag, detailed)
    if not traceEnabled then return end
    if not DamageMeter or not DamageMeter.ForEachSessionWindow then return end
    local total, secret, tagged, noGuid = 0, 0, 0, 0
    local ok, err = pcall(function()
        DamageMeter:ForEachSessionWindow(function(sw)
            if not sw.ForEachEntryFrame then return end
            sw:ForEachEntryFrame(function(frame)
                total = total + 1
                if not frame._dilvlGUID then noGuid = noGuid + 1 end
                local nameFS = frame.GetName and frame:GetName()
                if not nameFS or type(nameFS) == "string" then return end
                local hasTxt, txt = pcall(nameFS.GetText, nameFS)
                if not hasTxt or not txt or isSecret(txt) then
                    secret = secret + 1
                else
                    if type(txt) == "string" and txt:find("%[%d+%]") then tagged = tagged + 1 end
                end
                -- Detailed per-frame log: what data is readable right now?
                if detailed then
                    local sn = frame.sourceName
                    local snS = (not sn and "nil") or (isSecret(sn) and "SEC") or tostring(sn):sub(1,15)
                    local nt = frame.nameText
                    local ntS = (not nt and "nil") or (isSecret(nt) and "SEC") or tostring(nt):sub(1,20)
                    local gnt = frame.GetNameText and frame:GetNameText()
                    local gntS = (not gnt and "nil") or (isSecret(gnt) and "SEC") or tostring(gnt):sub(1,20)
                    local lp = frame.isLocalPlayer == true and "YOU" or ""
                    local gd = frame._dilvlGUID and "GUID" or "noGUID"
                    trace(format("  [%d] sn=%s nt=%s gnt=%s %s %s",
                        total, snS, ntS, gntS, gd, lp))
                end
            end)
        end)
    end)
    if ok then
        trace(format("[%s] frames=%d secret=%d tagged=%d noGuid=%d",
            tag, total, secret, tagged, noGuid))
    else
        trace(format("[%s] ERROR: %s", tag, tostring(err)))
    end
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
local globalFontFile = nil     -- cached from first CLEAN frame: font file path
local globalFontSize = nil     -- cached from first CLEAN frame: font size
local globalFontFlags = nil    -- cached from first CLEAN frame: font flags ("OUTLINE" etc.)
local globalTextScale = nil    -- cached from first CLEAN frame: Blizzard's runtime text scale
do
    local icl = InCombatLockdown()
    -- InCombatLockdown() returns secret in instances (Issue #2).
    -- Only trust an explicit true; secret or false → assume out of combat.
    if icl == true then inCombat = true end
end

-- Combat guard: should we inject right now?
-- Only checks OUR combat state + boss encounter.
-- In LFR, someone in the 25-man raid is almost ALWAYS in combat
-- (tank pulls next trash before everyone is OOC). Scanning all
-- members with UnitAffectingCombat blocked us permanently.
-- Our own REGEN events + IsEncounterInProgress is sufficient:
-- secrets on OUR frames unlock when WE leave combat.
local function IsGroupInCombat()
    if inCombat then return true end
    local eip = IsEncounterInProgress()
    -- IsEncounterInProgress() can return secret in instances — treat as false
    if eip == true then return true end
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

    local isLeft = db.ilvlPosition == "left"
    local prefix = isLeft and "" or " "
    local tag
    if db.colorIlvl then
        tag = prefix .. API.GetIlvlColor(cached.ilvl) .. "[" .. cached.ilvl .. "]|r"
    else
        tag = prefix .. "[" .. cached.ilvl .. "]"
    end

    if db.showSetBonus and setBonus then
        tag = tag .. " |cFF00FF00[" .. setBonus .. "]|r"
    end

    return tag
end

---------------------------------------------------------------
-- Strip our iLvl/tier tags from a text string.
-- Used by StripAllTags (combat start) and ResolveFrameGUID
-- (parse nameText for roster lookup).
---------------------------------------------------------------
local function StripTagFromText(txt)
    if not txt or type(txt) ~= "string" then return txt end
    -- Strip colored iLvl tags: " |cFFxxxxxx[245]|r" or "|cFFxxxxxx[245]|r "
    -- Left-position places tag AFTER rank with trailing space, right-position
    -- places tag at end with leading space. Handle both with surrounding %s*.
    txt = txt:gsub("%s*|c%x%x%x%x%x%x%x%x%[%d+%]|r%s*", " ")
    -- Strip uncolored iLvl tags: " [245]" or "[245] "
    txt = txt:gsub("%s*%[%d+%]%s*", " ")
    -- Strip colored tier tags: " |cFF00FF00[2P]|r" / " |cFF00FF00[4P]|r"
    txt = txt:gsub("%s*|c%x%x%x%x%x%x%x%x%[%d[PT]%]|r%s*", " ")
    -- Collapse any double spaces and trim
    txt = txt:gsub("  +", " ")
    txt = txt:match("^%s*(.-)%s*$") or txt
    return txt
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

    local cachedGUID = frame._dilvlGUID
    local name = frame.sourceName
    local nameReadable = name and not isSecret(name)

    -- Validate cached GUID against current sourceName.
    -- ScrollBox recycles frames — cached GUID can belong to a different player.
    -- Ambiguate API resolves the authoritative GUID from the roster.
    if cachedGUID and not isSecret(cachedGUID) then
        if nameReadable then
            local freshGUID = API.ResolveGUIDByName(name)
            if freshGUID and freshGUID ~= cachedGUID then
                frame._dilvlGUID = freshGUID
                return freshGUID
            end
        end
        return cachedGUID
    end

    -- No cached GUID — resolve from sourceName
    if nameReadable then
        local guid = API.ResolveGUIDByName(name)
        if guid then frame._dilvlGUID = guid end
        return guid
    end

    -- Fallback 1: nameText field (no secret wrapper on field itself)
    local nt = frame.nameText
    if nt and not isSecret(nt) then
        local parsed = tostring(nt):match("^%d+%.%s*(.+)") or tostring(nt)
        parsed = StripTagFromText(parsed)
        parsed = parsed and parsed:match("^%s*(.-)%s*$")
        if parsed and parsed ~= "" then
            local guid = API.ResolveGUIDByName(parsed)
            if guid then
                frame._dilvlGUID = guid
                return guid
            end
        end
    end

    -- Fallback 2: read native FontString GetText() directly.
    -- Post-combat, sourceName and nameText may be secret but the rendered
    -- FontString often has the readable text (e.g. "1. Phaenthar-Silvermoon").
    local nameFS = frame.GetName and frame:GetName()
    if nameFS and type(nameFS) ~= "string" then
        local ok, txt = pcall(nameFS.GetText, nameFS)
        if ok and txt and not isSecret(txt) and type(txt) == "string" then
            local parsed = txt:match("^%d+%.%s*(.+)") or txt
            parsed = StripTagFromText(parsed)
            parsed = parsed and parsed:match("^%s*(.-)%s*$")
            if parsed and parsed ~= "" then
                -- Try full name first (e.g. "Phaenthar-Silvermoon")
                local guid = API.ResolveGUIDByName(parsed)
                if guid then
                    frame._dilvlGUID = guid
                    return guid
                end
                -- Fallback: FontString may truncate realm names (e.g. "Тобальд-Гордун"
                -- instead of "Тобальд-Гордунни"). Strip realm and try name-only.
                local nameOnly = parsed:match("^([^%-]+)")
                if nameOnly and nameOnly ~= parsed then
                    guid = API.ResolveGUIDByName(nameOnly)
                    if guid then
                        frame._dilvlGUID = guid
                        return guid
                    end
                end
            end
        end
    end

    -- All fallbacks exhausted — trace why
    if traceEnabled then
        local snS = (not name and "nil") or (isSecret(name) and "SEC") or "ok"
        local ntS = (not frame.nameText and "nil") or (isSecret(frame.nameText) and "SEC") or "ok"
        trace(format("ResolveGUID FAIL: sn=%s nt=%s cached=%s lp=%s",
            snS, ntS,
            cachedGUID and (isSecret(cachedGUID) and "SEC" or "ok") or "nil",
            tostring(frame.isLocalPlayer)))
    end
    return nil
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
    -- Restore TextScale — SetToDefaults resets to 1.0, Blizzard sets a runtime scale.
    if frame._dilvlTextScale then
        nameFS:SetTextScale(frame._dilvlTextScale)
    elseif globalTextScale then
        nameFS:SetTextScale(globalTextScale)
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
local function StripAllTags()
    if not DamageMeter or not DamageMeter.ForEachSessionWindow then return end
    trace("StripAllTags")
    DamageMeter:ForEachSessionWindow(function(sw)
        if not sw.ForEachEntryFrame then return end
        sw:ForEachEntryFrame(function(frame)
            if frame._dilvlNameFS then frame._dilvlNameFS:Hide() end
            local nameFS = frame.GetName and frame:GetName()
            if not nameFS or type(nameFS) == "string" then return end
            local ok, txt = pcall(nameFS.GetText, nameFS)
            if not ok or not txt or isSecret(txt) then return end
            local clean = StripTagFromText(txt)
            if clean ~= txt then
                nameFS:SetText(clean)
            end
        end)
    end)
    traceFrameState("StripAllTags_DONE")
end

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
                        restoreText = Ambiguate(cached.name, "none")
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
local MAX_RESOLVE_FAILS = 3  -- stop retrying after this many consecutive failures per player
local nameResolveFails = {}   -- sourceName → fail count (per-player, not per-frame)

-- When a GUID resolves on one frame, propagate it to ALL other visible frames
-- with the same sourceName. Fixes: left-position causes frame A to fail while
-- frame B (same player, different window) succeeds — without propagation,
-- frame A hits MAX_RESOLVE_FAILS and gives up permanently.
local function PropagateGUID(sourceName, guid)
    if not sourceName or not guid then return end
    if not DamageMeter or not DamageMeter.ForEachSessionWindow then return end
    DamageMeter:ForEachSessionWindow(function(sw)
        if not sw.ForEachEntryFrame then return end
        sw:ForEachEntryFrame(function(f)
            if f.sourceName and not isSecret(f.sourceName)
               and f.sourceName == sourceName and f._dilvlGUID ~= guid then
                local prev = f._dilvlGUID
                f._dilvlGUID = guid
                if traceEnabled then
                    trace(format("PropagateGUID: %s → frame (was %s)",
                        sourceName and tostring(sourceName):sub(1,15) or "?",
                        prev and "cached" or "nil"))
                end
            end
        end)
    end)
end

local function InjectIlvl(frame)
    -- Combat = we don't exist. Pure return, no writes, no ClearOverlay.
    -- StripAllTags already cleaned up on combat start.
    -- RefreshAllFrames will re-inject when everyone is OOC.
    if IsGroupInCombat() then return end

    -- Give-up: stop retrying PLAYERS that are permanently secret (e.g. Schadensklassen segment)
    -- Track by sourceName so ALL frames for the same player share one counter.
    local sn = frame.sourceName
    local snKey = sn and not isSecret(sn) and tostring(sn) or nil
    if snKey and nameResolveFails[snKey] and nameResolveFails[snKey] >= MAX_RESOLVE_FAILS then
        return
    end

    local guid = ResolveFrameGUID(frame)
    if not guid then
        -- Track consecutive failures per player name
        if snKey then
            nameResolveFails[snKey] = (nameResolveFails[snKey] or 0) + 1
            if nameResolveFails[snKey] >= MAX_RESOLVE_FAILS and traceEnabled then
                trace(format("InjectIlvl: giving up on player '%s' after %d resolve fails",
                    snKey:sub(1,15), MAX_RESOLVE_FAILS))
            end
        end
        ClearOverlay(frame) return
    end
    -- Reset fail counter on success + propagate GUID to sibling frames
    if snKey then
        nameResolveFails[snKey] = nil
        PropagateGUID(sn, guid)
    end

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
    local nameSource -- trace: which priority resolved the name
    -- Priority 1: Blizzard's formatted text with rank prefix ("1. Quinroth")
    local nameText = frame.nameText
    if nameText and not isSecret(nameText) then
        baseName = nameText
        nameSource = "nameText"
    else
        -- Priority 2: GetNameText() — formatted with rank, readable post-combat
        local fmtText = frame.GetNameText and frame:GetNameText()
        if fmtText and not isSecret(fmtText) then
            baseName = fmtText
            nameSource = "GetNameText"
        else
            -- Priority 3: sourceName / player name / cache name (no rank prefix)
            local name = frame.sourceName
            if not name or isSecret(name) then
                if frame.isLocalPlayer == true then
                    local pn = UnitName("player")
                    if pn and not isSecret(pn) then name = pn end
                    nameSource = name and "UnitName(player)" or nil
                end
            else
                nameSource = "sourceName"
            end
            if not name or isSecret(name) then
                local cached = API.GetCacheData(guid)
                if cached and cached.name and not isSecret(cached.name) then
                    name = Ambiguate(cached.name, "none")
                    nameSource = "cache"
                end
            end
            if not name or isSecret(name) then
                trace(format("InjectIlvl SKIP: no readable name for GUID %s (nameText=%s sn=%s)",
                    guid:sub(1,8) .. "..",
                    nameText and (isSecret(nameText) and "SEC" or "ok") or "nil",
                    frame.sourceName and (isSecret(frame.sourceName) and "SEC" or "ok") or "nil"))
                ClearOverlay(frame) return
            end
            baseName = name
        end
    end

    local displayText
    local db = API.GetDb()
    if db and db.ilvlPosition == "left" then
        -- Insert between rank prefix and name: "1. [272] Playername"
        local rank, rest = baseName:match("^(%d+%.%s*)(.*)")
        if rank then
            displayText = rank .. tag .. " " .. rest
        else
            displayText = tag .. " " .. baseName
        end
    else
        displayText = baseName .. tag
    end

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
    local textScale = nameFS:GetTextScale()
    if textScale and not isSecret(textScale) then
        frame._dilvlTextScale = textScale
        if not globalTextScale then globalTextScale = textScale end
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
        if frame._dilvlTextScale then
            nameFS:SetTextScale(frame._dilvlTextScale)
        elseif globalTextScale then
            nameFS:SetTextScale(globalTextScale)
        end
        -- Clean path: do NOT touch color — Blizzard's own SetTextColor is correct.
        -- We only restore color after ClearSecretText (clear path below).
        return  -- Clean path: SetText succeeded
    end

    -- FontString holds sticky secret aspect (persists after combat).
    -- ClearAspect(Text) if available (surgical), else SetToDefaults (nuclear).
    -- Runs ONCE per combat transition, not every frame.
    ClearSecretText(frame, nameFS)

    -- NOW SetText works — secret aspect is cleared
    nameFS:SetText(displayText)

    -- Clear path: ClearSecretText nuked the color, restore from cache.
    -- Use cached Blizzard color (captured in UpdateName hook when frame was clean).
    -- Do NOT use GetPlayerInfoByGUID — GUID mapping is unreliable in LFR.
    if frame._dilvlTextColor then
        pcall(nameFS.SetTextColor, nameFS, unpack(frame._dilvlTextColor))
        frame._dilvlColorSetByAddon = "cached"
        if traceEnabled then
            trace(format("InjectIlvl: restore cached color (clear path) for %s", baseName and baseName:sub(1, 20) or "?"))
        end
    else
        frame._dilvlColorSetByAddon = nil
        if traceEnabled then
            trace(format("InjectIlvl: NO cached color for %s — Blizz default", baseName and baseName:sub(1, 20) or "?"))
        end
    end
end

---------------------------------------------------------------
-- Refresh all visible DamageMeter entry frames.
-- Uses DamageMeter:ForEachSessionWindow → ForEachEntryFrame
-- (official Blizzard iteration API, same pattern ElvUI uses).
---------------------------------------------------------------
-- One-shot deferred retry flag: when RefreshAllFrames finds frames still
-- secret after combat ends (~0.5s unlock delay), it sets this flag so the
-- next UpdateName hook fires a full refresh. Event-driven, no timer (#19).
local deferredRetryPending = false

local function RefreshAllFrames()
    if blizzDMState.disabled then return end
    local db = API.GetDb()
    if not db or not db.enabled then return end
    if db.blizzDM == false then return end
    if db.blizzDM == nil and Details then return end

    -- Safety reset: if inCombat is stuck but we're clearly OOC, force-reset.
    -- Catches Delve/M+ edge cases where combat events fire in unexpected order.
    if inCombat then
        local icl = InCombatLockdown()
        local eip = IsEncounterInProgress()
        if icl ~= true and eip ~= true then
            inCombat = false
            trace("RefreshAllFrames: inCombat stuck, ICL+EIP both false → FORCE RESET")
        end
    end

    if not DamageMeter.ForEachSessionWindow then return end

    local hasRetriableSecret = false
    -- Wrapped iteration: a thrown error in Blizzard's iteration API or our
    -- InjectIlvl can't take down all remaining frames silently. SafeBlizzCall
    -- counts errors; after BLIZZDM_ERROR_LIMIT it auto-disables BlizzDM only
    -- (db.blizzDM = false), without touching db.enabled or other features.
    SafeBlizzCall("ForEachSessionWindow", DamageMeter.ForEachSessionWindow,
        DamageMeter, function(sessionWindow)
            if not sessionWindow.ForEachEntryFrame then return end
            SafeBlizzCall("ForEachEntryFrame", sessionWindow.ForEachEntryFrame,
                sessionWindow, function(frame)
                    SafeBlizzCall("InjectIlvl", InjectIlvl, frame)
                    if not hasRetriableSecret and frame.sourceName
                        and isSecret(frame.sourceName) then
                        hasRetriableSecret = true
                    end
                end)
        end)

    -- Only defer retry if there are frames that haven't given up yet
    if hasRetriableSecret and not IsGroupInCombat() then
        deferredRetryPending = true
        trace("RefreshAllFrames: frames still secret, deferred retry pending")
    elseif not hasRetriableSecret and deferredRetryPending then
        deferredRetryPending = false
        trace("RefreshAllFrames: all secret frames gave up, retry stopped")
    end
end

---------------------------------------------------------------
-- Hook: DamageMeterEntryMixin:UpdateName()
-- Fires EVERY time Blizzard sets/resets bar name text (on
-- combat update, session switch, style change, etc.).
-- This is the primary injection point — much more reliable
-- than Init which only fires on ScrollBox frame creation.
---------------------------------------------------------------
hooksecurefunc(DamageMeterEntryMixin, "UpdateName", function(self)
    -- Combat = we don't exist. No reads, no writes, no traces.
    -- Full group combat check (inCombat + IsEncounterInProgress + UnitAffectingCombat).
    if IsGroupInCombat() then return end

    -- Capture GUID from sourceName when readable (OOC).
    -- Init hook misses ScrollBox-recycled frames, this catches them.
    local name = self.sourceName
    if name and not isSecret(name) then
        local guid = API.ResolveGUIDByName(name)
        if guid then self._dilvlGUID = guid end
    end

    -- Cache class color from native FontString while readable (OOC).
    -- ClearSecretText resets color to default; we restore it in InjectIlvl.
    local nameFS = self.GetName and self:GetName()
    if nameFS and nameFS.GetTextColor then
        local ok, r, g, b, a = pcall(nameFS.GetTextColor, nameFS)
        if ok and r and not isSecret(r) and not isSecret(g) and not isSecret(b) then
            self._dilvlTextColor = {r, g, b, a or 1}
            if traceEnabled then
                trace(format("UpdateName: cached color r=%.2f g=%.2f b=%.2f for %s",
                    r, g, b, name and not isSecret(name) and tostring(name) or "?"))
            end
        end
    end

    -- Deferred retry: post-combat RefreshAllFrames found secret frames,
    -- now UpdateName fired (secrets unlocked ~0.5s later) → full refresh (#19)
    if deferredRetryPending and ScheduleRefresh then
        deferredRetryPending = false
        trace("UpdateName: deferred retry → RefreshAllFrames")
        ScheduleRefresh()
    end

    -- Trace: log when Blizzard calls UpdateName and what state the frame is in
    if traceEnabled then
        local nameFS = self.GetName and self:GetName()
        local txtOk, txt = nameFS and pcall(nameFS.GetText, nameFS)
        local display = (txtOk and txt and not isSecret(txt)) and tostring(txt):sub(1, 30) or "(secret)"
        trace(format("UpdateName [%s] nameText=%s",
            name and not isSecret(name) and tostring(name) or "?", display))
    end

    InjectIlvl(self)
end)

---------------------------------------------------------------
-- Event dispatch system (self-registering handlers).
-- RegisterHandler(event, fn) registers the event AND its handler
-- in one call — can't forget one without the other.
--
-- Combat safeguards — layered defense against Secret Values:
--   PLAYER_REGEN_DISABLED/ENABLED — own combat state
--   UNIT_FLAGS — registered, no-op (kept for future use)
--   ENCOUNTER_START/END — precise boss encounter boundaries
--   INSTANCE_ENCOUNTER_ENGAGE_UNIT — earliest boss detection (frame appears)
--   LOADING_SCREEN_DISABLED — safe moment after zone transitions
--   PLAYER_ENTERING_WORLD — login, reload, instance port
-- Future-safe: if any of these start returning secrets, IsGroupInCombat()
-- treats unknown/secret values as "in combat" (safe default).
---------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
local eventHandlers = {}

local function RegisterHandler(event, handler)
    eventHandlers[event] = handler
    eventFrame:RegisterEvent(event)
end

---------------------------------------------------------------
-- Dirty-flag refresh system (replaces C_Timer.After ScheduleRefresh).
-- Multiple events in the same frame only trigger ONE refresh.
-- After combat ends, OnUpdate keeps checking for untagged frames
-- whose secrets have unlocked, refreshing them incrementally
-- until all visible frames are tagged (then goes idle).
-- Zero closure allocation, purely event-driven.
---------------------------------------------------------------
local refreshDirty = false      -- set by events/hooks, consumed by OnUpdate
local refreshActive = false     -- true while post-combat catch-up is running
local refreshThrottle = 0       -- throttle post-combat catch-up to every 0.5s
local REFRESH_INTERVAL = 0.5    -- seconds between catch-up passes
local refreshStats = {total = 0, tagged = 0, passes = 0, lastPass = 0}

local refreshFrame = CreateFrame("Frame")
refreshFrame:Hide()  -- starts idle, no CPU cost

-- Forward declarations (used in OnUpdate before the full bodies are defined)
local ScheduleRefresh
local StartPostCombatRefresh

refreshFrame:SetScript("OnUpdate", function(self, elapsed)
    -- Safety reset: if inCombat is stuck but ICL + EIP both say OOC, force-reset.
    -- Must run BEFORE IsGroupInCombat() check, otherwise we never reach RefreshAllFrames.
    if inCombat then
        local icl = InCombatLockdown()
        local eip = IsEncounterInProgress()
        if icl ~= true and eip ~= true then
            inCombat = false
            trace("OnUpdate: inCombat stuck, ICL+EIP both false → FORCE RESET")
            StartPostCombatRefresh()
        end
    end
    if IsGroupInCombat() then
        refreshDirty = false
        self:Hide()
        return
    end

    if refreshDirty then
        refreshDirty = false
        refreshStats.passes = refreshStats.passes + 1
        refreshStats.lastPass = GetTime()
        RefreshAllFrames()
    end

    -- Post-combat catch-up: throttled to every 0.5s.
    -- If no progress since last pass → go idle (avoid endless loop
    -- when frames have readable nameText but GUID can't be resolved).
    if refreshActive then
        refreshThrottle = refreshThrottle - elapsed
        if refreshThrottle > 0 then return end
        refreshThrottle = REFRESH_INTERVAL
        local tagged = 0
        local total = 0
        if DamageMeter.ForEachSessionWindow then
            DamageMeter:ForEachSessionWindow(function(sw)
                if not sw.ForEachEntryFrame then return end
                sw:ForEachEntryFrame(function(frame)
                    total = total + 1
                    local nameFS = frame.GetName and frame:GetName()
                    if not nameFS or type(nameFS) == "string" then return end
                    local txt = nameFS:GetText()
                    if txt and not isSecret(txt) and type(txt) == "string" and txt:find("%[%d+%]") then
                        tagged = tagged + 1
                    end
                end)
            end)
        end
        refreshStats.total = total
        local prevTagged = refreshStats.tagged
        refreshStats.tagged = tagged
        if tagged > prevTagged then
            -- Made progress — keep going
            refreshDirty = true
        else
            -- No progress — go idle
            refreshActive = false
            if not refreshDirty then
                self:Hide()
                trace(format("RefreshIdle: %d/%d tagged in %d passes",
                    tagged, total, refreshStats.passes))
            end
        end
    elseif not refreshDirty then
        self:Hide()  -- no work left, go idle
    end
end)

function ScheduleRefresh()
    refreshDirty = true
    refreshFrame:Show()  -- wake up OnUpdate
end

-- Start post-combat catch-up: OnUpdate keeps running until all frames tagged
function StartPostCombatRefresh()
    refreshActive = true
    refreshStats.passes = 0
    ScheduleRefresh()
end

---------------------------------------------------------------
-- Event handlers (self-registering: one call = register + define)
---------------------------------------------------------------

-- === Combat START signals — strip our tags, go silent ===
RegisterHandler("PLAYER_REGEN_DISABLED", function()
    inCombat = true
    refreshActive = false
    refreshFrame:Hide()
    StripAllTags()
end)

RegisterHandler("PLAYER_IN_COMBAT_CHANGED", function(...)
    -- Guard: if any event arg is secret, fall back to InCombatLockdown().
    -- Previous approach: always assume combat-start on secret args.
    -- Problem: in Delves, PLAYER_IN_COMBAT_CHANGED fires with secret args
    -- AFTER combat ends. inCombat got stuck true with no event to reset it.
    if _hasanysecretvalues(...) then
        local icl = InCombatLockdown()
        if icl == true then
            inCombat = true
            trace("COMBAT_CHANGED → SECRET args, ICL=true → IN")
            StripAllTags()
        else
            inCombat = false
            trace("COMBAT_CHANGED → SECRET args, ICL=false → OUT")
            traceFrameState("COMBAT_CHANGED_SECRET_OUT", true)
            StartPostCombatRefresh()
        end
        return
    end
    local combatState = ...
    if isSecret(combatState) then
        -- Lazy-taint: hasanysecretvalues passed but individual arg is secret
        local icl = InCombatLockdown()
        if icl == true then
            inCombat = true
            trace("COMBAT_CHANGED → lazy-secret, ICL=true → IN")
            StripAllTags()
        else
            inCombat = false
            trace("COMBAT_CHANGED → lazy-secret, ICL=false → OUT")
            traceFrameState("COMBAT_CHANGED_LAZY_OUT", true)
            StartPostCombatRefresh()
        end
    elseif combatState == true then
        inCombat = true
        trace("COMBAT_CHANGED → IN")
        StripAllTags()
    else
        inCombat = false
        trace("COMBAT_CHANGED → OUT")
        traceFrameState("COMBAT_CHANGED_OUT", true)
        StartPostCombatRefresh()
    end
end)

local function OnCombatStart()
    inCombat = true
    StripAllTags()
end
RegisterHandler("ENCOUNTER_START", OnCombatStart)
RegisterHandler("INSTANCE_ENCOUNTER_ENGAGE_UNIT", OnCombatStart)

-- No-op: no longer used for combat detection, kept registered for future use
RegisterHandler("UNIT_FLAGS", function() end)

-- === Combat END signals — safe to inject again ===
RegisterHandler("PLAYER_REGEN_ENABLED", function()
    inCombat = false
    trace("REGEN_ENABLED")
    traceFrameState("REGEN_ENABLED", true)
    StartPostCombatRefresh()
end)

RegisterHandler("ENCOUNTER_END", function()
    -- Don't blindly set inCombat=false here — trash packs after a boss can
    -- mean we're still in combat. Use InCombatLockdown() as truth.
    local icl = InCombatLockdown()
    if icl ~= true then
        inCombat = false
    end
    trace(format("ENCOUNTER_END icl=%s inCombat=%s", tostring(icl), tostring(inCombat)))
    traceFrameState("ENCOUNTER_END")
    StartPostCombatRefresh()
end)

-- === Transition events — clean slate, safe to refresh ===
local function OnTransition()
    inCombat = false
    ScheduleRefresh()
end
RegisterHandler("LOADING_SCREEN_DISABLED", OnTransition)
RegisterHandler("PLAYER_ENTERING_WORLD", OnTransition)

-- === Data events ===
RegisterHandler("DAMAGE_METER_COMBAT_SESSION_UPDATED", function()
    -- Safety reset on data events too (OnUpdate may be hidden/idle)
    if inCombat then
        local icl = InCombatLockdown()
        local eip = IsEncounterInProgress()
        if icl ~= true and eip ~= true then
            inCombat = false
            trace("DM_SESSION_UPDATED: inCombat stuck → FORCE RESET")
            StartPostCombatRefresh()
            return
        end
    end
    if not IsGroupInCombat() then
        trace("DM_SESSION_UPDATED → dirty")
        ScheduleRefresh()
    end
end)

-- Fallback events — no special logic, just schedule a refresh
RegisterHandler("DAMAGE_METER_CURRENT_SESSION_UPDATED", ScheduleRefresh)
RegisterHandler("DAMAGE_METER_RESET", ScheduleRefresh)
RegisterHandler("GROUP_ROSTER_UPDATE", ScheduleRefresh)
RegisterHandler("ZONE_CHANGED_NEW_AREA", ScheduleRefresh)

-- Dispatcher: O(1) table lookup, fallback for any future unhandled events
eventFrame:SetScript("OnEvent", function(_, event, ...)
    local handler = eventHandlers[event]
    if handler then handler(...) else ScheduleRefresh() end
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
            hooksecurefunc(sessionWindow, "Refresh", function(sw)
                -- Session switch (DPS→Gesamt, Heal→DPS): frames get recycled
                -- for different players. Clear per-frame caches so InjectIlvl
                -- re-resolves everything fresh via Ambiguate API.
                if sw.ForEachEntryFrame then
                    sw:ForEachEntryFrame(function(frame)
                        -- Preserve GUID when sourceName is still secret — the Init
                        -- hook captured a valid GUID that can't be re-resolved without
                        -- a readable sourceName. Clearing it would permanently lose
                        -- the mapping until Blizzard unlocks the secret text.
                        local sn = frame.sourceName
                        if not sn or not isSecret(sn) then
                            frame._dilvlGUID = nil
                        end
                        frame._dilvlFontFile = nil
                        frame._dilvlFontSize = nil
                        frame._dilvlFontFlags = nil
                        frame._dilvlTextScale = nil
                        frame._dilvlTextColor = nil
                        frame._dilvlColorSetByAddon = nil
                        frame._dilvlNameFS = nil
                    end)
                    -- Reset per-player resolve fails (session switch = new context)
                    wipe(nameResolveFails)
                end
                ScheduleRefresh()
            end)
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
    local icl = InCombatLockdown()
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
        iclRaw = (icl == true and "YES") or (isSecret(icl) and "SECRET") or "no",
        inCombat = inCombat,
        encounter = eip == true,
        encounterSecret = eip and isSecret(eip),
        unitFlags = unitFlagsCombat,
        members = count,
        refreshActive = refreshActive,
        refreshPasses = refreshStats.passes,
        refreshTagged = refreshStats.tagged,
        refreshTotal = refreshStats.total,
        refreshLastPass = refreshStats.lastPass,
        deferredRetry = deferredRetryPending, -- (#19)
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
                local sn = frame.sourceName
                local snDbg = sn and not isSecret(sn) and tostring(sn) or nil
                if snDbg and nameResolveFails[snDbg] and nameResolveFails[snDbg] >= MAX_RESOLVE_FAILS then
                    path = "GAVE-UP(" .. snDbg:sub(1,10) .. ")"
                else
                    path = "NO-GUID"
                end
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
                textColor = (function()
                    -- Show current FS color + source for debug
                    local colorStr = ""
                    if nameFS and type(nameFS) ~= "string" then
                        local ok, r, g, b = pcall(nameFS.GetTextColor, nameFS)
                        if ok and r and not isSecret(r) then
                            colorStr = format("%.2f/%.2f/%.2f", r, g, b)
                        else
                            colorStr = "secret"
                        end
                    end
                    -- Determine color source
                    local src = "blizz"
                    if frame._dilvlColorSetByAddon then
                        src = frame._dilvlColorSetByAddon
                    end
                    return colorStr ~= "" and (colorStr .. "(" .. src .. ")") or nil
                end)(),
                path = path,
                nameFSType = nameFSType,
                resolveFails = (function()
                    local sn = frame.sourceName
                    local snK = sn and not isSecret(sn) and tostring(sn) or nil
                    return snK and nameResolveFails[snK] or 0
                end)(),
            }
        end)
    end)
    -- Expose per-player resolve fail counts for debug
    local resolveFails = {}
    for name, count in pairs(nameResolveFails) do
        resolveFails[#resolveFails + 1] = { name = name, fails = count, gaveUp = count >= MAX_RESOLVE_FAILS }
    end

    return windows, frames, hasGuid, hasTag, secretName, entries, combatInfo, resolveFails, MAX_RESOLVE_FAILS
end

---------------------------------------------------------------
-- Global trace toggle — called from /dilvl blizztrace
---------------------------------------------------------------
function Details_iLvlDisplay_BlizzTrace(showWindow)
    traceEnabled = not traceEnabled
    if traceEnabled then
        wipe(traceLog)
        print("|cFF00FF00Details! iLvl Display:|r Blizz trace |cFF00FF00ON|r — fight, leave combat, then /dilvl blizztrace")
    else
        print("|cFF00FF00Details! iLvl Display:|r Blizz trace |cFFFF0000OFF|r")
        if showWindow and #traceLog > 0 then
            local buf = {"=== Blizz DM Event Trace (" .. #traceLog .. " entries) ===\n"}
            for _, entry in ipairs(traceLog) do
                table.insert(buf, entry)
            end
            table.insert(buf, "\n=== End Trace ===")
            local text = table.concat(buf, "\n")
            if Details_iLvlDisplay_ShowDebugWindow then
                Details_iLvlDisplay_ShowDebugWindow(text)
            else
                print(text)
            end
        elseif showWindow then
            print("  (no events captured)")
        end
    end
end
