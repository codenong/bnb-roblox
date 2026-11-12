-- SnapshotCodec: stateless pack/unzip roundtrips. unpack(pack(s)) must
-- reproduce the exact logical snapshot table Game:snapshot() builds, for
-- hand-built samples and for every tick of a live simulation. buffer.byteLength
-- of the packed frame is the real on-network size.
local TestLib = require("./testlib")
local check = TestLib.check

local Constants = require("./Constants")
local Map = require("./Map")
local Game = require("./Game")
local SnapshotCodec = require("./SnapshotCodec")

local TILE = Constants.TILE
local ROWS, COLS = Constants.ROWS, Constants.COLS

-- Rough per-payload cost model (bytes) for the UNPACKED table: numbers 8,
-- booleans 1, strings 1+len, tables 4 + entries (+ key names). Compared only
-- against the packed frame's exact byteLength to show the shape win.
local function cost(v)
    local t = type(v)
    if t == "number" then
        return 8
    elseif t == "boolean" then
        return 1
    elseif t == "string" then
        return 1 + #v
    elseif t == "table" then
        local sum = 4
        for k, entry in pairs(v) do
            sum += 1 + cost(entry)
            if type(k) == "string" then
                sum += #k
            end
        end
        return sum
    end
    return 0
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

local function roundtrip(full, label)
    local packed = SnapshotCodec.pack(full)
    check(label .. ": pack returns a buffer", typeof(packed) == "buffer", typeof(packed))
    local decoded = SnapshotCodec.unpack(packed)
    check(label .. ": unpack reproduces the full snapshot", deepEqual(decoded, full),
        decoded and "mismatch" or "nil")
    return packed, decoded
end

---------------------------------------------------------------- 样本帧

local function sampleSnapshot()
    return {
        tick = 90,
        warmup = 0,
        timeLeft = 115,
        players = {
            { id = "a", x = 30, y = 40, fx = 30.5, fy = 40.2, ack = 17,
                alive = true, trapped = false, mount = nil, kick = true,
                speed = 3, maxBombs = 2, range = 3,
                inv = { needle = 1, remote = 0 } },
            { id = 2, x = 260, y = 250, fx = 260, fy = 250, ack = 0,
                alive = false, trapped = true, mount = "ufo", kick = false,
                speed = 180, maxBombs = 1, range = 1,
                inv = { needle = 0, remote = 2 } },
        },
        bombs = {
            { id = 3, x = 4, y = 5, sx = 4.3, sy = 5, fuse = 12, remote = false,
                owner = "a", seq = 17, pass = { "a", 2 } },
            { id = 4, x = 9, y = 9, sx = 9, sy = 9, fuse = 9999, remote = true,
                owner = 2, seq = nil, pass = {} },
        },
        expl = { { id = 1, cells = { { 3, 5 }, { 4, 5 }, { 5, 5 } }, ttl = 6 } },
        items = { { x = 2, y = 7, kind = "needle" }, { x = 11, y = 3, kind = "ufo" } },
        loot = { { kind = "coin", x0 = 45, y0 = 45, x1 = 165, y1 = 45, left = 21, total = 24 } },
        crateSlides = { { fx = 260.5, fy = 280, tx = 7, ty = 7, left = 9, total = 12 } },
    }
end

local full0 = sampleSnapshot()
local packed0, decoded0 = roundtrip(full0, "sample")
check("the packed frame is far smaller than the table",
    buffer.len(packed0) < cost(full0) * 0.5,
    tostring(buffer.len(packed0)) .. " vs " .. tostring(cost(full0)))
print(string.format("  sample frame: table model %.0f bytes -> packed %d bytes",
    cost(full0), buffer.len(packed0)))

---------------------------------------------------------------- 可空字段与边界

local nils = sampleSnapshot()
nils.players[2].mount = nil
nils.bombs[2].seq = nil
roundtrip(nils, "nil mount and seq")

local empties = {
    tick = 0, warmup = 90, timeLeft = 180,
    players = {}, bombs = {}, expl = {}, items = {}, loot = {}, crateSlides = {},
}
roundtrip(empties, "all sections empty")

local gridded = sampleSnapshot()
gridded.grid = { "###############", "#.............#", "###############" }
gridded.gridVer = 7
roundtrip(gridded, "frame with grid")
check("a frame without grid stays without grid",
    SnapshotCodec.unpack(SnapshotCodec.pack(sampleSnapshot())).grid == nil, "grid present")
check("a frame without grid stays without gridVer",
    SnapshotCodec.unpack(SnapshotCodec.pack(sampleSnapshot())).gridVer == nil, "gridVer present")
check("a frame with grid keeps the exact rows",
    deepEqual(SnapshotCodec.unpack(SnapshotCodec.pack(gridded)).grid, gridded.grid), "rows differ")
check("a frame with grid keeps the map version",
    SnapshotCodec.unpack(SnapshotCodec.pack(gridded)).gridVer == 7,
    tostring(SnapshotCodec.unpack(SnapshotCodec.pack(gridded)).gridVer))

---------------------------------------------------------------- 损坏与外来帧

check("a foreign version fails cleanly",
    SnapshotCodec.unpack(buffer.fromstring("\x63\x00")) == nil, "decoded")
check("a truncated frame fails cleanly",
    SnapshotCodec.unpack(buffer.fromstring("\x02\x00\x2a")) == nil, "decoded")
check("a non-buffer payload fails cleanly",
    SnapshotCodec.unpack({ tick = 1 }) == nil, "decoded")
local packed = SnapshotCodec.pack(empties)
local padded = buffer.create(buffer.len(packed) + 1)
buffer.copy(padded, 0, packed, 0, buffer.len(packed))
buffer.writeu8(padded, buffer.len(packed), 0)
check("trailing garbage fails cleanly", SnapshotCodec.unpack(padded) == nil, "decoded")

---------------------------------------------------------------- 真实对局逐 tick 对拍

local function defs()
    return {
        { id = "a", name = "A" },
        { id = 2, name = "B" },
    }
end

local game = Game.new(defs(), {
    random = function()
        return 0.99
    end,
    warmup = 0,
})
game.grid[1][4] = Map.EMPTY
game.players.a.x = 1 * TILE + TILE / 2
game.players.a.y = 1 * TILE + TILE / 2

local compared = 0
local totalPacked = 0
local totalTable = 0
local worstPacked = 0

for i = 1, 150 do
    if i % 9 == 0 then
        game:setInput("a", { "right" }, i)
    elseif i % 9 == 4 then
        game:setInput("a", {}, i)
    end
    if i == 12 or i == 40 then
        game:placeBomb("a", false, i)
    end
    game:tick()
    if i % 2 == 0 then
        local full = game:snapshot()
        local packed = SnapshotCodec.pack(full)
        local decoded = SnapshotCodec.unpack(packed)
        compared += 1
        check("simulation tick " .. i .. ": unpack equals the logical snapshot",
            deepEqual(decoded, full), "mismatch")
        totalPacked += buffer.len(packed)
        totalTable += cost(full)
        worstPacked = math.max(worstPacked, buffer.len(packed))
    end
end

check("the simulation actually compared ticks", compared == 75, tostring(compared))
check("bombs and explosions cycled through the chain", game.tickCount == 150,
    tostring(game.tickCount))
print(string.format("  live 1v1 frames: table model %.0f bytes -> packed avg %d bytes (worst %d)",
    totalTable / compared, math.floor(totalPacked / compared), worstPacked))
check("packed frames stay well below the unpacked model",
    totalPacked / compared < totalTable / compared * 0.5, "too big")

TestLib.finish()
