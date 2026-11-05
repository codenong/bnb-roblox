-- src/shared/ProfileSchema.luau
-- Versioned player-profile data. Pure Luau: no Roblox services, no DataStore.
-- Free and purchased stock are separate buckets so the shop and the daily free
-- needle can never spend each other's inventory.

local ProfileSchema = {}

ProfileSchema.VERSION = 1
ProfileSchema.ITEM_IDS = { "needle", "remote", "kick" }
ProfileSchema.FREE_NEEDLE_MAX = 5
ProfileSchema.FREE_NEEDLE_DAILY = 5
ProfileSchema.DEFAULT_CHAR = "baobao"

local function isFiniteNumber(value: any): boolean
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function nonNegativeInt(value: any, fallback: number): number
    if not isFiniteNumber(value) then
        return fallback
    end
    return math.max(0, math.floor(value))
end

local function boundedInt(value: any, fallback: number, maximum: number): number
    return math.min(maximum, nonNegativeInt(value, fallback))
end

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

local function tableOrEmpty(value: any): { [any]: any }
    if type(value) == "table" then
        return copy(value)
    end
    return {}
end

local function newInventory()
    local inventory = {}
    for _, itemId in ipairs(ProfileSchema.ITEM_IDS) do
        inventory[itemId] = { free = 0, purchased = 0 }
    end
    return inventory
end

local function newLoadout()
    local loadout = {}
    for _, itemId in ipairs(ProfileSchema.ITEM_IDS) do
        loadout[itemId] = 0
    end
    return loadout
end

function ProfileSchema.newProfile(): any
    return {
        currency = 0,
        inventory = newInventory(),
        loadout = newLoadout(),
        stats = {
            versus = { games = 0, wins = 0, losses = 0, draws = 0 },
        },
        freeNeedle = {
            progress = 2,
            earnedToday = 0,
            day = "",
        },
        receipts = {},
        settings = { char = ProfileSchema.DEFAULT_CHAR },
    }
end

function ProfileSchema.isItemId(itemId: any): boolean
    if type(itemId) ~= "string" then
        return false
    end
    for _, id in ipairs(ProfileSchema.ITEM_IDS) do
        if id == itemId then
            return true
        end
    end
    return false
end

local function isBucket(name: any): boolean
    return name == "free" or name == "purchased"
end

local function normalizeBucket(bucket: any): { [any]: any }
    local result = tableOrEmpty(bucket)
    result.free = nonNegativeInt(result.free, 0)
    result.purchased = nonNegativeInt(result.purchased, 0)
    return result
end

-- Returns a fresh, normalized profile. The input is never modified. Unknown
-- fields from the same schema version are kept so a newer server can add data
-- without this one silently deleting it.
function ProfileSchema.normalize(value: any): any
    local result = tableOrEmpty(value)
    local defaults = ProfileSchema.newProfile()

    result.currency = nonNegativeInt(result.currency, defaults.currency)

    local inventory = tableOrEmpty(result.inventory)
    for _, itemId in ipairs(ProfileSchema.ITEM_IDS) do
        inventory[itemId] = normalizeBucket(inventory[itemId])
    end
    result.inventory = inventory

    local loadout = tableOrEmpty(result.loadout)
    for _, itemId in ipairs(ProfileSchema.ITEM_IDS) do
        loadout[itemId] = nonNegativeInt(loadout[itemId], 0)
    end
    result.loadout = loadout

    local stats = tableOrEmpty(result.stats)
    local versus = tableOrEmpty(stats.versus)
    for _, field in ipairs({ "games", "wins", "losses", "draws" }) do
        versus[field] = nonNegativeInt(versus[field], 0)
    end
    stats.versus = versus
    result.stats = stats

    local freeNeedle = tableOrEmpty(result.freeNeedle)
    freeNeedle.progress = boundedInt(freeNeedle.progress, 2, ProfileSchema.FREE_NEEDLE_MAX)
    freeNeedle.earnedToday = nonNegativeInt(freeNeedle.earnedToday, 0)
    freeNeedle.day = if type(freeNeedle.day) == "string" then freeNeedle.day else ""
    result.freeNeedle = freeNeedle

    result.receipts = tableOrEmpty(result.receipts)

    -- PlayerService validates against Characters when the profile is seated;
    -- the schema only guards the field's shape so headless tests stay service-free.
    local settings = tableOrEmpty(result.settings)
    if type(settings.char) ~= "string" or settings.char == "" then
        settings.char = ProfileSchema.DEFAULT_CHAR
    end
    result.settings = settings

    return result
end

local function getBucket(profile: any, itemId: any): { [any]: any }?
    if type(profile) ~= "table" or not ProfileSchema.isItemId(itemId) then
        return nil
    end
    local inventory = profile.inventory
    if type(inventory) ~= "table" then
        return nil
    end
    local bucket = inventory[itemId]
    if type(bucket) ~= "table" then
        return nil
    end
    return bucket
end

function ProfileSchema.addStock(profile: any, itemId: any, bucketName: any, amount: any): boolean
    local bucket = getBucket(profile, itemId)
    if not bucket or not isBucket(bucketName) then
        return false
    end
    if not isFiniteNumber(amount) or amount < 0 then
        return false
    end
    local count = math.floor(amount)
    bucket[bucketName] = nonNegativeInt(bucket[bucketName], 0) + count
    return true
end

function ProfileSchema.totalStock(profile: any, itemId: any): number
    local bucket = getBucket(profile, itemId)
    if not bucket then
        return 0
    end
    return nonNegativeInt(bucket.free, 0) + nonNegativeInt(bucket.purchased, 0)
end

-- All-or-nothing: check the combined total before touching either bucket.
-- On success free stock is spent first, then purchased stock.
function ProfileSchema.consumeStock(profile: any, itemId: any, amount: any): (boolean, { free: number, purchased: number }?)
    local bucket = getBucket(profile, itemId)
    if not bucket or not isFiniteNumber(amount) or amount < 0 then
        return false, nil
    end

    local count = math.floor(amount)
    local total = ProfileSchema.totalStock(profile, itemId)
    if total < count then
        return false, nil
    end

    if count == 0 then
        return true, { free = 0, purchased = 0 }
    end

    local free = nonNegativeInt(bucket.free, 0)
    local purchased = nonNegativeInt(bucket.purchased, 0)
    local fromFree = math.min(free, count)
    local fromPurchased = count - fromFree

    bucket.free = free - fromFree
    bucket.purchased = purchased - fromPurchased

    return true, { free = fromFree, purchased = fromPurchased }
end

return table.freeze(ProfileSchema)
