-- Search only complete, caller-owned buffers. Positions use Lua's 1-based API.
local search = {initialized = false, fallbacks = 0, copies = 0}
ffi.cdef[[
    void *hd2dap_search_v1_memchr(const void *, int, size_t) __asm__("memchr");
    int hd2dap_search_v1_memcmp(const void *, const void *, size_t) __asm__("memcmp");
]]

function search.prepare(buffer, amount, marker)
    assert(type(amount) == "number" and amount >= 0 and amount <= 0x100200
        and amount % 1 == 0, "invalid search buffer length")
    assert(#marker == 12, "unsupported runtime marker length")
    if not search.initialized then
        search.initialized = true
        local ok, result = pcall(function()
            local library = ffi.load("ucrtbase")
            return {library = library, memchr = library.hd2dap_search_v1_memchr,
                memcmp = library.hd2dap_search_v1_memcmp}
        end)
        if ok then search.native = result end
        M.search_status = ok and "native with density fallback" or "string fallback: " .. tostring(result):sub(1, 120)
        note("runtime search: " .. M.search_status)
    end
    local state = {buffer = buffer, amount = amount, marker = marker, first_byte = marker:byte(1),
        budget = math.max(1, math.floor(amount / 128))}
    if not search.native then
        state.data = ffi.string(buffer, amount)
        search.copies = search.copies + 1
    elseif not search.marker then
        search.marker = ffi.new("uint8_t[?]", #marker)
        ffi.copy(search.marker, marker, #marker)
        search.marker_value = marker
    end
    assert(not search.native or search.marker_value == marker, "runtime marker changed")
    return state
end

function search.find(state, at)
    assert(type(at) == "number" and at >= 1 and at % 1 == 0, "invalid search start")
    if state.data then return state.data:find(state.marker, at, true) end
    local offset, limit = at - 1, state.amount - #state.marker
    while offset <= limit do
        if state.budget == 0 then
            state.data = ffi.string(state.buffer, state.amount)
            search.fallbacks, search.copies = search.fallbacks + 1, search.copies + 1
            return state.data:find(state.marker, offset + 1, true)
        end
        local pointer = search.native.memchr(state.buffer + offset, state.first_byte, limit - offset + 1)
        if pointer == nil then return nil end
        local hit = ffi.cast("uint8_t *", pointer)
        local pos = tonumber(hit - state.buffer)
        assert(pos >= offset and pos <= limit, "native search returned an invalid pointer")
        state.budget = state.budget - 1
        if search.native.memcmp(hit, search.marker, #state.marker) == 0 then return pos + 1 end
        offset = pos + 1
    end
end
