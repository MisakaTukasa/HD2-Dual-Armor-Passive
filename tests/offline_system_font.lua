-- Engine mock for the installed-font backend. No game connection.
local resources = {}
s3d.Renderer = {
    create_resource = function(kind, format, width, height)
        assert(kind == "texture" and format == "R8G8B8A8" and width * height * 4 <= 2016)
        local resource = {width = width, height = height}
        resources[resource] = true
        return resource
    end,
    update_texture_base64 = function(resource, payload, size)
        assert(resources[resource] and size == resource.width * resource.height * 4)
        assert(#payload == math.ceil(size / 3) * 4 and size <= 2016)
    end,
    destroy_resource = function(resource)
        assert(resources[resource])
        for _, entry in pairs(ctx.gui_entries) do
            local live_world = ctx.worlds_override == nil
            for _, world in ipairs(ctx.worlds_override or {}) do
                if world == entry.instance.world then live_world = true end
            end
            assert(not live_world or not entry.instance.ink or entry.instance.ink.texture ~= resource,
                "font texture still has live primitives")
        end
        resources[resource] = nil
    end,
}
s3d.Gui.material = function(instance, name)
    assert(name == "core/performance_hud/debug")
    instance.glyph_gui = true
    instance.ink = {gui = instance}
    return instance.ink
end
local set_resource = function(ink, slot, resource)
    assert(resources[resource] and slot.hash == "3aa8b87e00000000" and slot.frame == ctx.frame)
    ink.texture = resource
end
setmetatable(s3d.Material, {__index = function(_, key)
    if key == "set_resource" and ctx.font_failure ~= "resources" and ctx.font_failure ~= "api" then
        return set_resource
    end
end})
s3d.Gui.bitmap_uv = function(instance, name, uv0, uv1, position, size, color)
    assert(instance.glyph_gui and name == "core/performance_hud/debug")
    assert(resources[instance.ink.texture] and position.z == 902)
    assert(uv0.x == 0 and uv0.y == 0 and uv1.x == 1 and uv1.y == 1)
    return gui_entry("bitmap", instance, name, uv0, uv1, position, size, color)
end
s3d.Gui.destroy_bitmap = function(instance, handle)
    assert(ctx.gui_entries[handle].instance == instance)
    ctx.gui_entries[handle] = nil
end
local destroy_gui = s3d.World.destroy_gui
s3d.World.destroy_gui = function(world, instance)
    if instance.glyph_gui then
        assert(instance.world == world)
        for handle, entry in pairs(ctx.gui_entries) do
            if entry.instance == instance then ctx.gui_entries[handle] = nil end
        end
    else
        destroy_gui(world, instance)
    end
end
