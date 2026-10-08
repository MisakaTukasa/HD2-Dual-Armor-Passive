-- Compatibility follows supported data contracts, never a build-number allowlist.
local C = (function()
    local C = {status = {}, max_blob = 0x1000000, retry_ms = 0}
    local bit = require("bit")
    local function status(name, value)
        if C.status[name] ~= value then
            C.status[name] = value
            notice("compat_" .. name, "compatibility " .. name .. ": " .. value)
        end
    end
    C.set = status
    M.compatibility = C.status
    local function callable(value)
        local kind = type(value)
        if kind == "function" or kind == "cdata" then return true end
        if kind ~= "table" and kind ~= "userdata" then return false end
        local meta = getmetatable(value)
        return type(meta) == "table" and type(meta.__call) == "function"
    end
    C.callable = callable
    local required = {
        {"Application", "worlds"}, {"Application", "main_world"}, {"Application", "can_get"},
        {"World", "units_by_resource"}, {"World", "create_screen_gui"}, {"World", "destroy_gui"},
        {"Gui", "resolution"}, {"Gui", "rect"}, {"Gui", "text"},
        {"Gui", "destroy_rect"}, {"Gui", "destroy_text"},
        {"Keyboard", "pressed"}, {"Mouse", "pressed"}, {"Mouse", "axis"},
        {"Window", "show_cursor"}, {"Window", "set_show_cursor"}, {"IdString64", "from_hex"},
    }
    local constructors = {"Vector2", "Vector3", "Color"}

    function C.game()
        if C.image then return C.image end
        local module = kernel.GetModuleHandleA("game.dll")
        if module == nil then status("module", "waiting for game.dll"); return nil end
        local base = tonumber(ffi.cast("uintptr_t", module))
        if not base or base < 0x10000 or base > MAX_ADDRESS - 0x10000 then return nil end
        local dos = read_bytes(base, 64)
        local pe = dos and read32(base + 60)
        if not dos or dos:sub(1, 2) ~= "MZ" or not pe or pe < 64 or pe > 4096
            or read_bytes(base + pe, 4) ~= "PE\0\0" or not read_into(base + pe + 4, 20) then
            status("module", "invalid or unreadable PE header"); return nil
        end
        local shorts = ffi.cast("uint16_t *", bytes)
        local machine, section_count, optional = tonumber(shorts[0]), tonumber(shorts[1]), tonumber(shorts[8])
        local stamp = tonumber(numbers[1])
        if machine ~= 0x8664 or section_count < 1 or section_count > 96 or optional < 64
            or optional > 4096 or not read_into(base + pe + 24, 64) then
            status("module", "unsupported PE machine or optional header"); return nil
        end
        local magic, length = tonumber(shorts[0]), tonumber(numbers[14])
        if magic ~= 0x20b or length < 0x10000 or length > 0x20000000 or base > MAX_ADDRESS - length then
            status("module", "unsupported PE format or image extent"); return nil
        end
        C.image = {base = base, length = length, section_count = section_count,
            sections = base + pe + 24 + optional, stamp = stamp}
        status("module", string.format("PE32+ checked; stamp %08X, image 0x%x; build is diagnostic", stamp, length))
        return C.image
    end

    function C.address(rva, length)
        local image = C.game()
        if image and rva >= 0 and length >= 1 and rva + length <= image.length then return image.base + rva end
    end

    function C.span(address, length, executable)
        if not address or address < 0x10000 or length < 1 or address > MAX_ADDRESS - length then return false end
        local finish, cursor, queries = address + length, address, 0
        while cursor < finish and queries < 32 do
            queries = queries + 1
            if kernel.VirtualQuery(ffi.cast("const void *", cursor), mem_region,
                ffi.sizeof(mem_region[0])) ~= ffi.sizeof(mem_region[0]) then return false end
            local region = mem_region[0]
            local base = tonumber(ffi.cast("uintptr_t", region.base))
            local size, protect = tonumber(region.size), tonumber(region.protection)
            local low = protect % 256
            if tonumber(region.state) ~= 0x1000 or protect >= 0x100 or base > cursor or base + size <= cursor then return false end
            if executable then
                if low ~= 0x20 and low ~= 0x40 and low ~= 0x80 then return false end
            elseif low ~= 2 and low ~= 4 and low ~= 8 then return false end
            cursor = math.min(finish, base + size)
        end
        return cursor == finish
    end

    function C.interfaces(api, force)
        if not force and C.api == api and M.now_ms < (C.api_retry or 0) then return C.api_ready end
        C.api, C.api_ready, C.api_retry = api, false, M.now_ms + 1000
        for _, entry in ipairs(required) do
            if not api or not api[entry[1]] or not callable(api[entry[1]][entry[2]]) then
                status("interfaces", "missing " .. entry[1] .. "." .. entry[2]); return false
            end
        end
        for _, name in ipairs(constructors) do
            if not callable(api[name]) then status("interfaces", "missing " .. name); return false end
        end
        if not callable(api.Keyboard.button_id or api.Keyboard.button_index)
            or not callable(api.Mouse.button_id or api.Mouse.button_index)
            or not callable(api.Mouse.axis_id or api.Mouse.axis_index) then
            status("interfaces", "input ID resolvers unavailable"); return false
        end
        status("interfaces", "required entries present; behavior checked on use")
        C.api_ready = true
        return true
    end

    -- The source contains count followed by 24-byte DL headers and payloads.
    -- Walk bounded headers to determine its extent, then parse one owned copy.
    function C.parse_source(base, region_length)
        local count = read32(base)
        if not count or count < 1 or count > 8192 then return nil, "invalid armor record count" end
        local limit, offset = math.min(region_length, C.max_blob), 4
        for _ = 1, count do
            if offset + 88 > limit or not read_into(base + offset, 24) then return nil, "incomplete armor record header" end
            if tonumber(numbers[0]) ~= 0x444c444c or tonumber(numbers[1]) ~= 1
                or tonumber(numbers[2]) ~= 0xd9a55aa0 or tonumber(numbers[4]) ~= 1 or tonumber(numbers[5]) ~= 0 then
                return nil, "unsupported armor record format"
            end
            local size = tonumber(numbers[3])
            if size < 64 or size % 8 ~= 0 or size > limit - offset - 24 then return nil, "armor payload out of bounds" end
            offset = offset + 24 + size
        end
        if not C.blob or C.blob_size < offset then
            C.blob, C.blob_size = ffi.new("uint8_t[?]", offset), offset
        end
        if kernel.ReadProcessMemory(process, ffi.cast("const void *", base), C.blob, offset, got) == 0
            or tonumber(got[0]) ~= offset then return nil, "incomplete armor table copy" end
        local u32 = ffi.cast("uint32_t *", C.blob)
        local function u(at) return tonumber(u32[at / 4]) end
        local function bounded64(at, maximum)
            if u(at + 4) ~= 0 then return nil end
            local value = u(at)
            return value <= maximum and value or nil
        end
        local address_mode
        local function record_offset(at, start, size)
            local high = u(at + 4)
            if high > 0x7fff then return nil end
            local value = u(at) + high * 0x100000000
            local relative, mode
            if value <= size then relative, mode = value, "offset"
            else relative, mode = value - (base + start), "pointer" end
            if relative < 0 or relative > size then return nil end
            if address_mode and address_mode ~= mode then return nil end
            address_mode = mode
            -- Loaded DL arrays contain absolute pointers. Convert only pointers
            -- inside this record to offsets, then inspect the owned table copy.
            return relative
        end
        if u(0) ~= count then return nil, "armor table changed while reading" end
        local fields, ids, headers, cursor = {}, {}, {}, 4
        for i = 1, count do
            if cursor + 88 > offset or u(cursor) ~= 0x444c444c or u(cursor + 4) ~= 1
                or u(cursor + 8) ~= 0xd9a55aa0 or u(cursor + 16) ~= 1 or u(cursor + 20) ~= 0 then
                return nil, "armor record changed while reading"
            end
            local size, start = u(cursor + 12), cursor + 24
            if size < 64 or size % 8 ~= 0 or start + size > offset then return nil, "invalid copied armor payload" end
            local kit, kind = u(start), u(start + 40)
            if kit == 0 or ids[kit] or kind > 2 or (u(start + 32) == 0 and u(start + 36) == 0) then
                return nil, "invalid or duplicate armor kit identity"
            end
            ids[kit] = true
            local body = record_offset(start + 48, start, size)
            local bodies = bounded64(start + 56, 16)
            if not body or not bodies or bodies < 1 or body < 64 or body % 8 ~= 0 or body + bodies * 24 > size then
                return nil, "invalid armor body array at record " .. i
            end
            for index = 0, bodies - 1 do
                local at = start + body + index * 24
                local pieces = record_offset(at + 8, start, size)
                local n = bounded64(at + 16, 64)
                if u(at) > 3 or not pieces or not n or n < 1 or pieces < body + bodies * 24
                    or pieces % 8 ~= 0 or pieces + n * 96 > size then
                    return nil, "invalid armor piece array at record " .. i
                end
                local helmet_piece = false
                for j = 0, n - 1 do
                    local piece = start + pieces + j * 96
                    local slot = u(piece + 8)
                    if slot > 9 or u(piece + 12) > 2 or u(piece + 16) > 2 then return nil, "unsupported armor piece layout" end
                    if slot == 0 then helmet_piece = true end
                end
                if kind == 1 and not helmet_piece then return nil, "helmet kit has no helmet piece" end
            end
            headers[i] = {cursor, ffi.string(C.blob + cursor, 24)}
            if kind == 1 then fields[#fields + 1] = {start + 28, kit} end
            cursor = start + size
        end
        if cursor ~= offset or #fields == 0 then return nil, "invalid armor extent or empty helmet set" end
        return {fields = fields, count = count, length = offset, headers = headers,
            header = ffi.string(C.blob, 32), address_mode = address_mode}
    end

    function C.source(base, install)
        if kernel.VirtualQuery(ffi.cast("const void *", base), mem_region,
            ffi.sizeof(mem_region[0])) ~= ffi.sizeof(mem_region[0]) then return false, "armor region unavailable" end
        local region = mem_region[0]
        local region_base = tonumber(ffi.cast("uintptr_t", region.base))
        local length = tonumber(region.size) - (base - region_base)
        if not C.span(base, 32) or tonumber(region.type) ~= 0x20000 then return false, "unsafe armor region" end
        local parsed, why = C.parse_source(base, length)
        if not parsed then status("source", why); return false, why end
        if not install and C.source_base == base then
            if parsed.header ~= C.source_header or parsed.length ~= C.source_length or #parsed.fields ~= #HELMET_FIELDS
                or parsed.address_mode ~= C.source_mode then
                return false, "armor layout changed before write"
            end
            for i, field in ipairs(parsed.fields) do
                if field[1] ~= HELMET_FIELDS[i][1] or field[2] ~= HELMET_FIELDS[i][2] then
                    return false, "armor kit mapping changed before write"
                end
            end
            for i, header in ipairs(parsed.headers) do
                if not C.headers[i] or header[1] ~= C.headers[i][1] or header[2] ~= C.headers[i][2] then
                    return false, "armor record layout changed before write"
                end
            end
        else
            HELMET_FIELDS = parsed.fields
            for kit in pairs(HELMET_IDS) do HELMET_IDS[kit] = nil end
            for _, field in ipairs(HELMET_FIELDS) do HELMET_IDS[field[2]] = true end
            C.source_base, C.source_header, C.source_length, C.headers = base, parsed.header, parsed.length, parsed.headers
            C.source_mode = parsed.address_mode
            if C.previous_source then M.runtime_header = nil end
            C.previous_source = base
            M.helmet_count, M.record_count = #parsed.fields, parsed.count
        end
        status("source", string.format("DL1 checked; %d records, %d helmets, %d bytes; %s arrays checked within payload",
            parsed.count, #parsed.fields, parsed.length, parsed.address_mode))
        return true
    end

    function C.input_entry(prefix, rva)
        if C.entry and C.entry_frame == M.frame then return C.entry end
        rva = C.entry_rva or rva
        local address = C.address(rva, #prefix)
        if address and C.span(address, #prefix, true) and read_bytes(address, #prefix) == prefix then
            C.entry, C.entry_rva, C.entry_frame = address, rva, M.frame
            status("input_entry", string.format("signature checked at +0x%x", rva)); return address
        end
        C.entry = nil
        if C.entry_lookup_done then return nil end
        if M.now_ms < (C.entry_retry or 0) then return nil end
        if (C.entry_attempts or 0) >= 3 then
            C.entry_lookup_done = true
            status("input_entry", "signature lookup retry limit reached; native call refused"); return nil
        end
        C.entry_retry = M.now_ms + 1000
        local image, found, count, total = C.game(), nil, 0, 0
        if not image then return nil end
        C.entry_attempts = (C.entry_attempts or 0) + 1
        local buffer = ffi.new("uint8_t[?]", 0x100000 + #prefix - 1)
        for index = 0, image.section_count - 1 do
            if not read_into(image.sections + index * 40, 40) then
                status("input_entry", "incomplete PE section table; native call refused"); return nil
            end
            local size, start, flags = tonumber(numbers[2]), tonumber(numbers[3]), tonumber(numbers[9])
            if bit.band(flags, 0x20000000) ~= 0 then
                if size < 1 or start + size > image.length then
                    status("input_entry", "invalid executable section extent"); return nil
                end
                local cursor, finish = image.base + start, image.base + start + size
                while cursor < finish do
                    if kernel.VirtualQuery(ffi.cast("const void *", cursor), mem_region,
                        ffi.sizeof(mem_region[0])) ~= ffi.sizeof(mem_region[0]) then
                        status("input_entry", "incomplete executable region lookup"); return nil
                    end
                    local region = mem_region[0]
                    local next_region = tonumber(ffi.cast("uintptr_t", region.base)) + tonumber(region.size)
                    if next_region <= cursor then status("input_entry", "invalid executable region"); return nil end
                    local stop = math.min(next_region, finish)
                    local low = tonumber(region.protection) % 256
                    if tonumber(region.state) == 0x1000 and (low == 0x20 or low == 0x40 or low == 0x80) then
                        if tonumber(region.protection) >= 0x100 then status("input_entry", "guarded executable region"); return nil end
                        local at = cursor
                        while at < stop do
                            local owned = math.min(0x100000, stop - at)
                            local amount = math.min(owned + #prefix - 1, finish - at)
                            while amount > owned and not C.span(at, amount, true) do amount = amount - 1 end
                            total = total + amount
                            if total > 0x4000000 then status("input_entry", "signature lookup exceeds 64 MiB limit"); return nil end
                            if kernel.ReadProcessMemory(process, ffi.cast("const void *", at), buffer, amount, got) == 0
                                or tonumber(got[0]) ~= amount then status("input_entry", "incomplete signature lookup"); return nil end
                            local data, position = ffi.string(buffer, amount), 1
                            while true do
                                local hit = data:find(prefix, position, true)
                                if not hit then break end
                                if hit <= owned then
                                    found, count = at + hit - 1, count + 1
                                    if count > 1 then
                                        C.entry_lookup_done = true
                                        status("input_entry", "ambiguous input signature; native call refused"); return nil
                                    end
                                end
                                position = hit + 1
                            end
                            at = at + 0x100000
                        end
                    end
                    cursor = stop
                end
            end
        end
        if count == 1 and C.span(found, #prefix, true) and read_bytes(found, #prefix) == prefix then
            C.entry, C.entry_rva, C.entry_frame = found, found - image.base, M.frame
            status("input_entry", string.format("unique complete signature relocated to +0x%x", C.entry_rva))
            return found
        end
        C.entry_lookup_done = true
        status("input_entry", "known signature unavailable; native call refused")
    end

    function C.input_owner(owner)
        if C.owner == owner and C.owner_frame == M.frame then return true end
        -- Covers the established 13 groups of 97 action states, 32 bytes each.
        if not C.span(owner, 808 + 13 * 97 * 32) or not read_bytes(owner, 8)
            or not read_bytes(owner + 808 + 13 * 97 * 32 - 8, 8) then
            status("input_owner", "input object extent unavailable"); return false
        end
        status("input_owner", "object memory checked; action behavior requires live verification")
        C.owner, C.owner_frame = owner, M.frame
        return true
    end

    function C.capture(label)
        if not READ_ONLY or not C.game() then return end
        local image = C.game()
        for name, rva in pairs({input = 0x12fde90, dispatch = 0x3326e68, owner = 0x347cf18,
            loadout = 0x347ce38, font = 0x3772268, material = 0x37c5478, atlas = 0x3772ee8}) do
            local address = C.address(rva, 64)
            local data = address and read_bytes(address, 64)
            local hex = data and (data:gsub(".", function(char) return string.format("%02x", char:byte()) end)) or "unreadable"
            note("probe " .. label .. " " .. name .. ": " .. hex)
        end
        local owner_slot = C.address(0x347cf18, 8)
        local owner = owner_slot and read64(owner_slot)
        if owner and owner >= 0x10000 then C.input_owner(owner) end
        note(string.format("probe %s: game stamp %08X; no native calls, GUI mutations or passive writes", label, image.stamp))
    end
    return C
end)()
