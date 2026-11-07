-- src/server/ShopConfig.luau
-- Deployment-specific shop settings. Nothing here is secret, but only the
-- server decides what a ProductId grants.
--
-- ProductId 0 means "not listed yet": the shop still shows the item and its
-- stock, but the purchase button stays disabled. Replace each 0 with the
-- Developer Product id from the Creator Dashboard when it exists. The Robux
-- price is configured there, never in code; the native purchase prompt handles
-- the player's balance and insufficient-funds cases.

local ITEM_IDS = { "needle", "remote", "kick" }
local ITEM_SET = { needle = true, remote = true, kick = true }

local ShopConfig = {}

-- Practice is free by default: using brought items never changes saved stock.
-- Set this to true to exercise real inventory consumption in practice when
-- testing the payment/accounting path.
ShopConfig.CONSUME_IN_PRACTICE = false

-- One product per item. `amount` is how much stock one purchase grants.
ShopConfig.PRODUCTS = {
    needle = { productId = 0, amount = 1 },
    remote = { productId = 0, amount = 1 },
    kick = { productId = 0, amount = 1 },
}

-- Returns nil for unknown or disabled products so both the shop UI and
-- ProcessReceipt treat the placeholder ids as "not for sale".
function ShopConfig.getProduct(itemId: any)
    if type(itemId) ~= "string" or not ITEM_SET[itemId] then
        return nil
    end
    local entry = ShopConfig.PRODUCTS[itemId]
    if type(entry) ~= "table" then
        return nil
    end
    local productId = entry.productId
    local amount = entry.amount
    if type(productId) ~= "number" or productId <= 0 or productId % 1 ~= 0 then
        return nil
    end
    if type(amount) ~= "number" or amount < 1 or amount % 1 ~= 0 then
        return nil
    end
    return {
        productId = productId,
        amount = amount,
    }
end

function ShopConfig.findByProductId(productId: any): (string?, { productId: number, amount: number }?)
    if type(productId) ~= "number" then
        return nil, nil
    end
    for _, itemId in ipairs(ITEM_IDS) do
        local product = ShopConfig.getProduct(itemId)
        if product and product.productId == productId then
            return itemId, product
        end
    end
    return nil, nil
end

return ShopConfig
