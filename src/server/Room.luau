-- src/server/Room.luau
-- One independent match room. A practice room contains one human and one bot;
-- the member/audience split is kept generic so versus tables and spectators can
-- reuse the same room lifecycle later.
--
-- All outbound events (RoundState/Snapshot/Fx/RoundEnd) are addressed to this
-- room's members only. Nothing in here touches PlayerService.list() globally.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local Characters = require(Shared:WaitForChild("Characters"))
local Grid = require(Shared:WaitForChild("Grid"))
local Map = require(Shared:WaitForChild("Map"))
local Game = require(Shared:WaitForChild("Game"))
local Net = require(Shared:WaitForChild("Net"))
local Shop = require(Shared:WaitForChild("Shop"))

local BotService = require(script.Parent:WaitForChild("BotService"))
local PlayerService = require(script.Parent:WaitForChild("PlayerService"))
local SnapshotService = require(script.Parent:WaitForChild("SnapshotService"))

local Room = {}
Room.__index = Room

local FIRST = {
    "快乐", "无敌", "闪电", "暴走", "泡泡", "奶茶", "深海",
    "元气", "榴莲", "章鱼", "海盗", "甜心", "蓝莓", "冲锋",
}
local SECOND = {
    "宝宝", "小乖", "战士", "船长", "鱼丸", "果冻", "皮皮",
    "球球", "大侠", "萌新", "骑士", "魔王", "胖胖", "糖豆",
}

local VALID_DIRS = {
    up = true,
    down = true,
    left = true,
    right = true,
}

local function recordColorIndex(record)
    return Characters.colorIndex(Characters.colorOf(record.charColors, record.char)) or 0
end

local function buildRoster(defs)
    local result = {}
    for i, def in ipairs(defs) do
        result[i] = {
            id = def.id,
            name = def.name,
            isBot = def.isBot == true,
            char = Characters.getChar(def.char).id,
            colorIndex = Characters.sanitizeColorIndex(def.colorIndex, i - 1),
            items = if type(def.carry) == "table" then table.clone(def.carry) else nil,
        }
    end
    return result
end

local function indexRoster(list)
    local byId = {}
    for _, entry in ipairs(list) do
        byId[entry.id] = entry
    end
    return byId
end

local function randomBotName(rng, used)
    for _ = 1, 40 do
        local name = FIRST[rng:NextInteger(1, #FIRST)] .. SECOND[rng:NextInteger(1, #SECOND)]
        if rng:NextNumber() < 0.25 then
            name ..= tostring(rng:NextInteger(1, 98))
        end
        if not used[name] then
            used[name] = true
            return name
        end
    end
    local fallback = "Bot" .. tostring(rng:NextInteger(1000, 9999))
    used[fallback] = true
    return fallback
end

local function allPlayerFx(player)
    return {
        alive = player.alive,
        trapped = player.trapped,
        needle = player.inv.needle,
        eaten = #player.eaten,
    }
end

local function makeFxState(current)
    local bombs = {}
    for _, bomb in ipairs(current.bombs) do
        bombs[bomb.id] = true
    end
    local explosions = {}
    for _, explosion in ipairs(current.explosions) do
        explosions[explosion] = true
    end
    local players = {}
    for _, player in ipairs(current.playerOrder) do
        players[player.id] = allPlayerFx(player)
    end
    return {
        bombs = bombs,
        explosions = explosions,
        players = players,
        warmup = current.warmup,
    }
end

function Room.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Room)

    self.id = opts.id or 0
    self.mode = opts.mode or "practice"
    self.maxPlayers = opts.maxPlayers or Constants.PRACTICE_PLAYERS
    self.fillBots = opts.fillBots ~= false
    self.waitingTicks = opts.waitingTicks or Constants.WAITING_TICKS
    self.resultsTicks = opts.resultsTicks or Constants.RESULTS_TICKS
    -- Selection locks for the last charLockTicks of the waiting countdown. Capped
    -- below the full countdown so a very short wait (tests, tuning) never starts
    -- out locked.
    self.charLockTicks = math.min(opts.charLockTicks or Constants.CHAR_LOCK_TICKS, self.waitingTicks - 1)
    self.random = opts.random or Random.new()
    self.onSettled = opts.onSettled
    self.onUsageSettled = opts.onUsageSettled

    self.phase = "waiting"
    self.waitingLeft = self.waitingTicks
    self.resultsLeft = 0
    self.roundId = 0

    self.game = nil
    self.brains = {}
    self.roster = {}
    self.rosterById = {}
    self.lastResult = nil
    self.fxState = nil
    self.snapshot = SnapshotService.new()

    -- Members receive this room's state and snapshots. Seats are the subset that
    -- plays the next/current round; everyone else is a read-only spectator.
    -- Spectators never take a seat, even when one becomes vacant.
    self.members = {}
    self.memberById = {}
    self.seats = {}
    self.seatById = {}
    self.maxSpectators = opts.maxSpectators or Constants.VERSUS_SPECTATORS

    -- Versus rooms have a temporary host and optional entry password. Practice
    -- rooms leave these unused. The password stays in server memory only and is
    -- never put in a state/sync/table payload.
    self.defaultName = opts.defaultName or ("房间 " .. tostring(self.id))
    self.name = if self.mode == "versus" then self.defaultName else nil
    self.hostId = nil
    self.password = nil

    -- Participants are fixed when the round starts so a player leaving mid-round
    -- still shows up in settlement (and therefore in versus stats).
    self.roundParticipants = {}
    self.roundParticipantById = {}
    self.roundActivity = {}
    self.roundLeft = {}
    self.roundNoAction = {}
    self.roundNoActionChecked = false
    self.roundEndReason = nil
    -- Items are settled once per participant per round. This set survives a
    -- participant leaving the room so a later round-end/save cannot charge twice.
    self.usageSettled = {}
    -- [participantId] = { queue = {{seq, dirs}, ...}, lastQueued = n }
    -- Sequenced input waits here so every command is applied for exactly one
    -- simulation tick, in order. Legacy unsequenced input bypasses the queue.
    self.inputQueues = {}

    return self
end

function Room:isEmpty(): boolean
    return #self.members == 0
end

function Room:getMemberCount(): number
    return #self.members
end

function Room:getSeatCount(): number
    return #self.seats
end

function Room:getSpectatorCount(): number
    return #self.members - #self.seats
end

function Room:getRoomName(): string?
    return self.name
end

function Room:getHostId(): string?
    return self.hostId
end

function Room:getHostRecord()
    if self.hostId == nil then
        return nil
    end
    return self.memberById[self.hostId]
end

function Room:getHostName(): string?
    local record = self:getHostRecord()
    return if record then record.name else nil
end

function Room:hasPassword(): boolean
    return self.password ~= nil
end

function Room:checkPassword(password): boolean
    return self.password ~= nil
        and type(password) == "string"
        and password == self.password
end

-- Copy of the non-seated members. MatchService uses this when a room loses its
-- last seat and must move its audience out.
function Room:getSpectatorRecords()
    local result = {}
    for _, record in ipairs(self.members) do
        if not self.seatById[record.id] then
            table.insert(result, record)
        end
    end
    return result
end

function Room:resetConfig()
    self.hostId = nil
    self.name = if self.mode == "versus" then self.defaultName else nil
    self.password = nil
end

-- Host-only mutation. Name/password validation and filtering happen in
-- MatchService; Room only keeps the room-scoped state and broadcasts it.
function Room:setConfig(requesterId, name: string?, passwordUpdate: string?): (boolean, string?)
    if self.mode ~= "versus" then
        return false, "not_versus"
    end
    if self.phase ~= "waiting" then
        return false, "not_waiting"
    end
    if requesterId == nil or self.hostId ~= requesterId then
        return false, "not_host"
    end
    if name ~= nil then
        self.name = name
    end
    if passwordUpdate ~= nil then
        self.password = if passwordUpdate == "" then nil else passwordUpdate
    end
    self:broadcastState()
    return true
end

function Room:getPhase(): string
    return self.phase
end

function Room:getMode(): string
    return self.mode
end

function Room:getWaitingSeconds(): number
    return math.max(0, math.ceil(self.waitingLeft / Constants.TICK_RATE))
end

function Room:getResultsSeconds(): number
    return math.max(0, math.ceil(self.resultsLeft / Constants.TICK_RATE))
end

-- Public, copy-only view used by the table browser.
function Room:getSeatSummary()
    local result = {}
    for i, record in ipairs(self.seats) do
        result[i] = { id = record.id, name = record.name }
    end
    return result
end

function Room:isSeated(record): boolean
    return record ~= nil and self.seatById[record.id] ~= nil
end

function Room:isFull(): boolean
    return #self.seats >= self.maxPlayers
end

-- Practice rooms are ready with one human because a bot fills the other seat.
function Room:isCountdownReady(): boolean
    return self.fillBots or self:isFull()
end

-- Whether another member can be accepted: a free seat always wins over the
-- spectator cap, otherwise the spectator cap applies.
function Room:canAddMember(): boolean
    if self.phase == "waiting" and not self:isFull() then
        return true
    end
    return self:getSpectatorCount() < self.maxSpectators
end

-- True while the waiting countdown is inside its lock window. Not locked when the
-- room is not counting down (e.g. a versus table that is not full yet).
function Room:isCharLocked(): boolean
    return self.phase == "waiting"
        and self:isCountdownReady()
        and self.waitingLeft > 0
        and self.waitingLeft <= self.charLockTicks
end

function Room:_send(record, name: string, payload: any)
    if record and record.player then
        Net.send(record.player, name, payload)
    end
end

function Room:_sendAll(name: string, payload: any)
    for _, record in ipairs(self.members) do
        self:_send(record, name, payload)
    end
end

function Room:_refreshWaitingRoster()
    local entries = {}
    for i, record in ipairs(self.seats) do
        if i > self.maxPlayers then
            break
        end
        entries[i] = {
            id = record.id,
            name = record.name,
            isBot = false,
            char = record.char,
            colorIndex = recordColorIndex(record),
            -- Visible to everyone in the room, including spectators. This is the
            -- automatic carry for this room's mode: versus caps stock at the
            -- entry limit, practice carries nothing.
            items = Shop.effectiveCarry(record.profile, self.mode),
        }
    end
    self.roster = entries
    self.rosterById = indexRoster(entries)
end

-- Called by MatchService after a purchase so everyone in the waiting room sees
-- the new stock/carry immediately.
function Room:refreshInventory(): boolean
    if self.phase ~= "waiting" then
        return false
    end
    self:_refreshWaitingRoster()
    self:broadcastState()
    return true
end

function Room:_buildState(record)
    local selectedChar = if record then record.char else Characters.DEFAULT_CHAR
    local charColors = Characters.normalizeColors(if record then record.charColors else nil)
    local selectedColor = Characters.colorOf(charColors, selectedChar)
    local state = {
        phase = self.phase,
        roundId = self.roundId,
        endsIn = 0,
        warmup = 0,
        timeLeft = 0,
        roster = self.roster,
        botFill = 0,
        grid = if self.game then self.game:gridRows() else Grid.gridToRows(Map.buildMap()),
        spawns = Map.SPAWNS,
        tile = Constants.TILE,
        selectedChar = selectedChar,
        selectedColor = selectedColor,
        charColors = charColors,
        inventory = if record then Shop.inventorySummary(record.profile, self.mode) else nil,
        spectating = true,
        charLocked = self:isCharLocked(),
        -- New capability: placement can travel inside the sequenced input
        -- command and is applied on that command's tick. Old clients ignore it;
        -- new clients fall back to Action "place" when it is absent.
        placeSequenced = true,
        roomId = self.id,
        mode = self.mode,
        practice = self.mode == "practice",
        maxPlayers = self.maxPlayers,
        seatCount = #self.seats,
        spectatorCount = self:getSpectatorCount(),
        waitingForPlayers = false,
        roomName = self.name,
        hostId = self.hostId,
        hostName = self:getHostName(),
        hasPassword = self:hasPassword(),
        isHost = record ~= nil and self.hostId == record.id,
    }

    if self.phase == "waiting" then
        state.waitingForPlayers = not self:isCountdownReady()
        state.endsIn = if #self.members > 0 and self:isCountdownReady()
            then math.ceil(self.waitingLeft / Constants.TICK_RATE)
            else 0
        state.botFill = if self.fillBots
            then math.max(0, self.maxPlayers - #self.roster)
            else 0
    elseif self.phase == "playing" then
        state.warmup = if self.game then self.game.warmup else 0
        state.timeLeft = if self.game
            then math.max(0, math.ceil((Constants.ROUND_TICKS - self.game.tickCount) / Constants.TICK_RATE))
            else 0
    elseif self.phase == "ended" then
        state.endsIn = math.max(0, math.ceil(self.resultsLeft / Constants.TICK_RATE))
        state.lastResult = self.lastResult
    end

    if record and self.seatById[record.id] then
        state.yourId = record.id
        state.spectating = false
    end

    return state
end

function Room:sendState(record)
    self:_send(record, "RoundState", self:_buildState(record))
end

function Room:broadcastState()
    for _, record in ipairs(self.members) do
        self:sendState(record)
    end
end

function Room:addMember(record)
    if not record or self.memberById[record.id] then
        return false
    end

    local wantsSeat = self.phase == "waiting" and not self:isFull()
    if not wantsSeat and self:getSpectatorCount() >= self.maxSpectators then
        return false
    end

    table.insert(self.members, record)
    self.memberById[record.id] = record

    if wantsSeat then
        table.insert(self.seats, record)
        self.seatById[record.id] = record
        if self.mode == "versus" and self.hostId == nil then
            self.hostId = record.id
        end
    end

    if self.phase == "waiting" then
        -- Only a new seat changes the countdown/roster. A spectator joining a
        -- full table must not restart the 10 s countdown.
        if wantsSeat then
            self.waitingLeft = self.waitingTicks
            self:_refreshWaitingRoster()
        end
        self:broadcastState()
    else
        -- Joined mid-round/mid-results: receive this room's current state and
        -- subsequent snapshots as a spectator.
        self:sendState(record)
    end
    return true
end

-- Charge one participant's real item use. The callback receives copies so the
-- profile can be updated even though the room is about to reset its game state.
-- Marking first makes this idempotent for round end/leave/shutdown races.
function Room:_settleUsageFor(record, reason: string): boolean
    if not record or not self.game or self.usageSettled[record.id] then
        return false
    end
    local used, carried = self.game:getItemUsage(record.id)
    if not used then
        return false
    end
    self.usageSettled[record.id] = true
    if self.onUsageSettled then
        local context = {
            roomId = self.id,
            mode = self.mode,
            roundId = self.roundId,
            reason = reason,
        }
        local ok, err = pcall(self.onUsageSettled, record, used, carried, context)
        if not ok then
            warn(string.format("[BnB] room %d item settlement failed: %s", self.id, tostring(err)))
        end
    end
    return true
end

-- Settle every participant who has not been charged yet. Used at round end,
-- when a player leaves mid-round, and by BindToClose before profiles are saved.
function Room:settleActiveUsage(reason: string): number
    local count = 0
    for _, record in ipairs(self.roundParticipants) do
        if self:_settleUsageFor(record, reason) then
            count += 1
        end
    end
    return count
end

function Room:removeMember(record)
    if not record or not self.memberById[record.id] then
        return false
    end

    local wasSeated = self.seatById[record.id] ~= nil
    self.memberById[record.id] = nil
    self.inputQueues[record.id] = nil
    for i = #self.members, 1, -1 do
        if self.members[i] == record then
            table.remove(self.members, i)
        end
    end
    if wasSeated then
        self.seatById[record.id] = nil
        for i = #self.seats, 1, -1 do
            if self.seats[i] == record then
                table.remove(self.seats, i)
            end
        end
    end

    -- Host transfer happens before settlement/broadcast so the remaining players
    -- receive the new host and the reset name/password in the same state. A room
    -- with no seats has no host at all.
    local emptiedSeats = wasSeated and #self.seats == 0
    if self.mode == "versus" then
        local wasHost = self.hostId == record.id
        if emptiedSeats or wasHost then
            self:resetConfig()
            if not emptiedSeats and self.seats[1] then
                self.hostId = self.seats[1].id
            end
        elseif self.hostId == nil and self.seats[1] then
            self.hostId = self.seats[1].id
        end
    end

    local finished = false
    if self.phase == "playing" and self.game and self.roundParticipantById[record.id] then
        -- Leaving/disconnecting during a round is a forfeit. The participant is
        -- kept in the round list so settlement can record the loss after the
        -- member itself has been detached. Item use is settled now so a leaver
        -- is not still holding an uncharged remote/needle.
        self.roundLeft[record.id] = true
        self.roundEndReason = "leave"
        self:_settleUsageFor(record, "leave")
        self.game:markDisconnected(record.id)
        self:collectFx()
        if self.game.over then
            self:finishRound()
            finished = true
        end
    elseif self.phase == "waiting" and wasSeated then
        self.waitingLeft = self.waitingTicks
        self:_refreshWaitingRoster()
    end

    if not finished and #self.members > 0 then
        self:broadcastState()
    end
    return true, emptiedSeats
end

function Room:collectFx()
    if not self.game or not self.fxState then
        return
    end

    local events = {}

    -- One event per bomb so the placing client can suppress only the sound of
    -- its own predicted placement, keyed by the ordered command sequence.
    for _, bomb in ipairs(self.game.bombs) do
        if not self.fxState.bombs[bomb.id] then
            self.fxState.bombs[bomb.id] = true
            local event = { kind = "bomb_set", ownerId = bomb.ownerId }
            if type(bomb.seq) == "number" then
                event.seq = bomb.seq
            end
            table.insert(events, event)
        end
    end

    local currentExplosions = {}
    local newExplosion = false
    for _, explosion in ipairs(self.game.explosions) do
        currentExplosions[explosion] = true
        if not self.fxState.explosions[explosion] then
            newExplosion = true
        end
    end
    self.fxState.explosions = currentExplosions
    if newExplosion then
        table.insert(events, { kind = "explode" })
    end

    for _, player in ipairs(self.game.playerOrder) do
        local previous = self.fxState.players[player.id] or allPlayerFx(player)
        if player.alive and #player.eaten > previous.eaten then
            table.insert(events, { kind = "get", playerId = player.id })
        end
        if previous.trapped and not player.trapped and player.alive
            and player.inv.needle < previous.needle then
            table.insert(events, { kind = "save", playerId = player.id })
        end
        if previous.alive and not player.alive then
            table.insert(events, { kind = "role_die", playerId = player.id })
        end
        self.fxState.players[player.id] = allPlayerFx(player)
    end

    if self.fxState.warmup > 0 and self.game.warmup == 0 then
        table.insert(events, { kind = "start" })
    end
    self.fxState.warmup = self.game.warmup

    if #self.members > 0 then
        for _, event in ipairs(events) do
            self:_sendAll("Fx", event)
        end
    end
end

function Room:_resetInputQueues()
    self.inputQueues = {}
end

-- Drain at most one buffered command per participant per simulation tick.
-- Requiring two queued commands keeps jitter from making the server consume a
-- later command too early; the wait timeout guarantees liveness if the client
-- sends slower than 30Hz or a packet is late. Game keeps the previous direction
-- when nothing is applied, which is the same "held key" behavior as before.
function Room:_applyInputCommands()
    if not self.game then
        return
    end
    for id, state in pairs(self.inputQueues) do
        local command = state.queue[1]
        if command then
            command.wait = (command.wait or 0) + 1
            if #state.queue >= Constants.INPUT_BUFFER_TICKS
                or command.wait >= Constants.INPUT_BUFFER_TICKS
            then
                table.remove(state.queue, 1)
                self.game:setInput(id, command.dirs, command.seq, command.place)
            end
        end
    end
end

function Room:_startRound()
    local participants = {}
    local defs = {}
    local usedNames = {}
    local usedColors = {}

    for _, record in ipairs(self.seats) do
        if #participants >= self.maxPlayers then
            break
        end
        table.insert(participants, record)
        usedNames[record.name] = true
        local colorIndex = recordColorIndex(record)
        usedColors[colorIndex] = true
        table.insert(defs, {
            id = record.id,
            name = record.name,
            isBot = false,
            char = record.char,
            colorIndex = colorIndex,
            carry = Shop.effectiveCarry(record.profile, self.mode),
        })
    end

    if #defs == 0 then
        return
    end
    if not self.fillBots and #defs < self.maxPlayers then
        return
    end

    local botCount = if self.fillBots then self.maxPlayers - #defs else 0
    for i = 1, botCount do
        local character = Characters.CHARACTERS[self.random:NextInteger(1, #Characters.CHARACTERS)]
        local colorIndex = nil
        for candidate = 0, Characters.COLOR_COUNT - 1 do
            if not usedColors[candidate] then
                colorIndex = candidate
                break
            end
        end
        if colorIndex == nil then
            colorIndex = (i - 1) % Characters.COLOR_COUNT
        end
        usedColors[colorIndex] = true
        table.insert(defs, {
            id = "bot" .. i,
            name = randomBotName(self.random, usedNames),
            isBot = true,
            char = character.id,
            colorIndex = colorIndex,
        })
    end

    self.roundId += 1
    self.phase = "playing"
    self.waitingLeft = 0
    self.resultsLeft = 0
    self.lastResult = nil
    self.roundParticipants = table.clone(participants)
    self.roundParticipantById = {}
    self.roundActivity = {}
    self.roundLeft = {}
    self.roundNoAction = {}
    self.roundNoActionChecked = false
    self.roundEndReason = nil
    self.usageSettled = {}
    for _, record in ipairs(participants) do
        self.roundParticipantById[record.id] = record
        self.roundActivity[record.id] = false
    end

    self.game = Game.new(defs, {
        random = function()
            return self.random:NextNumber()
        end,
        warmup = Constants.WARMUP_TICKS,
    })
    self.brains = BotService.build(self.game)
    self.roster = buildRoster(defs)
    self.rosterById = indexRoster(self.roster)
    self.fxState = makeFxState(self.game)
    self:_resetInputQueues()
    self.snapshot:reset()
    self:broadcastState()
end

-- Clear round-scoped state without touching members or room configuration.
-- Used both by the normal results -> waiting transition and when a room loses
-- its last seat.
function Room:resetForWaiting()
    -- A round torn down by a recycle/room reset may never reach finishRound.
    -- Settle any remaining participant before the game state is discarded.
    if self.phase == "playing" then
        self:settleActiveUsage("reset")
    end
    self.usageSettled = {}
    self.phase = "waiting"
    self.waitingLeft = self.waitingTicks
    self.resultsLeft = 0
    self.game = nil
    self.brains = {}
    self.lastResult = nil
    self.fxState = nil
    self.roundParticipants = {}
    self.roundParticipantById = {}
    self.roundActivity = {}
    self.roundLeft = {}
    self.roundNoAction = {}
    self.roundNoActionChecked = false
    self.roundEndReason = nil
    self:_resetInputQueues()
    -- A seat opened by a departing player stays open for a new joiner. Existing
    -- spectators remain read-only and are never seated automatically.
    self:_refreshWaitingRoster()
    self.snapshot:reset()
end

function Room:_beginWaiting()
    self:resetForWaiting()
    self:broadcastState()
end

-- Hard reset used when a versus room is recycled after an internal failure. Its
-- members are moved out by MatchService first; the room keeps its registry slot
-- and returns to a clean empty waiting state.
function Room:resetEmpty()
    self.members = {}
    self.memberById = {}
    self.seats = {}
    self.seatById = {}
    self:resetConfig()
    self:resetForWaiting()
end

function Room:finishRound()
    if self.phase ~= "playing" or not self.game then
        return
    end

    local winner = self.game.winner
    local aliveCount = 0
    for _, player in ipairs(self.game.playerOrder) do
        if player.alive then
            aliveCount += 1
        end
    end

    local reason = self.roundEndReason
    if not reason then
        if winner == nil and self.game.tickCount >= Constants.ROUND_TICKS then
            reason = "timeout"
        else
            reason = "elimination"
        end
    end

    self.lastResult = {
        roundId = self.roundId,
        winnerId = if winner then winner.id else nil,
        winnerName = if winner then winner.name else nil,
        winnerChar = if winner then winner.char else nil,
        winnerColorIndex = if winner then winner.colorIndex else nil,
        winnerIsBot = if winner then winner.isBot else false,
        draw = winner == nil,
        duration = math.floor(self.game.tickCount / Constants.TICK_RATE),
        durationTicks = self.game.tickCount,
        aliveCount = aliveCount,
        reason = reason,
    }

    -- Final frame + result only to this room. RoundState below carries the
    -- same result to members that are not in the snapshot audience path.
    self:_sendAll("Snapshot", self.game:snapshot())
    self:_sendAll("RoundEnd", self.lastResult)

    self.phase = "ended"
    self.resultsLeft = self.resultsTicks
    self.snapshot:reset()
    self:broadcastState()

    -- Charge actual item use before the stats/commit hook. Each participant is
    -- charged at most once; someone who left earlier was already settled.
    self:settleActiveUsage("round_end")

    if self.onSettled then
        local participants = table.clone(self.roundParticipants)
        local activity = {}
        local left = {}
        local noAction = {}
        for _, record in ipairs(participants) do
            local acted = self.roundActivity[record.id] == true
            activity[record.id] = acted
            left[record.id] = self.roundLeft[record.id] == true
            noAction[record.id] = not acted
        end
        local context = {
            roomId = self.id,
            mode = self.mode,
            roundId = self.roundId,
            participants = participants,
            activity = activity,
            left = left,
            noAction = noAction,
            durationTicks = self.game.tickCount,
            reason = reason,
        }
        local ok, err = pcall(
            self.onSettled,
            table.clone(self.members),
            self.lastResult,
            context
        )
        if not ok then
            warn(string.format(
                "[BnB] room %d settlement hook failed: %s",
                self.id,
                tostring(err)
            ))
        end
    end
end

function Room:_stepWaiting()
    if #self.members == 0 then
        self.waitingLeft = self.waitingTicks
        return
    end

    -- Versus rooms wait for a full table; practice rooms always have a bot
    -- opponent ready, so one human is enough to start.
    if not self:isCountdownReady() then
        self.waitingLeft = self.waitingTicks
        return
    end

    local before = math.ceil(self.waitingLeft / Constants.TICK_RATE)
    local lockedBefore = self:isCharLocked()
    self.waitingLeft -= 1

    if self.waitingLeft <= 0 then
        self:_startRound()
        return
    end

    local after = math.ceil(self.waitingLeft / Constants.TICK_RATE)
    if after ~= before or self:isCharLocked() ~= lockedBefore then
        self:broadcastState()
    end
end

-- A participant that never sends input/action for the whole no-action window
-- forfeits. When both are idle the round is a draw. Either way the settlement
-- context marks the absent player as no-action, so the game never counts toward
-- versus stats.
function Room:_checkNoAction()
    if self.mode ~= "versus" or self.roundNoActionChecked then
        return
    end
    if self.game.tickCount < Constants.VERSUS_NO_ACTION_TICKS then
        return
    end
    self.roundNoActionChecked = true

    local idle = {}
    local aliveParticipants = 0
    for _, record in ipairs(self.roundParticipants) do
        local player = self.game.players[record.id]
        if player and player.alive and not player.disconnected then
            aliveParticipants += 1
            if self.roundActivity[record.id] ~= true then
                table.insert(idle, record)
            end
        end
    end
    if #idle == 0 then
        return
    end

    self.roundEndReason = "no_action"
    for _, record in ipairs(idle) do
        self.roundNoAction[record.id] = true
    end

    if #idle >= aliveParticipants then
        self.game.over = true
        self.game.winner = nil
        return
    end

    for _, record in ipairs(idle) do
        self.game:markDisconnected(record.id)
    end
    self:collectFx()
end

function Room:_stepPlaying()
    if not self.game then
        self:_beginWaiting()
        return
    end

    if #self.members == 0 then
        return
    end

    -- Apply the buffered human commands for this tick before movement. Bots
    -- still decide directly; only the network input path needs a queue.
    self:_applyInputCommands()

    if self.game.warmup <= 0 then
        BotService.act(self.game, self.brains)
    end

    local ok, err = pcall(self.game.tick, self.game)
    if not ok then
        warn("[BnB] game tick failed: " .. tostring(err))
        self.game.over = true
        self.game.winner = nil
    else
        self:collectFx()
    end

    if not self.game.over then
        self:_checkNoAction()
    end

    if self.game.over then
        self:finishRound()
        return
    end

    if #self.members > 0 then
        self.snapshot:step(self.game, function(snapshot)
            self:_sendAll("Snapshot", snapshot)
        end)
    end
end

function Room:_stepEnded()
    if #self.members == 0 then
        return
    end

    local before = math.ceil(self.resultsLeft / Constants.TICK_RATE)
    self.resultsLeft -= 1

    if self.resultsLeft <= 0 then
        self:_beginWaiting()
        return
    end

    local after = math.ceil(self.resultsLeft / Constants.TICK_RATE)
    if after ~= before then
        self:broadcastState()
    end
end

function Room:step()
    if self.phase == "waiting" then
        self:_stepWaiting()
    elseif self.phase == "playing" then
        self:_stepPlaying()
    elseif self.phase == "ended" then
        self:_stepEnded()
    end
end

function Room:setInput(record, payload)
    if self.phase ~= "playing" or not self.game or type(payload) ~= "table" then
        return
    end
    if not record or not self.memberById[record.id] then
        return
    end

    -- New clients send { seq, roundId, dirs }. An unsequenced plain array is
    -- still accepted so older clients (and direct engine tests) keep their old
    -- immediate behavior; those commands have no ack to reconcile against.
    local sequenced = payload.seq ~= nil or payload.roundId ~= nil
    local dirs = if sequenced then payload.dirs else payload
    if type(dirs) ~= "table" then
        return
    end
    -- A placement request is only meaningful inside the sequenced envelope and
    -- only as a boolean. Old array payloads never place through this path.
    local place = sequenced and payload.place == true

    -- Accept at most four unique legal directions in press order. Game uses
    -- the last entry as the most recently pressed direction.
    local clean = {}
    local seen = {}
    for i = 1, math.min(#dirs, 4) do
        local dir = dirs[i]
        if type(dir) == "string" and VALID_DIRS[dir] and not seen[dir] then
            seen[dir] = true
            table.insert(clean, dir)
        end
    end

    local participant = self.game.players[record.id]
    if not participant then
        return
    end

    if not sequenced then
        if participant.alive and #clean > 0 then
            self.roundActivity[record.id] = true
        end
        self.game:setInput(record.id, clean)
        return
    end

    -- A command from a previous round must never leak into the current one.
    if payload.roundId ~= self.roundId then
        return
    end
    local seq = payload.seq
    if type(seq) ~= "number"
        or seq ~= seq
        or seq == math.huge
        or seq == -math.huge
        or seq % 1 ~= 0
        or seq <= 0
    then
        return
    end

    local state = self.inputQueues[record.id]
    if not state then
        state = { queue = {}, lastQueued = 0 }
        self.inputQueues[record.id] = state
    end
    -- Duplicate/reordered/old commands are ignored. The client sends one
    -- command per 30Hz tick, so strictly increasing seq is the normal case.
    if seq <= state.lastQueued then
        return
    end
    state.lastQueued = seq

    if participant.alive and (#clean > 0 or place) then
        self.roundActivity[record.id] = true
    end

    table.insert(state.queue, { seq = seq, dirs = clean, place = place })
    if #state.queue > Constants.INPUT_QUEUE_LIMIT then
        table.remove(state.queue, 1)
    end
end

function Room:action(record, action: string)
    if self.phase ~= "playing" or not self.game then
        return
    end
    if not record or not self.memberById[record.id] then
        return
    end
    -- Spectators are room members but never round participants; ignore their
    -- input entirely so reading the match cannot affect it.
    if not self.roundParticipantById[record.id] then
        return
    end
    if action == "place" then
        self.roundActivity[record.id] = true
        self.game:placeBomb(record.id, false)
    elseif action == "use" then
        self.roundActivity[record.id] = true
        self.game:useItem(record.id)
    end
end

function Room:selectChar(record, charId: string): boolean
    if self.phase ~= "waiting" or not record or not self.memberById[record.id] then
        return false
    end
    if self:isCharLocked() then
        return false
    end
    if record.char == charId then
        return true -- already selected: nothing changed, nothing to broadcast
    end
    if not PlayerService.setChar(record.player, charId) then
        return false
    end
    self:_refreshWaitingRoster()
    self:broadcastState()
    return true
end

function Room:selectColor(record, colorKey: string): boolean
    if self.phase ~= "waiting" or not record or not self.memberById[record.id] then
        return false
    end
    if self:isCharLocked() then
        return false
    end
    if Characters.isValidColor(colorKey) and Characters.colorOf(record.charColors, record.char) == colorKey then
        return true -- already selected: nothing changed, nothing to broadcast
    end
    if not PlayerService.setColor(record.player, colorKey) then
        return false
    end
    self:_refreshWaitingRoster()
    self:broadcastState()
    return true
end

function Room:getSync(record)
    if not record or not self.memberById[record.id] then
        return nil
    end
    local state = self:_buildState(record)
    if self.game and self.phase ~= "waiting" then
        state.snapshot = self.game:snapshot(true)
    end
    return state
end

return table.freeze(Room)
