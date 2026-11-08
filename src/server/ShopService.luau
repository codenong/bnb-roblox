-- src/server/ShopService.luau
-- Developer Product receipts. Pure Luau: ProfileService/ProfileStore are
-- injected so the receipt rules run headlessly against a fake DataStore.
--
-- A receipt is acknowledged only after its grant (or its duplicate marker) is
-- durable. If the player is still connected we flush their live profile; a
-- disconnected/not-yet-loaded player gets a direct load/grant/release so a
-- purchase cannot be lost merely because the player left mid-transaction.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ProfileSchema = require(Shared:WaitForChild("ProfileSchema"))

local ShopConfig = require(script.Parent:WaitForChild("ShopConfig"))

local ShopService = {}
ShopService.__index = ShopService

function ShopService.new(opts)
    opts = opts or {}
    return setmetatable({
        profiles = opts.profiles,
        store = opts.store,
        flushSeconds = tonumber(opts.flushSeconds) or 10,
        logger = opts.logger or function(_message: string)
        end,
        onGranted = opts.onGranted or function(_player)
        end,
    }, ShopService)
end

function ShopService:_log(message: string)
    local ok = pcall(self.logger, message)
    if not ok then
        -- Diagnostic logging must never change a purchase decision.
    end
end

function ShopService:_notify(player)
    local ok, err = pcall(self.onGranted, player)
    if not ok then
        self:_log("[BnB] purchase UI refresh failed: " .. tostring(err))
    end
end

-- Live profile path. The profile object is the same table PlayerService and the
-- match room see, so a successful flush immediately updates stock and the next
-- round's automatic carry without a reload.
function ShopService:_grantLoaded(player, purchaseId, itemId, amount)
    local profile = self.profiles:getProfile(player)
    if not profile then
        return nil -- caller falls back to a direct store transaction
    end

    local granted, reason = ProfileSchema.grantPurchase(profile, purchaseId, itemId, amount)
    if not granted and reason ~= "duplicate" then
        self:_log(string.format(
            "[BnB] receipt %s could not be granted to %s: %s",
            purchaseId,
            tostring(player.UserId),
            tostring(reason)
        ))
        return false, "invalid_grant"
    end

    local durable, flushReason = self.profiles:flush(player, self.flushSeconds)
    if not durable then
        self:_log(string.format(
            "[BnB] receipt %s not durable for %s: %s",
            purchaseId,
            tostring(player.UserId),
            tostring(flushReason)
        ))
        return false, "not_durable"
    end

    self:_notify(player)
    return true
end

-- Disconnected or not-yet-loaded player path. Acquiring the lock, granting and
-- releasing in one call also makes a concurrent purchase retry serialize behind
-- the same per-profile lock rather than double-granting.
function ShopService:_grantDirect(player, purchaseId, itemId, amount)
    if not self.store then
        return false, "no_store"
    end

    local handle, loadReason = self.store:load(player.UserId)
    if not handle then
        self:_log(string.format(
            "[BnB] receipt %s could not load %s: %s",
            purchaseId,
            tostring(player.UserId),
            tostring(loadReason)
        ))
        return false, "not_loaded"
    end

    local granted, reason = ProfileSchema.grantPurchase(handle.data, purchaseId, itemId, amount)
    if not granted and reason ~= "duplicate" then
        self.store:save(handle, true)
        self:_log(string.format(
            "[BnB] direct receipt %s was invalid for %s: %s",
            purchaseId,
            tostring(player.UserId),
            tostring(reason)
        ))
        return false, "invalid_grant"
    end

    local saved, saveReason = self.store:save(handle, true)
    if not saved then
        self:_log(string.format(
            "[BnB] direct receipt %s not durable for %s: %s",
            purchaseId,
            tostring(player.UserId),
            tostring(saveReason)
        ))
        return false, "not_durable"
    end
    return true
end

-- Returns true when Roblox may finalize the purchase. Every failure path returns
-- false so ProcessReceipt can answer NotProcessedYet; the next callback retries
-- both the grant and the durability check, with the receipt id preventing a
-- duplicate grant.
function ShopService:processReceipt(player, receiptInfo): (boolean, string?)
    -- A connected player is a Roblox Instance, for which type() answers "userdata"
    -- (only typeof() says "Instance"); an offline buyer is a plain table. Do not
    -- test the type name: accept anything that exposes a numeric UserId.
    local readable, userId = pcall(function()
        return (player :: any).UserId
    end)
    if not readable or type(userId) ~= "number" then
        return false, "invalid_player"
    end
    if type(receiptInfo) ~= "table" then
        return false, "invalid_receipt"
    end

    local purchaseId = receiptInfo.PurchaseId
    if type(purchaseId) ~= "string" or purchaseId == "" then
        return false, "invalid_receipt"
    end

    if receiptInfo.PlayerId ~= nil and receiptInfo.PlayerId ~= player.UserId then
        self:_log(string.format(
            "[BnB] receipt %s player mismatch (%s != %s)",
            purchaseId,
            tostring(receiptInfo.PlayerId),
            tostring(player.UserId)
        ))
        return false, "player_mismatch"
    end

    local itemId, product = ShopConfig.findByProductId(receiptInfo.ProductId)
    if not itemId or not product then
        self:_log(string.format(
            "[BnB] receipt %s references unknown/disabled product %s",
            purchaseId,
            tostring(receiptInfo.ProductId)
        ))
        return false, "unknown_product"
    end

    local ok, reason = self:_grantLoaded(player, purchaseId, itemId, product.amount)
    if ok ~= nil then
        return ok, reason
    end
    return self:_grantDirect(player, purchaseId, itemId, product.amount)
end

return ShopService
