-- src/shared/RoomName.luau
-- Pure room-name rules shared by the server and HUD. The server still filters
-- user text through TextService before storing it; this module only normalizes
-- and validates the characters and length.

local Constants = require(script.Parent.Constants)

local RoomName = {}

local MAX_CODEPOINTS = Constants.ROOM_NAME_MAX_CODEPOINTS

-- C0 controls other than LF, DEL, and C1 controls are never allowed. CR is
-- normalized to LF before this check so Windows-style input is accepted.
local function validateBody(text)
    local length = utf8.len(text)
    if length == nil then
        return nil
    end
    local nonWhitespace = false
    for _, code in utf8.codes(text) do
        if code == 127 or (code >= 128 and code <= 159) then
            return nil
        end
        if code < 32 and code ~= 10 then
            return nil
        end
        if code ~= 32 and code ~= 10 then
            nonWhitespace = true
        end
    end
    if not nonWhitespace then
        return nil
    end
    if length < 1 or length > MAX_CODEPOINTS then
        return nil
    end
    return text
end

-- Normalize line endings, trim surrounding spaces/newlines, then validate.
function RoomName.normalize(raw)
    if type(raw) ~= "string" then
        return nil, "invalid_name"
    end
    local text = raw:gsub("\r\n", "\n"):gsub("\r", "\n")
    text = text:gsub("^[ \n]+", ""):gsub("[ \n]+$", "")
    local valid = validateBody(text)
    if not valid then
        return nil, "invalid_name"
    end
    return valid
end

-- Revalidate TextService output. The filter may change spacing, so do not trim
-- here, but the result still has to be safe and within the same length limit.
function RoomName.validateFiltered(text)
    if type(text) ~= "string" then
        return nil, "filter_failed"
    end
    local valid = validateBody(text)
    if not valid then
        return nil, "filter_failed"
    end
    return valid
end

-- Names may contain newlines, but table rows and titles are single-line. Keep
-- the stored value intact and collapse line breaks only for display.
function RoomName.display(name)
    if type(name) ~= "string" then
        return nil
    end
    local text = name:gsub("\r\n", "\n"):gsub("[\r\n]+", " ")
    text = text:gsub("^ +", ""):gsub(" +$", "")
    if text == "" then
        return nil
    end
    return text
end

return table.freeze(RoomName)
