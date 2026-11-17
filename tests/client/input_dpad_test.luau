-- Touch direction pad (the default layout): four press-and-hold buttons in
-- the joystick's old spot, one source per button, press order = priority,
-- using the real Input.luau with stubbed GUI objects.
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
local up = find("DPadUp")
local down = find("DPadDown")
local left = find("DPadLeft")
local right = find("DPadRight")

check("direction pad built with all four buttons",
    pad ~= nil and up ~= nil and down ~= nil and left ~= nil and right ~= nil)
check("direction-pad mode builds no joystick",
    find("Joystick") == nil and find("JoystickKnob") == nil and find("JoystickSurface") == nil)
check("bubble and item buttons remain", find("泡泡") ~= nil and find("道具") ~= nil)
check("touch controls start hidden", controls.Visible == false)
Input.setControlsVisible(true)
check("touch controls can be shown", controls.Visible == true)

-- The pad takes the joystick base's exact spot: anchored bottom-left at
-- (24, H-24), 106x106, with 46px round buttons.
check("the pad sits where the joystick was",
    pad.Position.X.Offset == 77 and pad.Position.Y.Offset == -24 and pad.Size.X.Offset == 106,
    tostring(pad.Position.X.Offset) .. "," .. tostring(pad.Position.Y.Offset) .. "," .. tostring(pad.Size.X.Offset))
check("the buttons are 46px wide",
    up.Size.X.Offset == 46 and right.Size.X.Offset == 46,
    tostring(up.Size.X.Offset) .. "/" .. tostring(right.Size.X.Offset))

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
check("pressing highlights the button", right.BackgroundTransparency == 0.5, tostring(right.BackgroundTransparency))
press(up)
check("held buttons keep press order, newest last", dirs() == "right,up", dirs())
lift(right)
check("lifting right leaves up held", dirs() == "up", dirs())
check("release clears the highlight", right.BackgroundTransparency == 0.72, tostring(right.BackgroundTransparency))
lift(up)
check("lifting the last button stops", dirs() == "", dirs())

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

-- Two fingers resting on one button: the direction survives the first lift.
press(up)
press(up)
check("two fingers on one button hold up", dirs() == "up", dirs())
lift(up)
check("the first lift keeps it held", dirs() == "up", dirs())
lift(up)
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
