-- Roblox-independent globals for loading the real Main.client.luau in the Luau
-- CLI. tests/run.sh prepends aliases for game/Instance/Enum/script to the copy.
local Env = {
    remotes = {}, -- name -> fake remote (handler = OnClientEvent callback)
    renderStepped = nil, -- RenderStepped callback captured from Main
    syncResponse = nil, -- what GetSync:InvokeServer() returns
    invokeResponses = {}, -- name -> value/function returned by that remote's InvokeServer
    lastGrid = nil,
    gridCalls = 0,
    loadingTimedOut = false,
}

-- Property sets are stored; any method call is a harmless no-op.
local function newInstance()
    return setmetatable({}, {
        __index = function()
            return function() end
        end,
    })
end

-- BindableEvent that counts how often it was fired (Input.placePressed etc.).
local function newBindable()
    return {
        fireCount = 0,
        Fire = function(self)
            self.fireCount += 1
        end,
        Event = { Connect = function() end },
    }
end

Env.Instance = {
    new = function(className)
        if className == "BindableEvent" then
            return newBindable()
        end
        return newInstance()
    end,
}

-- Enum.<Group>.<Name> is a stable table with a Name field, so it can be used as a
-- table key (MOVE_KEYS[input.KeyCode]) and read as KeyCode.Name like in Roblox.
Env.Enum = setmetatable({}, {
    __index = function(t, group)
        local items = {}
        local proxy = setmetatable({}, {
            __index = function(_, name)
                local item = items[name]
                if not item then
                    item = { Name = name, EnumType = group }
                    if group == "ContextActionPriority" then
                        item.Value = ({ Low = 1000, Medium = 2000, Default = 2000, High = 3000 })[name]
                    end
                    items[name] = item
                end
                return item
            end,
        })
        rawset(t, group, proxy)
        return proxy
    end,
})

-- UserInputService signals: Env.fire("InputBegan", input, processed) calls every
-- handler Input.init connected.
local signalHandlers = {}
local function makeSignal(name)
    signalHandlers[name] = {}
    return {
        Connect = function(_, fn)
            table.insert(signalHandlers[name], fn)
        end,
    }
end
function Env.fire(name, ...)
    for _, fn in ipairs(signalHandlers[name]) do
        fn(...)
    end
end

-- ContextActionService with Roblox-like dispatch. Env.dispatchKey(input, state)
-- offers the key to the matching bindings from the highest priority down; a Sink
-- (or nil) result swallows it, a Pass result moves on. It returns whether the key
-- was swallowed, which is what InputBegan reports as gameProcessedEvent.
local bindings = {}
local ContextActionService = {}
function ContextActionService:BindActionAtPriority(name, fn, _touchButton, priority, ...)
    local keys = {}
    for _, key in ipairs({ ... }) do
        keys[key] = true
    end
    bindings[name] = { name = name, fn = fn, priority = priority, keys = keys }
end
function ContextActionService:BindAction(name, fn, touchButton, ...)
    self:BindActionAtPriority(name, fn, touchButton, 2000, ...)
end
function ContextActionService:UnbindAction(name)
    bindings[name] = nil
end
function Env.dispatchKey(input, state)
    local matching = {}
    for _, binding in pairs(bindings) do
        if binding.keys[input.KeyCode] then
            table.insert(matching, binding)
        end
    end
    table.sort(matching, function(a, b)
        return a.priority > b.priority
    end)
    for _, binding in ipairs(matching) do
        local result = binding.fn(binding.name, state, input)
        if result ~= Env.Enum.ContextActionResult.Pass then
            return true
        end
    end
    return false
end

-- What Roblox's default camera script does: it claims Left/Right (rotate) and I/O
-- (zoom) at default priority. Env.cameraKeyCalls counts what actually reached it.
Env.cameraKeyCalls = 0
function Env.installDefaultCamera()
    local E = Env.Enum
    ContextActionService:BindAction("RbxCameraKeypress", function()
        Env.cameraKeyCalls += 1
        return E.ContextActionResult.Sink
    end, false, E.KeyCode.Left, E.KeyCode.Right, E.KeyCode.I, E.KeyCode.O)
end

-- task.spawn runs the function as a coroutine right away; task.wait suspends it
-- until a test calls Env.advanceTasks(), which stands in for time passing.
Env.waits = 0
Env.threads = {}
Env.task = {
    spawn = function(fn, ...)
        local thread = coroutine.create(fn)
        table.insert(Env.threads, thread)
        local ok, err = coroutine.resume(thread, ...)
        if not ok then
            error(err, 0)
        end
        return thread
    end,
    wait = function(seconds)
        Env.waits += 1
        coroutine.yield()
        return seconds or 0
    end,
}
function Env.advanceTasks()
    for _, thread in ipairs(Env.threads) do
        if coroutine.status(thread) == "suspended" then
            local ok, err = coroutine.resume(thread)
            if not ok then
                error(err, 0)
            end
        end
    end
end

local services = {
    Players = {
        LocalPlayer = {
            WaitForChild = function()
                return {}
            end,
        },
    },
    ReplicatedStorage = {
        WaitForChild = function()
            return {
                WaitForChild = function(_, name)
                    return "./" .. name
                end,
            }
        end,
    },
    RunService = {
        RenderStepped = {
            Connect = function(_, fn)
                Env.renderStepped = fn
            end,
        },
    },
    UserInputService = {
        TouchEnabled = false,
        InputBegan = makeSignal("InputBegan"),
        InputEnded = makeSignal("InputEnded"),
        InputChanged = makeSignal("InputChanged"),
        WindowFocusReleased = makeSignal("WindowFocusReleased"),
    },
    ContextActionService = ContextActionService,
    GuiService = {
        AutoSelectGuiEnabled = true,
        GuiNavigationEnabled = true,
        SelectedObject = {},
    },
}
Env.guiService = services.GuiService

Env.game = {
    GetService = function(_, name)
        return services[name]
    end,
}

Env.script = {
    Parent = {
        WaitForChild = function(_, name)
            return "./" .. name
        end,
    },
}

return Env
