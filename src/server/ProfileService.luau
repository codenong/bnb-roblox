-- src/server/ProfileService.luau
-- Owns one loaded profile per player and serializes every save/release for that
-- profile through a single worker. The store is injected; this module never
-- touches Roblox services directly and never kicks a player itself.

local ProfileService = {}
ProfileService.__index = ProfileService

function ProfileService.new(opts)
    opts = opts or {}
    return setmetatable({
        store = opts.store,
        isActive = opts.isActive or function(player)
            return player.Parent ~= nil
        end,
        spawn = opts.spawn or function(fn)
            task.spawn(fn)
        end,
        sleep = opts.sleep or function(seconds)
            task.wait(seconds)
        end,
        warn = opts.warn or function(_message)
        end,
        autoSaveSeconds = opts.autoSaveSeconds or 30,
        shutdownSeconds = opts.shutdownSeconds or 20,
        onLockLost = opts.onLockLost or function(_player, _reason)
        end,
        states = {},
        byUserId = {},
        active = 0,
        accumulator = 0,
        shutting = false,
    }, ProfileService)
end

function ProfileService:_warn(message: string)
    local ok = pcall(self.warn, message)
    if not ok then
        -- Diagnostic logging must not take the profile worker down.
    end
end

function ProfileService:_finish(state)
    if state.released then
        return
    end
    state.released = true
    state.closing = true
    state.dirty = false
    if self.states[state.player] == state then
        self.states[state.player] = nil
    end
    if self.byUserId[state.userId] == state then
        self.byUserId[state.userId] = nil
    end
end

function ProfileService:_drop(state, reason)
    if state.released then
        return
    end
    state.released = true
    state.closing = true
    state.dirty = false
    if self.states[state.player] == state then
        self.states[state.player] = nil
    end
    if self.byUserId[state.userId] == state then
        self.byUserId[state.userId] = nil
    end

    local ok, err = pcall(self.onLockLost, state.player, reason)
    if not ok then
        self:_warn(string.format(
            "[BnB] profile lock-lost handler failed for %s: %s",
            tostring(state.userId),
            tostring(err)
        ))
    end
end

-- A handle can be acquired after the player left or after shutdown started. It
-- was never registered as a state, so release it directly; a failure here must
-- not turn a cancelled load into a crash, only leave the lock to go stale.
function ProfileService:_releaseOrphan(handle)
    local ok, released, reason = pcall(self.store.save, self.store, handle, true)
    if not ok then
        self:_warn(string.format(
            "[BnB] orphan profile release crashed for %s: %s",
            tostring(handle and handle.userId),
            tostring(released)
        ))
    elseif not released then
        self:_warn(string.format(
            "[BnB] orphan profile release failed for %s: %s",
            tostring(handle and handle.userId),
            tostring(reason)
        ))
    end
end

function ProfileService:_runWorker(state)
    while state.dirty and not state.released do
        state.dirty = false
        local release = state.closing
        local ok, reason = self.store:save(state.handle, release)

        if ok then
            if release then
                self:_finish(state)
            end
        elseif reason == "lock_lost" then
            self:_drop(state, reason)
            return
        else
            -- Ordinary DataStore failures keep the profile dirty. The next
            -- heartbeat, settlement or shutdown retries it.
            state.dirty = true
            self:_warn(string.format(
                "[BnB] profile save failed for %s: %s",
                tostring(state.userId),
                tostring(reason)
            ))
            return
        end
    end
end

function ProfileService:_schedule(state)
    if state.worker or state.released then
        return
    end

    state.worker = true
    self.active += 1
    local finished = false

    local function finish(ok: boolean, err: any)
        if finished then
            return
        end
        finished = true
        state.worker = false
        self.active -= 1
        if not ok and not state.released then
            state.dirty = true
            self:_warn(string.format(
                "[BnB] profile worker failed for %s: %s",
                tostring(state.userId),
                tostring(err)
            ))
        end
    end

    local function run()
        local ok, err = pcall(self._runWorker, self, state)
        finish(ok, err)
    end

    local ok, err = pcall(self.spawn, run)
    if not ok then
        finish(false, err)
    end
end

function ProfileService:load(player)
    if self.shutting then
        return nil, "shutdown"
    end
    if self.states[player] or self.byUserId[player.UserId] then
        return nil, "duplicate"
    end
    if not self.isActive(player) then
        return nil, "inactive"
    end

    self.active += 1
    local handle = nil
    local reason = nil
    local ok, err = pcall(function()
        handle, reason = self.store:load(player.UserId)
    end)

    if not ok then
        self.active -= 1
        self:_warn(string.format(
            "[BnB] profile load crashed for %s: %s",
            tostring(player.UserId),
            tostring(err)
        ))
        return nil, "load_failed"
    end
    if not handle then
        self.active -= 1
        return nil, reason or "load_failed"
    end

    if self.shutting then
        self:_releaseOrphan(handle)
        self.active -= 1
        return nil, "shutdown"
    end
    if not self.isActive(player) then
        self:_releaseOrphan(handle)
        self.active -= 1
        return nil, "cancelled"
    end
    if self.states[player] or self.byUserId[player.UserId] then
        self:_releaseOrphan(handle)
        self.active -= 1
        return nil, "duplicate"
    end

    local state = {
        player = player,
        userId = player.UserId,
        handle = handle,
        data = handle.data,
        dirty = false,
        closing = false,
        worker = false,
        released = false,
    }
    self.states[player] = state
    self.byUserId[player.UserId] = state
    self.active -= 1
    return state.data, nil
end

function ProfileService:getProfile(player)
    local state = self.states[player]
    if not state or state.released then
        return nil
    end
    return state.data
end

function ProfileService:isLoaded(player): boolean
    local state = self.states[player]
    return state ~= nil and not state.released
end

function ProfileService:commitMany(records)
    for _, record in ipairs(records or {}) do
        local player = record and record.player
        local state = player and self.states[player]
        if state and not state.released then
            state.dirty = true
            self:_schedule(state)
        end
    end
end

function ProfileService:release(player)
    local state = self.states[player]
    if not state or state.released then
        return
    end
    state.closing = true
    state.dirty = true
    self:_schedule(state)
end

function ProfileService:step(dt: number)
    if self.shutting then
        return
    end
    dt = tonumber(dt) or 0
    if dt <= 0 then
        return
    end

    self.accumulator += dt
    if self.accumulator < self.autoSaveSeconds then
        return
    end
    self.accumulator = 0

    for _, state in pairs(self.states) do
        if not state.released then
            state.dirty = true
            self:_schedule(state)
        end
    end
end

function ProfileService:shutdown()
    if self.shutting then
        return
    end
    self.shutting = true

    for _, state in pairs(self.states) do
        if not state.released then
            state.closing = true
            state.dirty = true
            self:_schedule(state)
        end
    end

    local deadline = os.clock() + self.shutdownSeconds
    while self.active > 0 and os.clock() < deadline do
        self.sleep(0.05)
    end

    if self.active > 0 then
        self:_warn(string.format(
            "[BnB] profile shutdown timed out with %d operation(s) still active",
            self.active
        ))
    end
    for _, state in pairs(self.states) do
        if not state.released then
            self:_warn(string.format(
                "[BnB] profile for %s was not released before shutdown",
                tostring(state.userId)
            ))
        end
    end
end

return ProfileService
