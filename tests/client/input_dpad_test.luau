-- Touch four-way ring pad (the default layout): a ring split into four
-- sectors around a round hub, steered by the thumb's position around the pad
-- centre through one touch surface. Covers the layout, that nothing is ever
-- drawn outside the ring, that the four sectors tile the ring exactly, landing
-- and sliding between sectors without lifting, the hub dead zone and its
-- hysteresis, axis hysteresis, multi-finger rules, release paths and the visual
-- feedback, using the real Input.luau with stubbed GUI objects.
local TestLib = require("./testlib")
local check = TestLib.check

local Env = require("./ClientEnv")
local Enum = Env.Enum
local Vector2, Vector3 = Env.Vector2, Env.Vector3

Env.game:GetService("UserInputService").TouchEnabled = true

local TouchModule = require("./InputTouch")
check("the ring pad is the default layout", TouchModule.USE_DIRECTION_PAD == true)

local Input = require("./Input")
Input.init({})
Input.setEnabled(true)

local function find(name: string)
    for _, instance in ipairs(Env.instances) do
        if instance.Name == name then
            return instance
        end
    end
    return nil
end

local controls = find("TouchControls")
local pad = find("DPad")
local rim = find("DPadRim")
local hub = find("DPadHub")
local thumb = find("DPadThumb")
local surface = find("DPadSurface")
local seams = { find("DPadSeam1"), find("DPadSeam2") }

local SECTOR_KEYS = { up = "DPadUp", right = "DPadRight", down = "DPadDown", left = "DPadLeft" }
local sectors = {}
for direction, key in pairs(SECTOR_KEYS) do
    local bars = {}
    for _, instance in ipairs(Env.instances) do
        if type(instance.Name) == "string" and string.match(instance.Name, "^" .. key .. "Bar%d+$") then
            table.insert(bars, instance)
        end
    end
    sectors[direction] = {
        bars = bars,
        arrows = { find(key .. "Arrow1"), find(key .. "Arrow2") },
    }
end

local built = pad ~= nil and rim ~= nil and hub ~= nil and thumb ~= nil and surface ~= nil
    and seams[1] ~= nil and seams[2] ~= nil
for _, sector in pairs(sectors) do
    built = built and #sector.bars > 30 and sector.arrows[1] ~= nil and sector.arrows[2] ~= nil
end
check("the pad is built: four sectors of bars with arrows, two seams, rim, hub, dot and one touch surface", built)
check("cross-pad mode builds no joystick",
    find("Joystick") == nil and find("JoystickKnob") == nil and find("JoystickSurface") == nil)
check("bubble and item buttons remain", find("泡泡") ~= nil and find("道具") ~= nil)
check("touch controls start hidden", controls.Visible == false)
Input.setControlsVisible(true)
check("touch controls can be shown", controls.Visible == true)

---------------------------------------------------------------- 布局
-- The same bottom-left spot as the old joystick: a 152px ring anchored at
-- (24, H-24).
local SIZE = 152
local HALF = SIZE / 2
local HUB_R = 22
check("the pad is a 152px ring in the bottom-left spot",
    pad.Size.X.Offset == 152 and pad.Size.Y.Offset == 152
        and pad.Position.X.Offset == 100 and pad.Position.Y.Offset == -24
        and pad.AnchorPoint.X == 0.5 and pad.AnchorPoint.Y == 1,
    tostring(pad.Size.X.Offset) .. "," .. tostring(pad.Position.X.Offset) .. "," .. tostring(pad.Position.Y.Offset))
check("the hub is a 44px circle in the middle",
    hub.Size.X.Offset == 44 and hub.Position.X.Offset == HALF and hub.Position.Y.Offset == HALF)
check("the dot starts in the middle of the hub",
    thumb.Position.X.Offset == HALF and thumb.Position.Y.Offset == HALF and thumb.Size.X.Offset == 13)
check("the touch surface reaches 24px past the ring on every side",
    surface.Size.X.Offset == 200 and surface.Size.Y.Offset == 200
        and surface.Position.X.Offset == -24 and surface.Position.Y.Offset == -24,
    tostring(surface.Size.X.Offset) .. "," .. tostring(surface.Position.X.Offset))
check("the surface sits above the visuals",
    surface.ZIndex > hub.ZIndex and surface.ZIndex > thumb.ZIndex and surface.ZIndex > sectors.up.bars[1].ZIndex)

---------------------------------------------------------------- 只画在圆内
-- The reported bug: the sectors were drawn as big squares that spilled far
-- outside the ring (CanvasGroup clipping did not take effect on the runtime).
-- Nothing may depend on clipping now, so no CanvasGroup is used...
local canvasGroups = 0
for _, instance in ipairs(Env.instances) do
    if instance.ClassName == "CanvasGroup" then
        canvasGroups += 1
    end
end
check("no CanvasGroup is used anywhere (clipping and group transparency are not relied on)", canvasGroups == 0, canvasGroups)

-- ...and every drawn piece must lie inside the ring's circle by itself.
local function corners(instance)
    local width, height = instance.Size.X.Offset, instance.Size.Y.Offset
    -- Unset properties of a stub fall through to a function, so check the types.
    local anchor = if type(instance.AnchorPoint) == "table" then instance.AnchorPoint else Vector2.new(0, 0)
    local rotation = if type(instance.Rotation) == "number" then instance.Rotation else 0
    local left = instance.Position.X.Offset - anchor.X * width
    local top = instance.Position.Y.Offset - anchor.Y * height
    local pivotX, pivotY = left + width * anchor.X, top + height * anchor.Y
    local angle = math.rad(rotation)
    local out = {}
    for _, point in ipairs({ { left, top }, { left + width, top }, { left + width, top + height }, { left, top + height } }) do
        local dx, dy = point[1] - pivotX, point[2] - pivotY
        out[#out + 1] = {
            pivotX + dx * math.cos(angle) - dy * math.sin(angle),
            pivotY + dx * math.sin(angle) + dy * math.cos(angle),
        }
    end
    return out
end
local function farthest(instance): number
    local worst = 0
    for _, corner in ipairs(corners(instance)) do
        worst = math.max(worst, math.sqrt((corner[1] - HALF) ^ 2 + (corner[2] - HALF) ^ 2))
    end
    return worst
end

local worstBar, barCount = 0, 0
for _, sector in pairs(sectors) do
    for _, bar in ipairs(sector.bars) do
        worstBar = math.max(worstBar, farthest(bar))
        barCount += 1
    end
end
check("every sector bar lies inside the ring's circle", worstBar <= HALF + 0.001,
    string.format("farthest bar corner %.3f of %d", worstBar, HALF))
check("the bars are plenty (a smooth edge), but not thousands", barCount > 200 and barCount < 400, barCount)
check("the seams end on the circle, no further",
    farthest(seams[1]) <= HALF + 0.05 and farthest(seams[2]) <= HALF + 0.05,
    string.format("%.3f / %.3f", farthest(seams[1]), farthest(seams[2])))
local worstArrow = 0
for _, sector in pairs(sectors) do
    worstArrow = math.max(worstArrow, farthest(sector.arrows[1]), farthest(sector.arrows[2]))
end
check("the arrows lie inside the ring", worstArrow <= HALF, worstArrow)
check("the seams are the two diagonals, 3px wide",
    seams[1].Rotation == 45 and seams[2].Rotation == -45
        and seams[1].Size.X.Offset == 152 and seams[1].Size.Y.Offset == 3
        and seams[1].Position.X.Offset == HALF and seams[1].Position.Y.Offset == HALF)

-- The four sectors tile the ring: away from the diagonals every point of the
-- band is covered by exactly one sector, and it is the one of its own quadrant.
local function covers(bar, x: number, y: number): boolean
    local left, top = bar.Position.X.Offset, bar.Position.Y.Offset
    return x >= left and x <= left + bar.Size.X.Offset and y >= top and y <= top + bar.Size.Y.Offset
end
local function quadrant(dx: number, dy: number): string
    if math.abs(dx) >= math.abs(dy) then
        return if dx >= 0 then "right" else "left"
    end
    return if dy > 0 then "down" else "up"
end
local wrong, doubled, holes, seamCover, tested = 0, 0, 0, 0, 0
for radius = 26, 74, 2 do
    for degrees = 0, 359 do
        local angle = math.rad(degrees)
        local dx, dy = radius * math.sin(angle), -radius * math.cos(angle)
        local x, y = HALF + dx, HALF + dy
        local hits, which = 0, nil
        for direction, sector in pairs(sectors) do
            for _, bar in ipairs(sector.bars) do
                if covers(bar, x, y) then
                    hits += 1
                    which = direction
                    break
                end
            end
        end
        local nearDiagonal = math.abs(math.abs(dx) - math.abs(dy)) / math.sqrt(2) < 1.5
        if nearDiagonal then
            seamCover += 1
        else
            tested += 1
            if hits == 0 then
                holes += 1
            elseif hits > 1 then
                doubled += 1
            elseif which ~= quadrant(dx, dy) then
                wrong += 1
            end
        end
    end
end
check("away from the diagonals no point of the ring is left uncovered", holes == 0, holes .. " of " .. tested)
check("away from the diagonals no point is covered by two sectors", doubled == 0, doubled)
check("every point is covered by the sector of its own quadrant", wrong == 0, wrong)
check("opposite sectors are the same size and so are the two axes",
    #sectors.up.bars == #sectors.down.bars and #sectors.left.bars == #sectors.right.bars
        and #sectors.up.bars == #sectors.left.bars,
    #sectors.up.bars .. "/" .. #sectors.down.bars .. "/" .. #sectors.left.bars .. "/" .. #sectors.right.bars)
check("the hub's inside is left to the hub (no bar reaches the middle)",
    (function()
        for _, sector in pairs(sectors) do
            for _, bar in ipairs(sector.bars) do
                local nearest = math.huge
                for _, corner in ipairs(corners(bar)) do
                    nearest = math.min(nearest, math.sqrt((corner[1] - HALF) ^ 2 + (corner[2] - HALF) ^ 2))
                end
                -- a bar's nearest corner may sit just inside the hub edge (it is overlapped by the hub)
                if nearest < HUB_R - 2 then
                    return false
                end
            end
        end
        return true
    end)())

---------------------------------------------------------------- 箭头
-- A chevron of two rounded strokes per sector, centred mid-band 49px from the
-- centre and pointing outward.
local function near(a: number, b: number): boolean
    return math.abs(a - b) < 0.01
end
local function arrowCentre(sector)
    local a, b = sector.arrows[1], sector.arrows[2]
    return (a.Position.X.Offset + b.Position.X.Offset) / 2, (a.Position.Y.Offset + b.Position.Y.Offset) / 2
end
local ux, uy = arrowCentre(sectors.up)
local rx, ry = arrowCentre(sectors.right)
local dx, dy = arrowCentre(sectors.down)
local lx, ly = arrowCentre(sectors.left)
check("each arrow's centre is on its axis, 49px from the pad centre",
    near(ux, HALF) and near(uy, HALF - 49)
        and near(rx, HALF + 49) and near(ry, HALF)
        and near(dx, HALF) and near(dy, HALF + 49)
        and near(lx, HALF - 49) and near(ly, HALF),
    string.format("up (%.1f,%.1f) right (%.1f,%.1f)", ux, uy, rx, ry))
check("the up chevron: strokes lean back at -45 and +45, 14x4",
    sectors.up.arrows[1].Rotation == -45 and sectors.up.arrows[2].Rotation == 45
        and sectors.up.arrows[1].Size.X.Offset == 14 and sectors.up.arrows[1].Size.Y.Offset == 4)
check("the right/down/left chevrons are the up chevron turned 90/180/270",
    sectors.right.arrows[1].Rotation == 45 and sectors.right.arrows[2].Rotation == 135
        and sectors.down.arrows[1].Rotation == 135 and sectors.down.arrows[2].Rotation == 225
        and sectors.left.arrows[1].Rotation == 225 and sectors.left.arrows[2].Rotation == 315)
check("arrows are plain frames (no font glyphs)", sectors.up.arrows[1].ClassName == "Frame")

-- Only the surface is interactive, so there is no seam to fall into and nothing
-- to land on "wrong".
local interactive = 0
for _, instance in ipairs(Env.instances) do
    if instance.ClassName == "TextButton" and instance.Parent == pad then
        interactive += 1
    end
end
check("exactly one interactive button on the pad", interactive == 1, interactive)

-- The pad container's on-screen rectangle, as Roblox would report it.
pad.AbsolutePosition = Vector2.new(24, 380)
pad.AbsoluteSize = Vector2.new(152, 152)
local cx = 24 + 76
local cy = 380 + 76

local function touchAt(x: number, y: number)
    return {
        UserInputType = Enum.UserInputType.Touch,
        Position = Vector3.new(x, y, 0),
    }
end
local function begin(input)
    surface.InputBegan:Fire(input)
end
local function drag(input, x: number, y: number)
    input.Position = Vector3.new(x, y, 0)
    Env.fire("InputChanged", input)
end
local function release(input)
    Env.fire("InputEnded", input)
end
local function dirs(): string
    return table.concat(Input.getDirs(), ",")
end

---------------------------------------------------------------- 落点即方向
-- Landing on a sector steers at once, like pressing a key.
local function landOn(ox: number, oy: number): string
    local t = touchAt(cx + ox, cy + oy)
    begin(t)
    local result = dirs()
    release(t)
    return result
end
check("landing on the right sector moves right", landOn(50, 0) == "right")
check("landing on the left sector moves left", landOn(-50, 0) == "left")
check("landing on the up sector moves up", landOn(0, -50) == "up")
check("landing on the down sector moves down", landOn(0, 50) == "down")
check("near the inner edge of the ring still steers", landOn(0, -24) == "up")
check("near the outer edge of the ring still steers", landOn(72, 0) == "right")
check("the diagonal seam goes to the nearer axis (right)", landOn(40, 26) == "right")
check("the diagonal seam goes to the nearer axis (down)", landOn(26, 40) == "down")
check("past the ring but inside the hit margin still steers", landOn(96, 0) == "right")
check("lifting stops", dirs() == "", dirs())

---------------------------------------------------------------- 中心圆钮的滞回
-- Landing on the hub is silent, sliding out starts, easing back stops.
local hubTouch = touchAt(cx + 11, cy)
begin(hubTouch)
check("landing on the hub does nothing", dirs() == "", dirs())
drag(hubTouch, cx + 17, cy)
check("still inside the 18px engage radius", dirs() == "", dirs())
drag(hubTouch, cx + 19, cy)
check("sliding past 18px starts steering", dirs() == "right", dirs())
drag(hubTouch, cx + 13, cy)
check("easing back to 13px keeps steering (hysteresis)", dirs() == "right", dirs())
drag(hubTouch, cx + 9, cy)
check("coming back inside 11px stops", dirs() == "", dirs())
drag(hubTouch, cx + 13, cy)
check("13px from rest is silent again (the band re-arms)", dirs() == "", dirs())
release(hubTouch)

---------------------------------------------------------------- 不抬手滑动换向
-- The reason for the rewrite: turning without lifting.
local slide = touchAt(cx + 50, cy)
begin(slide)
check("land on the right sector", dirs() == "right", dirs())
drag(slide, cx + 50, cy - 18)
check("a little upward drift keeps right", dirs() == "right", dirs())
drag(slide, cx + 30, cy - 40)
check("sliding on to the up sector turns up without lifting", dirs() == "up", dirs())
drag(slide, cx + 42, cy - 40)
check("a wobble where right is only slightly stronger does not flip back (axis hysteresis)", dirs() == "up", dirs())
drag(slide, cx + 48, cy - 40)
check("a clearly stronger right does turn back", dirs() == "right", dirs())
drag(slide, cx + 30, cy - 40)
check("and up again from there", dirs() == "up", dirs())
drag(slide, cx + 46, cy - 18)
check("sliding back toward right turns right again", dirs() == "right", dirs())
drag(slide, cx + 18, cy + 46)
check("and round to the down sector", dirs() == "down", dirs())
drag(slide, cx - 46, cy + 18)
check("and on to the left sector", dirs() == "left", dirs())
release(slide)
check("one lift stops it all", dirs() == "", dirs())

-- Straight across the hub is a stop in the middle and a restart on the far side.
local across = touchAt(cx + 44, cy)
begin(across)
drag(across, cx, cy)
check("passing through the hub stops", dirs() == "", dirs())
drag(across, cx - 14, cy)
check("14px past the centre is still the hub", dirs() == "", dirs())
drag(across, cx - 20, cy)
check("20px past the centre reverses", dirs() == "left", dirs())
drag(across, cx + 44, cy)
check("a one-event jump straight across reverses at once", dirs() == "right", dirs())
release(across)

-- The thumb may leave the ring and the hit surface; it keeps steering until lifted.
local far = touchAt(cx + 50, cy)
begin(far)
drag(far, cx + 400, cy + 20)
check("far outside the pad it still steers right", dirs() == "right", dirs())
drag(far, cx + 400, cy + 700)
check("and swings round to down out there", dirs() == "down", dirs())
Env.fire("InputChanged", { UserInputType = Enum.UserInputType.Touch, Position = Vector3.new(cx - 300, cy, 0) })
check("another finger's movement is not ours", dirs() == "down", dirs())
release(far)
check("lifting stops", dirs() == "", dirs())

---------------------------------------------------------------- 手指归属
-- Only the first finger owns the pad.
local first = touchAt(cx + 50, cy)
local second = touchAt(cx - 50, cy)
begin(first)
begin(second)
check("a second finger on the pad is ignored", dirs() == "right", dirs())
drag(second, cx, cy - 50)
check("and so is its movement", dirs() == "right", dirs())
release(second)
check("lifting the second finger changes nothing", dirs() == "right", dirs())
surface.InputEnded:Fire(first)
check("the GUI losing the touch does not stop the pad", dirs() == "right", dirs())
release(first)
check("lifting the owner stops it", dirs() == "", dirs())
second.Position = Vector3.new(cx - 50, cy, 0)
begin(second)
check("a new finger takes over after the first lifted", dirs() == "left", dirs())
release(second)

---------------------------------------------------------------- 视觉反馈
local function uniform(sector, test): boolean
    for _, bar in ipairs(sector.bars) do
        if not test(bar) then
            return false
        end
    end
    return true
end
local function lit(direction: string): boolean
    local sector = sectors[direction]
    return uniform(sector, function(bar)
        return bar.BackgroundTransparency == 0.06 and bar.BackgroundColor3.B > bar.BackgroundColor3.R
    end) and sector.arrows[1].BackgroundTransparency == 0 and sector.arrows[2].BackgroundTransparency == 0
end
local function idle(direction: string): boolean
    local sector = sectors[direction]
    return uniform(sector, function(bar)
        return bar.BackgroundTransparency == 0.42 and bar.BackgroundColor3.B < 100
    end) and sector.arrows[1].BackgroundTransparency > 0.2
end
local function allIdle(): boolean
    return idle("up") and idle("right") and idle("down") and idle("left")
        and hub.BackgroundTransparency == 0.3
        and thumb.Position.X.Offset == HALF and thumb.Position.Y.Offset == HALF
end
check("at rest every sector is idle and the dot is centred", allIdle())

local look = touchAt(cx + 50, cy)
begin(look)
check("pressing right lights every bar of the right sector and only that sector",
    lit("right") and idle("up") and idle("down") and idle("left"))
check("the hub firms up while steering", hub.BackgroundTransparency < 0.3, hub.BackgroundTransparency)
check("the dot leans toward the pressed sector",
    thumb.Position.X.Offset == HALF + 8 and thumb.Position.Y.Offset == HALF,
    tostring(thumb.Position.X.Offset) .. "," .. tostring(thumb.Position.Y.Offset))
drag(look, cx, cy - 50)
check("sliding up moves the light to the up sector", lit("up") and idle("right"))
check("and the dot follows", thumb.Position.X.Offset == HALF and thumb.Position.Y.Offset == HALF - 8)
release(look)
check("lifting puts every sector, arrow and the dot back", allIdle())

---------------------------------------------------------------- 鼠标（桌面调试）
begin({ UserInputType = Enum.UserInputType.MouseButton1, Position = Vector3.new(cx - 50, cy, 0) })
check("a mouse press steers", dirs() == "left", dirs())
Env.fire("InputChanged", { UserInputType = Enum.UserInputType.MouseMovement, Position = Vector3.new(cx, cy - 50, 0) })
check("mouse movement while pressed slides to up", dirs() == "up", dirs())
Env.fire("InputEnded", { UserInputType = Enum.UserInputType.MouseButton1, Position = Vector3.new(cx, cy - 50, 0) })
check("mouse buttons are matched by object, so a different release object is ignored", dirs() == "up", dirs())
TouchModule.reset()
check("reset clears it", dirs() == "", dirs())
check("and puts the visuals back", allIdle())

---------------------------------------------------------------- 释放路径
local held = touchAt(cx + 50, cy)
begin(held)
check("held before disabling", dirs() == "right", dirs())
Input.setEnabled(false)
check("disabling releases the pad", dirs() == "", dirs())
check("and puts the visuals back", allIdle())
begin(touchAt(cx + 50, cy))
check("presses are ignored while disabled", dirs() == "", dirs())
Input.setEnabled(true)
release(held)
check("a stale lift after re-enable is harmless", dirs() == "", dirs())

local hidden = touchAt(cx, cy + 50)
begin(hidden)
check("held before hiding", dirs() == "down", dirs())
Input.setControlsVisible(false)
check("hiding the controls releases", dirs() == "", dirs())
Input.setControlsVisible(true)
drag(hidden, cx + 50, cy)
check("the released finger does not steer any more", dirs() == "", dirs())
release(hidden)

local lost = touchAt(cx, cy - 50)
begin(lost)
Env.fire("WindowFocusReleased")
check("focus loss releases the pad", dirs() == "", dirs())
drag(lost, cx + 50, cy)
check("and the old finger does not come back to life", dirs() == "", dirs())
release(lost)
check("controls remain shown after all that", controls.Visible == true)
check("nothing left over", table.concat(Input.sample(), ",") == "")

TestLib.finish()
