-- src/server/PlayerService.luau
-- Roblox player registry. BnB logic ids are "u<userId>"; bots only live in Game.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Characters = require(Shared:WaitForChild("Characters"))

local PlayerService = {}

local records: { [Player]: any } = {}
local sequence = 0

local function makeRecord(player: Player)
    sequence += 1
    return {
        player = player,
        id = "u" .. tostring(player.UserId),
        name = player.DisplayName,
        char = Characters.DEFAULT_CHAR,
        order = sequence,
    }
end

function PlayerService.add(player: Player)
    local existing = records[player]
    if existing then
        return existing
    end
    local record = makeRecord(player)
    records[player] = record
    return record
end

function PlayerService.remove(player: Player)
    local record = records[player]
    records[player] = nil
    return record
end

function PlayerService.get(player: Player)
    return records[player]
end

function PlayerService.getById(id: string)
    for _, record in pairs(records) do
        if record.id == id then
            return record
        end
    end
    return nil
end

function PlayerService.list()
    local list = {}
    for _, record in pairs(records) do
        table.insert(list, record)
    end
    table.sort(list, function(a, b)
        return a.order < b.order
    end)
    return list
end

function PlayerService.count(): number
    local count = 0
    for _ in pairs(records) do
        count += 1
    end
    return count
end

function PlayerService.setChar(player: Player, charId: any): boolean
    local record = records[player]
    if not record or type(charId) ~= "string" or not Characters.isValidChar(charId) then
        return false
    end
    record.char = charId
    return true
end

function PlayerService.refreshNames()
    for _, record in pairs(records) do
        record.name = record.player.DisplayName
    end
end

-- 不使用 Roblox 默认角色；Main 也会尽早设置 CharacterAutoLoads=false。
function PlayerService.destroyCharacter(character: Instance)
    task.defer(function()
        if character and character.Parent then
            character:Destroy()
        end
    end)
end

return table.freeze(PlayerService)
