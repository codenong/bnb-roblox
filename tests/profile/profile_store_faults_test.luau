-- tests/profile/profile_store_faults_test.luau
-- Failure modes the plain fake cannot produce: a write that is committed while
-- the caller gets an error (lost response), and a transform that Roblox runs more
-- than once. The store must stay consistent with the lock it actually wrote.
local TestLib = require("./testlib")
local check = TestLib.check

local FakeDataStore = require("./FakeDataStore")
local ProfileSchema = require("./ProfileSchema")
local ProfileStore = require("./ProfileStore")

local now = 1000

local function newStore(fake, sessionId)
    return ProfileStore.new({
        dataStore = fake,
        schema = ProfileSchema,
        sessionId = sessionId,
        now = function()
            return now
        end,
        sleep = function(_seconds: number) end,
        logger = function(_message: string) end,
        lockStaleSeconds = 120,
        maxAttempts = 4,
        retryDelays = { 0, 0, 0 },
    })
end

---------------------------------------------------------------- 首次加载：写入成功但响应丢失

do
    local fake = FakeDataStore.new()
    fake:loseResponseNext(1)
    local store = newStore(fake, "A")
    local handle, reason = store:load(1)

    check("fresh load survives a lost response", handle ~= nil, reason)
    check("the lost response cost one retry", fake.updateCount == 2, fake.updateCount)
    if handle then
        local stored = fake:get(handle.key)
        check("stored lock belongs to the returned handle", stored.lock.lockId == handle.lockId and stored.lock.sessionId == "A")
        handle.data.currency = 7
        check("the handle can save afterwards", store:save(handle) == true)
        check("the save landed", fake:get(handle.key).data.currency == 7)
    end
end

---------------------------------------------------------------- 普通保存：响应丢失

do
    local fake = FakeDataStore.new()
    local store = newStore(fake, "A")
    local handle = store:load(1)
    handle.data.currency = 42
    fake:loseResponseNext(1)

    check("save survives a lost response", store:save(handle) == true)
    check("data was persisted", fake:get(handle.key).data.currency == 42)
    check("lock is still held", fake:get(handle.key).lock ~= nil and fake:get(handle.key).lock.lockId == handle.lockId)
end

---------------------------------------------------------------- 释放：写入已清锁但响应丢失

do
    local fake = FakeDataStore.new()
    local a = newStore(fake, "A")
    local handle = a:load(1)
    handle.data.currency = 99
    fake:loseResponseNext(1)

    check("release survives a lost response", a:save(handle, true) == true)
    check("the lock was cleared", fake:get(handle.key).lock == nil)

    local b = newStore(fake, "B")
    local other = b:load(1)
    check("another server can load right away", other ~= nil)
    check("it sees the released data", other ~= nil and other.data.currency == 99)
end

---------------------------------------------------------------- 释放时锁已被别人接管：不能因为"锁为空/不是我"而误报成功

do
    local fake = FakeDataStore.new()
    local a, b = newStore(fake, "A"), newStore(fake, "B")
    local handle = a:load(1)
    now += 500 -- A's heartbeat stopped; its lock is now stale
    local taken = b:load(1)
    check("B takes over the stale lock", taken ~= nil)

    local released, reason = a:save(handle, true)
    check("A's stale release is refused", released == false and reason == "lock_lost", reason)
    check("B's lock survives", fake:get(handle.key).lock ~= nil and fake:get(handle.key).lock.sessionId == "B")
    if taken then
        check("B can still save", b:save(taken) == true)
    end
end

---------------------------------------------------------------- 接管过期锁：响应丢失

do
    local fake = FakeDataStore.new()
    local a, b = newStore(fake, "A"), newStore(fake, "B")
    local old = a:load(1)
    now += 500
    fake:loseResponseNext(1)

    local taken, reason = b:load(1)
    check("takeover survives a lost response", taken ~= nil, reason)
    if taken then
        check("stored lock belongs to the new handle", fake:get(taken.key).lock.lockId == taken.lockId and fake:get(taken.key).lock.sessionId == "B")
        check("the old handle cannot save", a:save(old) == false)
    end
end

---------------------------------------------------------------- 回调被重跑：写入的锁必须和返回的句柄一致

do
    local fake = FakeDataStore.new()
    fake.rerunTransforms = true
    local a, b = newStore(fake, "A"), newStore(fake, "B")

    local first = a:load(1)
    check("fresh load with re-run", first ~= nil and fake:get(first.key).lock.lockId == first.lockId)

    now += 500
    local taken = b:load(1)
    check("takeover with re-run", taken ~= nil and fake:get(taken.key).lock.lockId == taken.lockId)
    check("takeover with re-run belongs to B", taken ~= nil and fake:get(taken.key).lock.sessionId == "B")
    check("takeover issued a new lockId", taken ~= nil and first ~= nil and taken.lockId ~= first.lockId)

    if taken then
        taken.data.currency = 5
        check("the new handle saves after a re-run", b:save(taken) == true)
        check("the old handle is still refused", a:save(first) == false)
    end
end

---------------------------------------------------------------- 两种故障叠加，且连续丢失多次

do
    local fake = FakeDataStore.new()
    fake.rerunTransforms = true
    fake:loseResponseNext(2)
    local store = newStore(fake, "A")
    local handle, reason = store:load(1)
    check("load survives two lost responses with re-runs", handle ~= nil, reason)
    if handle then
        check("lock matches the handle", fake:get(handle.key).lock.lockId == handle.lockId)
        fake:loseResponseNext(2)
        handle.data.currency = 3
        check("save survives two lost responses", store:save(handle) == true)
        check("and the data is there", fake:get(handle.key).data.currency == 3)
    end
end

---------------------------------------------------------------- 超过重试次数时如实失败，而不是假装成功

do
    local fake = FakeDataStore.new()
    local store = newStore(fake, "A")
    local handle = store:load(1)
    handle.data.currency = 8
    fake:failNext(4) -- before any write: nothing is committed
    local ok, reason = store:save(handle)
    check("exhausted retries report failure", ok == false and reason == "save_failed", reason)
    check("nothing was written by the failed attempts", fake:get(handle.key).data.currency == 0)
    check("a later save still works", store:save(handle) == true)
    check("and persists the data", fake:get(handle.key).data.currency == 8)
end

TestLib.finish()
