-- src/shared/Shop.luau
-- Pure shop/loadout rules shared by the server and the client. There is no
-- Roblox service access here: the catalog is data, the inventory lives in the
-- profile, and settlement only mutates plain tables.
--
-- Loadouts are player intent, clamped to each item's entry cap. The effective
-- carry is min(loadout, owned stock, cap), so buying more stock never changes a
-- saved loadout and a temporarily empty stock never erases it.

local Shop = {}

Shop.ITEM_ORDER = { "needle", "remote", "kick" }

Shop.ITEMS = {
    needle = {
        name = "逃生针",
        short = "针",
        description = "被困时用掉 1 根，立刻脱身。",
        cap = 2,
    },
    remote = {
        name = "遥控炸弹",
        short = "遥",
        description = "放下一枚遥控泡泡，再按一次使用键引爆。",
        cap = 1,
    },
    kick = {
        name = "踢泡泡",
        short = "踢",
        description = "本局可以踢泡泡；成功踢到至少一枚才扣 1 个。",
        cap = 1,
    },
}

local function isFiniteNumber(value: any): boolean
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function nonNegativeInt(value: any): number
    if not isFiniteNumber(value) then
        return 0
    end
    return math.max(0, math.floor(value))
end

local function bucketOf(profile: any, itemId: string)
    if type(profile) ~= "table" then
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

function Shop.isItemId(itemId: any): boolean
    return type(itemId) == "string" and Shop.ITEMS[itemId] ~= nil
end

function Shop.newLoadout()
    local loadout = {}
    for _, itemId in ipairs(Shop.ITEM_ORDER) do
        loadout[itemId] = 0
    end
    return loadout
end

function Shop.clampLoadoutValue(itemId: any, value: any): number
    if not Shop.isItemId(itemId) then
        return 0
    end
    return math.min(Shop.ITEMS[itemId].cap, nonNegativeInt(value))
end

-- Copies the input (including unknown fields) and clamps the known item ids.
function Shop.normalizeLoadout(value: any): { [string]: number }
    local result = if type(value) == "table" then table.clone(value) else {}
    for _, itemId in ipairs(Shop.ITEM_ORDER) do
        result[itemId] = Shop.clampLoadoutValue(itemId, result[itemId])
    end
    return result
end

function Shop.totalStock(profile: any, itemId: any): number
    if not Shop.isItemId(itemId) then
        return 0
    end
    local bucket = bucketOf(profile, itemId)
    if not bucket then
        return 0
    end
    return nonNegativeInt(bucket.free) + nonNegativeInt(bucket.purchased)
end

function Shop.stock(profile: any, itemId: any): (number, number)
    if not Shop.isItemId(itemId) then
        return 0, 0
    end
    local bucket = bucketOf(profile, itemId)
    if not bucket then
        return 0, 0
    end
    return nonNegativeInt(bucket.free), nonNegativeInt(bucket.purchased)
end

function Shop.loadoutValue(profile: any, itemId: any): number
    if not Shop.isItemId(itemId) or type(profile) ~= "table" then
        return 0
    end
    local loadout = profile.loadout
    if type(loadout) ~= "table" then
        return 0
    end
    return Shop.clampLoadoutValue(itemId, loadout[itemId])
end

-- The number of each item actually brought into the round.
function Shop.effectiveCarry(profile: any): { [string]: number }
    local carry = {}
    for _, itemId in ipairs(Shop.ITEM_ORDER) do
        local wanted = Shop.loadoutValue(profile, itemId)
        carry[itemId] = math.min(wanted, Shop.totalStock(profile, itemId), Shop.ITEMS[itemId].cap)
    end
    return carry
end

local function usageOf(used: any, itemId: string): number
    if type(used) ~= "table" then
        return 0
    end
    return nonNegativeInt(used[itemId])
end

-- How much should be deducted after a round. Map pickups are counted as using
-- the brought stock first, but never beyond what was actually carried.
function Shop.usageCharge(carry: any, used: any): { [string]: number }
    local charge = {}
    for _, itemId in ipairs(Shop.ITEM_ORDER) do
        local carried = if type(carry) == "table" then nonNegativeInt(carry[itemId]) else 0
        local actual = usageOf(used, itemId)
        charge[itemId] = math.min(carried, actual, Shop.ITEMS[itemId].cap)
    end
    return charge
end

-- Deduct min(carry, usage) from the profile, free stock first. The deduction is
-- also capped by what the profile currently owns, so corrupted/edited stock can
-- never go negative. Returns what was actually taken from each bucket.
function Shop.settleUsage(profile: any, carry: any, used: any)
    local charge = Shop.usageCharge(carry, used)
    local spent = {
        needle = { free = 0, purchased = 0 },
        remote = { free = 0, purchased = 0 },
        kick = { free = 0, purchased = 0 },
    }
    if type(profile) ~= "table" then
        return spent, charge
    end

    for _, itemId in ipairs(Shop.ITEM_ORDER) do
        local amount = math.min(charge[itemId], Shop.totalStock(profile, itemId))
        if amount > 0 then
            local bucket = bucketOf(profile, itemId)
            if bucket then
                local free = nonNegativeInt(bucket.free)
                local purchased = nonNegativeInt(bucket.purchased)
                local fromFree = math.min(free, amount)
                local fromPurchased = amount - fromFree
                bucket.free = free - fromFree
                bucket.purchased = purchased - fromPurchased
                spent[itemId].free = fromFree
                spent[itemId].purchased = fromPurchased
            end
        end
    end
    return spent, charge
end

-- Practice rounds are free by default. The server config can flip this switch
-- when it needs to test real inventory consumption.
function Shop.shouldConsume(mode: any, consumeInPractice: boolean): boolean
    if mode == "practice" then
        return consumeInPractice == true
    end
    return true
end

-- Short "针2 遥1 踢" line used by the waiting roster and the sidebar.
function Shop.describeItems(items: any): string
    if type(items) ~= "table" then
        return "无道具"
    end
    local parts = {}
    for _, itemId in ipairs(Shop.ITEM_ORDER) do
        local count = nonNegativeInt(items[itemId])
        if count > 0 then
            local info = Shop.ITEMS[itemId]
            if itemId == "kick" then
                table.insert(parts, info.short)
            else
                table.insert(parts, info.short .. tostring(count))
            end
        end
    end
    if #parts == 0 then
        return "无道具"
    end
    return table.concat(parts, " ")
end

return table.freeze(Shop)
