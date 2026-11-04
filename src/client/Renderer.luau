-- src/client/Renderer.luau
-- ScreenGui renderer for the Snapshot stream. Uses BnB sheets when uploaded
-- and clear colored shapes when AssetIds is still empty.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local Sprites = require(Shared:WaitForChild("Sprites"))
local AssetIds = require(Shared:WaitForChild("AssetIds"))

local Board = require(script.Parent:WaitForChild("Board"))

local T = Constants.TILE
local VISUAL_DY = Constants.VISUAL_DY
local H = T * 1.3

local Renderer = {}

local board: Frame
local rosterById = {}
local yourId = nil

local itemPool = { byKey = {}, free = {} }
local bombPool = { byKey = {}, free = {} }
local explosionPool = { byKey = {}, free = {} }
local lootPool = { byKey = {}, free = {} }
local slidePool = { byKey = {}, free = {} }
local playerPool = { byKey = {}, free = {} }

local deathEffects = {}
local deathAll = {}
local deathFree = {}

local faces = {}
local lastPositions = {}
local lastMoveAt = {}
local trapAt = {}

local ITEM_FALLBACK = {
    bubble = { text = "泡", color = Color3.fromRGB(56, 189, 248) },
    potion = { text = "力", color = Color3.fromRGB(139, 92, 246) },
    shoe = { text = "鞋", color = Color3.fromRGB(34, 197, 94) },
    gremlin = { text = "紫", color = Color3.fromRGB(168, 85, 247) },
    devil = { text = "红", color = Color3.fromRGB(239, 68, 68) },
    kick = { text = "踢", color = Color3.fromRGB(14, 165, 233) },
    needle = { text = "针", color = Color3.fromRGB(250, 204, 21) },
    remote = { text = "遥", color = Color3.fromRGB(251, 146, 60) },
    turtle = { text = "龟", color = Color3.fromRGB(22, 163, 74) },
    owl = { text = "鹰", color = Color3.fromRGB(180, 83, 9) },
    ufo = { text = "碟", color = Color3.fromRGB(100, 116, 139) },
    pirateTurtle = { text = "龟", color = Color3.fromRGB(220, 38, 38) },
}

local function asset(key: string): string
    return AssetIds[key] or ""
end

local function teamColor(colorIndex: number): Color3
    local key = Sprites.teamKey(colorIndex or 0)
    local hex = Constants.TEAM_HEX[key] or "#ffffff"
    return Color3.fromRGB(
        tonumber(string.sub(hex, 2, 3), 16) or 255,
        tonumber(string.sub(hex, 4, 5), 16) or 255,
        tonumber(string.sub(hex, 6, 7), 16) or 255
    )
end

local function setZRecursive(root: GuiObject, z: number)
    root.ZIndex = z
    for _, child in ipairs(root:GetDescendants()) do
        if child:IsA("GuiObject") then
            child.ZIndex = z
        end
    end
end

local function addCorner(gui: GuiObject, radius: number)
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(radius, 0)
    corner.Parent = gui
    return corner
end

local function addStroke(gui: GuiObject, color: Color3, thickness: number, transparency: number?)
    local stroke = Instance.new("UIStroke")
    stroke.Color = color
    stroke.Thickness = thickness
    stroke.Transparency = transparency or 0
    stroke.Parent = gui
    return stroke
end

local function newRoot(name: string, parent: Instance): Frame
    local root = Instance.new("Frame")
    root.Name = name
    root.BackgroundTransparency = 1
    root.BorderSizePixel = 0
    root.Size = UDim2.fromOffset(0, 0)
    root.Position = UDim2.fromOffset(0, 0)
    root.ClipsDescendants = false
    root.Parent = parent
    return root
end

local function newImage(parent: Instance, name: string): ImageLabel
    local image = Instance.new("ImageLabel")
    image.Name = name
    image.BackgroundTransparency = 1
    image.BorderSizePixel = 0
    image.AnchorPoint = Vector2.new(0.5, 0.5)
    image.Position = UDim2.fromOffset(0, 0)
    image.Size = UDim2.fromOffset(40, 40)
    image.ScaleType = Enum.ScaleType.Stretch
    image.Visible = false
    image.Parent = parent
    return image
end

local function newText(
    parent: Instance,
    name: string,
    text: string,
    color: Color3,
    textSize: number
): TextLabel
    local label = Instance.new("TextLabel")
    label.Name = name
    label.BackgroundTransparency = 1
    label.BorderSizePixel = 0
    label.AnchorPoint = Vector2.new(0.5, 0.5)
    label.Position = UDim2.fromOffset(0, 0)
    label.Size = UDim2.fromOffset(40, 40)
    label.Font = Enum.Font.GothamBold
    label.Text = text
    label.TextColor3 = color
    label.TextSize = textSize
    label.TextStrokeColor3 = Color3.fromRGB(10, 25, 36)
    label.TextStrokeTransparency = 0.45
    label.Visible = false
    label.Parent = parent
    return label
end

local function newBadge(
    parent: Instance,
    name: string,
    text: string,
    color: Color3,
    size: number,
    textSize: number
): TextLabel
    local label = newText(parent, name, text, Color3.fromRGB(255, 255, 255), textSize)
    label.BackgroundColor3 = color
    label.BackgroundTransparency = 0.05
    label.Size = UDim2.fromOffset(size, size)
    addCorner(label, 0.5)
    addStroke(label, Color3.fromRGB(255, 255, 255), 1.5, 0.55)
    return label
end

local function setImageRect(image: ImageLabel, id: string, fw: number, fh: number, col: number, row: number)
    image.Image = id
    image.ImageRectSize = Vector2.new(fw, fh)
    image.ImageRectOffset = Vector2.new(col * fw, row * fh)
    image.Visible = true
end

local function setFullImage(image: ImageLabel, id: string)
    image.Image = id
    image.ImageRectSize = Vector2.zero
    image.ImageRectOffset = Vector2.zero
    image.Visible = true
end

local function acquire(pool, key: string, create)
    local unit = pool.byKey[key]
    if not unit then
        local count = #pool.free
        if count > 0 then
            unit = pool.free[count]
            pool.free[count] = nil
        else
            unit = create()
        end
        pool.byKey[key] = unit
    end
    unit.root.Visible = true
    return unit
end

local function sweep(pool, seen)
    local stale = {}
    for key in pairs(pool.byKey) do
        if not seen[key] then
            table.insert(stale, key)
        end
    end
    for _, key in ipairs(stale) do
        local unit = pool.byKey[key]
        pool.byKey[key] = nil
        unit.root.Visible = false
        table.insert(pool.free, unit)
    end
end

local function releasePool(pool)
    for _, unit in pairs(pool.byKey) do
        unit.root.Visible = false
        table.insert(pool.free, unit)
    end
    pool.byKey = {}
end

---------------------------------------------------------------- 道具图标

local function createItemUnit()
    local root = newRoot("Item", board)
    local shadow = Instance.new("Frame")
    shadow.BackgroundColor3 = Color3.fromRGB(8, 19, 28)
    shadow.BackgroundTransparency = 0.65
    shadow.BorderSizePixel = 0
    shadow.AnchorPoint = Vector2.new(0.5, 0.5)
    shadow.Position = UDim2.fromOffset(0, 9)
    shadow.Size = UDim2.fromOffset(28, 7)
    shadow.ZIndex = 1
    shadow.Parent = root
    addCorner(shadow, 0.5)

    local image = newImage(root, "Icon")
    local fallback = newBadge(root, "Fallback", "", Color3.fromRGB(56, 189, 248), 24, 14)
    return { root = root, shadow = shadow, image = image, fallback = fallback }
end

local function setItemVisual(image: ImageLabel, fallback: TextLabel, kind: string, now: number)
    local sprite = Sprites.ITEMS[kind]
    local id = if sprite then asset(sprite.assetKey) else ""
    if sprite and id ~= "" then
        local frame = math.floor(now / 0.24) % math.max(1, sprite.frames)
        image.Size = UDim2.fromOffset(sprite.displayWidth, sprite.displayWidth * sprite.frameHeight / sprite.frameWidth)
        setImageRect(image, id, sprite.frameWidth, sprite.frameHeight, frame, 0)
        fallback.Visible = false
    else
        image.Visible = false
        local def = ITEM_FALLBACK[kind] or { text = "?", color = Color3.fromRGB(100, 116, 139) }
        fallback.Text = def.text
        fallback.BackgroundColor3 = def.color
        fallback.Size = UDim2.fromOffset(24, 24)
        fallback.Visible = true
    end
end

local function updateItemUnit(unit, kind: string, x: number, y: number, now: number)
    unit.root.Position = UDim2.fromOffset(x * T + T / 2, y * T + T / 2 + VISUAL_DY)
    unit.shadow.Visible = true
    setZRecursive(unit.root, 100 + y * 100 + 20)
    setItemVisual(unit.image, unit.fallback, kind, now)
end

---------------------------------------------------------------- 泡泡

local function createBombUnit()
    local root = newRoot("Bomb", board)
    local image = newImage(root, "Popo")
    local fallback = newBadge(root, "Fallback", "", Color3.fromRGB(56, 189, 248), 26, 12)
    local highlight = Instance.new("Frame")
    highlight.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    highlight.BackgroundTransparency = 0.4
    highlight.BorderSizePixel = 0
    highlight.AnchorPoint = Vector2.new(0.5, 0.5)
    highlight.Position = UDim2.fromOffset(-5, -6)
    highlight.Size = UDim2.fromOffset(8, 5)
    highlight.ZIndex = 2
    highlight.Parent = root
    addCorner(highlight, 0.5)

    local antenna = Instance.new("Frame")
    antenna.BackgroundColor3 = Color3.fromRGB(194, 65, 12)
    antenna.BorderSizePixel = 0
    antenna.AnchorPoint = Vector2.new(0.5, 1)
    antenna.Position = UDim2.fromOffset(0, -13)
    antenna.Size = UDim2.fromOffset(2, 9)
    antenna.Visible = false
    antenna.ZIndex = 2
    antenna.Parent = root

    local antennaDot = Instance.new("Frame")
    antennaDot.BackgroundColor3 = Color3.fromRGB(254, 240, 138)
    antennaDot.BorderSizePixel = 0
    antennaDot.AnchorPoint = Vector2.new(0.5, 0.5)
    antennaDot.Position = UDim2.fromOffset(0, -22)
    antennaDot.Size = UDim2.fromOffset(5, 5)
    antennaDot.Visible = false
    antennaDot.ZIndex = 2
    antennaDot.Parent = root
    addCorner(antennaDot, 0.5)

    return {
        root = root,
        image = image,
        fallback = fallback,
        highlight = highlight,
        antenna = antenna,
        antennaDot = antennaDot,
    }
end

local function updateBombUnit(unit, bomb, now: number)
    local sx = bomb.sx or (bomb.x * T + T / 2)
    local sy = (bomb.sy or (bomb.y * T + T / 2)) + VISUAL_DY
    unit.root.Position = UDim2.fromOffset(sx, sy)

    local urgent = not bomb.remote and (bomb.fuse or 999) < 20
    local pulse = if urgent then 1 + 0.08 * math.sin(now * 18) else 1
    local group = if bomb.remote then Sprites.POPO.remote else Sprites.POPO.blue
    local frame = math.floor(now / (if urgent then 0.09 else 0.3)) % 3 + 1
    local id = asset(group.assetKeys[frame])

    if id ~= "" then
        unit.image.Size = UDim2.fromOffset(38 * pulse, 36 * pulse)
        setFullImage(unit.image, id)
        unit.fallback.Visible = false
        unit.highlight.Visible = false
    else
        unit.image.Visible = false
        unit.fallback.Text = ""
        unit.fallback.BackgroundColor3 = if bomb.remote
            then Color3.fromRGB(249, 115, 22)
            else Color3.fromRGB(56, 189, 248)
        unit.fallback.Size = UDim2.fromOffset(26 * pulse, 26 * pulse)
        unit.fallback.Visible = true
        unit.highlight.Visible = true
    end

    unit.antenna.Visible = bomb.remote == true
    unit.antennaDot.Visible = bomb.remote == true
    setZRecursive(unit.root, 100 + (bomb.y or 0) * 100 + 30)
end

---------------------------------------------------------------- 爆炸

local function createExplosionUnit()
    local root = newRoot("Explosion", board)
    local fallback = Instance.new("Frame")
    fallback.BackgroundColor3 = Color3.fromRGB(125, 211, 252)
    fallback.BorderSizePixel = 0
    fallback.AnchorPoint = Vector2.new(0.5, 0.5)
    fallback.Size = UDim2.fromOffset(T - 6, T - 6)
    fallback.Parent = root
    addCorner(fallback, 0.2)
    fallback.Visible = false

    local image = newImage(root, "Flame")
    image.Size = UDim2.fromOffset(T, T)
    return { root = root, image = image, fallback = fallback }
end

local function updateExplosionUnit(unit, explosion, cell, center, cellSet, now: number)
    local x, y = cell[1], cell[2]
    local cx, cy = center[1], center[2]
    unit.root.Position = UDim2.fromOffset(x * T + T / 2, y * T + T / 2)

    local sheet = Sprites.SHEETS.explosion
    local id = asset(sheet.assetKey)
    local ttl = explosion.ttl or 0
    local progress = math.min(1, (Constants.EXPLOSION_TICKS - ttl) / Constants.EXPLOSION_TICKS)
    local tipFrame = math.min(7, math.floor(progress * 8))

    if id ~= "" and explosion.cells and explosion.cells[1] then
        local colIndex, rowIndex
        if x == cx and y == cy then
            rowIndex = 5
            colIndex = math.floor(now / 0.1) % 4 + 1
        else
            local horizontal = y == cy
            local sign = if horizontal then (x > cx and 1 or -1) else (y > cy and 1 or -1)
            if horizontal then
                rowIndex = if sign > 0 then 4 else 3
            else
                rowIndex = if sign > 0 then 2 else 1
            end
            local nextKey = if horizontal
                then string.format("%d,%d", x + sign, y)
                else string.format("%d,%d", x, y + sign)
            local isTip = not cellSet[nextKey]
            colIndex = if isTip then 7 + tipFrame else 4
        end
        setImageRect(
            unit.image,
            id,
            sheet.frameWidth,
            sheet.frameHeight,
            colIndex - 1,
            rowIndex - 1
        )
        unit.image.Size = UDim2.fromOffset(T, T)
        unit.fallback.Visible = false
    else
        unit.image.Visible = false
        unit.fallback.Visible = true
        local transparency = math.min(0.85, 0.15 + progress * 0.65)
        unit.fallback.BackgroundColor3 = Color3.fromRGB(125, 211, 252)
        unit.fallback.BackgroundTransparency = transparency
        unit.fallback.Size = UDim2.fromOffset(
            (T - 6) * (0.75 + progress * 0.25),
            (T - 6) * (0.75 + progress * 0.25)
        )
    end

    setZRecursive(unit.root, 9000)
end

---------------------------------------------------------------- 抛射 / 滑箱 / 死亡

local function createLootUnit()
    local root = newRoot("Loot", board)
    local shadow = Instance.new("Frame")
    shadow.BackgroundColor3 = Color3.fromRGB(8, 19, 28)
    shadow.BackgroundTransparency = 0.7
    shadow.BorderSizePixel = 0
    shadow.AnchorPoint = Vector2.new(0.5, 0.5)
    shadow.Position = UDim2.fromOffset(0, 9)
    shadow.Size = UDim2.fromOffset(24, 6)
    shadow.Parent = root
    addCorner(shadow, 0.5)

    local image = newImage(root, "Icon")
    local fallback = newBadge(root, "Fallback", "", Color3.fromRGB(250, 204, 21), 22, 13)
    return { root = root, shadow = shadow, image = image, fallback = fallback }
end

local function createSlideUnit()
    local root = newRoot("SlidingCrate", board)
    local image = newImage(root, "Crate")
    image.AnchorPoint = Vector2.new(0, 0)
    image.Position = UDim2.fromOffset(0, 0)
    image.Size = UDim2.fromOffset(T, T * 1.2)

    local fallback = Instance.new("Frame")
    fallback.BackgroundColor3 = Color3.fromRGB(101, 55, 28)
    fallback.BorderSizePixel = 0
    fallback.Size = UDim2.fromOffset(T - 4, 43)
    fallback.Position = UDim2.fromOffset(2, 0)
    fallback.Parent = root
    addCorner(fallback, 0.1)
    addStroke(fallback, Color3.fromRGB(51, 26, 12), 2)
    fallback.Visible = false

    local mark = Instance.new("TextLabel")
    mark.BackgroundTransparency = 1
    mark.Size = UDim2.fromScale(1, 1)
    mark.Font = Enum.Font.GothamBold
    mark.Text = "✕"
    mark.TextColor3 = Color3.fromRGB(245, 196, 120)
    mark.TextSize = 22
    mark.Parent = fallback

    return { root = root, image = image, fallback = fallback }
end

local function createDeathUnit()
    local root = newRoot("Death", board)
    local image = newImage(root, "Die")
    image.AnchorPoint = Vector2.new(0.5, 1)
    image.Position = UDim2.fromOffset(0, 0)

    local bubble = newBadge(root, "Bubble", "泡", Color3.fromRGB(125, 211, 252), 42, 17)
    return { root = root, image = image, bubble = bubble }
end

local function acquireDeath(): any
    local count = #deathFree
    if count > 0 then
        local unit = deathFree[count]
        deathFree[count] = nil
        return unit
    end
    local unit = createDeathUnit()
    table.insert(deathAll, unit)
    return unit
end

local function releaseDeath(unit)
    unit.root.Visible = false
    table.insert(deathFree, unit)
end

local function addDeath(playerId: string, x: number, y: number, now: number)
    for _, effect in ipairs(deathEffects) do
        if effect.playerId == playerId and now - effect.at < 1.1 then
            return
        end
    end
    local entry = rosterById[playerId] or {}
    table.insert(deathEffects, {
        playerId = playerId,
        char = entry.char or "baobao",
        x = x,
        y = y,
        at = now,
        unit = nil,
    })
end

---------------------------------------------------------------- 玩家

local function createPlayerUnit()
    local root = newRoot("Player", board)

    local shadow = Instance.new("Frame")
    shadow.BackgroundColor3 = Color3.fromRGB(8, 19, 28)
    shadow.BackgroundTransparency = 0.66
    shadow.BorderSizePixel = 0
    shadow.AnchorPoint = Vector2.new(0.5, 0.5)
    shadow.Position = UDim2.fromOffset(0, -4)
    shadow.Size = UDim2.fromOffset(24, 10)
    shadow.Parent = root
    addCorner(shadow, 0.5)

    local mountBelow = newImage(root, "MountBelow")
    mountBelow.AnchorPoint = Vector2.new(0.5, 1)
    mountBelow.Position = UDim2.fromOffset(0, -8)

    local mountBelowFallback = newBadge(root, "MountBelowFallback", "龟", Color3.fromRGB(22, 163, 74), 30, 14)
    mountBelowFallback.AnchorPoint = Vector2.new(0.5, 1)
    mountBelowFallback.Position = UDim2.fromOffset(0, -8)

    local body = newImage(root, "Body")
    body.AnchorPoint = Vector2.new(0.5, 1)
    body.Position = UDim2.fromOffset(0, 0)

    local bodyFallback = Instance.new("Frame")
    bodyFallback.BackgroundColor3 = Color3.fromRGB(226, 59, 59)
    bodyFallback.BorderSizePixel = 0
    bodyFallback.AnchorPoint = Vector2.new(0.5, 1)
    bodyFallback.Position = UDim2.fromOffset(0, 0)
    bodyFallback.Size = UDim2.fromOffset(30, 34)
    bodyFallback.Parent = root
    addCorner(bodyFallback, 0.5)
    addStroke(bodyFallback, Color3.fromRGB(20, 24, 30), 2, 0.15)

    local function eye(xOffset: number)
        local eyeFrame = Instance.new("Frame")
        eyeFrame.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
        eyeFrame.BorderSizePixel = 0
        eyeFrame.AnchorPoint = Vector2.new(0.5, 0.5)
        eyeFrame.Position = UDim2.fromOffset(xOffset, -10)
        eyeFrame.Size = UDim2.fromOffset(7, 8)
        eyeFrame.Parent = bodyFallback
        addCorner(eyeFrame, 0.5)
        local pupil = Instance.new("Frame")
        pupil.BackgroundColor3 = Color3.fromRGB(20, 24, 30)
        pupil.BorderSizePixel = 0
        pupil.AnchorPoint = Vector2.new(0.5, 0.5)
        pupil.Position = UDim2.fromOffset(0, 1)
        pupil.Size = UDim2.fromOffset(3, 4)
        pupil.Parent = eyeFrame
        addCorner(pupil, 0.5)
    end
    eye(-6)
    eye(6)

    local mountAbove = newImage(root, "MountAbove")
    mountAbove.AnchorPoint = Vector2.new(0.5, 1)
    mountAbove.Position = UDim2.fromOffset(0, -8)

    local mountAboveFallback = newBadge(root, "MountAboveFallback", "碟", Color3.fromRGB(100, 116, 139), 30, 14)
    mountAboveFallback.AnchorPoint = Vector2.new(0.5, 1)
    mountAboveFallback.Position = UDim2.fromOffset(0, -8)

    local bubble = newImage(root, "BigPopo")
    bubble.Size = UDim2.fromOffset(66, 66)

    local bubbleFallback = Instance.new("Frame")
    bubbleFallback.BackgroundColor3 = Color3.fromRGB(125, 211, 252)
    bubbleFallback.BackgroundTransparency = 0.5
    bubbleFallback.BorderSizePixel = 0
    bubbleFallback.AnchorPoint = Vector2.new(0.5, 0.5)
    bubbleFallback.Size = UDim2.fromOffset(56, 56)
    bubbleFallback.Parent = root
    addCorner(bubbleFallback, 0.5)
    addStroke(bubbleFallback, Color3.fromRGB(255, 255, 255), 2, 0.15)
    bubbleFallback.Visible = false

    local name = newText(root, "Name", "", Color3.fromRGB(255, 255, 255), 11)
    name.AnchorPoint = Vector2.new(0.5, 1)
    name.Size = UDim2.fromOffset(140, 18)

    local marker = newText(root, "SelfMarker", "●", Color3.fromRGB(79, 195, 247), 16)
    marker.Size = UDim2.fromOffset(26, 26)

    local needle = newText(root, "NeedleHint", "Ctrl 自救", Color3.fromRGB(254, 240, 138), 11)
    needle.AnchorPoint = Vector2.new(0.5, 1)
    needle.Size = UDim2.fromOffset(120, 16)

    return {
        root = root,
        shadow = shadow,
        mountBelow = mountBelow,
        mountBelowFallback = mountBelowFallback,
        body = body,
        bodyFallback = bodyFallback,
        mountAbove = mountAbove,
        mountAboveFallback = mountAboveFallback,
        bubble = bubble,
        bubbleFallback = bubbleFallback,
        name = name,
        marker = marker,
        needle = needle,
    }
end

local MOUNT_FALLBACK_TEXT = {
    turtle = "龟",
    owl = "鹰",
    pirateTurtle = "龟",
    ufo = "碟",
}

local function updatePlayerUnit(unit, player, roster, now: number, warmup: number, interpolatedX: number, interpolatedY: number)
    local char = roster.char or "baobao"
    local colorIndex = roster.colorIndex or 0
    local color = teamColor(colorIndex)
    local mountKind = player.mount
    local lift = if mountKind then T * 0.26 else 0
    local trapped = player.trapped == true
    local footRow = math.floor((player.y or 0) / T)
    local subRow = math.floor((((player.y or 0) % T) / T) * 20)
    local z = 100 + footRow * 100 + 50 + subRow
    local groundY = interpolatedY + T * 0.42 + VISUAL_DY
    local feetY = groundY - lift

    unit.root.Position = UDim2.fromOffset(interpolatedX, groundY)
    unit.root.Visible = true

    local previous = lastPositions[player.id]
    if previous then
        local dx = interpolatedX - previous.x
        local dy = interpolatedY - previous.y
        if dx * dx + dy * dy > 0.6 then
            if math.abs(dx) >= math.abs(dy) then
                faces[player.id] = if dx > 0 then 4 else 3
            else
                faces[player.id] = if dy > 0 then 2 else 1
            end
            lastMoveAt[player.id] = now
        end
    else
        faces[player.id] = faces[player.id] or 2
    end
    lastPositions[player.id] = { x = interpolatedX, y = interpolatedY }

    local moving = now - (lastMoveAt[player.id] or 0) < 0.15
    local row = faces[player.id] or 2
    local anim = Sprites.ANIM[char] or Sprites.ANIM.baobao
    local frame = if trapped
        then math.floor(now / 0.12) % 2
        else if moving then math.floor(now / 0.1) % anim.cols else 0
    local id = asset(Sprites.animKey(char, colorIndex))

    unit.body.Position = UDim2.fromOffset(0, -lift)
    unit.bodyFallback.Position = UDim2.fromOffset(0, -lift - (moving and math.abs(math.sin(now * 8)) * 1.5 or 0))
    unit.bodyFallback.BackgroundColor3 = color

    if id ~= "" then
        local bodyHeight = anim.drawHeight
        local bodyWidth = anim.frameWidth * bodyHeight / anim.frameHeight
        unit.body.Size = UDim2.fromOffset(bodyWidth, bodyHeight)
        setImageRect(unit.body, id, anim.frameWidth, anim.frameHeight, frame, row - 1)
        unit.bodyFallback.Visible = false
    else
        unit.body.Visible = false
        unit.bodyFallback.Visible = true
    end

    unit.mountBelow.Visible = false
    unit.mountBelowFallback.Visible = false
    unit.mountAbove.Visible = false
    unit.mountAboveFallback.Visible = false

    local mountRow = row - 1
    local mountCol = if moving then math.floor(now / 0.12) % 2 else 0
    if mountKind then
        local mount = Sprites.MOUNTS[mountKind]
        local mountId = if mount then asset(mount.assetKey) else ""
        local upper = mountKind == "ufo"
        local image = if upper then unit.mountAbove else unit.mountBelow
        local fallback = if upper then unit.mountAboveFallback else unit.mountBelowFallback
        if mount and mountId ~= "" then
            image.Size = UDim2.fromOffset(mount.displayWidth, mount.displayHeight)
            setImageRect(
                image,
                mountId,
                mount.frameWidth,
                mount.frameHeight,
                mountCol,
                mountRow
            )
            image.Visible = true
            fallback.Visible = false
        else
            fallback.Text = MOUNT_FALLBACK_TEXT[mountKind] or "?"
            fallback.BackgroundColor3 = if mountKind == "ufo"
                then Color3.fromRGB(100, 116, 139)
                else if mountKind == "turtle"
                    then Color3.fromRGB(22, 163, 74)
                    else if mountKind == "pirateTurtle"
                        then Color3.fromRGB(220, 38, 38)
                        else Color3.fromRGB(180, 83, 9)
            fallback.Visible = true
        end
    end

    if trapped then
        trapAt[player.id] = trapAt[player.id] or now
        local age = now - trapAt[player.id]
        local bigId = asset(Sprites.SHEETS.big_popo.assetKey)
        local bubbleY = feetY - H * 0.5
        unit.bubble.Position = UDim2.fromOffset(0, bubbleY - groundY)
        unit.bubbleFallback.Position = UDim2.fromOffset(0, bubbleY - groundY)
        if bigId ~= "" then
            local f = math.min(3, math.floor(age / 0.11))
            setImageRect(
                unit.bubble,
                bigId,
                Sprites.SHEETS.big_popo.frameWidth,
                Sprites.SHEETS.big_popo.frameHeight,
                f,
                0
            )
            unit.bubble.Size = UDim2.fromOffset(66, 66)
            unit.bubbleFallback.Visible = false
        else
            unit.bubble.Visible = false
            unit.bubbleFallback.Visible = true
            unit.bubbleFallback.BackgroundTransparency = 0.48
        end
    else
        trapAt[player.id] = nil
        unit.bubble.Visible = false
        unit.bubbleFallback.Visible = false
    end

    local nameY = -lift - H - (trapped and 10 or 2)
    unit.name.Text = roster.name or player.id
    unit.name.TextColor3 = color
    unit.name.Position = UDim2.fromOffset(0, nameY)
    unit.name.Visible = true

    unit.marker.Visible = player.id == yourId
    if unit.marker.Visible then
        local countdown = (warmup or 0) > 0
        unit.marker.Text = if countdown then "▼" else "●"
        unit.marker.TextColor3 = if countdown then Color3.fromRGB(255, 59, 48) else Color3.fromRGB(79, 195, 247)
        unit.marker.TextSize = if countdown then 22 else 16
        unit.marker.Position = UDim2.fromOffset(
            0,
            -lift - H - 22 - (countdown and math.abs(math.sin(now * 3)) * 8 or 0)
        )
    end

    unit.needle.Visible = trapped and (player.inv and player.inv.needle or 0) > 0
    if unit.needle.Visible then
        unit.needle.Position = UDim2.fromOffset(0, -lift - H - (trapped and 28 or 16))
    end

    setZRecursive(unit.root, z)
end

---------------------------------------------------------------- 更新入口

local function updateItems(items, now)
    local seen = {}
    for _, item in ipairs(items or {}) do
        local key = string.format("%s:%d:%d", item.kind, item.x, item.y)
        seen[key] = true
        local unit = acquire(itemPool, key, createItemUnit)
        updateItemUnit(unit, item.kind, item.x, item.y, now)
    end
    sweep(itemPool, seen)
end

local function updateBombs(bombs, now)
    local seen = {}
    for _, bomb in ipairs(bombs or {}) do
        local key = tostring(bomb.id or string.format("%s:%d:%d", tostring(bomb.owner), bomb.x, bomb.y))
        seen[key] = true
        local unit = acquire(bombPool, key, createBombUnit)
        updateBombUnit(unit, bomb, now)
    end
    sweep(bombPool, seen)
end

local function updateExplosions(explosions, now)
    local seen = {}
    for _, explosion in ipairs(explosions or {}) do
        if explosion.cells and explosion.cells[1] then
            local center = explosion.cells[1]
            local cellSet = {}
            for _, cell in ipairs(explosion.cells) do
                cellSet[string.format("%d,%d", cell[1], cell[2])] = true
            end
            for _, cell in ipairs(explosion.cells) do
                local key = string.format("%s:%d:%d", tostring(explosion.id or "x"), cell[1], cell[2])
                seen[key] = true
                local unit = acquire(explosionPool, key, createExplosionUnit)
                updateExplosionUnit(unit, explosion, cell, center, cellSet, now)
            end
        end
    end
    sweep(explosionPool, seen)
end

local function updateLoot(shots, now)
    local seen = {}
    for _, shot in ipairs(shots or {}) do
        local key = string.format(
            "%s:%d:%d:%d:%d",
            shot.kind,
            shot.x0,
            shot.y0,
            shot.x1,
            shot.y1
        )
        seen[key] = true
        local unit = acquire(lootPool, key, createLootUnit)
        local total = math.max(1, shot.total or 1)
        local progress = math.min(1, 1 - (shot.left or 0) / total)
        local px = shot.x0 + (shot.x1 - shot.x0) * progress
        local py = shot.y0 + (shot.y1 - shot.y0) * progress
        local dx, dy = shot.x1 - shot.x0, shot.y1 - shot.y0
        local arc = (T * 0.9 + math.sqrt(dx * dx + dy * dy) * 0.25) * math.sin(math.pi * progress)
        unit.root.Position = UDim2.fromOffset(px, py - arc + VISUAL_DY)
        unit.shadow.Visible = progress >= 1
        setItemVisual(unit.image, unit.fallback, shot.kind, now)
        setZRecursive(unit.root, 8000)
    end
    sweep(lootPool, seen)
end

local function updateSlides(slides, now)
    local seen = {}
    for _, slide in ipairs(slides or {}) do
        local key = string.format("%d:%d:%d:%d", slide.fx, slide.fy, slide.tx, slide.ty)
        seen[key] = true
        local unit = acquire(slidePool, key, createSlideUnit)
        local total = math.max(1, slide.total or 1)
        local progress = math.min(1, 1 - (slide.left or 0) / total)
        local x = (slide.fx + (slide.tx - slide.fx) * progress) * T
        local y = (slide.fy + (slide.ty - slide.fy) * progress) * T
        unit.root.Position = UDim2.fromOffset(x, y + T / 8)

        local id = asset(Sprites.SHEETS.crate.assetKey)
        if id ~= "" then
            setFullImage(unit.image, id)
            unit.image.Visible = true
            unit.image.Size = UDim2.fromOffset(T, T * 1.2)
            unit.fallback.Visible = false
        else
            unit.image.Visible = false
            unit.fallback.Visible = true
        end

        setZRecursive(unit.root, 100 + math.floor(y / T) * 100 + 40)
    end
    sweep(slidePool, seen)
end

local function updateDeaths(now)
    local remaining = {}
    for _, effect in ipairs(deathEffects) do
        local age = now - effect.at
        if age < 1.1 then
            local unit = effect.unit
            if not unit then
                unit = acquireDeath()
                effect.unit = unit
            end
            unit.root.Visible = true
            unit.root.Position = UDim2.fromOffset(
                effect.x,
                effect.y + T * 0.42 + VISUAL_DY
            )

            local die = Sprites.DIE[effect.char] or Sprites.DIE.baobao
            local id = asset(die.assetKey)
            if id ~= "" then
                local anim = Sprites.ANIM[effect.char] or Sprites.ANIM.baobao
                local scale = H / anim.frameHeight
                local width = die.frameWidth * scale
                local height = die.frameHeight * scale
                local frame = math.min(die.frames - 1, math.floor(age / 0.1))
                unit.image.Size = UDim2.fromOffset(width, height)
                setImageRect(unit.image, id, die.frameWidth, die.frameHeight, frame, 0)
                unit.bubble.Visible = false
            else
                unit.image.Visible = false
                unit.bubble.Visible = true
                local t = age / 0.6
                if t >= 1 then
                    unit.bubble.Visible = false
                else
                    unit.bubble.Text = "泡"
                    unit.bubble.Size = UDim2.fromOffset(42 + t * 24, 42 + t * 24)
                    unit.bubble.BackgroundTransparency = math.min(0.9, 0.4 + t * 0.4)
                    unit.bubble.Position = UDim2.fromOffset(0, -H * 0.5)
                end
            end
            setZRecursive(unit.root, 9100)
            table.insert(remaining, effect)
        else
            if effect.unit then
                releaseDeath(effect.unit)
                effect.unit = nil
            end
        end
    end
    deathEffects = remaining
end

local function updatePlayers(players, previousPlayers, alpha, now, warmup)
    local seen = {}
    for _, player in ipairs(players or {}) do
        local previous = previousPlayers[player.id]
        if previous and previous.alive and not player.alive then
            addDeath(player.id, player.x, player.y, now)
        end

        if player.alive then
            local x, y = player.x, player.y
            if previous and previous.alive then
                local dx, dy = player.x - previous.x, player.y - previous.y
                if dx * dx + dy * dy < 100 * 100 then
                    x = previous.x + (player.x - previous.x) * alpha
                    y = previous.y + (player.y - previous.y) * alpha
                end
            end
            seen[player.id] = true
            local unit = acquire(playerPool, player.id, createPlayerUnit)
            local roster = rosterById[player.id] or { name = player.id, char = "baobao", colorIndex = 0 }
            updatePlayerUnit(unit, player, roster, now, warmup, x, y)
        end
    end
    sweep(playerPool, seen)
end

function Renderer.init(parent: Frame)
    board = parent
end

function Renderer.setRoster(list)
    rosterById = {}
    for _, entry in ipairs(list or {}) do
        rosterById[entry.id] = entry
    end
end

function Renderer.setYourId(id: string?)
    yourId = id
end

function Renderer.update(previous, current, alpha, now, warmup)
    if not current then
        updateDeaths(now)
        return
    end

    -- 地图 grid 由 Main.client 在收到快照时应用（见 applySnapshot），这里只负责滑动中的箱子。
    Board.setSliding(current.crateSlides or {})

    local previousPlayers = {}
    if previous then
        for _, player in ipairs(previous.players or {}) do
            previousPlayers[player.id] = player
        end
    end

    updatePlayers(current.players or {}, previousPlayers, alpha, now, warmup or current.warmup or 0)
    updateItems(current.items or {}, now)
    updateBombs(current.bombs or {}, now)
    updateExplosions(current.expl or {}, now)
    updateLoot(current.loot or {}, now)
    updateSlides(current.crateSlides or {}, now)
    updateDeaths(now)
end

function Renderer.clear()
    releasePool(itemPool)
    releasePool(bombPool)
    releasePool(explosionPool)
    releasePool(lootPool)
    releasePool(slidePool)
    releasePool(playerPool)

    for _, effect in ipairs(deathEffects) do
        if effect.unit then
            releaseDeath(effect.unit)
            effect.unit = nil
        end
    end
    deathEffects = {}

    faces = {}
    lastPositions = {}
    lastMoveAt = {}
    trapAt = {}
    Board.setSliding({})
end

return table.freeze(Renderer)
