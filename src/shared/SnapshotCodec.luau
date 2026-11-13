-- src/shared/SnapshotCodec.luau
-- Stateless zip/unzip for the 20Hz Snapshot stream ("打包/解包").
--
-- Game:snapshot() builds the full logical snapshot table (the same shape the
-- client has always received). pack() turns it into one compact binary buffer
-- per frame; the Room sends that buffer to every member over the Snapshot
-- remote. unpack() on the client restores the exact same logical table, so
-- Interpolation, Prediction and Hud keep working unchanged. RemoteEvent
-- transfers buffers byte-for-byte, so buffer.byteLength of the packed frame is
-- what actually crosses the network.
--
-- The codec is stateless: every frame is self-contained, there is no delta
-- baseline to lose, no per-member state, and no re-sync path. RoundState and
-- the GetSync answer keep carrying raw tables (they are one-off full states).
--
-- Frame layout (little-endian via the buffer API):
--   u8  version (3)
--   u8  flags: bit0 = grid present
--   u32 tick
--   u16 warmup, u16 timeLeft
--   players:  u8 count; per player:
--     id (u8 kind: 1 = u32 number, 2 = u8-len string)
--     u16 x, u16 y (pixels)        u16 fx*10, u16 fy*10 (0.1px sub-pixel)
--     u32 ack                      u8 flags: alive | trapped<<1 | kick<<2
--     mount (u8 len, 0 = nil)      u16 speed*10
--     u8 maxBombs, u8 range, u8 inv.needle, u8 inv.remote
--     u8 dir: 0 = nil, 1 = up, 2 = down, 3 = left, 4 = right (lastMoveDir)
--   bombs:    u8 count; per bomb:
--     u16 id, u8 x, u8 y (tiles), u16 sx*10, u16 sy*10, u16 fuse,
--     u8 flags: remote<<0, owner id, seq (u8 present + u32, absent = nil),
--     pass list (u8 count + ids)
--   expl:     u8 count; per explosion: u16 id, u8 ttl, cells (u8 count + u8x,u8y)
--   items:    u8 count; per item: u8 x, u8 y, kind (u8-len string)
--   loot:     u8 count; per shot: kind, u16 x0,y0,x1,y1 (pixels), u16 left, u16 total
--   slides:   u8 count; per slide: u16 fx*10, u16 fy*10, u8 tx, u8 ty, u16 left, u16 total
--   grid:     u32 gridVer, u8 rows; per row: u8 len + bytes (row strings from
--             Grid.gridToRows). gridVer is the monotonic map version the
--             gridVer sync rides on: Game:snapshot() attaches it together with
--             the grid rows, so it is encoded verbatim whenever the grid is
--             present (a nil gridVer packs as 0).
--
-- Sub-pixel values are the 0.1-precision numbers Game:snapshot() already
-- produces, so *10 with rounding is lossless. A nil mount (and nil bomb seq)
-- is encoded as absent; the decoded table simply omits the key, which is
-- exactly what a table with a nil-valued key looks like in Luau.

local SnapshotCodec = {}

SnapshotCodec.VERSION = 3

local KIND_NUMBER = 1
local KIND_STRING = 2

-- Last movement direction (player.lastMoveDir) drives the shared turn buffer
-- and release glide; without it a reconciled client would replay differently
-- from the server. 0 encodes nil (player has not moved yet).
local DIR_CODES = { up = 1, down = 2, left = 3, right = 4 }
local DIR_NAMES = { [1] = "up", [2] = "down", [3] = "left", [4] = "right" }

local SCRATCH_BYTES = 16384

local function isBuffer(v)
    -- typeof() returns "buffer" for the buffer type on both Roblox and the
    -- Luau CLI (type() differs between them), so typeof is the portable check.
    return typeof(v) == "buffer"
end

---------------------------------------------------------------- 打包

local function writeId(buf, off, id)
    local t = type(id)
    if t == "number" then
        buffer.writeu8(buf, off, KIND_NUMBER)
        buffer.writeu32(buf, off + 1, id)
        return off + 5
    elseif t == "string" then
        buffer.writeu8(buf, off, KIND_STRING)
        buffer.writeu8(buf, off + 1, #id)
        buffer.writestring(buf, off + 2, id)
        return off + 2 + #id
    end
    error("snapshot id must be a number or string, got " .. t)
end

local function writeString(buf, off, value)
    buffer.writeu8(buf, off, #value)
    buffer.writestring(buf, off + 1, value)
    return off + 1 + #value
end

local function packPlayers(buf, off, players)
    buffer.writeu8(buf, off, #players)
    off += 1
    for _, p in ipairs(players) do
        off = writeId(buf, off, p.id)
        buffer.writeu16(buf, off, p.x)
        buffer.writeu16(buf, off + 2, p.y)
        buffer.writeu16(buf, off + 4, math.floor(p.fx * 10 + 0.5))
        buffer.writeu16(buf, off + 6, math.floor(p.fy * 10 + 0.5))
        buffer.writeu32(buf, off + 8, p.ack)
        buffer.writeu8(buf, off + 12,
            (p.alive and 1 or 0) + (p.trapped and 2 or 0) + (p.kick and 4 or 0))
        off += 13
        if p.mount ~= nil then
            buffer.writeu8(buf, off, #p.mount)
            buffer.writestring(buf, off + 1, p.mount)
            off += 1 + #p.mount
        else
            buffer.writeu8(buf, off, 0)
            off += 1
        end
        buffer.writeu16(buf, off, math.floor(p.speed * 10 + 0.5))
        buffer.writeu8(buf, off + 2, p.maxBombs)
        buffer.writeu8(buf, off + 3, p.range)
        buffer.writeu8(buf, off + 4, p.inv and p.inv.needle or 0)
        buffer.writeu8(buf, off + 5, p.inv and p.inv.remote or 0)
        buffer.writeu8(buf, off + 6, if p.dir ~= nil then DIR_CODES[p.dir] or 0 else 0)
        off += 7
    end
    return off
end

local function packBombs(buf, off, bombs)
    buffer.writeu8(buf, off, #bombs)
    off += 1
    for _, b in ipairs(bombs) do
        buffer.writeu16(buf, off, b.id)
        buffer.writeu8(buf, off + 2, b.x)
        buffer.writeu8(buf, off + 3, b.y)
        buffer.writeu16(buf, off + 4, math.floor(b.sx * 10 + 0.5))
        buffer.writeu16(buf, off + 6, math.floor(b.sy * 10 + 0.5))
        buffer.writeu16(buf, off + 8, b.fuse)
        buffer.writeu8(buf, off + 10, b.remote and 1 or 0)
        off += 11
        off = writeId(buf, off, b.owner)
        if b.seq ~= nil then
            buffer.writeu8(buf, off, 1)
            buffer.writeu32(buf, off + 1, b.seq)
            off += 5
        else
            buffer.writeu8(buf, off, 0)
            off += 1
        end
        buffer.writeu8(buf, off, #b.pass)
        off += 1
        for _, id in ipairs(b.pass) do
            off = writeId(buf, off, id)
        end
    end
    return off
end

local function packExpl(buf, off, expl)
    buffer.writeu8(buf, off, #expl)
    off += 1
    for _, e in ipairs(expl) do
        buffer.writeu16(buf, off, e.id)
        buffer.writeu8(buf, off + 2, e.ttl)
        off += 3
        buffer.writeu8(buf, off, #e.cells)
        off += 1
        for _, cell in ipairs(e.cells) do
            buffer.writeu8(buf, off, cell[1])
            buffer.writeu8(buf, off + 1, cell[2])
            off += 2
        end
    end
    return off
end

local function packItems(buf, off, items)
    buffer.writeu8(buf, off, #items)
    off += 1
    for _, item in ipairs(items) do
        buffer.writeu8(buf, off, item.x)
        buffer.writeu8(buf, off + 1, item.y)
        off = writeString(buf, off + 2, item.kind)
    end
    return off
end

local function packLoot(buf, off, loot)
    buffer.writeu8(buf, off, #loot)
    off += 1
    for _, shot in ipairs(loot) do
        off = writeString(buf, off, shot.kind)
        buffer.writeu16(buf, off, shot.x0)
        buffer.writeu16(buf, off + 2, shot.y0)
        buffer.writeu16(buf, off + 4, shot.x1)
        buffer.writeu16(buf, off + 6, shot.y1)
        buffer.writeu16(buf, off + 8, shot.left)
        buffer.writeu16(buf, off + 10, shot.total)
        off += 12
    end
    return off
end

local function packSlides(buf, off, slides)
    buffer.writeu8(buf, off, #slides)
    off += 1
    for _, s in ipairs(slides) do
        buffer.writeu16(buf, off, math.floor(s.fx * 10 + 0.5))
        buffer.writeu16(buf, off + 2, math.floor(s.fy * 10 + 0.5))
        buffer.writeu8(buf, off + 4, s.tx)
        buffer.writeu8(buf, off + 5, s.ty)
        buffer.writeu16(buf, off + 6, s.left)
        buffer.writeu16(buf, off + 8, s.total)
        off += 10
    end
    return off
end

local function packGrid(buf, off, rows, gridVer)
    buffer.writeu32(buf, off, gridVer or 0)
    buffer.writeu8(buf, off + 4, #rows)
    off += 5
    for _, row in ipairs(rows) do
        off = writeString(buf, off, row)
    end
    return off
end

-- Pack one logical snapshot into a compact buffer. Returns the buffer whose
-- byteLength is the on-network size.
function SnapshotCodec.pack(snapshot)
    local buf = buffer.create(SCRATCH_BYTES)
    local off = 0
    local flags = snapshot.grid ~= nil and 1 or 0
    buffer.writeu8(buf, off, SnapshotCodec.VERSION)
    buffer.writeu8(buf, off + 1, flags)
    buffer.writeu32(buf, off + 2, snapshot.tick)
    buffer.writeu16(buf, off + 6, snapshot.warmup)
    buffer.writeu16(buf, off + 8, snapshot.timeLeft)
    off = 10

    off = packPlayers(buf, off, snapshot.players or {})
    off = packBombs(buf, off, snapshot.bombs or {})
    off = packExpl(buf, off, snapshot.expl or {})
    off = packItems(buf, off, snapshot.items or {})
    off = packLoot(buf, off, snapshot.loot or {})
    off = packSlides(buf, off, snapshot.crateSlides or {})
    if flags == 1 then
        off = packGrid(buf, off, snapshot.grid, snapshot.gridVer)
    end

    -- The scratch buffer is generously sized; copy the used prefix out so the
    -- transmitted buffer's byteLength is the real on-network size.
    local out = buffer.create(off)
    buffer.copy(out, 0, buf, 0, off)
    return out
end

---------------------------------------------------------------- 解包

local function readId(buf, off)
    local kind = buffer.readu8(buf, off)
    if kind == KIND_NUMBER then
        return buffer.readu32(buf, off + 1), off + 5
    elseif kind == KIND_STRING then
        local len = buffer.readu8(buf, off + 1)
        return buffer.readstring(buf, off + 2, len), off + 2 + len
    end
    return nil, off + 1
end

local function readString(buf, off)
    local len = buffer.readu8(buf, off)
    return buffer.readstring(buf, off + 1, len), off + 1 + len
end

local function unpackPlayers(buf, off)
    local count = buffer.readu8(buf, off)
    off += 1
    local players = {}
    for _ = 1, count do
        local p = {}
        p.id, off = readId(buf, off)
        p.x = buffer.readu16(buf, off)
        p.y = buffer.readu16(buf, off + 2)
        p.fx = buffer.readu16(buf, off + 4) / 10
        p.fy = buffer.readu16(buf, off + 6) / 10
        p.ack = buffer.readu32(buf, off + 8)
        local flags = buffer.readu8(buf, off + 12)
        p.alive = bit32.band(flags, 1) == 1
        p.trapped = bit32.band(flags, 2) == 2
        p.kick = bit32.band(flags, 4) == 4
        off += 13
        local mountLen = buffer.readu8(buf, off)
        if mountLen > 0 then
            p.mount = buffer.readstring(buf, off + 1, mountLen)
        end
        off += 1 + mountLen
        p.speed = buffer.readu16(buf, off) / 10
        p.maxBombs = buffer.readu8(buf, off + 2)
        p.range = buffer.readu8(buf, off + 3)
        p.inv = {
            needle = buffer.readu8(buf, off + 4),
            remote = buffer.readu8(buf, off + 5),
        }
        local dirCode = buffer.readu8(buf, off + 6)
        if dirCode ~= 0 then
            p.dir = DIR_NAMES[dirCode]
        end
        off += 7
        table.insert(players, p)
    end
    return players, off
end

local function unpackBombs(buf, off)
    local count = buffer.readu8(buf, off)
    off += 1
    local bombs = {}
    for _ = 1, count do
        local b = {
            id = buffer.readu16(buf, off),
            x = buffer.readu8(buf, off + 2),
            y = buffer.readu8(buf, off + 3),
            sx = buffer.readu16(buf, off + 4) / 10,
            sy = buffer.readu16(buf, off + 6) / 10,
            fuse = buffer.readu16(buf, off + 8),
            remote = buffer.readu8(buf, off + 10) == 1,
        }
        off += 11
        b.owner, off = readId(buf, off)
        if buffer.readu8(buf, off) == 1 then
            b.seq = buffer.readu32(buf, off + 1)
            off += 5
        else
            off += 1
        end
        local pass = {}
        local passCount = buffer.readu8(buf, off)
        off += 1
        for _ = 1, passCount do
            local id
            id, off = readId(buf, off)
            table.insert(pass, id)
        end
        b.pass = pass
        table.insert(bombs, b)
    end
    return bombs, off
end

local function unpackExpl(buf, off)
    local count = buffer.readu8(buf, off)
    off += 1
    local expl = {}
    for _ = 1, count do
        local e = {
            id = buffer.readu16(buf, off),
            ttl = buffer.readu8(buf, off + 2),
        }
        off += 3
        local cells = {}
        local cellCount = buffer.readu8(buf, off)
        off += 1
        for _ = 1, cellCount do
            table.insert(cells, { buffer.readu8(buf, off), buffer.readu8(buf, off + 1) })
            off += 2
        end
        e.cells = cells
        table.insert(expl, e)
    end
    return expl, off
end

local function unpackItems(buf, off)
    local count = buffer.readu8(buf, off)
    off += 1
    local items = {}
    for _ = 1, count do
        local item = {
            x = buffer.readu8(buf, off),
            y = buffer.readu8(buf, off + 1),
        }
        item.kind, off = readString(buf, off + 2)
        table.insert(items, item)
    end
    return items, off
end

local function unpackLoot(buf, off)
    local count = buffer.readu8(buf, off)
    off += 1
    local loot = {}
    for _ = 1, count do
        local shot = {}
        shot.kind, off = readString(buf, off)
        shot.x0 = buffer.readu16(buf, off)
        shot.y0 = buffer.readu16(buf, off + 2)
        shot.x1 = buffer.readu16(buf, off + 4)
        shot.y1 = buffer.readu16(buf, off + 6)
        shot.left = buffer.readu16(buf, off + 8)
        shot.total = buffer.readu16(buf, off + 10)
        off += 12
        table.insert(loot, shot)
    end
    return loot, off
end

local function unpackSlides(buf, off)
    local count = buffer.readu8(buf, off)
    off += 1
    local slides = {}
    for _ = 1, count do
        local s = {
            fx = buffer.readu16(buf, off) / 10,
            fy = buffer.readu16(buf, off + 2) / 10,
            tx = buffer.readu8(buf, off + 4),
            ty = buffer.readu8(buf, off + 5),
            left = buffer.readu16(buf, off + 6),
            total = buffer.readu16(buf, off + 8),
        }
        off += 10
        table.insert(slides, s)
    end
    return slides, off
end

local function unpackGrid(buf, off)
    local gridVer = buffer.readu32(buf, off)
    local count = buffer.readu8(buf, off + 4)
    off += 5
    local rows = {}
    for _ = 1, count do
        local row
        row, off = readString(buf, off)
        table.insert(rows, row)
    end
    return rows, gridVer, off
end

-- Unpack one frame back into the exact logical snapshot table. Returns nil
-- for a foreign version or a truncated/corrupt frame; packing is stateless,
-- so the caller can simply drop such a frame.
function SnapshotCodec.unpack(buf)
    if not isBuffer(buf) then
        return nil
    end

    local ok, result = pcall(function()
        local version = buffer.readu8(buf, 0)
        if version ~= SnapshotCodec.VERSION then
            return nil
        end
        local flags = buffer.readu8(buf, 1)
        local out = {
            tick = buffer.readu32(buf, 2),
            warmup = buffer.readu16(buf, 6),
            timeLeft = buffer.readu16(buf, 8),
        }
        local off = 10

        out.players, off = unpackPlayers(buf, off)
        out.bombs, off = unpackBombs(buf, off)
        out.expl, off = unpackExpl(buf, off)
        out.items, off = unpackItems(buf, off)
        out.loot, off = unpackLoot(buf, off)
        out.crateSlides, off = unpackSlides(buf, off)
        if bit32.band(flags, 1) == 1 then
            out.grid, out.gridVer, off = unpackGrid(buf, off)
        end
        if off ~= buffer.len(buf) then
            return nil -- trailing bytes: treat as corrupt rather than guess
        end
        return out
    end)
    -- A read past the end (truncated/corrupt frame) surfaces as ok == false.
    if not ok then
        return nil
    end
    return result
end

return table.freeze(SnapshotCodec)
