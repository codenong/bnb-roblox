-- Minimal headless test helpers (Luau CLI).

local TestLib = { passed = 0, failed = 0 }

function TestLib.check(name: string, condition: any, extra: any)
    if condition then
        TestLib.passed += 1
    else
        TestLib.failed += 1
        local suffix = if extra ~= nil then " -> " .. tostring(extra) else ""
        print("FAIL: " .. name .. suffix)
    end
end

function TestLib.near(a: number, b: number, eps: number?): boolean
    return math.abs(a - b) <= (eps or 1e-6)
end

function TestLib.finish()
    print(string.format("%d passed, %d failed", TestLib.passed, TestLib.failed))
    if TestLib.failed > 0 then
        error(string.format("%d test(s) failed", TestLib.failed), 0)
    end
end

return TestLib
