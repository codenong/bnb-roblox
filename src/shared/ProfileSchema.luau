-- src/shared/ProfileSchema.luau
-- Versioned player-profile data. Pure Luau: no Roblox services, no DataStore.
-- Free and purchased stock are separate buckets so the shop and the daily free
-- needle can never spend each other's inventory.

local Characters = require(script.Parent.Characters)
local Shop = require(script.Parent.Shop)

local ProfileSchema = {}

ProfileSchema.VERSION = 1
ProfileSchema.ITEM_IDS = { "needle", "remote", "kick" }

-- Free needle rules. These are tuning knobs: change the numbers here, nothing
-- else needs to know. The rules themselves are in detail.md.
ProfileSchema.FREE_NEEDLE_GOAL = 5 -- valid versus games that earn one free needle
ProfileSchema.FREE_NEEDLE_START_PROGRESS = 2 -- new players start at 2/5 (endowed progress)
ProfileSchema.FREE_NEEDLE_DAILY_CAP = 3 -- free needles that can be earned per day
ProfileSchema.FREE_NEEDLE_STOCK_CAP = 4 -- free needles that can be stored at once
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
    return Shop.newLoadout()
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
            progress = ProfileSchema.FREE_NEEDLE_START_PROGRESS,
            earnedToday = 0,
            day = "",
        },
        receipts = {},
        settings = {
            char = ProfileSchema.DEFAULT_CHAR,
            charColors = Characters.defaultColors(),
        },
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

    -- Loadout is player intent and is capped at entry capacity, not at current
    -- stock. Unknown fields are preserved like the rest of the schema.
    result.loadout = Shop.normalizeLoadout(result.loadout)

    local stats = tableOrEmpty(result.stats)
    local versus = tableOrEmpty(stats.versus)
    for _, field in ipairs({ "games", "wins", "losses", "draws" }) do
        versus[field] = nonNegativeInt(versus[field], 0)
    end
    stats.versus = versus
    result.stats = stats

    local freeNeedle = tableOrEmpty(result.freeNeedle)
    freeNeedle.progress = boundedInt(
        freeNeedle.progress,
        ProfileSchema.FREE_NEEDLE_START_PROGRESS,
        ProfileSchema.FREE_NEEDLE_GOAL
    )
    freeNeedle.earnedToday = nonNegativeInt(freeNeedle.earnedToday, 0)
    freeNeedle.day = if type(freeNeedle.day) == "string" then freeNeedle.day else ""
    result.freeNeedle = freeNeedle

    result.receipts = tableOrEmpty(result.receipts)

    -- PlayerService validates the selected character when the profile is seated;
    -- the schema only guards the field's shape. Character colors are pure data,
    -- so old profiles can be repaired here without Roblox services.
    local settings = tableOrEmpty(result.settings)
    if type(settings.char) ~= "string" or settings.char == "" then
        settings.char = ProfileSchema.DEFAULT_CHAR
    end
    settings.charColors = Characters.normalizeColors(settings.charColors)
    result.settings = settings

    return result
end

-- Record one valid versus game. `outcome` is "win", "loss" or "draw"; games is
-- always incremented exactly once. Returns false for an unsupported outcome or a
-- profile that cannot hold stats, without mutating it.
function ProfileSchema.recordVersus(profile: any, outcome: any): boolean
    if type(profile) ~= "table" then
        return false
    end
    if outcome ~= "win" and outcome ~= "loss" and outcome ~= "draw" then
        return false
    end

    local stats = profile.stats
    if type(stats) ~= "table" then
        stats = {}
        profile.stats = stats
    end
    local versus = stats.versus
    if type(versus) ~= "table" then
        versus = {}
        stats.versus = versus
    end

    versus.games = nonNegativeInt(versus.games, 0) + 1
    local field = if outcome == "win" then "wins" elseif outcome == "loss" then "losses" else "draws"
    versus[field] = nonNegativeInt(versus[field], 0) + 1
    return true
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

function ProfileSchema.hasReceipt(profile: any, purchaseId: any): boolean
    if type(profile) ~= "table" or type(purchaseId) ~= "string" or purchaseId == "" then
        return false
    end
    local receipts = profile.receipts
    return type(receipts) == "table" and receipts[purchaseId] ~= nil
end

-- Grants one paid product atomically with its receipt marker. A repeated
-- PurchaseId is a no-op; the caller must still make sure the first grant is
-- durable before telling Roblox the purchase was processed.
function ProfileSchema.grantPurchase(
    profile: any,
    purchaseId: any,
    itemId: any,
    amount: any
): (boolean, string?)
    if type(profile) ~= "table" or type(profile.inventory) ~= "table" then
        return false, "invalid_profile"
    end
    if type(purchaseId) ~= "string" or purchaseId == "" then
        return false, "invalid_receipt"
    end
    if not ProfileSchema.isItemId(itemId) then
        return false, "invalid_item"
    end
    if not isFiniteNumber(amount) or amount < 1 or amount % 1 ~= 0 then
        return false, "invalid_amount"
    end
    if ProfileSchema.hasReceipt(profile, purchaseId) then
        return false, "duplicate"
    end

    local receipts = profile.receipts
    if type(receipts) ~= "table" then
        receipts = {}
        profile.receipts = receipts
    end
    receipts[purchaseId] = true
    if not ProfileSchema.addStock(profile, itemId, "purchased", amount) then
        receipts[purchaseId] = nil
        return false, "invalid_item"
    end
    return true
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
