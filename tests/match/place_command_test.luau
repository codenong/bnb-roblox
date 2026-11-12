-- Ordered placement protocol: place travels inside the sequenced input command,
-- is applied on that command's tick before movement, and is confirmed by the
-- bomb's owner+seq in snapshots/Fx. The legacy immediate Action stays available.
local TestLib = require("./testlib")
local check = TestLib.check

local Constants = require("./Constants")
local Grid = require("./Grid")
local Game = require("./Game")
local Room = require("./Room")
local PlayerService = require("./PlayerService")
local Net = require("./Net")

local fxEvents = {}
Net.sendHook = function(_, name, payload)
    if name == "Fx" then
        table.insert(fxEvents, payload)
    end
end
local function clearFx()
    for i = #fxEvents, 1, -1 do
        fxEvents[i] = nil
    end
end
local function bombFx()
    -- Net.sendHook sees one call per recipient; collapse identical events so the
    -- assertions count bomb_set events, not audience size.
    local result = {}
    local seen = {}
    for _, event in ipairs(fxEvents) do
        if event.kind == "bomb_set" then
            local key = tostring(event.ownerId) .. ":" .. tostring(event.seq)
            if not seen[key] then
                seen[key] = true
                table.insert(result, event)
            end
        end
    end
    return result
end

local nextUserId = 9700
local nextRoomId = 710

local function emptyRows()
    local rows = {}
    for y = 1, Constants.ROWS do
        rows[y] = string.rep(".", Constants.COLS)
    end
    return rows
end

local function addRecord(name)
    nextUserId += 1
    return PlayerService.add({
        UserId = nextUserId,
        DisplayName = name,
    })
end

-- A practice room always needs a second participant or Game:checkOver ends the
-- round (the match build's bot is inert, so one human + one bot is enough).
local function makeRoom(members: number?, maxPlayers: number?)
    nextRoomId += 1
    local room = Room.new({
        id = nextRoomId,
        mode = "practice",
        maxPlayers = maxPlayers or 2,
        fillBots = true,
        waitingTicks = 1,
        resultsTicks = 4,
    })
    local records = {}
    for i = 1, (members or 1) do
        local record = addRecord("Place" .. tostring(nextRoomId) .. "_" .. tostring(i))
        room:addMember(record)
        records[i] = record
    end
    room:step()
    check("the placement test round started", room:getPhase() == "playing", room:getPhase())
    room.game.warmup = 0
    room.game.grid = Grid.rowsToGrid(emptyRows())
    room.game.items = {}
    room.game.lootShots = {}
    room.game.crateSlides = {}
    clearFx()
    return room, records
end

local function findBomb(room, seq)
    for _, bomb in ipairs(room.game.bombs) do
        if bomb.seq == seq then
            return bomb
        end
    end
    return nil
end

local function payload(room, seq, dirs, place)
    return {
        seq = seq,
        roundId = room.roundId,
        dirs = dirs or {},
        place = place,
    }
end

---------------------------------------------------------------- 移动前放置 / 协议字段

do
    local room, records = makeRoom(1)
    local alice = records[1]
    local state = room:getSync(alice)
    check("RoundState advertises ordered placement", state.placeSequenced == true,
        state.placeSequenced)

    local player = room.game.players[alice.id]
    -- One tick moves 4.8px, so 78 -> 82.8 crosses from tile 1 to tile 2. The
    -- bomb must stay on the pre-move tile.
    player.x = 78
    player.y = 60

    room:setInput(alice, payload(room, 1, { "right" }, true))
    check("placement is not applied on arrival", #room.game.bombs == 0)
    room:step()
    check("the first buffered tick does not apply the command",
        player.ack == 0 and #room.game.bombs == 0)
    room:step()

    check("the command's tick advances the ack", player.ack == 1, player.ack)
    check("the command's tick creates the bomb", #room.game.bombs == 1)
    local bomb = room.game.bombs[1]
    check("placement uses the pre-move tile", bomb and bomb.tx == 1 and bomb.ty == 1,
        bomb and (tostring(bomb.tx) .. "," .. tostring(bomb.ty)))
    check("the player then moves normally", player.x > 80, player.x)
    check("the bomb carries the command sequence", bomb and bomb.seq == 1, bomb and bomb.seq)

    local snapshot = room.game:snapshot()
    local entry = snapshot.bombs[1]
    check("the snapshot serializes the bomb sequence", entry and entry.seq == 1,
        entry and entry.seq)
    check("the snapshot keeps the owner", entry and entry.owner == alice.id)

    local fx = bombFx()
    check("one bomb_set event is emitted", #fx == 1, #fx)
    check("the Fx event names the owner and sequence",
        fx[1] and fx[1].ownerId == alice.id and fx[1].seq == 1,
        fx[1] and (tostring(fx[1].ownerId) .. ":" .. tostring(fx[1].seq)))
end

---------------------------------------------------------------- 只有放置、没有方向也有效

do
    local room, records = makeRoom(1)
    local alice = records[1]
    local player = room.game.players[alice.id]

    room:setInput(alice, payload(room, 1, {}, true))
    check("place counts as round activity", room.roundActivity[alice.id] == true)
    room:step()
    room:step()
    check("an empty-direction placement still advances the ack", player.ack == 1, player.ack)
    check("an empty-direction placement still creates a bomb", #room.game.bombs == 1)
    check("the player has no movement direction", #player.dirs == 0)
end

---------------------------------------------------------------- 只有布尔 true 才能放置

do
    local room, records = makeRoom(1)
    local alice = records[1]
    local player = room.game.players[alice.id]

    room:setInput(alice, payload(room, 1, {}, 1))
    room:setInput(alice, payload(room, 2, {}, "true"))
    room:setInput(alice, payload(room, 3, {}, { yes = true }))
    local queued = room.inputQueues[alice.id].queue
    check("non-boolean place values are ignored",
        queued[1] and queued[1].place == false
            and queued[2].place == false
            and queued[3].place == false)
    for _ = 1, 6 do
        room:step()
    end
    check("all three commands are acknowledged", player.ack == 3, player.ack)
    check("none of them places a bomb", #room.game.bombs == 0, #room.game.bombs)
end

---------------------------------------------------------------- 服务器拒绝时 ack 仍前进

do
    -- Warmup.
    local room, records = makeRoom(1)
    local alice = records[1]
    local player = room.game.players[alice.id]
    room.game.warmup = 5
    room:setInput(alice, payload(room, 1, {}, true))
    room:step()
    room:step()
    check("a warmup placement is rejected but acknowledged",
        player.ack == 1 and #room.game.bombs == 0,
        tostring(player.ack) .. ":" .. tostring(#room.game.bombs))

    -- Same tile already occupied by the player's own bomb.
    local sameRoom, sameRecords = makeRoom(1)
    local sameAlice = sameRecords[1]
    local samePlayer = sameRoom.game.players[sameAlice.id]
    sameRoom:setInput(sameAlice, payload(sameRoom, 1, {}, true))
    sameRoom:step()
    sameRoom:step()
    check("the first bomb exists", #sameRoom.game.bombs == 1)
    sameRoom:setInput(sameAlice, payload(sameRoom, 2, {}, true))
    sameRoom:step()
    sameRoom:step()
    check("a same-tile placement is rejected but acknowledged",
        samePlayer.ack == 2 and #sameRoom.game.bombs == 1,
        tostring(samePlayer.ack) .. ":" .. tostring(#sameRoom.game.bombs))

    -- Max bombs: move off the first bomb's tile without spending a command.
    local capRoom, capRecords = makeRoom(1)
    local capAlice = capRecords[1]
    local capPlayer = capRoom.game.players[capAlice.id]
    capRoom:setInput(capAlice, payload(capRoom, 1, {}, true))
    capRoom:step()
    capRoom:step()
    check("the cap test bomb exists", #capRoom.game.bombs == 1)
    capPlayer.x = 140
    capPlayer.y = 60
    capRoom:setInput(capAlice, payload(capRoom, 2, {}, true))
    capRoom:step()
    capRoom:step()
    check("the max-bomb placement is rejected but acknowledged",
        capPlayer.ack == 2 and #capRoom.game.bombs == 1,
        tostring(capPlayer.ack) .. ":" .. tostring(#capRoom.game.bombs))
end

-- Direct engine checks for states that would otherwise end the room round.
do
    local function freshGame()
        return Game.new({
            { id = "u1", name = "U1", char = "baobao" },
        }, { warmup = 0 })
    end

    for _, state in ipairs({ "dead", "trapped" }) do
        local game = freshGame()
        local player = game.players.u1
        if state == "dead" then
            player.alive = false
        else
            player.trapped = true
        end
        game:setInput("u1", {}, 1, true)
        check(("a %s player still advances the ack"):format(state), player.ack == 1,
            player.ack)
        check(("a %s player places nothing"):format(state), #game.bombs == 0)
    end

    -- A remote already out means place detonates it instead of placing a normal
    -- bomb; no new bomb carries the command sequence.
    local game = freshGame()
    local player = game.players.u1
    player.inv.remote = 1
    check("the remote bomb was created", game:placeBomb("u1", true) == true)
    local before = #game.bombs
    game:setInput("u1", {}, 7, true)
    check("place with a remote out still advances the ack", player.ack == 7, player.ack)
    check("place with a remote out creates no normal bomb", #game.bombs == before)
    check("the existing remote bomb is detonated", game.bombs[1].fuse == 0,
        game.bombs[1].fuse)
    check("the remote bomb has no sequence", game.bombs[1].seq == nil)
end

---------------------------------------------------------------- 旧 Action 回退

do
    local room, records = makeRoom(1)
    local alice = records[1]
    local before = #room.game.bombs
    room:action(alice, "place")
    check("the legacy action places immediately", #room.game.bombs == before + 1)
    local bomb = room.game.bombs[#room.game.bombs]
    check("the legacy bomb has no sequence", bomb.seq == nil, bomb.seq)
    check("the legacy action counts as round activity",
        room.roundActivity[alice.id] == true)

    room:step()
    local snapshot = room.game:snapshot()
    check("the legacy snapshot bomb has no sequence", snapshot.bombs[#snapshot.bombs].seq == nil)
    local fx = bombFx()
    check("the legacy Fx event has no sequence",
        #fx >= 1 and fx[#fx].ownerId == alice.id and fx[#fx].seq == nil,
        fx[#fx] and tostring(fx[#fx].seq))
end

---------------------------------------------------------------- 同一 tick 的多个泡泡各发一条 Fx

do
    local room, records = makeRoom(2, 2)
    local alice, bob = records[1], records[2]
    room:setInput(alice, payload(room, 1, {}, true))
    room:setInput(bob, payload(room, 1, {}, true))
    room:step()
    room:step()

    check("both players' bombs were created", #room.game.bombs == 2, #room.game.bombs)
    local fx = bombFx()
    check("each new bomb gets its own Fx event", #fx == 2, #fx)
    local owners = {}
    for _, event in ipairs(fx) do
        owners[event.ownerId] = (owners[event.ownerId] or 0) + 1
        check("a same-tick bomb event keeps its sequence", event.seq == 1, event.seq)
    end
    check("the two events belong to different players",
        owners[alice.id] == 1 and owners[bob.id] == 1)
end

TestLib.finish()
