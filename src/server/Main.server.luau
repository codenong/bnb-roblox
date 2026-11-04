-- src/server/Main.server.luau
-- Server entry point: remotes, player lifecycle and the fixed-step match loop.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- The game is rendered entirely in a ScreenGui; never spawn a Roblox character.
Players.CharacterAutoLoads = false

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local Net = require(Shared:WaitForChild("Net"))

Net.init()

local MatchService = require(script.Parent:WaitForChild("MatchService"))
local PlayerService = require(script.Parent:WaitForChild("PlayerService"))

MatchService.init()

---------------------------------------------------------------- 网络事件

Net.get("Input").OnServerEvent:Connect(function(player, dirs)
    MatchService.setInput(player, dirs)
end)

Net.get("Action").OnServerEvent:Connect(function(player, action)
    if type(action) == "string" then
        MatchService.action(player, action)
    end
end)

Net.get("SelectChar").OnServerEvent:Connect(function(player, charId)
    MatchService.selectChar(player, charId)
end)

Net.get("GetSync").OnServerInvoke = function(player)
    return MatchService.getSync(player)
end

---------------------------------------------------------------- 玩家进出

local function onPlayerAdded(player: Player)
    player.CharacterAdded:Connect(function(character)
        PlayerService.destroyCharacter(character)
    end)
    if player.Character then
        PlayerService.destroyCharacter(player.Character)
    end

    PlayerService.add(player)
    MatchService.onPlayerAdded(player)
end

local function onPlayerRemoving(player: Player)
    local record = PlayerService.remove(player)
    if record then
        MatchService.onPlayerRemoving(player, record)
    end
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

for _, player in ipairs(Players:GetPlayers()) do
    onPlayerAdded(player)
end

---------------------------------------------------------------- 主循环

local accumulator = 0

RunService.Heartbeat:Connect(function(dt)
    accumulator += math.min(dt, 0.25)

    local steps = 0
    while accumulator >= Constants.DT and steps < 4 do
        MatchService.step()
        accumulator -= Constants.DT
        steps += 1
    end

    -- Do not spiral after a long frame; drop the excess backlog.
    if steps == 4 then
        accumulator = math.min(accumulator, Constants.DT)
    end
end)
