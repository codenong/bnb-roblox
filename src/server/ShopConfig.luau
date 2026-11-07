-- src/server/ShopConfig.luau
-- Deployment-specific shop settings. Nothing here is secret, but only the
-- server decides what a ProductId grants.
--
-- ProductId 0 means "not listed yet": the shop still shows the item and its
-- stock, but the purchase button stays disabled. The ids below are the fixed
-- Developer Product identifiers for this experience; changing a product's name
-- or Robux price in the Creator Dashboard keeps the same id, while deleting and
-- recreating the product produces a new one. The Robux price is configured
-- there, never in code; the native purchase prompt handles the player's balance
-- and insufficient-funds cases.
--
-- Roblox Developer Products have a fixed price and a fixed grant per product.
-- There is no quantity selector, cart or custom total, so the shop sells one
-- item per native purchase prompt.

local ITEM_IDS = { "needle", "remote", "kick" }
local ITEM_SET = { needle = true, remote = true, kick = true }

local ShopConfig = {}

-- One product per item, one unit per purchase. `amount` remains in the schema
-- for future fixed bundles, but no pack/cart UI is exposed.
ShopConfig.PRODUCTS = {
    needle = { productId = 3729274253, amount = 1 }, -- Escape Needle
    remote = { productId = 3729278162, amount = 1 }, -- Remote Control
    kick = { productId = 3729285352, amount = 1 }, -- Bubble Kick Shoes
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
