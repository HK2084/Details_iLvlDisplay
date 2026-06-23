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
    -- instances InCombatLockdown() can return a secret-wrapped false, which is truthy
    -- userdata in Lua — a raw check would falsely "defer" the UI on every /dilvl ui.
    if ns.secrets.MayBeInCombat() then
        print("|cFF00FF00Details! iLvl Display:|r Settings UI deferred until combat ends.")
    end
    main.Toggle(tab)
end
