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

-- Receipts are both the idempotency set and a bounded purchase history. The
-- newest 1000 entries by last Roblox retry are kept; old receipts are dropped
-- oldest-first. At roughly 110-130 bytes per entry this is well below the
-- DataStore 4 MB per-key limit even before compression.
ProfileSchema.RECEIPT_LIMIT = 1000

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

local function optionalNonNegativeInt(value: any): number?
    if not isFiniteNumber(value) or value < 0 then
        return nil
    end
    return math.floor(value)
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

-- Receipt values used to be `true`; they are now records so the same bounded
-- map doubles as purchase history. A legacy/unknown marker must still count as
-- seen (idempotency), even when its item, amount or purchase time is unknown.
local function normalizeReceiptRecord(value: any, now: number): { [any]: any }
    if type(value) ~= "table" then
        local stamp = optionalNonNegativeInt(value)
        if stamp then
            return { at = stamp, seenAt = stamp }
        end
        return { at = 0, seenAt = now }
    end

    local record = copy(value)
    local at = optionalNonNegativeInt(record.at)
    local seenAt = optionalNonNegativeInt(record.seenAt)
    if at == nil then
        at = seenAt or 0
    end
    if seenAt == nil then
        seenAt = at
    end
    record.at = at
    record.seenAt = seenAt

    if not ProfileSchema.isItemId(record.item) then
        record.item = nil
    end
    if not isFiniteNumber(record.amount) or record.amount < 1 or record.amount % 1 ~= 0 then
        record.amount = nil
    else
        record.amount = math.floor(record.amount)
    end
    if not isFiniteNumber(record.price) or record.price < 0 or record.price % 1 ~= 0 then
        record.price = nil
    else
        record.price = math.floor(record.price)
    end
    return record
end

-- Keep the newest `RECEIPT_LIMIT` entries by last receipt callback. `seenAt`
-- rather than `at` is intentional: a retried receipt must stay protected from
-- double-granting even if the purchase itself was older.
local function trimReceipts(receipts: { [any]: any }): { [any]: any }
    local count = 0
    for _ in pairs(receipts) do
        count += 1
    end
    if count <= ProfileSchema.RECEIPT_LIMIT then
        return receipts
    end

    local entries = {}
    for key, record in pairs(receipts) do
        entries[#entries + 1] = {
            key = key,
            seenAt = record.seenAt or 0,
            at = record.at or 0,
        }
    end
    table.sort(entries, function(a, b)
        if a.seenAt ~= b.seenAt then
            return a.seenAt > b.seenAt
        end
        if a.at ~= b.at then
            return a.at > b.at
        end
        return a.key < b.key
    end)
    for index = ProfileSchema.RECEIPT_LIMIT + 1, #entries do
        receipts[entries[index].key] = nil
    end
    return receipts
end

local function normalizeReceipts(value: any, now: number): { [any]: any }
    local result = {}
    if type(value) == "table" then
        for key, entry in pairs(value) do
            if type(key) == "string" and key ~= "" then
                result[key] = normalizeReceiptRecord(entry, now)
            end
        end
    end
    return trimReceipts(result)
end

-- Returns a fresh, normalized profile. The input is never modified. Unknown
-- fields from the same schema version are kept so a newer server can add data
-- without this one silently deleting it.
function ProfileSchema.normalize(value: any, now: any): any
    local result = tableOrEmpty(value)
    local defaults = ProfileSchema.newProfile()
    local stamp = optionalNonNegativeInt(now) or os.time()

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

    result.receipts = normalizeReceipts(result.receipts, stamp)

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

function ProfileSchema.getReceipt(profile: any, purchaseId: any): any
    if type(profile) ~= "table" or type(purchaseId) ~= "string" or purchaseId == "" then
        return nil
    end
    local receipts = profile.receipts
    if type(receipts) ~= "table" then
        return nil
    end
    return receipts[purchaseId]
end

function ProfileSchema.hasReceipt(profile: any, purchaseId: any): boolean
    return ProfileSchema.getReceipt(profile, purchaseId) ~= nil
end

-- Grants one paid product atomically with its receipt/history record. A
-- repeated PurchaseId does not add stock; it refreshes seenAt (and fills any
-- missing details on a legacy marker). The caller must still make sure the
-- first grant is durable before telling Roblox the purchase was processed.
function ProfileSchema.grantPurchase(
    profile: any,
    purchaseId: any,
    itemId: any,
    amount: any,
    opts: any?
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

    local now = optionalNonNegativeInt(type(opts) == "table" and opts.now or nil) or os.time()
    local price = nil
    if type(opts) == "table" and isFiniteNumber(opts.price)
        and opts.price >= 0 and opts.price % 1 == 0
    then
        price = math.floor(opts.price)
    end

    local receipts = profile.receipts
    local existing = if type(receipts) == "table" then receipts[purchaseId] else nil
    if existing ~= nil then
        local record = normalizeReceiptRecord(existing, now)
        record.seenAt = now
        if record.item == nil then
            record.item = itemId
        end
        if record.amount == nil then
            record.amount = amount
        end
        if record.price == nil and price ~= nil then
            record.price = price
        end
        receipts[purchaseId] = record
        trimReceipts(receipts)
        return false, "duplicate"
    end

    -- Add stock first: if the inventory is unusable there is no marker to roll
    -- back, and a successful add cannot fail afterwards.
    if not ProfileSchema.addStock(profile, itemId, "purchased", amount) then
        return false, "invalid_item"
    end

    if type(receipts) ~= "table" then
        receipts = {}
        profile.receipts = receipts
    end
    local record = {
        at = now,
        seenAt = now,
        item = itemId,
        amount = math.floor(amount),
    }
    if price ~= nil then
        record.price = price
    end
    receipts[purchaseId] = record
    trimReceipts(receipts)
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
