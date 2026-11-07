-- Round settlement wiring: a carry snapshot at round start, one settlement per
-- participant, practice gating and the free-first deduction.
-- Loaded by tests/run.sh from tests/build/match.
local TestLib = require("./testlib")
local check = TestLib.check

local Constants = require("./Constants")
local Net = require("./Net")
local PlayerService = require("./PlayerService")
local ProfileSchema = require("./ProfileSchema")
local Room = require("./Room")
local Shop = require("./Shop")

local nextUserId = 20000

local function newPatient(stock, loadout)
    local profile = ProfileSchema.normalize(ProfileSchema.newProfile())
    for itemId, buckets in pairs(stock or {}) do
        profile.inventory[itemId].free = buckets.free or 0
        profile.inventory[itemId].purchased = buckets.purchased or 0
    end
    for itemId, value in pairs(loadout or {}) do
        profile.loadout[itemId] = value
    end
    nextUserId += 1
    return PlayerService.add({
        UserId = nextUserId,
        DisplayName = "P" .. tostring(nextUserId),
    }, profile)
end

local function newRoom(opts)
    opts = opts or {}
    local events = {}
    local room = Room.new({
        id = opts.id or 801,
        mode = opts.mode or "practice",
        maxPlayers = opts.maxPlayers or 2,
        fillBots = opts.fillBots ~= false,
        waitingTicks = 1,
        resultsTicks = 4,
        onUsageSettled = function(record, used, carried, context)
            table.insert(events, {
                record = record,
                used = used,
                carried = carried,
                context = context,
            })
            if Shop.shouldConsume(context.mode, opts.consumeInPractice == true) then
                Shop.settleUsage(record.profile, carried, used)
            end
        end,
    })
    return room, events
end

local function start(room, record)
    room:addMember(record)
    room:step()
    return room.game
end

local function setUsed(room, record, used)
    local player = room.game.players[record.id]
    player.used.needle = used.needle or 0
    player.used.remote = used.remote or 0
    player.used.kick = used.kick or 0
end

---------------------------------------------------------------- 练习模式默认不扣库存

do
    local record = newPatient({
        needle = { free = 1 },
        remote = { purchased = 1 },
        kick = { purchased = 1 },
    }, { needle = 1, remote = 1, kick = 1 })
    local room, events = newRoom({ id = 801 })
    local game = start(room, record)
    check("the round has started", room:getPhase() == "playing", room:getPhase())
    check("the round starts with the effective carry",
        game.players[record.id].inv.needle == 1 and game.players[record.id].inv.remote == 1
            and game.players[record.id].kick == true)

    -- The carry snapshot was taken at round start. Later profile edits must not
    -- rewrite what the player brought into this round.
    record.profile.loadout.needle = 0
    record.profile.inventory.needle.free = 0
    setUsed(room, record, { needle = 1, remote = 1, kick = 1 })
    room:finishRound()

    check("practice still reports actual use", #events == 1, #events)
    local event = events[1]
    check("the settlement context names the room", event.context.roomId == 801)
    check("the settlement context names the mode", event.context.mode == "practice")
    check("the settlement reason is round end", event.context.reason == "round_end")
    check("usage includes every successfully used item",
        event.used.needle == 1 and event.used.remote == 1 and event.used.kick == 1)
    check("the carry snapshot is the round-start value, not the edited profile",
        event.carried.needle == 1 and event.carried.remote == 1 and event.carried.kick == 1)
    check("practice settlement leaves free stock untouched",
        record.profile.inventory.needle.free == 0 and record.profile.inventory.remote.purchased == 1
            and record.profile.inventory.kick.purchased == 1)

    room:finishRound()
    check("a second finish does not settle again", #events == 1, #events)
    check("settleActiveUsage after finish is a no-op", room:settleActiveUsage("duplicate") == 0)
end

---------------------------------------------------------------- 开关打开时练习也真实扣库存

do
    local record = newPatient({
        needle = { free = 1, purchased = 2 },
        kick = { purchased = 1 },
    }, { needle = 2, kick = 1 })
    local room, events = newRoom({ id = 802, consumeInPractice = true })
    start(room, record)
    setUsed(room, record, { needle = 2, remote = 0, kick = 1 })
    room:finishRound()

    check("the enabled switch settles practice", #events == 1, #events)
    check("needle spending takes free stock first",
        record.profile.inventory.needle.free == 0, record.profile.inventory.needle.free)
    check("needle spending then takes purchased stock",
        record.profile.inventory.needle.purchased == 1, record.profile.inventory.needle.purchased)
    check("a successful kick spends the purchased kick",
        record.profile.inventory.kick.purchased == 0, record.profile.inventory.kick.purchased)
end

---------------------------------------------------------------- 对战：地图拾取不超额扣库存

do
    local record = newPatient({
        needle = { free = 1, purchased = 2 },
        remote = { purchased = 1 },
        kick = { purchased = 1 },
    }, { needle = 2, remote = 1, kick = 1 })
    local room, events = newRoom({ id = 803, mode = "versus" })
    start(room, record)
    -- Actual use exceeds the brought copy for needles and remotes: the extra
    -- uses came from map pickups and must not be charged.
    setUsed(room, record, { needle = 5, remote = 3, kick = 1 })
    room:finishRound()

    check("versus always settles", #events == 1, #events)
    check("needle charges at most the carried copy",
        record.profile.inventory.needle.free == 0
            and record.profile.inventory.needle.purchased == 1,
        record.profile.inventory.needle.free .. "/" .. record.profile.inventory.needle.purchased)
    check("remote charges at most the carried copy",
        record.profile.inventory.remote.purchased == 0,
        record.profile.inventory.remote.purchased)
    check("kick charges once", record.profile.inventory.kick.purchased == 0)
    check("idempotent after settlement", room:settleActiveUsage("duplicate") == 0)

    room:resetForWaiting()
    check("reset after settlement does not charge again", #events == 1, #events)
end

---------------------------------------------------------------- 中途离开只结算一次

do
    local record = newPatient({ needle = { purchased = 1 } }, { needle = 1 })
    local room, events = newRoom({ id = 804, mode = "versus" })
    start(room, record)
    setUsed(room, record, { needle = 1 })
    room:removeMember(record)
    check("leaving mid-round settles immediately", #events == 1, #events)
    check("the leave reason is recorded", events[1].context.reason == "leave",
        events[1] and events[1].context.reason)
    check("the leaver is charged once", record.profile.inventory.needle.purchased == 0)

    room:settleActiveUsage("round_end")
    check("round end does not charge the leaver twice", record.profile.inventory.needle.purchased == 0)
    check("no extra settlement was emitted", #events == 1, #events)
end

---------------------------------------------------------------- 重置/回收也会结算，且只结算一次

do
    local record = newPatient({ remote = { purchased = 1 } }, { remote = 1 })
    local room, events = newRoom({ id = 805, consumeInPractice = true })
    start(room, record)
    setUsed(room, record, { remote = 1 })
    room:resetForWaiting()
    check("a reset settles the live round", #events == 1, #events)
    check("the reset reason is recorded", events[1].context.reason == "reset",
        events[1] and events[1].context.reason)
    check("the reset charges the used item", record.profile.inventory.remote.purchased == 0)
    room:resetForWaiting()
    check("a second reset does not charge again", #events == 1 and
        record.profile.inventory.remote.purchased == 0, #events)
end

---------------------------------------------------------------- 等待名单和观战者都看得到实带

do
    local alice = newPatient({ needle = { free = 2 }, kick = { purchased = 1 } },
        { needle = 2, kick = 1 })
    local bob = newPatient({ remote = { purchased = 1 } }, { remote = 1 })
    local cara = newPatient({ needle = { purchased = 1 } }, { needle = 1 })

    local room = Room.new({
        id = 806,
        mode = "versus",
        maxPlayers = 2,
        fillBots = false,
        maxSpectators = Constants.VERSUS_SPECTATORS,
        waitingTicks = Constants.WAITING_TICKS,
    })
    room:addMember(alice)
    room:addMember(bob)
    room:addMember(cara)

    local spectatorState = room:getSync(cara)
    check("the third player is a spectator", spectatorState.spectating == true)
    local byId = {}
    for _, entry in ipairs(spectatorState.roster) do
        byId[entry.id] = entry
    end
    check("a spectator sees Alice's effective carry",
        byId[alice.id].items.needle == 2 and byId[alice.id].items.kick == 1)
    check("a spectator sees Bob's effective carry",
        byId[bob.id].items.remote == 1, byId[bob.id].items.remote)

    alice.profile.loadout.needle = 1
    Net.reset()
    room:refreshLoadouts()
    local refreshed = room:getSync(cara)
    for _, entry in ipairs(refreshed.roster) do
        if entry.id == alice.id then
            check("a loadout edit refreshes the spectator's view", entry.items.needle == 1,
                entry.items.needle)
        end
    end
    check("the refreshed roster is broadcast to every member",
        Net.sentCount(alice, "RoundState") == 1
            and Net.sentCount(bob, "RoundState") == 1
            and Net.sentCount(cara, "RoundState") == 1)
end

TestLib.finish()
