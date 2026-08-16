-- Details! Item Level Display — Copyright (c) 2026 HK2084. All rights reserved.
-- Licensed for private use only; see LICENSE. No redistribution of modified copies.
-- ui/slash_ui.lua — /dilvl ui slash routing.
--
-- Keeps the existing /dilvl slash table intact (core.lua owns it); we hook
-- in a single new sub-command "ui" via the same slash entry point. Putting
-- the routing in its own file means a UI crash never touches core.lua's
-- slash table.

local addonName, ns = ...
ns.ui = ns.ui or {}
local slash = {}
ns.ui.slash = slash

-- nil = nothing deferred · true = deferred without a tab · string = deferred tab id
local pendingTab = nil

-- Export the handler. core.lua's slash chain calls this when msg starts with "ui".
-- Signature: HandleSlash(restOfMsg) — restOfMsg is whatever followed "ui ".
function slash.HandleSlash(rest)
    rest = rest or ""
    local tab = rest:match("^%s*(%S+)") -- optional sub-arg = tab id

    local main = ns.ui and ns.ui.main
    if not main then
        print("|cFF00FF00Details! iLvl Display:|r Settings UI not loaded.")
        return
    end

    -- MayBeInCombat (secret => true), not raw InCombatLockdown(): inside restricted
    -- instances InCombatLockdown() can return a secret-wrapped false, which still
    -- never reads as false in a conditional — a raw check would falsely "defer"
    -- the UI on every /dilvl ui.
    --
    -- This used to print the message and then fall through to Toggle anyway, so
    -- the line was wrong in both directions: with the window closed it opened
    -- regardless, and with the window OPEN a /dilvl ui in combat CLOSED it while
    -- promising a re-open that no code ever performed. Now the promise is kept.
    if ns.secrets.MayBeInCombat() then
        pendingTab = tab or true
        print("|cFF00FF00Details! iLvl Display:|r Settings UI deferred until combat ends.")
        return
    end
    pendingTab = nil
    main.Toggle(tab)
end

-- Redeem the deferral. Registered here rather than in core.lua so a UI fault
-- cannot reach the core event handler (same reason this file exists at all).
local combatWatcher = CreateFrame("Frame")
combatWatcher:RegisterEvent("PLAYER_REGEN_ENABLED")
combatWatcher:SetScript("OnEvent", function()
    if pendingTab == nil then return end
    local tab = (pendingTab ~= true) and pendingTab or nil
    pendingTab = nil
    local main = ns.ui and ns.ui.main
    if not main or not main.Open then return end
    -- Open, never Toggle: the user asked for the window, and by now the state
    -- may have changed under us.
    pcall(main.Open, tab)
end)
