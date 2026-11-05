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
        alwaysFail = false,
        beforeUpdate = nil,
    }, FakeDataStore)
end

function FakeDataStore:failNext(count: number?)
    self.failures += count or 1
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
    if result == nil then
        return nil
    end

    self.values[key] = copy(result)
    table.insert(self.writeLog, { key = key, value = copy(result) })
    return copy(result)
end

return FakeDataStore
