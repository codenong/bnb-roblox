-- Room-level snapshot wire tests: the Room packs every snapshot into one
-- binary buffer per frame, the same buffer goes to every member, and unpacking
-- it restores exactly the logical snapshot Game:snapshot() builds. Packing is
-- stateless, so late joiners, returning members and spectators all work
-- without any baseline or re-sync path.
local TestLib = require("./testlib")
local check = TestLib.check

local Room = require("./Room")
local PlayerService = require("./PlayerService")
local SnapshotCodec = require("./SnapshotCodec")
local Net = require("./Net")

local nextUserId = 9800

local function addRecord(name)
    nextUserId += 1
    return PlayerService.add({
        UserId = nextUserId,
        DisplayName = name,
    })
end

local function deepEqual(a, b)
    if type(a) ~= type(b) then
        return false
    end
    if type(a) ~= "table" then
        return a == b
    end
    local aKeys, bKeys = 0, 0
    for k, v in pairs(a) do
        aKeys += 1
        if not deepEqual(v, b[k]) then
            return false
        end
    end
    for _ in pairs(b) do
        bKeys += 1
    end
    return aKeys == bKeys
end

-- Per-recipient capture of the Snapshot payloads the Room actually sends.
local captured = {} -- [player] = { buffer, ... }

Net.sendHook = function(player, name, payload)
    if name == "Snapshot" then
        captured[player] = captured[player] or {}
        table.insert(captured[player], payload)
    end
end

local function wiresFor(record)
    return captured[record.player] or {}
end

local function lastWire(record)
    local wires = wiresFor(record)
    return wires[#wires]
end

local alice = addRecord("WireAlice")
local room = Room.new({
    id = 611,
    mode = "practice",
    maxPlayers = 2,
    fillBots = true,
    waitingTicks = 1,
    resultsTicks = 4,
})
room:addMember(alice)
room:step()

check("the test round started", room:getPhase() == "playing", room:getPhase())

-- Game:snapshot() consumes the "grid changed" flag as a side effect, so a
-- test-side comparison snapshot is taken with forceGrid and the grid keys are
-- added/removed to mirror what the frame actually carried. gridVer rides with
-- the grid in both Game:snapshot() and the codec, so it mirrors too.
local function expectedFor(decoded)
    local expected = room.game:snapshot(true)
    if decoded == nil or decoded.grid == nil then
        expected.grid = nil
        expected.gridVer = nil
    end
    return expected
end

---------------------------------------------------------------- 帧格式与逐帧对拍

-- Snapshot cadence is 20Hz inside the 30Hz simulation, so a step does not
-- always send. A frame is only comparable against game:snapshot() in the same
-- step it was sent, because the simulation has not advanced since.
local frames = 0
local compared = 0
local packedSizes = {}
for _ = 1, 60 do
    local before = #wiresFor(alice)
    room:step()
    if #wiresFor(alice) > before then
        frames += 1
        local payload = lastWire(alice)
        check("every payload is a buffer", typeof(payload) == "buffer", typeof(payload))
        local decoded = SnapshotCodec.unpack(payload)
        check("every frame unpacks to the exact logical snapshot",
            deepEqual(decoded, expectedFor(decoded)), "mismatch")
        check("the frame is far smaller than the table",
            buffer.len(payload) < 500, tostring(buffer.len(payload)))
        table.insert(packedSizes, buffer.len(payload))
        compared += 1
    end
end

check("the room actually sent snapshot frames", frames >= 5, tostring(frames))

-- gridVer rides with the grid rows: a forced-grid frame must round-trip the
-- exact monotonic map version the gridVer sync depends on.
local forced = SnapshotCodec.pack(room.game:snapshot(true))
local forcedDecoded = SnapshotCodec.unpack(forced)
check("a forced-grid frame carries the current map version",
    forcedDecoded ~= nil and forcedDecoded.grid ~= nil
        and forcedDecoded.gridVer == room.game.gridVer,
    forcedDecoded and tostring(forcedDecoded.gridVer) or "nil frame")
check("a forced-grid frame unpacks to the exact logical snapshot",
    deepEqual(forcedDecoded, expectedFor(forcedDecoded)), "mismatch")

---------------------------------------------------------------- 全员收到同一帧、迟到者免基线

local bob = addRecord("WireBob")
check("a second seat can join mid-round", room:addMember(bob), "refused")
local bobGot, aliceGot = false, false
for _ = 1, 30 do
    room:step()
    bobGot = bobGot or #wiresFor(bob) > 0
    aliceGot = aliceGot or #wiresFor(alice) > 0
    if bobGot and aliceGot then
        break
    end
end
check("the new member received frames too", bobGot, "none")

local bobFrame = lastWire(bob)
local aliceFrame = lastWire(alice)
check("late joiner and existing member get the same bytes",
    bobFrame ~= nil and aliceFrame ~= nil and buffer.len(bobFrame) == buffer.len(aliceFrame),
    "differ")
local bobDecoded = SnapshotCodec.unpack(bobFrame)
check("the late joiner's frame unpacks standalone",
    deepEqual(bobDecoded, expectedFor(bobDecoded)), "mismatch")

---------------------------------------------------------------- GetSync 保持原始表

local syncState = room:getSync(alice)
check("getSync still carries a raw full snapshot",
    syncState ~= nil and type(syncState.snapshot) == "table", typeof(syncState and syncState.snapshot))
check("getSync snapshot includes the grid", syncState.snapshot.grid ~= nil, "no grid")

---------------------------------------------------------------- 离开再回来、观战者

room:removeMember(bob)
room:addMember(bob)
local rejoined = false
for _ = 1, 30 do
    room:step()
    rejoined = #wiresFor(bob) > 0 and lastWire(bob) ~= bobFrame
    if rejoined then
        break
    end
end
check("a returning member receives frames again", rejoined, "none")
local rejoinedDecoded = SnapshotCodec.unpack(lastWire(bob))
check("the returning member's frame unpacks standalone",
    deepEqual(rejoinedDecoded, expectedFor(rejoinedDecoded)), "mismatch")

local cara = addRecord("WireCara")
check("a spectator can join mid-round", room:addMember(cara), "refused")
local caraGot = false
for _ = 1, 30 do
    room:step()
    caraGot = #wiresFor(cara) > 0
    if caraGot then
        break
    end
end
check("the spectator received frames", caraGot, "none")
local caraDecoded = SnapshotCodec.unpack(lastWire(cara))
check("the spectator's frame unpacks standalone",
    deepEqual(caraDecoded, expectedFor(caraDecoded)), "mismatch")

---------------------------------------------------------------- 体积统计

local total = 0
for _, size in ipairs(packedSizes) do
    total += size
end
print(string.format("  room frames captured: %d, avg packed size %d bytes",
    compared, math.floor(total / compared)))
check("typical frames stay small", total / compared < 400, tostring(total / compared))

TestLib.finish()
