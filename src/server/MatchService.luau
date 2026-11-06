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

-- A room that throws is closed and its members are moved to a fresh room, so one
-- bad room can never stop the others from stepping. To stop a deterministic bug
-- from churning rooms forever, a player is re-seated at most MAX_RECYCLES times
-- within RECYCLE_WINDOW_STEPS; after that they are left without a room (and the
-- failure is logged) until they rejoin.
local MAX_RECYCLES = 3
local RECYCLE_WINDOW_STEPS = 30 * Constants.TICK_RATE

local rooms = {}
local roomByPlayer = {}
local nextRoomId = 0
local stepCount = 0
local failures = {} -- [Player] = { count = n, firstStep = step }
local scratch = {} -- reused per step: rooms are stepped from a stable copy
local loadingPlayers = {} -- [Player] = true while their profile is still loading
local settlementHandler = nil

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
        onSettled = settlementHandler,
    })
    rooms[room.id] = room
    roomByPlayer[record.player] = room
    room:addMember(record)
    return room
end

function MatchService.init(opts)
    opts = opts or {}
    rooms = {}
    roomByPlayer = {}
    nextRoomId = 0
    stepCount = 0
    failures = {}
    loadingPlayers = {}
    table.clear(scratch)
    settlementHandler = opts.onSettled
end

-- Main marks a player as loading from PlayerAdded until the profile load ends
-- (loaded, failed or cancelled). While marked, GetSync answers { phase = "loading" }
-- so the client can show a loading screen instead of an empty one.
function MatchService.setLoading(player: Player, loading: boolean)
    loadingPlayers[player] = if loading then true else nil
end

local function detachRoom(room)
    rooms[room.id] = nil
    for _, record in ipairs(room.members) do
        if roomByPlayer[record.player] == room then
            roomByPlayer[record.player] = nil
        end
    end
end

-- Counts a failure for this player; false once they have exceeded the budget.
local function mayReseat(player: Player): boolean
    local entry = failures[player]
    if not entry or stepCount - entry.firstStep > RECYCLE_WINDOW_STEPS then
        entry = { count = 0, firstStep = stepCount }
        failures[player] = entry
    end
    entry.count += 1
    return entry.count <= MAX_RECYCLES
end

local function recycleRoom(room, err)
    warn(string.format(
        "[BnB] room %d (%s, phase=%s) failed and was closed: %s",
        room.id,
        tostring(room.mode),
        tostring(room.phase),
        tostring(err)
    ))

    local members = table.clone(room.members)
    detachRoom(room)

    for _, record in ipairs(members) do
        if mayReseat(record.player) then
            local ok, seatErr = pcall(createPracticeRoom, record)
            if not ok then
                warn(string.format("[BnB] could not create a replacement room for %s: %s", record.id, tostring(seatErr)))
                -- createPracticeRoom registers the room before addMember runs;
                -- drop a half-built room so it cannot fail again every step.
                local half = roomByPlayer[record.player]
                if half then
                    detachRoom(half)
                    roomByPlayer[record.player] = nil
                end
            end
        else
            warn(string.format("[BnB] %s kept failing rooms; not reassigning until they rejoin", record.id))
        end
    end
end

function MatchService.step()
    stepCount += 1

    -- Rooms are created and removed while recycling, so never iterate `rooms`
    -- directly. Stepping in id order also keeps behaviour deterministic.
    table.clear(scratch)
    for _, room in pairs(rooms) do
        table.insert(scratch, room)
    end
    table.sort(scratch, function(a, b)
        return a.id < b.id
    end)

    for _, room in ipairs(scratch) do
        if rooms[room.id] == room then
            if room:isEmpty() then
                rooms[room.id] = nil
            else
                local ok, err = pcall(room.step, room)
                if not ok then
                    recycleRoom(room, err)
                end
            end
        end
    end
end

function MatchService.onPlayerAdded(player: Player)
    loadingPlayers[player] = nil
    local record = PlayerService.get(player)
    if not record or roomByPlayer[player] then
        return
    end
    createPracticeRoom(record)
end

function MatchService.onPlayerRemoving(player: Player, record)
    failures[player] = nil
    loadingPlayers[player] = nil
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
        if loadingPlayers[player] then
            return { phase = "loading" }
        end
        return nil
    end
    return room:getSync(PlayerService.get(player))
end

return table.freeze(MatchService)
