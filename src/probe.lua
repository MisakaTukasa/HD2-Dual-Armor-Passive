-- HD2-Addon: mods/hd2/dual_armor_probe
-- Read-only runtime probe. It never changes equipment or process memory.

if rawget(_G, "HD2DualArmorProbe") then return end

local P = {
    version = "probe-2",
    frames = 0,
    phase = "starting",
    regions = {},
    region_cursor = 1,
    scan_offset = 0,
    scanned = 0,
    candidates = {},
    f9_count = 0,
    events = {},
    next_address = 0x10000,
}
rawset(_G, "HD2DualArmorProbe", P)

local ffi = require("ffi")
local declarations = {
    "void *GetCurrentProcess(void);",
    "int ReadProcessMemory(void *process, const void *address, void *buffer, size_t size, size_t *read);",
    "size_t VirtualQuery(const void *address, void *region, size_t size);",
    [[typedef struct {
        void *base; void *allocation_base; uint32_t allocation_protection;
        uint16_t partition; uint16_t reserved; size_t size;
        uint32_t state; uint32_t protection; uint32_t type;
    } HD2ProbeMemRegion;]],
}
for i = 1, #declarations do pcall(ffi.cdef, declarations[i]) end
local kernel = ffi.load("kernel32")
local process = kernel.GetCurrentProcess()
local region = ffi.new("HD2ProbeMemRegion[1]")
local read_count = ffi.new("size_t[1]")
local buffer = ffi.new("uint8_t[?]", 65536)
local max_address = 0x7fffffffffff
local magic = "LDLD"
-- The following 12 bytes are the armorset data type marker from the prior build.
-- The record count may change, but this marker distinguishes armorsets from
-- other datalibrary blobs that also begin with LDLD.
local armor_mark = magic .. string.char(1, 0, 0, 0, 160, 90, 165, 217)
local samples = {
    {2616, 0x7934ed8b}, {5384, 0x056848e9}, {13304, 0xa3a7e93d},
    {31736, 0x584ab37b}, {72008, 0x8abccc54}, {120808, 0x9f3f8a17},
    {180712, 0x2180eb8d}, {379880, 0x9cc5cc35},
    {384040, 0x0b84e99d},
}

local function event(message)
    P.events[#P.events + 1] = string.format("frame %d: %s", P.frames, message)
    if #P.events > 80 then table.remove(P.events, 1) end
end

local function scrub(value)
    local result = tostring(value):gsub("%a:[\\/][^%s,;]*", "<path>")
    return result:sub(1, 300):gsub("%c", " ")
end

local function log()
    local loader = rawget(_G, "CowboyBingusModLoader")
    if type(loader) ~= "table" or type(loader.open_log) ~= "function" then return end
    local ok, file = pcall(loader.open_log, "HD2DualArmorProbe.log")
    if not ok or not file then return end
    local lines = {
        "HD2 Dual Armor Passive Probe " .. P.version,
        "Loader API: " .. tostring(loader.api),
        "Phase: " .. P.phase,
        "Frames: " .. P.frames,
        "F9 presses: " .. P.f9_count,
        "Keyboard route: " .. tostring(P.key_route),
        "Engine table: " .. tostring(P.engine_table),
        "World count: " .. tostring(P.world_count),
        "Cursor visible: " .. tostring(P.cursor_visible),
        "Screen: " .. tostring(P.screen),
        "Regions: " .. #P.regions .. ", scanned: " .. math.floor(P.scanned / 1048576) .. " MiB",
        "Candidates: " .. #P.candidates,
    }
    for i = 1, #P.candidates do lines[#lines + 1] = P.candidates[i] end
    lines[#lines + 1] = "Events:"
    for i = 1, #P.events do lines[#lines + 1] = P.events[i] end
    pcall(function() file:write(table.concat(lines, "\n"), "\n"); file:close() end)
end

local function read_memory(address, length)
    if length > 65536 or length < 1 then return nil end
    local ok = kernel.ReadProcessMemory(process, ffi.cast("const void *", address), buffer, length, read_count)
    if ok == 0 or tonumber(read_count[0]) ~= length then return nil end
    return ffi.string(buffer, length)
end

local function u32(data, at)
    local a, b, c, d = data:byte(at, at + 3)
    if not d then return nil end
    return a + b * 256 + c * 65536 + d * 16777216
end

local function le_bytes(value)
    return string.char(value % 256, math.floor(value / 256) % 256,
        math.floor(value / 65536) % 256, math.floor(value / 16777216) % 256)
end

local function inspect_candidate(address, count)
    if #P.candidates >= 8 then return end
    local first = read_memory(address, 64)
    if not first or first:sub(5, 16) ~= armor_mark then return end
    local good = 0
    local report = {}
    for i = 1, #samples do
        local offset, kit = samples[i][1], samples[i][2]
        local word = read_memory(address + offset, 4)
        local value = word and u32(word, 1) or nil
        local around = read_memory(address + offset - 128, 256)
        local id_at = around and around:find(le_bytes(kit), 1, true) or nil
        local id_delta = id_at and (id_at - 1 - 128) or nil
        if value == 0 then good = good + 1 end
        report[#report + 1] = string.format("+%d=%s,kit_delta=%s", offset,
            value and string.format("0x%08x", value) or "unreadable",
            id_delta and tostring(id_delta) or "missing")
    end
    local line = string.format(
        "@0x%x count=%d zero-samples=%d/%d head=%s fields=%s",
        address, count, good, #samples,
        first:gsub(".", function(c) return string.format("%02x", c:byte()) end),
        table.concat(report, ",")
    )
    P.candidates[#P.candidates + 1] = line
    event("armorsets marker matched; sample zero fields " .. good .. "/" .. #samples)
    P.best = address
    P.phase = "armorsets marker matched; ready for review"
    log()
end

local function scan_bytes(base, data)
    local pos = 1
    while true do
        local at = data:find(magic, pos, true)
        if not at then return end
        if at >= 5 then
            local count = u32(data, at - 4)
            if count and count >= 200 and count <= 700
                and data:sub(at, at + 11) == armor_mark then
                local address = base + at - 5
                inspect_candidate(address, count)
            end
        end
        pos = at + 4
    end
end

local function enumerate_step()
    local n = 0
    while P.next_address < max_address and n < 180 do
        local address = P.next_address
        local size = kernel.VirtualQuery(ffi.cast("const void *", address), region, ffi.sizeof(region[0]))
        if size ~= ffi.sizeof(region[0]) then
            P.phase = "enumeration finished"
            P.region_cursor = 1
            return
        end
        local base = tonumber(ffi.cast("uintptr_t", region[0].base))
        local length = tonumber(region[0].size)
        P.next_address = base + math.max(length, 4096)
        if P.next_address <= address then P.phase = "enumeration stopped"; return end
        local protection = tonumber(region[0].protection)
        local low = protection % 256
        local readable = low == 0x02 or low == 0x04 or low == 0x08
        if tonumber(region[0].state) == 0x1000 and tonumber(region[0].type) == 0x20000
            and readable and length >= 4096 then
            P.regions[#P.regions + 1] = {base, length}
            local first = read_memory(base, math.min(256, length))
            if first then scan_bytes(base, first) end
        end
        n = n + 1
        if P.best then return end
    end
    if P.next_address >= max_address then P.phase = "enumeration finished" end
end

local function sweep_step()
    for _ = 1, 3 do
        local item = P.regions[P.region_cursor]
        if not item then P.phase = "scan finished; no validated candidate"; log(); return end
        local base, length = item[1], item[2]
        if P.scan_offset >= length then
            P.region_cursor = P.region_cursor + 1
            P.scan_offset = 0
        else
            local n = math.min(65536, length - P.scan_offset)
            local chunk = read_memory(base + P.scan_offset, n)
            if chunk then scan_bytes(base + P.scan_offset, chunk) end
            P.scan_offset = P.scan_offset + n
            P.scanned = P.scanned + n
            if P.best then return end
        end
    end
end

local function engine_step()
    local s3d = rawget(_G, "s3d") or rawget(_G, "stingray")
    if type(s3d) ~= "table" then P.engine_table = "missing"; return end
    P.engine_table = rawget(_G, "s3d") and "s3d" or "stingray"
    local keyboard = s3d.Keyboard
    if type(keyboard) == "table" and type(keyboard.pressed) == "function" then
        local index = 120
        if type(keyboard.button_index) == "function" then
            local ok, value = pcall(keyboard.button_index, "f9")
            if ok and type(value) == "number" then index = value end
        end
        P.key_route = "Keyboard.pressed(" .. index .. ")"
        local ok, pressed = pcall(keyboard.pressed, index)
        if ok and pressed then
            P.f9_count = P.f9_count + 1
            event(string.format("F9 pressed; worlds=%s cursor=%s screen=%s",
                tostring(P.world_count), tostring(P.cursor_visible), tostring(P.screen)))
            log()
        end
    end
    if P.frames % 30 == 0 then
        local app = s3d.Application
        if type(app) == "table" and type(app.worlds) == "function" then
            local ok, worlds = pcall(app.worlds)
            if ok and type(worlds) == "table" then P.world_count = #worlds end
        end
        local window = s3d.Window
        if type(window) == "table" and type(window.show_cursor) == "function" then
            local ok, visible = pcall(window.show_cursor)
            if ok then P.cursor_visible = visible end
        end
        local gui = s3d.Gui
        if type(gui) == "table" and type(gui.resolution) == "function" then
            local ok, w, h = pcall(gui.resolution)
            if ok and w and h then P.screen = tostring(w) .. "x" .. tostring(h) end
        end
    end
end

local function tick()
    if P.failed then return end
    P.frames = P.frames + 1
    engine_step()
    if P.frames < 120 or P.frames % 3 ~= 0 or P.best then return end
    if P.phase == "starting" then P.phase = "enumerating regions" end
    if P.phase == "enumerating regions" then enumerate_step()
    elseif P.phase == "enumeration finished" then P.phase = "scanning regions"
    elseif P.phase == "scanning regions" then sweep_step() end
    if P.frames % 600 == 0 then log() end
end

local previous_update = rawget(_G, "update")
update = function(...)
    local result
    if previous_update then result = {previous_update(...)} end
    local ok, err = pcall(tick)
    if not ok then P.failed = true; P.phase = "error: " .. scrub(err); event(P.phase); log() end
    if result then return unpack(result) end
end

local previous_shutdown = rawget(_G, "shutdown")
shutdown = function(...)
    event("clean shutdown")
    log()
    if previous_shutdown then return previous_shutdown(...) end
end

event("probe initialized")
log()
