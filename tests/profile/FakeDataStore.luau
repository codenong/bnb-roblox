-- tests/profile/FakeDataStore.luau
-- Synchronous, atomic DataStore substitute. Two ProfileStore instances sharing
-- one fake behave like two servers talking to the same key space.

local FakeDataStore = {}
FakeDataStore.__index = FakeDataStore

local function copy(value: any): any
    if type(value) ~= "table" then
        return value
    end
    local result = {}
    for key, item in pairs(value) do
        result[copy(key)] = copy(item)
    end
    return result
end

function FakeDataStore.new()
    return setmetatable({
        values = {},
        writeLog = {},
        updateLog = {},
        updateCount = 0,
        failures = 0,
        lostResponses = 0,
        rerunTransforms = false,
        alwaysFail = false,
        beforeUpdate = nil,
    }, FakeDataStore)
end

-- The next `count` calls fail BEFORE anything is written.
function FakeDataStore:failNext(count: number?)
    self.failures += count or 1
end

-- The next `count` calls are written, then raise an error anyway. This is what a
-- timeout after the server accepted the write looks like to the caller: the data
-- changed but the response never arrived.
function FakeDataStore:loseResponseNext(count: number?)
    self.lostResponses += count or 1
end

function FakeDataStore:resetLog()
    table.clear(self.writeLog)
    table.clear(self.updateLog)
    self.updateCount = 0
end

function FakeDataStore:get(key: string)
    return copy(self.values[key])
end

function FakeDataStore:UpdateAsync(key: string, transform: (any) -> any)
    self.updateCount += 1
    table.insert(self.updateLog, key)

    if self.alwaysFail then
        error("fake DataStore failure", 0)
    end
    if self.failures > 0 then
        self.failures -= 1
        error("fake DataStore failure", 0)
    end

    local old = copy(self.values[key])
    if self.beforeUpdate then
        self.beforeUpdate(key, old)
    end

    local result = transform(old)
    if self.rerunTransforms then
        -- Roblox re-runs the transform when another write lands first. Only the
        -- last run's result is written, so a transform must not depend on being
        -- called exactly once. The first result is discarded here.
        result = transform(copy(self.values[key]))
    end
    if result == nil then
        return nil
    end

    self.values[key] = copy(result)
    table.insert(self.writeLog, { key = key, value = copy(result) })

    if self.lostResponses > 0 then
        self.lostResponses -= 1
        error("fake DataStore timeout after commit", 0)
    end
    return copy(result)
end

return FakeDataStore
