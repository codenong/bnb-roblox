-- tests/profile/profile_service_test.luau
local TestLib = require("./testlib")
local check = TestLib.check

local ProfileService = require("./ProfileService")

local function newPlayer(userId: number, name: string?)
    return {
        UserId = userId,
        DisplayName = name or ("P" .. tostring(userId)),
    }
end

local function newFakeStore()
    local store = {
        loads = 0,
        saves = {},
        nextLockId = 0,
        loadHook = nil,
        loadError = nil,
        saveError = nil,
        lockLost = false,
    }

    function store:load(userId: number)
        self.loads += 1
        if self.loadHook then
            self.loadHook()
        end
        if self.loadError then
            return nil, self.loadError
        end
        self.nextLockId += 1
        local data = {
            userId = userId,
            currency = 0,
            settings = { char = "baobao" },
        }
        return {
            userId = userId,
            sessionId = "fake",
            lockId = "lock-" .. tostring(self.nextLockId),
            data = data,
        }
    end

    function store:save(handle, release: boolean?)
        table.insert(self.saves, {
            userId = handle.userId,
            release = release == true,
            currency = handle.data.currency,
        })
        if self.saveError then
            local reason = self.saveError
            self.saveError = nil
            return false, reason
        end
        if self.lockLost then
            return false, "lock_lost"
        end
        return true
    end

    return store
end

local function newQueue()
    local queue = {}
    return {
        spawn = function(fn)
            table.insert(queue, fn)
        end,
        drain = function()
            while #queue > 0 do
                local fn = table.remove(queue, 1)
                fn()
            end
        end,
        length = function()
            return #queue
        end,
    }
end

local function newService(store, opts)
    opts = opts or {}
    local active = if opts.active == nil then true else opts.active
    local locksLost = {}
    local service = ProfileService.new({
        store = store,
        isActive = function(_player)
            return active
        end,
        spawn = opts.spawn or function(fn)
            fn()
        end,
        sleep = opts.sleep or function(_seconds: number) end,
        warn = function(_message: string) end,
        autoSaveSeconds = 30,
        shutdownSeconds = 1,
        onLockLost = function(player, reason)
            table.insert(locksLost, { player = player, reason = reason })
        end,
    })
    return service, {
        setActive = function(value)
            active = value
        end,
        locksLost = locksLost,
    }
end

---------------------------------------------------------------- load / commit / release 的串行 worker

do
    local store = newFakeStore()
    local queue = newQueue()
    local service = newService(store, { spawn = queue.spawn })

    local player = newPlayer(1, "Alice")
    local profile, reason = service:load(player)
    check("load succeeds", profile ~= nil, reason)
    check("profile is loaded", service:isLoaded(player))
    check("getProfile returns the same table", service:getProfile(player) == profile)

    local secondPlayer = newPlayer(1, "Alice again")
    local duplicate, duplicateReason = service:load(secondPlayer)
    check("same UserId is rejected", duplicate == nil and duplicateReason == "duplicate", duplicateReason)

    profile.currency = 4
    local savesBefore = #store.saves
    service:commitMany({ { player = player } })
    check("commitMany returns before the worker runs", #store.saves == savesBefore)
    check("commitMany queues one worker", queue.length() == 1, queue.length())
    queue.drain()
    check("commitMany saves after the queue drains", #store.saves == savesBefore + 1)
    check("commitMany does not release", store.saves[#store.saves].release == false)

    service:release(player)
    check("release returns before the worker runs", #store.saves == savesBefore + 1)
    check("release keeps the state until it finishes", service:isLoaded(player))
    queue.drain()
    check("release saves the latest data", store.saves[#store.saves].release == true)
    check("release writes the latest value", store.saves[#store.saves].currency == 4)
    check("release removes the loaded state", not service:isLoaded(player))
end

---------------------------------------------------------------- 快速重连：等待旧会话释放后再加载

do
    local store = newFakeStore()
    local queue = newQueue()
    local sleeps = 0
    local service = newService(store, {
        spawn = queue.spawn,
        sleep = function(_seconds: number)
            sleeps += 1
            queue.drain()
        end,
    })

    local oldPlayer = newPlayer(8, "Hana")
    service:load(oldPlayer)
    service:release(oldPlayer)

    local rejoined = newPlayer(8, "Hana again")
    local profile, reason = service:load(rejoined, {
        duplicateRetries = 3,
        duplicateRetrySeconds = 0,
    })
    check("a quick rejoin waits for the old release", profile ~= nil, reason)
    check("the rejoin retried once", sleeps == 1, sleeps)
    check("the old state is released", not service:isLoaded(oldPlayer))
    check("the new player is loaded", service:isLoaded(rejoined))
    check("the profile was loaded again", store.loads == 2, store.loads)
end

---------------------------------------------------------------- 快速重连：等待超时后如实失败，释放后仍可再加载

do
    local store = newFakeStore()
    local queue = newQueue()
    local sleeps = 0
    local service = newService(store, {
        spawn = queue.spawn,
        sleep = function(_seconds: number)
            sleeps += 1
        end,
    })

    local oldPlayer = newPlayer(9, "Ivy")
    service:load(oldPlayer)
    service:release(oldPlayer)

    local rejoined = newPlayer(9, "Ivy again")
    local profile, reason = service:load(rejoined, {
        duplicateRetries = 2,
        duplicateRetrySeconds = 0,
    })
    check("a stuck release reports duplicate", profile == nil and reason == "duplicate", reason)
    check("it uses every retry", sleeps == 2, sleeps)
    check("the old profile is still closing", service:isLoaded(oldPlayer))

    queue.drain()
    check("the release can still finish later", not service:isLoaded(oldPlayer))
    local retried, retriedReason = service:load(rejoined, { duplicateRetries = 0 })
    check("a later load succeeds", retried ~= nil, retriedReason)
    check("the later load reaches the store", store.loads == 2, store.loads)
end

---------------------------------------------------------------- 保存后立刻 release：只写最终快照

do
    local store = newFakeStore()
    local queue = newQueue()
    local service = newService(store, { spawn = queue.spawn })
    local player = newPlayer(2, "Bob")

    service:load(player)
    service:getProfile(player).currency = 9
    service:commitMany({ { player = player } })
    service:release(player)
    queue.drain()

    check("release after a pending commit does not double-save", #store.saves == 1, #store.saves)
    check("the single write is the final release", store.saves[1].release == true)
    check("the final release has the newest data", store.saves[1].currency == 9)
end

---------------------------------------------------------------- 加载期间离开

do
    local store = newFakeStore()
    local queue = newQueue()
    local service, control = newService(store, { spawn = queue.spawn })
    control.setActive(false)
    local player = newPlayer(3, "Cara")

    local profile, reason = service:load(player)
    check("inactive player is not loaded", profile == nil and reason == "inactive", reason)
    check("inactive load does not call the store", store.loads == 0, store.loads)

    control.setActive(true)
    store.loadHook = function()
        control.setActive(false)
    end
    local leftProfile, leftReason = service:load(player)
    check("leaving during load is cancelled", leftProfile == nil and leftReason == "cancelled", leftReason)
    check("the acquired handle is released", #store.saves == 1 and store.saves[1].release == true)
    check("a cancelled load keeps no state", not service:isLoaded(player))
end

---------------------------------------------------------------- step 心跳与普通保存失败重试

do
    local store = newFakeStore()
    local queue = newQueue()
    local service = newService(store, { spawn = queue.spawn })
    local player = newPlayer(4, "Dora")
    service:load(player)

    local savesBefore = #store.saves
    service:step(29)
    check("step before the interval does not save", #store.saves == savesBefore)
    service:step(1)
    check("step accumulates to the interval", queue.length() == 1, queue.length())
    queue.drain()
    check("heartbeat saves", #store.saves == savesBefore + 1)

    store.saveError = "save_failed"
    service:release(player)
    queue.drain()
    check("failed release keeps the profile", service:isLoaded(player))
    check("failed release requested a retry", store.saves[#store.saves].release == true)

    service:step(30)
    queue.drain()
    check("a later heartbeat retries the release", #store.saves >= savesBefore + 3)
    check("retried release succeeds", not service:isLoaded(player))
end

---------------------------------------------------------------- lock_lost 回调

do
    local store = newFakeStore()
    local queue = newQueue()
    local service, control = newService(store, { spawn = queue.spawn })
    local player = newPlayer(5, "Eve")
    service:load(player)
    service:getProfile(player).currency = 1

    store.lockLost = true
    service:commitMany({ { player = player } })
    queue.drain()

    check("lock loss stops the profile", not service:isLoaded(player))
    check("lock loss invokes onLockLost", #control.locksLost == 1, #control.locksLost)
    check("lock loss reports the player", control.locksLost[1].player == player)
    check("lock loss reports the reason", control.locksLost[1].reason == "lock_lost")
end

---------------------------------------------------------------- shutdown

do
    local store = newFakeStore()
    local service = newService(store, {
        spawn = function(fn)
            fn()
        end,
    })
    local first = newPlayer(6, "Finn")
    local second = newPlayer(7, "Gia")
    service:load(first)
    service:load(second)
    service:getProfile(first).currency = 6
    service:getProfile(second).currency = 7

    service:shutdown()
    check("shutdown releases the first profile", not service:isLoaded(first))
    check("shutdown releases the second profile", not service:isLoaded(second))
    local released = 0
    for _, save in ipairs(store.saves) do
        if save.release then
            released += 1
        end
    end
    check("shutdown performs one release per profile", released == 2, released)
end

TestLib.finish()
