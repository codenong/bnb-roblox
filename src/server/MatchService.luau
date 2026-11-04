-- src/server/MatchService.luau
-- Room manager. Every human gets an independent practice room (1 human + 1
-- bot) in M1; additional modes can create other room configurations without
-- changing the room-scoped transport in Room.luau.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

local Room = require(script.Parent:WaitForChild("Room"))
local PlayerService = require(script.Parent:WaitForChild("PlayerService"))

local MatchService = {}

local rooms = {}
local roomByPlayer = {}
local nextRoomId = 0

local function createPracticeRoom(record)
    nextRoomId += 1
    local room = Room.new({
        id = nextRoomId,
        mode = "practice",
        maxPlayers = Constants.PRACTICE_PLAYERS,
        fillBots = true,
        waitingTicks = Constants.WAITING_TICKS,
        resultsTicks = Constants.RESULTS_TICKS,
        random = Random.new(),
    })
    rooms[room.id] = room
    roomByPlayer[record.player] = room
    room:addMember(record)
    return room
end

function MatchService.init()
    rooms = {}
    roomByPlayer = {}
    nextRoomId = 0
end

function MatchService.step()
    for id, room in pairs(rooms) do
        if room:isEmpty() then
            rooms[id] = nil
        else
            room:step()
        end
    end
end

function MatchService.onPlayerAdded(player: Player)
    local record = PlayerService.get(player)
    if not record or roomByPlayer[player] then
        return
    end
    createPracticeRoom(record)
end

function MatchService.onPlayerRemoving(player: Player, record)
    local room = roomByPlayer[player]
    if not room then
        return
    end

    roomByPlayer[player] = nil
    room:removeMember(record)
    if room:isEmpty() then
        rooms[room.id] = nil
    end
end

function MatchService.getRoomFor(player: Player)
    return roomByPlayer[player]
end

function MatchService.getRoomCount(): number
    local count = 0
    for _ in pairs(rooms) do
        count += 1
    end
    return count
end

function MatchService.setInput(player: Player, dirs)
    local room = roomByPlayer[player]
    if not room then
        return
    end
    room:setInput(PlayerService.get(player), dirs)
end

function MatchService.action(player: Player, action: string)
    local room = roomByPlayer[player]
    if not room then
        return
    end
    room:action(PlayerService.get(player), action)
end

function MatchService.selectChar(player: Player, charId: string): boolean
    local room = roomByPlayer[player]
    if not room then
        return false
    end
    return room:selectChar(PlayerService.get(player), charId)
end

function MatchService.getSync(player: Player)
    local room = roomByPlayer[player]
    if not room then
        -- The client can invoke GetSync in the same join frame as PlayerAdded;
        -- create the practice room lazily instead of leaving it unsynced.
        local record = PlayerService.get(player)
        if record then
            room = createPracticeRoom(record)
        end
    end
    if not room then
        return nil
    end
    return room:getSync(PlayerService.get(player))
end

return table.freeze(MatchService)
