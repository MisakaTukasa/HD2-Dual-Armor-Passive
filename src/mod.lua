-- HD2-Addon: mods/hd2/dual_armor_passive
-- Helmet passive switching, guarded by supported data contracts.

-- @READ_ONLY@

local module_name = READ_ONLY and "HD2DualArmorCompatibilityProbe" or "HD2DualArmorPassive"
if rawget(_G, module_name) then return end

local M = {
    revision = "1.1.0-compat2",
    phase = "starting",
    frame = 0,
    selected = 0,
    applied = 0,
    visible = false,
    page = 1,
    events = {},
    next_address = 0x10000,
    now_ms = 0,
    runtime_retry_ms = 0,
    maintenance_ms = 0,
    hotkey = "f9",
}
rawset(_G, module_name, M)

-- @LAYOUT@

-- @HELMET_FIELDS@

-- @PASSIVES@
local PASSIVE_IDS = {}
for i = 1, #PASSIVES do PASSIVE_IDS[PASSIVES[i][1]] = true end
local HELMET_IDS = {}
for i = 1, #HELMET_FIELDS do HELMET_IDS[HELMET_FIELDS[i][2]] = true end

local ffi = require("ffi")
-- A shared LuaJIT VM keeps the first declaration of a C symbol. Private names
-- avoid inheriting another addon's Windows prototypes and typedefs.
ffi.cdef[[
    void *hd2dap_v1_GetCurrentProcess(void) __asm__("GetCurrentProcess");
    void *hd2dap_v1_GetModuleHandleA(const char *name) __asm__("GetModuleHandleA");
    int hd2dap_v1_ReadProcessMemory(void *process, const void *address, void *buffer, size_t size, size_t *read) __asm__("ReadProcessMemory");
    int hd2dap_v1_WriteProcessMemory(void *process, void *address, const void *buffer, size_t size, size_t *written) __asm__("WriteProcessMemory");
    int hd2dap_v1_VirtualProtect(void *address, size_t size, uint32_t new_protection, uint32_t *old_protection) __asm__("VirtualProtect");
    size_t hd2dap_v1_VirtualQuery(const void *address, void *region, size_t size) __asm__("VirtualQuery");
    uint32_t hd2dap_v1_GetCurrentProcessId(void) __asm__("GetCurrentProcessId");
    uint32_t hd2dap_v1_GetLastError(void) __asm__("GetLastError");
    int hd2dap_v1_MoveFileExA(const char *existing, const char *replacement, uint32_t flags) __asm__("MoveFileExA");
    void *hd2dap_v1_FindFirstFileA(const char *pattern, void *data) __asm__("FindFirstFileA");
    int hd2dap_v1_FindClose(void *handle) __asm__("FindClose");
    uint64_t hd2dap_v1_GetTickCount64(void) __asm__("GetTickCount64");
    void *hd2dap_v1_GetForegroundWindow(void) __asm__("GetForegroundWindow");
    uint32_t hd2dap_v1_GetWindowThreadProcessId(void *window, uint32_t *process) __asm__("GetWindowThreadProcessId");
    int16_t hd2dap_v1_GetAsyncKeyState(int key) __asm__("GetAsyncKeyState");
    typedef struct {
        void *base; void *allocation_base; uint32_t allocation_protection;
        uint16_t partition; uint16_t reserved; size_t size;
        uint32_t state; uint32_t protection; uint32_t type;
    } HD2DAP_v1_MemRegion;
    typedef struct {
        uint32_t attributes; uint32_t timestamps[6];
        uint32_t file_size_high, file_size_low, reserved0, reserved1;
        char name[260]; char alternate_name[14];
    } HD2DAP_v1_FindData;
]]
assert(ffi.abi("win") and ffi.sizeof("void *") == 8, "HD2 Dual Armor Passive requires Win64")
assert(ffi.sizeof("HD2DAP_v1_MemRegion") == 48
    and ffi.offsetof("HD2DAP_v1_MemRegion", "size") == 24
    and ffi.offsetof("HD2DAP_v1_MemRegion", "state") == 32
    and ffi.offsetof("HD2DAP_v1_MemRegion", "protection") == 36
    and ffi.offsetof("HD2DAP_v1_MemRegion", "type") == 40
    and ffi.sizeof("HD2DAP_v1_FindData") == 320
    and ffi.offsetof("HD2DAP_v1_FindData", "name") == 44, "HD2 Dual Armor Passive Windows ABI mismatch")

local function private_library(name, symbols)
    local library, result = ffi.load(name), {}
    for _, symbol in ipairs(symbols) do result[symbol] = library["hd2dap_v1_" .. symbol] end
    result._library = library -- Keep the namespace alive with its function pointers.
    return result
end
local kernel = private_library("kernel32", {"GetCurrentProcess", "GetModuleHandleA",
    "ReadProcessMemory", "WriteProcessMemory", "VirtualProtect", "VirtualQuery",
    "GetCurrentProcessId", "GetLastError", "MoveFileExA", "FindFirstFileA", "FindClose", "GetTickCount64"})
local user = private_library("user32", {"GetForegroundWindow", "GetWindowThreadProcessId", "GetAsyncKeyState"})
local process = kernel.GetCurrentProcess()
local process_id = tonumber(kernel.GetCurrentProcessId())
local window_pid = ffi.new("uint32_t[1]")
local mem_region = ffi.new("HD2DAP_v1_MemRegion[1]")
local got = ffi.new("size_t[1]")
local written = ffi.new("size_t[1]")
local old_protect = ffi.new("uint32_t[1]")
local restore_protect = ffi.new("uint32_t[1]")
local bytes = ffi.new("uint64_t[8]")
local numbers = ffi.cast("uint32_t *", bytes)
local word = ffi.new("uint32_t[1]")

local function game_language()
    local root = os.getenv("APPDATA")
    if not root then return "en" end
    local folder = root .. "\\Arrowhead\\Helldivers2\\saves\\"
    local data = ffi.new("HD2DAP_v1_FindData[1]")
    local ok, handle = pcall(kernel.FindFirstFileA, folder .. "*_user_settings.config", data)
    if not ok or handle == nil or handle == ffi.cast("void *", -1) then return "en" end
    local filename = ffi.string(data[0].name)
    pcall(kernel.FindClose, handle)
    local file = io.open(folder .. filename, "r")
    if not file then return "en" end
    local result = "en"
    for line in file:lines() do
        local value = line:match('^%s*language%s*=%s*"([%w_-]+)"')
        if value then result = value:lower(); break end
    end
    file:close()
    return result
end

local function from_hex(hex)
    return (hex:gsub("..", function(pair) return string.char(tonumber(pair, 16)) end))
end
local HEADER = from_hex("9b0100004c444c4401000000a05aa5d9e8090000010000000000000078fa9b1f")
local MAX_ADDRESS = 0x7fffffffffff
local log_dirty, log_retry_ms = false, 0
local notices = {}

local function note(message)
    M.events[#M.events + 1] = string.format("frame %d: %s", M.frame, tostring(message))
    if #M.events > 60 then table.remove(M.events, 1) end
    log_dirty = true
end

local function notice(key, message)
    if notices[key] == message then return end
    notices[key] = message
    if message then note(message) end
end

local function update_time()
    if not M.clock_failed then
        local ok, value = pcall(kernel.GetTickCount64)
        local now = ok and tonumber(value)
        if now and now >= M.now_ms then M.now_ms = now; return end
        M.clock_failed = true
        M.clock_failure_ms, M.clock_failure_frame = M.now_ms, M.frame
        note("monotonic clock unavailable; using 60-frame maintenance timing")
    end
    M.now_ms = M.clock_failure_ms + (M.frame - M.clock_failure_frame) * (1000 / 60)
end

local function flush_log(force)
    if not log_dirty or (not force and M.now_ms < log_retry_ms) then return end
    local loader = rawget(_G, "CowboyBingusModLoader")
    if not loader or type(loader.open_log) ~= "function" then
        log_retry_ms = M.now_ms + 1000
        return
    end
    local ok, file = pcall(loader.open_log, READ_ONLY and "HD2DualArmorCompatibilityProbe.log" or "HD2DualArmorPassive.log")
    if not ok or not file then log_retry_ms = M.now_ms + 1000; return end
    local caps = type(loader.capabilities) == "table" and loader.capabilities or {}
    local capability_lines = {}
    for _, name in ipairs({"api", "logs", "discovery", "jit_budget", "health", "after_startup"}) do
        capability_lines[#capability_lines + 1] = name .. "=" .. tostring(caps[name])
    end
    local lines = {
        "HD2 Dual Armor Passive " .. M.revision,
        "Process: " .. tostring(process_id),
        "Phase: " .. M.phase,
        "Selected: " .. M.selected,
        "Applied: " .. M.applied,
        "Table: " .. (M.base and string.format("0x%x", M.base) or "not found"),
        "Runtime: " .. tostring(M.runtime_status),
        "Menu: " .. tostring(M.visible),
        "Hotkey: " .. M.hotkey:upper(),
        "Hotkey status: " .. tostring(M.hotkey_status),
        "GUI: " .. tostring(M.gui_status),
        "Scene: " .. tostring(M.scene_status),
        "Native input: " .. tostring(M.native_input_status),
        "Mode: " .. (READ_ONLY and "read-only compatibility probe" or "passive menu"),
        "Search: " .. tostring(M.search_status),
        "Compatibility: dependency checks; gameplay behavior requires live verification",
        "Loader API: " .. tostring(loader.api),
        "Loader revision: " .. tostring(loader.revision),
        "Loader capabilities: " .. table.concat(capability_lines, " "),
        "Loader JIT managed: " .. tostring(type(loader.jit) == "table" and loader.jit.managed or false),
    }
    for _, name in ipairs({"module", "interfaces", "source", "input_entry", "input_owner", "font", "gui", "preflight", "runtime"}) do
        lines[#lines + 1] = "Compatibility " .. name .. ": " .. tostring(M.compatibility and M.compatibility[name])
    end
    lines[#lines + 1] = "Events:"
    for i = 1, #M.events do lines[#lines + 1] = M.events[i] end
    local write_ok, result = pcall(file.write, file, table.concat(lines, "\n"), "\n")
    local close_ok, closed = pcall(file.close, file)
    if write_ok and result and close_ok and closed then
        log_dirty, log_retry_ms = false, 0
    else
        log_retry_ms = M.now_ms + 1000
    end
end

local function log(force)
    log_dirty = true
    if force then flush_log(true) end
end

local function read_into(address, length)
    if length < 1 or length > 64 then return false end
    return kernel.ReadProcessMemory(process, ffi.cast("const void *", address), bytes, length, got) ~= 0
        and tonumber(got[0]) == length
end

local function read_bytes(address, length)
    if not read_into(address, length) then return nil end
    return ffi.string(bytes, length)
end

local function read32(address)
    if not read_into(address, 4) then return nil end
    return tonumber(numbers[0])
end

local function read64(address)
    if not read_into(address, 8) then return nil end
    return tonumber(bytes[0])
end

-- @COMPATIBILITY@

-- @SEARCH@

-- Consume native selection, back and the separate Escape game-menu action
-- through release. Raw Mouse.pressed and Keyboard.pressed remain available to
-- our GUI. These action codes, the entry point and owner are build-specific.
local INPUT_CONSUME_RVA = 0x12fde90
local INPUT_OWNER_RVA = 0x347cf18
local INPUT_CONSUME_PREFIX = from_hex("40534883ec204c8bd14c8bca488bcae8dc7c28ff")
local UI_SELECT = ffi.new("uint64_t", 0xA00000000)
local UI_BACK = ffi.new("uint64_t", 0x900000000)
local UI_GAME_MENU = ffi.new("uint64_t", 0x4900000000)
local native_consume, input_owner_base, native_entry

local function input_capture_ready()
    local entry = C.input_entry(INPUT_CONSUME_PREFIX, INPUT_CONSUME_RVA)
    if not entry then
        M.native_input_status = "consume signature mismatch"
        return false
    end
    if native_consume and native_entry == entry then return true end
    local slot = C.address(INPUT_OWNER_RVA, 8)
    local owner = slot and read64(slot)
    if not owner or not C.input_owner(owner) then
        M.native_input_status = "input owner unavailable"
        return false
    end
    input_owner_base = slot
    native_consume = ffi.cast("void (*)(void *, uint64_t, float)", entry)
    native_entry = entry
    M.native_input_status = "ready"
    note("native menu input consumer ready (select/back/game menu)")
    return true
end

local function consume_native_menu()
    if READ_ONLY then return false end
    if not input_capture_ready() then return false end
    local owner = read64(input_owner_base)
    if not owner or not C.input_owner(owner) then
        M.native_input_status = "input owner lost"
        return false
    end
    local pointer = ffi.cast("void *", owner)
    local ok, err = pcall(native_consume, pointer, UI_SELECT, -1)
    if ok then ok, err = pcall(native_consume, pointer, UI_BACK, -1) end
    if ok then ok, err = pcall(native_consume, pointer, UI_GAME_MENU, -1) end
    if not ok then
        M.native_input_status = "consume failed: " .. tostring(err):sub(1, 120)
        return false
    end
    M.native_input_status = "consuming select/back/game menu while menu is open"
    return true
end

local function table_header_ok(base)
    local expected = C.source_base == base and C.source_header or HEADER
    return read_bytes(base, #expected) == expected
end

local function table_fields_ok(base, own)
    local other = 0
    local zero = 0
    for i = 1, #HELMET_FIELDS do
        local offset, kit = HELMET_FIELDS[i][1], HELMET_FIELDS[i][2]
        if not read_into(base + offset + FIELD_READ_START, FIELD_READ_SIZE) then
            return false, "unreadable helmet record " .. i
        end
        local actual_kit = tonumber(numbers[(KIT_ID_DELTA - FIELD_READ_START) / 4])
        if actual_kit ~= kit then
            return false, string.format("helmet %d kit ID mismatch: expected 0x%08x, got %s",
                i, kit, actual_kit and string.format("0x%08x", actual_kit) or "unreadable")
        end
        local kind = tonumber(numbers[(KIT_TYPE_DELTA - FIELD_READ_START) / 4])
        if kind ~= HELMET_TYPE then
            return false, string.format("helmet %d type mismatch: expected %d, got %s",
                i, HELMET_TYPE, tostring(kind))
        end
        local value = tonumber(numbers[-FIELD_READ_START / 4])
        if value == 0 then zero = zero + 1 end
        if value ~= 0 and value ~= own then other = other + 1 end
    end
    if other > 0 then return false, other .. " helmet fields belong to another mod or build" end
    return true, nil, zero
end

local function read_config()
    local root = os.getenv("LOCALAPPDATA")
    if not root then return 0 end
    local file = io.open(root .. "/CowboyBingus/Helldivers2/HD2DualArmorPassive.cfg", "r")
    if not file then return 0 end
    local value = tonumber(file:read("*l"))
    file:close()
    if value and PASSIVE_IDS[value] then return value end
    return 0
end

local function write_config(value)
    if READ_ONLY then return false, "read-only probe" end
    local root = os.getenv("LOCALAPPDATA")
    if not root then return false, "LOCALAPPDATA unavailable" end
    local path = root .. "\\CowboyBingus\\Helldivers2\\HD2DualArmorPassive.cfg"
    local temporary = path .. ".tmp." .. tostring(kernel.GetCurrentProcessId())
    local file, open_error = io.open(temporary, "wb")
    if not file then return false, "temporary config open failed: " .. tostring(open_error) end
    local write_ok, written, write_error = pcall(file.write, file, tostring(value), "\n")
    local close_ok, closed, close_error = pcall(file.close, file)
    if not write_ok or not written or not close_ok or not closed then
        os.remove(temporary)
        local reason = (not write_ok and written) or (not written and write_error)
            or (not close_ok and closed) or close_error or "unknown I/O error"
        return false, "temporary config write failed: "
            .. tostring(reason)
    end
    -- The temporary file is in the same directory. Replace the previous choice
    -- only after the new one has been fully written and closed.
    if kernel.MoveFileExA(temporary, path, 0x9) == 0 then
        local code = tonumber(kernel.GetLastError())
        os.remove(temporary)
        return false, "config replacement failed (Win32 " .. code .. ")"
    end
    return true
end

local function valid_hotkey(value)
    if type(value) ~= "string" then return nil end
    value = value:match("^%s*(.-)%s*$"):lower()
    local number = tonumber(value:match("^f(%d+)$"))
    if number and number >= 1 and number <= 12 and value == "f" .. number then return value end
end

local function read_hotkey()
    local root = os.getenv("LOCALAPPDATA")
    if not root then return "f9", "LOCALAPPDATA unavailable" end
    local file, reason, code = io.open(root .. "\\CowboyBingus\\Helldivers2\\HD2DualArmorPassive.ini", "rb")
    if not file then
        if code == 2 then return "f9" end
        return "f9", "settings open failed: " .. tostring(reason)
    end
    local ok, content = pcall(file.read, file, 4097)
    local closed, result = pcall(file.close, file)
    if not ok or type(content) ~= "string" or not closed or not result or #content > 4096 then
        return "f9", "settings read failed or file is too large"
    end
    local values = {}
    for line in content:gmatch("[^\r\n]+") do
        if line:find("%S") and not line:match("^%s*[#;]") then
            local name, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
            if not name then return "f9", "malformed settings line" end
            name = name:lower()
            if name == "settings_version" or name == "menu_hotkey" then
                if values[name] ~= nil then return "f9", "duplicate settings field: " .. name end
                values[name] = value
            end
        end
    end
    if values.settings_version ~= "1" then return "f9", "unsupported settings version" end
    local key = valid_hotkey(values.menu_hotkey)
    if not key then return "f9", "menu_hotkey must be F1-F12" end
    return key
end

local function write_hotkey(value)
    if READ_ONLY then return false, "read-only probe" end
    if not valid_hotkey(value) then return false, "menu_hotkey must be F1-F12" end
    local root = os.getenv("LOCALAPPDATA")
    if not root then return false, "LOCALAPPDATA unavailable" end
    local path = root .. "\\CowboyBingus\\Helldivers2\\HD2DualArmorPassive.ini"
    local temporary = path .. ".tmp." .. tostring(process_id)
    local file, open_error = io.open(temporary, "wb")
    if not file then return false, "temporary settings open failed: " .. tostring(open_error) end
    local ok, written, write_error = pcall(file.write, file,
        "settings_version=1\nmenu_hotkey=" .. value .. "\n")
    local closed, result, close_error = pcall(file.close, file)
    if not ok or not written or not closed or not result then
        os.remove(temporary)
        return false, "temporary settings write failed: " .. tostring(
            (not ok and written) or (not written and write_error)
            or (not closed and result) or close_error or "unknown I/O error")
    end
    if kernel.MoveFileExA(temporary, path, 0x9) == 0 then
        local code = tonumber(kernel.GetLastError())
        os.remove(temporary)
        return false, "settings replacement failed (Win32 " .. code .. ")"
    end
    return true
end

local function write32(address, value)
    if READ_ONLY then return false, "read-only probe" end
    local ptr = ffi.cast("void *", address)
    if kernel.VirtualQuery(ptr, mem_region, ffi.sizeof(mem_region[0])) ~= ffi.sizeof(mem_region[0]) then
        return false, "VirtualQuery failed"
    end
    local region = mem_region[0]
    local protection = tonumber(region.protection)
    local low = protection % 256
    if tonumber(region.state) ~= 0x1000 or tonumber(region.type) ~= 0x20000 then
        return false, "not a committed private data page"
    end
    if protection >= 0x100 or (low ~= 0x02 and low ~= 0x04 and low ~= 0x08) then
        return false, "not a safe non-executable data page"
    end
    local flipped = low ~= 0x04
    if flipped and kernel.VirtualProtect(ptr, 4, 0x04, old_protect) == 0 then
        return false, "VirtualProtect failed"
    end
    word[0] = value
    local ok = kernel.WriteProcessMemory(process, ptr, word, 4, written) ~= 0
        and tonumber(written[0]) == 4
    local restored = not flipped or kernel.VirtualProtect(ptr, 4, old_protect[0], restore_protect) ~= 0
    if not restored then return false, "VirtualProtect restore failed" end
    if not ok or read32(address) ~= value then return false, "write/readback failed" end
    return true
end

local RUNTIME_MARKER = from_hex("080000000000000002000000")
local runtime_scan_buffer

local function runtime_record_ok(address, identity_only)
    if not address or address < 0x10000 or address > MAX_ADDRESS - 0x160 then return false end
    if read_bytes(address, #RUNTIME_MARKER) ~= RUNTIME_MARKER then return false end
    if read64(address - 8) ~= address - 0x48 or read32(address - 0x60) ~= 3 then return false end
    local first, second = read32(address + 0x38), read32(address + 0x148)
    return first ~= nil and first == second and HELMET_IDS[first]
        and (identity_only or PASSIVE_IDS[read32(address + 0x6c)] == true)
end

local function lookup_runtime_record()
    if runtime_record_ok(M.runtime_header) then return M.runtime_header end
    M.runtime_header = nil
    local slot = C.address(0x3326e68, 8)
    if not slot then return nil, "game.dll layout unavailable" end
    local dispatch = read64(slot)
    if not dispatch or dispatch < 0x10000 or dispatch > MAX_ADDRESS then
        return nil, "UI dispatch unavailable"
    end
    if kernel.VirtualQuery(ffi.cast("const void *", dispatch), mem_region,
        ffi.sizeof(mem_region[0])) ~= ffi.sizeof(mem_region[0]) then
        return nil, "UI arena lookup failed"
    end
    local arena = tonumber(ffi.cast("uintptr_t", mem_region[0].allocation_base))
    if not arena or arena < 0x10000 or arena > MAX_ADDRESS then
        return nil, "UI arena base invalid"
    end
    if kernel.VirtualQuery(ffi.cast("const void *", arena), mem_region,
        ffi.sizeof(mem_region[0])) ~= ffi.sizeof(mem_region[0]) then
        return nil, "UI arena extent unavailable"
    end
    local region = mem_region[0]
    local length = tonumber(region.size)
    local low = tonumber(region.protection) % 256
    if tonumber(region.state) ~= 0x1000 or tonumber(region.type) ~= 0x20000
        or (low ~= 0x02 and low ~= 0x04 and low ~= 0x08)
        or length < 0x100000 or length > 0x10000000 then
        return nil, "UI arena layout changed"
    end
    if not runtime_scan_buffer then runtime_scan_buffer = ffi.new("uint8_t[?]", 0x100200) end
    local found, count = nil, 0
    for offset = 0, length - 1, 0x100000 do
        local amount = math.min(0x100200, length - offset)
        if kernel.ReadProcessMemory(process, ffi.cast("const void *", arena + offset),
            runtime_scan_buffer, amount, got) == 0 or tonumber(got[0]) ~= amount then
            return nil, "UI arena scan incomplete"
        else
            local data = search.prepare(runtime_scan_buffer, amount, RUNTIME_MARKER)
            local at = 1
            while true do
                local pos = search.find(data, at)
                if not pos then break end
                local address = arena + offset + pos - 1
                if (pos <= 0x100000 or offset + 0x100000 >= length)
                    and runtime_record_ok(address) then
                    found, count = address, count + 1
                    if count > 1 then return nil, "multiple live helmet records" end
                end
                at = pos + 1
            end
        end
    end
    if count ~= 1 then return nil, "live helmet record not found" end
    if not runtime_record_ok(found) then return nil, "live helmet record changed during scan" end
    M.runtime_header = found
    note(string.format("live helmet record found at 0x%x", found))
    return found
end

local function find_runtime_record()
    local ok, result, why = pcall(lookup_runtime_record)
    if not ok then
        M.runtime_header = nil
        return nil, "runtime lookup error: " .. tostring(result):sub(1, 120)
    end
    return result, why
end

local function restore_runtime(address, before)
    if not runtime_record_ok(address, true) then return 1 end
    if read32(address + 0x6c) == before then return 0 end
    return write32(address + 0x6c, before) and 0 or 1
end

local compatibility_ready

local function refresh_runtime(value)
    if READ_ONLY then return false, "read-only probe" end
    if compatibility_ready then
        local ready, reason = compatibility_ready()
        if not ready then return false, "compatibility: " .. reason end
    end
    local address, why = find_runtime_record()
    if not address then M.runtime_status = why; return false, why end
    local field = address + 0x6c
    local before = read32(field)
    if not before or not PASSIVE_IDS[before] then
        M.runtime_status = "unexpected cached passive"
        return false, M.runtime_status
    end
    if not runtime_record_ok(address) then
        M.runtime_header = nil
        M.runtime_status = "live helmet record changed before write"
        return false, M.runtime_status
    end
    if before ~= value then
        local ok, error_text = write32(field, value)
        if not ok then
            local rollback_failed = restore_runtime(address, before)
            M.runtime_status = error_text
            return false, error_text .. "; runtime rollback failures=" .. rollback_failed
        end
    end
    M.runtime_status = string.format("kit 0x%08x passive %d -> %d", read32(address + 0x38), before, value)
    note("runtime " .. M.runtime_status)
    return true, nil, before, address
end

local function restore_fields(base, before, changed)
    local failed = 0
    for j = #changed, 1, -1 do
        local k = changed[j]
        local address = base + HELMET_FIELDS[k][1]
        if read32(address) ~= before[k] and not write32(address, before[k]) then
            failed = failed + 1
        end
    end
    return failed
end

local function apply_passive(value, save)
    if READ_ONLY then return false, "read-only probe" end
    if compatibility_ready then
        local ready, reason = compatibility_ready()
        if not ready then return false, "compatibility: " .. reason end
    end
    if not PASSIVE_IDS[value] then return false, "unknown passive ID" end
    local base = M.base
    if not base or not table_header_ok(base) then
        M.base = nil
        M.next_address = 0x10000
        M.phase = "finding armor table"
        return false, "armor table is unavailable"
    end
    local supported, reason = C.source(base, false)
    if not supported then return false, reason end
    local valid, why = table_fields_ok(base, M.applied)
    if not valid then return false, why end
    local before = {}
    for i = 1, #HELMET_FIELDS do
        before[i] = read32(base + HELMET_FIELDS[i][1])
        if before[i] == nil then return false, "read failed before write" end
    end
    local changed = {}
    for i = 1, #HELMET_FIELDS do
        if before[i] ~= value then
            -- A write can succeed even when its readback fails. Include this
            -- field in rollback before calling write32.
            changed[#changed + 1] = i
            local ok, error_text = write32(base + HELMET_FIELDS[i][1], value)
            if not ok then
                local rollback_failed = restore_fields(base, before, changed)
                return false, string.format("field %d failed: %s; rollback failures=%d", i, error_text, rollback_failed)
            end
        end
    end
    if save then
        local refreshed, error_text, runtime_before, runtime_address = refresh_runtime(value)
        if not refreshed then
            local rollback_failed = restore_fields(base, before, changed)
            return false, string.format("runtime refresh: %s; rollback failures=%d", error_text, rollback_failed)
        end
        local saved, save_error = write_config(value)
        if not saved then
            local runtime_failed = restore_runtime(runtime_address, runtime_before)
            local fields_failed = restore_fields(base, before, changed)
            M.runtime_status = runtime_failed == 0 and "restored after config save failure"
                or "restore failed after config save failure"
            return false, string.format("config save: %s; runtime rollback failures=%d; field rollback failures=%d",
                save_error, runtime_failed, fields_failed)
        end
    end
    M.applied = value
    M.selected = value
    M.phase = "active"
    note(string.format("passive ID %d written to %d helmet fields", value, #changed))
    log()
    return true
end

local function locate_step()
    if M.base then return end
    local processed = 0
    while M.next_address < MAX_ADDRESS and processed < 160 do
        local at = M.next_address
        if kernel.VirtualQuery(ffi.cast("const void *", at), mem_region, ffi.sizeof(mem_region[0])) ~= ffi.sizeof(mem_region[0]) then
            M.phase = "armor table not found"
            return
        end
        local region = mem_region[0]
        local base = tonumber(ffi.cast("uintptr_t", region.base))
        local length = tonumber(region.size)
        M.next_address = base + math.max(length, 4096)
        if M.next_address <= at then M.phase = "memory scan stopped"; return end
        local low = tonumber(region.protection) % 256
        if tonumber(region.state) == 0x1000 and tonumber(region.type) == 0x20000
            and (low == 0x02 or low == 0x04 or low == 0x08)
            and length >= 92 and read_bytes(base + 4, 4) == "LDLD" and read32(base + 12) == 0xd9a55aa0 then
            local good, why = C.source(base, true)
            if good then good, why = table_fields_ok(base, 0) end
            if good then
                M.base = base
                M.phase = "armor table verified"
                note("armor table found and all " .. #HELMET_FIELDS .. " helmet fields verified")
                log()
                if READ_ONLY then
                    M.phase = "read-only source verified"
                    C.capture("source")
                elseif M.selected ~= 0 then
                    local ok, err = apply_passive(M.selected, false)
                    if not ok then M.phase = "apply failed: " .. err; note(M.phase); log(true)
                    else M.runtime_pending = true end
                end
                return
            else
                note("armor marker matched but fields were rejected: " .. why)
            end
        end
        processed = processed + 1
    end
    if M.next_address >= MAX_ADDRESS then M.phase = "armor table not found" end
end

local s3d = rawget(_G, "s3d") or rawget(_G, "stingray")
local SHIP_TABLE_HASH = "3b9bcf29e38da0a6"
local GUI = { layers = {}, instance = nil, rects = {}, texts = {}, buttons = {}, font = nil,
    cleanup_pending = false,
    native_font = nil,
    ship_world = nil }
local ui_state = { visible = false, highlight = 1, page = 1, redraw = true,
    old_cursor = nil, loadout_cursor = false, lang = "en", missing_frames = 0,
    capture = nil, hotkey_latched = false, hotkey_message = "ready", actions_allowed = false }

local function call(func, ...)
    -- Stingray constructors such as Vector2/Vector3/Color may be callable tables.
    if func == nil then return nil end
    local ok, a, b, c = pcall(func, ...)
    if ok then notices[func] = nil; return a, b, c end
    notice(func, "GUI call failed: " .. tostring(a):sub(1, 120))
    return nil
end

local input_cache = setmetatable({}, {__mode = "k"})
local function input_id(device, category, name, fallback)
    if not device then return nil end
    local resolver = device[category .. "_id"] or device[category .. "_index"]
    local device_cache = input_cache[device]
    if not device_cache then device_cache = {}; input_cache[device] = device_cache end
    local cache = device_cache[category]
    if not cache or cache.resolver ~= resolver then
        cache = {resolver = resolver, ids = {}}
        device_cache[category] = cache
    end
    local index = cache.ids[name]
    if index == nil then
        index = call(resolver, name)
        if index ~= nil then cache.ids[name] = index end
    end
    return index or fallback
end

local function key_pressed(name, fallback)
    local keyboard = s3d and s3d.Keyboard
    if not keyboard or not keyboard.pressed then return false end
    local index = input_id(keyboard, "button", name, fallback)
    return index ~= nil and call(keyboard.pressed, index) == true
end

local function focused_game()
    local window = user.GetForegroundWindow()
    if window == nil then return false end
    window_pid[0] = 0
    if user.GetWindowThreadProcessId(window, window_pid) == 0 then return false end
    return tonumber(window_pid[0]) == process_id
end

local function f_key_down(number)
    return tonumber(user.GetAsyncKeyState(111 + number)) < 0
end

local function capture_status(message)
    if ui_state.hotkey_message ~= message then ui_state.redraw = true end
    ui_state.hotkey_message = message
end

local function cancel_capture()
    if not ui_state.capture or ui_state.capture == "release_after" then return end
    ui_state.capture = "release_after"
    capture_status("cancelled")
    M.hotkey_status = "capture cancelled"
    log()
end

local function save_hotkey(value)
    local ok, reason = write_hotkey(value)
    if ok then
        M.hotkey = value
        M.hotkey_config_error = nil
        M.hotkey_status = "saved " .. value:upper()
        capture_status("saved")
        note("menu hotkey saved: " .. value:upper())
        log()
    else
        M.hotkey_status = reason
        capture_status("failed")
        note("menu hotkey save failed: " .. reason)
        log(true)
    end
    ui_state.capture = "release_after"
    ui_state.hotkey_latched = true
    ui_state.redraw = true
end

local function capture_tick()
    local count, pressed = 0, nil
    for number = 1, 12 do
        if f_key_down(number) then count, pressed = count + 1, number end
    end
    if ui_state.capture == "release_before" or ui_state.capture == "release_after" then
        if count == 0 then
            if ui_state.capture == "release_before" then
                ui_state.capture = "capture"
                capture_status("capture")
            else
                ui_state.capture = nil
                ui_state.hotkey_latched = false
            end
        end
    elseif count > 1 then
        ui_state.capture = "release_before"
        capture_status("multiple")
    elseif count == 1 then
        save_hotkey("f" .. pressed)
    end
end

local function worlds()
    if not s3d or not s3d.Application then return nil end
    local list = call(s3d.Application.worlds)
    if type(list) == "table" then return list end
    return nil
end

local function world_present(list, world)
    for i = 1, #(list or {}) do if list[i] == world then return true end end
    return false
end

local function clear_gui(can_destroy)
    if can_destroy and s3d and s3d.Gui then
        for _, layer in ipairs(GUI.layers) do
            for i = #layer.rects, 1, -1 do call(s3d.Gui.destroy_rect, layer.instance, layer.rects[i]) end
            for i = #layer.texts, 1, -1 do call(s3d.Gui.destroy_text, layer.instance, layer.texts[i]) end
            layer.rects, layer.texts = {}, {}
        end
    end
    GUI.rects, GUI.texts, GUI.buttons = {}, {}, {}
end

local function release_gui(list)
    if type(list) ~= "table" then
        -- Unknown worlds may still own live GUIs. Retain their handles until a
        -- later world list tells us which instances are safe to destroy.
        GUI.cleanup_pending = #GUI.layers > 0
        GUI.instance = nil
        GUI.rects, GUI.texts, GUI.buttons = {}, {}, {}
        return
    end
    for _, layer in ipairs(GUI.layers) do
        if world_present(list, layer.world) then
            for i = #layer.rects, 1, -1 do call(s3d.Gui.destroy_rect, layer.instance, layer.rects[i]) end
            for i = #layer.texts, 1, -1 do call(s3d.Gui.destroy_text, layer.instance, layer.texts[i]) end
            if s3d.World and s3d.World.destroy_gui then
                call(s3d.World.destroy_gui, layer.world, layer.instance)
            end
        end
    end
    GUI.layers, GUI.instance = {}, nil
    GUI.rects, GUI.texts, GUI.buttons = {}, {}, {}
    GUI.cleanup_pending = false
end

local function finish_gui_cleanup()
    local list = worlds()
    if list then
        release_gui(list)
        note("deferred GUI cleanup completed")
    end
end

local function draw_rect(x, y, w, h, r, g, b, a)
    local position = call(s3d.Vector3, x, y, 900)
    local size = call(s3d.Vector2, w, h)
    local color = call(s3d.Color, a or 255, r, g, b)
    assert(position and size and color, "GUI geometry constructors unavailable")
    local id = call(s3d.Gui.rect, GUI.instance, position, size, color)
    assert(id ~= nil, "GUI rectangle creation failed")
    if id ~= nil then GUI.rects[#GUI.rects + 1] = id end
end

local function draw_text(text, x, y, size, r, g, b)
    assert(GUI.font or GUI.native_font, "GUI font unavailable")
    local position = call(s3d.Vector3, x, y, 902)
    local color = call(s3d.Color, 255, r or 255, g or 255, b or 255)
    assert(position and color, "GUI text constructors unavailable")
    local font, material = GUI.font, GUI.font
    if GUI.native_font then
        -- Engine IDs only survive the current frame. Keep their hashes as strings.
        font = call(s3d.IdString64.from_hex, GUI.native_font.font)
        material = call(s3d.IdString64.from_hex, GUI.native_font.material)
        assert(font and material, "GUI font resource IDs unavailable")
    end
    local id = call(s3d.Gui.text, GUI.instance, text, font, size, material, position, color)
    assert(id ~= nil, "GUI text creation failed")
    if id ~= nil then GUI.texts[#GUI.texts + 1] = id end
end

local function button(label, x, y, w, h, action, selected)
    draw_rect(x, y, w, h, selected and 38 or 25, selected and 101 or 45, selected and 140 or 60, 245)
    draw_text(label, x + 12, y + 8, 20)
    GUI.buttons[#GUI.buttons + 1] = {x, y, w, h, action}
end

local function active_font_hashes()
    local image = C.game()
    if not image then return nil, "game.dll layout unavailable" end
    local base = image.base
    if not C.address(0x3772268, 8) or not C.address(0x37c5478, 8) or not C.address(0x3772ee8, 8) then
        return nil, "font slots outside game.dll"
    end
    local function hash(address)
        local lo, hi = read32(address), read32(address + 4)
        if not lo or not hi or (lo == 0 and hi == 0) then return nil end
        return string.format("%08x%08x", hi, lo)
    end
    local lo, hi = read32(base + 0x37c5478), read32(base + 0x37c547c)
    if not lo or not hi then return nil, "font material pointer unavailable" end
    local material_pointer = lo + hi * 0x100000000
    if material_pointer < 0x10000 or material_pointer > MAX_ADDRESS then
        return nil, "invalid font material pointer"
    end
    local font = hash(base + 0x3772268)
    local material = hash(material_pointer + 24)
    local atlas = hash(base + 0x3772ee8)
    if not font or not material or not atlas then return nil, "active locale font unavailable" end
    return {font = font, material = material, atlas = atlas}
end

compatibility_ready = function()
    if not C.game() or not C.interfaces(s3d, true) then return false, "required game interfaces unavailable" end
    if not C.input_entry(INPUT_CONSUME_PREFIX, INPUT_CONSUME_RVA) then return false, "native input entry unavailable" end
    local slot = C.address(INPUT_OWNER_RVA, 8)
    local owner = slot and read64(slot)
    if not owner or not C.input_owner(owner) then return false, "native input object unavailable" end
    if M.language == "cn" then
        local resources, why = active_font_hashes()
        if not resources then C.set("font", why); return false, why end
        for name, kind in pairs({font = "font", material = "material", atlas = "texture"}) do
            local id = call(s3d.IdString64.from_hex, resources[name])
            if not id or call(s3d.Application.can_get, kind, id) ~= true then
                C.set("font", "native locale " .. name .. " unavailable")
                return false, "native locale " .. name .. " unavailable"
            end
        end
        for _, name in ipairs({"set_scalar", "set_vector2", "set_vector4", "set_texture"}) do
            if not s3d.Material or not C.callable(s3d.Material[name]) then
                local reason = "font Material." .. name .. " unavailable"
                C.set("font", reason); return false, reason
            end
        end
        if not C.callable(s3d.Gui.material) then
            C.set("font", "font material API unavailable"); return false, "font material API unavailable"
        end
        C.set("font", "native locale resources available; rendering requires live verification")
    end
    return true
end

local function pick_debug_font()
    if not s3d or not s3d.Application or not s3d.Application.can_get then return false end
    local candidates = {"core/performance_hud/debug", "core/editor_slave/gui/arial"}
    for _, name in ipairs(candidates) do
        local font = call(s3d.Application.can_get, "font", name)
        local material = call(s3d.Application.can_get, "material", name)
        if font and material then GUI.font = name; note("GUI font: " .. name); return true end
    end
    return false
end

local function pick_font()
    if ui_state.lang == "cn" and not GUI.native_font then
        local native, reason = active_font_hashes()
        if native then
            GUI.font = nil
            GUI.native_font = native
            note("GUI native font: " .. native.font .. " material: " .. native.material
                .. " atlas: " .. native.atlas)
            return true
        end
        note("GUI native font unavailable: " .. reason)
    end
    if GUI.font or GUI.native_font then return true end
    return pick_debug_font()
end

local function setup_native_font(instance)
    local ids = GUI.native_font
    if not ids then return true end
    local ok, reason = pcall(function()
        local make_id = s3d.IdString64.from_hex
        local material = make_id(ids.material)
        local ink = assert(s3d.Gui.material(instance, material), "font material unavailable")
        local function slot(hash) return make_id(hash .. "00000000") end
        for _, hash in ipairs({"8035c266", "5e8455fe", "309e7783", "82b803a8"}) do
            s3d.Material.set_scalar(ink, slot(hash), 0)
        end
        s3d.Material.set_vector2(ink, slot("e13777ce"), s3d.Vector2(1, -1))
        s3d.Material.set_vector4(ink, slot("7701209e"), s3d.Color(0, 0, 0, 0))
        s3d.Material.set_texture(ink, slot("88bac99b"), make_id(ids.atlas))
    end)
    if not ok then note("GUI native font setup failed: " .. tostring(reason):sub(1, 180)) end
    return ok
end

local function loadout_screen_active()
    if not M.base then return false end
    local image = C.game()
    if not image then return false end
    local base = image.base
    if not C.address(0x347ce38, 8) then return false end
    -- The native pre-drop loadout screen is type 11 in the current build.
    local lo, hi = read32(base + 0x347ce38), read32(base + 0x347ce3c)
    if not lo or not hi then return false end
    local stack = lo + hi * 0x100000000
    if stack < 0x10000 or stack > MAX_ADDRESS then return false end
    return read32(stack) == 11
end

local function scene_allowed(list)
    if type(list) ~= "table" then return false, "world list unavailable" end
    if not s3d or not s3d.IdString64 or not s3d.World
        or not s3d.IdString64.from_hex or not s3d.World.units_by_resource then
        return false, "ship-world lookup API unavailable"
    end
    -- IdString64 values are temporary and must be recreated in each frame.
    local ship_id = call(s3d.IdString64.from_hex, SHIP_TABLE_HASH)
    if not ship_id then return false, "ship resource ID unavailable" end
    local function has_table(world)
        local units = call(s3d.World.units_by_resource, world, ship_id)
        return type(units) == "table" and next(units) ~= nil
    end
    if GUI.ship_world and world_present(list, GUI.ship_world) and has_table(GUI.ship_world) then
        return true, "galaxy table present"
    end
    GUI.ship_world = nil
    for _, world in ipairs(list) do
        if has_table(world) then
            GUI.ship_world = world
            return true, "galaxy table present"
        end
    end
    return false, "galaxy table absent"
end

local function menu_open()
    if READ_ONLY or not C.interfaces(s3d, true) then return false end
    local list = worlds()
    if not list then return false end
    if GUI.cleanup_pending then release_gui(list) end
    local allowed, reason = scene_allowed(list)
    if not allowed then
        M.scene_status = M.hotkey:upper() .. " ignored: " .. reason .. " (" .. #list .. " worlds)"
        note(M.scene_status)
        log()
        return false
    end
    if M.base and C.source_base ~= M.base then
        local supported, why = C.source(M.base, true)
        if not supported then M.phase = "compatibility failed: " .. why; log(); return false end
    end
    if not input_capture_ready() then
        note("menu input capture unavailable: " .. M.native_input_status)
        log()
        return false
    end
    if not consume_native_menu() then
        note("menu input capture failed: " .. M.native_input_status)
        log()
        return false
    end
    local lang = game_language()
    if ui_state.lang ~= lang then GUI.font, GUI.native_font = nil, nil end
    ui_state.lang = lang
    note("Game language: " .. lang)
    local main = call(s3d.Application.main_world)
    local host = list[2]
    if not host or not pick_font() then
        M.gui_status = "GUI world or font unavailable"
        log()
        return false
    end
    local candidates = {{host, "world-2"}}
    if main and main ~= host and world_present(list, main) then
        candidates[#candidates + 1] = {main, "main-world"}
    end
    for _, candidate in ipairs(candidates) do
        local instance = call(s3d.World.create_screen_gui, candidate[1], 0, 0, "scale", 1, 1)
        if instance then
            if s3d.Gui and s3d.Gui.set_visible then call(s3d.Gui.set_visible, instance, true) end
            GUI.layers[#GUI.layers + 1] = {
                world = candidate[1], instance = instance, name = candidate[2], rects = {}, texts = {}
            }
        end
    end
    if #GUI.layers == 0 then M.gui_status = "create_screen_gui failed"; log(); return false end
    if GUI.native_font then
        for _, layer in ipairs(GUI.layers) do
            if not setup_native_font(layer.instance) then
                GUI.native_font = nil
                if not pick_debug_font() then
                    M.gui_status = "native and fallback fonts unavailable"
                    release_gui(list)
                    log()
                    return false
                end
                break
            end
        end
    end
    note(string.format("GUI API types: Vector2=%s Vector3=%s Color=%s rect=%s text=%s",
        type(s3d.Vector2), type(s3d.Vector3), type(s3d.Color),
        type(s3d.Gui and s3d.Gui.rect), type(s3d.Gui and s3d.Gui.text)))
    ui_state.visible = true
    ui_state.capture = nil
    ui_state.hotkey_message = M.hotkey_config_error and "invalid" or "ready"
    ui_state.missing_frames = 0
    M.visible = true
    M.scene_status = "menu opened: " .. reason .. " (" .. #list .. " worlds)"
    if s3d.Window and s3d.Window.show_cursor then ui_state.old_cursor = call(s3d.Window.show_cursor) end
    ui_state.loadout_cursor = loadout_screen_active()
    note("cursor before menu: " .. tostring(ui_state.old_cursor)
        .. "; loadout screen: " .. tostring(ui_state.loadout_cursor))
    if s3d.Window and s3d.Window.set_show_cursor then call(s3d.Window.set_show_cursor, true) end
    ui_state.redraw = true
    note(M.scene_status)
    log()
    return true
end

local function menu_close()
    ui_state.actions_allowed = false
    cancel_capture()
    local list = worlds()
    release_gui(list)
    local keep_loadout_cursor = ui_state.loadout_cursor and loadout_screen_active()
    if (ui_state.old_cursor ~= nil or keep_loadout_cursor)
        and s3d and s3d.Window and s3d.Window.set_show_cursor then
        call(s3d.Window.set_show_cursor, keep_loadout_cursor or ui_state.old_cursor)
    end
    ui_state.visible, M.visible = false, false
    ui_state.capture = nil
    ui_state.hotkey_latched = true
    M.native_input_status = "idle"
    ui_state.old_cursor = nil
    ui_state.loadout_cursor = false
    note("cursor after menu: " .. tostring(call(s3d.Window and s3d.Window.show_cursor))
        .. "; kept for loadout: " .. tostring(keep_loadout_cursor))
    note("menu closed")
    log()
end

local function redraw()
    if #GUI.layers == 0 or not s3d or not s3d.Gui then return end
    clear_gui(true)
    local width, height = call(s3d.Gui.resolution)
    if type(width) ~= "number" or type(height) ~= "number" then return end
    local x = math.floor((width - 680) / 2)
    local y = math.floor((height - 600) / 2)
    M.box = {x, y, 680, 600}
    local summary = {}
    for _, layer in ipairs(GUI.layers) do
    GUI.instance, GUI.rects, GUI.texts = layer.instance, layer.rects, layer.texts
    draw_rect(x, y, 680, 600, 8, 15, 23, 240)
    draw_rect(x + 8, y + 8, 664, 584, 14, 24, 35, 240)
    local zh = ui_state.lang == "cn" and GUI.native_font ~= nil
    draw_text(zh and "额外护甲被动" or "EXTRA ARMOR PASSIVE", x + 28, y + 555, 29, 240, 220, 160)
    local active_name = PASSIVES[1][zh and 3 or 2]
    for _, entry in ipairs(PASSIVES) do
        if entry[1] == M.applied then active_name = entry[zh and 3 or 2]; break end
    end
    local status = M.base and (zh and "已就绪" or "Ready") or (zh and "加载中" or "Loading")
    if M.phase:find("^apply failed:") then status = zh and "应用失败, 请查看日志" or "Apply failed; check log" end
    draw_text((zh and "当前: " or "Current: ") .. active_name .. "    " .. status,
        x + 28, y + 522, 17, 180, 205, 220)
    draw_text((zh and "打开菜单: " or "MENU KEY: ") .. M.hotkey:upper(), x + 28, y + 472, 20)
    button(zh and "修改快捷键" or "CHANGE KEY", x + 300, y + 464, 170, 36, {"hotkey"})
    button(zh and "恢复 F9" or "RESET F9", x + 482, y + 464, 170, 36, {"hotkey_reset"})
    local messages = {
        ready = {"Choose F1-F12 as the menu key.", "可设置 F1-F12 单键打开菜单."},
        waiting = {"Release all F keys first; Esc cancels.", "请先松开所有 F 键; Esc 取消."},
        capture = {"Press F1-F12 to bind; Esc cancels.", "按 F1-F12 设置; Esc 取消."},
        multiple = {"Press one F key at a time; release to retry.", "请一次按一个 F 键; 松开后重试."},
        saved = {"Key saved. Release F keys to continue.", "快捷键已保存. 松开 F 键后继续."},
        failed = {"Save failed; previous key kept. Check log.", "保存失败, 已保留原快捷键; 请查看日志."},
        cancelled = {"Key change cancelled.", "已取消修改快捷键."},
        invalid = {"Invalid settings; using F9. Change key to repair.", "配置无效, 使用 F9; 修改快捷键可重新保存."},
    }
    local message = messages[ui_state.hotkey_message] or messages.ready
    draw_text(message[zh and 2 or 1], x + 28, y + 432, 16, 180, 205, 220)
    local first = (ui_state.page - 1) * 8 + 1
    for row = 0, 7 do
        local index = first + row
        local entry = PASSIVES[index]
        if entry then
            local label = string.format("%02d  %s", entry[1], zh and entry[3] or entry[2])
            button(label, x + 28, y + 386 - row * 43, 624, 38,
                {"select", index}, ui_state.highlight == index)
        end
    end
    button(zh and "上页" or "PREV", x + 28, y + 18, 110, 40, {"prev"})
    button(zh and "下页" or "NEXT", x + 150, y + 18, 110, 40, {"next"})
    button(zh and "确认" or "APPLY", x + 395, y + 18, 120, 40, {"apply"})
    button(zh and "关闭" or "CLOSE", x + 527, y + 18, 125, 40, {"close"})
    draw_text(string.format(zh and "第 %d / %d 页" or "Page %d / %d", ui_state.page, math.ceil(#PASSIVES / 8)),
        x + 278, y + 28, 18)
    summary[#summary + 1] = string.format("%s rect=%d text=%d", layer.name, #layer.rects, #layer.texts)
    end
    M.gui_status = string.format("drawn %dx%d: %s", width, height, table.concat(summary, "; "))
    C.set("gui", "draw calls succeeded; visual behavior requires live verification")
    note(M.gui_status)
    log()
    ui_state.redraw = false
end

local function action(which)
    local operation, arg = which[1], which[2]
    if operation ~= "close" and (not ui_state.actions_allowed or ui_state.capture) then return end
    if operation == "select" then ui_state.highlight = arg; ui_state.redraw = true
    elseif operation == "prev" then ui_state.page = math.max(1, ui_state.page - 1); ui_state.redraw = true
    elseif operation == "next" then ui_state.page = math.min(math.ceil(#PASSIVES / 8), ui_state.page + 1); ui_state.redraw = true
    elseif operation == "close" then menu_close()
    elseif operation == "hotkey" then
        ui_state.capture = "release_before"
        capture_status("waiting")
        M.hotkey_status = "capturing F1-F12"
        log()
    elseif operation == "hotkey_reset" then save_hotkey("f9")
    elseif operation == "apply" then
        local value = PASSIVES[ui_state.highlight][1]
        local ok, why = apply_passive(value, true)
        if not ok then M.phase = "apply failed: " .. why; note(M.phase); log(true) end
        ui_state.redraw = true
    end
end

local function mouse_action()
    if not s3d.Mouse then return end
    local mouse = s3d.Mouse
    local left = input_id(mouse, "button", "left")
    if left == nil or call(mouse.pressed, left) ~= true then return end
    local cursor = input_id(mouse, "axis", "cursor")
    if cursor == nil then return end
    local point = call(mouse.axis, cursor)
    if not point then return end
    local x = call(s3d.Vector3.x, point)
    local y = call(s3d.Vector3.y, point)
    if type(x) ~= "number" or type(y) ~= "number" then
        note("mouse click detected, but cursor position was unavailable")
        log()
        return
    end
    for i = 1, #GUI.buttons do
        local item = GUI.buttons[i]
        if x >= item[1] and x <= item[1] + item[3]
            and y >= item[2] and y <= item[2] + item[4] then
            note(string.format("mouse clicked %s at %.0f,%.0f", item[5][1], x, y))
            action(item[5])
            return
        end
    end
    note(string.format("mouse clicked outside menu at %.0f,%.0f", x, y))
    log()
end

local function ui_tick()
    ui_state.actions_allowed = false
    if not s3d then return end
    local capturing = ui_state.capture ~= nil
    local hotkey_number = tonumber(M.hotkey:sub(2))
    local pressed = not capturing and key_pressed(M.hotkey, 111 + hotkey_number)
    -- A closed, idle menu needs no foreground or physical-key polling.
    if (ui_state.visible or pressed) and not focused_game() then
        if ui_state.capture then cancel_capture() end
        ui_state.hotkey_latched = true
        if ui_state.visible and ui_state.redraw then redraw() end
        return
    end
    if not capturing then
        if ui_state.hotkey_latched and not f_key_down(hotkey_number) then ui_state.hotkey_latched = false end
        if pressed and not ui_state.hotkey_latched then
            ui_state.hotkey_latched = true
            if ui_state.visible then menu_close() else menu_open() end
        end
    end
    if not ui_state.visible then return end
    if not consume_native_menu() then menu_close(); return end
    local list = worlds()
    if not list then
        menu_close()
        return
    end
    local allowed = scene_allowed(list)
    if not allowed then
        if ui_state.capture then cancel_capture() end
        ui_state.missing_frames = ui_state.missing_frames + 1
        if ui_state.missing_frames >= 5 then menu_close(); return end
    else
        ui_state.missing_frames = 0
    end
    for _, layer in ipairs(GUI.layers) do
        if not world_present(list, layer.world) then menu_close(); return end
    end
    ui_state.actions_allowed = allowed
    if not allowed then
        -- Keep the visual grace period, but accept only closing inputs.
        if key_pressed("escape", 27) then menu_close(); return end
    elseif capturing then
        if key_pressed("escape", 27) then cancel_capture() else capture_tick() end
    else
        if key_pressed("escape", 27) then menu_close(); return end
        if key_pressed("left", 37) then action({"prev"}) end
        if key_pressed("right", 39) then action({"next"}) end
        if key_pressed("up", 38) then
            ui_state.highlight = math.max(1, ui_state.highlight - 1)
            ui_state.page = math.floor((ui_state.highlight - 1) / 8) + 1
            ui_state.redraw = true
        end
        if key_pressed("down", 40) then
            ui_state.highlight = math.min(#PASSIVES, ui_state.highlight + 1)
            ui_state.page = math.floor((ui_state.highlight - 1) / 8) + 1
            ui_state.redraw = true
        end
        if key_pressed("enter", 13) then action({"apply"}) end
    end
    if ui_state.redraw then redraw() end
    mouse_action()
    if ui_state.visible and ui_state.loadout_cursor and s3d.Window and s3d.Window.show_cursor
        and s3d.Window.set_show_cursor and call(s3d.Window.show_cursor) == false then
        call(s3d.Window.set_show_cursor, true)
    end
end

M.selected = read_config()
M.language = game_language()
note("saved passive ID " .. M.selected)
M.hotkey, M.hotkey_config_error = read_hotkey()
M.hotkey_status = M.hotkey_config_error or "loaded " .. M.hotkey:upper()
if M.hotkey_config_error then note("settings fallback to F9: " .. M.hotkey_config_error) end
C.interfaces(s3d)
C.game()
update_time()
log(true)

local function tick()
    if M.failed then return end
    M.frame = M.frame + 1
    update_time()
    if not C.interfaces(s3d) or not C.game() then
        if ui_state.visible then menu_close() end
        flush_log(false)
        return
    end
    if M.frame >= 120 and not M.base and M.frame % 3 == 0 then locate_step() end
    if READ_ONLY then
        if not M.probe_retry_ms or M.now_ms >= M.probe_retry_ms then
            M.probe_retry_ms = M.now_ms + 1000
            local ready, why = compatibility_ready()
            C.set("preflight", ready and "static dependencies checked; no gameplay certification" or why)
        end
        if M.base and M.now_ms >= M.runtime_retry_ms and scene_allowed(worlds()) then
            M.runtime_retry_ms = M.now_ms + 1000
            local before = M.runtime_header
            local address, why = find_runtime_record()
            M.runtime_status = address and "read-only record checked" or why
            C.set("runtime", M.runtime_status)
            if address and not before then C.capture("runtime") end
        end
        flush_log(false)
        return
    end
    if M.base and (M.runtime_pending or M.now_ms >= M.maintenance_ms) then
        M.runtime_pending = false
        M.maintenance_ms = M.now_ms + 1000
        if not table_header_ok(M.base) then
            M.base = nil
            M.next_address = 0x10000
            M.applied = 0
            M.phase = "armor table changed; searching again"
            note(M.phase)
            log(true)
        elseif M.selected ~= 0 then
            local ok, why, zero = table_fields_ok(M.base, M.applied)
            if not ok then
                notice("restore_attempt", nil)
                M.phase = "helmet fields changed externally: " .. why
                if notices.fields ~= M.phase then notice("fields", M.phase); log(true) end
            elseif zero > 0 then
                notice("fields", nil)
                notice("restore_attempt", "restoring " .. zero .. " reset helmet fields")
                local restored, error_text = apply_passive(M.selected, false)
                if not restored then
                    M.phase = "restore failed: " .. error_text
                    if notices.restore ~= M.phase then notice("restore", M.phase); log(true) end
                else notice("restore", nil); notice("restore_attempt", nil) end
            else
                if notices.fields or notices.restore or notices.restore_attempt then
                    notice("fields", nil); notice("restore", nil)
                    notice("restore_attempt", nil)
                    M.phase = "active"
                    note("helmet field maintenance recovered")
                end
                local allowed = scene_allowed(worlds())
                if allowed and (M.runtime_header or M.now_ms >= M.runtime_retry_ms) then
                    local header = M.runtime_header
                    local current = header and runtime_record_ok(header) and read32(header + 0x6c)
                    if current ~= M.selected then
                        local refreshed, error_text = refresh_runtime(M.selected)
                        if not refreshed then
                            M.runtime_status = error_text
                            M.runtime_retry_ms = M.now_ms + 1000
                            notice("runtime", "runtime refresh pending: " .. error_text)
                        else notice("runtime", nil) end
                    elseif notices.runtime then
                        notice("runtime", nil)
                        note("runtime maintenance recovered")
                    end
                end
            end
        end
    end
    ui_tick()
    flush_log(false)
end

local prior_update = rawget(_G, "update")
local function fail_update(prefix, err)
    if M.failed then return end
    local close_error
    if ui_state.visible or #GUI.layers > 0 then
        local closed, why = pcall(menu_close)
        if not closed then
            close_error = tostring(why):sub(1, 120)
            local cursor = ui_state.old_cursor
            if ui_state.loadout_cursor then
                local checked, active = pcall(loadout_screen_active)
                if checked and active then cursor = true end
            end
            ui_state.visible, M.visible = false, false
            M.native_input_status = "idle after error"
            local worlds_ok, list = pcall(worlds)
            pcall(release_gui, worlds_ok and list or nil)
            if cursor ~= nil and s3d and s3d.Window and s3d.Window.set_show_cursor then
                pcall(s3d.Window.set_show_cursor, cursor)
            end
        end
    end
    M.failed = true
    M.phase = prefix .. tostring(err):sub(1, 180)
    note(M.phase)
    if close_error then note("menu close error: " .. close_error) end
    log(true)
end

local function after_update(...)
    local ok, err = pcall(tick)
    if not ok then fail_update("module error: ", err) end
    return ...
end

local function after_prior_update(ok, ...)
    if not ok then
        fail_update("prior update error: ", select(1, ...))
        return
    end
    return after_update(...)
end

update = function(...)
    -- Cleanup must also run when our tick is disabled or a prior update keeps
    -- throwing. Neither state makes a retained GUI handle disposable.
    if GUI.cleanup_pending then
        local ok, why = pcall(finish_gui_cleanup)
        if not ok then fail_update("GUI cleanup error: ", why) end
    end
    if ui_state.visible then
        local ok, consumed
        if C.interfaces(s3d, true) then ok, consumed = pcall(consume_native_menu) end
        if not ok or not consumed then
            local closed, why = pcall(menu_close)
            if not closed then fail_update("input capture error: ", why) end
        end
    end
    if prior_update then return after_prior_update(pcall(prior_update, ...)) end
    return after_update()
end

local prior_shutdown = rawget(_G, "shutdown")
shutdown = function(...)
    if ui_state.visible then menu_close() end
    note("clean shutdown")
    log(true)
    if prior_shutdown then return prior_shutdown(...) end
end
