-- Receipt processing: product mapping, durability, duplicate ids and the
-- disconnected/not-loaded direct store path.
-- Loaded by tests/run.sh from tests/build/match.
local TestLib = require("./testlib")
local check = TestLib.check

local ProfileSchema = require("./ProfileSchema")
local ShopConfig = require("./ShopConfig")
local ShopService = require("./ShopService")

local function newProfile()
    return ProfileSchema.normalize(ProfileSchema.newProfile())
end

local function copy(value)
    if type(value) ~= "table" then
        return value
    end
    local result = {}
    for key, item in pairs(value) do
        result[copy(key)] = copy(item)
    end
    return result
end

local function receipt(purchaseId, productId, userId)
    return {
        PurchaseId = purchaseId,
        ProductId = productId,
        PlayerId = userId,
    }
end

local NEEDLE_PRODUCT = 91001
local REMOTE_PRODUCT = 91002

---------------------------------------------------------------- 上架映射

-- Temporarily clear the deployment ids to pin the "0 = not listed" behavior,
-- then restore them and check that every configured product maps back.
local configuredIds = {}
for _, itemId in ipairs({ "needle", "remote", "kick" }) do
    configuredIds[itemId] = ShopConfig.PRODUCTS[itemId].productId
    ShopConfig.PRODUCTS[itemId].productId = 0
end
check("zero product ids mean not listed", ShopConfig.getProduct("needle") == nil)
check("zero ids resolve to no item", ShopConfig.findByProductId(0) == nil)

for _, itemId in ipairs({ "needle", "remote", "kick" }) do
    ShopConfig.PRODUCTS[itemId].productId = configuredIds[itemId]
    local product = ShopConfig.getProduct(itemId)
    check("the configured " .. itemId .. " product is for sale", product ~= nil)
    check("the configured " .. itemId .. " id maps back",
        product ~= nil and ShopConfig.findByProductId(product.productId) == itemId)
end
check("an unknown product id resolves to no item", ShopConfig.findByProductId(999999) == nil)

-- Use isolated ids for the receipt transaction itself.
ShopConfig.PRODUCTS.needle.productId = NEEDLE_PRODUCT
ShopConfig.PRODUCTS.remote.productId = REMOTE_PRODUCT
check("an enabled product is for sale", ShopConfig.getProduct("needle").productId == NEEDLE_PRODUCT)
check("product ids map back to their item",
    ShopConfig.findByProductId(REMOTE_PRODUCT) == "remote")
check("an unknown live product is still rejected", ShopConfig.findByProductId(91003) == nil)

local function newLoadedEnv()
    local profile = newProfile()
    local env = {
        profile = profile,
        flushOk = true,
        flushReason = nil,
        flushCalls = 0,
        grantedCalls = 0,
        grantsThrow = false,
    }
    env.profiles = {
        getProfile = function(_, player)
            if env.profile == nil then
                return nil
            end
            return env.profile
        end,
        flush = function(_, player, seconds)
            env.flushCalls += 1
            return env.flushOk, env.flushReason
        end,
    }
    env.service = ShopService.new({
        profiles = env.profiles,
        flushSeconds = 3,
        logger = function(_message) end,
        onGranted = function(player)
            env.grantedCalls += 1
            if env.grantsThrow then
                error("ui refresh failed")
            end
        end,
    })
    return env
end

local function newDirectEnv()
    local env = {
        stored = newProfile(),
        loadReason = nil,
        saveFailures = 0,
        loads = 0,
        saves = {},
        grantedCalls = 0,
    }
    env.store = {
        load = function(_, userId)
            env.loads += 1
            if env.loadReason then
                return nil, env.loadReason
            end
            return {
                userId = userId,
                data = copy(env.stored),
            }
        end,
        save = function(_, handle, release)
            table.insert(env.saves, { release = release == true, data = copy(handle.data) })
            if env.saveFailures > 0 then
                env.saveFailures -= 1
                return false, "datastore_error"
            end
            env.stored = copy(handle.data)
            return true
        end,
    }
    env.service = ShopService.new({
        profiles = {
            getProfile = function()
                return nil
            end,
            flush = function()
                error("flush should not be used on the direct path")
            end,
        },
        store = env.store,
        logger = function(_message) end,
        onGranted = function()
            env.grantedCalls += 1
        end,
    })
    return env
end

---------------------------------------------------------------- 参数校验

local env = newLoadedEnv()
local player = { UserId = 101, Parent = {} }

local ok, reason = env.service:processReceipt(nil, receipt("r1", NEEDLE_PRODUCT, 101))
check("a missing player is rejected", ok == false and reason == "invalid_player", reason)
ok, reason = env.service:processReceipt(player, nil)
check("a missing receipt is rejected", ok == false and reason == "invalid_receipt", reason)
ok, reason = env.service:processReceipt(player, receipt("", NEEDLE_PRODUCT, 101))
check("an empty purchase id is rejected", ok == false and reason == "invalid_receipt", reason)
ok, reason = env.service:processReceipt(player, receipt("r2", NEEDLE_PRODUCT, 202))
check("a mismatched receipt player is rejected", ok == false and reason == "player_mismatch", reason)
ok, reason = env.service:processReceipt(player, receipt("r3", 0, 101))
check("a disabled product is rejected", ok == false and reason == "unknown_product", reason)
check("a rejected receipt does not grant stock", env.profile.inventory.needle.purchased == 0)
check("a rejected receipt does not write", env.flushCalls == 0, env.flushCalls)

---------------------------------------------------------------- 在线档案：先落盘，再确认

ok, reason = env.service:processReceipt(player, receipt("r4", NEEDLE_PRODUCT, 101))
check("a valid receipt is granted", ok == true, reason)
check("the grant lands in purchased stock", env.profile.inventory.needle.purchased == 1,
    env.profile.inventory.needle.purchased)
check("the receipt id is stored", ProfileSchema.hasReceipt(env.profile, "r4"))
check("the live profile is flushed", env.flushCalls == 1, env.flushCalls)
check("the UI is notified after the flush", env.grantedCalls == 1, env.grantedCalls)

ok, reason = env.service:processReceipt(player, receipt("r4", NEEDLE_PRODUCT, 101))
check("a duplicate receipt is acknowledged", ok == true, reason)
check("a duplicate receipt does not grant again", env.profile.inventory.needle.purchased == 1,
    env.profile.inventory.needle.purchased)
check("a duplicate receipt is still checked for durability", env.flushCalls == 2, env.flushCalls)

env.flushOk = false
env.flushReason = "timeout"
ok, reason = env.service:processReceipt(player, receipt("r5", REMOTE_PRODUCT, 101))
check("a non-durable grant is not acknowledged", ok == false and reason == "not_durable", reason)
check("the in-memory grant is still present", env.profile.inventory.remote.purchased == 1,
    env.profile.inventory.remote.purchased)
check("a non-durable grant does not notify the UI", env.grantedCalls == 2, env.grantedCalls)
local flushesBefore = env.flushCalls

env.flushOk = true
env.flushReason = nil
ok, reason = env.service:processReceipt(player, receipt("r5", REMOTE_PRODUCT, 101))
check("a retry acknowledges the stored receipt", ok == true, reason)
check("a retry does not double-grant", env.profile.inventory.remote.purchased == 1,
    env.profile.inventory.remote.purchased)
check("a retry re-checks durability", env.flushCalls == flushesBefore + 1, env.flushCalls)
check("a successful retry notifies the UI", env.grantedCalls == 3, env.grantedCalls)

env.grantsThrow = true
ok, reason = env.service:processReceipt(player, receipt("r6", NEEDLE_PRODUCT, 101))
check("a UI notification failure cannot undo a durable grant",
    ok == true and env.profile.inventory.needle.purchased == 2, reason)

---------------------------------------------------------------- 已断线 / 未加载：直接锁内交易

local direct = newDirectEnv()
local absent = { UserId = 303, Parent = nil }
local directOk, directReason = direct.service:processReceipt(
    absent,
    receipt("direct-1", NEEDLE_PRODUCT, 303)
)
check("a receipt for a disconnected player succeeds", directOk == true, directReason)
check("the direct path writes purchased stock", direct.stored.inventory.needle.purchased == 1,
    direct.stored.inventory.needle.purchased)
check("the direct path releases its lock", direct.saves[#direct.saves].release == true)
check("the direct path never notifies a missing player", direct.grantedCalls == 0)

direct.service:processReceipt(absent, receipt("direct-1", NEEDLE_PRODUCT, 303))
check("a direct duplicate is acknowledged without a second grant",
    direct.stored.inventory.needle.purchased == 1,
    direct.stored.inventory.needle.purchased)
check("a direct duplicate still releases the lock it acquired",
    #direct.saves == 2 and direct.saves[2].release == true, #direct.saves)

local savesBeforeLocked = #direct.saves
direct.loadReason = "locked"
directOk, directReason = direct.service:processReceipt(
    absent,
    receipt("direct-2", REMOTE_PRODUCT, 303)
)
check("a still-locked profile defers the receipt",
    directOk == false and directReason == "not_loaded", directReason)
check("a deferred receipt does not write", #direct.saves == savesBeforeLocked)
direct.loadReason = nil

direct.saveFailures = 1
directOk, directReason = direct.service:processReceipt(
    absent,
    receipt("direct-2", REMOTE_PRODUCT, 303)
)
check("a store write failure defers the receipt", directOk == false and directReason == "not_durable",
    directReason)
check("a failed direct write leaves stored stock alone",
    direct.stored.inventory.remote.purchased == 0, direct.stored.inventory.remote.purchased)

directOk, directReason = direct.service:processReceipt(
    absent,
    receipt("direct-2", REMOTE_PRODUCT, 303)
)
check("a direct retry grants exactly once", directOk == true
    and direct.stored.inventory.remote.purchased == 1, directReason)

TestLib.finish()
