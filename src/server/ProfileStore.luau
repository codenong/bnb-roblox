-- src/server/ProfileStore.luau
-- DataStore persistence with a per-load session lock. Pure Luau: the DataStore,
-- schema, clock and sleep function are injected so the same code runs in
-- headless tests and in Studio.
--
-- Lock identity is (sessionId, lockId), not just sessionId: two handles created
-- by the same server must not overwrite or release each other after a stale
-- takeover.

local ProfileStore = {}
ProfileStore.__index = ProfileStore

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

local function isFiniteNumber(value: any): boolean
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function isValidEnvelope(old: any): boolean
    if type(old) ~= "table" then
        return false
    end
    if not isFiniteNumber(old.version) or type(old.data) ~= "table" then
        return false
    end
    if old.lock ~= nil then
        if type(old.lock) ~= "table" then
            return false
        end
        if type(old.lock.sessionId) ~= "string" or type(old.lock.lockId) ~= "string" then
            return false
        end
        if not isFiniteNumber(old.lock.updatedAt) then
            return false
        end
    end
    return true
end

function ProfileStore.new(opts)
    opts = opts or {}
    return setmetatable({
        dataStore = opts.dataStore,
        schema = opts.schema,
        sessionId = opts.sessionId or "session",
        now = opts.now or os.time,
        sleep = opts.sleep or function(_seconds: number) end,
        logger = opts.logger or function(_message: string) end,
        lockStaleSeconds = opts.lockStaleSeconds or 120,
        maxAttempts = math.max(1, opts.maxAttempts or 4),
        retryDelays = opts.retryDelays or { 1, 2, 4 },
        loadSequence = 0,
    }, ProfileStore)
end

function ProfileStore:_nextLockId(): string
    self.loadSequence += 1
    return self.sessionId .. ":" .. tostring(self.loadSequence)
end

function ProfileStore:_delay(attempt: number)
    local delays = self.retryDelays
    local seconds = delays[math.min(attempt, #delays)] or 0
    if seconds > 0 then
        self.sleep(seconds)
    end
end

function ProfileStore:_log(message: string)
    local ok, err = pcall(self.logger, message)
    if not ok then
        -- Logging must never break a save or release.
        local _ = err
    end
end

function ProfileStore:_claim(old: any, requestedLockId: string)
    local schema = self.schema

    if old == nil then
        local data = schema.newProfile()
        return {
            write = true,
            data = data,
            lockId = requestedLockId,
            envelope = {
                version = schema.VERSION,
                data = data,
                lock = {
                    sessionId = self.sessionId,
                    lockId = requestedLockId,
                    updatedAt = self.now(),
                },
            },
        }
    end

    if not isValidEnvelope(old) then
        return { write = false, reason = "corrupt" }
    end
    if old.version > schema.VERSION then
        return { write = false, reason = "newer_version" }
    end

    local lockId = requestedLockId
    if old.lock ~= nil then
        local sameHandle = old.lock.sessionId == self.sessionId
            and old.lock.lockId == lockId
        if not sameHandle then
            local age = self.now() - old.lock.updatedAt
            if age < self.lockStaleSeconds then
                return { write = false, reason = "locked" }
            end
            -- A stale lock from any server may be taken over. Give this
            -- takeover a fresh fencing token so the old handle cannot save or
            -- release against the new lock.
            lockId = self:_nextLockId()
        end
    end

    local data = schema.normalize(old.data)
    return {
        write = true,
        data = data,
        lockId = lockId,
        envelope = {
            version = schema.VERSION,
            data = data,
            lock = {
                sessionId = self.sessionId,
                lockId = lockId,
                updatedAt = self.now(),
            },
        },
    }
end

function ProfileStore:load(userId: any)
    if not self.dataStore or not self.schema then
        return nil, "load_failed"
    end

    local key = "Player_" .. tostring(userId)
    local lockId = self:_nextLockId()
    local lastReason = "load_failed"

    for attempt = 1, self.maxAttempts do
        local decision = nil
        local ok = pcall(function()
            self.dataStore:UpdateAsync(key, function(old)
                local claimed = self:_claim(old, lockId)
                decision = claimed
                if claimed.write then
                    lockId = claimed.lockId
                    return claimed.envelope
                end
                return nil
            end)
        end)

        if ok and decision then
            if decision.write then
                return {
                    userId = userId,
                    key = key,
                    sessionId = self.sessionId,
                    lockId = decision.lockId,
                    data = decision.data,
                }, nil
            end
            if decision.reason == "newer_version" or decision.reason == "corrupt" then
                self:_log(string.format(
                    "[BnB] profile load refused for %s: %s",
                    tostring(userId),
                    tostring(decision.reason)
                ))
                return nil, decision.reason
            end
            lastReason = decision.reason or "load_failed"
        elseif not ok then
            lastReason = "load_failed"
        end

        if attempt < self.maxAttempts then
            self:_delay(attempt)
        end
    end

    self:_log(string.format(
        "[BnB] profile load failed for %s after %d attempts: %s",
        tostring(userId),
        self.maxAttempts,
        tostring(lastReason)
    ))
    return nil, lastReason
end

function ProfileStore:save(handle: any, release: boolean?)
    if type(handle) ~= "table"
        or type(handle.key) ~= "string"
        or type(handle.sessionId) ~= "string"
        or type(handle.lockId) ~= "string"
        or type(handle.data) ~= "table"
    then
        return false, "lock_lost"
    end
    if not self.dataStore or not self.schema then
        return false, "save_failed"
    end

    local snapshot = copy(handle.data)
    local lastReason = "save_failed"

    for attempt = 1, self.maxAttempts do
        local decision = nil
        local ok = pcall(function()
            self.dataStore:UpdateAsync(handle.key, function(old)
                if old == nil or not isValidEnvelope(old) then
                    decision = { ok = false, reason = "lock_lost" }
                    return nil
                end
                if old.version > self.schema.VERSION then
                    decision = { ok = false, reason = "lock_lost" }
                    return nil
                end

                if old.lock == nil then
                    if release then
                        -- A previous release may have written the final data
                        -- and cleared the lock, but its response was lost.
                        decision = { ok = true, released = true }
                    else
                        decision = { ok = false, reason = "lock_lost" }
                    end
                    return nil
                end

                if old.lock.sessionId ~= handle.sessionId
                    or old.lock.lockId ~= handle.lockId
                then
                    decision = { ok = false, reason = "lock_lost" }
                    return nil
                end

                decision = { ok = true }
                if release then
                    return {
                        version = self.schema.VERSION,
                        data = snapshot,
                        lock = nil,
                    }
                end
                return {
                    version = self.schema.VERSION,
                    data = snapshot,
                    lock = {
                        sessionId = handle.sessionId,
                        lockId = handle.lockId,
                        updatedAt = self.now(),
                    },
                }
            end)
        end)

        if ok and decision then
            if decision.ok then
                return true
            end
            return false, decision.reason or "lock_lost"
        elseif not ok then
            lastReason = "save_failed"
        end

        if attempt < self.maxAttempts then
            self:_delay(attempt)
        end
    end

    self:_log(string.format(
        "[BnB] profile save failed for %s after %d attempts: %s",
        tostring(handle.userId),
        self.maxAttempts,
        tostring(lastReason)
    ))
    return false, lastReason
end

return ProfileStore
