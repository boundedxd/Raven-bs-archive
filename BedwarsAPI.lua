--[[
██████╗  █████╗ ██╗   ██╗███████╗███╗   ██╗    ██████╗ ██╗  ██╗
██╔══██╗██╔══██╗██║   ██║██╔════╝████╗  ██║    ██╔══██╗██║  ██║
██████╔╝███████║██║   ██║█████╗  ██╔██╗ ██║    ██████╔╝███████║
██╔══██╗██╔══██║╚██╗ ██╔╝██╔══╝  ██║╚██╗██║    ██╔══██╗╚════██║
██║  ██║██║  ██║ ╚████╔╝ ███████╗██║ ╚████║    ██████╔╝     ██║
╚═╝  ╚═╝╚═╝  ╚═╝  ╚═══╝  ╚══════╝╚═╝  ╚═══╝    ╚═════╝      ╚═╝
Bedwars API — hooks into the game's internal controller system
]]

local Players  = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

-- ============================================================
-- Lazy Controller Discovery
-- Controllers are found on first access, not at startup.
-- All discovery is wrapped in pcall so a missing executor API
-- (getgc, getsenv) never breaks the loader.
-- ============================================================

local _controllers = nil        -- raw game controller registry
local _store       = nil        -- Rodux ClientHandlerStore

-- Attempt 1: getgc scan — finds the live controller registry table
local function tryGetgc()
    local ok, gc = pcall(getgc, true)
    if not ok or type(gc) ~= "table" then
        -- Some executors use getgc() without the boolean arg
        ok, gc = pcall(getgc)
    end
    if not ok or type(gc) ~= "table" then return nil, nil end

    local ctrl, store = nil, nil
    for _, v in ipairs(gc) do
        if type(v) ~= "table" then continue end
        -- Controller registry has at least these two keys
        if not ctrl
            and rawget(v, "SwordController")  ~= nil
            and rawget(v, "SprintController") ~= nil
        then
            ctrl = v
        end
        -- Rodux store: has getState() and a .changed signal
        if not store
            and type(rawget(v, "getState")) == "function"
            and type(rawget(v, "changed"))  == "table"
        then
            local ok2, state = pcall(function() return v:getState() end)
            if ok2 and type(state) == "table" and state.Bedwars ~= nil then
                store = v
            end
        end
        if ctrl and store then break end
    end
    return ctrl, store
end

-- Attempt 2: getsenv scan — walks every LocalScript environment
local function tryGetsenv()
    if not getsenv then return nil, nil end
    local ctrl, store = nil, nil
    local ok, scripts = pcall(function()
        return LocalPlayer.PlayerScripts:GetDescendants()
    end)
    if not ok then return nil, nil end
    for _, s in ipairs(scripts) do
        if not s:IsA("LocalScript") then continue end
        local eok, env = pcall(getsenv, s)
        if not eok or type(env) ~= "table" then continue end
        if not ctrl and type(env.controllers) == "table"
            and env.controllers.SwordController ~= nil then
            ctrl = env.controllers
        end
        if not store and type(env.ClientHandlerStore) == "table"
            and type(env.ClientHandlerStore.getState) == "function" then
            store = env.ClientHandlerStore
        end
        if ctrl and store then break end
    end
    return ctrl, store
end

local function makeStubStore()
    local state = {Bedwars = {kit = "none"}, matchState = 0}
    local subs  = {}
    return {
        getState = function() return state end,
        changed  = {
            connect = function(_, fn)
                table.insert(subs, fn)
            end
        }
    }
end

-- Resolve controllers on demand — tries each method once per call.
local function resolveControllers()
    if _controllers and _store then return end

    local c, s = tryGetgc()
    if not c or not s then
        c2, s2 = tryGetsenv()
        c = c or c2
        s = s or s2
    end

    _controllers = c or {}
    _store       = s or makeStubStore()
    _controllers.ClientHandlerStore = _store
end

-- Proxy so callers always get the up-to-date controller table
local Controllers = setmetatable({}, {
    __index = function(_, key)
        resolveControllers()
        if key == "ClientHandlerStore" then return _store end
        return _controllers[key]
    end,
    __newindex = function(_, key, value)
        resolveControllers()
        _controllers[key] = value
    end,
})

-- Kick off a background resolution attempt immediately
-- so controllers are usually ready by the time game code runs.
task.defer(function()
    resolveControllers()
end)

-- ============================================================
-- Helpers
-- ============================================================

local function getPlayerTeam(player)
    local ok, team = pcall(function() return player.Team end)
    return ok and team or nil
end

local function getEntityHealth(player)
    if player.Character and player.Character:FindFirstChild("Humanoid") then
        return player.Character.Humanoid.Health
    end
    return 0
end

local function buildEntity(player)
    return {
        Player = player,
        Team   = getPlayerTeam(player),
        Health = getEntityHealth(player),
    }
end

-- ============================================================
-- Entity
-- ============================================================

local Entity = {}

function Entity.getNearestEntity(maxDistance)
    local char = LocalPlayer.Character
    if not char or not char:FindFirstChild("HumanoidRootPart") then return nil end
    local origin = char.HumanoidRootPart.Position

    local nearest, nearestDist = nil, maxDistance
    for _, player in ipairs(Players:GetPlayers()) do
        if player == LocalPlayer then continue end
        local c = player.Character
        if not c or not c:FindFirstChild("HumanoidRootPart") then continue end
        if c:FindFirstChild("Humanoid") and c.Humanoid.Health <= 0 then continue end
        local dist = (c.HumanoidRootPart.Position - origin).Magnitude
        if dist < nearestDist then
            nearestDist = dist
            nearest     = buildEntity(player)
        end
    end
    return nearest
end

function Entity.getEntitiesInRange(maxDistance)
    local char = LocalPlayer.Character
    if not char or not char:FindFirstChild("HumanoidRootPart") then return {} end
    local origin = char.HumanoidRootPart.Position

    local result = {}
    for _, player in ipairs(Players:GetPlayers()) do
        if player == LocalPlayer then continue end
        local c = player.Character
        if not c or not c:FindFirstChild("HumanoidRootPart") then continue end
        if c:FindFirstChild("Humanoid") and c.Humanoid.Health <= 0 then continue end
        if (c.HumanoidRootPart.Position - origin).Magnitude <= maxDistance then
            table.insert(result, buildEntity(player))
        end
    end
    return result
end

-- ============================================================
-- Player
-- ============================================================

local Player = {}

function Player.getHealth(player)
    player = player or LocalPlayer
    if player.Character and player.Character:FindFirstChild("Humanoid") then
        return player.Character.Humanoid.Health
    end
    return 0
end

function Player.getTeam(player)
    return getPlayerTeam(player or LocalPlayer)
end

-- ============================================================
-- Inventory
-- ============================================================

local SWORD_NAMES = {
    "wood_sword", "stone_sword", "iron_sword", "diamond_sword", "emerald_sword",
    "wood_dao",   "stone_dao",   "iron_dao",   "diamond_dao",   "emerald_dao",
    "ice_sword",  "infernal_saber", "light_sword",
}

local function isSword(toolName)
    local lower = toolName:lower()
    for _, name in ipairs(SWORD_NAMES) do
        if lower == name then return true end
    end
    return false
end

local Inventory = {}

function Inventory.getSword()
    -- Equipped in character first
    local char = LocalPlayer.Character
    if char then
        for _, v in ipairs(char:GetChildren()) do
            if v:IsA("Tool") and isSword(v.Name) then
                return {tool = v, name = v.Name}
            end
        end
    end
    -- Then backpack
    for _, v in ipairs(LocalPlayer.Backpack:GetChildren()) do
        if v:IsA("Tool") and isSword(v.Name) then
            return {tool = v, name = v.Name}
        end
    end
    return nil
end

function Inventory.equipItem(tool)
    if not tool or not tool:IsA("Tool") then return end
    local hum = LocalPlayer.Character
        and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
    if hum then hum:EquipTool(tool) end
end

function Inventory.getItem(itemName)
    -- Try game's own InventoryController
    local inv = rawget(_controllers or {}, "InventoryController")
    if inv then
        local ok, result = pcall(function() return inv:getItem(itemName) end)
        if ok and result then return result end
    end
    -- Fallback: scan character and backpack
    local lower = itemName:lower()
    local function scan(parent)
        for _, v in ipairs(parent:GetChildren()) do
            if v:IsA("Tool") and v.Name:lower() == lower then
                return {tool = v, amount = 1, itemType = itemName}
            end
        end
    end
    local char = LocalPlayer.Character
    if char then
        local found = scan(char)
        if found then return found end
    end
    return scan(LocalPlayer.Backpack)
end

-- ============================================================
-- Utility
-- ============================================================

local Utility = {}

-- 0 = lobby/waiting, 1 = in-game, 2 = game ended
function Utility.getMatchState()
    local store = _store or makeStubStore()
    local ok, state = pcall(function() return store:getState() end)
    if ok and state then
        if state.matchState ~= nil then return state.matchState end
        if state.Bedwars and state.Bedwars.matchState ~= nil then
            return state.Bedwars.matchState
        end
    end
    if workspace:FindFirstChild("Map") or workspace:FindFirstChild("Bedwars") then
        return 1
    end
    return 0
end

function Utility.getQueueType()
    local store = _store or makeStubStore()
    local ok, state = pcall(function() return store:getState() end)
    if ok and state then
        if state.queueType then return state.queueType end
        if state.Lobby and state.Lobby.queueType then return state.Lobby.queueType end
    end
    return "solos"
end

-- ============================================================
-- Return API  (Controllers is a lazy proxy — never hangs startup)
-- ============================================================

return {
    Controllers = Controllers,
    Entity      = Entity,
    Player      = Player,
    Inventory   = Inventory,
    Utility     = Utility,
}
