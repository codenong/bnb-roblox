-- src/server/MatchService.luau
-- Automatic match flow:
--   Waiting (4s, character select) -> Playing (3s warmup) -> Ended (4s) -> ...

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

local MatchService = {}

local rng = Random.new()

local phase = "waiting"
local waitingLeft = Constants.WAITING_TICKS
local resultsLeft = 0
local roundId = 0

local game = nil
local brains = {}
local roster = {}
local rosterById = {}
local lastResult = nil
local fxState = nil

local FIRST = {
    "快乐", "无敌", "闪电", "暴走", "泡泡", "奶茶", "深海",
    "元气", "榴莲", "章鱼", "海盗", "甜心", "蓝莓", "冲锋",
}
local SECOND = {
    "宝宝", "小乖", "战士", "船长", "鱼丸", "果冻", "皮皮",
    "球球", "大侠", "萌新", "骑士", "魔王", "胖胖", "糖豆",
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

local function refreshWaitingRoster()
    local list = PlayerService.list()
    local entries = {}
    for i, record in ipairs(list) do
        if i > Constants.MAX_PLAYERS then
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
    roster = entries
    rosterById = indexRoster(entries)
end

local function randomBotName(used)
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

local function collectFx()
    if not game then
        return
    end

    local events = {}

    local newBomb = false
    for _, bomb in ipairs(game.bombs) do
        if not fxState.bombs[bomb.id] then
            fxState.bombs[bomb.id] = true
            newBomb = true
        end
    end
    if newBomb then
        table.insert(events, { kind = "bomb_set" })
    end

    local currentExplosions = {}
    local newExplosion = false
    for _, explosion in ipairs(game.explosions) do
        currentExplosions[explosion] = true
        if not fxState.explosions[explosion] then
            newExplosion = true
        end
    end
    fxState.explosions = currentExplosions
    if newExplosion then
        table.insert(events, { kind = "explode" })
    end

    for _, player in ipairs(game.playerOrder) do
        local previous = fxState.players[player.id] or allPlayerFx(player)
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
        fxState.players[player.id] = allPlayerFx(player)
    end

    if fxState.warmup > 0 and game.warmup == 0 then
        table.insert(events, { kind = "start" })
    end
    fxState.warmup = game.warmup

    if PlayerService.count() > 0 then
        for _, event in ipairs(events) do
            Net.broadcast("Fx", event)
        end
    end
end

local function buildState(record)
    local state = {
        phase = phase,
        roundId = roundId,
        endsIn = 0,
        warmup = 0,
        timeLeft = 0,
        roster = roster,
        botFill = 0,
        grid = if game then game:gridRows() else Grid.gridToRows(Map.buildMap()),
        spawns = Map.SPAWNS,
        tile = Constants.TILE,
        selectedChar = if record then record.char else Characters.DEFAULT_CHAR,
        spectating = true,
    }

    if phase == "waiting" then
        state.endsIn = if PlayerService.count() > 0
            then math.ceil(waitingLeft / Constants.TICK_RATE)
            else 0
        state.botFill = math.max(0, Constants.MAX_PLAYERS - #roster)
    elseif phase == "playing" then
        state.warmup = if game then game.warmup else 0
        state.timeLeft = if game
            then math.max(0, math.ceil((Constants.ROUND_TICKS - game.tickCount) / Constants.TICK_RATE))
            else 0
    elseif phase == "ended" then
        state.endsIn = math.max(0, math.ceil(resultsLeft / Constants.TICK_RATE))
        state.lastResult = lastResult
    end

    if record and rosterById[record.id] then
        state.yourId = record.id
        state.spectating = false
    end

    return state
end

local function sendState(record)
    Net.send(record.player, "RoundState", buildState(record))
end

local function broadcastState()
    for _, record in ipairs(PlayerService.list()) do
        sendState(record)
    end
end

local function startRound()
    local participants = {}
    local defs = {}
    local usedNames = {}

    for _, record in ipairs(PlayerService.list()) do
        if #participants >= Constants.MAX_PLAYERS then
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

    local botCount = Constants.MAX_PLAYERS - #participants
    for i = 1, botCount do
        local character = Characters.CHARACTERS[rng:NextInteger(1, #Characters.CHARACTERS)]
        table.insert(defs, {
            id = "bot" .. i,
            name = randomBotName(usedNames),
            isBot = true,
            char = character.id,
        })
    end

    roundId += 1
    phase = "playing"
    waitingLeft = 0
    resultsLeft = 0
    lastResult = nil

    game = Game.new(defs, {
        random = function()
            return rng:NextNumber()
        end,
        warmup = Constants.WARMUP_TICKS,
    })
    brains = BotService.build(game)
    roster = buildRoster(defs)
    rosterById = indexRoster(roster)
    fxState = makeFxState(game)
    SnapshotService.reset()
    broadcastState()
end

local function beginWaiting()
    phase = "waiting"
    waitingLeft = Constants.WAITING_TICKS
    resultsLeft = 0
    game = nil
    brains = {}
    lastResult = nil
    fxState = nil
    refreshWaitingRoster()
    SnapshotService.reset()
    broadcastState()
end

local function finishRound()
    if phase ~= "playing" or not game then
        return
    end

    local winner = game.winner
    local aliveCount = 0
    for _, player in ipairs(game.playerOrder) do
        if player.alive then
            aliveCount += 1
        end
    end

    lastResult = {
        roundId = roundId,
        winnerId = if winner then winner.id else nil,
        winnerName = if winner then winner.name else nil,
        winnerChar = if winner then winner.char else nil,
        winnerColorIndex = if winner then winner.colorIndex else nil,
        winnerIsBot = if winner then winner.isBot else false,
        draw = winner == nil,
        duration = math.floor(game.tickCount / Constants.TICK_RATE),
        aliveCount = aliveCount,
    }

    Net.broadcast("Snapshot", game:snapshot())
    Net.broadcast("RoundEnd", lastResult)

    phase = "ended"
    resultsLeft = Constants.RESULTS_TICKS
    SnapshotService.reset()
    broadcastState()
end

local function stepWaiting()
    if PlayerService.count() == 0 then
        waitingLeft = Constants.WAITING_TICKS
        return
    end

    local before = math.ceil(waitingLeft / Constants.TICK_RATE)
    waitingLeft -= 1

    if waitingLeft <= 0 then
        startRound()
        return
    end

    local after = math.ceil(waitingLeft / Constants.TICK_RATE)
    if after ~= before then
        broadcastState()
    end
end

local function stepPlaying()
    if not game then
        beginWaiting()
        return
    end

    -- No humans left: stop simulating the bot-only match immediately rather
    -- than burning a whole round with nobody watching.
    if PlayerService.count() == 0 then
        beginWaiting()
        return
    end

    if game.warmup <= 0 then
        BotService.act(game, brains)
    end

    local ok, err = pcall(game.tick, game)
    if not ok then
        warn("[BnB] game tick failed: " .. tostring(err))
        game.over = true
        game.winner = nil
    else
        collectFx()
    end

    if game.over then
        finishRound()
        return
    end

    if PlayerService.count() > 0 then
        SnapshotService.step(game)
    end
end

local function stepEnded()
    local before = math.ceil(resultsLeft / Constants.TICK_RATE)
    resultsLeft -= 1

    if resultsLeft <= 0 then
        beginWaiting()
        return
    end

    local after = math.ceil(resultsLeft / Constants.TICK_RATE)
    if after ~= before then
        broadcastState()
    end
end

function MatchService.init()
    beginWaiting()
end

function MatchService.step()
    if phase == "waiting" then
        stepWaiting()
    elseif phase == "playing" then
        stepPlaying()
    elseif phase == "ended" then
        stepEnded()
    end
end

function MatchService.onPlayerAdded(player: Player)
    local record = PlayerService.get(player)
    if not record then
        return
    end

    if phase == "waiting" then
        waitingLeft = Constants.WAITING_TICKS
        refreshWaitingRoster()
        broadcastState()
    else
        sendState(record)
    end
end

function MatchService.onPlayerRemoving(_player: Player, record)
    if not record then
        return
    end

    if phase == "waiting" then
        waitingLeft = Constants.WAITING_TICKS
        refreshWaitingRoster()
        broadcastState()
    elseif phase == "playing" and game and rosterById[record.id] then
        game:markDisconnected(record.id)
        if PlayerService.count() == 0 then
            beginWaiting()
            return
        end
        collectFx()
        if game.over then
            finishRound()
        end
    end
end

local VALID_DIRS = {
    up = true,
    down = true,
    left = true,
    right = true,
}

function MatchService.setInput(player: Player, dirs)
    if phase ~= "playing" or not game or type(dirs) ~= "table" then
        return
    end
    local record = PlayerService.get(player)
    if not record then
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

    local participant = game.players[record.id]
    if participant and participant.alive then
        game:setInput(record.id, clean)
    end
end

function MatchService.action(player: Player, action: string)
    if phase ~= "playing" or not game then
        return
    end
    local record = PlayerService.get(player)
    if not record then
        return
    end
    if action == "place" then
        game:placeBomb(record.id, false)
    elseif action == "use" then
        game:useItem(record.id)
    end
end

function MatchService.selectChar(player: Player, charId: string): boolean
    if phase ~= "waiting" then
        return false
    end
    if not PlayerService.setChar(player, charId) then
        return false
    end
    refreshWaitingRoster()
    broadcastState()
    return true
end

function MatchService.getSync(player: Player)
    local record = PlayerService.get(player)
    if not record then
        return nil
    end
    local state = buildState(record)
    if game and phase ~= "waiting" then
        state.snapshot = game:snapshot(true)
    end
    return state
end

return table.freeze(MatchService)
