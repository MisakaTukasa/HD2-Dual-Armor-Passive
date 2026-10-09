-- Isolated system-font bitmap experiment; bounded uploads and GUI-local material names.
local SF = {pixel_size = 18, max_raster = 16384, glyphs = {}, alpha_step = 64,
    exact_sizes = true, size_glyphs = {}, font_attempts = {}}
SF.families = {
    {name='Microsoft YaHei', aliases={'Microsoft YaHei', '微软雅黑'}},
    {name='Microsoft YaHei UI', aliases={'Microsoft YaHei UI', '微软雅黑 UI'}},
    {name='Microsoft JhengHei', aliases={'Microsoft JhengHei', '微軟正黑體'}},
    {name='Microsoft JhengHei UI', aliases={'Microsoft JhengHei UI', '微軟正黑體 UI'}},
    {name='SimSun', aliases={'SimSun', '宋体', '宋體'}},
}
local ffi = require('ffi')
local bit = require('bit')
ffi.cdef[[
typedef void *hd2dap_sf11_handle;
typedef unsigned short hd2dap_sf11_wchar;
typedef struct { long x; long y; } hd2dap_sf11_point;
typedef struct {
    unsigned long width, height;
    hd2dap_sf11_point origin;
    short advance_x, advance_y;
} hd2dap_sf11_metrics;
typedef struct { unsigned short fract; short value; } hd2dap_sf11_fixed;
typedef struct {
    hd2dap_sf11_fixed a, b, c, d;
} hd2dap_sf11_matrix;
typedef struct {
    long height, ascent, descent, internal_leading, external_leading;
    long average_width, max_width, weight, overhang, digitized_x, digitized_y;
    hd2dap_sf11_wchar first_char, last_char, default_char, break_char;
    unsigned char italic, underlined, struck_out, pitch_and_family, charset;
} hd2dap_sf11_textmetrics;
hd2dap_sf11_handle hd2dap_sf11_CreateCompatibleDC(hd2dap_sf11_handle) __asm__("CreateCompatibleDC");
int hd2dap_sf11_DeleteDC(hd2dap_sf11_handle) __asm__("DeleteDC");
hd2dap_sf11_handle hd2dap_sf11_CreateFontW(int,int,int,int,int,unsigned long,unsigned long,
    unsigned long,unsigned long,unsigned long,unsigned long,unsigned long,
    unsigned long,const hd2dap_sf11_wchar *) __asm__("CreateFontW");
hd2dap_sf11_handle hd2dap_sf11_SelectObject(hd2dap_sf11_handle,hd2dap_sf11_handle) __asm__("SelectObject");
int hd2dap_sf11_DeleteObject(hd2dap_sf11_handle) __asm__("DeleteObject");
int hd2dap_sf11_GetTextFaceW(hd2dap_sf11_handle,int,hd2dap_sf11_wchar *) __asm__("GetTextFaceW");
int hd2dap_sf11_GetTextMetricsW(hd2dap_sf11_handle,hd2dap_sf11_textmetrics *) __asm__("GetTextMetricsW");
unsigned long hd2dap_sf11_GetGlyphIndicesW(hd2dap_sf11_handle,const hd2dap_sf11_wchar *,int,
    unsigned short *,unsigned long) __asm__("GetGlyphIndicesW");
unsigned long hd2dap_sf11_GetGlyphOutlineW(hd2dap_sf11_handle,unsigned int,unsigned int,
    hd2dap_sf11_metrics *,unsigned long,void *,const hd2dap_sf11_matrix *) __asm__("GetGlyphOutlineW");
]]
assert(ffi.abi('win') and ffi.sizeof('void *') == 8
    and ffi.sizeof('hd2dap_sf11_metrics') == 20 and ffi.sizeof('hd2dap_sf11_matrix') == 16
    and ffi.sizeof('hd2dap_sf11_textmetrics') == 60,
    'system font experiment requires the Win64 GDI ABI')
local library = ffi.load('gdi32')
local gdi = setmetatable({_library = library}, {__index = function(_, name)
    return library['hd2dap_sf11_' .. name]
end})
local function codes(text)
    local result, at = {}, 1
    while at <= #text do
        local a, b, c = text:byte(at, at + 2)
        local value, length
        if a < 128 then value, length = a, 1
        elseif a >= 194 and a <= 223 and b and b >= 128 and b <= 191 then
            value, length = (a - 192) * 64 + b - 128, 2
        elseif a >= 224 and a <= 239 and b and c and b >= 128 and b <= 191
            and c >= 128 and c <= 191 then
            value, length = (a - 224) * 4096 + (b - 128) * 64 + c - 128, 3
            assert(value >= 2048 and (value < 55296 or value > 57343), 'invalid UTF-8')
        else error('system font experiment supports BMP menu characters only') end
        result[#result + 1] = value
        at = at + length
    end
    return result
end
SF.codes = codes

local function wide(text)
    local values = codes(text)
    local out = ffi.new('hd2dap_sf11_wchar[?]', #values + 1)
    for i, value in ipairs(values) do out[i - 1] = value end
    return out
end

-- Keep full GDI gray coverage; only small, bounded tiles are uploaded.
SF.compact = function(glyph) return 0 end
-- Leave 32 bytes of margin inside the engine's 2048-byte decoder buffer.
SF.max_upload, SF.texture_slot = 2016, '3aa8b87e00000000'
SF.textures, SF.texture_sizes, SF.layers = {}, {}, {}
SF.generation, SF.bitmap_created, SF.bitmap_destroyed, SF.label_reused = 0, 0, 0, 0
SF.weight_glyphs = {[400] = SF.size_glyphs, [700] = {}}
function SF.weight_for_language(language)
    return 700
end
local function rasterize(required, family, pixel_size, weight)
    local dc, font, old
    local ok, result = pcall(function()
        dc = gdi.CreateCompatibleDC(nil)
        assert(dc ~= nil, 'CreateCompatibleDC failed')
        font = gdi.CreateFontW(-pixel_size, 0, 0, 0, weight, 0, 0, 0,
            1, 4, 0, 4, 0, wide(family.name))
        assert(font ~= nil, 'CreateFontW failed')
        old = gdi.SelectObject(dc, font)
        assert(old ~= nil and old ~= ffi.cast('void *', -1), 'SelectObject failed')
        local name = ffi.new('hd2dap_sf11_wchar[128]')
        local n = gdi.GetTextFaceW(dc, 128, name)
        assert(n > 0, 'GetTextFaceW failed')
        local actual = {}
        for i = 0, n - 1 do
            if name[i] == 0 then break end
            actual[#actual + 1] = tonumber(name[i])
        end
        local function same(expected)
            local values = codes(expected)
            if #actual ~= #values then return false end
            for i, value in ipairs(values) do if actual[i] ~= value then return false end end
            return true
        end
        local matched = false
        for _, alias in ipairs(family.aliases) do if same(alias) then matched = true; break end end
        assert(matched, family.name .. ' substituted by GDI')
        local textmetrics = ffi.new('hd2dap_sf11_textmetrics[1]')
        assert(gdi.GetTextMetricsW(dc, textmetrics) ~= 0, 'GetTextMetricsW failed')
        assert(tonumber(textmetrics[0].weight) == weight,
            'selected font weight differs from requested weight')
        local needed = {}
        for _, text in ipairs(required) do
            for _, value in ipairs(codes(text)) do needed[value] = true end
        end
        local matrix = ffi.new('hd2dap_sf11_matrix[1]')
        matrix[0].a.value, matrix[0].d.value = 1, 1
        local char, index = ffi.new('hd2dap_sf11_wchar[1]'), ffi.new('unsigned short[1]')
        local metrics = ffi.new('hd2dap_sf11_metrics[1]')
        local glyphs, count, bytes, largest, run_count = {}, 0, 0, 0, 0
        for value in pairs(needed) do
            char[0] = value
            assert(gdi.GetGlyphIndicesW(dc, char, 1, index, 1) ~= 0xffffffff
                and index[0] ~= 0xffff, 'font missing U+' .. string.format('%04X', value))
            local length = tonumber(gdi.GetGlyphOutlineW(dc, index[0], 134, metrics, 0, nil, matrix))
            assert(length ~= 0xffffffff, 'GetGlyphOutlineW failed')
            local gm = metrics[0]
            local glyph = {advance = tonumber(gm.advance_x), left = tonumber(gm.origin.x) - 1,
                bottom = tonumber(gm.origin.y) - tonumber(gm.height) - 1}
            if length > 0 and gm.width > 0 and gm.height > 0 then
                glyph.width, glyph.height = tonumber(gm.width) + 2, tonumber(gm.height) + 2
                local size = glyph.width * glyph.height * 4
                assert(size <= SF.max_raster, 'glyph exceeds bounded raster size')
                local mask = ffi.new('unsigned char[?]', length)
                assert(tonumber(gdi.GetGlyphOutlineW(dc, index[0], 134, metrics,
                    length, mask, matrix)) == length, 'glyph read failed')
                local pixels = ffi.new('unsigned char[?]', size)
                local stride = bit.band(tonumber(gm.width) + 3, bit.bnot(3))
                assert(length >= stride * tonumber(gm.height), string.format(
                    'short glyph bitmap U+%04X: bytes=%d stride=%d width=%d height=%d',
                    value, length, stride, tonumber(gm.width), tonumber(gm.height)))
                for y = 0, tonumber(gm.height) - 1 do
                    for x = 0, tonumber(gm.width) - 1 do
                        local coverage = math.floor(tonumber(mask[y * stride + x]) * 255 / 64 + 0.5)
                        local at = ((y + 1) * glyph.width + x + 1) * 4
                        for channel = 0, 3 do pixels[at + channel] = coverage end
                    end
                end
                glyph.raster_bytes = size
                glyph.rgba = ffi.string(pixels, size)
                bytes, largest = bytes + size, math.max(largest, size)
                run_count = run_count + SF.compact(glyph)
            end
            glyphs[value], count = glyph, count + 1
        end
        return {glyphs=glyphs, count=count, bytes=bytes, largest=largest, run_count=run_count,
            weight=tonumber(textmetrics[0].weight)}
    end)
    if old and old ~= ffi.cast('void *', -1) then gdi.SelectObject(dc, old) end
    if font then gdi.DeleteObject(font) end
    if dc then gdi.DeleteDC(dc) end
    return ok, result
end

function SF.prepare(required)
    if SF.ready then return true end
    local all = {' !"#$%&\'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~'}
    for _, text in ipairs(required) do all[#all + 1] = text end
    SF.font_attempts = {}
    for _, family in ipairs(SF.families) do
        local ok, result = rasterize(all, family, SF.pixel_size, 400)
        local bold
        if ok then
            local bold_ok
            bold_ok, bold = rasterize(all, family, SF.pixel_size, 700)
            if not bold_ok then ok, result = false, bold end
        end
        if ok then
            SF.family, SF.face = family, family.name
            SF.glyphs, SF.count, SF.bytes = result.glyphs, result.count, result.bytes + bold.bytes
            SF.largest = math.max(result.largest, bold.largest)
            SF.run_count, SF.ready = result.run_count, true
            SF.size_glyphs[SF.pixel_size] = SF.glyphs
            SF.weight_glyphs[700][SF.pixel_size] = bold.glyphs
            SF.actual_weights = {normal=result.weight, chinese=bold.weight}
            return true
        end
        SF.font_attempts[#SF.font_attempts + 1] = family.name .. ': ' .. tostring(result):gsub('^.-:%d+: ', ''):sub(1, 240)
    end
    return false, table.concat(SF.font_attempts, '; ')
end

function SF.ensure(text, size, weight)
    assert(SF.ready, 'font has not been prepared')
    assert(size == math.floor(size) and size >= 8 and size <= 48, 'unsupported menu font size')
    weight = weight or 400
    assert(weight == 400 or weight == 700, 'unsupported menu font weight')
    local sizes = SF.weight_glyphs[weight]
    if not SF.exact_sizes then return sizes[SF.pixel_size], size / SF.pixel_size end
    local glyphs = sizes[size] or {}
    local missing = {}
    for _, code in ipairs(codes(text)) do
        if not glyphs[code] then
            -- Keep the original UTF-8 text as input; duplicate characters are deduplicated by rasterize.
            missing[1] = text
            break
        end
    end
    if #missing > 0 then
        local ok, result = rasterize(missing, SF.family, size, weight)
        assert(ok, tostring(result))
        for code, glyph in pairs(result.glyphs) do
            if not glyphs[code] then
                glyphs[code] = glyph
                SF.bytes = SF.bytes + (glyph.raster_bytes or 0)
                SF.run_count = SF.run_count + #(glyph.runs or {})
            end
        end
        SF.largest = math.max(SF.largest, result.largest)
        sizes[size] = glyphs
    end
    return glyphs, 1
end

local alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

local function base64(bytes)
    local output = {}
    for at = 1, #bytes, 3 do
        local a, b, c = bytes:byte(at, at + 2)
        local word = a * 65536 + (b or 0) * 256 + (c or 0)
        local a1, a2 = math.floor(word / 262144) % 64, math.floor(word / 4096) % 64
        local a3, a4 = math.floor(word / 64) % 64, word % 64
        output[#output + 1] = alphabet:sub(a1 + 1, a1 + 1)
            .. alphabet:sub(a2 + 1, a2 + 1)
            .. (b and alphabet:sub(a3 + 1, a3 + 1) or '=')
            .. (c and alphabet:sub(a4 + 1, a4 + 1) or '=')
    end
    return table.concat(output)
end
SF.base64 = base64
function SF.api_available(engine)
    for _, pair in ipairs({{'Renderer','create_resource'}, {'Renderer','update_texture_base64'},
        {'Renderer','destroy_resource'}, {'Gui','bitmap_uv'}, {'Gui','destroy_bitmap'},
        {'Gui','material'}, {'Material','set_resource'}, {'World','create_screen_gui'},
        {'World','destroy_gui'}, {'IdString64','from_hex'}}) do
        if not engine or not engine[pair[1]] or not engine[pair[1]][pair[2]] then
            return false, pair[1] .. '.' .. pair[2] .. ' unavailable'
        end
    end
    return true
end

local function destroy_label(engine, label)
    while #label.items > 0 do
        local item = label.items[#label.items]
        engine.Gui.destroy_bitmap(item.owner.gui, item.id)
        item.owner.bitmaps[item.id] = nil
        table.remove(label.items)
        SF.bitmap_destroyed = SF.bitmap_destroyed + 1
    end
end

function SF.begin_render()
    SF.generation = SF.generation + 1
end

function SF.end_render(engine)
    for _, layer in ipairs(SF.layers) do
        for slot, label in pairs(layer.labels) do
            if label.generation ~= SF.generation then
                destroy_label(engine, label)
                layer.labels[slot] = nil
            end
        end
    end
    -- Keep GPU resources only for the current view; CPU masks remain cached.
    local used = {}
    for _, layer in ipairs(SF.layers) do
        for key, glyph in pairs(layer.glyphs) do
            if next(glyph.bitmaps) == nil then
                engine.World.destroy_gui(layer.world, glyph.gui)
                layer.glyphs[key] = nil
            else
                used[key] = true
            end
        end
    end
    for key, texture in pairs(SF.textures) do
        if not used[key] then
            engine.Renderer.destroy_resource(texture)
            SF.textures[key] = nil
            SF.texture_sizes[key] = nil
        end
    end
end

function SF.clear(engine)
    for _, layer in ipairs(SF.layers) do
        for slot, label in pairs(layer.labels) do
            destroy_label(engine, label)
            layer.labels[slot] = nil
        end
    end
end

function SF.release(engine, worlds)
    if type(worlds) ~= 'table' then return false end
    local present = {}
    for _, world in ipairs(worlds) do present[world] = true end
    -- Destroying a GUI destroys its owned primitives. Keep failed handles for retry.
    for _, layer in ipairs(SF.layers) do
        if present[layer.world] then
            for key, glyph in pairs(layer.glyphs) do
                engine.World.destroy_gui(layer.world, glyph.gui)
                layer.glyphs[key] = nil
            end
        end
    end
    SF.layers = {}
    -- No surviving GUI can consume these textures; known-world errors return before this point.
    for key, texture in pairs(SF.textures) do
        engine.Renderer.destroy_resource(texture)
        SF.textures[key] = nil
        SF.texture_sizes[key] = nil
    end
    return true
end

function SF.tiles(glyph)
    if glyph.tiles then return glyph.tiles end
    local tiles = {}
    if glyph.rgba then
        assert(glyph.width <= math.floor(SF.max_upload / 4)
            and #glyph.rgba == glyph.width * glyph.height * 4)
        local rows = math.floor(SF.max_upload / (glyph.width * 4))
        assert(rows >= 1, 'tile width exceeds bounded upload size')
        for y = 0, glyph.height - 1, rows do
            local height = math.min(rows, glyph.height - y)
            local rgba = glyph.rgba:sub(y * glyph.width * 4 + 1, (y + height) * glyph.width * 4)
            assert(#rgba == glyph.width * height * 4 and #rgba <= SF.max_upload)
            tiles[#tiles + 1] = {width=glyph.width, height=height, top=y, rgba=rgba}
        end
    end
    glyph.tiles = tiles
    return tiles
end

function SF.draw(engine, host, text, x, y, size, r, g, b, material_name, weight)
    weight = weight or 400
    local layer
    for _, item in ipairs(SF.layers) do if item.world == host.world then layer = item; break end end
    if not layer then
        layer = {world=host.world, glyphs={}, labels={}}
        SF.layers[#SF.layers + 1] = layer
    end
    local slot = x .. ':' .. y
    local signature = text .. ':' .. size .. ':' .. weight .. ':' .. (r or 255) .. ':' .. (g or 255) .. ':' .. (b or 255)
    local label = layer.labels[slot]
    if label and label.signature == signature then
        label.generation = SF.generation
        SF.label_reused = SF.label_reused + 1
        return
    end
    if label then destroy_label(engine, label) end
    label = {signature=signature, generation=SF.generation, items={}}
    layer.labels[slot] = label
    local glyphs, scale = SF.ensure(text, size, weight)
    assert(scale == 1, 'bitmap glyphs must use their actual pixel size')
    local cursor = math.floor(x + 0.5)
    for _, code in ipairs(codes(text)) do
        local glyph = assert(glyphs[code], 'unprepared menu glyph')
        for at, tile in ipairs(SF.tiles(glyph)) do
            local key = weight .. ':' .. size .. ':' .. code .. ':' .. at
            local drawable = layer.glyphs[key]
            if not drawable then
                local texture = SF.textures[key]
                if not texture then
                    texture = assert(engine.Renderer.create_resource('texture', 'R8G8B8A8',
                        tile.width, tile.height), 'dynamic texture creation failed')
                    SF.textures[key] = texture
                    SF.texture_sizes[key] = #tile.rgba
                    engine.Renderer.update_texture_base64(texture, base64(tile.rgba), #tile.rgba)
                end
                local gui = assert(engine.World.create_screen_gui(host.world, 0, 0,
                    'scale', 1, 1), 'glyph GUI creation failed')
                drawable = {gui=gui, bitmaps={}}
                layer.glyphs[key] = drawable
                if engine.Gui.set_visible then engine.Gui.set_visible(gui, true) end
                local ink = assert(engine.Gui.material(gui, material_name), 'glyph material unavailable')
                engine.Material.set_resource(ink, engine.IdString64.from_hex(SF.texture_slot), texture)
            end
            -- Both GUI modes accept names and resolve the same GUI-local material as Gui.material.
            -- One mode rejects pointers without consuming the argument, shifting the geometry.
            local id = assert(engine.Gui.bitmap_uv(drawable.gui, material_name,
                engine.Vector2(0, 0), engine.Vector2(1, 1),
                engine.Vector3(cursor + glyph.left,
                    math.floor(y + 0.5) + glyph.bottom + glyph.height - tile.top - tile.height, 902),
                engine.Vector2(tile.width, tile.height),
                engine.Color(255, r or 255, g or 255, b or 255)), 'glyph bitmap creation failed')
            drawable.bitmaps[id] = true
            label.items[#label.items + 1] = {owner=drawable, id=id}
            SF.bitmap_created = SF.bitmap_created + 1
        end
        cursor = cursor + glyph.advance
    end
end

function SF.stats()
    local textures, guis, bitmaps, bytes = 0, 0, 0, 0
    for key in pairs(SF.textures) do
        textures = textures + 1
        bytes = bytes + SF.texture_sizes[key]
    end
    for _, layer in ipairs(SF.layers) do
        for _, glyph in pairs(layer.glyphs) do
            guis = guis + 1
            for _ in pairs(glyph.bitmaps) do bitmaps = bitmaps + 1 end
        end
    end
    return textures, guis, bitmaps, bytes
end

ffi.cdef[[
int hd2dap_sf11_QueryPerformanceCounter(int64_t *) __asm__("QueryPerformanceCounter");
int hd2dap_sf11_QueryPerformanceFrequency(int64_t *) __asm__("QueryPerformanceFrequency");
]]
local timer = ffi.load('kernel32')
local frequency, counter = ffi.new('int64_t[1]'), ffi.new('int64_t[1]')
local timer_ok = pcall(function()
    assert(timer.hd2dap_sf11_QueryPerformanceFrequency(frequency) ~= 0 and frequency[0] > 0)
end)
function SF.clock()
    if timer_ok and timer.hd2dap_sf11_QueryPerformanceCounter(counter) ~= 0 then
        return tonumber(counter[0]) * 1000 / tonumber(frequency[0])
    end
    return os.clock() * 1000
end
return SF
