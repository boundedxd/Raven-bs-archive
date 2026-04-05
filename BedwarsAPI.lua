--[[
██████╗  █████╗ ██╗   ██╗███████╗███╗   ██╗    ██████╗ ██╗  ██╗
██╔══██╗██╔══██╗██║   ██║██╔════╝████╗  ██║    ██╔══██╗██║  ██║
██████╔╝███████║██║   ██║█████╗  ██╔██╗ ██║    ██████╔╝███████║
██╔══██╗██╔══██║╚██╗ ██╔╝██╔══╝  ██║╚██╗██║    ██╔══██╗╚════██║
██║  ██║██║  ██║ ╚████╔╝ ███████╗██║ ╚████║    ██████╔╝     ██║
╚═╝  ╚═╝╚═╝  ╚═╝  ╚═══╝  ╚══════╝╚═╝  ╚═══╝    ╚═════╝      ╚═╝
Bedwars API - hooks into the game's internal controller system
]]

local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local RunService = game:GetService("RunService")

-- ============================================================
-- Controller Discovery
-- Bedwars uses a Flamework-style controller registry.
-- We find it via getgc() by looking for a table that contains
-- the known controller keys.
-- ============================================================

local function findControllers()
    for _, v in ipairs(getgc(true)) do
        if type(v) == "table"
            and rawget(v, "SwordController") ~= nil
            and rawget(v, "SprintController") ~= nil
            and rawget(v, "KnockbackUtil") ~= nil
        then
            return v
        end
    end
end

-- ClientHandlerStore is a Rodux store whose state has a .Bedwars key.
local function findClientHandlerStore()
    for _, v in ipairs(getgc(true)) do
        if type(v) == "table"
            and type(rawget(v, "getState")) == "function"
            and type(rawget(v, "changed")) == "table"
            and type(rawget(v, "changed").connect) == "function"
        then
            local ok, state = pcall(function() return v:getState() end)
            if ok and type(state) == "table" and state.Bedwars ~= nil then
                return v
            end
        end
    end
end

local Controllers = nil
local ClientHandlerStore = nil

-- Retry for up to 15 seconds
for _ = 1, 30 do
    Controllers = findControllers()
    ClientHandlerStore = findClientHandlerStore()
    if Controllers and ClientHandlerStore then break end
    task.wait(0.5)
end

if not Controllers then
    warn("[RavenB4 API] Failed to locate game controllers")
    Controllers = {}
end

if not ClientHandlerStore then
    warn("[RavenB4 API] Failed to locate ClientHandlerStore")
    -- Stub so the rest of the code doesn't error
    local state = {Bedwars = {kit = "none"}, matchState = 0}
    local subscribers = {}
    ClientHandlerStore = {
        getState = function() return state end,
        changed = {
            connect = function(_, fn) table.insert(subscribers, fn) end
        }
    }
end

Controllers.ClientHandlerStore = ClientHandlerStore

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
            nearest = buildEntity(player)
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
    -- Check equipped tool in character first
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
    local humanoid = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
    if humanoid then
        humanoid:EquipTool(tool)
    end
end

function Inventory.getItem(itemName)
    -- Try the game's own InventoryController if available
    if Controllers.InventoryController then
        local ok, result = pcall(function()
            return Controllers.InventoryController:getItem(itemName)
        end)
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
    if Controllers.ClientHandlerStore then
        local ok, state = pcall(function()
            return Controllers.ClientHandlerStore:getState()
        end)
        if ok and state then
            if state.matchState ~= nil then return state.matchState end
            if state.Bedwars and state.Bedwars.matchState ~= nil then
                return state.Bedwars.matchState
            end
        end
    end
    -- Rough fallback: if a Map/Bedwars folder exists, we're in a match
    if workspace:FindFirstChild("Map") or workspace:FindFirstChild("Bedwars") then
        return 1
    end
    return 0
end

function Utility.getQueueType()
    if Controllers.ClientHandlerStore then
        local ok, state = pcall(function()
            return Controllers.ClientHandlerStore:getState()
        end)
        if ok and state then
            if state.queueType then return state.queueType end
            if state.Lobby and state.Lobby.queueType then return state.Lobby.queueType end
        end
    end
    return "solos"
end

-- ============================================================
-- Return API
-- ============================================================

return {
    Controllers = Controllers,
    Entity      = Entity,
    Player      = Player,
    Inventory   = Inventory,
    Utility     = Utility,
}
