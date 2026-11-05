-- tests/profile/profile_store_test.luau
local TestLib = require("./testlib")
local check = TestLib.check

local FakeDataStore = require("./FakeDataStore")
local ProfileSchema = require("./ProfileSchema")
local ProfileStore = require("./ProfileStore")

local now = 1000

local function newStore(fake, sessionId, overrides)
    local opts = {
        dataStore = fake,
        schema = ProfileSchema,
        sessionId = sessionId,
        now = function()
            return now
        end,
        sleep = function(_seconds: number) end,
        logger = function(_message: string) end,
        lockStaleSeconds = 10,
        maxAttempts = 2,
        retryDelays = { 0, 0 },
    }
    for key, value in pairs(overrides or {}) do
        opts[key] = value
    end
    return ProfileStore.new(opts)
end

local function key(userId)
    return "Player_" .. tostring(userId)
end

---------------------------------------------------------------- 首次加载 / 保存 / 重进

do
    local fake = FakeDataStore.new()
    local first = newStore(fake, "server-1")
    local handle, reason = first:load(1)
    check("first load succeeds", handle ~= nil, reason)
    check("first load creates a default profile", handle and handle.data.settings.char == "baobao")
    check("first load writes an envelope", fake:get(key(1)) ~= nil)

    handle.data.currency = 7
    handle.data.inventory.needle.free = 2
    handle.data.inventory.needle.purchased = 3
    check("normal save succeeds", first:save(handle, false) == true)

    check("stored currency", fake:get(key(1)).data.currency == 7)
    check("stored free stock", fake:get(key(1)).data.inventory.needle.free == 2)
    check("stored purchased stock", fake:get(key(1)).data.inventory.needle.purchased == 3)
    check("stored lock belongs to the first server", fake:get(key(1)).lock.sessionId == "server-1")

    check("release succeeds", first:save(handle, true) == true)
    check("release clears the lock", fake:get(key(1)).lock == nil)

    local second = newStore(fake, "server-2")
    local reloaded, reloadReason = second:load(1)
    check("reload succeeds", reloaded ~= nil, reloadReason)
    check("currency persists", reloaded and reloaded.data.currency == 7)
    check("free stock persists", reloaded and reloaded.data.inventory.needle.free == 2)
    check("purchased stock persists separately", reloaded and reloaded.data.inventory.needle.purchased == 3)
    check("total stock is conserved", reloaded and ProfileSchema.totalStock(reloaded.data, "needle") == 5)
    second:save(reloaded, true)
end

---------------------------------------------------------------- 活锁阻止第二个会话

do
    local fake = FakeDataStore.new()
    local first = newStore(fake, "active")
    local held = first:load(2)
    check("holder loads", held ~= nil)

    local writesBefore = #fake.writeLog
    local second = newStore(fake, "other")
    local blocked, blockedReason = second:load(2)
    check("second session is locked out", blocked == nil and blockedReason == "locked", blockedReason)
    check("blocked load does not write", #fake.writeLog == writesBefore)
    check("blocked load does not create a default", fake:get(key(2)).data.currency == 0)

    first:save(held, true)
    local admitted, admittedReason = second:load(2)
    check("second session loads after release", admitted ~= nil, admittedReason)
    check("second session sees the same profile", admitted and admitted.data.settings.char == "baobao")
    second:save(admitted, true)
end

---------------------------------------------------------------- 同一个 session 的两个 handle：lockId fencing

do
    local fake = FakeDataStore.new()
    local store = newStore(fake, "same-server")

    now = 2000
    local older = store:load(3)
    check("older handle loads", older ~= nil)

    local newer, reason = store:load(3)
    check("live same-session handle blocks a second load", newer == nil and reason == "locked", reason)

    now = 2010 -- lockStaleSeconds is 10
    local takeover, takeoverReason = store:load(3)
    check("stale same-session lock can be taken over", takeover ~= nil, takeoverReason)
    check("takeover gets a different lockId", takeover and takeover.lockId ~= older.lockId)
    local takeoverLockId = takeover and fake:get(key(3)).lock.lockId

    local saveOk, saveReason = store:save(older, false)
    check("old handle cannot save after takeover", saveOk == false and saveReason == "lock_lost", saveReason)
    local releaseOk, releaseReason = store:save(older, true)
    check("old handle cannot release the new lock", releaseOk == false and releaseReason == "lock_lost", releaseReason)
    check("new lock survives the old release", fake:get(key(3)).lock.lockId == takeoverLockId)

    store:save(takeover, true)
end

---------------------------------------------------------------- 心跳刷新锁

do
    local fake = FakeDataStore.new()
    local store = newStore(fake, "heartbeat")

    now = 3000
    local holder = store:load(4)
    check("heartbeat holder loads", holder ~= nil)

    now = 3005
    holder.data.currency = 1
    check("heartbeat save succeeds", store:save(holder, false) == true)
    check("heartbeat refreshes updatedAt", fake:get(key(4)).lock.updatedAt == 3005)

    local blocked, reason = store:load(4)
    check("refreshed lock still blocks", blocked == nil and reason == "locked", reason)

    now = 3015
    local takeover, takeoverReason = store:load(4)
    check("stale refreshed lock can be taken over", takeover ~= nil, takeoverReason)
    local saveOk, saveReason = store:save(holder, false)
    check("old heartbeat handle loses ownership", saveOk == false and saveReason == "lock_lost", saveReason)

    store:save(takeover, true)
end

---------------------------------------------------------------- 重试、失败不创建默认档、损坏 / 新版本拒绝

do
    local fake = FakeDataStore.new()
    local store = newStore(fake, "retry")
    local handle = store:load(5)
    check("retry load succeeds", handle ~= nil)

    fake:failNext(1)
    local saveOk, saveReason = store:save(handle, false)
    check("save retries a transient error", saveOk == true, saveReason)
    check("retried save wrote the data", fake:get(key(5)).data.settings.char == "baobao")
    store:save(handle, true)
end

do
    local fake = FakeDataStore.new()
    fake.alwaysFail = true
    local store = newStore(fake, "down")
    local handle, reason = store:load(6)
    check("failed load does not return a handle", handle == nil)
    check("failed load reports load_failed", reason == "load_failed", reason)
    check("failed load makes no write", #fake.writeLog == 0, #fake.writeLog)
    check("failed load does not create a default", fake:get(key(6)) == nil)
end

do
    local fake = FakeDataStore.new()
    fake.values[key(7)] = "not an envelope"
    local store = newStore(fake, "corrupt")
    local handle, reason = store:load(7)
    check("corrupt envelope is rejected", handle == nil and reason == "corrupt", reason)
    check("corrupt envelope is not overwritten", fake:get(key(7)) == "not an envelope")
end

do
    local fake = FakeDataStore.new()
    fake.values[key(8)] = {
        version = ProfileSchema.VERSION + 1,
        data = ProfileSchema.newProfile(),
        lock = nil,
    }
    local store = newStore(fake, "newer")
    local handle, reason = store:load(8)
    check("newer schema is rejected", handle == nil and reason == "newer_version", reason)
    check("newer schema is not overwritten", fake:get(key(8)).version == ProfileSchema.VERSION + 1)
end

---------------------------------------------------------------- 保存前快照

do
    local fake = FakeDataStore.new()
    local store = newStore(fake, "snapshot")
    local handle = store:load(9)
    check("snapshot handle loads", handle ~= nil)

    handle.data.currency = 1
    fake.beforeUpdate = function()
        -- Simulates a game write landing while UpdateAsync is in flight.
        handle.data.currency = 2
    end
    check("snapshot save succeeds", store:save(handle, false) == true)
    check("in-flight mutation is not persisted by this save", fake:get(key(9)).data.currency == 1)

    fake.beforeUpdate = nil
    handle.data.currency = 3
    check("next save writes the latest value", store:save(handle, false) == true)
    check("latest value is now persisted", fake:get(key(9)).data.currency == 3)
    store:save(handle, true)
end

---------------------------------------------------------------- 两个会话的最终保存

do
    local fake = FakeDataStore.new()
    local first = newStore(fake, "one")
    local second = newStore(fake, "two")

    local a = first:load(10)
    local b = second:load(11)
    check("two profiles load", a ~= nil and b ~= nil)
    a.data.currency = 10
    b.data.currency = 11
    check("first final save", first:save(a, true) == true)
    check("second final save", second:save(b, true) == true)

    local reload = newStore(fake, "three")
    local a2 = reload:load(10)
    local b2 = reload:load(11)
    check("profile 10 survives shutdown", a2 and a2.data.currency == 10)
    check("profile 11 survives shutdown", b2 and b2.data.currency == 11)
    reload:save(a2, true)
    reload:save(b2, true)
end

TestLib.finish()
