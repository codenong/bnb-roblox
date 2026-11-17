-- Touch direction pad (the default layout): a near-black ring of
-- press-and-hold pie sectors around a dead hole, one source per sector,
-- press order = priority, using the real Input.luau with stubbed GUI objects.
local TestLib = require("./testlib")
local check = TestLib.check

local Env = require("./ClientEnv")
local Enum = Env.Enum
local Vector2, Vector3 = Env.Vector2, Env.Vector3

Env.game:GetService("UserInputService").TouchEnabled = true

local TouchModule = require("./InputTouch")
check("direction pad is the default layout", TouchModule.USE_DIRECTION_PAD == true)

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
local up = find("DPadUpSeg1")
local down = find("DPadDownSeg1")
local left = find("DPadLeftSeg1")
local right = find("DPadRightSeg1")
local upMid = find("DPadUpSeg5")
local upLabel = find("DPadUpLabel")
local rightLabel = find("DPadRightLabel")
local centre = find("DPadCentre")
local mark = find("DPadCentreMark")

check("direction pad built with spokes, labels and the dead hole",
    pad ~= nil and up ~= nil and down ~= nil and left ~= nil and right ~= nil
        and upMid ~= nil and upLabel ~= nil and rightLabel ~= nil and centre ~= nil and mark ~= nil)
check("direction-pad mode builds no joystick",
    find("Joystick") == nil and find("JoystickKnob") == nil and find("JoystickSurface") == nil)
check("bubble and item buttons remain", find("泡泡") ~= nil and find("道具") ~= nil)
check("touch controls start hidden", controls.Visible == false)
Input.setControlsVisible(true)
check("touch controls can be shown", controls.Visible == true)

-- The pad keeps the joystick's bottom-left spot as a 160px ring: anchored at
-- (24, H-24). Each 90° sector is fanned from nine 14x48 spokes spanning the
-- 48px band (hole edge to rim), so ring and hole meet with no gap and the
-- 64px hole owns the middle.
check("the pad keeps the bottom-left spot, grown to 160px",
    pad.Position.X.Offset == 104 and pad.Position.Y.Offset == -24 and pad.Size.X.Offset == 160,
    tostring(pad.Position.X.Offset) .. "," .. tostring(pad.Position.Y.Offset) .. "," .. tostring(pad.Size.X.Offset))
check("each sector is fanned from rotated spokes across the band",
    up.Size.X.Offset == 14 and up.Size.Y.Offset == 48 and up.Rotation == -40
        and right.Size.X.Offset == 14 and right.Size.Y.Offset == 48 and right.Rotation == 50
        and upMid.Size.X.Offset == 14 and upMid.Rotation == 0,
    tostring(up.Size.X.Offset) .. "x" .. tostring(up.Size.Y.Offset)
        .. " rot " .. tostring(up.Rotation) .. "/" .. tostring(right.Rotation))
check("the centre dead hole is a 64px non-interactive circle with a marker",
    centre.ClassName == "Frame" and centre.Size.X.Offset == 64 and centre.Size.Y.Offset == 64
        and mark.Text == "×",
    centre.ClassName .. " " .. tostring(centre.Size.X.Offset))

local function press(button)
    button.InputBegan:Fire({
        UserInputType = Enum.UserInputType.Touch,
        Position = Vector3.new(0, 0, 0),
    })
end
local function lift(button)
    button.InputEnded:Fire({
        UserInputType = Enum.UserInputType.Touch,
        Position = Vector3.new(0, 0, 0),
    })
end
local function dirs(): string
    return table.concat(Input.getDirs(), ",")
end

press(right)
check("pressing right moves right", dirs() == "right", dirs())
check("pressing floods the sector blue and raises it above neighbours",
    right.BackgroundTransparency == 0 and rightLabel.TextTransparency == 0 and right.ZIndex == 50006,
    tostring(right.BackgroundTransparency) .. "/" .. tostring(rightLabel.TextTransparency)
        .. "/" .. tostring(right.ZIndex))
press(up)
check("held sectors keep press order, newest last", dirs() == "right,up", dirs())
lift(right)
check("lifting right leaves up held", dirs() == "up", dirs())
check("release restores the dark ring",
    right.BackgroundTransparency == 0 and rightLabel.TextTransparency == 0.3 and right.ZIndex == 50002,
    tostring(right.BackgroundTransparency) .. "/" .. tostring(rightLabel.TextTransparency)
        .. "/" .. tostring(right.ZIndex))
lift(up)
check("lifting the last sector stops", dirs() == "", dirs())

-- All four directions, one fresh press each.
local function pressOnly(button): string
    press(button)
    local result = dirs()
    lift(button)
    return result
end
check("down button moves down", pressOnly(down) == "down", dirs())
check("left button moves left", pressOnly(left) == "left", dirs())
check("up button moves up", pressOnly(up) == "up", dirs())
check("right button moves right", pressOnly(right) == "right", dirs())

-- Opposite buttons held together: both sources stay, order decides priority.
press(up)
press(down)
check("up then down are both held", dirs() == "up,down", dirs())
lift(up)
check("lifting the older one keeps down", dirs() == "down", dirs())
lift(down)
check("lifting the last one stops", dirs() == "", dirs())

-- Two fingers resting anywhere on one sector, on different spokes: the
-- direction survives the first lift.
press(up)
press(upMid)
check("two fingers on one sector hold up", dirs() == "up", dirs())
lift(up)
check("the first lift keeps it held", dirs() == "up", dirs())
lift(upMid)
check("the second lift stops", dirs() == "", dirs())

-- Mouse support: pressing with the mouse works, dragging off releases.
left.InputBegan:Fire({
    UserInputType = Enum.UserInputType.MouseButton1,
    Position = Vector3.new(0, 0, 0),
})
check("a mouse press moves left", dirs() == "left", dirs())
left.MouseLeave:Fire()
check("dragging the mouse off releases", dirs() == "", dirs())

-- Disabling input releases held buttons and ignores new presses.
press(right)
check("held before disabling", dirs() == "right", dirs())
Input.setEnabled(false)
check("disabling releases the button", dirs() == "", dirs())
press(right)
check("presses are ignored while disabled", dirs() == "", dirs())
Input.setEnabled(true)
lift(right)
check("a stale lift after re-enable is harmless", dirs() == "", dirs())

-- Hiding the controls releases; so does losing window focus.
press(right)
check("held before hiding", dirs() == "right", dirs())
Input.setControlsVisible(false)
check("hiding the controls releases", dirs() == "", dirs())
Input.setControlsVisible(true)
press(up)
Env.fire("WindowFocusReleased")
check("focus loss releases the button", dirs() == "", dirs())
lift(up)
check("controls remain shown after re-enabling", controls.Visible == true)
check("nothing left over", table.concat(Input.sample(), ",") == "")

TestLib.finish()
