-- Owned-buffer search equivalence, using the exact production module.
ffi = require("ffi")
M = {}
local notices = 0
note = function() notices = notices + 1 end
local original_load = ffi.load
if CASE == "search_missing_library" then ffi.load = function() error("missing library") end end
if CASE == "search_missing_symbol" then
    ffi.load = function() return setmetatable({}, {__index = function() error("missing symbol") end}) end
end
local search = assert(loadstring(MOD_SOURCE .. "\nreturn search"))()
local marker = string.char(8, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0)
local function check(buffer, amount)
    local text, state, next_at, count = ffi.string(buffer, amount), search.prepare(buffer, amount, marker), 1, 0
    while true do
        local expected = text:find(marker, next_at, true)
        local actual = search.find(state, next_at)
        assert(actual == expected, "ordered marker positions differ")
        if not actual then return count end
        count, next_at = count + 1, actual + 1
    end
end
local tiny = ffi.new("uint8_t[128]")
for length = 0, 64 do
    ffi.fill(tiny, 128, 255); assert(check(tiny, length) == 0)
    for at = 0, length - 12 do
        ffi.fill(tiny, 128, 255); ffi.copy(tiny + at, marker, 12)
        assert(check(tiny, length) == 1)
    end
end
local dense = ffi.new("uint8_t[65536]")
ffi.fill(dense, 65536, 8)
for _, at in ipairs({0, 300, 12000, 65524}) do ffi.copy(dense + at, marker, 12) end
local copies = search.copies
assert(check(dense, 65536) == 4)
assert(search.copies == copies + 1, "dense block copies exactly once")
assert(not search.native or search.fallbacks > 0, "native density budget is cumulative")
local buffer = ffi.new("uint8_t[?]", 0x100200)
ffi.fill(buffer, 0x100200, 255)
for _, at in ipairs({1, 0xffffb, 0x100080, 0x1001f4}) do ffi.copy(buffer + at, marker, 12) end
assert(check(buffer, 0x100200) == 4)
assert(not pcall(search.prepare, buffer, 0x100201, marker), "oversized buffers rejected")
assert(not pcall(search.prepare, buffer, -1, marker), "negative lengths rejected")
assert(not pcall(search.prepare, buffer, 12.5, marker), "fractional lengths rejected")
assert(not pcall(search.prepare, buffer, 10, "bad"), "unsupported marker lengths rejected")
local valid = search.prepare(buffer, 0x100200, marker)
for _, start in ipairs({0, -1, 1.5, "1"}) do
    assert(not pcall(search.find, valid, start), "invalid start rejected before native pointer arithmetic")
end
assert(notices == 1, "backend is resolved and diagnosed once")
ffi.load = original_load
RESULT_reads = "0"
