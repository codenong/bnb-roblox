-- Input mapping and gamepad hand-over, using the real Input.luau with a stubbed
-- UserInputService / GuiService.
local TestLib = require("./testlib")
local check = TestLib.check

local Env = require("./ClientEnv")
local Enum = Env.Enum

-- Like a real client: Roblox's default camera script is already running and has
-- claimed Left/Right before our Input module starts.
Env.installDefaultCamera()

local Input = require("./Input")
Input.init({})
Input.setEnabled(true)

local lastProcessed = false

-- A key press the way the engine delivers it: ContextActionService bindings get
-- the first look, then UserInputService.InputBegan fires with gameProcessedEvent
-- telling whether a binding swallowed it. `forceProcessed` simulates input that a
-- GUI (e.g. a focused chat box) consumed.
local function begin(keyName: string, forceProcessed: boolean?)
    local input = { KeyCode = Enum.KeyCode[keyName], UserInputType = Enum.UserInputType.Keyboard }
    local processed = forceProcessed == true
    if not processed then
        processed = Env.dispatchKey(input, Enum.UserInputState.Begin)
    end
    lastProcessed = processed
    Env.fire("InputBegan", input, processed)
end
local function finish(keyName: string)
    local input = { KeyCode = Enum.KeyCode[keyName], UserInputType = Enum.UserInputType.Keyboard }
    Env.dispatchKey(input, Enum.UserInputState.End)
    Env.fire("InputEnded", input)
end
local function stick(x: number, y: number)
    Env.fire("InputChanged", { KeyCode = Enum.KeyCode.Thumbstick1, Position = { X = x, Y = y } })
end
local function dirs(): string
    return table.concat(Input.getDirs(), ",")
end

---------------------------------------------------------------- 回归：默认相机占用了左/右方向键
-- Bug report: Up/Down arrows moved the player but Left/Right did nothing. The
-- camera script swallows Left/Right, so they reach InputBegan as "processed".
do
    local cameraCallsBefore = Env.cameraKeyCalls

    begin("Left")
    check("Left arrow moves left even though the camera wants it", dirs() == "left", dirs())
    finish("Left")
    begin("Right")
    check("Right arrow moves right even though the camera wants it", dirs() == "right", dirs())
    finish("Right")
    check("arrow keys are released cleanly", dirs() == "", dirs())

    check("the arrow keys never reach the camera script", Env.cameraKeyCalls == cameraCallsBefore, Env.cameraKeyCalls - cameraCallsBefore)

    begin("Up")
    check("Up arrow swallowed by the game binding", lastProcessed == true)
    check("Up arrow still moves up", dirs() == "up", dirs())
    finish("Up")

    begin("W")
    check("W is not claimed (reaches InputBegan unprocessed)", lastProcessed == false)
    check("W still moves up", dirs() == "up", dirs())
    finish("W")

    -- Held together with the other layout, then released one at a time.
    begin("Left")
    begin("A")
    check("Left arrow + A is a single 'left'", dirs() == "left", dirs())
    finish("A")
    check("Left arrow still held after A is released", dirs() == "left", dirs())
    finish("Left")
    check("all released", dirs() == "", dirs())

    -- The engine can take the key away (another binding, focus change): Cancel.
    local rightInput = { KeyCode = Enum.KeyCode.Right, UserInputType = Enum.UserInputType.Keyboard }
    begin("Right")
    check("Right held", dirs() == "right", dirs())
    Env.dispatchKey(rightInput, Enum.UserInputState.Cancel)
    check("Cancel releases the arrow key", dirs() == "", dirs())
    finish("Right")

    -- Arrow keys do nothing while input is disabled (waiting / spectating).
    Input.setEnabled(false)
    begin("Left")
    check("arrow keys ignored while disabled", dirs() == "", dirs())
    finish("Left")
    Input.setEnabled(true)
end

---------------------------------------------------------------- 键盘 / 方向键 / 手柄十字键
local groups = {
    up = { "W", "Up", "DPadUp" },
    down = { "S", "Down", "DPadDown" },
    left = { "A", "Left", "DPadLeft" },
    right = { "D", "Right", "DPadRight" },
}
for direction, keys in pairs(groups) do
    for _, keyName in ipairs(keys) do
        begin(keyName)
        check(keyName .. " moves " .. direction, dirs() == direction, dirs())
        finish(keyName)
        check(keyName .. " release stops", dirs() == "", dirs())
    end
end

-- Order is oldest press first; the newest press is the last entry.
begin("Up")
begin("Right")
check("two directions keep press order", dirs() == "up,right", dirs())
finish("Up")
check("releasing the older one keeps the newer", dirs() == "right", dirs())
finish("Right")

-- WASD and arrow keys held together do not duplicate or fight each other.
begin("W")
begin("Up")
check("W + Up is a single 'up'", dirs() == "up", dirs())
finish("W")
check("Up still held after W is released", dirs() == "up", dirs())
finish("Up")
check("both released", dirs() == "", dirs())

-- Keyboard and gamepad D-pad can be mixed.
begin("Left")
begin("DPadDown")
check("arrow key + D-pad combine", dirs() == "left,down", dirs())
finish("Left")
finish("DPadDown")

---------------------------------------------------------------- 手柄左摇杆
stick(0.9, 0)
check("stick right", dirs() == "right", dirs())
stick(-0.9, 0)
check("stick left", dirs() == "left", dirs())
stick(0, 0.9) -- stick up reports +Y
check("stick up", dirs() == "up", dirs())
stick(0, -0.9)
check("stick down", dirs() == "down", dirs())
stick(0.2, 0.1)
check("stick inside the dead zone does nothing", dirs() == "", dirs())
stick(0.9, 0)
stick(0, 0)
check("stick centred stops", dirs() == "", dirs())
stick(0.9, 0.5)
check("stick picks the dominant axis", dirs() == "right", dirs())
stick(0, 0)

---------------------------------------------------------------- 手柄摇杆：滞回 / 轴向偏置 / 回弹保护
-- Tuning in InputGamepad: engage 0.40, release 0.28, axis bias 1.15, reverse
-- guard 0.10 s (reverse needs 0.70 inside it). The clock is injected so the
-- time-based guard is deterministic.
do
    local Gamepad = require("./InputGamepad")
    local now = 0
    Gamepad._setClock(function()
        return now
    end)
    Gamepad.reset()
    stick(0, 0)

    -- Engage / release hysteresis.
    stick(0.30, 0)
    check("below the engage threshold from rest does nothing", dirs() == "", dirs())
    stick(0.45, 0)
    check("past the engage threshold starts moving", dirs() == "right", dirs())
    stick(0.30, 0)
    check("easing off to 0.30 keeps moving (still above release)", dirs() == "right", dirs())
    stick(0.25, 0)
    check("falling below release stops", dirs() == "", dirs())
    stick(0.30, 0)
    check("0.30 from rest is silent again (the band re-arms)", dirs() == "", dirs())

    -- Noise around the old single 0.35 threshold used to toggle the direction.
    stick(0.45, 0)
    local last, changes = dirs(), 0
    for _, value in ipairs({ 0.36, 0.44, 0.33, 0.41, 0.31, 0.43, 0.35, 0.40, 0.29 }) do
        stick(value, 0)
        if dirs() ~= last then
            changes += 1
            last = dirs()
        end
    end
    check("noise between 0.29 and 0.44 never toggles the direction", changes == 0 and last == "right", changes)
    stick(0, 0)

    -- Axis bias: turning a corner needs the other axis to win by 15%.
    stick(0.8, 0)
    check("moving right", dirs() == "right", dirs())
    stick(0.8, 0.85)
    check("a slightly stronger vertical does not turn the corner", dirs() == "right", dirs())
    stick(0.8, 0.95)
    check("a clearly stronger vertical turns the corner", dirs() == "up", dirs())
    stick(0.8, 0.85)
    check("and does not flip back on a small wobble", dirs() == "up", dirs())
    stick(0.9, 0.2)
    check("a clearly horizontal stick goes back to right", dirs() == "right", dirs())
    stick(0, 0)

    -- Spring-back: letting go sweeps through the centre and overshoots.
    now = 10
    stick(1, 0)
    check("held right", dirs() == "right", dirs())
    now = 10.02
    stick(0.4, 0)
    now = 10.04
    stick(0.1, 0)
    check("released", dirs() == "", dirs())
    now = 10.06
    stick(-0.5, 0)
    check("spring-back overshoot to -0.5 is ignored", dirs() == "", dirs())
    now = 10.08
    stick(-0.65, 0)
    check("even -0.65 inside the guard is ignored", dirs() == "", dirs())
    now = 10.10
    stick(0, 0)

    -- Once the guard has run out the same push is a real reverse.
    now = 11
    stick(1, 0)
    now = 11.02
    stick(0, 0)
    now = 11.30
    stick(-0.5, 0)
    check("after the guard a -0.5 push reverses", dirs() == "left", dirs())
    stick(0, 0)

    -- A deliberate, full-strength reverse is not delayed by the guard.
    now = 12
    stick(1, 0)
    now = 12.03
    stick(-0.9, 0)
    check("a full-strength reverse goes through immediately", dirs() == "left", dirs())
    stick(0, 0)

    -- A weak sign flip with no sample in between is also spring-back.
    now = 13
    stick(1, 0)
    now = 13.01
    stick(-0.3, 0)
    check("a direct flip to -0.3 stops instead of reversing", dirs() == "", dirs())
    now = 13.40
    stick(-0.3, 0)
    check("-0.3 from rest stays silent", dirs() == "", dirs())
    stick(0, 0)

    -- Turning a corner is not a reversal: the guard never delays it.
    now = 14
    stick(1, 0)
    now = 14.01
    stick(0, 0.6)
    check("a perpendicular turn inside the guard is immediate", dirs() == "up", dirs())
    stick(0, 0)

    -- A reset closes an open hysteresis band.
    now = 15
    stick(1, 0)
    check("held right before reset", dirs() == "right", dirs())
    Gamepad.reset()
    stick(0.30, 0)
    check("after a reset 0.30 is below engage again", dirs() == "", dirs())
    stick(0, 0)

    Gamepad._setClock(os.clock)
end

---------------------------------------------------------------- 放泡泡 / 用道具
local function fired(event)
    return event.fireCount
end
local placeBefore, useBefore = fired(Input.placePressed), fired(Input.usePressed)
begin("Space")
begin("ButtonA")
check("Space and gamepad A place a bubble", fired(Input.placePressed) == placeBefore + 2, fired(Input.placePressed) - placeBefore)
for _, keyName in ipairs({ "E", "LeftShift", "RightShift", "LeftControl", "RightControl", "ButtonB", "ButtonX" }) do
    begin(keyName)
end
check("E / Shift / Ctrl / gamepad B and X use an item", fired(Input.usePressed) == useBefore + 7, fired(Input.usePressed) - useBefore)
check("use keys never place a bubble", fired(Input.placePressed) == placeBefore + 2)

---------------------------------------------------------------- 已被界面处理的按键不触发（聊天框等）
local before = fired(Input.placePressed)
begin("Space", true)
begin("W", true)
check("processed inputs are ignored", dirs() == "" and fired(Input.placePressed) == before, dirs())
begin("W")
Env.fire("InputEnded", { KeyCode = Enum.KeyCode.W })
check("release is always honoured", dirs() == "")

---------------------------------------------------------------- 关闭输入 / 失去焦点
Input.setEnabled(false)
begin("W")
begin("Space")
check("disabled input does nothing", dirs() == "" and fired(Input.placePressed) == before)
Input.setEnabled(true)

begin("Up")
begin("Right")
Env.fire("WindowFocusReleased")
check("losing window focus releases held keys", dirs() == "", dirs())
finish("Up")
finish("Right")

begin("Down")
Input.setEnabled(false)
check("disabling clears held keys", dirs() == "", dirs())
Input.setEnabled(true)

---------------------------------------------------------------- 手柄：对局中交还给游戏，选角界面恢复界面导航
local gui = Env.guiService
Input.setEnabled(true)
check("playing: auto-select is off", gui.AutoSelectGuiEnabled == false)
check("playing: GUI navigation is off", gui.GuiNavigationEnabled == false)
check("playing: nothing stays selected", gui.SelectedObject == nil)

Input.setEnabled(false)
check("not playing: auto-select is back on", gui.AutoSelectGuiEnabled == true)
check("not playing: GUI navigation is back on", gui.GuiNavigationEnabled == true)

TestLib.finish()
