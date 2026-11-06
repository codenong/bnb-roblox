-- src/server/MatchService.luau
-- Room manager. New players default to an independent practice room (1 human +
-- 1 bot). Versus tables are created lazily and hold two humans with a bounded
-- spectator audience; a player can move between modes through joinPractice /
-- joinVersus. All transport stays room-scoped in Room.luau.

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
local lobbyPlayers = {} -- [Player] = true after leaving a room, before choosing another
local settlementHandler = nil

-- Seat a record and keep the reverse index in sync. A fresh practice room can
-- never reject its only human, but versus joins can lose a race with a seat
-- opening/closing, so callers must handle false.
local function attachPlayer(room, record): boolean
    roomByPlayer[record.player] = room
    if room:addMember(record) then
        lobbyPlayers[record.player] = nil
        return true
    end
    roomByPlayer[record.player] = nil
    return false
end

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
    if not attachPlayer(room, record) then
        rooms[room.id] = nil
        return nil
    end
    return room
end

local function createVersusRoom()
    nextRoomId += 1
    local room = Room.new({
        id = nextRoomId,
        mode = "versus",
        maxPlayers = Constants.VERSUS_PLAYERS,
        fillBots = false,
        maxSpectators = Constants.VERSUS_SPECTATORS,
        waitingTicks = Constants.WAITING_TICKS,
        resultsTicks = Constants.RESULTS_TICKS,
        random = Random.new(),
        onSettled = settlementHandler,
    })
    rooms[room.id] = room
    return room
end

local function countVersusRooms(): number
    local count = 0
    for _, room in pairs(rooms) do
        if room.mode == "versus" then
            count += 1
        end
    end
    return count
end

-- Remove a record from whatever room it is in. This is synchronous: a versus
-- round can finish here, which reports the leaver through the settlement hook
-- before the player is seated somewhere else.
local function detachPlayer(player: Player, record): any
    local room = roomByPlayer[player]
    if not room then
        return nil
    end
    roomByPlayer[player] = nil
    if record then
        room:removeMember(record)
    end
    if room:isEmpty() then
        rooms[room.id] = nil
    end
    return room
end

-- Prefer a waiting table with an open seat, then a newly created table, and only
-- then spectate an existing match. This keeps quick play out of the audience
-- when there is still room to play.
local function findAutoVersusRoom()
    local waiting = nil
    for _, room in pairs(rooms) do
        if room.mode == "versus" and room.phase == "waiting" and not room:isFull()
            and (waiting == nil or room.id < waiting.id) then
            waiting = room
        end
    end
    if waiting then
        return waiting
    end

    if countVersusRooms() < Constants.VERSUS_TABLES then
        return createVersusRoom()
    end

    local spectator = nil
    for _, room in pairs(rooms) do
        if room.mode == "versus" and room:canAddMember() then
            if spectator == nil
                or room:getSpectatorCount() < spectator:getSpectatorCount()
                or (room:getSpectatorCount() == spectator:getSpectatorCount() and room.id < spectator.id) then
                spectator = room
            end
        end
    end
    return spectator
end

-- Drop a newly created but unused table so a failed join cannot leak a room.
local function discardEmptyRoom(room)
    if room and room.mode == "versus" and room:isEmpty() then
        rooms[room.id] = nil
    end
end

function MatchService.init(opts)
    opts = opts or {}
    rooms = {}
    roomByPlayer = {}
    nextRoomId = 0
    stepCount = 0
    failures = {}
    loadingPlayers = {}
    lobbyPlayers = {}
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
            local ok, replacement = pcall(createPracticeRoom, record)
            if not ok then
                warn(string.format("[BnB] could not create a replacement room for %s: %s", record.id, tostring(replacement)))
            elseif not replacement then
                warn(string.format("[BnB] replacement room rejected %s", record.id))
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
    lobbyPlayers[player] = nil
    local record = PlayerService.get(player)
    if not record or roomByPlayer[player] then
        return
    end
    createPracticeRoom(record)
end

function MatchService.onPlayerRemoving(player: Player, record)
    failures[player] = nil
    loadingPlayers[player] = nil
    lobbyPlayers[player] = nil
    detachPlayer(player, record)
end

function MatchService.getRoomFor(player: Player)
    return roomByPlayer[player]
end

-- Move a player to a private practice room. Joining practice while already in
-- one is a no-op. Leaving a live versus round here is a forfeit, exactly like
-- any other seat exit.
function MatchService.joinPractice(player: Player): (boolean, string?, number?)
    local record = PlayerService.get(player)
    if not record then
        return false, "not_loaded", nil
    end

    local current = roomByPlayer[player]
    if current and current.mode == "practice" then
        return true, nil, current.id
    end

    detachPlayer(player, record)
    local room = createPracticeRoom(record)
    if not room then
        return false, "join_failed", nil
    end
    return true, nil, room.id
end

-- Join a specific versus table, or pick one automatically when tableId is nil.
-- A specific table is validated before the player leaves their current room, so
-- a failed switch never strands them. Quick join while already seated at a
-- versus table keeps that table instead of hopping around.
function MatchService.joinVersus(player: Player, tableId: number?): (boolean, string?, number?)
    local record = PlayerService.get(player)
    if not record then
        return false, "not_loaded", nil
    end
    if tableId ~= nil and (type(tableId) ~= "number" or tableId % 1 ~= 0) then
        return false, "invalid_table", nil
    end

    local current = roomByPlayer[player]
    if current and current.mode == "versus" and (tableId == nil or tableId == current.id) then
        return true, nil, current.id
    end

    local target = nil
    if tableId == nil then
        target = findAutoVersusRoom()
        if not target then
            return false, "no_tables", nil
        end
    else
        target = rooms[tableId]
        if not target or target.mode ~= "versus" then
            return false, "no_table", nil
        end
    end

    if target ~= current and not target:canAddMember() then
        discardEmptyRoom(target)
        return false, "table_full", nil
    end

    if current then
        detachPlayer(player, record)
    end

    if not attachPlayer(target, record) then
        discardEmptyRoom(target)
        -- The old room is gone at this point; give the player a safe fallback
        -- rather than leaving them with no state to sync.
        createPracticeRoom(record)
        return false, "join_failed", nil
    end
    return true, nil, target.id
end

-- Remote-facing entry point. Accepts "practice", "versus", a table id, or a
-- { mode = "practice" | "versus", tableId = n? } request.
function MatchService.join(player: Player, target: any): (boolean, string?, number?)
    if target == nil or target == "practice" then
        return MatchService.joinPractice(player)
    end
    if target == "versus" then
        return MatchService.joinVersus(player, nil)
    end
    if type(target) == "number" then
        return MatchService.joinVersus(player, target)
    end
    if type(target) == "table" then
        if target.mode == "practice" then
            return MatchService.joinPractice(player)
        elseif target.mode == "versus" then
            local tableId = target.tableId
            if tableId == nil then
                return MatchService.joinVersus(player, nil)
            end
            return MatchService.joinVersus(player, tableId)
        end
    end
    return false, "invalid_target", nil
end

-- Public table browser data. Returned tables are copies; the client can never
-- mutate a live room through this payload.
function MatchService.getTables()
    local list = {}
    for _, room in pairs(rooms) do
        if room.mode == "versus" then
            local waitingReady = room.phase == "waiting" and room:isCountdownReady()
            table.insert(list, {
                id = room.id,
                mode = room.mode,
                phase = room.phase,
                seats = room:getSeatSummary(),
                seatCount = room:getSeatCount(),
                maxPlayers = room.maxPlayers,
                spectatorCount = room:getSpectatorCount(),
                maxSpectators = room.maxSpectators,
                waitingForPlayers = room.phase == "waiting" and not room:isCountdownReady(),
                endsIn = if room.phase == "waiting" and waitingReady
                    then room:getWaitingSeconds()
                    elseif room.phase == "ended" then room:getResultsSeconds()
                    else 0,
                joinable = room:canAddMember(),
            })
        end
    end
    table.sort(list, function(a, b)
        return a.id < b.id
    end)
    return list
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

-- "换桌" means leaving the current room. The old room settles/cancels exactly as
-- any other leave (a live versus round is a forfeit), and the player stays in the
-- table browser without a room until choosing practice or another table.
function MatchService.leaveTable(player: Player): (boolean, string?)
    local record = PlayerService.get(player)
    if not record then
        return false, "not_loaded"
    end
    detachPlayer(player, record)
    lobbyPlayers[player] = true
    return true
end

function MatchService.getSync(player: Player)
    local room = roomByPlayer[player]
    if not room then
        -- A player browsing after "换桌" has deliberately left; do not recreate a
        -- practice room behind the browser. Choosing a mode clears this flag.
        if lobbyPlayers[player] then
            return nil
        end
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
