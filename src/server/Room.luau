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

local function buildRoster(defs)
    local result = {}
    for i, def in ipairs(defs) do
        result[i] = {
            id = def.id,
            name = def.name,
            isBot = def.isBot == true,
            char = Characters.getChar(def.char).id,
            colorIndex = i - 1,
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

    -- Members receive this room's state and snapshots. In practice there is
    -- exactly one; versus will add spectators here without changing transport.
    self.members = {}
    self.memberById = {}

    return self
end

function Room:isEmpty(): boolean
    return #self.members == 0
end

function Room:getMemberCount(): number
    return #self.members
end

function Room:getPhase(): string
    return self.phase
end

function Room:getMode(): string
    return self.mode
end

-- True while the waiting countdown is inside its lock window. Not locked when the
-- room is not counting down (e.g. a versus table that is not full yet).
function Room:isCharLocked(): boolean
    return self.phase == "waiting"
        and #self.members > 0
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
    for i, record in ipairs(self.members) do
        if i > self.maxPlayers then
            break
        end
        entries[i] = {
            id = record.id,
            name = record.name,
            isBot = false,
            char = record.char,
            colorIndex = i - 1,
        }
    end
    self.roster = entries
    self.rosterById = indexRoster(entries)
end

function Room:_buildState(record)
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
        selectedChar = if record then record.char else Characters.DEFAULT_CHAR,
        spectating = true,
        charLocked = self:isCharLocked(),
        roomId = self.id,
        mode = self.mode,
        practice = self.mode == "practice",
        maxPlayers = self.maxPlayers,
    }

    if self.phase == "waiting" then
        state.endsIn = if #self.members > 0
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

    if record and self.rosterById[record.id] then
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

    table.insert(self.members, record)
    self.memberById[record.id] = record

    if self.phase == "waiting" then
        self.waitingLeft = self.waitingTicks
        self:_refreshWaitingRoster()
        self:broadcastState()
    else
        -- Joined mid-round/mid-results: receive this room's current state and
        -- subsequent snapshots as a spectator.
        self:sendState(record)
    end
    return true
end

function Room:removeMember(record)
    if not record or not self.memberById[record.id] then
        return false
    end

    self.memberById[record.id] = nil
    for i = #self.members, 1, -1 do
        if self.members[i] == record then
            table.remove(self.members, i)
        end
    end

    local finished = false
    if self.phase == "playing" and self.game and self.rosterById[record.id] then
        self.game:markDisconnected(record.id)
        self:collectFx()
        if self.game.over then
            self:finishRound()
            finished = true
        end
    elseif self.phase == "waiting" then
        self.waitingLeft = self.waitingTicks
        self:_refreshWaitingRoster()
    end

    if not finished and #self.members > 0 then
        self:broadcastState()
    end
    return true
end

function Room:collectFx()
    if not self.game or not self.fxState then
        return
    end

    local events = {}

    local newBomb = false
    for _, bomb in ipairs(self.game.bombs) do
        if not self.fxState.bombs[bomb.id] then
            self.fxState.bombs[bomb.id] = true
            newBomb = true
        end
    end
    if newBomb then
        table.insert(events, { kind = "bomb_set" })
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

function Room:_startRound()
    local participants = {}
    local defs = {}
    local usedNames = {}

    for _, record in ipairs(self.members) do
        if #participants >= self.maxPlayers then
            break
        end
        table.insert(participants, record)
        usedNames[record.name] = true
        table.insert(defs, {
            id = record.id,
            name = record.name,
            isBot = false,
            char = record.char,
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
        table.insert(defs, {
            id = "bot" .. i,
            name = randomBotName(self.random, usedNames),
            isBot = true,
            char = character.id,
        })
    end

    self.roundId += 1
    self.phase = "playing"
    self.waitingLeft = 0
    self.resultsLeft = 0
    self.lastResult = nil

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
    self.snapshot:reset()
    self:broadcastState()
end

function Room:_beginWaiting()
    self.phase = "waiting"
    self.waitingLeft = self.waitingTicks
    self.resultsLeft = 0
    self.game = nil
    self.brains = {}
    self.lastResult = nil
    self.fxState = nil
    self:_refreshWaitingRoster()
    self.snapshot:reset()
    self:broadcastState()
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

    self.lastResult = {
        roundId = self.roundId,
        winnerId = if winner then winner.id else nil,
        winnerName = if winner then winner.name else nil,
        winnerChar = if winner then winner.char else nil,
        winnerColorIndex = if winner then winner.colorIndex else nil,
        winnerIsBot = if winner then winner.isBot else false,
        draw = winner == nil,
        duration = math.floor(self.game.tickCount / Constants.TICK_RATE),
        aliveCount = aliveCount,
    }

    -- Final frame + result only to this room. RoundState below carries the
    -- same result to members that are not in the snapshot audience path.
    self:_sendAll("Snapshot", self.game:snapshot())
    self:_sendAll("RoundEnd", self.lastResult)

    self.phase = "ended"
    self.resultsLeft = self.resultsTicks
    self.snapshot:reset()
    self:broadcastState()

    if self.onSettled then
        local ok, err = pcall(
            self.onSettled,
            table.clone(self.members),
            self.lastResult,
            { roomId = self.id, mode = self.mode, roundId = self.roundId }
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
    if not self.fillBots and #self.members < self.maxPlayers then
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

function Room:_stepPlaying()
    if not self.game then
        self:_beginWaiting()
        return
    end

    if #self.members == 0 then
        return
    end

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

function Room:setInput(record, dirs)
    if self.phase ~= "playing" or not self.game or type(dirs) ~= "table" then
        return
    end
    if not record or not self.memberById[record.id] then
        return
    end

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
    if participant and participant.alive then
        self.game:setInput(record.id, clean)
    end
end

function Room:action(record, action: string)
    if self.phase ~= "playing" or not self.game then
        return
    end
    if not record or not self.memberById[record.id] then
        return
    end
    if action == "place" then
        self.game:placeBomb(record.id, false)
    elseif action == "use" then
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
    if not PlayerService.setChar(record.player, charId) then
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
