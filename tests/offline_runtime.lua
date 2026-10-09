-- Isolated fixtures for the actual expanded addon. No real game or config I/O.
local ffi = require("ffi")
local real_new, real_cast, real_load = ffi.new, ffi.cast, ffi.load
local fixture = assert(loadstring(FIXTURE_SOURCE))()
local ROOT = "V:/offline/local/CowboyBingus/Helldivers2/"
local CFG, INI = ROOT .. "HD2DualArmorPassive.cfg", ROOT .. "HD2DualArmorPassive.ini"
local ARMOR, GAME, ARENA, LIVE = 0x20000000, 0x180000000, 0x40000000, 0x40000080
if CASE == "address_high" then ARMOR = 0x19a6d780000 end
local source_mode = CASE == "address_relative" and "offset" or "pointer"
local PREFIX = "40534883ec204c8bd14c8bca488bcae8dc7c28ff"
local function hex(value)
    return (value:gsub("..", function(pair) return string.char(tonumber(pair, 16)) end))
end
local function equal(actual, expected, message)
    assert(actual == expected, CASE .. ": " .. (message or "value") .. ": expected "
        .. tostring(expected) .. ", got " .. tostring(actual))
end
local function pack(...) return {n = select("#", ...), ...} end
local function normalized(path) return path:gsub("\\", "/") end
local ctx = {
    time = 0, frame = 0, focused = true, allowed = true, cursor = false,
    pressed = {}, down = {}, files = {[CFG] = "0\n"}, blocks = {},
    reads = 0, table_reads = 0, writes = 0, validation_reads = 0, pointer_reads = 0, scans = 0,
    scan_allocations = 0, log_opens = 0, consumes = 0, replaces = 0,
    id_calls = {}, gui_entries = {}, next_gui_id = 0, destroyed = 0,
    protections = {}, native_order = {}, destroyed_worlds = {},
    owner_read_sizes = {},
    focus_queries = 0, physical_key_queries = 0,
}
local function block(address, size)
    local entry = {address = address, size = size, data = real_new("uint8_t[?]", size)}
    ctx.blocks[#ctx.blocks + 1] = entry
    ctx.protections[address] = 0x04
    return entry
end
local function lookup(address, size)
    for _, entry in ipairs(ctx.blocks) do
        if address >= entry.address and address + size <= entry.address + entry.size then
            return entry, address - entry.address
        end
    end
end
local function put(address, data)
    local entry, offset = lookup(address, #data)
    assert(entry, "fixture write outside an owned buffer")
    ffi.copy(entry.data + offset, data, #data)
end
local function put32(address, value)
    local word = real_new("uint32_t[1]", value)
    put(address, ffi.string(word, 4))
end
local function put64(address, value)
    local word = real_new("uint64_t[1]", value)
    put(address, ffi.string(word, 8))
end
local function get32(address)
    local entry, offset = lookup(address, 4)
    return tonumber(real_cast("uint32_t *", entry.data + offset)[0])
end
local function sparse(address, data)
    block(address, #data)
    put(address, data)
end
local function sparse64(address, value)
    block(address, 8)
    put64(address, value)
end
if CASE == "dynamic_add" then
    fixture.records[#fixture.records + 1] = {184, 0x12345689, 1}
elseif CASE == "dynamic_remove" then
    for i, record in ipairs(fixture.records) do if record[3] == 1 then table.remove(fixture.records, i); break end end
elseif CASE == "dynamic_reorder" then
    fixture.records[1], fixture.records[#fixture.records] = fixture.records[#fixture.records], fixture.records[1]
elseif CASE == "dynamic_growth" then fixture.records[1][1] = fixture.records[1][1] + 8 end
local function describe_source()
    fixture.size, fixture.fields = 4, {}
    for _, record in ipairs(fixture.records) do
        if record[3] == 1 then fixture.fields[#fixture.fields + 1] = {fixture.size + 52, record[2]} end
        fixture.size = fixture.size + 24 + record[1]
    end
end
describe_source()
block(ARMOR, fixture.size + 4096)
local function make_source()
put32(ARMOR, #fixture.records)
local record_offset = 4
for _, record in ipairs(fixture.records) do
    local size, kit, kind = unpack(record)
    local head, start = ARMOR + record_offset, ARMOR + record_offset + 24
    put(head, hex("4c444c4401000000a05aa5d9")); put32(head + 12, size); put32(head + 16, 1)
    put32(start, kit); put64(start + 32, 1); put32(start + 40, kind)
    put64(start + 48, source_mode == "pointer" and start + 64 or 64); put64(start + 56, 1)
    put64(start + 72, source_mode == "pointer" and start + 88 or 88); put64(start + 80, 1)
    put32(start + 96, kind == 1 and 0 or kind == 2 and 1 or 2)
    record_offset = record_offset + 24 + size
end
equal(record_offset, fixture.size, "synthetic source extent")
end
make_source()
block(GAME, 4096)
put(GAME, "MZ"); put32(GAME + 60, 0x100); put(GAME + 0x100, "PE\0\0")
put32(GAME + 0x104, 0x00018664); put32(GAME + 0x108, 0x6ab3b43f)
put32(GAME + 0x114, 240); put32(GAME + 0x118, 0x20b); put32(GAME + 0x150, 0x4744000)
put32(GAME + 0x210, 0x10000); put32(GAME + 0x214, 0x12fde90); put32(GAME + 0x22c, 0x60000000)
block(0x70000000, 808 + 13 * 97 * 32)
block(ARENA, (CASE == "scan_short" or CASE == "runtime_scan_changed" or CASE == "scan_boundary"
    or CASE == "scan_overlap" or CASE == "scan_last_record") and 0x200000 or 0x100000)
local function live_record(address, passive)
    put(address, hex("080000000000000002000000"))
    put64(address - 8, address - 0x48)
    put32(address - 0x60, 3)
    put32(address + 0x38, fixture.fields[1][2])
    put32(address + 0x148, fixture.fields[1][2])
    put32(address + 0x6c, passive or 0)
end
live_record(LIVE)
sparse64(GAME + 0x3326e68, ARENA + 0x20)
sparse64(GAME + 0x347cf18, 0x70000000)
sparse(GAME + 0x12fde90, hex(PREFIX) .. string.rep("\xcc", 108))
ctx.protections[GAME + 0x12fde90] = 0x20
sparse64(GAME + 0x347ce38, 0)
sparse64(GAME + 0x3772268, 0x12345678)
sparse64(GAME + 0x37c5478, 0x50000000)
sparse64(0x50000000 + 24, 0x23456789)
sparse64(GAME + 0x3772ee8, 0x34567890)

if CONFIG_OVERRIDE then ctx.files[INI] = CONFIG_OVERRIDE end
if CASE == "settings_valid" then ctx.files[INI] = "settings_version=1\nmenu_hotkey=F12\n" end
if CASE == "settings_invalid" then ctx.files[INI] = "settings_version=1\nmenu_hotkey=ctrl+f9\n" end
if CASE == "settings_version" then ctx.files[INI] = "settings_version=2\nmenu_hotkey=f10\n" end
if CASE == "settings_duplicate" then
    ctx.files[INI] = "settings_version=1\nmenu_hotkey=f10\nmenu_hotkey=f11\n"
end
if CASE == "settings_large" then ctx.files[INI] = string.rep(" ", 4097) end
if CASE == "settings_read_error" then ctx.files[INI] = "settings_version=1\nmenu_hotkey=f10\n" end
if CASE:find("^settings_save_") or CASE == "hotkey_reset" then
    ctx.files[INI] = "settings_version=1\nmenu_hotkey=f10\n"
end
if CASE == "startup_locate" or CASE:find("^dynamic_") or CASE:find("^address_") or (CASE:find("^compat_")
    and CASE ~= "compat_draw_failure" and CASE ~= "compat_live_api_loss") or CASE:find("^probe_") then
    ctx.files[CFG] = tostring(fixture.ids[2]) .. "\n"
end
if CASE == "ffi_aliases" then
    ffi.cdef("int GetCurrentProcess(void); typedef struct { int wrong; } HD2DualArmorMemRegion;")
end

local function fake_file(path, mode, kind)
    local content, position = ctx.files[path] or "", 1
    local file = {}
    function file:read(format)
        if kind == "settings" and CASE == "settings_read_error" then error("injected read error") end
        if format == "*l" then return content:match("^[^\r\n]*") end
        local value = content:sub(position, position + format - 1)
        position = position + #value
        return #value > 0 and value or nil
    end
    function file:lines()
        return content:gmatch("[^\r\n]+")
    end
    function file:write(...)
        if kind == "settings" and ctx.save_failure == "write" then return nil, "injected write failure" end
        if kind == "log" and ctx.log_failure == "write" then return nil, "injected log failure" end
        local parts = {...}
        for i = 1, #parts do parts[i] = tostring(parts[i]) end
        content = content .. table.concat(parts)
        ctx.files[path] = content
        return self
    end
    function file:close()
        if kind == "settings" and ctx.save_failure == "close" then return nil, "injected close failure" end
        if kind == "log" and ctx.log_failure == "close" then return nil, "injected log close failure" end
        if kind == "log" then ctx.last_log = content end
        return true
    end
    return file
end
os.getenv = function(name)
    if name == "LOCALAPPDATA" then return "V:/offline/local" end
    if name == "APPDATA" and (CASE == "zh_ui" or CASE == "font_fallback" or CASE:find("^compat_font_")
        or CASE:find("^language_")) then
        return "V:/offline/roaming"
    end
end
os.remove = function(path) ctx.files[normalized(path)] = nil; return true end
io.open = function(path, mode)
    path = normalized(path)
    local kind = path:find("%.ini") and "settings" or "passive"
    if path == INI and CASE == "settings_permission" then return nil, "permission denied", 13 end
    if mode:find("w") then
        if kind == "settings" and ctx.save_failure == "open" then return nil, "injected open failure" end
        ctx.files[path] = ""
    elseif ctx.files[path] == nil then return nil, "not found", 2 end
    return fake_file(path, mode, kind)
end
ctx.files["V:/offline/roaming/Arrowhead/Helldivers2/saves/offline_user_settings.config"] = 'language = "cn"\n'
local game_config = "V:/offline/roaming/Arrowhead/Helldivers2/saves/offline_user_settings.config"
if CASE:find("^language_") then ctx.files[game_config] = 'vo_language = "us"\nlanguage = "cn"\nplatform_language = "cn"\n' end
if CASE == "language_auto_tw" then ctx.files[game_config] = 'language = "tc"\nvo_language = "us"\n' end
if CASE == "language_auto_unknown" then ctx.files[game_config] = 'language = "jp"\nvo_language = "cn"\n' end
if CASE == "language_reload_en_game" or CASE == "language_auto_en" then
    ctx.files[game_config] = 'vo_language = "cn"\nlanguage = "us"\nplatform_language = "cn"\n'
end
local kernel = {}
function kernel.GetCurrentProcess() return real_cast("void *", -1) end
function kernel.GetCurrentProcessId() return 4242 end
function kernel.GetLastError() return 5 end
function kernel.GetModuleHandleA() return real_cast("void *", GAME) end
function kernel.GetTickCount64()
    if ctx.clock_failure then error("injected clock failure") end
    return math.floor(ctx.time)
end
function kernel.ReadProcessMemory(_, pointer, buffer, size, received)
    local address = tonumber(real_cast("uintptr_t", pointer))
    ctx.reads = ctx.reads + 1
    if address > ARMOR and address < ARMOR + fixture.size and (size == 4 or size == 44) then
        ctx.table_reads = ctx.table_reads + 1
    end
    if address == GAME + 0x347cf18 then ctx.owner_read_sizes[#ctx.owner_read_sizes + 1] = size end
    if size == 44 then ctx.validation_reads = ctx.validation_reads + 1 end
    if size == 8 then ctx.pointer_reads = ctx.pointer_reads + 1 end
    if size > 64 and address >= ARENA and address < ARENA + 0x10000000 then ctx.scans = ctx.scans + 1 end
    if ctx.invalidate_during_scan and address == ARENA + 0x100000 and size > 64 then
        ctx.invalidate_during_scan = nil
        put32(LIVE + 0x38, 99)
        put32(LIVE + 0x148, 99)
    end
    if ctx.invalidate_before_write and address == LIVE + 0x6c and size == 4 then
        ctx.runtime_value_reads = (ctx.runtime_value_reads or 0) + 1
        if ctx.runtime_value_reads == 2 then
            ctx.invalidate_before_write = nil
            put32(LIVE + 0x38, 99)
            put32(LIVE + 0x148, 99)
        end
    end
    local failure = ctx.read_failure
    if failure and failure.address == address and (not failure.size or failure.size == size) then
        if not failure.repeated then ctx.read_failure = nil end
        received[0] = size - 1
        return 1
    end
    local copied = 0
    while copied < size do
        local entry, offset = lookup(address + copied, 1)
        if not entry then received[0] = copied; return 0 end
        local amount = math.min(size - copied, entry.size - offset)
        ffi.copy(real_cast("uint8_t *", buffer) + copied, entry.data + offset, amount)
        copied = copied + amount
    end
    received[0] = size
    return 1
end
function kernel.WriteProcessMemory(_, pointer, buffer, size, written)
    local address = tonumber(real_cast("uintptr_t", pointer))
    local entry, offset = lookup(address, size)
    assert(entry, "production attempted to write outside an owned fixture")
    ctx.writes = ctx.writes + 1
    if ctx.runtime_write_failure and address == LIVE + 0x6c then
        ctx.runtime_write_failure = nil
        written[0] = 0
        return 0
    end
    ffi.copy(entry.data + offset, buffer, size)
    written[0] = size
    if ctx.readback_failure == address then
        ctx.readback_failure = nil
        ctx.read_failure = {address = address, size = size}
    end
    return 1
end
function kernel.VirtualQuery(pointer, region, size)
    local address = tonumber(real_cast("uintptr_t", pointer))
    local entry = lookup(address, 1)
    local base, length, protection, state, kind
    if entry then
        base, length, protection = entry.address, entry.size, ctx.protections[entry.address]
        state, kind = 0x1000, 0x20000
    elseif address < ARMOR then
        base, length, protection, state, kind = 0x10000, ARMOR - 0x10000, 1, 0x10000, 0
    else
        local next_block = 0x800000000000
        for _, candidate in ipairs(ctx.blocks) do
            if candidate.address > address then next_block = math.min(next_block, candidate.address) end
        end
        base, length, protection, state, kind = address, next_block - address, 1, 0x10000, 0
    end
    if ctx.unsafe_page and base == ARMOR then protection = 0x20 end
    region[0].base = real_cast("void *", base)
    region[0].allocation_base = real_cast("void *", base)
    region[0].size, region[0].state = length, state
    region[0].protection, region[0].type = protection, kind
    return size
end
function kernel.VirtualProtect(pointer, _, protection, previous)
    local address = tonumber(real_cast("uintptr_t", pointer))
    local entry = assert(lookup(address, 1))
    ctx.protect_calls = (ctx.protect_calls or 0) + 1
    if ctx.protect_restore_failure and protection == 0x02 then
        ctx.protect_restore_failure = nil
        return 0
    end
    previous[0] = ctx.protections[entry.address]
    ctx.protections[entry.address] = protection
    return 1
end
function kernel.MoveFileExA(existing, replacement, flags)
    equal(flags, 9, "atomic replacement flags")
    existing, replacement = normalized(existing), normalized(replacement)
    ctx.replaces = ctx.replaces + 1
    if (replacement == INI and ctx.save_failure == "replace")
        or (replacement == CFG and ctx.passive_save_failure) then return 0 end
    assert(ctx.files[existing], "replacement source was not written")
    ctx.files[replacement], ctx.files[existing] = ctx.files[existing], nil
    return 1
end
function kernel.FindFirstFileA(_, data)
    ffi.copy(data[0].name, "offline_user_settings.config")
    return real_cast("void *", 1)
end
function kernel.FindClose() return 1 end
local user = {}
function user.GetForegroundWindow()
    ctx.focus_queries = ctx.focus_queries + 1
    if ctx.focus_failure then error("injected input failure") end
    return real_cast("void *", 1)
end
function user.GetWindowThreadProcessId(_, pid) pid[0] = ctx.focused and 4242 or 9; return 1 end
function user.GetAsyncKeyState(code)
    ctx.physical_key_queries = ctx.physical_key_queries + 1
    if ctx.down_failure then error("injected input failure") end
    return ctx.down[code] and -32768 or 0
end
ffi.load = function(name)
    if name == "gdi32" then return real_load(name) end
    if name == "ucrtbase" then
        ctx.crt_loads = (ctx.crt_loads or 0) + 1
        if CASE == "scan_library_missing" then error("injected UCRT unavailable") end
        if CASE == "scan_symbol_missing" then return setmetatable({}, {__index = function() error("injected symbol missing") end}) end
        local library = real_load(name)
        if CASE == "scan_native_error" then
            return {hd2dap_search_v1_memchr = function() error("injected native search error") end,
                hd2dap_search_v1_memcmp = library.hd2dap_search_v1_memcmp}
        end
        return library
    end
    local library = name == "kernel32" and kernel or name == "user32" and user
    assert(library, "unexpected production DLL load: " .. tostring(name))
    return setmetatable({}, {__index = function(_, symbol)
        local original = symbol:match("^hd2dap_v1_(.+)$")
        if not original and CASE:find("^measure_") then original = symbol end
        assert(original and library[original], "unexpected production native entry: " .. tostring(symbol))
        return library[original]
    end})
end
ffi.new = function(kind, ...)
    if kind == "uint8_t[?]" and select(1, ...) == 0x100200 then
        ctx.scan_allocations = ctx.scan_allocations + 1
    end
    return real_new(kind, ...)
end
ffi.cast = function(kind, value)
    if kind == "void (*)(void *, uint64_t, float)" then
        equal(value, ctx.native_entry or GAME + 0x12fde90, "native input entry")
        return function(_, action, duration)
            local code = tonumber(action)
            local names = {[0xA00000000] = "select", [0x900000000] = "back", [0x4900000000] = "game_menu"}
            assert(names[code], "native menu action")
            equal(duration, -1, "native action duration")
            ctx.consumes = ctx.consumes + 1
            ctx.native_order[#ctx.native_order + 1] = names[code]
            if ctx.consume_failure == names[code] then error("native action consumer failed") end
        end
    end
    return real_cast(kind, value)
end

local world1, world2, world3 = {}, {}, {}
local world_list = {world1, world2, world3}
local font_atlases = {
    fbb35bee675f2295 = "f14daed0a7d38271", e01b1c60bb279a7c = "1a87fa21dafbd90e",
    ["3da89f2c15b53d65"] = "86667f650dca00f9", ["7c63fea1f706eec4"] = "3454c1d97f395663",
}
local font_packages = {
    ["fbb35bee675f2295"] = "09caa46bc556e38f", ["e01b1c60bb279a7c"] = "09caa46bc556e38f",
    ["3da89f2c15b53d65"] = "c0b7644cc5c4aaa8", ["7c63fea1f706eec4"] = "c0b7644cc5c4aaa8",
}
local font_materials = {
    ["fbb35bee675f2295"] = "b0496b27039825bd", ["e01b1c60bb279a7c"] = "b0496b27039825bd",
    ["3da89f2c15b53d65"] = "702bd6ee6303dcca", ["7c63fea1f706eec4"] = "702bd6ee6303dcca",
}
local codes = {escape = 27, enter = 13, left = 37, up = 38, right = 39, down = 40}
for number = 1, 12 do codes["f" .. number] = 111 + number end
local function id(device, name)
    local label = device .. ":" .. name
    ctx.id_calls[label] = (ctx.id_calls[label] or 0) + 1
    return device == "keyboard" and codes[name] or 1
end
local function gui_entry(kind, instance, ...)
    ctx.next_gui_id = ctx.next_gui_id + 1
    ctx.gui_entries[ctx.next_gui_id] = {kind = kind, instance = instance, args = {...}}
    return ctx.next_gui_id
end
local vector3 = setmetatable({x = function(p) return p.x end, y = function(p) return p.y end},
    {__call = function(_, x, y, z) return {x = x, y = y, z = z} end})
s3d = {
    Vector3 = vector3,
    Vector2 = setmetatable({}, {__call = function(_, x, y) return {x = x, y = y} end}),
    Color = setmetatable({}, {__call = function(_, ...) return {...} end}),
    IdString64 = {from_hex = function(hash) return {hash = hash, frame = ctx.frame} end},
    Application = {
        worlds = function() if not ctx.worlds_missing then return ctx.worlds_override or world_list end end,
        main_world = function() return world1 end,
        can_get = function(kind, resource)
            if type(resource) == "table" then
                equal(resource.frame, ctx.frame, "font resource ID lifetime")
                if ctx.packages and kind ~= "package" then
                    local package = font_packages[resource.hash]
                    if not package and kind == "material" then
                        package = resource.hash == "b0496b27039825bd" and "09caa46bc556e38f"
                            or resource.hash == "702bd6ee6303dcca" and "c0b7644cc5c4aaa8" or nil
                    end
                    if package then return ctx.packages[package] and ctx.packages[package].available == true end
                end
                if ctx.font_failure == "resources" then return false end
                if ctx.font_failure == "primary" and resource.hash == "fbb35bee675f2295" then return false end
                if ctx.font_failure == "primary_atlas" and resource.hash == "f14daed0a7d38271" then return false end
                if ctx.font_failure == "atlas" and kind == "texture" then return false end
            end
            return ctx.font_failure ~= "all"
        end,
    },
    World = {
        units_by_resource = function(world, resource)
            equal(resource.frame, ctx.frame, "resource ID lifetime")
            return ctx.allowed and world == world2 and {1} or {}
        end,
        create_screen_gui = function(world) return {world = world} end,
        destroy_gui = function(world)
            ctx.destroyed = ctx.destroyed + 1
            ctx.destroyed_worlds[#ctx.destroyed_worlds + 1] = world
        end,
    },
    Window = {
        show_cursor = function() return ctx.cursor end,
        set_show_cursor = function(value) ctx.cursor = value end,
    },
    Gui = {
        resolution = function() return 1280, 720 end,
        set_visible = function() end,
        rect = function(...) return gui_entry("rect", ...) end,
        text = function(instance, text, font, size, material, ...)
            if type(font) == "table" then
                equal(font.frame, ctx.frame, "draw font ID lifetime")
                equal(material.frame, ctx.frame, "draw material ID lifetime")
                equal(material.hash, assert(font_materials[font.hash]), "localized font material")
                local ink = assert(instance.font_material, "GUI-local font material")
                equal(ink.atlas, assert(font_atlases[font.hash], "known static font"), "font/atlas pairing")
                for _, hash in ipairs({"8035c266", "5e8455fe", "309e7783", "82b803a8", "a8ea55ba"}) do
                    equal(ink[hash .. "00000000"], 0, "font material scalar")
                end
                equal(ink.e13777ce00000000.x, 1); equal(ink.e13777ce00000000.y, -1)
                for i = 1, 4 do equal(ink["7701209e00000000"][i], 0, "font material vector") end
            end
            return gui_entry("text", instance, text, font, size, material, ...)
        end,
        destroy_rect = function(_, handle) ctx.gui_entries[handle] = nil end,
        destroy_text = function(_, handle) ctx.gui_entries[handle] = nil end,
        material = function(instance, resource)
            equal(resource.frame, ctx.frame, "material ID lifetime")
            ctx.material_calls = (ctx.material_calls or 0) + 1
            if ctx.font_failure == "material" or (ctx.font_failure == "second_layer" and instance.world == world1) then
                error("injected Chinese material failure")
            end
            instance.font_material = instance.font_material or {}
            return instance.font_material
        end,
    },
    Material = {
        set_scalar = function(ink, slot, value)
            equal(slot.frame, ctx.frame, "material scalar slot lifetime"); ink[slot.hash] = value
        end,
        set_vector2 = function(ink, slot, value)
            equal(slot.frame, ctx.frame, "material vector2 slot lifetime"); ink[slot.hash] = value
        end,
        set_vector4 = function(ink, slot, value)
            equal(slot.frame, ctx.frame, "material vector4 slot lifetime"); ink[slot.hash] = value
        end,
        set_texture = function(ink, slot, texture)
            equal(slot.frame, ctx.frame, "material texture slot lifetime")
            equal(texture.frame, ctx.frame, "atlas ID lifetime")
            equal(slot.hash, "88bac99b00000000", "font atlas slot")
            if ctx.font_failure == "setter" then error("injected atlas binding failure") end
            ink.atlas = texture.hash
        end,
    },
    Keyboard = {button_id = function(name) return id("keyboard", name) end,
        pressed = function(code) return ctx.pressed[code] == true end},
    Mouse = {
        button_id = function(name) return id("mouse", name) end,
        axis_id = function(name) return id("axis", name) end,
        pressed = function() return ctx.mouse_pressed == true end,
        axis = function() return ctx.mouse_point end,
    },
}
CowboyBingusModLoader = {
    api = 1,
    open_log = function()
        ctx.log_opens = ctx.log_opens + 1
        if ctx.log_failure == "open" then return nil end
        ctx.files["log"] = ""
        return fake_file("log", "wb", "log")
    end,
}
if CASE == "loader_v19" then
    CowboyBingusModLoader.revision = "loader-v19"
    CowboyBingusModLoader.version = 17
    CowboyBingusModLoader.jit = {managed = false}
    CowboyBingusModLoader.capabilities = setmetatable({}, {
        __index = {api = true, logs = true, discovery = true, jit_budget = true,
            health = true, after_startup = true},
        __newindex = function() error("readonly capabilities") end,
    })
    CowboyBingusModLoader.after_startup = function() error("unneeded startup registration") end
end
update = function(...)
    ctx.prior_args = pack(...)
    ctx.native_order[#ctx.native_order + 1] = "prior"
    if ctx.prior_failure then error("injected prior failure") end
    return "prior-result", nil, 99, nil
end
shutdown = function(...) ctx.shutdown_args = pack(...); return "shutdown-result", nil, 8, nil end
if CASE:find("^language_package_") then
    ctx.packages, ctx.package_loads, ctx.package_flushes = {}, 0, 0
    ctx.package_unloads, ctx.package_releases = 0, 0
    ctx.package_failure = CASE:match("^language_package_failure_(.+)")
    local function checked(operation, entry)
        if ctx.package_failure == operation then error("injected package " .. operation .. " failure") end
        assert(entry and not entry.released, "live resource package handle")
    end
    s3d.Application.resource_package = function(resource)
        equal(resource.frame, ctx.frame, "package resource ID lifetime")
        if ctx.package_failure == "create" then error("injected package create failure") end
        assert(not ctx.packages[resource.hash] or ctx.packages[resource.hash].released)
        local entry = {hash = resource.hash}
        ctx.packages[resource.hash] = entry
        return entry
    end
    s3d.Application.release_resource_package = function(entry)
        checked("release", entry); assert(entry.unloaded, "unload before release")
        entry.released = true; ctx.package_releases = ctx.package_releases + 1
    end
    s3d.ResourcePackage = {
        load = function(entry)
            ctx.package_loads = ctx.package_loads + 1; entry.started = true; checked("load", entry)
        end,
        has_loaded = function(entry) checked("poll", entry); return ctx.package_ready == true end,
        flush = function(entry)
            checked("flush", entry); assert(ctx.package_ready, "never block flushing an incomplete load")
            assert(not entry.available, "flush only once"); entry.available = true
            ctx.package_flushes = ctx.package_flushes + 1
        end,
        unload = function(entry)
            checked("unload", entry)
            for _, drawn in pairs(ctx.gui_entries) do
                if drawn.kind == "text" and type(drawn.args[2]) == "table" then
                    assert(font_packages[drawn.args[2].hash] ~= entry.hash, "GUI font users released first")
                end
            end
            entry.unloaded, entry.available = true, false
            ctx.package_unloads = ctx.package_unloads + 1
        end,
    }
    if CASE == "language_package_missing_api" then s3d.ResourcePackage.flush = nil end
    if CASE == "language_package_missing_create_api" then s3d.Application.resource_package = nil end
    if CASE == "language_package_missing_release_api" then s3d.Application.release_resource_package = nil end
end
if CASE == "compat_unknown_stamp" then put32(GAME + 0x108, 0x12345678) end
if CASE == "compat_pe_magic" then put(GAME, "XX") end
if CASE == "compat_pe_offset" then put32(GAME + 60, 0x100000) end
if CASE == "compat_pe_machine" then put32(GAME + 0x104, 0x0001014c) end
if CASE == "compat_pe_optional" then put32(GAME + 0x114, 32) end
if CASE == "compat_pe_size" then put32(GAME + 0x150, 0x20000) end
if CASE == "compat_pe_short" then ctx.read_failure = {address = GAME, size = 64, repeated = true} end
if CASE == "compat_api_missing" then s3d.Gui.text = nil end
if CASE == "compat_api_noncallable" then s3d.Gui.text = true end
if CASE == "compat_font_resource" then s3d.Application.can_get = function() return false end end
if CASE == "compat_font_material" then s3d.Gui.material = nil end
if CASE == "compat_font_pointer" then put64(GAME + 0x37c5478, 0) end
if CASE == "compat_input_retry" then
    put(GAME + 0x12fde90, string.rep("\xcc", 20))
    ctx.read_failure = {address = GAME + 0x12fde90, size = 128, repeated = true}
end
if CASE == "compat_owner_short" then ctx.blocks[3].size = 8 end
if CASE == "compat_owner_absent" then put64(GAME + 0x347cf18, 0) end
if CASE == "compat_input_move" or CASE == "compat_input_multiple" or CASE == "compat_input_absent"
    or CASE == "compat_input_boundary" then
    put(GAME + 0x12fde90, string.rep("\xcc", 20))
    if CASE ~= "compat_input_absent" then
        ctx.native_entry = GAME + 0x12fee90
        if CASE == "compat_input_boundary" then
            sparse(ctx.native_entry, hex(PREFIX):sub(1, 10)); ctx.protections[ctx.native_entry] = 0x20
            sparse(ctx.native_entry + 10, hex(PREFIX):sub(11)); ctx.protections[ctx.native_entry + 10] = 0x40
        else sparse(ctx.native_entry, hex(PREFIX)); ctx.protections[ctx.native_entry] = 0x20 end
    end
    if CASE == "compat_input_multiple" then
        sparse(GAME + 0x12ffe90, hex(PREFIX)); ctx.protections[GAME + 0x12ffe90] = 0x20
    end
end
if CASE:find("^compat_source_") then
    local first, start = ARMOR + 4, ARMOR + 28
    local damage = CASE:match("^compat_source_(.+)")
    if damage == "version" then put32(first + 4, 2)
    elseif damage == "flags" then put32(first + 16, 0)
    elseif damage == "size" then put32(first + 12, 0xfffffff8)
    elseif damage == "count" then put32(ARMOR, 8193)
    elseif damage == "body" then put64(start + 48, 0xfffffff0)
    elseif damage == "pieces" then put64(start + 72, 0xfffffff0)
    elseif damage == "slot" then put32(start + 96, 42)
    elseif damage == "duplicate" then put32(ARMOR + fixture.fields[1][1] - 28, fixture.records[1][2])
    elseif damage == "short" then ctx.read_failure = {address = ARMOR, size = fixture.size}
    else error("unknown parser damage") end
end
if CASE:find("^address_") then
    local start = ARMOR + 28
    if CASE == "address_mixed" then put64(start + 72, 88)
    elseif CASE == "address_outside" then put64(start + 48, ARMOR + fixture.size + 1024)
    elseif CASE == "address_cross_record" then put64(start + 72, ARMOR + 2588 + 88)
    elseif CASE == "address_overflow" then put64(start + 48, 0x800000000000)
    elseif CASE == "address_unaligned" then put64(start + 48, start + 65)
    elseif CASE == "address_invalid_count" then put64(start + 56, 0x100000001) end
end
-- @SYSTEM_FONT_MOCK@
local observed_labels = {}
HD2DAP_TEST_LABEL = function(text) observed_labels[#observed_labels + 1] = text end
HD2DAP_TEST_REDRAW = function() observed_labels = {} end
MOD_SOURCE = MOD_SOURCE:gsub("local function draw_text%(text, x, y, size, r, g, b%)\n",
    "local function draw_text(text, x, y, size, r, g, b)\n    HD2DAP_TEST_LABEL(text)\n", 1)
MOD_SOURCE = MOD_SOURCE:gsub("local function redraw%(%)\n",
    "local function redraw()\n    HD2DAP_TEST_REDRAW()\n", 1)
assert(loadstring(MOD_SOURCE, "@expanded/mod.lua"))()
local M = HD2DualArmorPassive or HD2DualArmorCompatibilityProbe
if CASE ~= "startup_locate" and not CASE:find("^probe_") and not CASE:find("^dynamic_")
    and not CASE:find("^compat_source_") and not CASE:find("^address_") then M.base = ARMOR end
if not CASE:find("^probe_") then M.runtime_header = LIVE end
local function step(keys, milliseconds, held)
    ctx.pressed, ctx.down = {}, {}
    for _, name in ipairs(keys or {}) do ctx.pressed[assert(codes[name])] = true end
    for _, name in ipairs(held or keys or {}) do ctx.down[assert(codes[name])] = true end
    ctx.time, ctx.frame = ctx.time + (milliseconds or 16), ctx.frame + 1
    local results = pack(update("sentinel", nil, 7, nil))
    if CASE ~= "callback_prior_error" and CASE ~= "callback_module_error" and CASE ~= "gui_failed_cleanup"
        and CASE ~= "compat_draw_failure" then
        assert(not M.failed, CASE .. ": unexpected module failure: " .. tostring(M.phase))
    end
    return results
end
local function tap(name) step({name}); step({}) end
local function open_menu()
    tap(M.hotkey)
    equal(M.visible, true, "menu opened")
    equal(ctx.cursor, true, "menu cursor")
end
local click_positions = {
    hotkey = {305, 470}, reset = {487, 470}, close = {532, 25},
    apply = {400, 25}, select_second = {35, 350},
    simplified = {180, 552}, traditional = {338, 552}, english = {504, 552},
    prev = {35, 25}, next = {155, 25},
}
local function click(name, held)
    local position = assert(click_positions[name])
    ctx.mouse_point = {x = M.box[1] + position[1], y = M.box[2] + position[2]}
    ctx.mouse_pressed = true
    step({}, 16, held)
    ctx.mouse_pressed = false
    step({}, 16, held)
end
local function choose_extra()
    open_menu()
    tap("down")
end
local function assert_source(value)
    for index, entry in ipairs(fixture.fields) do
        equal(get32(ARMOR + entry[1]), value, "source field " .. index)
        equal(get32(ARMOR + entry[1] - 28), entry[2], "kit identity preserved")
        equal(get32(ARMOR + entry[1] + 12), 1, "type preserved")
    end
end
local function active()
    M.selected, M.applied, M.phase = fixture.ids[2], fixture.ids[2], "active"
    for _, entry in ipairs(fixture.fields) do put32(ARMOR + entry[1], M.selected) end
    put32(LIVE + 0x6c, M.selected)
end
local function assert_no_temporaries()
    for path in pairs(ctx.files) do assert(not path:find("%.tmp%."), "temporary config leaked") end
end
local function has_text(text)
    if M.visible then
        for _, label in ipairs(observed_labels) do
            if label:find(text, 1, true) then return true end
        end
    end
    for _, entry in pairs(ctx.gui_entries) do
        if entry.kind == "text" and entry.args[1]:find(text, 1, true) then return true end
    end
    return false
end

local function gui_count()
    local count = 0
    for _, entry in pairs(ctx.gui_entries) do
        if entry.kind ~= "bitmap" then count = count + 1 end
    end
    return count
end

if CASE == "address_relative" or CASE == "address_high" or CASE == "address_mode_change" then
    for _ = 1, 120 do step({}) end
    equal(M.base, ARMOR); equal(M.applied, fixture.ids[2]); assert_source(M.selected)
    assert(M.compatibility.source:find(source_mode .. " arrays checked", 1, true))
    if CASE == "address_mode_change" then
        local before = ctx.writes
        for _, field in ipairs(fixture.fields) do put32(ARMOR + field[1], 0) end
        source_mode = "offset"; make_source()
        step({}, 1001)
        equal(ctx.writes, before, "encoding change refused before writes")
        assert_source(0); assert(M.phase:find("layout changed before write", 1, true))
    end
elseif CASE:find("^address_") then
    for _ = 1, 123 do step({}) end
    equal(M.base, nil); equal(ctx.writes, 0); equal(ctx.replaces, 0)
    assert(M.compatibility.source and not M.compatibility.source:find("DL1 checked", 1, true))
elseif CASE:find("^probe_") then
    local cfg, ini = ctx.files[CFG], ctx.files[INI]
    for _ = 1, 180 do step({"f9"}) end
    assert(HD2DualArmorPassive == nil, "probe uses a separate global entry")
    equal(M.base, ARMOR); equal(M.helmet_count, #fixture.fields)
    equal(M.runtime_header, LIVE); equal(M.visible, false); equal(ctx.cursor, false)
    equal(ctx.writes, 0); equal(ctx.replaces, 0); equal(ctx.consumes, 0)
    equal(gui_count(), 0); equal(ctx.destroyed, 0)
    equal(ctx.files[CFG], cfg); equal(ctx.files[INI], ini); assert_source(0)
    local result = pack(shutdown("probe-exit")); equal(result[1], "shutdown-result")
    equal(ctx.writes, 0); equal(ctx.replaces, 0)
    assert(ctx.last_log:find("read-only compatibility probe", 1, true))
elseif CASE:find("^dynamic_") then
    for _ = 1, 120 do step({}) end
    equal(M.base, ARMOR); equal(M.record_count, #fixture.records); equal(M.helmet_count, #fixture.fields)
    equal(M.applied, fixture.ids[2]); assert_source(M.selected); equal(get32(LIVE + 0x6c), M.selected)
    if CASE == "dynamic_rebind" then
        fixture.records[#fixture.records + 1] = {184, 0x12345689, 1}
        describe_source()
        ffi.fill(assert(lookup(ARMOR, fixture.size)).data, fixture.size, 0)
        make_source()
        put(LIVE, string.rep("\0", 12)); live_record(ARENA + 0x2080)
        step({}, 1001); equal(M.base, nil, "old source mapping invalidated")
        for _ = 1, 9 do step({}) end
        equal(M.base, ARMOR); equal(M.helmet_count, #fixture.fields); equal(M.record_count, #fixture.records)
        assert_source(M.selected); equal(M.runtime_header, ARENA + 0x2080, "old runtime cache replaced")
        equal(get32(M.runtime_header + 0x6c), M.selected)
    end
    equal(ctx.replaces, 0, "startup restoration never resaves config")
elseif CASE:find("^compat_source_") then
    for _ = 1, 123 do step({}) end
    equal(M.base, nil); equal(ctx.writes, 0); equal(ctx.replaces, 0)
    assert(M.compatibility.source and not M.compatibility.source:find("DL1 checked", 1, true))
elseif CASE:find("^compat_pe_") or CASE == "compat_api_missing" or CASE == "compat_api_noncallable" then
    for _ = 1, 3 do step({"f9"}) end
    equal(M.visible, false); equal(ctx.writes, 0); equal(ctx.consumes, 0); equal(ctx.replaces, 0)
    assert(M.compatibility.module or M.compatibility.interfaces)
elseif CASE == "compat_unknown_stamp" or CASE == "compat_input_move" or CASE == "compat_input_boundary" then
    choose_extra(); tap("enter"); equal(M.applied, fixture.ids[2]); assert_source(M.applied)
    if CASE == "compat_unknown_stamp" then assert(M.compatibility.module:find("12345678", 1, true))
    else assert(M.compatibility.input_entry:find("12fee90", 1, true)) end
elseif CASE == "compat_input_absent" or CASE == "compat_input_multiple" or CASE == "compat_owner_absent" or CASE == "compat_owner_short" then
    for _ = 1, 3 do step({"f9"}) end
    equal(ctx.writes, 0); equal(ctx.consumes, 0); equal(ctx.replaces, 0); equal(M.visible, false)
elseif CASE == "compat_input_retry" then
    for _ = 1, 6 do step({"f9"}, 1001); step({}) end
    equal(ctx.writes, 0); equal(ctx.consumes, 0); equal(ctx.replaces, 0); equal(M.visible, false)
    assert(M.compatibility.input_entry:find("retry limit", 1, true))
elseif CASE:find("^compat_font_") then
    for _ = 1, 180 do step({}) end
    equal(ctx.replaces, 0)
    if CASE == "compat_font_resource" then
        equal(ctx.writes, 0); assert_source(0)
        assert(M.compatibility.font:find("menu fonts unavailable", 1, true))
    else
        assert_source(fixture.ids[2]); equal(M.applied, fixture.ids[2])
        if CASE == "compat_font_material" then assert(M.compatibility.font:find("English fallback", 1, true)) end
        if CASE == "compat_font_pointer" then
            open_menu()
            assert(M.compatibility.font:find("system font ", 1, true), "installed font ignores runtime font pointer")
        end
    end
elseif CASE == "compat_live_input_loss" then
    choose_extra(); tap("enter"); tap("escape")
    equal(M.applied, fixture.ids[2]); equal(M.visible, false)
    local before = ctx.writes
    put32(LIVE + 0x6c, 0); put(GAME + 0x12fde90, string.rep("\xcc", 20))
    step({}, 1001)
    equal(ctx.writes, before, "runtime maintenance refuses a lost input dependency")
    equal(get32(LIVE + 0x6c), 0); assert(M.runtime_status:find("compatibility", 1, true))
elseif CASE == "compat_draw_failure" or CASE == "compat_live_api_loss" then
    if CASE == "compat_draw_failure" then s3d.Gui.bitmap_uv = function() return nil end; tap("f9")
    else open_menu(); s3d.Gui.text = nil; step({}) end
    equal(M.visible, false); equal(ctx.cursor, false); equal(gui_count(), 0)
    equal(ctx.writes, 0); equal(ctx.replaces, 0)
elseif CASE == "scan_library_missing" or CASE == "scan_symbol_missing" or CASE == "scan_native_error" then
    choose_extra(); M.runtime_header = nil; tap("enter")
    if CASE == "scan_native_error" then
        equal(M.selected, 0); assert_source(0); equal(ctx.files[CFG], "0\n")
        assert(M.runtime_status:find("lookup error", 1, true)); assert(not M.failed)
    else
        equal(M.selected, fixture.ids[2]); assert_source(M.selected)
        assert(M.search_status:find("string fallback", 1, true)); equal(ctx.crt_loads, 1)
        M.runtime_header = nil; tap("enter"); equal(ctx.crt_loads, 1)
    end
elseif CASE == "scan_boundary" or CASE == "scan_overlap" or CASE == "scan_last_record" then
    choose_extra(); M.runtime_header = nil; put(LIVE, string.rep("\0", 12))
    local offset = CASE == "scan_boundary" and 0xffffc or CASE == "scan_overlap" and 0x100080 or 0x1ffea0
    live_record(ARENA + offset); tap("enter")
    equal(M.selected, fixture.ids[2]); equal(M.runtime_header, ARENA + offset)
    assert_source(M.selected); equal(get32(ARENA + offset + 0x6c), M.selected)
    equal(ctx.scans, 2, "complete scan owns overlap once")
elseif CASE:find("^settings_") and not CASE:find("^settings_save_") then
    local expected = "f9"
    if CASE == "settings_valid" then expected = "f12" end
    if CASE == "settings_override" then expected = CONFIG_OVERRIDE:match("menu_hotkey=([^\n]+)"):match("^%s*(.-)%s*$"):lower() end
    equal(M.hotkey, expected, "loaded hotkey")
    equal(ctx.replaces, 0, "no startup settings write")
    equal(M.selected, 0, "old passive config")
    if CASE == "settings_missing" then
        equal(ctx.files[INI], nil, "missing config remains absent")
        equal(M.hotkey_config_error, nil, "missing config uses default quietly")
    elseif CASE ~= "settings_valid" and CASE ~= "settings_override" then
        assert(M.hotkey_config_error, "invalid/unreadable settings need diagnostic")
    end
elseif CASE == "capture_save" then
    open_menu(); click("hotkey"); tap("f1")
    equal(M.hotkey, "f1", "captured key")
    equal(M.visible, true, "new key does not close while captured")
    equal(ctx.files[CFG], "0\n", "passive config untouched")
    equal(ctx.writes, 0, "capture does not apply passive")
    tap("f9"); equal(M.visible, true, "old key disabled")
    tap("f1"); equal(M.visible, false, "new key closes")
    tap("f1"); equal(M.visible, true, "new key reopens")
    assert_no_temporaries()
elseif CASE == "capture_wait" then
    open_menu(); click("hotkey", {"f9"}); step({"f10"}, 16, {"f9", "f10"})
    equal(ctx.replaces, 0, "held original key not captured")
    step({}); tap("f10"); equal(M.hotkey, "f10")
elseif CASE == "capture_cancel" then
    open_menu(); click("hotkey"); tap("escape")
    equal(M.visible, true, "capture Escape keeps menu")
    equal(ctx.replaces, 0); equal(M.hotkey, "f9")
    tap("escape"); equal(M.visible, false, "normal Escape closes")
elseif CASE == "capture_multiple" then
    open_menu(); click("hotkey"); step({"f1", "f2"})
    equal(ctx.replaces, 0); equal(M.hotkey, "f9")
    step({}); tap("f12"); equal(M.hotkey, "f12")
elseif CASE == "capture_close" then
    open_menu(); click("hotkey"); click("close")
    equal(M.visible, false); equal(ctx.replaces, 0)
    tap("f1"); equal(M.hotkey, "f9"); equal(M.visible, false)
elseif CASE == "capture_focus" then
    open_menu(); click("hotkey"); ctx.focused = false; step({"f1"})
    equal(ctx.replaces, 0); equal(M.hotkey, "f9")
    local before = ctx.log_opens
    for _ = 1, 50 do step({}) end
    equal(ctx.log_opens, before, "unfocused cancellation is logged once")
    ctx.focused = true; step({}); tap("f1"); equal(ctx.replaces, 0)
elseif CASE == "capture_scene" then
    open_menu(); click("hotkey"); ctx.allowed = false; step({"f1"})
    equal(ctx.replaces, 0, "scene invalidated before capturing same-frame key")
    for _ = 1, 5 do step({}) end
    equal(M.visible, false)
elseif CASE == "capture_blocks_apply" then
    open_menu(); click("hotkey"); tap("enter"); click("apply"); click("select_second")
    equal(ctx.writes, 0); equal(M.selected, 0); equal(ctx.replaces, 0)
    tap("f9"); equal(M.visible, true, "capturing current key keeps menu")
elseif CASE == "hotkey_hold" then
    step({"f9"}); equal(M.visible, true)
    for _ = 1, 20 do step({"f9"}) end
    equal(M.visible, true, "held key does not repeat")
    step({}); step({"f9"}); equal(M.visible, false)
elseif CASE == "hotkey_reset" then
    open_menu(); click("reset"); equal(M.hotkey, "f9")
    equal(ctx.files[INI], "settings_version=1\nmenu_hotkey=f9\n")
    tap("f10"); equal(M.visible, true)
    tap("f9"); equal(M.visible, false)
elseif CASE == "scene_gate" then
    ctx.allowed = false; tap("f9"); equal(M.visible, false)
    equal(ctx.writes, 0); equal(ctx.replaces, 0)
elseif CASE:find("^scene_grace_") then
    choose_extra()
    if CASE == "scene_grace_reset" then
        click("hotkey"); tap("f10")
    end
    local original_ini, original_key, original_status = ctx.files[INI], M.hotkey, M.hotkey_status
    local before_replaces = ctx.replaces
    ctx.allowed = false
    if CASE == "scene_grace_enter" then tap("enter")
    elseif CASE == "scene_grace_mouse" then click("apply")
    elseif CASE == "scene_grace_reset" then click("reset")
    elseif CASE == "scene_grace_capture" then click("hotkey")
    elseif CASE == "scene_grace_navigation" then
        step({"down", "right"})
        assert(has_text("Page 1 / 4"), "disallowed scene must not change page")
    elseif CASE == "scene_grace_close" then click("close")
    elseif CASE == "scene_grace_escape" then tap("escape")
    elseif CASE == "scene_grace_recovery" then tap("enter")
    else error("unknown scene grace case") end
    equal(ctx.writes, 0, "scene grace blocks memory writes")
    equal(ctx.replaces, before_replaces, "scene grace blocks config replacement")
    equal(ctx.files[CFG], "0\n"); equal(ctx.files[INI], original_ini)
    equal(M.hotkey, original_key); equal(M.hotkey_status, original_status)
    if CASE == "scene_grace_close" or CASE == "scene_grace_escape" then
        equal(M.visible, false, "close remains available in scene grace")
        equal(ctx.cursor, false)
    else
        equal(M.visible, true, "short scene gap retains menu")
        ctx.allowed = true; step({}); tap("enter")
        local expected = fixture.ids[2]
        equal(M.selected, expected, "original selection applies after scene recovers")
        assert_source(expected)
    end
elseif CASE:find("^settings_save_") then
    local original = ctx.files[INI]
    open_menu(); click("hotkey")
    ctx.save_failure = CASE:match("settings_save_(.+)")
    tap("f12")
    equal(M.hotkey, "f10", "failed save retains current key")
    equal(ctx.files[INI], original, "failed save retains original file")
    equal(ctx.files[CFG], "0\n"); equal(M.selected, 0); equal(ctx.writes, 0)
    assert(M.hotkey_status:find("failed")); assert_no_temporaries()
elseif CASE == "apply_success" or CASE == "apply_clear" then
    choose_extra()
    local before = ctx.validation_reads
    tap("enter")
    equal(ctx.validation_reads - before, #fixture.fields, "one read per identity record")
    equal(M.selected, fixture.ids[2]); equal(M.applied, M.selected)
    assert_source(M.selected); equal(get32(LIVE + 0x6c), M.selected)
    equal(ctx.files[CFG], tostring(M.selected) .. "\n"); equal(ctx.scan_allocations, 0)
    if CASE == "apply_clear" then
        tap("up"); tap("enter"); equal(M.selected, 0)
        assert_source(0); equal(get32(LIVE + 0x6c), 0); equal(ctx.files[CFG], "0\n")
    end
elseif CASE:find("^reject_") then
    choose_extra()
    local first = ARMOR + fixture.fields[1][1]
    if CASE == "reject_kit" then put32(first - 28, 99) end
    if CASE == "reject_type" then put32(first + 12, 2) end
    if CASE == "reject_passive" then put32(first, fixture.ids[3]) end
    if CASE == "reject_short" then ctx.read_failure = {address = first - 28, size = 44} end
    if CASE == "reject_header" then put32(ARMOR, 0) end
    if CASE == "reject_page" then ctx.unsafe_page = true end
    if CASE == "reject_before_write" then ctx.read_failure = {address = first, size = 4} end
    tap("enter")
    equal(ctx.writes, 0, "rejection must precede writes")
    equal(M.selected, 0); equal(ctx.files[CFG], "0\n")
    assert(M.phase:find("failed"))
elseif CASE:find("^rollback_") then
    choose_extra()
    if CASE == "rollback_readback" then ctx.readback_failure = ARMOR + fixture.fields[3][1] end
    if CASE == "rollback_runtime" then ctx.runtime_write_failure = true end
    if CASE == "rollback_config" then ctx.passive_save_failure = true end
    if CASE == "rollback_protect" then
        ctx.protections[ARMOR] = 0x02; ctx.protect_restore_failure = true
    end
    tap("enter")
    equal(M.selected, 0); equal(M.applied, 0); assert_source(0)
    equal(get32(LIVE + 0x6c), 0); equal(ctx.files[CFG], "0\n")
    assert(M.phase:find("failed")); assert_no_temporaries()
    assert(ctx.last_log:find("failed"), "transaction failures flush immediately")
elseif CASE == "protected_write" then
    choose_extra(); ctx.protections[ARMOR] = 0x02; tap("enter")
    assert_source(fixture.ids[2]); equal(ctx.protections[ARMOR], 0x02)
    equal(ctx.protect_calls, 2 * #fixture.fields, "all source protections restored")
elseif CASE == "startup_locate" then
    for _ = 1, 120 do step({}) end
    equal(M.base, ARMOR); equal(M.applied, fixture.ids[2]); assert_source(M.selected)
    equal(get32(LIVE + 0x6c), M.selected, "startup runtime synced immediately")
elseif CASE == "source_reset" then
    active(); put32(ARMOR + fixture.fields[2][1], 0); step({})
    assert_source(M.selected)
elseif CASE == "source_recovery" then
    active(); local first = ARMOR + fixture.fields[1][1]
    put32(first, fixture.ids[3]); step({}); assert(M.phase:find("externally"))
    put32(first, M.selected); step({}, 1001); equal(M.phase, "active")
elseif CASE == "runtime_scan_changed" or CASE == "runtime_before_write_changed" then
    choose_extra()
    if CASE == "runtime_scan_changed" then
        M.runtime_header = nil
        ctx.invalidate_during_scan = true
    else ctx.invalidate_before_write = true end
    tap("enter")
    equal(get32(LIVE + 0x38), 99, "runtime identity invalidated by fixture")
    equal(get32(LIVE + 0x6c), 0, "changed runtime identity is never written")
    equal(M.runtime_header, nil, "changed runtime cache discarded")
    equal(M.selected, 0); equal(M.applied, 0); assert_source(0)
    equal(ctx.files[CFG], "0\n"); equal(ctx.replaces, 0)
    assert(M.phase:find("changed", 1, true), "identity change reported")
    if CASE == "runtime_scan_changed" then equal(ctx.scans, 2) else equal(ctx.scans, 0) end
elseif CASE:find("^scan_") then
    choose_extra()
    if CASE ~= "scan_cached" then M.runtime_header = nil end
    if CASE == "scan_multiple" then live_record(ARENA + 0x400) end
    if CASE == "scan_absent" or CASE == "scan_lazy_reuse" then put(LIVE, string.rep("\0", 12)) end
    if CASE == "scan_short" then ctx.read_failure = {address = ARENA + 0x100000, size = 0x100000} end
    equal(ctx.scan_allocations, 0, "scan buffer deferred")
    tap("enter")
    if CASE == "scan_cached" then equal(ctx.scans, 0); equal(ctx.scan_allocations, 0)
    else equal(ctx.scans, CASE == "scan_short" and 2 or 1); equal(ctx.scan_allocations, 1) end
    if CASE == "scan_unique" or CASE == "scan_cached" then equal(M.selected, fixture.ids[2])
    else equal(M.selected, 0); assert_source(0); equal(ctx.files[CFG], "0\n") end
    if CASE == "scan_lazy_reuse" then
        tap("enter"); equal(ctx.scans, 2); equal(ctx.scan_allocations, 1, "scan buffer reused")
    end
elseif CASE:match("^timer%d+$") then
    active()
    local fps = tonumber(CASE:match("%d+"))
    for _ = 1, fps * 10 do step({}, 1000 / fps) end
    equal(ctx.validation_reads, #fixture.fields * 10, "ten seconds means ten maintenance passes")
elseif CASE == "timer_gap" then
    active(); step({}); local before = ctx.validation_reads
    step({}, 10000); equal(ctx.validation_reads - before, #fixture.fields, "one pass after long gap")
    before = ctx.validation_reads; step({}); equal(ctx.validation_reads, before, "no catch-up burst")
elseif CASE == "timer_fallback" then
    active(); ctx.clock_failure = true
    for _ = 1, 180 do step({}) end
    equal(M.clock_failed, true)
    assert(ctx.validation_reads >= #fixture.fields * 3 and ctx.validation_reads <= #fixture.fields * 4)
elseif CASE == "runtime_retry" then
    active(); M.runtime_header = nil; put(LIVE, string.rep("\0", 12)); M.runtime_pending = true
    for _ = 1, 240 * 5 do step({}, 1000 / 240) end
    equal(ctx.scans, 5, "failed runtime scans limited to about one per second")
    equal(ctx.validation_reads, #fixture.fields * 5, "pending does not revalidate every frame")
elseif CASE == "log_idle" then
    local before = ctx.log_opens
    for _ = 1, 300 do step({}) end
    equal(ctx.log_opens, before, "idle frames perform no log I/O")
    equal(ctx.focus_queries, 0, "closed idle menu does not query focus")
    equal(ctx.physical_key_queries, 0, "closed idle menu does not poll keys")
elseif CASE == "log_merge" then
    local before = ctx.log_opens; step({"f9"})
    equal(ctx.log_opens - before, 1, "open, font, draw events merged per frame")
    before = ctx.log_opens; step({})
    equal(ctx.log_opens, before, "visible idle menu does not rewrite log")
elseif CASE:find("^log_retry") then
    ctx.log_failure = CASE == "log_retry" and "open" or CASE:match("log_retry_(.+)")
    local before = ctx.log_opens
    step({"f9"}); equal(ctx.log_opens, before + 1)
    for _ = 1, 50 do step({}) end
    equal(ctx.log_opens, before + 1, "failed log open is throttled")
    ctx.log_failure = nil; step({}, 1001); equal(ctx.log_opens, before + 2, "dirty log retried")
elseif CASE == "log_dedup" then
    active(); put32(ARMOR + fixture.fields[1][1], fixture.ids[3]); step({})
    local before = ctx.log_opens
    for _ = 1, 10 do step({}, 1001) end
    equal(ctx.log_opens, before, "stable external conflict not repeatedly logged")
elseif CASE == "log_restore_dedup" or CASE == "log_restore_recovery" then
    active()
    local first = ARMOR + fixture.fields[1][1]
    put32(first, 0); ctx.unsafe_page = true; step({})
    assert(M.phase:find("restore failed:", 1, true))
    local before = ctx.log_opens
    for _ = 1, 10 do step({}, 1001) end
    equal(ctx.log_opens, before, "stable restore failure does not rewrite log")
    equal(get32(first), 0); equal(ctx.writes, 0)
    if CASE == "log_restore_recovery" then
        ctx.unsafe_page = false; step({}, 1001)
        equal(M.phase, "active"); assert_source(M.selected)
        equal(ctx.log_opens, before + 1, "successful recovery logged")
        before = ctx.log_opens
        for _ = 1, 3 do step({}, 1001) end
        equal(ctx.log_opens, before, "recovered idle state stays quiet")
        put32(first, 0); ctx.unsafe_page = true; step({}, 1001)
        equal(ctx.log_opens, before + 1, "new failure after recovery is logged again")
    end
elseif CASE == "input_cache" then
    open_menu()
    for _ = 1, 30 do click("select_second") end
    equal(ctx.id_calls["keyboard:f9"], 1); equal(ctx.id_calls["mouse:left"], 1)
    equal(ctx.id_calls["axis:cursor"], 1)
    s3d.Keyboard.button_id = function(name) id("replacement", name); return codes[name] end
    -- A resolver replacement must invalidate the old keyboard cache.
    step({}); equal(ctx.id_calls["replacement:f9"], 1)
    s3d.Keyboard = {button_id = function(name) id("new_device", name); return codes[name] end,
        pressed = function(code) return ctx.pressed[code] == true end}
    tap("f9"); equal(ctx.id_calls["new_device:f9"], 1); equal(M.visible, false)
elseif CASE == "pointer_reads" then
    open_menu()
    equal(#ctx.owner_read_sizes, 5, "one owner read per consumer/initialization")
    for _, size in ipairs(ctx.owner_read_sizes) do equal(size, 8, "one syscall per pointer") end
elseif CASE == "callback_values" then
    local result = step({})
    equal(result.n, 4); equal(result[1], "prior-result"); equal(result[2], nil)
    equal(result[3], 99); equal(result[4], nil)
    equal(ctx.prior_args.n, 4); equal(ctx.prior_args[1], "sentinel")
    equal(ctx.prior_args[2], nil); equal(ctx.prior_args[3], 7); equal(ctx.prior_args[4], nil)
    open_menu(); ctx.native_order = {}; step({})
    equal(table.concat(ctx.native_order, ","), "select,back,game_menu,prior,select,back,game_menu", "native menu actions consumed around prior callback")
elseif CASE:find("^gui_") then
    open_menu()
    local before = gui_count()
    ctx.worlds_missing = true
    if CASE == "gui_failed_cleanup" then ctx.prior_failure = true
    elseif CASE == "gui_consumer_cleanup" then ctx.consume_failure = "back" end
    step({})
    equal(M.visible, false); equal(ctx.cursor, false)
    equal(ctx.destroyed, 0, "unknown worlds must not be destroyed")
    equal(gui_count(), before, "unknown-world cleanup retains GUI primitives")
    local consumes = ctx.consumes
    for _ = 1, 10 do step({}) end
    equal(ctx.consumes, consumes, "pending cleanup does not consume input")
    equal(gui_count(), before, "pending cleanup does not create more GUI")
    ctx.worlds_missing = false
    if CASE == "gui_removed_world" then ctx.worlds_override = {world2, world3} end
    step({})
    if CASE == "gui_removed_world" then
        equal(ctx.destroyed, 1, "only surviving world is destroyed")
        equal(ctx.destroyed_worlds[1], world2, "dead world handle is never called")
    else
        equal(ctx.destroyed, 2, "deferred cleanup releases both GUI instances")
        equal(gui_count(), 0, "deferred cleanup releases all primitives")
    end
    if CASE == "gui_failed_cleanup" then
        equal(M.failed, true, "cleanup runs even after module failure")
    elseif CASE == "gui_deferred_cleanup" then
        open_menu(); equal(gui_count(), before, "reopen has no orphan GUI primitives")
    elseif CASE ~= "gui_removed_world" and CASE ~= "gui_consumer_cleanup" then
        error("unknown GUI cleanup case")
    end
elseif CASE == "callback_prior_error" or CASE == "callback_module_error" then
    open_menu()
    if CASE == "callback_prior_error" then ctx.prior_failure = true else ctx.focus_failure = true end
    step({}); equal(M.failed, true); equal(M.visible, false); equal(ctx.cursor, false)
    equal(ctx.destroyed, 2); local before = ctx.consumes; step({})
    equal(ctx.consumes, before, "failed module stops input consumption")
elseif CASE == "native_back_error" or CASE == "native_game_menu_error" then
    open_menu()
    ctx.consume_failure = CASE == "native_back_error" and "back" or "game_menu"
    local result = step({})
    equal(M.visible, false, "consumer failure closes menu")
    equal(ctx.cursor, false, "consumer failure releases cursor")
    equal(ctx.destroyed, 2, "consumer failure releases GUI")
    equal(result.n, 4, "consumer failure preserves prior returns")
    equal(result[1], "prior-result")
    local before = ctx.consumes
    step({})
    equal(ctx.consumes, before, "closed menu stops consumption")
elseif CASE == "shutdown" then
    open_menu(); local before = ctx.log_opens
    local result = pack(shutdown("exit", nil))
    equal(M.visible, false); equal(ctx.cursor, false); equal(ctx.log_opens, before + 1)
    equal(result.n, 4); equal(result[1], "shutdown-result"); equal(result[3], 8)
    equal(ctx.shutdown_args.n, 2); equal(ctx.shutdown_args[1], "exit")
elseif CASE == "loader_legacy" then
    assert(ctx.last_log:find("Loader API: 1", 1, true))
    assert(ctx.last_log:find("Loader revision: nil", 1, true)); step({})
elseif CASE == "loader_v19" then
    assert(ctx.last_log:find("Loader revision: loader-v19", 1, true))
    assert(ctx.last_log:find("after_startup=true", 1, true))
    assert(ctx.last_log:find("Loader JIT managed: false", 1, true))
    step({}); equal(CowboyBingusModLoader.version, 17)
elseif CASE == "ffi_aliases" then
    local exports = real_load("kernel32")
    for name in pairs(kernel) do assert(exports["hd2dap_v1_" .. name], "real alias missing: " .. name) end
    local foreground = real_load("user32")
    for name in pairs(user) do assert(foreground["hd2dap_v1_" .. name]) end
    assert(exports.hd2dap_v1_GetCurrentProcess() ~= nil)
    assert(tonumber(exports.hd2dap_v1_GetCurrentProcessId()) > 0)
    assert(tonumber(exports.hd2dap_v1_GetTickCount64()) > 0)
    equal(ffi.sizeof("HD2DualArmorMemRegion"), 4, "foreign type stays untouched")
    equal(ffi.sizeof("HD2DAP_v1_MemRegion"), 48, "private ABI")
elseif CASE:find("^language_") then
    local before_ini, before_cfg = ctx.files[INI], ctx.files[CFG]
    if CASE:find("^language_package_") then
        open_menu(); equal(M.display_language, "en", "pending language package uses English")
        local expected = CASE == "language_package_tw" and "zh_tw" or "zh_cn"
        if CASE:find("^language_package_missing_") then
            ctx.package_ready = true; step({}); equal(ctx.package_loads, 0)
            equal(M.display_language, "en", "missing loader API preserves fallback")
            local missing = CASE == "language_package_missing_api" and "ResourcePackage.flush"
                or CASE == "language_package_missing_create_api" and "Application.resource_package"
                or "Application.release_resource_package"
            assert(M.language_status:find(missing .. " unavailable", 1, true), "fallback names the missing API")
        elseif CASE:find("^language_package_failure_") then
            ctx.package_ready = true; step({}); equal(M.display_language, "en")
            equal(M.failed, nil, "package failure does not disable module")
            equal(ctx.package_loads, ctx.package_failure == "create" and 0 or 1)
            ctx.package_failure = nil
        elseif CASE == "language_package_retry" then
            -- Start a failed load by injecting it before a different language choice.
            ctx.package_failure = "load"; click("traditional")
            equal(M.display_language, "en"); equal(ctx.package_loads, 2)
            ctx.package_failure = nil; tap("escape"); step({}, 6000); open_menu()
            equal(ctx.package_loads, 3, "manual reopen retries a failed load after backoff")
            ctx.package_ready = true; step({}); equal(M.display_language, "zh_tw")
            equal(ctx.package_releases, 1, "retry frees failed handle")
        elseif CASE == "language_package_switch" then
            tap("right"); click("traditional"); equal(ctx.package_loads, 2)
            click("english"); ctx.package_ready = true; step({})
            equal(M.display_language, "en", "late completion respects newer English choice")
            click("traditional"); equal(M.display_language, "zh_tw")
            assert(has_text("第 2 / 4 頁"), "background load preserves page")
            equal(ctx.package_loads, 2, "reuse loaded language packages")
        elseif CASE == "language_package_shutdown_pending" then
            equal(ctx.package_flushes, 0)
        else
            for _ = 1, 5 do step({}) end
            equal(ctx.package_loads, 1, "one handle while load is pending")
            equal(ctx.package_flushes, 0, "incomplete load is not flushed")
            if CASE == "language_package_closed" then tap("escape") end
            ctx.package_ready = true; step({})
            if CASE == "language_package_closed" then
                equal(M.visible, false, "load completion does not open closed menu"); open_menu()
            end
            equal(M.display_language, expected, "loaded package restores requested language")
            equal(ctx.package_flushes, 1)
            step({}); equal(ctx.package_flushes, 1, "flush only once")
        end
        if CASE == "language_package_cleanup_deferred" then ctx.worlds_missing = true end
        if CASE == "language_package_cleanup_unload" then ctx.package_failure = "unload" end
        if CASE == "language_package_cleanup_release" then ctx.package_failure = "release" end
        local result = pack(shutdown("package-exit", nil))
        equal(result[1], "shutdown-result"); equal(result.n, 4)
        if CASE == "language_package_cleanup_deferred" then
            equal(ctx.package_releases, 0, "fonts retained while GUI cleanup is deferred")
            ctx.worlds_missing = false; step({})
        elseif ctx.package_failure then
            equal(ctx.package_releases, 0, "cleanup failure retains handle for retry")
            ctx.package_failure = nil; step({})
            equal(M.failed, nil, "cleanup retry does not disable module")
        end
        for _, entry in pairs(ctx.packages) do assert(entry.released, "package handle released") end
        if not CASE:find("switch") and not CASE:find("retry") then
            equal(ctx.package_unloads, ctx.package_loads, "each owned load unloaded once")
        end
        equal(ctx.writes, 0); equal(ctx.files[CFG], before_cfg)
        if not CASE:find("switch") and not CASE:find("retry") then equal(ctx.files[INI], before_ini) end
    elseif CASE:find("^language_auto_") then
        local expected = ({cn = "zh_cn", tw = "zh_tw", en = "en", unknown = "en"})[CASE:match("language_auto_(.+)")]
        open_menu(); equal(M.menu_language, nil, "legacy settings stay automatic")
        equal(M.display_language, expected, "automatic selection uses text language")
        equal(ctx.files[INI], before_ini); equal(ctx.replaces, 0)
        if expected == "zh_tw" then assert(has_text("偵察兵"), "official Traditional passive name") end
    elseif CASE == "language_reload_en_game" or CASE == "language_reload" then
        open_menu()
        local preference = CONFIG_OVERRIDE:match("menu_language=([^\n]+)"):match("^%s*(.-)%s*$"):lower()
        equal(M.menu_language, preference); equal(M.display_language, preference)
        local key = CONFIG_OVERRIDE:match("menu_hotkey=([^\n]+)"):match("^%s*(.-)%s*$"):lower()
        equal(M.hotkey, key); equal(ctx.files[INI], before_ini); equal(ctx.replaces, 0)
    elseif CASE == "language_invalid" or CASE == "language_duplicate" then
        open_menu(); equal(M.menu_language, "en"); equal(M.display_language, "en")
        equal(M.hotkey, "f10", "invalid language preserves valid hotkey")
        assert(M.language_config_error); equal(M.hotkey_config_error, nil)
        equal(ctx.replaces, 0); click("traditional")
        equal(M.language_config_error, nil); equal(M.hotkey, "f10"); equal(M.display_language, "zh_tw")
    elseif CASE == "language_key_invalid" then
        open_menu(); equal(M.menu_language, "zh_tw"); equal(M.display_language, "zh_tw")
        equal(M.hotkey, "f9"); assert(M.hotkey_config_error); equal(M.language_config_error, nil)
        click("english"); equal(M.hotkey_config_error, nil)
        equal(ctx.files[INI], "settings_version=1\nmenu_hotkey=f9\nmenu_language=en\n")
    elseif CASE == "language_click" then
        choose_extra(); tap("right")
        assert(has_text("Page 2 / 4") or has_text("第 2 / 4 页"))
        click("traditional")
        equal(M.menu_language, "zh_tw"); equal(M.display_language, "zh_tw"); equal(M.hotkey, "f9")
        assert(has_text("第 2 / 4 頁"), "switch preserves current page")
        equal(ctx.writes, 0, "language click does not apply passive")
        equal(ctx.files[CFG], before_cfg); equal(M.selected, 0)
        tap("enter"); equal(M.selected, fixture.ids[2], "switch preserves highlighted passive")
        tap("escape"); open_menu(); equal(M.display_language, "zh_tw", "manual choice survives reopening")
    elseif CASE == "language_save_cycle" then
        open_menu(); click("hotkey"); tap("f10"); click("traditional")
        equal(ctx.files[INI], "settings_version=1\nmenu_hotkey=f10\nmenu_language=zh_tw\n")
        click("reset"); equal(M.hotkey, "f9")
        equal(ctx.files[INI], "settings_version=1\nmenu_hotkey=f9\nmenu_language=zh_tw\n")
        local handles = gui_count()
        for _ = 1, 5 do click("english"); click("simplified"); click("traditional"); equal(gui_count(), handles) end
        click("hotkey"); tap("f12")
        equal(ctx.files[INI], "settings_version=1\nmenu_hotkey=f12\nmenu_language=zh_tw\n")
        equal(M.visible, true); equal(ctx.writes, 0); equal(ctx.files[CFG], before_cfg)
        tap("escape"); equal(gui_count(), 0, "language redraws leave no GUI handles")
        equal(ctx.destroyed, 2); assert_no_temporaries()
    elseif CASE == "language_capture_block" or CASE == "language_scene_block" or CASE == "language_focus_block" then
        open_menu()
        if CASE == "language_capture_block" then click("hotkey")
        elseif CASE == "language_scene_block" then ctx.allowed = false
        else ctx.focused = false end
        click("traditional"); equal(M.menu_language, nil); equal(ctx.files[INI], before_ini)
        equal(ctx.writes, 0); equal(ctx.replaces, 0)
    elseif CASE:find("^language_save_failure_") then
        open_menu(); local old_language, old_display = M.menu_language, M.display_language
        ctx.save_failure = CASE:match("language_save_failure_(.+)")
        click("traditional")
        equal(M.menu_language, old_language); equal(M.display_language, old_display)
        equal(M.hotkey, "f10"); equal(ctx.files[INI], before_ini)
        equal(ctx.files[CFG], before_cfg); equal(ctx.writes, 0)
        assert(has_text("Language save failed")); assert_no_temporaries()
        ctx.save_failure = nil; click("traditional")
        equal(M.display_language, "zh_tw"); equal(M.menu_language, "zh_tw"); equal(M.hotkey, "f10")
    elseif CASE:find("^language_font_") and CASE ~= "language_font_choose" then
        ctx.font_failure = CASE:match("language_font_(.+)")
        local texture_setter = s3d.Material.set_texture
        if ctx.font_failure == "api" then s3d.Material.set_texture = nil end
        open_menu()
        if ctx.font_failure == "primary" or ctx.font_failure == "primary_atlas" then
            equal(M.display_language, "zh_cn", "alternate verified font works")
        else
            equal(M.menu_language, "zh_cn"); equal(M.display_language, "en")
            assert(has_text("Chinese font unavailable")); equal(ctx.files[INI], before_ini)
            tap("escape"); ctx.font_failure = nil; s3d.Material.set_texture = texture_setter; open_menu()
            equal(M.display_language, "zh_cn", "reopening retries requested language")
        end
        equal(ctx.writes, 0); equal(ctx.files[CFG], before_cfg); equal(ctx.replaces, 0)
    elseif CASE == "language_font_choose" then
        open_menu(); ctx.font_failure = "resources"; click("traditional")
        equal(M.menu_language, "zh_tw"); equal(M.display_language, "en")
        equal(ctx.files[INI], "settings_version=1\nmenu_hotkey=f9\nmenu_language=zh_tw\n")
        assert(has_text("Chinese font unavailable"))
        tap("escape"); ctx.font_failure = nil; open_menu(); equal(M.display_language, "zh_tw")
        equal(ctx.writes, 0)
    elseif CASE == "language_all_fonts_lost" then
        open_menu(); ctx.font_failure = "all"; click("traditional")
        equal(M.visible, false); equal(ctx.cursor, false); equal(gui_count(), 0)
        equal(M.menu_language, "zh_tw"); equal(ctx.writes, 0); equal(ctx.destroyed, 2)
    else error("unknown language case: " .. CASE) end
elseif CASE == "pagination_keyboard" or CASE == "pagination_mouse" or CASE == "pagination_single" then
    choose_extra()
    local previous = CASE == "pagination_mouse" and function() click("prev") end or function() tap("left") end
    local following = CASE == "pagination_mouse" and function() click("next") end or function() tap("right") end
    local pages = CASE == "pagination_single" and 1 or 4
    previous(); assert(has_text("Page " .. pages .. " / " .. pages), "first page wraps backward")
    following(); assert(has_text("Page 1 / " .. pages), "last page wraps forward")
    for page = 2, pages do following(); assert(has_text("Page " .. page .. " / " .. pages)) end
    following(); assert(has_text("Page 1 / " .. pages), "forward wrap after sequential navigation")
    equal(ctx.writes, 0); equal(ctx.replaces, 0); equal(M.selected, 0)
    tap("enter"); equal(M.selected, fixture.ids[2], "pagination preserves highlighted passive")
elseif CASE == "zh_ui" or CASE == "font_fallback" then
    if CASE == "font_fallback" then ctx.font_failure = "resources" end
    open_menu()
    assert(has_text(CASE == "zh_ui" and "修改快捷键" or "CHANGE KEY"), "localized toolbar")
    equal(M.box[4], 680)
    local rows = 0
    for _, entry in pairs(ctx.gui_entries) do
        if entry.kind == "rect" and entry.args[2].x == 624 then rows = rows + 1 end
    end
    equal(rows, 16, "eight rows in each GUI layer")
elseif CASE == "measure_work" then
    active()
    local fps = tonumber(MEASURE_FPS)
    for _ = 1, fps * 10 do step({}, 1000 / fps) end
elseif CASE == "measure_menu" then
    step({"f9"})
else
    error("unknown offline case: " .. tostring(CASE))
end
RESULT_INI = ctx.files[INI]
RESULT_reads, RESULT_table_reads, RESULT_scans = ctx.reads, ctx.table_reads, ctx.scans
RESULT_scan_allocations, RESULT_log_opens = ctx.scan_allocations, ctx.log_opens
RESULT_key_resolutions = ctx.id_calls["keyboard:f9"] or 0
